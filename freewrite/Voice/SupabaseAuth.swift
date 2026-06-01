import Foundation
import AppKit
import Supabase

@MainActor
final class SupabaseAuth: ObservableObject {
    static let shared = SupabaseAuth()

    // Supabase project (publishable key — safe to ship in the client).
    private let client = SupabaseClient(
        supabaseURL: URL(string: "https://glzxxdwlsttayuoajycq.supabase.co")!,
        supabaseKey: "sb_publishable_UmMcVy-1CFwG-AT6kyzRyw_hq89U1Ie"
    )

    @Published var accessToken: String?
    @Published var isSignedIn = false

    // Lets start() await the OAuth deep-link callback instead of returning early.
    private var pendingSignIn: CheckedContinuation<Void, Error>?

    /// Expose the client so the transcript store can insert rows under RLS.
    var supabase: SupabaseClient { client }

    func restore() async {
        if let session = try? await client.auth.session {
            accessToken = session.accessToken
            isSignedIn = true
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

    func currentToken() -> String? { accessToken }
    func currentUserId() async -> String? {
        (try? await client.auth.session)?.user.id.uuidString
    }
}
