import Foundation
import AppKit
import Supabase

/// File-based session storage instead of the keychain. Why: dev builds are
/// ad-hoc/unsigned, so the app's code signature changes every rebuild and
/// macOS treats each build as a different app — "Always Allow" on the keychain
/// item never sticks and the password prompt reappears forever. A 0600 file in
/// Application Support avoids the keychain entirely. (If we ship with a stable
/// Developer ID signature later, we can switch back to KeychainLocalStorage.)
struct FileAuthLocalStorage: AuthLocalStorage {
    private let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask)[0]
        .appendingPathComponent("Freewrite", isDirectory: true)

    private func fileURL(for key: String) -> URL {
        let safe = key.replacingOccurrences(of: "/", with: "_")
        return dir.appendingPathComponent("\(safe).authstore")
    }

    func store(key: String, value: Data) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = fileURL(for: key)
        try value.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: url.path)
    }

    func retrieve(key: String) throws -> Data? {
        try? Data(contentsOf: fileURL(for: key))
    }

    func remove(key: String) throws {
        try? FileManager.default.removeItem(at: fileURL(for: key))
    }
}

/// Coalesces overlapping OAuth requests onto one browser round trip. Voice and
/// chat can both discover an expired session at nearly the same time; sharing
/// the operation prevents a second attempt from replacing the first caller's
/// continuation.
@MainActor
final class OAuthSignInCoordinator {
    private var active: (id: UUID, task: Task<Void, Error>)?

    func run(_ operation: @escaping @MainActor (UUID) async throws -> Void) async throws {
        if let active {
            try await active.task.value
            return
        }

        let id = UUID()
        let task = Task { @MainActor in
            try await operation(id)
        }
        active = (id, task)
        defer {
            if active?.id == id {
                active = nil
            }
        }
        try await task.value
    }
}

enum OAuthCallbackAttempt {
    private static let queryName = "freewrite_attempt"

    static func redirectURL(for attemptID: UUID) -> URL {
        var components = URLComponents()
        components.scheme = "freewrite"
        components.host = "auth-callback"
        components.queryItems = [
            URLQueryItem(name: queryName, value: attemptID.uuidString),
        ]
        return components.url!
    }

    static func id(from url: URL) -> UUID? {
        let value = URLComponents(
            url: url, resolvingAgainstBaseURL: false
        )?.queryItems?.first(where: { $0.name == queryName })?.value
        return value.flatMap(UUID.init(uuidString:))
    }
}

@MainActor
final class SupabaseAuth: ObservableObject {
    static let shared = SupabaseAuth()

    // Supabase project (publishable key — safe to ship in the client).
    private let client = SupabaseClient(
        supabaseURL: URL(string: "https://glzxxdwlsttayuoajycq.supabase.co")!,
        supabaseKey: "sb_publishable_UmMcVy-1CFwG-AT6kyzRyw_hq89U1Ie",
        options: SupabaseClientOptions(
            auth: SupabaseClientOptions.AuthOptions(
                storage: FileAuthLocalStorage(),
                emitLocalSessionAsInitialSession: true
            )
        )
    )

    @Published var accessToken: String?
    @Published var isSignedIn = false

    // Lets start() await the OAuth deep-link callback instead of returning early.
    private let signInCoordinator = OAuthSignInCoordinator()
    private var pendingSignIn: (
        id: UUID,
        continuation: CheckedContinuation<Void, Error>
    )?

    /// Expose the client so the transcript store can insert rows under RLS.
    var supabase: SupabaseClient { client }

    func restore() async {
        do {
            let session = try await client.auth.session
            guard !session.isExpired else {
                accessToken = nil
                isSignedIn = false
                return
            }
            accessToken = session.accessToken
            isSignedIn = true
        } catch {
            accessToken = nil
            isSignedIn = false
        }
    }

    /// Opens Google OAuth in the user's DEFAULT browser (not Safari/ASWebAuth).
    /// We build the provider URL and hand it to NSWorkspace; the browser then
    /// redirects to freewrite://auth-callback, which `handleCallback` consumes.
    /// Suspends until that callback resolves the session (or times out).
    func signInWithGoogle() async throws {
        try await signInCoordinator.run { [weak self] attemptId in
            guard let self else { throw CancellationError() }
            try await self.performGoogleSignIn(attemptId: attemptId)
        }
    }

    private func performGoogleSignIn(attemptId: UUID) async throws {
        let url = try client.auth.getOAuthSignInURL(
            provider: .google,
            redirectTo: OAuthCallbackAttempt.redirectURL(for: attemptId)
        )

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            pendingSignIn = (attemptId, cont)
            guard NSWorkspace.shared.open(url) else {
                pendingSignIn = nil
                cont.resume(throwing: URLError(.cannotLoadFromNetwork))
                return
            }
            // Safety timeout so the UI doesn't hang forever if the user bails.
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 180 * 1_000_000_000)
                guard let self, self.pendingSignIn?.id == attemptId,
                      let pending = self.pendingSignIn else { return }
                self.pendingSignIn = nil
                pending.continuation.resume(throwing: URLError(.timedOut))
            }
        }
    }

    /// Called from freewriteApp's .onOpenURL when the browser redirects back.
    func handleCallback(url: URL) async {
        guard let callbackAttemptID = OAuthCallbackAttempt.id(from: url),
              let pending = pendingSignIn,
              pending.id == callbackAttemptID else {
            return
        }
        // Claim this attempt before awaiting Supabase. Its timeout can no
        // longer fire, and a late callback cannot consume a future attempt.
        pendingSignIn = nil
        do {
            let session = try await client.auth.session(from: url)
            accessToken = session.accessToken
            isSignedIn = true
            pending.continuation.resume()
        } catch {
            pending.continuation.resume(throwing: error)
        }
    }

    /// Always ask Supabase for the current session. The SDK refreshes expired
    /// access tokens; returning the launch-time cached token caused avoidable
    /// 401s in long-running app sessions.
    func currentToken() async -> String? {
        do {
            let session = try await client.auth.session
            guard !session.isExpired else {
                accessToken = nil
                isSignedIn = false
                return nil
            }
            accessToken = session.accessToken
            isSignedIn = true
            return session.accessToken
        } catch {
            accessToken = nil
            isSignedIn = false
            return nil
        }
    }
    func currentUserId() async -> String? {
        (try? await client.auth.session)?.user.id.uuidString
    }
}
