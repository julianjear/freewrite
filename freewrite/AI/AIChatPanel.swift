import SwiftUI

struct AIChatPanel: View {
    private static let chatBottomID = "freewrite-ai-chat-bottom"
    @ObservedObject var manager: AIChatManager
    @ObservedObject var store: AIConversationStore
    @ObservedObject var voiceManager: VoiceCoachManager
    @ObservedObject var voiceConfigurationStore: VoiceConfigurationStore
    let context: AIChatContext
    let colorScheme: ColorScheme
    let isExpanded: Bool
    let showsVoiceSetup: Bool
    let showsVoiceCall: Bool
    let startingVoiceQuestion: String?
    let onToggleExpanded: () -> Void
    let onCall: (String?) -> Void
    let onInsertQuestion: (String) -> Void
    let onCancelVoiceSetup: () -> Void
    let onStartVoice: (VoiceSessionConfiguration) -> Void
    let onEndVoice: () -> Void
    let onClose: () -> Void
    @State private var toolsExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if showsVoiceSetup {
                VoiceSetupPanel(
                    store: voiceConfigurationStore,
                    startingQuestion: startingVoiceQuestion,
                    onCancel: onCancelVoiceSetup,
                    onStart: onStartVoice
                )
            } else if showsVoiceCall {
                VoiceCoachPanel(
                    manager: voiceManager,
                    colorScheme: colorScheme,
                    startingQuestion: startingVoiceQuestion,
                    chatImages: currentChatImages,
                    onEnd: onEndVoice
                )
            } else if manager.showingHistory {
                history
            } else if let voice = manager.selectedVoiceConversation {
                voiceConversation(voice)
            } else {
                chat
            }
        }
        .frame(
            minWidth: 610,
            idealWidth: 610,
            maxWidth: isExpanded ? .infinity : 610,
            maxHeight: .infinity
        )
        .background(colorScheme == .light ? Color.white : Color.black)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Freewrite AI panel")
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                manager.showingHistory.toggle()
            } label: {
                Image(systemName: manager.showingHistory ? "chevron.left" : "clock.arrow.circlepath")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .disabled(showsVoiceSetup || showsVoiceCall)
            .help(manager.showingHistory ? "Back to conversation" : "Conversation history")
            .accessibilityLabel(manager.showingHistory ? "Back to conversation" : "Conversation history")

            VStack(alignment: .leading, spacing: 1) {
                Text(headerTitle)
                    .font(.system(size: 14, weight: .semibold))
                if !manager.showingHistory {
                    Text(context.label)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            Button {
                manager.newConversation(context: context, store: store)
            } label: {
                Image(systemName: "square.and.pencil")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .disabled(manager.isStreaming || manager.isGeneratingQuestions
                      || showsVoiceSetup || showsVoiceCall)
            .help("New text conversation")
            .accessibilityLabel("New text conversation")

            Button {
                if showsVoiceCall {
                    voiceManager.showsObservability.toggle()
                } else {
                    manager.showsObservability.toggle()
                }
            } label: {
                let enabled = showsVoiceCall
                    ? voiceManager.showsObservability : manager.showsObservability
                Image(systemName: enabled ? "waveform.path.ecg.rectangle.fill" : "waveform.path.ecg.rectangle")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .disabled(showsVoiceSetup)
            .help("Toggle observability")
            .accessibilityLabel("Toggle observability")

            Button(action: onToggleExpanded) {
                Image(systemName: isExpanded
                      ? "arrow.down.right.and.arrow.up.left"
                      : "arrow.up.left.and.arrow.down.right")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Return to side panel" : "Expand chat to full width")
            .accessibilityLabel(isExpanded ? "Minimize chat" : "Expand chat")

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help("Close AI panel")
            .accessibilityLabel("Close AI panel")
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 52)
    }

    private var history: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Conversations")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("\(store.historyItems.count)")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)

            Divider()

            if store.historyItems.isEmpty {
                ContentUnavailableView(
                    "No conversations yet",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("Text chats and completed voice calls will appear here.")
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(store.historyItems) { item in
                            Button {
                                if let id = item.textConversationId {
                                    manager.selectText(id: id, store: store)
                                } else if let id = item.voiceConversationId {
                                    manager.selectVoice(id: id, store: store)
                                }
                            } label: {
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: item.kind == .voice ? "waveform" : "bubble.left")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 18, height: 18)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(item.title)
                                            .font(.system(size: 13))
                                            .foregroundStyle(.primary)
                                            .lineLimit(2)
                                            .multilineTextAlignment(.leading)
                                        HStack {
                                            Text(item.subtitle)
                                                .lineLimit(1)
                                            Spacer()
                                            Text(item.date.formatted(date: .abbreviated, time: .shortened))
                                                .lineLimit(1)
                                        }
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 11)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                if let id = item.textConversationId {
                                    Button("Delete conversation", role: .destructive) {
                                        store.deleteTextConversation(id: id)
                                    }
                                }
                            }
                            Divider().padding(.leading, 42)
                        }
                    }
                }
            }
        }
    }

    private var chat: some View {
        VStack(spacing: 0) {
            messages
            if let error = manager.errorMessage {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(error).font(.system(size: 11)).textSelection(.enabled)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.orange.opacity(0.09))
            }
            Divider()
            composer
        }
        .frame(maxHeight: .infinity)
    }

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Web views carry process and layout state; keeping message
                // children stable avoids LazyVStack recycling them while the
                // user scrolls or begins a follow-up turn.
                VStack(alignment: .leading, spacing: 16) {
                    if manager.showsObservability {
                        availableTools
                    }
                    if manager.currentConversation?.messages.isEmpty != false {
                        emptyChat
                    }
                    ForEach(manager.currentConversation?.messages ?? []) { message in
                        AIChatMessageView(message: message,
                                          showsObservability: manager.showsObservability,
                                          colorScheme: colorScheme,
                                          isStreaming: manager.isStreaming
                                            && message.id == manager.currentConversation?.messages.last?.id)
                            .id(message.id)
                        if shouldShowReflectionQuestions(after: message.id) {
                            reflectionQuestions
                        }
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(Self.chatBottomID)
                }
                .padding(14)
                .padding(.bottom, 8)
            }
            .scrollIndicators(.automatic)
            .frame(maxHeight: .infinity)
            .onAppear {
                // Opening the chat is an explicit navigation action, so resume
                // at its newest content. Streaming and completion do not reuse
                // this path and therefore cannot steal the reader's position.
                DispatchQueue.main.async {
                    proxy.scrollTo(Self.chatBottomID, anchor: .bottom)
                }
            }
            .onChange(of: manager.currentConversation?.id) { _, _ in
                DispatchQueue.main.async {
                    proxy.scrollTo(Self.chatBottomID, anchor: .bottom)
                }
            }
            .onChange(of: manager.requestedScrollMessageID) { _, messageID in
                guard let messageID else { return }
                // A submitted user turn becomes the top of the viewport. We
                // never move the scroll position merely because generation
                // completed, so readers do not lose the passage they chose.
                DispatchQueue.main.async {
                    withAnimation(.easeOut(duration: 0.16)) {
                        proxy.scrollTo(messageID, anchor: .top)
                    }
                }
            }
        }
    }

    private func shouldShowReflectionQuestions(after messageID: UUID) -> Bool {
        guard let conversation = manager.currentConversation else { return false }
        let anchor = conversation.reflectionAnchorMessageID
            ?? conversation.messages.first(where: {
                $0.role == .assistant && $0.voiceCall == nil
            })?.id
        guard anchor == messageID else { return false }
        return manager.isGeneratingQuestions
            || conversation.reflectionQuestions?.isEmpty == false
            || manager.questionErrorMessage != nil
    }

    @ViewBuilder
    private var reflectionQuestions: some View {
        if manager.isGeneratingQuestions {
            HStack(spacing: 9) {
                ProgressView().controlSize(.small)
                Text("Finding reflection questions to go deeper…")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
        } else if let questions = manager.currentConversation?.reflectionQuestions,
                  !questions.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 7) {
                    Image(systemName: "sparkles")
                    Text("Reflection questions to go deeper")
                    Spacer()
                    if manager.showsObservability,
                       let usage = manager.currentConversation?.questionGenerationUsage {
                        Text("\(usage.totalTokens.formatted()) tokens · \(usage.estimatedCostUSD, format: .currency(code: "USD").precision(.fractionLength(4)))")
                            .font(.system(size: 9).monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .help("Separate question-generation call · input \(usage.inputTokens.formatted()), cached \((usage.cachedInputTokens ?? 0).formatted()), output \(usage.outputTokens.formatted()) tokens")
                    }
                }
                .font(.system(size: 12, weight: .semibold))

                ForEach(Array(questions.enumerated()), id: \.element.id) { index, question in
                    HStack(alignment: .top, spacing: 10) {
                        Text("\(index + 1)")
                            .font(.system(size: 10, weight: .bold).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 18, height: 18)
                            .background(Color.secondary.opacity(0.10), in: Circle())
                        Text(question.text)
                            .font(.system(size: 13, weight: .medium))
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                        Spacer(minLength: 4)
                        Button {
                            onInsertQuestion(question.text)
                        } label: {
                            Image(systemName: "pencil")
                                .frame(width: 26, height: 26)
                                .background(Color.secondary.opacity(0.08), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .help("Add this question to the bottom of the current note")
                        .accessibilityLabel("Write about question \(index + 1)")
                        .pointerCursor()

                        Button {
                            onCall(question.text)
                        } label: {
                            Image(systemName: "phone.fill")
                                .frame(width: 26, height: 26)
                                .background(Color.accentColor.opacity(0.14), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .help("Start a call from this question")
                        .accessibilityLabel("Call about question \(index + 1)")
                        .pointerCursor()
                    }
                    .padding(10)
                    .background(Color.secondary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
                }
            }
            .padding(13)
            .background(Color.accentColor.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.accentColor.opacity(0.12), lineWidth: 1)
            }
        } else if let error = manager.questionErrorMessage {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.system(size: 10))
                .foregroundStyle(.orange)
                .padding(10)
        }
    }

    private var availableTools: some View {
        DisclosureGroup(isExpanded: $toolsExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(AIChatToolDefinition.available) { tool in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: tool.systemImage)
                            .frame(width: 16)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tool.title).font(.system(size: 10, weight: .semibold))
                            Text(tool.description)
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(.top, 8)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "wrench.and.screwdriver")
                Text("4 tools available")
                Spacer()
                Text("Activity appears on each response")
                    .foregroundStyle(.tertiary)
            }
            .font(.system(size: 9, weight: .medium))
        }
        .padding(10)
        .background(Color.secondary.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))
    }

    private var emptyChat: some View {
        VStack(alignment: .leading, spacing: 15) {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 19))
                    .foregroundStyle(.secondary)
                Text("Talk through this with me.")
                    .font(.system(size: 17, weight: .semibold))
                Text("I can work from the note in front of you, search the web, find reference images, and read links when it helps.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 7) {
                suggestion("What stands out to you?")
                suggestion("Challenge my thinking here")
                suggestion("What is the real bottleneck?")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 20)
    }

    private func suggestion(_ title: String) -> some View {
        Button {
            manager.draft = title
            manager.submit(context: context, store: store)
        } label: {
            HStack {
                Text(title).font(.system(size: 12))
                Spacer()
                Image(systemName: "arrow.up.right").font(.system(size: 9))
            }
            .padding(.horizontal, 11)
            .frame(height: 34)
            .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(manager.isStreaming || manager.isGeneratingQuestions)
    }

    private var composer: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Menu {
                    ForEach(AIChatModel.allCases) { model in
                        Button {
                            manager.selectedModel = model
                        } label: {
                            Label(model.title, systemImage: manager.selectedModel == model ? "checkmark" : "circle")
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(manager.selectedModel.title)
                        Image(systemName: "chevron.down").font(.system(size: 8))
                    }
                    .font(.system(size: 10, weight: .medium))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(manager.selectedModel.detail)

                Text("·").foregroundStyle(.tertiary)

                Menu {
                    ForEach(manager.selectedModel.supportedEfforts) { effort in
                        Button {
                            manager.reasoningEffort = effort
                        } label: {
                            Label(effort.title, systemImage: manager.reasoningEffort == effort ? "checkmark" : "circle")
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text("\(manager.reasoningEffort.title) thinking")
                        Image(systemName: "chevron.down").font(.system(size: 8))
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Spacer()
                Text(context.label)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            HStack(alignment: .bottom, spacing: 7) {
                TextField("Message Freewrite AI", text: $manager.draft, axis: .vertical)
                    .font(.system(size: 13))
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .padding(.leading, 6)
                    .padding(.vertical, 7)
                    .disabled(manager.isStreaming || manager.isGeneratingQuestions)
                    .accessibilityLabel("Message Freewrite AI")
                    .submitLabel(.send)
                    .onKeyPress(.return) {
                        guard sendEnabled else { return .handled }
                        manager.submit(context: context, store: store)
                        return .handled
                    }
                    .onSubmit {
                        guard sendEnabled else { return }
                        manager.submit(context: context, store: store)
                    }

                if manager.isStreaming || manager.isGeneratingQuestions {
                    Button { manager.cancel(store: store) } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 11))
                            .frame(width: 30, height: 30)
                            .foregroundStyle(.white)
                            .background(Color.primary, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Stop generation")
                    .accessibilityLabel(
                        manager.isGeneratingQuestions
                            ? "Stop reflection questions"
                            : "Stop response"
                    )
                    .pointerCursor()
                } else {
                    Button {
                        manager.submit(context: context, store: store)
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 12, weight: .bold))
                            .frame(width: 30, height: 30)
                            .foregroundStyle(colorScheme == .light ? .white : .black)
                            .background(sendEnabled ? Color.primary : Color.secondary.opacity(0.25), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!sendEnabled)
                    .help("Send message (Return)")
                    .accessibilityLabel("Send message")
                    .pointerCursor()
                }

                Button { onCall(nil) } label: {
                    Label("Call", systemImage: "phone.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .foregroundStyle(.primary)
                        .background(Color.secondary.opacity(0.10), in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(manager.isStreaming || manager.isGeneratingQuestions)
                .help("Continue this conversation by voice")
                .accessibilityLabel("Continue conversation by voice")
                .pointerCursor()
            }
            .padding(5)
            .background(Color.secondary.opacity(0.065), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(Color.secondary.opacity(0.10), lineWidth: 1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 9)
        .padding(.bottom, 12)
    }

    private var sendEnabled: Bool {
        !manager.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var headerTitle: String {
        if showsVoiceSetup { return "Set up voice" }
        if showsVoiceCall { return "Voice conversation" }
        return manager.selectedVoiceConversation == nil ? "Freewrite AI" : "Voice conversation"
    }

    private var currentChatImages: [AIChatImage] {
        manager.currentConversation?.messages.flatMap(\.images) ?? []
    }

    private func voiceConversation(_ conversation: VoiceConversationRecord) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                voiceStat("Duration", duration(conversation.durationSec))
                voiceStat("Model", conversation.model)
                voiceStat("Est. cost", conversation.estimatedCostUSD > 0
                          ? String(format: "$%.4f", conversation.estimatedCostUSD) : "—")
            }
            .padding(14)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(conversation.transcript) { line in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(line.speaker.uppercased())
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.secondary)
                            Text(line.text)
                                .font(.system(size: 13))
                                .textSelection(.enabled)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if manager.showsObservability, !conversation.strategyBriefs.isEmpty {
                        Divider().padding(.vertical, 4)
                        Text("BACKGROUND THINKING")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.purple)
                        ForEach(conversation.strategyBriefs) { event in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(event.detail["model"]?.stringValue ?? "Strategist")
                                    .font(.system(size: 11, weight: .semibold))
                                if let summary = event.detail["summary"]?.stringValue {
                                    Text(summary).font(.system(size: 12))
                                }
                                if let direction = event.detail["direction"]?.stringValue {
                                    Text("Direction: \(direction)")
                                        .font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                            }
                            .padding(10)
                            .background(Color.purple.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
                .padding(14)
            }
        }
    }

    private func voiceStat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 11, weight: .semibold)).lineLimit(1)
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func duration(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// Keeps each message's identity stable so its WebView can transition from a
/// sanitized partial DOM preview to the completed interactive artifact.
private struct AIChatMessageView: View {
    let message: AIChatMessage
    let showsObservability: Bool
    let colorScheme: ColorScheme
    let isStreaming: Bool

    var body: some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 8) {
            if showsObservability, message.role == .assistant, !message.tools.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(message.tools) { tool in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 7) {
                                if tool.status == .running {
                                    ProgressView().controlSize(.mini)
                                } else {
                                    Image(systemName: tool.status == .success ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                                        .foregroundStyle(tool.status == .success ? Color.green : Color.orange)
                                }
                                Text(tool.summary.isEmpty ? AIChatManager.displayName(for: tool.name) : tool.summary)
                                    .lineLimit(1)
                                Spacer()
                                if showsObservability, let duration = tool.durationMs {
                                    Text("\(duration) ms").monospacedDigit().foregroundStyle(.tertiary)
                                }
                            }
                            if showsObservability {
                                let input = compactJSON(tool.input)
                                if !input.isEmpty && input != "{}" {
                                    Text("Input  \(input)")
                                        .font(.system(size: 9).monospaced())
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(3)
                                        .textSelection(.enabled)
                                }
                                if let result = tool.result {
                                    Text("Result  \(compactJSON(result))")
                                        .font(.system(size: 9).monospaced())
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(3)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            }

            if let call = message.voiceCall {
                voiceCallSummary(call)
            } else if message.role == .user, !message.content.isEmpty {
                    HStack {
                        Spacer(minLength: 48)
                        Text(rendered(message.content))
                            .font(.system(size: 13))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 9)
                            .background(Color.secondary.opacity(0.10), in:
                                UnevenRoundedRectangle(
                                    cornerRadii: .init(topLeading: 10, bottomLeading: 10,
                                                       bottomTrailing: 0, topTrailing: 10),
                                    style: .continuous
                                )
                            )
                    }
            } else if message.role == .assistant, message.content.isEmpty {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.small)
                    Text("Thinking…").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            } else if message.role == .assistant,
                      isStreaming || AIHTMLArtifactView.looksLikeHTML(message.content) {
                AIHTMLArtifactView(
                    html: message.content,
                    colorScheme: colorScheme,
                    isStreaming: isStreaming
                )
            } else if message.role == .assistant, !message.content.isEmpty {
                Text(rendered(message.content))
                    .font(.system(size: 13))
                    .textSelection(.enabled)
            }

            if !message.images.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(message.images) { image in
                            Link(destination: URL(string: image.sourceURL) ?? URL(string: "https://commons.wikimedia.org")!) {
                                VStack(alignment: .leading, spacing: 4) {
                                    AsyncImage(url: URL(string: image.thumbnailURL)) { phase in
                                        switch phase {
                                        case .success(let loaded):
                                            loaded.resizable().scaledToFill()
                                        case .failure:
                                            Color.secondary.opacity(0.12).overlay(Image(systemName: "photo"))
                                        default:
                                            Color.secondary.opacity(0.08).overlay(ProgressView().controlSize(.small))
                                        }
                                    }
                                    .frame(width: 160, height: 105)
                                    .clipped()
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    Text(image.title).font(.system(size: 9)).lineLimit(1)
                                }
                                .frame(width: 160, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .scrollIndicators(.never)
            }

            if !message.citations.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 5) {
                        ForEach(message.citations) { citation in
                            if let url = URL(string: citation.url) {
                                Link(destination: url) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "link").font(.system(size: 8))
                                        Text(citation.title).lineLimit(1)
                                    }
                                    .font(.system(size: 9))
                                    .padding(.horizontal, 7).frame(height: 24)
                                    .background(Color.secondary.opacity(0.08), in: Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .scrollIndicators(.never)
            }

            if showsObservability, let usage = message.usage {
                HStack(spacing: 6) {
                    Text(usage.model)
                    Text("·")
                    Text("\(usage.totalTokens) tok")
                        .help(tokenBreakdown(usage))
                    Text("·")
                    Text(String(format: "~$%.5f", usage.estimatedCostUSD))
                        .help(costBreakdown(usage))
                    Text("·")
                    Text(String(format: "%.2fs", Double(usage.latencyMs) / 1000))
                }
                .font(.system(size: 9).monospacedDigit())
                .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity,
               alignment: message.role == .user ? .trailing : .leading)
    }

    private func voiceCallSummary(_ call: AIVoiceCallSummary) -> some View {
        HStack(spacing: 11) {
            Image(systemName: "phone.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 30, height: 30)
                .background(Color.accentColor.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text("There was a voice call")
                    .font(.system(size: 12, weight: .semibold))
                Text("It lasted \(duration(call.durationSeconds)).")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(call.endedAt.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 9).monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(11)
        .background(Color.secondary.opacity(0.055), in: RoundedRectangle(cornerRadius: 11))
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .stroke(Color.secondary.opacity(0.10), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("There was a voice call lasting \(duration(call.durationSeconds))")
    }

    private func duration(_ seconds: Int) -> String {
        let safe = max(0, seconds)
        if safe < 60 { return "\(safe) seconds" }
        let minutes = safe / 60
        let remainder = safe % 60
        return remainder == 0
            ? "\(minutes) minute\(minutes == 1 ? "" : "s")"
            : "\(minutes) minute\(minutes == 1 ? "" : "s") \(remainder) seconds"
    }
    private func rendered(_ value: String) -> AttributedString {
        (try? AttributedString(markdown: value,
                               options: .init(interpretedSyntax: .full)))
            ?? AttributedString(value)
    }

    private func compactJSON(_ value: [String: VoiceJSONValue]) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text.count > 600 ? String(text.prefix(600)) + "…" : text
    }

    private func tokenBreakdown(_ usage: AIChatUsage) -> String {
        var parts = ["Input: \(usage.inputTokens)"]
        if (usage.cachedInputTokens ?? 0) > 0 { parts.append("Cache reads: \(usage.cachedInputTokens ?? 0)") }
        if (usage.cacheWriteInputTokens ?? 0) > 0 { parts.append("Cache writes: \(usage.cacheWriteInputTokens ?? 0)") }
        parts.append("Output: \(usage.outputTokens)")
        if (usage.reasoningTokens ?? 0) > 0 { parts.append("Reasoning within output: \(usage.reasoningTokens ?? 0)") }
        return parts.joined(separator: "\n")
    }

    private func costBreakdown(_ usage: AIChatUsage) -> String {
        var parts = [
            String(format: "Uncached input: $%.6f", usage.inputCostUSD ?? 0),
            String(format: "Cached input: $%.6f", usage.cachedInputCostUSD ?? 0),
        ]
        if (usage.cacheWriteCostUSD ?? 0) > 0 {
            parts.append(String(format: "Cache writes: $%.6f", usage.cacheWriteCostUSD ?? 0))
        }
        parts.append(String(format: "Output: $%.6f", usage.outputCostUSD ?? 0))
        if (usage.toolCostUSD ?? 0) > 0 {
            parts.append(String(format: "Provider tools: $%.6f", usage.toolCostUSD ?? 0))
        }
        parts.append("Estimate from measured usage at public list prices; invoice adjustments are not included.")
        return parts.joined(separator: "\n")
    }
}
