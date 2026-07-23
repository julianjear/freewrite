import Foundation
import AVFoundation
@preconcurrency import LiveKit

@inline(__always) func vclog(_ message: String) {
    NSLog("[VoiceCoach] %@", message)
}

@MainActor
final class VoiceCoachManager: ObservableObject {
    enum Phase: Equatable {
        case idle, authenticating, connecting, listening, speaking, ended
        case error(String)
    }

    struct TranscriptLine: Codable, Identifiable, Equatable {
        let id: UUID
        let speaker: String
        let text: String
        init(id: UUID = UUID(), speaker: String, text: String) {
            self.id = id; self.speaker = speaker; self.text = text
        }
    }

    @Published var phase: Phase = .idle {
        didSet { VoiceCallSounds.shared.handleTransition(from: oldValue, to: phase) }
    }
    @Published var micMuted = false
    @Published var micLevel: Float = 0
    @Published private(set) var transcript: [TranscriptLine] = []
    @Published private(set) var telemetryEvents: [VoiceTelemetryEvent] = []
    @Published private(set) var canvasArtifacts: [VoiceCanvasArtifact] = []
    @Published var showsObservability = false
    @Published private(set) var durationSeconds = 0
    @Published private(set) var activeConfiguration = VoiceSessionConfiguration()
    @Published private(set) var lastCompletedCall: AIVoiceCallSummary?

    var totalEstimatedCost: Double {
        telemetryEvents.totalVoiceEstimatedCostUSD
    }

    var estimatedCostHelp: String {
        let usage = telemetryEvents.last(where: { $0.stage == "session-usage" })
        var parts = [usage?.costBreakdownDescription, usage?.tokenBreakdownDescription]
            .compactMap { $0 }
        parts.append("Measured usage at public list prices. Provider discounts, credits, minimum billing increments, LiveKit transport/deployment, and later invoice adjustments are not included.")
        return parts.joined(separator: "\n\n")
    }

    var elapsedDuration: String {
        String(format: "%d:%02d", durationSeconds / 60, durationSeconds % 60)
    }

    private var room: Room?
    private var levelTask: Task<Void, Never>?
    private var coachJoinTimeoutTask: Task<Void, Never>?
    private var coachJoined = false
    private var isEnding = false
    private(set) var startedAt = Date()
    private(set) var sessionId = ""
    private var entryRef: String?
    private var entryType = "text"
    private var entryDate = ""
    private var persistenceRoot = FileManager.default.urls(
        for: .documentDirectory, in: .userDomainMask
    )[0].appendingPathComponent("Freewrite", isDirectory: true)
    private var recentTranscriptKeys: [String: Date] = [:]

    private static let coachJoinTimeout: UInt64 = 15_000_000_000
    nonisolated(unsafe) private static var admConfigured = false

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

    func start(context: VoiceContext, entryId: String?, configuration: VoiceSessionConfiguration,
               persistenceRoot: URL? = nil) async {
        VoiceCoachManager.configureAudioDeviceModuleIfNeeded()
        activeConfiguration = configuration
        showsObservability = configuration.observabilityEnabled
        entryRef = entryId
        entryType = context.entryType.rawValue
        entryDate = context.entryDate
        if let persistenceRoot { self.persistenceRoot = persistenceRoot }
        coachJoined = false
        micMuted = false
        transcript = []
        recentTranscriptKeys = [:]
        telemetryEvents = []
        canvasArtifacts = []
        durationSeconds = 0
        lastCompletedCall = nil
        sessionId = ""
        isEnding = false

        vclog("start profile=\(configuration.profileId) entryType=\(entryType) chars=\(context.entryText.count)")
        phase = .authenticating
        guard await ensureMicPermission() else {
            phase = .error("Microphone access is needed. Enable it in System Settings ▸ Privacy ▸ Microphone.")
            return
        }

        let auth = SupabaseAuth.shared
        if await auth.currentToken() == nil {
            do { try await auth.signInWithGoogle() }
            catch {
                vclog("sign-in failed: \(error)")
                phase = .error("Sign-in failed: \(error.localizedDescription)")
                return
            }
        }
        phase = .connecting

        let token: VoiceSessionToken
        do {
            token = try await mintToken(
                context: context, entryId: entryId,
                configuration: configuration, auth: auth
            )
            vclog("token minted session=\(token.sessionId)")
        } catch let error as VoiceTokenError {
            vclog("token mint failed: \(error)")
            phase = .error(tokenErrorMessage(error)); return
        } catch {
            vclog("token mint failed: \(error)")
            phase = .error("Token error: \(error.localizedDescription)"); return
        }
        sessionId = token.sessionId
        startedAt = Date()

        let room = Room()
        room.add(delegate: self)
        do {
            try await room.connect(
                url: token.wsURL.absoluteString, token: token.token,
                roomOptions: RoomOptions(adaptiveStream: true, dynacast: true)
            )
            self.room = room
            try await room.localParticipant.setMicrophone(enabled: true)
            vclog("room connected and mic published")
        } catch {
            vclog("room/mic setup FAILED: \(error)")
            await room.disconnect()
            self.room = nil
            phase = .error("Connect failed: \(error.localizedDescription)")
            return
        }

        startLevelPolling(room)
        for (_, participant) in room.remoteParticipants where Self.isCoach(participant) {
            vclog("coach participant present — awaiting backend ready event")
        }

        coachJoinTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.coachJoinTimeout)
            guard let self, !Task.isCancelled else { return }
            if !self.coachJoined, self.phase == .connecting {
                self.coachJoinTimeoutTask = nil
                await self.failActiveCall(
                    "The coach didn't join. Confirm the selected provider credentials and agent deployment, then try again."
                )
            }
        }
    }

    private func mintToken(context: VoiceContext, entryId: String?,
                           configuration: VoiceSessionConfiguration,
                           auth: SupabaseAuth) async throws -> VoiceSessionToken {
        let client = VoiceTokenClient()
        do {
            return try await client.mint(
                context: context, entryId: entryId, configuration: configuration,
                accessToken: await auth.currentToken()
            )
        } catch VoiceTokenError.badResponse(401, _) {
            // One bounded retry after asking Supabase to refresh the session.
            await auth.restore()
            return try await client.mint(
                context: context, entryId: entryId, configuration: configuration,
                accessToken: await auth.currentToken()
            )
        }
    }

    private func markCoachJoined() {
        guard !coachJoined else { return }
        coachJoined = true
        coachJoinTimeoutTask?.cancel(); coachJoinTimeoutTask = nil
        if phase == .connecting { phase = .listening }
        vclog("coach joined — session live")
    }

    nonisolated private static func isCoach(_ participant: RemoteParticipant) -> Bool {
        participant.kind == .agent || (participant.identity?.stringValue.hasPrefix("agent") ?? false)
    }

    func toggleMute() async {
        guard let room else { return }
        micMuted.toggle()
        do { try await room.localParticipant.setMicrophone(enabled: !micMuted) }
        catch { vclog("mute toggle failed: \(error)") }
    }

    func end() async {
        guard !isEnding, phase != .idle, phase != .ended else { return }
        isEnding = true
        defer { isEnding = false }
        vclog("end session=\(sessionId) transcriptLines=\(transcript.count) events=\(telemetryEvents.count)")
        coachJoinTimeoutTask?.cancel(); coachJoinTimeoutTask = nil
        levelTask?.cancel(); levelTask = nil
        await room?.disconnect()
        room = nil
        if let completed = await persistSession() {
            durationSeconds = completed.durationSeconds
            lastCompletedCall = completed
        }
        phase = .ended
    }

    private func persistSession() async -> AIVoiceCallSummary? {
        guard !sessionId.isEmpty else {
            vclog("persist skipped: session empty")
            return nil
        }
        let endedAt = Date()
        let lines = transcript
        let events = telemetryEvents
        let config = activeConfiguration
        VoiceTranscriptStore.saveLocal(
            rootDirectory: persistenceRoot,
            entryBase: entryRef ?? "transient", sessionId: sessionId,
            lines: lines, events: events, configuration: config,
            startedAt: startedAt, endedAt: endedAt
        )
        vclog("persist local session saved")

        let completed = AIVoiceCallSummary(
            sessionId: sessionId,
            entryId: entryRef,
            startedAt: startedAt,
            endedAt: endedAt,
            durationSeconds: max(0, Int(endedAt.timeIntervalSince(startedAt))),
            entryType: entryType,
            entryDate: entryDate
        )

        let sessionId = sessionId
        let entryRef = entryRef
        let entryType = entryType
        let startedAt = startedAt
        Task {
            guard let userId = await SupabaseAuth.shared.currentUserId() else { return }
            do {
                try await VoiceTranscriptStore.saveCloud(
                    client: SupabaseAuth.shared.supabase, userId: userId,
                    sessionId: sessionId, entryRef: entryRef, entryType: entryType,
                    lines: lines, events: events, configuration: config,
                    startedAt: startedAt, endedAt: endedAt
                )
                vclog("persist cloud row inserted")
            } catch {
                vclog("persist cloud FAILED: \(error)")
            }
        }
        return completed
    }

    private func startLevelPolling(_ room: Room) {
        levelTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.micLevel = room.localParticipant.audioLevel
                self.durationSeconds = max(0, Int(Date().timeIntervalSince(self.startedAt)))
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    private func receiveTelemetry(_ data: Data) async {
        do {
            let event = try JSONDecoder().decode(VoiceTelemetryEvent.self, from: data)
            guard event.sessionId == sessionId else { return }
            telemetryEvents.append(event)
            if telemetryEvents.count > 400 { telemetryEvents.removeFirst(telemetryEvents.count - 400) }
            if let message = event.fatalErrorMessage {
                vclog("backend FAILED: \(message)")
                await failActiveCall(message)
            } else if event.eventType == "lifecycle", event.stage == "session",
               event.detail["status"]?.stringValue == "ready" {
                markCoachJoined()
            }
        } catch {
            vclog("telemetry decode failed: \(error)")
        }
    }

    private func failActiveCall(_ message: String) async {
        guard phase != .ended, !isEnding else { return }
        coachJoinTimeoutTask?.cancel()
        coachJoinTimeoutTask = nil
        levelTask?.cancel()
        levelTask = nil
        micLevel = 0

        let failedRoom = room
        room = nil
        phase = .error(message)
        await failedRoom?.disconnect()
    }

    private func receiveArtifact(_ data: Data) {
        do {
            let artifact = try JSONDecoder().decode(VoiceCanvasArtifact.self, from: data)
            guard artifact.sessionId == sessionId,
                  !canvasArtifacts.contains(where: { $0.id == artifact.id }) else { return }
            canvasArtifacts.append(artifact)
            if canvasArtifacts.count > 50 {
                canvasArtifacts.removeFirst(canvasArtifacts.count - 50)
            }
        } catch {
            vclog("artifact decode failed: \(error)")
        }
    }

    private func appendTranscript(speaker: String, text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        let key = "\(speaker)|\(clean)"
        let now = Date()
        recentTranscriptKeys = recentTranscriptKeys.filter { now.timeIntervalSince($0.value) < 3 }
        guard recentTranscriptKeys[key] == nil else { return }
        recentTranscriptKeys[key] = now
        transcript.append(.init(speaker: speaker, text: clean))
    }

    private func ensureMicPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    private func tokenErrorMessage(_ error: VoiceTokenError) -> String {
        switch error {
        case .notAuthenticated: return "Please sign in to use the coach"
        case .badResponse(let status, let message):
            return message.map { "Couldn't start the coach (\(status)): \($0)" }
                ?? "Couldn't start the coach (\(status))"
        case .badURL: return "Server returned a bad address"
        }
    }

    static func phase(afterAgentState state: String, current: Phase) -> Phase {
        switch current {
        case .ended, .error:
            return current
        default:
            break
        }
        switch state {
        case "speaking": return .speaking
        case "listening", "thinking": return .listening
        default: return current
        }
    }

    static func shouldFailAfterCoachDisconnect(current: Phase) -> Bool {
        switch current {
        case .connecting, .listening, .speaking:
            return true
        case .idle, .authenticating, .ended, .error:
            return false
        }
    }
}

extension VoiceCoachManager: RoomDelegate {
    nonisolated func room(_ room: Room, participantDidConnect participant: RemoteParticipant) {
        guard Self.isCoach(participant) else { return }
        vclog("coach participant joined — awaiting backend ready event")
    }

    nonisolated func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) {
        guard Self.isCoach(participant) else { return }
        Task { @MainActor in
            if Self.shouldFailAfterCoachDisconnect(current: self.phase) {
                await self.failActiveCall("The coach disconnected. Try again.")
            }
        }
    }

    nonisolated func room(_ room: Room, participant: RemoteParticipant,
                          didSubscribeTrack publication: RemoteTrackPublication) {
        vclog("subscribed to \(publication.kind) track")
    }

    nonisolated func room(_ room: Room, participant: Participant,
                          didUpdateAttributes attributes: [String: String]) {
        guard let state = attributes["lk.agent.state"] else { return }
        Task { @MainActor in
            // A real agent state is emitted only after AgentSession startup,
            // so it is a readiness signal; participant presence alone is not.
            self.markCoachJoined()
            self.phase = Self.phase(afterAgentState: state, current: self.phase)
        }
    }

    nonisolated func room(_ room: Room, participant: Participant,
                          trackPublication: TrackPublication,
                          didReceiveTranscriptionSegments segments: [TranscriptionSegment]) {
        let speaker = participant is RemoteParticipant ? "Coach" : "You"
        Task { @MainActor in
            for segment in segments where segment.isFinal {
                self.appendTranscript(speaker: speaker, text: segment.text)
            }
        }
    }

    nonisolated func room(_ room: Room, participant: RemoteParticipant?, didReceiveData data: Data,
                          forTopic topic: String, encryptionType: EncryptionType) {
        if topic == "freewrite.voice.telemetry" {
            Task { @MainActor in await self.receiveTelemetry(data) }
        } else if topic == "freewrite.voice.artifact" {
            Task { @MainActor in self.receiveArtifact(data) }
        }
    }
}
