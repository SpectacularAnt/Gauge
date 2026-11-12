import SwiftUI

/// A thin filled bar, used everywhere a value has a natural maximum.
struct Bar: View {
    let fraction: Double
    var tint: Color = .accentColor
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.1))
                Capsule()
                    .fill(tint)
                    .frame(width: max(0, min(fraction, 1)) * geometry.size.width)
            }
        }
        .frame(height: height)
    }
}

/// A label on the left, a value on the right, and a bar underneath.
struct LabeledBar: View {
    let label: String
    let value: String
    let fraction: Double
    var tint: Color = .accentColor

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label)
                    .font(.system(size: 11))
                Spacer()
                Text(value)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .monospacedDigit()
            }
            Bar(fraction: fraction, tint: tint)
        }
    }
}

/// A plain key and value line.
struct StatRow: View {
    let label: String
    let value: String
    var emphasised = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 11, weight: emphasised ? .semibold : .regular))
                .monospacedDigit()
        }
    }
}

/// A titled block with a faint background, so the panel reads as a stack of
/// cards rather than one long list.
struct Card<Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var content: Content
    @Environment(\.prominentCardTitles) private var prominent

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if prominent {
                    Text(title)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.primary)
                } else {
                    Text(title.uppercased())
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .tracking(0.6)
                }
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
            content
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Settings is mostly switches with a line of small print under some of them,
/// and small capitals for the card titles made the two look alike. There,
/// titles are drawn as proper headings instead.
private struct ProminentCardTitlesKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var prominentCardTitles: Bool {
        get { self[ProminentCardTitlesKey.self] }
        set { self[ProminentCardTitlesKey.self] = newValue }
    }
}

/// One short vertical bar per core, so a glance shows whether load is spread
/// across the chip or stuck on a single core.
struct CoreBars: View {
    let values: [Double]
    let label: String
    var tint: Color = .accentColor

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(tint)
                    .frame(width: 6, height: 6)
                Text(label)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Color.primary.opacity(0.1))
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(tint)
                            .frame(height: max(1, min(value, 1) * 26))
                    }
                    .frame(width: 7, height: 26)
                }
            }
        }
    }
}

/// Shared colour scale: calm when there is headroom, warm as it runs out.
enum Severity {
    static func tint(for fraction: Double) -> Color {
        switch fraction {
        case ..<0.6:  return .green
        case ..<0.8:  return .yellow
        case ..<0.92: return .orange
        default:      return .red
        }
    }

    /// Chip temperatures idle in the thirties and throttle near a hundred, so
    /// the scale is stretched over that range rather than over 0–100%.
    static func temperatureTint(celsius: Double) -> Color {
        tint(for: (celsius - 30) / 65)
    }
}
