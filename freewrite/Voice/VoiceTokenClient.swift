import Foundation

struct VoiceSessionToken {
    let token: String
    let wsURL: URL
    let sessionId: String
}

enum VoiceTokenError: Error { case notAuthenticated, badResponse(Int), badURL }

struct VoiceTokenClient {
    // Set to your deployed Worker, e.g. https://freewrite-voice-token.<you>.workers.dev
    static let workerBaseURL = URL(string: "https://YOUR-WORKER.workers.dev")!

    func mint(context: VoiceContext, entryId: String?, accessToken: String?) async throws -> VoiceSessionToken {
        guard let accessToken else { throw VoiceTokenError.notAuthenticated }
        var req = URLRequest(url: Self.workerBaseURL.appendingPathComponent("voice/token"))
        req.httpMethod = "POST"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = [
            "context": try JSONSerialization.jsonObject(with: JSONEncoder().encode(context))
        ]
        if let entryId { body["entryId"] = entryId }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else { throw VoiceTokenError.badResponse(status) }
        struct R: Decodable { let token: String; let wsUrl: String; let sessionId: String }
        let r = try JSONDecoder().decode(R.self, from: data)
        guard let url = URL(string: r.wsUrl) else { throw VoiceTokenError.badURL }
        return VoiceSessionToken(token: r.token, wsURL: url, sessionId: r.sessionId)
    }
}
