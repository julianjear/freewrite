import Foundation
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

    func start(context: VoiceContext, entryId: String?) async {
        phase = .authenticating
        let auth = SupabaseAuth.shared
        if !auth.isSignedIn {
            do { try await auth.signInWithGoogle() }
            catch { phase = .error("Sign-in failed"); return }
        }
        phase = .connecting
        do {
            let token = try await VoiceTokenClient().mint(
                context: context, entryId: entryId, accessToken: auth.currentToken())
            sessionId = token.sessionId
            startedAt = Date()
            let room = Room()
            room.add(delegate: self)
            try await room.connect(url: token.wsURL.absoluteString, token: token.token,
                                   roomOptions: RoomOptions(adaptiveStream: true, dynacast: true))
            try await room.localParticipant.setMicrophone(enabled: true)
            self.room = room
            phase = .listening
            startLevelPolling(room)
        } catch let e as VoiceTokenError {
            phase = .error(tokenErrorMessage(e))
        } catch {
            phase = .error("Couldn't reach the coach")
        }
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
    }

    private func startLevelPolling(_ room: Room) {
        levelTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.micLevel = room.localParticipant.audioLevel
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
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
