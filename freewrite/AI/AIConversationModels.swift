import Foundation

enum AIConversationKind: String, Codable {
    case text
    case voice
}

enum AIChatRole: String, Codable {
    case user
    case assistant
}

enum AIChatToolStatus: String, Codable {
    case running
    case success
    case error
}

struct AIChatCitation: Codable, Identifiable, Equatable {
    let id: UUID
    let title: String
    let url: String

    init(id: UUID = UUID(), title: String, url: String) {
        self.id = id
        self.title = title
        self.url = url
    }
}

struct AIChatImage: Codable, Identifiable, Equatable {
    let id: UUID
    let title: String
    let imageURL: String
    let thumbnailURL: String
    let sourceURL: String

    init(id: UUID = UUID(), title: String, imageURL: String,
         thumbnailURL: String, sourceURL: String) {
        self.id = id
        self.title = title
        self.imageURL = imageURL
        self.thumbnailURL = thumbnailURL
        self.sourceURL = sourceURL
    }
}

struct AIChatToolActivity: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    var status: AIChatToolStatus
    var summary: String
    var input: [String: VoiceJSONValue]
    var result: [String: VoiceJSONValue]?
    var durationMs: Int?
}

struct AIChatUsage: Codable, Equatable {
    let model: String
    let inputTokens: Int
    let cachedInputTokens: Int?
    let cacheWriteInputTokens: Int?
    let outputTokens: Int
    let reasoningTokens: Int?
    let totalTokens: Int
    let inputCostUSD: Double?
    let cachedInputCostUSD: Double?
    let cacheWriteCostUSD: Double?
    let outputCostUSD: Double?
    let toolCostUSD: Double?
    let estimatedCostUSD: Double
    let latencyMs: Int

    init(model: String, inputTokens: Int, cachedInputTokens: Int = 0,
         cacheWriteInputTokens: Int = 0, outputTokens: Int,
         reasoningTokens: Int = 0, totalTokens: Int,
         inputCostUSD: Double = 0, cachedInputCostUSD: Double = 0,
         cacheWriteCostUSD: Double = 0, outputCostUSD: Double = 0,
         toolCostUSD: Double = 0, estimatedCostUSD: Double, latencyMs: Int) {
        self.model = model
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.cacheWriteInputTokens = cacheWriteInputTokens
        self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens
        self.totalTokens = totalTokens
        self.inputCostUSD = inputCostUSD
        self.cachedInputCostUSD = cachedInputCostUSD
        self.cacheWriteCostUSD = cacheWriteCostUSD
        self.outputCostUSD = outputCostUSD
        self.toolCostUSD = toolCostUSD
        self.estimatedCostUSD = estimatedCostUSD
        self.latencyMs = latencyMs
    }
}

struct AIChatMessage: Codable, Identifiable, Equatable {
    let id: UUID
    let role: AIChatRole
    var content: String
    let createdAt: Date
    var citations: [AIChatCitation]
    var images: [AIChatImage]
    var tools: [AIChatToolActivity]
    var usage: AIChatUsage?
    var voiceCall: AIVoiceCallSummary?

    init(id: UUID = UUID(), role: AIChatRole, content: String,
         createdAt: Date = Date(), citations: [AIChatCitation] = [],
         images: [AIChatImage] = [], tools: [AIChatToolActivity] = [],
         usage: AIChatUsage? = nil, voiceCall: AIVoiceCallSummary? = nil) {
        self.id = id
        self.role = role
        self.content = content
        self.createdAt = createdAt
        self.citations = citations
        self.images = images
        self.tools = tools
        self.usage = usage
        self.voiceCall = voiceCall
    }
}

struct AIVoiceCallSummary: Codable, Equatable {
    let sessionId: String
    let entryId: String?
    let startedAt: Date
    let endedAt: Date
    let durationSeconds: Int
}

struct AIReflectionQuestion: Codable, Identifiable, Equatable {
    let id: UUID
    let text: String

    init(id: UUID = UUID(), text: String) {
        self.id = id
        self.text = text
    }
}

struct AIConversation: Codable, Identifiable, Equatable {
    let id: UUID
    let kind: AIConversationKind
    var entryId: String?
    var entryType: String
    var entryDate: String
    var title: String
    let createdAt: Date
    var updatedAt: Date
    var messages: [AIChatMessage]
    var reflectionQuestions: [AIReflectionQuestion]?
    var questionGenerationUsage: AIChatUsage?
    var reflectionAnchorMessageID: UUID?

    init(id: UUID = UUID(), entryId: String?, entryType: String,
         entryDate: String, title: String = "New conversation",
         createdAt: Date = Date(), updatedAt: Date = Date(),
         messages: [AIChatMessage] = [],
         reflectionQuestions: [AIReflectionQuestion]? = nil,
         questionGenerationUsage: AIChatUsage? = nil,
         reflectionAnchorMessageID: UUID? = nil) {
        self.id = id
        self.kind = .text
        self.entryId = entryId
        self.entryType = entryType
        self.entryDate = entryDate
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messages = messages
        self.reflectionQuestions = reflectionQuestions
        self.questionGenerationUsage = questionGenerationUsage
        self.reflectionAnchorMessageID = reflectionAnchorMessageID
    }
}

struct VoiceConversationRecord: Identifiable, Equatable {
    let id: String
    let entryRef: String
    let startedAt: Date
    let endedAt: Date
    let durationSec: Int
    let architecture: String
    let provider: String
    let model: String
    let estimatedCostUSD: Double
    let transcript: [VoiceCoachManager.TranscriptLine]
    let strategyBriefs: [VoiceTelemetryEvent]
}

struct AIConversationHistoryItem: Identifiable, Equatable {
    let id: String
    let kind: AIConversationKind
    let title: String
    let subtitle: String
    let date: Date
    let entryRef: String?
    let textConversationId: UUID?
    let voiceConversationId: String?
}

struct AIChatContext: Equatable {
    let entryId: String?
    let entryType: String
    let entryDate: String
    let entryText: String
    let recentWriting: String

    var label: String {
        let noun = entryType == "video" ? "Video transcript" : "Current note"
        return entryDate.isEmpty ? noun : "\(noun) · \(entryDate)"
    }
}

enum AIChatModel: String, CaseIterable, Identifiable {
    case terra = "gpt-5.6-terra"
    case sol = "gpt-5.6-sol"
    case sonnet = "claude-sonnet-5"
    case opus = "claude-opus-4-8"
    case fable = "claude-fable-5"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .terra: return "GPT-5.6 Terra"
        case .sol: return "GPT-5.6 Sol"
        case .sonnet: return "Claude Sonnet 5"
        case .opus: return "Claude Opus 4.8"
        case .fable: return "Claude Fable 5"
        }
    }
    var detail: String {
        switch self {
        case .terra: return "Fast, intelligent, and cost-efficient"
        case .sol: return "Frontier intelligence with strong visual generation"
        case .sonnet: return "Fast Claude with a strong intelligence/latency balance"
        case .opus: return "Deeper Claude for complex, deliberate work"
        case .fable: return "Anthropic's most capable model; highest latency and cost"
        }
    }
    var supportedEfforts: [AIChatReasoningEffort] {
        // Terra's minimal mode cannot use OpenAI hosted web search. Chat keeps
        // the complete toolset available and exposes only truthful combinations.
        self == .terra ? [.low, .medium] : [.low, .medium, .high, .xhigh, .max]
    }
}

enum AIChatReasoningEffort: String, CaseIterable, Identifiable {
    case minimal, low, medium, high, xhigh, max
    var id: String { rawValue }
    var title: String { rawValue == "xhigh" ? "Extra high" : rawValue.capitalized }
}

struct AIChatToolDefinition: Identifiable, Equatable {
    let id: String
    let title: String
    let description: String
    let systemImage: String

    static let available: [AIChatToolDefinition] = [
        .init(id: "web_search", title: "Web search",
              description: "Searches current public web results and returns citations.",
              systemImage: "globe"),
        .init(id: "image_search", title: "Image search",
              description: "Finds public reference images that can be embedded in an artifact.",
              systemImage: "photo.on.rectangle.angled"),
        .init(id: "read_url", title: "Read webpage",
              description: "Reads the useful text from a specific public URL.",
              systemImage: "doc.text.magnifyingglass"),
        .init(id: "search_current_note", title: "Search note",
              description: "Finds exact passages inside the note in front of you.",
              systemImage: "text.magnifyingglass"),
    ]
}
