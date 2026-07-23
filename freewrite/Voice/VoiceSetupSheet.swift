import SwiftUI

struct VoiceSetupSheet: View {
    @ObservedObject var store: VoiceConfigurationStore
    let onStart: (VoiceSessionConfiguration) -> Void
    @Environment(\.dismiss) private var dismiss

    private var configuration: Binding<VoiceSessionConfiguration> {
        $store.configuration
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Voice lab").font(.title2.weight(.semibold))
                    Text("Choose the pipeline before starting this call.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(24)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    section("Architecture") {
                        Picker("Architecture", selection: Binding(
                            get: { store.configuration.profile.architecture },
                            set: { store.selectArchitecture($0) }
                        )) {
                            ForEach(VoiceArchitecture.allCases) { architecture in
                                Text(architecture.title).tag(architecture)
                            }
                        }
                        .pickerStyle(.segmented)
                        Text(store.configuration.profile.architecture.summary)
                            .font(.callout).foregroundStyle(.secondary)
                    }

                    section("Conversation model") {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)], spacing: 12) {
                            ForEach(VoiceModelProfile.all.filter {
                                $0.architecture == store.configuration.profile.architecture
                            }) { profile in
                                modelCard(profile)
                            }
                        }
                    }

                    section("Latency and turn-taking") {
                        Picker("Fast-model thinking", selection: configuration.reasoningEffort) {
                            ForEach(VoiceReasoningEffort.allCases) { effort in
                                Text(effort.title).tag(effort)
                            }
                        }
                        .pickerStyle(.segmented)

                        if store.configuration.profile.architecture == .cascade {
                            Picker("End-of-turn detector", selection: configuration.turnStrategy) {
                                ForEach(VoiceTurnStrategy.allCases) { strategy in
                                    Text(strategy.title).tag(strategy)
                                }
                            }
                            Text(store.configuration.turnStrategy == .livekitAudio
                                 ? "Recommended: Nova-3 transcription plus LiveKit's acoustic and semantic turn detector."
                                 : "Experimental: Flux replaces Nova-3 and owns end-of-turn detection. English only in this test profile.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }

                    section("Background strategist") {
                        Toggle("Enable slower conversation analysis", isOn: configuration.supervisorEnabled)
                        if store.configuration.supervisorEnabled {
                            Picker("Strategist model", selection: configuration.supervisorModel) {
                                Text("Gemini 3.1 Pro Preview").tag("gemini-3.1-pro-preview")
                                Text("Gemini 3.5 Flash").tag("gemini-3.5-flash")
                                Text("Claude Sonnet 5").tag("claude-sonnet-5")
                                Text("Claude Opus 4.8").tag("claude-opus-4-8")
                                Text("GPT-5.6 Sol").tag("gpt-5.6-sol")
                            }
                            .onChange(of: store.configuration.supervisorModel) { _, model in
                                if model.hasPrefix("gemini-") && [.xhigh, .max].contains(store.configuration.supervisorEffort) {
                                    store.configuration.supervisorEffort = .high
                                }
                            }
                            Picker("Thinking effort", selection: configuration.supervisorEffort) {
                                ForEach(VoiceSupervisorEffort.allCases.filter {
                                    !store.configuration.supervisorModel.hasPrefix("gemini-") || [.low, .medium, .high].contains($0)
                                }) { effort in
                                    Text(effort.title).tag(effort)
                                }
                            }
                            Picker("Refresh cadence", selection: configuration.supervisorIntervalSeconds) {
                                Text("15 seconds").tag(15)
                                Text("20 seconds").tag(20)
                                Text("30 seconds").tag(30)
                            }
                            Text("Runs every 30 seconds by default, off the live path. Its structured brief is shown in the console and embedded into the next response context. Gemini Live uses the same brief through a tool because its instructions cannot be reliably changed after turn one.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }

                    section("Developer console") {
                        Toggle("Stream metrics, transcripts, costs, and strategy briefs into the call UI",
                               isOn: configuration.observabilityEnabled)
                    }
                }
                .padding(24)
            }

            Divider()
            HStack {
                let selected = store.configuration.profile
                Text("\(selected.provider) · \(selected.model)")
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                Spacer()
                Button("Start voice call") {
                    let value = store.configuration
                    dismiss()
                    onStart(value)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(18)
        }
        .frame(minWidth: 760, idealWidth: 860, minHeight: 640, idealHeight: 760)
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content()
        }
    }

    private func modelCard(_ profile: VoiceModelProfile) -> some View {
        let selected = profile.id == store.configuration.profileId
        return Button {
            store.configuration.profileId = profile.id
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(profile.name).font(.headline)
                    Spacer()
                    if let badge = profile.badge {
                        Text(badge).font(.caption2.weight(.semibold))
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(.secondary.opacity(0.12), in: Capsule())
                    }
                }
                Text(profile.summary).font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 12) {
                    Label(profile.latency, systemImage: "bolt")
                    Label(profile.intelligence, systemImage: "brain")
                }
                .font(.caption)
                Text(profile.price).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 154, alignment: .topLeading)
            .background(selected ? Color.accentColor.opacity(0.10) : Color.secondary.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(selected ? Color.accentColor : Color.secondary.opacity(0.14), lineWidth: selected ? 2 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(profile.name), \(profile.summary), \(profile.price)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
