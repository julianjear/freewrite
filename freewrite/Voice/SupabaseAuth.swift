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
    private var pendingSignIn: CheckedContinuation<Void, Error>?

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
        let url = try client.auth.getOAuthSignInURL(
            provider: .google,
            redirectTo: URL(string: "freewrite://auth-callback")!
        )
        NSWorkspace.shared.open(url)

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.pendingSignIn = cont
            // Safety timeout so the UI doesn't hang forever if the user bails.
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 180 * 1_000_000_000)
                guard let self, let pending = self.pendingSignIn else { return }
                self.pendingSignIn = nil
                pending.resume(throwing: URLError(.timedOut))
            }
        }
    }

    /// Called from freewriteApp's .onOpenURL when the browser redirects back.
    func handleCallback(url: URL) async {
        do {
            let session = try await client.auth.session(from: url)
            accessToken = session.accessToken
            isSignedIn = true
            pendingSignIn?.resume(); pendingSignIn = nil
        } catch {
            pendingSignIn?.resume(throwing: error); pendingSignIn = nil
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
