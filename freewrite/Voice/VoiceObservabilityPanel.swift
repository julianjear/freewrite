import SwiftUI

struct VoiceObservabilityPanel: View {
    @ObservedObject var manager: VoiceCoachManager
    @State private var tab: Tab = .events

    enum Tab: String, CaseIterable, Identifiable {
        case events = "Events"
        case transcript = "Transcript"
        case strategy = "Strategy"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Voice console").font(.headline)
                    Spacer()
                    Text(manager.activeConfiguration.profile.model)
                        .font(.caption2.monospaced()).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                HStack(spacing: 18) {
                    stat("Events", "\(manager.telemetryEvents.count)")
                    stat("Est. cost", manager.totalEstimatedCost > 0
                         ? String(format: "$%.5f", manager.totalEstimatedCost) : "—",
                         help: manager.estimatedCostHelp)
                    stat("Duration", manager.elapsedDuration)
                }
                Picker("Console view", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .padding(16)

            Divider()

            switch tab {
            case .events: events
            case .transcript: transcript
            case .strategy: strategy
            }
        }
        .frame(width: 410)
        .background(.regularMaterial)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Voice observability console")
    }

    private func stat(_ label: String, _ value: String, help: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.callout.monospacedDigit().weight(.semibold))
                .help(help ?? label)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var events: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(manager.telemetryEvents) { event in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(event.eventType.uppercased())
                                    .font(.caption2.monospaced().weight(.bold))
                                    .foregroundStyle(color(for: event.eventType))
                                Text(event.stage).font(.caption.monospaced()).lineLimit(1)
                                Spacer()
                                Text(shortTime(event.timestamp)).font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            if let summary = eventSummary(event) {
                                Text(summary).font(.caption).foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .help(eventHover(event))
                        .id(event.id)
                        Divider().padding(.leading, 14)
                    }
                }
            }
            .onChange(of: manager.telemetryEvents.count) { _, _ in
                if let id = manager.telemetryEvents.last?.id { proxy.scrollTo(id, anchor: .bottom) }
            }
        }
    }

    private var transcript: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if manager.transcript.isEmpty {
                    Text("Final transcript turns will appear here.")
                        .font(.callout).foregroundStyle(.secondary).padding(16)
                }
                ForEach(manager.transcript) { line in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(line.speaker.uppercased()).font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                        Text(line.text).font(.callout).textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(16)
        }
    }

    private var strategy: some View {
        ScrollView {
            if let event = manager.telemetryEvents.last(where: { $0.eventType == "supervisor" }) {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 18) {
                        strategyField("Model", event.detail["model"])
                        strategyField("Effort", event.detail["effort"])
                    }
                    strategyField("Context delivery", event.detail["contextDelivery"])
                    strategyField("Analysis latency", formattedMilliseconds(event.detail["analysisDuration"]))
                    strategyField("Estimated cost", formattedCost(event.detail["estimatedCostUSD"]))
                    strategyField("Summary", event.detail["summary"])
                    strategyField("Themes", event.detail["themes"])
                    strategyField("Direction", event.detail["direction"])
                    strategyField("Recommended next move", event.detail["recommended_next_move"])
                    strategyField("Candidate questions", event.detail["candidate_questions"])
                    strategyField("Risks", event.detail["risks"])
                    strategyField("Confidence", event.detail["confidence"])
                    Text("This structured brief is the strategist output that is passed to the conversational model. Hidden chain-of-thought is neither requested nor stored.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(16)
            } else {
                Text(manager.activeConfiguration.supervisorEnabled
                     ? "The first background brief appears after new conversation and the configured interval."
                     : "Background strategy is disabled for this call.")
                    .font(.callout).foregroundStyle(.secondary).padding(16)
            }
        }
    }

    private func formattedMilliseconds(_ value: VoiceJSONValue?) -> VoiceJSONValue? {
        guard let seconds = value?.doubleValue else { return nil }
        return .string(String(format: "%.0f ms", seconds * 1000))
    }

    private func formattedCost(_ value: VoiceJSONValue?) -> VoiceJSONValue? {
        guard let cost = value?.doubleValue else { return nil }
        return .string(String(format: "$%.6f", cost))
    }

    @ViewBuilder
    private func strategyField(_ title: String, _ value: VoiceJSONValue?) -> some View {
        if let rendered = render(value) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(rendered).font(.callout).textSelection(.enabled)
            }
        }
    }

    private func render(_ value: VoiceJSONValue?) -> String? {
        guard let value else { return nil }
        switch value {
        case .string(let text): return text
        case .number(let number): return String(format: "%.2f", number)
        case .bool(let flag): return flag ? "Yes" : "No"
        case .array(let items):
            let rendered = items.compactMap { render($0) }
            return rendered.isEmpty ? nil : "• " + rendered.joined(separator: "\n• ")
        case .object: return "Structured data"
        case .null: return nil
        }
    }

    private func eventSummary(_ event: VoiceTelemetryEvent) -> String? {
        if let message = event.detail["message"]?.stringValue { return message }
        if let text = event.detail["text"]?.stringValue { return text }
        if let duration = event.detail["duration"]?.doubleValue {
            var parts = [String(format: "%.0f ms", duration * 1000)]
            if let ttft = event.detail["ttft"]?.doubleValue, ttft >= 0 {
                parts.append(String(format: "TTFT %.0f ms", ttft * 1000))
            }
            if let ttfb = event.detail["ttfb"]?.doubleValue { parts.append(String(format: "TTFB %.0f ms", ttfb * 1000)) }
            if let cost = event.estimatedCostUSD { parts.append(String(format: "$%.6f", cost)) }
            return parts.joined(separator: " · ")
        }
        if let e2e = event.detail["e2e_latency"]?.doubleValue {
            var parts = [String(format: "E2E %.0f ms", e2e * 1000)]
            if let turn = event.detail["end_of_turn_delay"]?.doubleValue {
                parts.append(String(format: "EOT %.0f ms", turn * 1000))
            }
            if let ttft = event.detail["llm_node_ttft"]?.doubleValue {
                parts.append(String(format: "LLM %.0f ms", ttft * 1000))
            }
            if let ttfb = event.detail["tts_node_ttfb"]?.doubleValue {
                parts.append(String(format: "TTS %.0f ms", ttfb * 1000))
            }
            return parts.joined(separator: " · ")
        }
        if let cost = event.estimatedCostUSD {
            return String(format: "Estimated cumulative cost $%.6f", cost)
        }
        if let status = event.detail["status"]?.stringValue { return status }
        if let model = event.detail["model"]?.stringValue { return model }
        return nil
    }

    private func eventHover(_ event: VoiceTelemetryEvent) -> String {
        var parts = ["\(event.eventType.uppercased()) · \(event.stage)"]
        if let tokens = event.tokenBreakdownDescription { parts.append(tokens) }
        if let costs = event.costBreakdownDescription { parts.append(costs) }
        else if let cost = event.estimatedCostUSD {
            parts.append(String(format: "Estimated cost: $%.6f", cost))
        }
        return parts.joined(separator: "\n\n")
    }

    private func shortTime(_ value: String) -> String {
        let precise = ISO8601DateFormatter()
        precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = precise.date(from: value) ?? ISO8601DateFormatter().date(from: value)
        guard let date else { return "" }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    private func color(for type: String) -> Color {
        switch type {
        case "error": return .red
        case "metric": return .blue
        case "supervisor": return .purple
        case "config": return .green
        default: return .secondary
        }
    }
}
