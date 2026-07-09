import Foundation
import AVFoundation
@preconcurrency import LiveKit

/// Unified, filterable logging for the voice feature. In Console.app or the
/// Xcode console, filter on "[VoiceCoach]" to see the whole session lifecycle.
@inline(__always) func vclog(_ message: String) {
    NSLog("[VoiceCoach] %@", message)
}

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
    private var coachJoinTimeoutTask: Task<Void, Never>?
    private var coachJoined = false
    private(set) var startedAt = Date()
    private(set) var sessionId: String = ""
    private var entryRef: String?
    private var entryType: String = "text"

    /// How long we wait for the coach agent to join before surfacing an error
    /// instead of sitting in "connecting" forever. The agent normally joins in
    /// ~2s; 15s means it's not running or dispatch is misconfigured.
    private static let coachJoinTimeout: UInt64 = 15_000_000_000

    // The agent picks the actual model; the client records the configured
    // default (spec §5.4) for the saved session row.
    private static let coachModel = "gemini-2.5-flash"

    // One-time audio device module selection, done before any peer connection.
    nonisolated(unsafe) private static var admConfigured = false

    /// Select WebRTC's native HAL-based audio device module on macOS instead of
    /// the default AVAudioEngine ADM. The AVAudioEngine path fails on this Mac
    /// with `AVAudioEngineGraph Start: kAUStartIO error 35` (it can't start the
    /// audio unit — fights the system/other LiveKit apps over the device), which
    /// blocks BOTH mic publish and agent playback. `.platformDefault` uses HAL
    /// APIs directly and sidesteps AVAudioEngine entirely. MUST run before the
    /// first Room is created. Idempotent + safe to call once per process.
    static func configureAudioDeviceModuleIfNeeded() {
        guard !admConfigured else { return }
        do {
            try AudioManager.set(audioDeviceModuleType: .platformDefault)
            admConfigured = true
            vclog("audioDeviceModuleType = .platformDefault")
        } catch {
            vclog("set(audioDeviceModuleType:) FAILED: \(error)")
        }
    }

    func start(context: VoiceContext, entryId: String?) async {
        // Must precede any Room()/peer-connection init.
        VoiceCoachManager.configureAudioDeviceModuleIfNeeded()

        vclog("start: entryType=\(context.entryType.rawValue) chars=\(context.entryText.count) truncated=\(context.truncated)")
        phase = .authenticating
        entryRef = entryId
        entryType = context.entryType.rawValue
        coachJoined = false
        transcript = []

        // Mic permission MUST be granted before LiveKit starts audio I/O;
        // without it the audio unit fails and kills capture AND playback.
        guard await ensureMicPermission() else {
            vclog("mic permission missing/denied")
            phase = .error("Microphone access is needed. Enable it in System Settings ▸ Privacy ▸ Microphone.")
            return
        }

        let auth = SupabaseAuth.shared
        if !auth.isSignedIn {
            vclog("not signed in — starting Google OAuth")
            do { try await auth.signInWithGoogle() }
            catch {
                vclog("sign-in failed: \(error)")
                phase = .error("Sign-in failed"); return
            }
        }
        phase = .connecting

        // Token mint
        let token: VoiceSessionToken
        do {
            token = try await VoiceTokenClient().mint(
                context: context, entryId: entryId, accessToken: auth.currentToken())
            vclog("token minted, session=\(token.sessionId)")
        } catch let e as VoiceTokenError {
            vclog("token mint failed: \(e)")
            phase = .error(tokenErrorMessage(e)); return
        } catch {
            vclog("token mint failed: \(error)")
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
            vclog("room connected: \(token.sessionId)")
        } catch {
            vclog("room.connect FAILED: \(error)")
            phase = .error("Connect failed: \(error.localizedDescription)"); return
        }
        self.room = room

        // Mic publish — a failure here must NOT tear down the room (that's what
        // made the agent see "room disconnected while waiting for participant").
        do {
            try await room.localParticipant.setMicrophone(enabled: true)
            vclog("mic published")
        } catch {
            vclog("setMicrophone FAILED: \(error)")
            phase = .error("Mic failed: \(error.localizedDescription)"); return
        }

        startLevelPolling(room)

        // The coach may already be in the room (dispatch can beat our delegate
        // registration) — check before arming the join timeout.
        for (_, participant) in room.remoteParticipants {
            if Self.isCoach(participant) {
                vclog("coach already present: \(participant.identity?.stringValue ?? "?")")
                markCoachJoined()
                return
            }
        }

        // Stay in .connecting ("Connecting to your coach…") until the agent
        // actually joins; error out with an actionable message if it never does.
        vclog("waiting for coach to join (timeout \(Self.coachJoinTimeout / 1_000_000_000)s)…")
        coachJoinTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.coachJoinTimeout)
            guard let self, !Task.isCancelled else { return }
            if !self.coachJoined, self.phase == .connecting {
                vclog("coach NEVER JOINED — agent not running or dispatch misconfigured")
                self.phase = .error("The coach didn't join. Start the agent (backend/voice-coach-agent/run-agent.sh) and try again.")
                await self.room?.disconnect()
                self.room = nil
            }
        }
    }

    /// Agent participant present → session is live.
    private func markCoachJoined() {
        guard !coachJoined else { return }
        coachJoined = true
        coachJoinTimeoutTask?.cancel(); coachJoinTimeoutTask = nil
        if phase == .connecting { phase = .listening }
        vclog("coach joined ✓ — session live")
    }

    /// A remote participant is the coach if LiveKit marks it as an agent (or,
    /// belt-and-braces, its identity uses the server's agent- prefix).
    nonisolated private static func isCoach(_ p: RemoteParticipant) -> Bool {
        if p.kind == .agent { return true }
        return p.identity?.stringValue.hasPrefix("agent") ?? false
    }

    func toggleMute() async {
        guard let room else { return }
        micMuted.toggle()
        vclog("mic muted=\(micMuted)")
        try? await room.localParticipant.setMicrophone(enabled: !micMuted)
    }

    func end() async {
        vclog("end: session=\(sessionId) transcriptLines=\(transcript.count)")
        coachJoinTimeoutTask?.cancel(); coachJoinTimeoutTask = nil
        levelTask?.cancel(); levelTask = nil
        await room?.disconnect()
        room = nil
        phase = .ended
        await persistTranscript()
    }

    /// Save the conversation locally and (best-effort) to Supabase on session end.
    /// Skips when nothing was said or no session was established.
    private func persistTranscript() async {
        guard !sessionId.isEmpty, !transcript.isEmpty else {
            vclog("persist: skipped (session empty)")
            return
        }
        let endedAt = Date()
        let lines = transcript

        VoiceTranscriptStore.saveLocal(
            entryBase: entryRef ?? "transient",
            sessionId: sessionId, lines: lines,
            startedAt: startedAt, endedAt: endedAt)
        vclog("persist: local transcript saved (\(lines.count) lines)")

        if let userId = await SupabaseAuth.shared.currentUserId() {
            await VoiceTranscriptStore.saveCloud(
                client: SupabaseAuth.shared.supabase, userId: userId,
                sessionId: sessionId, entryRef: entryRef, entryType: entryType,
                lines: lines, startedAt: startedAt, endedAt: endedAt,
                model: Self.coachModel)
            vclog("persist: cloud row inserted")
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
// RoomDelegate.swift lines 42/98/102/129/133/158). They must match exactly or
// Swift treats them as unrelated methods that silently never fire (delegate
// methods have default empty implementations — no compile error, just dead
// callbacks).
extension VoiceCoachManager: RoomDelegate {
    nonisolated func room(_ room: Room, participantDidConnect participant: RemoteParticipant) {
        let identity = participant.identity?.stringValue ?? "?"
        vclog("participant joined: \(identity) kind=\(participant.kind)")
        guard Self.isCoach(participant) else { return }
        Task { @MainActor in self.markCoachJoined() }
    }

    nonisolated func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) {
        let identity = participant.identity?.stringValue ?? "?"
        vclog("participant left: \(identity)")
        guard Self.isCoach(participant) else { return }
        Task { @MainActor in
            // Coach dropping mid-conversation is an error state, not "listening".
            if self.phase == .listening || self.phase == .speaking {
                self.phase = .error("The coach disconnected. Try again.")
            }
        }
    }

    nonisolated func room(_ room: Room, participant: RemoteParticipant,
                          didSubscribeTrack publication: RemoteTrackPublication) {
        vclog("subscribed to \(publication.kind) track from \(participant.identity?.stringValue ?? "?")")
    }

    // Agent speaking/listening from the lk.agent.state participant attribute.
    nonisolated func room(_ room: Room, participant: Participant,
                          didUpdateAttributes attributes: [String: String]) {
        guard let state = attributes["lk.agent.state"] else { return }
        vclog("lk.agent.state -> \(state)")
        Task { @MainActor in
            self.markCoachJoined()   // publishing agent state proves the coach is here
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
                vclog("transcript[\(isAgent ? "coach" : "you")]: \(seg.text.prefix(80))")
                self.transcript.append(.init(speaker: isAgent ? "Coach" : "You", text: seg.text))
            }
        }
    }
}
