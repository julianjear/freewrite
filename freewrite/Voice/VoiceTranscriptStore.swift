import Foundation
import Supabase

struct VoiceTranscriptStore {
    /// Local: ~/Documents/Freewrite/VoiceSessions/<entryBase>/<sessionId>/transcript.md (+ meta.json)
    static func saveLocal(entryBase: String, sessionId: String,
                          lines: [VoiceCoachManager.TranscriptLine],
                          startedAt: Date, endedAt: Date) {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Freewrite/VoiceSessions/\(entryBase)/\(sessionId)")
        try? FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        let body = lines.map { "**\($0.speaker):** \($0.text)" }.joined(separator: "\n\n")
        try? body.write(to: docs.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
        let meta: [String: Any] = [
            "sessionId": sessionId, "entryRef": entryBase,
            "startedAt": ISO8601DateFormatter().string(from: startedAt),
            "endedAt": ISO8601DateFormatter().string(from: endedAt),
            "durationSec": Int(endedAt.timeIntervalSince(startedAt)),
        ]
        if let data = try? JSONSerialization.data(withJSONObject: meta, options: .prettyPrinted) {
            try? data.write(to: docs.appendingPathComponent("meta.json"))
        }
    }

    /// Cloud: insert into voice_sessions (RLS scopes to the user). Best-effort.
    static func saveCloud(client: SupabaseClient, userId: String, sessionId: String,
                          entryRef: String?, entryType: String,
                          lines: [VoiceCoachManager.TranscriptLine],
                          startedAt: Date, endedAt: Date, model: String) async {
        let transcript = lines.map { "\($0.speaker): \($0.text)" }.joined(separator: "\n")
        struct Row: Encodable {
            let id: String; let user_id: String; let entry_ref: String?
            let entry_type: String; let started_at: String; let ended_at: String
            let duration_sec: Int; let transcript: String; let model: String
        }
        let row = Row(id: sessionId, user_id: userId, entry_ref: entryRef,
                      entry_type: entryType,
                      started_at: ISO8601DateFormatter().string(from: startedAt),
                      ended_at: ISO8601DateFormatter().string(from: endedAt),
                      duration_sec: Int(endedAt.timeIntervalSince(startedAt)),
                      transcript: transcript, model: model)
        _ = try? await client.from("voice_sessions").insert(row).execute()
    }
}
