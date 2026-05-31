import SwiftUI

/// Continuously-animated voice visualization. Center-biased bars that are always
/// gently in motion (via TimelineView), with height driven by `level`. A frozen
/// bar row reads as "broken", so we always animate while `isActive`.
struct VoiceWaveform: View {
    var level: Float          // 0...1 current amplitude
    var isActive: Bool        // true while connected (listening or speaking)
    var color: Color
    private let barCount = 24

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let barWidth: CGFloat = 4
                let gap = (size.width - CGFloat(barCount) * barWidth) / CGFloat(barCount - 1)
                let midY = size.height / 2

                for i in 0..<barCount {
                    let x = CGFloat(i) * (barWidth + gap)
                    // Taller toward the middle for an organic, voice-like shape.
                    let dist = abs(CGFloat(i) - CGFloat(barCount - 1) / 2) / (CGFloat(barCount) / 2)
                    let centerBias = 1 - dist
                    // Per-bar travelling wave so the row is never static.
                    let phase = Double(i) * 0.45
                    let wave = (sin(t * 3.0 + phase) + 1) / 2          // 0...1
                    let amp = CGFloat(isActive ? max(0.12, Double(level)) : 0.05)
                    let h = 4 + size.height * 0.92 * amp * centerBias * (0.4 + 0.6 * CGFloat(wave))

                    let rect = CGRect(x: x, y: midY - h / 2, width: barWidth, height: h)
                    context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2),
                                 with: .color(color))
                }
            }
        }
    }
}
