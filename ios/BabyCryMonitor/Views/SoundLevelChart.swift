import SwiftUI

/// Shared by both phones so the scale, bars, threshold, and accessibility match.
struct SoundLevelChart: View {
    let levels: [Double]
    let trigger: Double
    let currentLevel: Double
    let monitoring: Bool
    var height: CGFloat = 88
    var color: Color = Palette.mint

    var body: some View {
        VStack(spacing: 12) {
            GeometryReader { geometry in
                let triggerHeight = levelHeight(trigger, in: geometry.size.height)
                ZStack(alignment: .bottom) {
                    HStack(alignment: .bottom, spacing: 4) {
                        ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                            let barHeight = max(3, levelHeight(level, in: geometry.size.height))
                            Capsule()
                                .fill(color.opacity(monitoring ? 0.65 : 0.2))
                                .overlay(alignment: .top) {
                                    if monitoring, level >= trigger {
                                        Rectangle()
                                            .fill(Palette.amber.opacity(0.8))
                                            .frame(height: max(0, barHeight - triggerHeight))
                                    }
                                }
                                .clipShape(Capsule())
                                .frame(maxWidth: .infinity)
                                .frame(height: barHeight)
                        }
                    }
                    thresholdLine(trigger, color: Palette.amber, dash: [6, 4], size: geometry.size)
                }
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .bottom)
                .clipped()
            }
            .frame(height: height)

            ViewThatFits(in: .horizontal) {
                HStack {
                    Text(monitoring ? "Current \(levelText(currentLevel))" : "Inactive")
                        .font(.caption.monospacedDigit()).foregroundStyle(Palette.muted)
                    Spacer(minLength: 12)
                    thresholdLabel("Trigger", value: trigger, color: Palette.amber, dash: [6, 4])
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(monitoring ? "Current \(levelText(currentLevel))" : "Inactive")
                        .font(.caption.monospacedDigit()).foregroundStyle(Palette.muted)
                    thresholdLabel("Trigger", value: trigger, color: Palette.amber, dash: [6, 4])
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("soundLevelChart")
        .accessibilityLabel("Live sound level")
        .accessibilityValue("\(monitoring ? levelText(currentLevel) : "Inactive"). Trigger \(levelText(trigger)).")
    }

    // Bars and guides share a bottom-aligned, full microphone scale of -100…0 dBFS.
    private func levelHeight(_ level: Double, in height: CGFloat) -> CGFloat {
        let clamped = min(0, max(-100, level.isFinite ? level : -100))
        return CGFloat((clamped + 100) / 100) * height
    }

    private func thresholdLine(_ level: Double, color: Color, dash: [CGFloat], size: CGSize) -> some View {
        Path { path in
            let y = min(size.height - 0.5, max(0.5, size.height - levelHeight(level, in: size.height)))
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
        }
        .stroke(color.opacity(monitoring ? 0.65 : 0.4), style: StrokeStyle(lineWidth: 1, dash: dash))
    }

    private func thresholdLabel(_ title: String, value: Double, color: Color, dash: [CGFloat]) -> some View {
        HStack(spacing: 6) {
            Path { path in
                path.move(to: CGPoint(x: 0, y: 1))
                path.addLine(to: CGPoint(x: 16, y: 1))
            }
            .stroke(color.opacity(0.8), style: StrokeStyle(lineWidth: 1, dash: dash))
            .frame(width: 16, height: 2)
            Text("\(title) \(levelText(value))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(color)
                .fixedSize()
        }
    }

    private func levelText(_ level: Double) -> String {
        String(format: "%.0f dBFS", level)
    }
}
