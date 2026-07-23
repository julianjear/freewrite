import Foundation

private actor AIConversationFileWriter {
    func save(_ conversation: AIConversation, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(conversation).write(to: url, options: .atomic)
    }
}

@MainActor
final class AIConversationStore: ObservableObject {
    @Published private(set) var textConversations: [AIConversation] = []
    @Published private(set) var voiceConversations: [VoiceConversationRecord] = []
    @Published private(set) var lastPersistenceError: String?

    private var rootDirectory = FileManager.default.urls(
        for: .documentDirectory, in: .userDomainMask
    )[0].appendingPathComponent("Freewrite", isDirectory: true)
    private let fileWriter = AIConversationFileWriter()

    private var conversationsDirectory: URL {
        rootDirectory.appendingPathComponent("Conversations", isDirectory: true)
    }

    func configure(rootDirectory: URL) {
        self.rootDirectory = rootDirectory.standardizedFileURL
        reload()
    }

    func reload() {
        textConversations = loadTextConversations()
        voiceConversations = loadVoiceConversations()
    }

    func latestConversation(entryId: String?) -> AIConversation? {
        textConversations
            .filter { $0.entryId == entryId }
            .max(by: { $0.updatedAt < $1.updatedAt })
    }

    func conversation(id: UUID) -> AIConversation? {
        textConversations.first(where: { $0.id == id })
    }

    func voiceConversation(id: String) -> VoiceConversationRecord? {
        voiceConversations.first(where: { $0.id == id })
    }

    func save(_ conversation: AIConversation) async {
        var value = conversation
        value.updatedAt = Date()
        if let index = textConversations.firstIndex(where: { $0.id == value.id }) {
            textConversations[index] = value
        } else {
            textConversations.append(value)
        }
        textConversations.sort { $0.updatedAt > $1.updatedAt }

        let url = conversationsDirectory.appendingPathComponent(
            "\(value.id.uuidString.lowercased()).json"
        )
        do {
            // Encoding and atomic disk I/O can become noticeable once a chat
            // contains multiple HTML artifacts. Keep it off MainActor so a
            // follow-up never blocks keyboard or scroll handling.
            try await fileWriter.save(value, to: url)
            lastPersistenceError = nil
        } catch {
            lastPersistenceError = "Conversation could not be saved: \(error.localizedDescription)"
            NSLog("[AIChat] local persistence failed: %@", error.localizedDescription)
        }
    }

    func deleteTextConversation(id: UUID) {
        textConversations.removeAll { $0.id == id }
        let url = conversationsDirectory.appendingPathComponent("\(id.uuidString.lowercased()).json")
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        } catch {
            lastPersistenceError = "Conversation could not be deleted: \(error.localizedDescription)"
        }
    }

    var historyItems: [AIConversationHistoryItem] {
        let chatItems = textConversations.map { conversation in
            AIConversationHistoryItem(
                id: "text-\(conversation.id.uuidString)", kind: .text,
                title: conversation.title,
                subtitle: conversation.entryDate.isEmpty ? "Text chat" : "Text chat · \(conversation.entryDate)",
                date: conversation.updatedAt, entryRef: conversation.entryId,
                textConversationId: conversation.id, voiceConversationId: nil
            )
        }
        let voiceItems = voiceConversations.map { conversation in
            AIConversationHistoryItem(
                id: "voice-\(conversation.id)", kind: .voice,
                title: conversation.transcript.first(where: { $0.speaker == "You" })?.text
                    ?? "Voice conversation",
                subtitle: "Voice · \(conversation.model)", date: conversation.startedAt,
                entryRef: conversation.entryRef, textConversationId: nil,
                voiceConversationId: conversation.id
            )
        }
        return (chatItems + voiceItems).sorted { $0.date > $1.date }
    }

    private func loadTextConversations() -> [AIConversation] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: conversationsDirectory, includingPropertiesForKeys: nil
        ) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return files
            .filter { $0.pathExtension.lowercased() == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                guard var conversation = try? decoder.decode(AIConversation.self, from: data) else {
                    return nil
                }
                // Older Anthropic dynamic-search responses exposed provider
                // implementation helpers as if they were Freewrite tools.
                // They are neither user actions nor executable app tools.
                let visibleTools: Set<String> = [
                    "web_search", "image_search", "read_url", "search_current_note",
                ]
                for messageIndex in conversation.messages.indices {
                    conversation.messages[messageIndex].tools.removeAll {
                        !visibleTools.contains($0.name)
                    }
                }
                // Repair placeholders written by a process that terminated
                // during streaming in an earlier app version.
                if let last = conversation.messages.last,
                   last.role == .assistant,
                   last.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   last.tools.isEmpty,
                   last.images.isEmpty,
                   last.citations.isEmpty,
                   last.voiceCall == nil {
                    conversation.messages.removeLast()
                }
                return conversation
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private struct VoiceMeta: Decodable {
        let sessionId: String
        let entryRef: String
        let startedAt: String
        let endedAt: String
        let durationSec: Int
        let architecture: String?
        let provider: String?
        let model: String?
        let estimatedCostUSD: Double?
    }

    private func loadVoiceConversations() -> [VoiceConversationRecord] {
        let defaultRoot = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        )[0].appendingPathComponent("Freewrite", isDirectory: true)
        let roots = [rootDirectory, defaultRoot].reduce(into: [URL]()) { result, value in
            if !result.contains(where: { $0.standardizedFileURL == value.standardizedFileURL }) {
                result.append(value)
            }
        }
        var records: [VoiceConversationRecord] = []
        var seen = Set<String>()
        let iso = ISO8601DateFormatter()
        for root in roots {
            let sessionsRoot = root.appendingPathComponent("VoiceSessions", isDirectory: true)
            guard let entryDirectories = try? FileManager.default.contentsOfDirectory(
                at: sessionsRoot, includingPropertiesForKeys: [.isDirectoryKey]
            ) else { continue }
            for entryDirectory in entryDirectories {
                guard let sessionDirectories = try? FileManager.default.contentsOfDirectory(
                    at: entryDirectory, includingPropertiesForKeys: [.isDirectoryKey]
                ) else { continue }
                for directory in sessionDirectories {
                    let metaURL = directory.appendingPathComponent("meta.json")
                    guard let data = try? Data(contentsOf: metaURL),
                          let meta = try? JSONDecoder().decode(VoiceMeta.self, from: data),
                          !seen.contains(meta.sessionId),
                          let startedAt = iso.date(from: meta.startedAt),
                          let endedAt = iso.date(from: meta.endedAt) else { continue }
                    seen.insert(meta.sessionId)
                    let transcript = loadVoiceTranscript(
                        directory.appendingPathComponent("transcript.md")
                    )
                    let analysisURL = directory.appendingPathComponent("analyses.json")
                    let briefs = (try? Data(contentsOf: analysisURL))
                        .flatMap { try? JSONDecoder().decode([VoiceTelemetryEvent].self, from: $0) } ?? []
                    records.append(VoiceConversationRecord(
                        id: meta.sessionId, entryRef: meta.entryRef,
                        startedAt: startedAt, endedAt: endedAt,
                        durationSec: meta.durationSec, architecture: meta.architecture ?? "legacy",
                        provider: meta.provider ?? "unknown", model: meta.model ?? "Legacy voice coach",
                        estimatedCostUSD: meta.estimatedCostUSD ?? 0,
                        transcript: transcript, strategyBriefs: briefs
                    ))
                }
            }
        }
        return records.sorted { $0.startedAt > $1.startedAt }
    }

    private func loadVoiceTranscript(_ url: URL) -> [VoiceCoachManager.TranscriptLine] {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return raw.components(separatedBy: "\n\n").compactMap { block in
            let text = block.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.hasPrefix("**"), let marker = text.range(of: ":**") else { return nil }
            let speakerStart = text.index(text.startIndex, offsetBy: 2)
            let speaker = String(text[speakerStart..<marker.lowerBound])
            let body = String(text[marker.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !speaker.isEmpty, !body.isEmpty else { return nil }
            return VoiceCoachManager.TranscriptLine(speaker: speaker, text: body)
        }
    }
}
