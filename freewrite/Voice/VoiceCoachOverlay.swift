import SwiftUI

struct VoiceCoachOverlay: View {
    @ObservedObject var manager: VoiceCoachManager
    var colorScheme: ColorScheme
    var onClose: () -> Void

    private var fg: Color { colorScheme == .dark ? Color(white: 0.92) : Color(white: 0.20) }
    private var bg: Color { colorScheme == .dark ? Color(white: 0.09) : Color(white: 0.99) }
    private var isActive: Bool {
        switch manager.phase { case .listening, .speaking: return true; default: return false }
    }

    var body: some View {
        HStack(spacing: 0) {
            ZStack(alignment: .topTrailing) {
                bg.ignoresSafeArea()
                VStack(spacing: 0) {
                    Spacer()
                    Text(statusText)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(isError ? Color.red.opacity(0.85) : fg.opacity(0.55))
                        .padding(.bottom, 36)
                        .animation(.easeInOut(duration: 0.2), value: statusText)

                    VoiceWaveform(level: waveLevel, isActive: isActive, color: fg.opacity(0.85))
                        .frame(height: 72)
                        .frame(maxWidth: 320)
                        .padding(.horizontal, 40)

                    Spacer()

                    HStack(spacing: 28) {
                        circleButton(
                            icon: manager.micMuted ? "mic.slash.fill" : "mic.fill",
                            filled: false,
                            accessibilityLabel: manager.micMuted ? "Unmute microphone" : "Mute microphone"
                        ) { Task { await manager.toggleMute() } }

                        circleButton(icon: "xmark", filled: true, diameter: 64,
                                     accessibilityLabel: "End voice call") {
                            Task { await manager.end(); onClose() }
                        }
                    }
                    .padding(.bottom, 56)
                }
                .padding()

                if manager.activeConfiguration.observabilityEnabled {
                    Button {
                        manager.showsObservability.toggle()
                    } label: {
                        Label(manager.showsObservability ? "Hide console" : "Show console",
                              systemImage: "waveform.path.ecg.rectangle")
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 11).padding(.vertical, 7)
                            .background(fg.opacity(0.07), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(fg.opacity(0.72))
                    .padding(18)
                    .help("Toggle voice metrics, transcript, and strategist briefs")
                }
            }

            if manager.showsObservability && manager.activeConfiguration.observabilityEnabled {
                Divider()
                VoiceObservabilityPanel(manager: manager)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .background(bg)
        .animation(.easeInOut(duration: 0.2), value: manager.showsObservability)
        .onChange(of: manager.phase) { _, p in if case .ended = p { onClose() } }
    }

    /// While the coach speaks we don't poll its track level, so drive a lively
    /// synthetic amplitude; while listening, use the real mic level.
    private var waveLevel: Float {
        switch manager.phase {
        case .speaking: return 0.75
        case .listening: return max(0.15, manager.micLevel)
        default: return 0.0
        }
    }

    private var isError: Bool { if case .error = manager.phase { return true } else { return false } }

    private var statusText: String {
        switch manager.phase {
        case .authenticating: return "Signing in…"
        case .connecting: return "Calling…"
        case .listening: return manager.micMuted ? "Muted" : "Listening…"
        case .speaking: return "Coach is speaking…"
        case .ended, .idle: return ""
        case .error(let m): return m
        }
    }

    @ViewBuilder
    private func circleButton(icon: String, filled: Bool, diameter: CGFloat = 56,
                              accessibilityLabel: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                if filled {
                    Circle().fill(fg)
                } else {
                    Circle().stroke(fg.opacity(0.28), lineWidth: 1.5)
                }
                Image(systemName: icon)
                    .font(.system(size: filled ? 20 : 17, weight: .medium))
                    .foregroundColor(filled ? bg : fg)
            }
            .frame(width: diameter, height: diameter)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .onHover { hovering in
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}
