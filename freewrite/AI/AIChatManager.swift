import Foundation

@MainActor
final class AIChatManager: ObservableObject {
    @Published var currentConversation: AIConversation?
    @Published var selectedVoiceConversation: VoiceConversationRecord?
    @Published var draft = ""
    @Published private(set) var isStreaming = false
    @Published private(set) var isGeneratingQuestions = false
    @Published private(set) var requestedScrollMessageID: UUID?
    @Published var errorMessage: String?
    @Published var questionErrorMessage: String?
    @Published var showingHistory = false
    @Published var showsObservability: Bool {
        didSet { UserDefaults.standard.set(showsObservability, forKey: "aiChatShowsObservability") }
    }
    @Published var selectedModel: AIChatModel {
        didSet {
            UserDefaults.standard.set(selectedModel.rawValue, forKey: "aiChatModel")
            if !selectedModel.supportedEfforts.contains(reasoningEffort) {
                reasoningEffort = .low
            }
        }
    }
    @Published var reasoningEffort: AIChatReasoningEffort {
        didSet { UserDefaults.standard.set(reasoningEffort.rawValue, forKey: "aiChatReasoningEffort") }
    }

    private var streamTask: Task<Void, Never>?

    init() {
        let defaults = UserDefaults.standard
        let savedModel = AIChatModel(
            rawValue: defaults.string(forKey: "aiChatModel") ?? ""
        ) ?? .terra
        let savedEffort = AIChatReasoningEffort(
            rawValue: defaults.string(forKey: "aiChatReasoningEffort") ?? ""
        ) ?? .low
        selectedModel = savedModel
        reasoningEffort = savedModel.supportedEfforts.contains(savedEffort) ? savedEffort : .low
        showsObservability = defaults.object(forKey: "aiChatShowsObservability") as? Bool ?? true
    }

    func prepare(context: AIChatContext, store: AIConversationStore) {
        guard !isStreaming, !isGeneratingQuestions else { return }
        if currentConversation?.entryId == context.entryId, selectedVoiceConversation == nil { return }
        selectedVoiceConversation = nil
        showingHistory = false
        errorMessage = nil
        questionErrorMessage = nil
        if let existing = store.latestConversation(entryId: context.entryId) {
            currentConversation = existing
        } else {
            startOpeningConversation(context: context, store: store)
        }
    }

    func newConversation(context: AIChatContext, store: AIConversationStore) {
        guard !isStreaming, !isGeneratingQuestions else { return }
        selectedVoiceConversation = nil
        showingHistory = false
        errorMessage = nil
        questionErrorMessage = nil
        startOpeningConversation(context: context, store: store)
    }

    func selectText(id: UUID, store: AIConversationStore) {
        guard !isStreaming, !isGeneratingQuestions else { return }
        currentConversation = store.conversation(id: id)
        selectedVoiceConversation = nil
        showingHistory = false
        errorMessage = nil
        questionErrorMessage = nil
    }

    func selectVoice(id: String, store: AIConversationStore) {
        guard !isStreaming, !isGeneratingQuestions else { return }
        selectedVoiceConversation = store.voiceConversation(id: id)
        currentConversation = nil
        showingHistory = false
        errorMessage = nil
        questionErrorMessage = nil
    }

    func submit(context: AIChatContext, store: AIConversationStore) {
        let userText = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !userText.isEmpty, !isStreaming, !isGeneratingQuestions else { return }
        draft = ""
        streamTask = Task { [weak self] in
            await self?.send(userText: userText, mode: "reply", context: context, store: store)
        }
    }

    func cancel(store: AIConversationStore) {
        streamTask?.cancel()
        streamTask = nil
        isStreaming = false
        if var conversation = currentConversation,
           let last = conversation.messages.last,
           last.role == .assistant,
           last.content.isEmpty,
           last.tools.isEmpty {
            conversation.messages.removeLast()
            currentConversation = conversation
            Task { await store.save(conversation) }
        }
    }

    private func startOpeningConversation(context: AIChatContext, store: AIConversationStore) {
        let conversation = AIConversation(
            entryId: context.entryId,
            entryType: context.entryType,
            entryDate: context.entryDate,
            title: context.entryDate.isEmpty ? "Opening reflection" : "Reflection · \(context.entryDate)"
        )
        currentConversation = conversation
        streamTask = Task { [weak self] in
            await self?.send(userText: nil, mode: "opening", context: context, store: store)
        }
    }

    private func send(userText: String?, mode: String, context: AIChatContext,
                      store: AIConversationStore) async {
        let startedAt = Date.timeIntervalSinceReferenceDate
        var conversation = currentConversation
        if conversation == nil || conversation?.entryId != context.entryId {
            conversation = AIConversation(
                entryId: context.entryId, entryType: context.entryType,
                entryDate: context.entryDate
            )
        }
        guard var conversation else { return }
        if let userText {
            let userMessage = AIChatMessage(role: .user, content: userText)
            conversation.messages.append(userMessage)
            requestedScrollMessageID = userMessage.id
            if conversation.messages.filter({ $0.role == .user }).count == 1 {
                conversation.title = Self.title(from: userText)
            }
        }
        // Show the user's turn immediately, but persist a copy without the
        // in-memory streaming placeholder. A terminated app should never
        // reopen to a blank answer.
        let durableConversation = conversation
        conversation.messages.append(AIChatMessage(role: .assistant, content: ""))
        currentConversation = conversation
        isStreaming = true
        errorMessage = nil
        questionErrorMessage = nil
        print("[AIChat] start conversation=\(conversation.id.uuidString) mode=\(mode) model=\(selectedModel.rawValue) history=\(conversation.messages.count - 1) contextBytes=\(context.entryText.utf8.count)")
        let persistenceStartedAt = Date.timeIntervalSinceReferenceDate
        await store.save(durableConversation)
        let persistenceMs = Int((Date.timeIntervalSinceReferenceDate - persistenceStartedAt) * 1_000)
        print("[AIChat] checkpoint persisted conversation=\(conversation.id.uuidString) latencyMs=\(persistenceMs)")

        var shouldGenerateQuestions = false
        do {
            let auth = SupabaseAuth.shared
            let authStartedAt = Date.timeIntervalSinceReferenceDate
            var token = await auth.currentToken()
            if token == nil {
                try await auth.signInWithGoogle()
                token = await auth.currentToken()
            }
            let authMs = Int((Date.timeIntervalSinceReferenceDate - authStartedAt) * 1_000)
            print("[AIChat] auth ready conversation=\(conversation.id.uuidString) latencyMs=\(authMs)")
            let events = AIChatClient().stream(
                conversation: conversation, context: context,
                model: selectedModel, effort: reasoningEffort,
                mode: mode,
                accessToken: token
            )
            var pendingText = ""
            var lastPublishedAt = Date.timeIntervalSinceReferenceDate
            var eventCount = 0
            var loggedFirstToken = false
            for try await event in events {
                guard !Task.isCancelled else { break }
                eventCount += 1
                if event.type == "text-delta" {
                    if !loggedFirstToken, event.delta?.isEmpty == false {
                        loggedFirstToken = true
                        let latencyMs = Int((Date.timeIntervalSinceReferenceDate - startedAt) * 1_000)
                        print("[AIChat] first token conversation=\(conversation.id.uuidString) latencyMs=\(latencyMs)")
                    }
                    pendingText += event.delta ?? ""
                    let now = Date.timeIntervalSinceReferenceDate
                    if now - lastPublishedAt >= 0.12 {
                        appendText(pendingText, to: &conversation)
                        pendingText = ""
                        currentConversation = conversation
                        lastPublishedAt = now
                    }
                } else {
                    appendText(pendingText, to: &conversation)
                    pendingText = ""
                    apply(event, to: &conversation)
                    currentConversation = conversation
                    lastPublishedAt = Date.timeIntervalSinceReferenceDate
                }
            }
            appendText(pendingText, to: &conversation)
            finalizeToolActivities(in: &conversation)
            currentConversation = conversation
            if !Task.isCancelled {
                await store.save(conversation)
                shouldGenerateQuestions = mode == "opening"
                let elapsedMs = Int((Date.timeIntervalSinceReferenceDate - startedAt) * 1_000)
                let characters = conversation.messages.last?.content.count ?? 0
                print("[AIChat] finish conversation=\(conversation.id.uuidString) elapsedMs=\(elapsedMs) events=\(eventCount) chars=\(characters)")
            }
        } catch {
            if !Task.isCancelled {
                let elapsedMs = Int((Date.timeIntervalSinceReferenceDate - startedAt) * 1_000)
                print("[AIChat] failure conversation=\(conversation.id.uuidString) elapsedMs=\(elapsedMs) error=\(error.localizedDescription)")
                errorMessage = error.localizedDescription
                if let index = conversation.messages.indices.last,
                   conversation.messages[index].role == .assistant,
                   conversation.messages[index].content.isEmpty {
                    conversation.messages.remove(at: index)
                }
                currentConversation = conversation
                await store.save(conversation)
            }
        }
        isStreaming = false
        if shouldGenerateQuestions, !Task.isCancelled {
            await generateReflectionQuestions(
                for: conversation, context: context, store: store
            )
        }
        streamTask = nil
    }

    private func generateReflectionQuestions(for conversation: AIConversation,
                                             context: AIChatContext,
                                             store: AIConversationStore) async {
        let anchorID = conversation.messages.last(where: {
            $0.role == .assistant && $0.voiceCall == nil
        })?.id
        if var anchored = currentConversation, anchored.id == conversation.id {
            anchored.reflectionAnchorMessageID = anchorID
            currentConversation = anchored
        }
        isGeneratingQuestions = true
        questionErrorMessage = nil
        let startedAt = Date.timeIntervalSinceReferenceDate
        print("[AIChatQuestions] start conversation=\(conversation.id.uuidString) model=\(selectedModel.rawValue)")
        do {
            let result = try await AIChatClient().reflectionQuestions(
                conversation: conversation,
                context: context,
                model: selectedModel,
                effort: reasoningEffort,
                accessToken: await SupabaseAuth.shared.currentToken()
            )
            guard currentConversation?.id == conversation.id else {
                isGeneratingQuestions = false
                return
            }
            var updated = currentConversation ?? conversation
            updated.reflectionQuestions = result.questions.map { AIReflectionQuestion(text: $0) }
            updated.questionGenerationUsage = result.usage
            updated.reflectionAnchorMessageID = anchorID
            currentConversation = updated
            await store.save(updated)
            let elapsedMs = Int((Date.timeIntervalSinceReferenceDate - startedAt) * 1_000)
            print("[AIChatQuestions] finish conversation=\(conversation.id.uuidString) elapsedMs=\(elapsedMs) count=\(result.questions.count)")
        } catch {
            guard !Task.isCancelled else {
                isGeneratingQuestions = false
                return
            }
            questionErrorMessage = error.localizedDescription
            let elapsedMs = Int((Date.timeIntervalSinceReferenceDate - startedAt) * 1_000)
            print("[AIChatQuestions] failure conversation=\(conversation.id.uuidString) elapsedMs=\(elapsedMs) error=\(error.localizedDescription)")
        }
        isGeneratingQuestions = false
    }

    func recordVoiceCall(_ call: AIVoiceCallSummary, context: AIChatContext,
                         store: AIConversationStore) {
        let targetEntryID = call.entryId ?? context.entryId
        var conversation: AIConversation
        if let currentConversation, currentConversation.entryId == targetEntryID {
            conversation = currentConversation
        } else if let existing = store.latestConversation(entryId: targetEntryID) {
            conversation = existing
        } else {
            conversation = AIConversation(
                entryId: targetEntryID,
                entryType: context.entryType,
                entryDate: context.entryDate,
                title: context.entryDate.isEmpty
                    ? "Voice conversation" : "Voice conversation · \(context.entryDate)"
            )
        }
        guard !conversation.messages.contains(where: {
            $0.voiceCall?.sessionId == call.sessionId
        }) else { return }

        conversation.messages.append(AIChatMessage(
            role: .assistant,
            content: "",
            createdAt: call.endedAt,
            voiceCall: call
        ))
        currentConversation = conversation
        selectedVoiceConversation = nil
        showingHistory = false
        Task { await store.save(conversation) }
    }

    func chatHandoffContext() -> String {
        guard let conversation = currentConversation else { return "" }
        let turns = AIChatRequestCompactor.history(conversation.messages)
        guard !turns.isEmpty else { return "" }
        return turns.map { turn in
            let label = turn.role == "user" ? "Julian" : "Freewrite AI"
            return "\(label): \(turn.content)"
        }.joined(separator: "\n\n")
    }

    private func apply(_ event: AIChatStreamEvent, to conversation: inout AIConversation) {
        guard let index = conversation.messages.indices.last,
              conversation.messages[index].role == .assistant else { return }
        switch event.type {
        case "text-delta":
            conversation.messages[index].content += event.delta ?? ""
        case "text-reset":
            conversation.messages[index].content = ""
        case "citation":
            guard let url = event.url, !url.isEmpty,
                  !conversation.messages[index].citations.contains(where: { $0.url == url }) else { return }
            conversation.messages[index].citations.append(
                AIChatCitation(title: event.title?.isEmpty == false ? event.title! : url, url: url)
            )
        case "tool-start":
            guard let id = event.id, let name = event.name,
                  Self.visibleToolNames.contains(name) else { return }
            let activity = AIChatToolActivity(
                id: id, name: name, status: .running,
                summary: Self.runningLabel(name), input: event.input ?? [:],
                result: nil, durationMs: nil
            )
            upsert(activity, in: &conversation.messages[index].tools)
        case "tool-result":
            guard let id = event.id, let name = event.name,
                  Self.visibleToolNames.contains(name) else { return }
            let activity = AIChatToolActivity(
                id: id, name: name,
                status: event.status == "error" ? .error : .success,
                summary: event.summary ?? Self.finishedLabel(name),
                input: event.input ?? [:], result: event.result,
                durationMs: event.durationMs
            )
            upsert(activity, in: &conversation.messages[index].tools)
            conversation.messages[index].images.append(contentsOf: Self.images(from: event.result))
        case "usage":
            conversation.messages[index].usage = AIChatUsage(
                model: event.model ?? selectedModel.rawValue,
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
        case "error":
            errorMessage = event.message ?? "The chat turn failed."
        default:
            break
        }
    }

    private func appendText(_ delta: String, to conversation: inout AIConversation) {
        guard !delta.isEmpty,
              let index = conversation.messages.indices.last,
              conversation.messages[index].role == .assistant else { return }
        conversation.messages[index].content += delta
    }

    private func upsert(_ activity: AIChatToolActivity,
                        in activities: inout [AIChatToolActivity]) {
        if let index = activities.firstIndex(where: { $0.id == activity.id }) {
            var merged = activity
            if merged.input.isEmpty { merged.input = activities[index].input }
            activities[index] = merged
        } else {
            activities.append(activity)
        }
    }

    private func finalizeToolActivities(in conversation: inout AIConversation) {
        guard let index = conversation.messages.indices.last,
              conversation.messages[index].role == .assistant else { return }
        conversation.messages[index].tools.removeAll {
            !Self.visibleToolNames.contains($0.name)
        }
        for toolIndex in conversation.messages[index].tools.indices
        where conversation.messages[index].tools[toolIndex].status == .running {
            conversation.messages[index].tools[toolIndex].status = .error
            conversation.messages[index].tools[toolIndex].summary = "Tool ended without a result"
        }
    }

    private static func images(from result: [String: VoiceJSONValue]?) -> [AIChatImage] {
        guard let result, case .array(let values) = result["images"] else { return [] }
        return values.compactMap { value in
            guard case .object(let item) = value,
                  let imageURL = item["imageUrl"]?.stringValue ?? item["image_url"]?.stringValue,
                  let sourceURL = item["sourceUrl"]?.stringValue ?? item["source_url"]?.stringValue else { return nil }
            return AIChatImage(
                title: item["title"]?.stringValue ?? "Image",
                imageURL: imageURL,
                thumbnailURL: item["thumbnailUrl"]?.stringValue
                    ?? item["thumbnail_url"]?.stringValue ?? imageURL,
                sourceURL: sourceURL
            )
        }
    }

    private static func title(from text: String) -> String {
        let compact = text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(compact.prefix(56)) + (compact.count > 56 ? "…" : "")
    }

    private static let visibleToolNames: Set<String> = [
        "web_search", "image_search", "read_url", "search_current_note",
    ]

    static func displayName(for tool: String) -> String {
        switch tool {
        case "web_search": return "Web search"
        case "image_search": return "Image search"
        case "read_url": return "Read webpage"
        case "search_current_note": return "Search note"
        default: return tool.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private static func runningLabel(_ tool: String) -> String {
        switch tool {
        case "web_search": return "Searching the web…"
        case "image_search": return "Searching for images…"
        case "read_url": return "Reading the webpage…"
        case "search_current_note": return "Searching the note…"
        default: return "Using \(displayName(for: tool))…"
        }
    }

    private static func finishedLabel(_ tool: String) -> String {
        "Used \(displayName(for: tool))"
    }
}
