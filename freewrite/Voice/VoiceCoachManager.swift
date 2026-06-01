import Foundation
import AVFoundation
@preconcurrency import LiveKit

@MainActor
final class VoiceCoachManager: ObservableObject {
    enum Phase: Equatable {
        case idle, authenticating, connecting, listening, speaking, ended
        case error(String)
    }

    @Published var phase: Phase = .idle
    @Published var micMuted = false
    @Published var micLevel: Float = 0     // drives the waveform
    @Published private(set) var transcript: [TranscriptLine] = []

    struct TranscriptLine: Identifiable { let id = UUID(); let speaker: String; let text: String }

    private var room: Room?
    private var levelTask: Task<Void, Never>?
    private(set) var startedAt = Date()
    private(set) var sessionId: String = ""
    private var entryRef: String?
    private var entryType: String = "text"

    // The agent picks the actual model; the client records the configured
    // default (spec §5.4) for the saved session row.
    private static let coachModel = "gemini-2.5-flash"

    func start(context: VoiceContext, entryId: String?) async {
        phase = .authenticating
        entryRef = entryId
        entryType = context.entryType.rawValue

        // Mic permission MUST be granted before LiveKit starts its voice-
        // processing I/O unit. Without it the VPIO unit fails to start
        // (-10877 / HAL error 35), which kills BOTH mic capture and agent
        // playback — you connect but hear nothing and the publish times out.
        guard await ensureMicPermission() else {
            phase = .error("Microphone access is needed. Enable it in System Settings ▸ Privacy ▸ Microphone.")
            return
        }

        let auth = SupabaseAuth.shared
        if !auth.isSignedIn {
            do { try await auth.signInWithGoogle() }
            catch { phase = .error("Sign-in failed"); return }
        }
        phase = .connecting
        // Token mint
        let token: VoiceSessionToken
        do {
            token = try await VoiceTokenClient().mint(
                context: context, entryId: entryId, accessToken: auth.currentToken())
        } catch let e as VoiceTokenError {
            phase = .error(tokenErrorMessage(e)); return
        } catch {
            phase = .error("Token error: \(error.localizedDescription)"); return
        }
        sessionId = token.sessionId
        startedAt = Date()

        // Room connect
        let room = Room()
        room.add(delegate: self)
        do {
            try await room.connect(url: token.wsURL.absoluteString, token: token.token,
                                   roomOptions: RoomOptions(adaptiveStream: true, dynacast: true))
        } catch {
            NSLog("[VoiceCoach] room.connect failed: \(error)")
            phase = .error("Connect failed: \(error.localizedDescription)"); return
        }
        self.room = room

        // Mic publish — a failure here must NOT tear down the room (that's what
        // made the agent see "room disconnected while waiting for participant").
        do {
            try await room.localParticipant.setMicrophone(enabled: true)
        } catch {
            NSLog("[VoiceCoach] setMicrophone failed: \(error)")
            phase = .error("Mic failed: \(error.localizedDescription)"); return
        }

        phase = .listening
        startLevelPolling(room)
    }

    func toggleMute() async {
        guard let room else { return }
        micMuted.toggle()
        try? await room.localParticipant.setMicrophone(enabled: !micMuted)
    }

    func end() async {
        levelTask?.cancel(); levelTask = nil
        await room?.disconnect()
        room = nil
        phase = .ended
        await persistTranscript()
    }

    /// Save the conversation locally and (best-effort) to Supabase on session end.
    /// Skips when nothing was said or no session was established.
    private func persistTranscript() async {
        guard !sessionId.isEmpty, !transcript.isEmpty else { return }
        let endedAt = Date()
        let lines = transcript

        VoiceTranscriptStore.saveLocal(
            entryBase: entryRef ?? "transient",
            sessionId: sessionId, lines: lines,
            startedAt: startedAt, endedAt: endedAt)

        if let userId = await SupabaseAuth.shared.currentUserId() {
            await VoiceTranscriptStore.saveCloud(
                client: SupabaseAuth.shared.supabase, userId: userId,
                sessionId: sessionId, entryRef: entryRef, entryType: entryType,
                lines: lines, startedAt: startedAt, endedAt: endedAt,
                model: Self.coachModel)
        }
    }

    private func startLevelPolling(_ room: Room) {
        levelTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.micLevel = room.localParticipant.audioLevel
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    /// Ensure microphone authorization before LiveKit touches the audio unit.
    private func ensureMicPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false   // denied / restricted
        }
    }

    private func tokenErrorMessage(_ e: VoiceTokenError) -> String {
        switch e {
        case .notAuthenticated: return "Please sign in to use the coach"
        case .badResponse(let s): return "Couldn't start the coach (\(s))"
        case .badURL: return "Server returned a bad address"
        }
    }
}

// Signatures below match RoomDelegate exactly (verified against client-sdk-swift
// 2.14: RoomDelegate.swift lines 129 & 133). They must match exactly or Swift
// treats them as unrelated methods that silently never fire (delegate methods
// have default empty implementations — no compile error, just dead callbacks).
extension VoiceCoachManager: RoomDelegate {
    // Agent speaking/listening from the lk.agent.state participant attribute.
    nonisolated func room(_ room: Room, participant: Participant,
                          didUpdateAttributes attributes: [String: String]) {
        guard let state = attributes["lk.agent.state"] else { return }
        Task { @MainActor in
            switch state {
            case "speaking": self.phase = .speaking
            case "listening", "thinking": if self.phase != .ended { self.phase = .listening }
            default: break
            }
        }
    }

    // Live transcription stream (lk.transcription) — note the trackPublication arg.
    nonisolated func room(_ room: Room, participant: Participant,
                          trackPublication: TrackPublication,
                          didReceiveTranscriptionSegments segments: [TranscriptionSegment]) {
        let isAgent = participant is RemoteParticipant
        Task { @MainActor in
            for seg in segments where seg.isFinal {
                self.transcript.append(.init(speaker: isAgent ? "Coach" : "You", text: seg.text))
            }
        }
    }
}
