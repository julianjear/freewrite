import Foundation
import Supabase

struct VoiceTranscriptStore {
    private struct LocalMeta: Codable {
        let sessionId: String
        let entryRef: String
        let startedAt: String
        let endedAt: String
        let durationSec: Int
        let architecture: String
        let provider: String
        let model: String
        let estimatedCostUSD: Double
        let configuration: VoiceSessionConfiguration
    }

    static func saveLocal(rootDirectory: URL, entryBase: String, sessionId: String,
                          lines: [VoiceCoachManager.TranscriptLine],
                          events: [VoiceTelemetryEvent],
                          configuration: VoiceSessionConfiguration,
                          startedAt: Date, endedAt: Date) {
        let safeEntry = pathComponent(entryBase)
        let safeSession = pathComponent(sessionId)
        let directory = rootDirectory
            .appendingPathComponent("VoiceSessions/\(safeEntry)/\(safeSession)")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let transcript = lines.map { "**\($0.speaker):** \($0.text)" }.joined(separator: "\n\n")
            try transcript.write(to: directory.appendingPathComponent("transcript.md"),
                                 atomically: true, encoding: .utf8)

            let profile = configuration.profile
            let meta = LocalMeta(
                sessionId: sessionId, entryRef: entryBase,
                startedAt: ISO8601DateFormatter().string(from: startedAt),
                endedAt: ISO8601DateFormatter().string(from: endedAt),
                durationSec: max(0, Int(endedAt.timeIntervalSince(startedAt))),
                architecture: profile.architecture.rawValue,
                provider: profile.provider,
                model: profile.model,
                estimatedCostUSD: events.totalVoiceEstimatedCostUSD,
                configuration: configuration
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(meta).write(to: directory.appendingPathComponent("meta.json"), options: .atomic)
            try encoder.encode(events).write(to: directory.appendingPathComponent("events.json"), options: .atomic)
            let analyses = events.filter { $0.eventType == "supervisor" }
            try encoder.encode(analyses).write(to: directory.appendingPathComponent("analyses.json"), options: .atomic)
        } catch {
            vclog("local session persistence FAILED: \(error)")
        }
    }

    static func saveCloud(client: SupabaseClient, userId: String, sessionId: String,
                          entryRef: String?, entryType: String,
                          lines: [VoiceCoachManager.TranscriptLine],
                          events: [VoiceTelemetryEvent],
                          configuration: VoiceSessionConfiguration,
                          startedAt: Date, endedAt: Date) async throws {
        struct Row: Encodable {
            let session_id: String
            let user_id: String
            let entry_ref: String?
            let entry_type: String
            let started_at: String
            let ended_at: String
            let duration_sec: Int
            let transcript: String
            let architecture: String
            let provider: String
            let model: String
            let voice_config: VoiceSessionConfiguration
            let telemetry_events: [VoiceTelemetryEvent]
            let strategy_briefs: [VoiceTelemetryEvent]
            let estimated_cost_usd: Double
        }

        let transcript = lines.map { "\($0.speaker): \($0.text)" }.joined(separator: "\n")
        let profile = configuration.profile
        let row = Row(
            session_id: sessionId, user_id: userId, entry_ref: entryRef,
            entry_type: entryType,
            started_at: ISO8601DateFormatter().string(from: startedAt),
            ended_at: ISO8601DateFormatter().string(from: endedAt),
            duration_sec: max(0, Int(endedAt.timeIntervalSince(startedAt))),
            transcript: transcript,
            architecture: profile.architecture.rawValue,
            provider: profile.provider,
            model: profile.model,
            voice_config: configuration,
            telemetry_events: events,
            strategy_briefs: events.filter { $0.eventType == "supervisor" },
            estimated_cost_usd: events.totalVoiceEstimatedCostUSD
        )
        _ = try await client.from("voice_sessions").insert(row).execute()
    }

    private static func pathComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let safe = value.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "-" }
        return String(String(safe).prefix(160))
    }
}
