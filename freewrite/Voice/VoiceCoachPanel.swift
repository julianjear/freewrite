import SwiftUI

/// Jungle-inspired in-panel call surface. Spoken prose and visual artifacts
/// stay separate so the default canvas remains glanceable during a live call.
struct VoiceCoachPanel: View {
    @ObservedObject var manager: VoiceCoachManager
    let colorScheme: ColorScheme
    let startingQuestion: String?
    let chatImages: [AIChatImage]
    let onEnd: () -> Void

    @State private var showsTranscript = false

    private var foreground: Color {
        colorScheme == .dark ? Color(white: 0.92) : Color(white: 0.18)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(manager.elapsedDuration)
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    showsTranscript.toggle()
                } label: {
                    Label(showsTranscript ? "Hide transcript" : "Show transcript",
                          systemImage: showsTranscript ? "eye.slash" : "eye")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 11)
                        .frame(height: 30)
                        .background(Color.secondary.opacity(0.08), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityValue(showsTranscript ? "on" : "off")
                .pointerCursor()

                if manager.activeConfiguration.observabilityEnabled {
                    Button {
                        manager.showsObservability.toggle()
                    } label: {
                        Image(systemName: manager.showsObservability
                              ? "waveform.path.ecg.rectangle.fill"
                              : "waveform.path.ecg.rectangle")
                            .frame(width: 30, height: 30)
                            .background(Color.secondary.opacity(0.08), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Toggle voice observability")
                    .pointerCursor()
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 48)

            Divider()

            if manager.showsObservability && manager.activeConfiguration.observabilityEnabled {
                VoiceObservabilityPanel(manager: manager)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if showsTranscript {
                transcript
            } else {
                canvas
            }

            Divider()

            VStack(spacing: 16) {
                VoiceWaveform(level: waveLevel, isActive: isActive,
                              color: foreground.opacity(0.82))
                    .frame(height: 44)
                    .frame(maxWidth: 300)

                Text(statusText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isError ? Color.red : .secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)

                HStack(spacing: 28) {
                    callButton(
                        icon: manager.micMuted ? "mic.slash.fill" : "mic.fill",
                        label: manager.micMuted ? "Unmute microphone" : "Mute microphone",
                        destructive: false
                    ) {
                        Task { await manager.toggleMute() }
                    }
                    callButton(icon: "phone.down.fill", label: "End call", destructive: true) {
                        Task { await manager.end() }
                    }
                }
            }
            .padding(.vertical, 18)
            .padding(.horizontal, 20)
        }
        .background(
            colorScheme == .dark
                ? Color(red: 0.08, green: 0.10, blue: 0.08)
                : Color(red: 0.96, green: 0.98, blue: 0.93)
        )
        .onChange(of: manager.phase) { _, phase in
            if phase == .ended { onEnd() }
        }
    }

    private var canvas: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let question = currentQuestion {
                    VStack(alignment: .leading, spacing: 9) {
                        Label("Question in focus", systemImage: "questionmark.circle.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text(question)
                            .font(.system(size: 20, weight: .semibold, design: .rounded))
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white.opacity(colorScheme == .dark ? 0.08 : 0.88),
                                in: RoundedRectangle(cornerRadius: 15))
                }

                ForEach(Array(chatImages.suffix(3))) { image in
                    VStack(alignment: .leading, spacing: 8) {
                        if !image.title.isEmpty {
                            Text(image.title)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        if let url = URL(string: image.thumbnailURL.isEmpty
                                         ? image.imageURL : image.thumbnailURL) {
                            AsyncImage(url: url) { phase in
                                switch phase {
                                case .success(let rendered):
                                    rendered.resizable().scaledToFit()
                                case .failure:
                                    Label("Image unavailable", systemImage: "photo")
                                        .frame(maxWidth: .infinity, minHeight: 100)
                                default:
                                    ProgressView().frame(maxWidth: .infinity, minHeight: 100)
                                }
                            }
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white.opacity(colorScheme == .dark ? 0.08 : 0.88),
                                in: RoundedRectangle(cornerRadius: 15))
                }

                ForEach(manager.canvasArtifacts) { artifact in
                    if let image = artifact.image,
                       let url = URL(string: image.thumbnailURL.isEmpty
                                     ? image.imageURL : image.thumbnailURL) {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Shown during this call", systemImage: "photo")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                            AsyncImage(url: url) { phase in
                                switch phase {
                                case .success(let rendered):
                                    rendered.resizable().scaledToFit()
                                case .failure:
                                    Label("Image unavailable", systemImage: "photo")
                                        .frame(maxWidth: .infinity, minHeight: 100)
                                default:
                                    ProgressView().frame(maxWidth: .infinity, minHeight: 100)
                                }
                            }
                            if !image.title.isEmpty {
                                Text(image.title)
                                    .font(.system(size: 11, weight: .medium))
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.white.opacity(colorScheme == .dark ? 0.08 : 0.88),
                                    in: RoundedRectangle(cornerRadius: 15))
                    }
                }

                if currentQuestion == nil && chatImages.isEmpty && manager.canvasArtifacts.isEmpty {
                    ContentUnavailableView(
                        "Live canvas",
                        systemImage: "sparkles.rectangle.stack",
                        description: Text("The question in focus and useful visual references appear here. Turn on the transcript whenever you want the spoken text.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 260)
                }
            }
            .padding(18)
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(manager.transcript) { line in
                        Text(line.text)
                            .font(.system(size: 14))
                            .padding(.horizontal, 13)
                            .padding(.vertical, 9)
                            .background(
                                line.speaker == "You"
                                    ? Color.accentColor.opacity(0.12)
                                    : Color.white.opacity(colorScheme == .dark ? 0.08 : 0.86),
                                in: UnevenRoundedRectangle(
                                    topLeadingRadius: 14,
                                    bottomLeadingRadius: line.speaker == "You" ? 14 : 3,
                                    bottomTrailingRadius: line.speaker == "You" ? 3 : 14,
                                    topTrailingRadius: 14
                                )
                            )
                            .frame(maxWidth: 460,
                                   alignment: line.speaker == "You" ? .trailing : .leading)
                            .frame(maxWidth: .infinity,
                                   alignment: line.speaker == "You" ? .trailing : .leading)
                            .id(line.id)
                    }
                }
                .padding(18)
            }
            .onChange(of: manager.transcript.count) { _, _ in
                if let id = manager.transcript.last?.id {
                    proxy.scrollTo(id, anchor: .bottom)
                }
            }
        }
    }

    private var currentQuestion: String? {
        if let latest = manager.transcript.reversed().first(where: {
            $0.speaker == "Coach" && $0.text.contains("?")
        }) {
            return latest.text
        }
        return startingQuestion
    }

    private var isActive: Bool {
        manager.phase == .listening || manager.phase == .speaking
    }

    private var waveLevel: Float {
        switch manager.phase {
        case .speaking: return 0.75
        case .listening: return max(0.15, manager.micLevel)
        default: return 0
        }
    }

    private var isError: Bool {
        if case .error = manager.phase { return true }
        return false
    }

    private var statusText: String {
        switch manager.phase {
        case .idle: return "Ready"
        case .authenticating: return "Signing in…"
        case .connecting: return "Calling…"
        case .listening: return manager.micMuted ? "Muted" : "Listening…"
        case .speaking: return "Freewrite AI is speaking…"
        case .ended: return "Call ended"
        case .error(let message): return message
        }
    }

    private func callButton(icon: String, label: String, destructive: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 58, height: 58)
                .background(destructive ? Color.red : Color.green, in: Circle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .pointerCursor()
    }
}
