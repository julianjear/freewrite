import Foundation

enum AIChatRequestCompactor {
    // Leave headroom below the Worker's 96 KB JSON limit for field names and
    // JSON escaping; the independent budgets must not add up to the wire cap.
    static let noteByteLimit = 24_000
    static let recentWritingByteLimit = 16_000
    static let historyByteLimit = 32_000
    static let messageByteLimit = 12_000

    static func note(_ value: String) -> String {
        utf8Suffix(value, limit: noteByteLimit)
    }

    static func recentWriting(_ value: String) -> String {
        utf8Suffix(value, limit: recentWritingByteLimit)
    }

    static func history(_ messages: [AIChatMessage]) -> [(role: String, content: String)] {
        var remaining = historyByteLimit
        var newestFirst: [(String, String)] = []
        for message in messages.reversed() where remaining > 0 {
            let source = message.role == .assistant
                ? visibleText(fromArtifact: message.content)
                : message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !source.isEmpty else { continue }
            let content = utf8Prefix(source, limit: min(messageByteLimit, remaining))
            guard !content.isEmpty else { continue }
            newestFirst.append((message.role.rawValue, content))
            remaining -= content.utf8.count
        }
        return Array(newestFirst.reversed())
    }

    static func visibleText(fromArtifact value: String) -> String {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("```html") {
            text.removeFirst(7)
        } else if text.hasPrefix("```") {
            text.removeFirst(3)
        }
        if text.hasSuffix("```") { text.removeLast(3) }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = text.lowercased()
        guard trimmed.hasPrefix("<!doctype html") || trimmed.hasPrefix("<html")
                || trimmed.hasPrefix("<main") || trimmed.hasPrefix("<article") else {
            return text
        }
        // The closing tag is optional so this also stays useful while an HTML
        // response is still streaming its style or script block.
        for pattern in ["(?is)<script\\b[^>]*>.*?(?:</script\\s*>|$)",
                        "(?is)<style\\b[^>]*>.*?(?:</style\\s*>|$)"] {
            text = text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        text = text.replacingOccurrences(
            of: "(?i)</?(?:p|div|main|article|section|h[1-6]|li|br|tr|blockquote)\\b[^>]*>",
            with: "\n", options: .regularExpression
        )
        text = text.replacingOccurrences(of: "(?s)<[^>]+>", with: " ", options: .regularExpression)
        for (entity, replacement) in [
            ("&nbsp;", " "), ("&quot;", "\""), ("&#39;", "'"),
            ("&lt;", "<"), ("&gt;", ">"), ("&amp;", "&"),
        ] {
            text = text.replacingOccurrences(of: entity, with: replacement,
                                             options: .caseInsensitive)
        }
        text = text.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func utf8Prefix(_ value: String, limit: Int) -> String {
        guard value.utf8.count > limit else { return value }
        return String(decoding: value.utf8.prefix(limit), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func utf8Suffix(_ value: String, limit: Int) -> String {
        guard value.utf8.count > limit else { return value }
        var bytes = Array(value.utf8.suffix(limit))
        while let first = bytes.first, first & 0b1100_0000 == 0b1000_0000 {
            bytes.removeFirst()
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

struct AIChatStreamEvent: Decodable {
    let type: String
    let delta: String?
    let id: String?
    let name: String?
    let status: String?
    let summary: String?
    let input: [String: VoiceJSONValue]?
    let result: [String: VoiceJSONValue]?
    let durationMs: Int?
    let url: String?
    let title: String?
    let model: String?
    let inputTokens: Int?
    let cachedInputTokens: Int?
    let cacheWriteInputTokens: Int?
    let outputTokens: Int?
    let reasoningTokens: Int?
    let totalTokens: Int?
    let inputCostUSD: Double?
    let cachedInputCostUSD: Double?
    let cacheWriteCostUSD: Double?
    let outputCostUSD: Double?
    let toolCostUSD: Double?
    let estimatedCostUSD: Double?
    let latencyMs: Int?
    let responseId: String?
    let message: String?
    let retryable: Bool?
}

enum AIChatClientError: LocalizedError {
    case notAuthenticated
    case badResponse(Int, String?)
    case malformedStream
    case malformedQuestions

    var errorDescription: String? {
        switch self {
        case .notAuthenticated: return "Please sign in to chat with Freewrite AI."
        case .badResponse(let status, let message):
            return message ?? "Chat request failed (\(status))."
        case .malformedStream: return "The chat stream ended unexpectedly."
        case .malformedQuestions: return "The reflection questions response was not valid."
        }
    }
}

struct AIChatClient {
    private struct RequestMessage: Encodable {
        let role: String
        let content: String
    }

    private struct Body: Encodable {
        let conversationId: String
        let entryId: String?
        let entryType: String
        let entryDate: String
        let entryText: String
        let recentWriting: String
        let messages: [RequestMessage]
        let model: String
        let reasoningEffort: String
        let mode: String
    }

    func stream(conversation: AIConversation, context: AIChatContext,
                model: AIChatModel, effort: AIChatReasoningEffort,
                mode: String = "reply", accessToken: String?) -> AsyncThrowingStream<AIChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            // Request encoding includes stripping prior HTML artifacts. Keep
            // that work, plus SSE decoding, off the MainActor so a follow-up
            // cannot stall the SwiftUI event loop.
            let task = Task.detached(priority: .userInitiated) {
                do {
                    let transportStartedAt = Date.timeIntervalSinceReferenceDate
                    guard let accessToken else { throw AIChatClientError.notAuthenticated }
                    let url = VoiceTokenClient.workerBaseURL.appendingPathComponent("chat/stream")
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    // Fable/Opus plus bounded tool rounds can legitimately take
                    // longer than a fast Terra response while still streaming.
                    request.timeoutInterval = 240
                    let compactMessages = mode == "opening"
                        ? [] : AIChatRequestCompactor.history(conversation.messages)
                    request.httpBody = try JSONEncoder().encode(Body(
                        conversationId: conversation.id.uuidString,
                        entryId: context.entryId,
                        entryType: context.entryType,
                        entryDate: context.entryDate,
                        entryText: AIChatRequestCompactor.note(context.entryText),
                        recentWriting: AIChatRequestCompactor.recentWriting(context.recentWriting),
                        messages: compactMessages.map { RequestMessage(role: $0.role, content: $0.content) },
                        model: model.rawValue,
                        reasoningEffort: effort.rawValue,
                        mode: mode
                    ))
                    print("[AIChatTransport] request ready conversation=\(conversation.id.uuidString) bytes=\(request.httpBody?.count ?? 0)")

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                    let headersMs = Int((Date.timeIntervalSinceReferenceDate - transportStartedAt) * 1_000)
                    print("[AIChatTransport] response headers conversation=\(conversation.id.uuidString) status=\(status) latencyMs=\(headersMs)")
                    guard status == 200 else {
                        var lines: [String] = []
                        for try await line in bytes.lines {
                            lines.append(line)
                            if lines.joined().count > 2_000 { break }
                        }
                        struct ErrorBody: Decodable { let error: String }
                        let data = Data(lines.joined(separator: "\n").utf8)
                        let detail = try? JSONDecoder().decode(ErrorBody.self, from: data).error
                        throw AIChatClientError.badResponse(status, detail)
                    }

                    var sawFinish = false
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data:") else { continue }
                        let json = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        guard !json.isEmpty, let data = json.data(using: .utf8) else { continue }
                        let event = try JSONDecoder().decode(AIChatStreamEvent.self, from: data)
                        if event.type == "finish" { sawFinish = true }
                        continuation.yield(event)
                        if event.type == "error" {
                            throw AIChatClientError.badResponse(
                                500,
                                event.message ?? "The chat turn failed."
                            )
                        }
                    }
                    if !sawFinish { throw AIChatClientError.malformedStream }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func reflectionQuestions(conversation: AIConversation, context: AIChatContext,
                             model: AIChatModel, effort: AIChatReasoningEffort,
                             accessToken: String?) async throws -> (questions: [String], usage: AIChatUsage?) {
        var text = ""
        var usage: AIChatUsage?
        let events = stream(
            conversation: conversation, context: context,
            model: model, effort: effort, mode: "questions",
            accessToken: accessToken
        )
        for try await event in events {
            switch event.type {
            case "text-delta":
                text += event.delta ?? ""
            case "text-reset":
                text = ""
            case "usage":
                usage = AIChatUsage(
                    model: event.model ?? model.rawValue,
                    inputTokens: event.inputTokens ?? 0,
                    cachedInputTokens: event.cachedInputTokens ?? 0,
                    cacheWriteInputTokens: event.cacheWriteInputTokens ?? 0,
                    outputTokens: event.outputTokens ?? 0,
                    reasoningTokens: event.reasoningTokens ?? 0,
                    totalTokens: event.totalTokens ?? 0,
                    inputCostUSD: event.inputCostUSD ?? 0,
                    cachedInputCostUSD: event.cachedInputCostUSD ?? 0,
                    cacheWriteCostUSD: event.cacheWriteCostUSD ?? 0,
                    outputCostUSD: event.outputCostUSD ?? 0,
                    toolCostUSD: event.toolCostUSD ?? 0,
                    estimatedCostUSD: event.estimatedCostUSD ?? 0,
                    latencyMs: event.latencyMs ?? 0
                )
            default:
                break
            }
        }
        let cleaned = text
            .replacingOccurrences(of: "```json", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        struct Envelope: Decodable { let questions: [String] }
        guard let data = cleaned.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(Envelope.self, from: data) else {
            throw AIChatClientError.malformedQuestions
        }
        let questions = decoded.questions
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard questions.count == 6 else { throw AIChatClientError.malformedQuestions }
        return (questions, usage)
    }
}
