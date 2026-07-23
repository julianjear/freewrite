import XCTest
@testable import freewrite

final class VoiceContextTests: XCTestCase {
    func testShortTextNotTruncated() {
        let c = VoiceContext.make(entryType: .text, entryDate: "May 30",
                                  entryText: "hello", hasTranscript: false)
        XCTAssertEqual(c.entryText, "hello")
        XCTAssertFalse(c.truncated)
    }

    func testLongTextKeepsTailAndMarksTruncated() {
        let long = String(repeating: "x", count: VoiceContext.maxEntryBytes + 500) + "TAIL"
        let c = VoiceContext.make(entryType: .text, entryDate: "May 30",
                                  entryText: long, hasTranscript: false)
        XCTAssertTrue(c.truncated)
        XCTAssertTrue(c.entryText.hasSuffix("TAIL"))
        XCTAssertLessThanOrEqual(c.entryText.utf8.count, VoiceContext.maxEntryBytes)
    }

    func testEncodesToExpectedJSONKeys() throws {
        let c = VoiceContext.make(entryType: .video, entryDate: "May 30",
                                  entryText: "hi", hasTranscript: true,
                                  chatHistory: "Julian: I am choosing.",
                                  startingQuestion: "What do you want?")
        let data = try JSONEncoder().encode(c)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(obj["entryType"] as? String, "video")
        XCTAssertEqual(obj["modality"] as? String, "voice")
        XCTAssertEqual(obj["hasTranscript"] as? Bool, true)
        XCTAssertEqual(obj["chatHistory"] as? String, "Julian: I am choosing.")
        XCTAssertEqual(obj["startingQuestion"] as? String, "What do you want?")
    }

    func testChatHandoffAndQuestionAreBoundedIndependently() {
        let context = VoiceContext.make(
            entryType: .text, entryDate: "Jul 20", entryText: "note",
            hasTranscript: false,
            chatHistory: String(repeating: "chat ", count: 4_000) + "LATEST CHAT",
            startingQuestion: String(repeating: "q", count: 2_000) + "?"
        )
        XCTAssertLessThanOrEqual(context.chatHistory.utf8.count, VoiceContext.maxChatBytes)
        XCTAssertTrue(context.chatHistory.hasSuffix("LATEST CHAT"))
        XCTAssertLessThanOrEqual(context.startingQuestion?.utf8.count ?? 0,
                                 VoiceContext.maxQuestionBytes)
    }

    func testConfigurationTelemetryErrorIsAlwaysUserFacing() {
        let event = VoiceTelemetryEvent(
            version: 1,
            id: "event-1",
            sequence: 1,
            sessionId: "session-1",
            eventType: "error",
            stage: "configuration",
            timestamp: "2026-07-23T20:00:00Z",
            monotonicSeconds: 1,
            detail: ["message": .string("Missing provider key")]
        )

        XCTAssertEqual(
            event.fatalErrorMessage,
            "Coach configuration error: Missing provider key"
        )
    }

    func testRecoverableAndSupervisorErrorsStayObservableWithoutEndingTheCall() {
        let recoverableSessionError = VoiceTelemetryEvent(
            version: 1,
            id: "event-2",
            sequence: 2,
            sessionId: "session-1",
            eventType: "error",
            stage: "agent-session",
            timestamp: "2026-07-23T20:00:01Z",
            monotonicSeconds: 2,
            detail: [
                "message": .string("Provider retrying"),
                "recoverable": .bool(true),
            ]
        )
        let supervisorError = VoiceTelemetryEvent(
            version: 1,
            id: "event-3",
            sequence: 3,
            sessionId: "session-1",
            eventType: "error",
            stage: "supervisor",
            timestamp: "2026-07-23T20:00:02Z",
            monotonicSeconds: 3,
            detail: ["message": .string("Strategist unavailable")]
        )

        XCTAssertNil(recoverableSessionError.fatalErrorMessage)
        XCTAssertNil(supervisorError.fatalErrorMessage)
    }

    func testNonrecoverableAgentErrorEndsTheCall() {
        let event = VoiceTelemetryEvent(
            version: 1,
            id: "event-4",
            sequence: 4,
            sessionId: "session-1",
            eventType: "error",
            stage: "agent-session",
            timestamp: "2026-07-23T20:00:03Z",
            monotonicSeconds: 4,
            detail: [
                "message": .string("Realtime model stopped"),
                "recoverable": .bool(false),
            ]
        )

        XCTAssertEqual(event.fatalErrorMessage, "Coach error: Realtime model stopped")
    }

    @MainActor
    func testAgentStateCannotOverwriteAnErrorPhase() {
        let current = VoiceCoachManager.Phase.error("Coach configuration error")

        XCTAssertEqual(
            VoiceCoachManager.phase(afterAgentState: "listening", current: current),
            current
        )
        XCTAssertEqual(
            VoiceCoachManager.phase(afterAgentState: "speaking", current: current),
            current
        )
    }
}
