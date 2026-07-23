import XCTest
@testable import freewrite

@MainActor
final class AIConversationStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FreewriteConversationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root, FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
        root = nil
    }

    func testConversationRoundTripsAndCanBeDeleted() async throws {
        let id = UUID()
        let store = AIConversationStore()
        store.configure(rootDirectory: root)
        await store.save(AIConversation(
            id: id,
            entryId: UUID().uuidString,
            entryType: "text",
            entryDate: "Jul 18",
            title: "A useful thread",
            messages: [
                AIChatMessage(role: .user, content: "Help me connect these ideas."),
                AIChatMessage(role: .assistant, content: "Here is the connection."),
            ],
            reflectionQuestions: [
                AIReflectionQuestion(text: "What would make the decision real today?")
            ],
            questionGenerationUsage: AIChatUsage(
                model: "gpt-5.6-terra", inputTokens: 10, outputTokens: 5,
                totalTokens: 15, estimatedCostUSD: 0.001, latencyMs: 200
            )
        ))

        let reloaded = AIConversationStore()
        reloaded.configure(rootDirectory: root)
        XCTAssertEqual(reloaded.textConversations.count, 1)
        XCTAssertEqual(reloaded.textConversations.first?.id, id)
        XCTAssertEqual(reloaded.textConversations.first?.messages.count, 2)
        XCTAssertEqual(reloaded.textConversations.first?.reflectionQuestions?.count, 1)
        XCTAssertEqual(reloaded.textConversations.first?.questionGenerationUsage?.totalTokens, 15)
        XCTAssertEqual(reloaded.historyItems.first?.title, "A useful thread")

        reloaded.deleteTextConversation(id: id)
        XCTAssertTrue(reloaded.textConversations.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Conversations/\(id.uuidString.lowercased()).json").path
        ))
    }

    func testReloadRepairsTrailingEmptyStreamingPlaceholder() throws {
        let id = UUID()
        let conversation = AIConversation(
            id: id,
            entryId: nil,
            entryType: "text",
            entryDate: "",
            messages: [
                AIChatMessage(role: .user, content: "A saved question"),
                AIChatMessage(role: .assistant, content: ""),
            ]
        )
        let directory = root.appendingPathComponent("Conversations", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(conversation).write(
            to: directory.appendingPathComponent("\(id.uuidString.lowercased()).json")
        )

        let store = AIConversationStore()
        store.configure(rootDirectory: root)
        XCTAssertEqual(store.textConversations.first?.messages.count, 1)
        XCTAssertEqual(store.textConversations.first?.messages.first?.content, "A saved question")
    }

    func testPreparingAnotherEntryCancelsOpeningBeforeItCanOverwriteSelection() async {
        let store = AIConversationStore()
        store.configure(rootDirectory: root)
        let manager = AIChatManager()
        let first = AIChatContext(
            entryId: "entry-one", entryType: "text", entryDate: "Jul 22",
            entryText: "First note", recentWriting: ""
        )
        let second = AIChatContext(
            entryId: "entry-two", entryType: "text", entryDate: "Jul 23",
            entryText: "Second note", recentWriting: ""
        )

        manager.prepare(context: first, store: store)
        manager.prepare(context: second, store: store)
        manager.cancel(store: store)
        await Task.yield()

        XCTAssertEqual(manager.currentConversation?.entryId, "entry-two")
        XCTAssertFalse(manager.isStreaming)
        XCTAssertFalse(manager.isGeneratingQuestions)
    }

    func testVoiceCallEndingAfterEntrySwitchPersistsWithoutChangingVisibleThread() async {
        let store = AIConversationStore()
        store.configure(rootDirectory: root)
        let manager = AIChatManager()
        let visible = AIConversation(
            entryId: "entry-new", entryType: "text", entryDate: "Jul 23",
            title: "Current note"
        )
        manager.currentConversation = visible
        let endedAt = Date()
        let call = AIVoiceCallSummary(
            sessionId: "call-from-old-note",
            entryId: "entry-old",
            startedAt: endedAt.addingTimeInterval(-45),
            endedAt: endedAt,
            durationSeconds: 45,
            entryType: "video",
            entryDate: "Jul 22"
        )
        let currentContext = AIChatContext(
            entryId: "entry-new", entryType: "text", entryDate: "Jul 23",
            entryText: "New note", recentWriting: ""
        )

        manager.recordVoiceCall(call, context: currentContext, store: store)
        await Task.yield()

        XCTAssertEqual(manager.currentConversation?.id, visible.id)
        let persisted = store.latestConversation(entryId: "entry-old")
        XCTAssertEqual(persisted?.entryType, "video")
        XCTAssertEqual(persisted?.entryDate, "Jul 22")
        XCTAssertEqual(persisted?.messages.last?.voiceCall?.sessionId, "call-from-old-note")
    }

    func testProviderHistoryStripsArtifactImplementationDetails() {
        let html = """
        <!doctype html><html><head><style>.secret{color:red}</style></head>
        <body><main><h1>Hello</h1><p>The visible idea.</p>
        <script>window.hidden = "do not replay"</script></main></body></html>
        """
        let history = AIChatRequestCompactor.history([
            AIChatMessage(role: .assistant, content: html),
            AIChatMessage(role: .user, content: "What next?"),
        ])

        XCTAssertEqual(history.map(\.role), ["assistant", "user"])
        XCTAssertTrue(history[0].content.contains("Hello"))
        XCTAssertTrue(history[0].content.contains("The visible idea."))
        XCTAssertFalse(history[0].content.contains("color:red"))
        XCTAssertFalse(history[0].content.contains("do not replay"))
    }

    func testStreamingPreviewStripsFencedAndIncompleteStyleBlocks() {
        let partial = """
        ```html
        <!doctype html><html><head><style>body { color: red; }
        """
        XCTAssertEqual(AIChatRequestCompactor.visibleText(fromArtifact: partial), "")

        let complete = """
        ```html
        <main><h1>A real heading</h1><p>A useful answer.</p></main>
        ```
        """
        let visible = AIChatRequestCompactor.visibleText(fromArtifact: complete)
        XCTAssertTrue(visible.contains("A real heading"))
        XCTAssertTrue(visible.contains("A useful answer."))
        XCTAssertFalse(visible.contains("```"))
    }

    func testStreamingArtifactUsesSanitizedIncrementalDOMRendering() {
        let shell = AIHTMLArtifactView.streamingShell(colorScheme: .dark)
        let renderer = AIHTMLArtifactView.streamingRendererScript

        XCTAssertTrue(shell.contains("script-src 'none'"))
        XCTAssertFalse(shell.contains("<script>"))
        XCTAssertTrue(shell.contains("stream-model-styles"))
        XCTAssertTrue(shell.contains("connect-src 'none'"))
        XCTAssertTrue(renderer.contains("window.__freewriteRender"))
        XCTAssertTrue(renderer.contains("new DOMParser()"))
        XCTAssertTrue(renderer.contains("script,iframe,object,embed,form"))
        XCTAssertTrue(renderer.contains(".join('\\n')"))
    }

    func testFinalArtifactStripsFenceAndOwnsNoNestedDocumentScroll() {
        let document = AIHTMLArtifactView.finalDocument(
            from: "```html\n<main><h1>Rendered</h1></main>\n```",
            colorScheme: .light
        )

        XCTAssertTrue(document.contains("<main><h1>Rendered</h1></main>"))
        XCTAssertTrue(document.contains("overflow:hidden"))
        XCTAssertTrue(document.contains("Content-Security-Policy"))
        XCTAssertFalse(document.contains("```"))
    }

    func testFinalArtifactNormalizesViewportMinimumForEmbeddedRendering() {
        let document = AIHTMLArtifactView.finalDocument(
            from: "<!doctype html><html><head><style>main{min-height:100vh}</style></head><body><main>Short</main></body></html>",
            colorScheme: .light
        )
        XCTAssertTrue(document.contains("min-height:auto"))
        XCTAssertFalse(document.contains("min-height:100vh"))
        XCTAssertTrue(AIHTMLArtifactView.streamingRendererScript.contains("min-height\\s*"))
    }

    func testProviderContextStaysInsideByteBudgets() {
        let long = String(repeating: "thought ", count: 8_000)
        let history = AIChatRequestCompactor.history([
            AIChatMessage(role: .user, content: long),
            AIChatMessage(role: .assistant, content: long),
            AIChatMessage(role: .user, content: long),
        ])
        XCTAssertLessThanOrEqual(
            history.reduce(0) { $0 + $1.content.utf8.count },
            AIChatRequestCompactor.historyByteLimit
        )
        XCTAssertTrue(history.allSatisfy {
            $0.content.utf8.count <= AIChatRequestCompactor.messageByteLimit
        })

        let note = String(repeating: "earlier ", count: 8_000) + "LATEST"
        let compact = AIChatRequestCompactor.note(note)
        XCTAssertLessThanOrEqual(compact.utf8.count, AIChatRequestCompactor.noteByteLimit)
        XCTAssertTrue(compact.hasSuffix("LATEST"))
    }

    func testReflectionAnchorAndVoiceCallSummaryRoundTrip() async throws {
        let conversationID = UUID()
        let reflectionID = UUID()
        let call = AIVoiceCallSummary(
            sessionId: "voice-test-session",
            entryId: UUID().uuidString,
            startedAt: Date(timeIntervalSince1970: 100),
            endedAt: Date(timeIntervalSince1970: 173),
            durationSeconds: 73
        )
        let store = AIConversationStore()
        store.configure(rootDirectory: root)
        await store.save(AIConversation(
            id: conversationID,
            entryId: call.entryId,
            entryType: "text",
            entryDate: "Jul 20",
            messages: [
                AIChatMessage(id: reflectionID, role: .assistant, content: "<html>Reflection</html>"),
                AIChatMessage(role: .assistant, content: "", voiceCall: call),
            ],
            reflectionQuestions: [AIReflectionQuestion(text: "What is true?")],
            reflectionAnchorMessageID: reflectionID
        ))

        let reloaded = AIConversationStore()
        reloaded.configure(rootDirectory: root)
        let conversation = try XCTUnwrap(reloaded.conversation(id: conversationID))
        XCTAssertEqual(conversation.reflectionAnchorMessageID, reflectionID)
        XCTAssertEqual(conversation.messages.count, 2)
        XCTAssertEqual(conversation.messages.last?.voiceCall?.durationSeconds, 73)
        XCTAssertTrue(AIChatRequestCompactor.history(conversation.messages).allSatisfy {
            !$0.content.contains("voice-test-session")
        })
    }

    func testReloadRemovesProviderInternalToolRows() throws {
        let id = UUID()
        let internalTool = AIChatToolActivity(
            id: "internal", name: "bash_code_execution", status: .running,
            summary: "Using Bash Code Execution…", input: [:],
            result: nil, durationMs: nil
        )
        let productTool = AIChatToolActivity(
            id: "search", name: "web_search", status: .success,
            summary: "Searched the web", input: [:],
            result: nil, durationMs: 20
        )
        let conversation = AIConversation(
            id: id, entryId: nil, entryType: "text", entryDate: "",
            messages: [AIChatMessage(
                role: .assistant, content: "<html>Answer</html>",
                tools: [internalTool, productTool]
            )]
        )
        let directory = root.appendingPathComponent("Conversations", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(conversation).write(
            to: directory.appendingPathComponent("\(id.uuidString.lowercased()).json")
        )

        let store = AIConversationStore()
        store.configure(rootDirectory: root)
        XCTAssertEqual(store.conversation(id: id)?.messages.first?.tools.map(\.name), ["web_search"])
    }

    func testHeaderMarkerMatchesBeforeHeadingTextExists() throws {
        let pattern = try XCTUnwrap(MarkdownEditor.Coordinator.headerPattern(prefix: "# "))
        let markerOnly = "# "
        XCTAssertNotNil(pattern.firstMatch(
            in: markerOnly,
            range: NSRange(location: 0, length: (markerOnly as NSString).length)
        ))
        XCTAssertNil(pattern.firstMatch(
            in: "plain text",
            range: NSRange(location: 0, length: ("plain text" as NSString).length)
        ))
    }
}
