import SwiftUI

/// Compact version of the voice lab that lives in the same surface as chat.
/// The owning panel remains responsible for expansion, dismissal, and start.
struct VoiceSetupPanel: View {
    @ObservedObject var store: VoiceConfigurationStore
    let startingQuestion: String?
    let onCancel: () -> Void
    let onStart: (VoiceSessionConfiguration) -> Void

    private var configuration: Binding<VoiceSessionConfiguration> {
        $store.configuration
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: onCancel) {
                    Label("Back to chat", systemImage: "chevron.left")
                }
                .buttonStyle(.plain)
                .pointerCursor()
                Spacer()
                Text("Voice lab")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Color.clear.frame(width: 78, height: 1)
            }
            .padding(.horizontal, 16)
            .frame(height: 48)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if let startingQuestion, !startingQuestion.isEmpty {
                        VStack(alignment: .leading, spacing: 7) {
                            Label("Starting point", systemImage: "questionmark.circle.fill")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Text(startingQuestion)
                                .font(.system(size: 15, weight: .medium))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    }

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
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    section("Conversation model") {
                        Picker("Model", selection: configuration.profileId) {
                            ForEach(VoiceModelProfile.all.filter {
                                $0.architecture == store.configuration.profile.architecture
                            }) { profile in
                                Text(profile.name).tag(profile.id)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        let selected = store.configuration.profile
                        Text(selected.summary)
                            .font(.callout)
                        HStack(spacing: 14) {
                            Label(selected.latency, systemImage: "bolt")
                            Label(selected.intelligence, systemImage: "brain")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        Text(selected.price)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
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
                                 ? "Nova-3 transcription with LiveKit acoustic and semantic turn detection."
                                 : "Experimental Flux transcription and turn detection. English only in this profile.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    section("Background strategist") {
                        Toggle("Enable slower conversation analysis", isOn: configuration.supervisorEnabled)
                        if store.configuration.supervisorEnabled {
                            Picker("Strategist", selection: configuration.supervisorModel) {
                                Text("Gemini 3.1 Pro Preview").tag("gemini-3.1-pro-preview")
                                Text("Gemini 3.5 Flash").tag("gemini-3.5-flash")
                                Text("Claude Sonnet 5").tag("claude-sonnet-5")
                                Text("Claude Opus 4.8").tag("claude-opus-4-8")
                                Text("GPT-5.6 Sol").tag("gpt-5.6-sol")
                            }
                            Picker("Thinking effort", selection: configuration.supervisorEffort) {
                                ForEach(VoiceSupervisorEffort.allCases.filter {
                                    !store.configuration.supervisorModel.hasPrefix("gemini-")
                                        || [.low, .medium, .high].contains($0)
                                }) { effort in
                                    Text(effort.title).tag(effort)
                                }
                            }
                            Text("Runs every 30 seconds and injects its observable brief into the next voice response.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Toggle("Show voice observability", isOn: configuration.observabilityEnabled)
                }
                .padding(18)
            }

            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.configuration.profile.name)
                        .font(.system(size: 11, weight: .semibold))
                    Text("Chat history and the current note will come with you.")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Start call") {
                    onStart(store.configuration)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .pointerCursor()
            }
            .padding(14)
        }
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.system(size: 12, weight: .semibold))
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
