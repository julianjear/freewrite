import Foundation

struct VoiceCanvasImage: Codable, Equatable {
    let title: String
    let imageURL: String
    let thumbnailURL: String
    let sourceURL: String
}

struct VoiceCanvasArtifact: Codable, Identifiable, Equatable {
    let version: Int
    let sessionId: String
    let id: String
    let kind: String
    let image: VoiceCanvasImage?
    let question: String?
}

enum VoiceJSONValue: Codable, Equatable {
    case string(String), number(Double), bool(Bool), object([String: VoiceJSONValue])
    case array([VoiceJSONValue]), null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: VoiceJSONValue].self) { self = .object(value) }
        else { self = .array(try container.decode([VoiceJSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var stringValue: String? {
        switch self {
        case .string(let value): return value
        case .number(let value): return String(format: "%.4f", value)
        case .bool(let value): return value ? "true" : "false"
        default: return nil
        }
    }

    var doubleValue: Double? { if case .number(let value) = self { return value }; return nil }
    var boolValue: Bool? { if case .bool(let value) = self { return value }; return nil }
}

struct VoiceTelemetryEvent: Codable, Identifiable, Equatable {
    let version: Int
    let id: String
    let sequence: Int
    let sessionId: String
    let eventType: String
    let stage: String
    let timestamp: String
    let monotonicSeconds: Double
    let detail: [String: VoiceJSONValue]

    var estimatedCostUSD: Double? { detail["estimatedCostUSD"]?.doubleValue }
    var isCumulativeCost: Bool { detail["costKind"]?.stringValue == "cumulative" }
    var fatalErrorMessage: String? {
        guard eventType == "error", let message = detail["message"]?.stringValue else {
            return nil
        }
        if stage == "configuration" {
            return "Coach configuration error: \(message)"
        }
        if stage == "agent-session", detail["recoverable"]?.boolValue != true {
            return "Coach error: \(message)"
        }
        return nil
    }

    var tokenBreakdownDescription: String? {
        var values: [(String, Int)] = []
        Self.collectTokens(in: .object(detail), path: "", into: &values)
        let unique = values.reduce(into: [(String, Int)]()) { result, item in
            guard !result.contains(where: { $0.0 == item.0 }) else { return }
            result.append(item)
        }
        guard !unique.isEmpty else { return nil }
        return unique.prefix(16).map { "\($0.0): \($0.1)" }.joined(separator: "\n")
    }

    var costBreakdownDescription: String? {
        guard case .object(let values) = detail["costBreakdownUSD"] else { return nil }
        let labels = [
            "stt": "Speech-to-text",
            "llmUncachedInput": "LLM uncached input",
            "llmCachedInput": "LLM cached input",
            "llmOutput": "LLM output",
            "tts": "Text-to-speech",
        ]
        let lines = values.compactMap { key, value -> String? in
            guard let number = value.doubleValue else { return nil }
            return String(format: "%@: $%.6f", labels[key] ?? key, number)
        }.sorted()
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    private static func collectTokens(in value: VoiceJSONValue, path: String,
                                      into result: inout [(String, Int)]) {
        switch value {
        case .object(let object):
            for (key, child) in object {
                let next = path.isEmpty ? key : "\(path).\(key)"
                if key.lowercased().contains("token"), let number = child.doubleValue {
                    result.append((next.replacingOccurrences(of: "_", with: " "), Int(number)))
                } else {
                    collectTokens(in: child, path: next, into: &result)
                }
            }
        case .array(let values):
            for value in values { collectTokens(in: value, path: path, into: &result) }
        default:
            break
        }
    }
}

extension Collection where Element == VoiceTelemetryEvent {
    /// Provider stage metrics are also present in the cumulative usage event;
    /// count them only as a fallback, then add independent strategist calls.
    var totalVoiceEstimatedCostUSD: Double {
        let cumulative = self.filter(\.isCumulativeCost).compactMap(\.estimatedCostUSD).max()
        let providerCost = cumulative ?? self
            .filter { $0.eventType == "metric" && !$0.isCumulativeCost }
            .compactMap(\.estimatedCostUSD).reduce(0, +)
        let strategistCost = self
            .filter { $0.eventType == "supervisor" }
            .compactMap(\.estimatedCostUSD).reduce(0, +)
        return providerCost + strategistCost
    }
}
