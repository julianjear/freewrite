import Foundation
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

    /// Expose the client so the transcript store can insert rows under RLS.
    var supabase: SupabaseClient { client }

    func restore() async {
        if let session = try? await client.auth.session {
            accessToken = session.accessToken
            isSignedIn = true
        }
    }

    /// Opens Google OAuth in the system browser; redirect scheme freewrite://auth-callback
    func signInWithGoogle() async throws {
        let session = try await client.auth.signInWithOAuth(
            provider: .google,
            redirectTo: URL(string: "freewrite://auth-callback")!
        )
        accessToken = session.accessToken
        isSignedIn = true
    }

    func handleCallback(url: URL) async {
        try? await client.auth.session(from: url)
        if let session = try? await client.auth.session {
            accessToken = session.accessToken
            isSignedIn = true
        }
    }

    func currentToken() -> String? { accessToken }
    func currentUserId() async -> String? {
        (try? await client.auth.session)?.user.id.uuidString
    }
}
