import Foundation

struct VoiceContext: Codable {
    enum EntryKind: String, Codable { case text, video }

    let entryType: EntryKind
    let entryDate: String
    let entryText: String
    let hasTranscript: Bool
    let chatHistory: String
    let startingQuestion: String?
    let truncated: Bool
    let modality: String   // always "voice"

    static let maxEntryBytes = 6144
    static let maxChatBytes = 5120
    static let maxQuestionBytes = 1200

    static func make(entryType: EntryKind, entryDate: String,
                     entryText: String, hasTranscript: Bool,
                     chatHistory: String = "", startingQuestion: String? = nil) -> VoiceContext {
        let (capped, truncated) = capTail(entryText, maxBytes: maxEntryBytes)
        let (cappedChat, _) = capTail(chatHistory, maxBytes: maxChatBytes)
        let cappedQuestion = startingQuestion.map {
            capTail($0, maxBytes: maxQuestionBytes).0
        }
        return VoiceContext(entryType: entryType, entryDate: entryDate,
                            entryText: capped, hasTranscript: hasTranscript,
                            chatHistory: cappedChat,
                            startingQuestion: cappedQuestion,
                            truncated: truncated, modality: "voice")
    }

    /// Keep the most-recent `maxBytes` UTF-8 bytes, repaired to a char boundary.
    static func capTail(_ text: String, maxBytes: Int) -> (String, Bool) {
        let bytes = Array(text.utf8)
        if bytes.count <= maxBytes { return (text, false) }
        var start = bytes.count - maxBytes
        while start < bytes.count && (bytes[start] & 0xC0) == 0x80 { start += 1 }
        let slice = Array(bytes[start...])
        return (String(decoding: slice, as: UTF8.self), true)
    }
}
