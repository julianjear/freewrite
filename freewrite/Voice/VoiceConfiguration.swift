import Foundation

enum VoiceArchitecture: String, Codable, CaseIterable, Identifiable {
    case cascade
    case realtime

    var id: String { rawValue }
    var title: String { self == .cascade ? "STT → LLM → TTS" : "Native voice-to-voice" }
    var summary: String {
        self == .cascade
            ? "Maximum model control and consistent ElevenLabs voice."
            : "Lowest-friction audio understanding and more natural interruption handling."
    }
}

enum VoiceReasoningEffort: String, Codable, CaseIterable, Identifiable {
    case minimal, low, medium
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum VoiceSupervisorEffort: String, Codable, CaseIterable, Identifiable {
    case low, medium, high, xhigh, max
    var id: String { rawValue }
    var title: String { rawValue == "xhigh" ? "X-High" : rawValue.capitalized }
}

enum VoiceTurnStrategy: String, Codable, CaseIterable, Identifiable {
    case livekitAudio = "livekit-audio"
    case flux
    var id: String { rawValue }
    var title: String { self == .livekitAudio ? "LiveKit audio detector" : "Deepgram Flux" }
}

struct VoiceModelProfile: Identifiable, Equatable {
    let id: String
    let architecture: VoiceArchitecture
    let provider: String
    let model: String
    let name: String
    let summary: String
    let latency: String
    let intelligence: String
    let price: String
    let badge: String?

    static let all: [VoiceModelProfile] = [
        .init(id: "cascade-gemini-3.5-flash", architecture: .cascade, provider: "Google", model: "gemini-3.5-flash", name: "Gemini 3.5 Flash", summary: "Best default balance of fast conversation and current Google intelligence.", latency: "Fast at low thinking", intelligence: "Highest cascade default", price: "$1.50 / $9 per 1M text tokens", badge: "Recommended"),
        .init(id: "cascade-gemini-3.1-flash-lite", architecture: .cascade, provider: "Google", model: "gemini-3.1-flash-lite", name: "Gemini 3.1 Flash-Lite", summary: "Very low latency and cost; useful as the speed floor in A/B tests.", latency: "Fastest cascade LLM", intelligence: "Lower", price: "$0.25 / $1.50 per 1M text tokens", badge: nil),
        .init(id: "cascade-gemini-3-flash-preview", architecture: .cascade, provider: "Google", model: "gemini-3-flash-preview", name: "Gemini 3 Flash", summary: "Preview baseline between 2.5 Flash and the newer 3.5 generation.", latency: "Fast", intelligence: "Strong", price: "$0.50 / $3 per 1M text tokens", badge: "Preview"),
        .init(id: "cascade-gemini-2.5-flash", architecture: .cascade, provider: "Google", model: "gemini-2.5-flash", name: "Gemini 2.5 Flash", summary: "The existing production baseline for before-and-after comparison.", latency: "Fast", intelligence: "Baseline", price: "$0.30 / $2.50 per 1M text tokens", badge: "Baseline"),
        .init(id: "cascade-gpt-5.6-terra", architecture: .cascade, provider: "OpenAI", model: "gpt-5.6-terra", name: "GPT-5.6 Terra", summary: "Fast non-reasoning OpenAI alternative with strong instruction following.", latency: "Fast", intelligence: "Strong", price: "$2.50 / $15 per 1M text tokens", badge: nil),
        .init(id: "cascade-claude-haiku-4.5", architecture: .cascade, provider: "Anthropic", model: "claude-haiku-4-5", name: "Claude Haiku 4.5", summary: "Conversational tone and control test; less raw reasoning than the leaders.", latency: "Fast", intelligence: "Moderate", price: "$1 / $5 per 1M text tokens", badge: nil),
        .init(id: "realtime-gpt-2.1", architecture: .realtime, provider: "OpenAI", model: "gpt-realtime-2.1", name: "GPT-Realtime 2.1", summary: "Current quality leader for native speech reasoning, tools, and interruption handling.", latency: "Sub-second target", intelligence: "Highest native voice", price: "$32 / $64 per 1M audio tokens", badge: "Recommended"),
        .init(id: "realtime-gpt-2.1-mini", architecture: .realtime, provider: "OpenAI", model: "gpt-realtime-2.1-mini", name: "GPT-Realtime 2.1 Mini", summary: "Cheaper, lighter native voice baseline when absolute quality is not required.", latency: "Sub-second target", intelligence: "Moderate", price: "$10 / $20 per 1M audio tokens", badge: nil),
        .init(id: "realtime-gemini-3.1-flash-live-preview", architecture: .realtime, provider: "Google", model: "gemini-3.1-flash-live-preview", name: "Gemini 3.1 Flash Live", summary: "Expressive native audio; starts by listening, and dynamic prompt updates are limited after turn one.", latency: "Sub-second target", intelligence: "Strong", price: "$3 / $12 per 1M audio tokens", badge: "Preview"),
        .init(id: "realtime-grok-think-fast", architecture: .realtime, provider: "xAI", model: "grok-voice-think-fast-1.0", name: "Grok Voice Think Fast", summary: "High-performing native voice alternative with simple per-minute pricing.", latency: "Sub-second target", intelligence: "Very strong", price: "$0.05 per audio minute", badge: "Experimental"),
    ]

    static func profile(id: String) -> VoiceModelProfile {
        all.first(where: { $0.id == id }) ?? all[0]
    }
}

struct VoiceSessionConfiguration: Codable, Equatable {
    var version = 1
    var profileId = "cascade-gemini-3.5-flash"
    var reasoningEffort: VoiceReasoningEffort = .low
    var supervisorEnabled = true
    var supervisorModel = "gemini-3.1-pro-preview"
    var supervisorEffort: VoiceSupervisorEffort = .high
    var supervisorIntervalSeconds = 30
    var observabilityEnabled = true
    var turnStrategy: VoiceTurnStrategy = .livekitAudio

    var profile: VoiceModelProfile { VoiceModelProfile.profile(id: profileId) }
}

@MainActor
final class VoiceConfigurationStore: ObservableObject {
    @Published var configuration: VoiceSessionConfiguration {
        didSet { save() }
    }

    private let defaultsKey = "voiceSessionConfiguration.v2"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode(VoiceSessionConfiguration.self, from: data),
           VoiceModelProfile.all.contains(where: { $0.id == decoded.profileId }) {
            configuration = decoded
        } else {
            configuration = VoiceSessionConfiguration()
        }
    }

    func selectArchitecture(_ architecture: VoiceArchitecture) {
        guard configuration.profile.architecture != architecture else { return }
        configuration.profileId = architecture == .cascade
            ? "cascade-gemini-3.5-flash"
            : "realtime-gpt-2.1"
        if architecture == .realtime { configuration.turnStrategy = .livekitAudio }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(configuration) else { return }
        defaults.set(data, forKey: defaultsKey)
    }
}
