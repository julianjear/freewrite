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
}
