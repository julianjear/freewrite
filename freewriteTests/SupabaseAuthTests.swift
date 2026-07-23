import XCTest
@testable import freewrite

final class SupabaseAuthTests: XCTestCase {
    @MainActor
    func testOverlappingSignInsShareOneOAuthOperation() async throws {
        let coordinator = OAuthSignInCoordinator()
        var operationCount = 0

        async let first: Void = coordinator.run { _ in
            operationCount += 1
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        async let second: Void = coordinator.run { _ in
            operationCount += 1
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        try await first
        try await second
        XCTAssertEqual(operationCount, 1)
    }

    @MainActor
    func testCompletedOAuthOperationDoesNotBlockTheNextAttempt() async throws {
        let coordinator = OAuthSignInCoordinator()
        var operationCount = 0

        try await coordinator.run { _ in operationCount += 1 }
        try await coordinator.run { _ in operationCount += 1 }

        XCTAssertEqual(operationCount, 2)
    }

    func testOAuthCallbackRoundTripsItsAttemptIdentity() {
        let attemptID = UUID()
        let callback = OAuthCallbackAttempt.redirectURL(for: attemptID)

        XCTAssertEqual(OAuthCallbackAttempt.id(from: callback), attemptID)
        XCTAssertNil(OAuthCallbackAttempt.id(from: URL(string: "freewrite://auth-callback")!))
        XCTAssertNil(OAuthCallbackAttempt.id(
            from: URL(string: "freewrite://auth-callback?freewrite_attempt=not-a-uuid")!
        ))
    }
}
