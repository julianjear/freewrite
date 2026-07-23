import Foundation

struct VoiceSessionToken {
    let token: String
    let wsURL: URL
    let sessionId: String
}

enum VoiceTokenError: Error {
    case notAuthenticated
    case badResponse(Int, String?)
    case badURL
}

struct VoiceTokenClient {
    static var workerBaseURL: URL {
        let environment = ProcessInfo.processInfo.environment["FREEWRITE_VOICE_TOKEN_URL"]
        let defaults = UserDefaults.standard.string(forKey: "voiceTokenBaseURL")
        return URL(string: environment ?? defaults ?? "https://freewrite-voice-token.infinite-0b9.workers.dev")!
    }

    func mint(context: VoiceContext, entryId: String?, configuration: VoiceSessionConfiguration,
              accessToken: String?) async throws -> VoiceSessionToken {
        guard let accessToken else { throw VoiceTokenError.notAuthenticated }
        var req = URLRequest(url: Self.workerBaseURL.appendingPathComponent("voice/token"))
        req.httpMethod = "POST"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        struct Body: Encodable {
            let context: VoiceContext
            let entryId: String?
            let voiceConfig: VoiceSessionConfiguration
        }
        req.httpBody = try JSONEncoder().encode(
            Body(context: context, entryId: entryId, voiceConfig: configuration)
        )

        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else {
            struct ErrorBody: Decodable { let error: String }
            let message = try? JSONDecoder().decode(ErrorBody.self, from: data).error
            throw VoiceTokenError.badResponse(status, message)
        }
        struct R: Decodable { let token: String; let wsUrl: String; let sessionId: String }
        let r = try JSONDecoder().decode(R.self, from: data)
        guard let url = URL(string: r.wsUrl) else { throw VoiceTokenError.badURL }
        return VoiceSessionToken(token: r.token, wsURL: url, sessionId: r.sessionId)
    }
}
