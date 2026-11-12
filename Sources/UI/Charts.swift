import AppKit
import SwiftUI

// MARK: - Colour

/// Two jobs, kept apart on purpose.
///
/// **Status** colours answer "is this all right?" — they are reserved for load
/// and temperature, and never show up as a series colour. **Series** colours
/// answer "which of these is which?" — they are assigned in a fixed order and
/// never cycled, so a thing keeps its colour as charts change.
///
/// Dark mode is chosen rather than derived: each hue has its own step picked for
/// a dark surface, because simply brightening a light-mode hue washes it out.
enum Palette {
    static let series1 = dynamic(light: "2a78d6", dark: "3987e5")   // blue
    static let series2 = dynamic(light: "eb6834", dark: "d95926")   // orange
    static let series3 = dynamic(light: "1baf7a", dark: "199e70")   // aqua
    /// Not a series colour. Used for the part of a total that is spare capacity
    /// rather than another category — cached memory, free disk space.
    static let neutral = Color.primary.opacity(0.22)

    static func dynamic(light: String, dark: String) -> Color {
        let lightColor = NSColor(hex: light)
        let darkColor = NSColor(hex: dark)
        let resolved = NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return isDark ? darkColor : lightColor
        }
        return Color(nsColor: resolved)
    }
}

extension NSColor {
    convenience init(hex: String) {
        var value: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&value)
        self.init(srgbRed: Double((value >> 16) & 0xff) / 255,
                  green: Double((value >> 8) & 0xff) / 255,
                  blue: Double(value & 0xff) / 255,
                  alpha: 1)
    }
}

// MARK: - Ring gauge

/// A single number that has a natural maximum, drawn as a filled arc.
///
/// The colour carries the verdict, but never alone: the label and the value are
/// always there to read, so the gauge still works if the colours do not.
struct RingGauge: View {
    let label: String
    let value: String
    let fraction: Double
    var tint: Color = .accentColor
    var diameter: CGFloat = 58

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.1), lineWidth: 6)
                Circle()
                    .trim(from: 0, to: max(0.001, min(fraction, 1)))
                    .stroke(tint, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(value)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
            }
            .frame(width: diameter, height: diameter)

            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

// MARK: - Sparkline

/// Recent history as a shape. One series, one hue — the card's title says what
/// it is, so there is nothing to put in a legend.
struct Sparkline: View {
    let values: [Double]
    var tint: Color = Palette.series1
    /// Leave nil to scale to the tallest value in the window.
    var maximum: Double?
    var height: CGFloat = 34
    /// A reading to mark with a dot, while the chart is being scrubbed.
    var highlight: Int?
    /// Readings that follow a gap in the recording. The line is cut before
    /// each of them rather than drawn straight across nothing.
    var breaks: Set<Int> = []

    var body: some View {
        GeometryReader { geometry in
            let scale = ceiling()
            let points = positions(in: geometry.size, scale: scale)
            ZStack {
                if points.count > 1 {
                    area(points, in: geometry.size)
                        .fill(LinearGradient(colors: [tint.opacity(0.28), tint.opacity(0.02)],
                                             startPoint: .top, endPoint: .bottom))
                    line(points)
                        .stroke(tint, style: StrokeStyle(lineWidth: 2, lineJoin: .round))
                    if let highlight, points.indices.contains(highlight) {
                        // A ring of background colour around the dot keeps it
                        // readable where it sits on top of its own line.
                        Circle()
                            .fill(tint)
                            .frame(width: 8, height: 8)
                            .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor),
                                                     lineWidth: 2))
                            .position(points[highlight])
                    }
                } else {
                    Text("collecting\u{2026}")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                }
            }
        }
        .frame(height: height)
    }

    /// Never divide by zero, and never let a flat line of zeroes fill the frame.
    private func ceiling() -> Double {
        if let maximum { return max(maximum, 0.0001) }
        return max(values.max() ?? 1, 0.0001)
    }

    private func positions(in size: CGSize, scale: Double) -> [CGPoint] {
        guard values.count > 1 else { return [] }
        let step = size.width / CGFloat(values.count - 1)
        // A 2pt stroke centred on the top edge would clip, so inset by half of it.
        let top: CGFloat = 1
        let usable = max(size.height - top * 2, 1)
        return values.enumerated().map { index, value in
            let ratio = min(max(value / scale, 0), 1)
            let y = top + usable * CGFloat(1 - ratio)
            return CGPoint(x: CGFloat(index) * step, y: y)
        }
    }

    /// The points split into unbroken stretches, so a gap in the recording
    /// becomes a gap in the drawing rather than a line across it.
    private func runs(_ points: [CGPoint]) -> [[CGPoint]] {
        guard !breaks.isEmpty else { return [points] }
        var result: [[CGPoint]] = []
        var current: [CGPoint] = []
        for (index, point) in points.enumerated() {
            if breaks.contains(index), !current.isEmpty {
                result.append(current)
                current = []
            }
            current.append(point)
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private func line(_ points: [CGPoint]) -> Path {
        var path = Path()
        for run in runs(points) where run.count > 1 {
            path.move(to: run[0])
            for point in run.dropFirst() {
                path.addLine(to: point)
            }
        }
        return path
    }

    private func area(_ points: [CGPoint], in size: CGSize) -> Path {
        var path = Path()
        for run in runs(points) where run.count > 1 {
            path.move(to: CGPoint(x: run[0].x, y: size.height))
            // Each point is joined with addLine rather than handed to addLines:
            // addLines begins a fresh shape at its first point, which would drop
            // the bottom-left corner and close the fill on a diagonal — a wedge
            // that looked thin on the left and full on the right whatever the data.
            for point in run {
                path.addLine(to: point)
            }
            path.addLine(to: CGPoint(x: run[run.count - 1].x, y: size.height))
            path.closeSubpath()
        }
        return path
    }
}

/// Two directions of the same measure, sharing one scale — download above the
/// line, upload below. Same unit on both halves, so there is still only one
/// axis to read.
struct MirroredSparkline: View {
    let upper: [Double]
    let lower: [Double]
    var upperTint: Color = Palette.series1
    var lowerTint: Color = Palette.series2
    var height: CGFloat = 48
    var highlight: Int?
    var breaks: Set<Int> = []

    var body: some View {
        let scale = max(upper.max() ?? 0, lower.max() ?? 0, 1024)
        VStack(spacing: 1) {
            Sparkline(values: upper, tint: upperTint, maximum: scale,
                      height: height / 2, highlight: highlight, breaks: breaks)
            Sparkline(values: lower, tint: lowerTint, maximum: scale,
                      height: height / 2, highlight: highlight, breaks: breaks)
                .scaleEffect(y: -1, anchor: .center)
        }
    }
}

// MARK: - Scrubbing

/// Lets you run the pointer along a chart to find out what was happening, and
/// when.
///
/// A hairline follows the pointer but snaps to the nearest actual reading, so
/// you aim at a moment rather than having to land on a two-point line. The
/// readout floats just above the chart: over the card's heading rather than
/// over the data you are trying to look at. It sits to the right of the
/// pointer on the left half of the chart and to the left on the right half, so
/// it never runs off the edge.
struct ScrubFrame<Chart: View, Readout: View>: View {
    let times: [Date]
    let height: CGFloat
    let chart: (Int?) -> Chart
    let readout: (Int) -> Readout

    @State private var pointerX: CGFloat?

    init(times: [Date],
         height: CGFloat,
         @ViewBuilder chart: @escaping (Int?) -> Chart,
         @ViewBuilder readout: @escaping (Int) -> Readout) {
        self.times = times
        self.height = height
        self.chart = chart
        self.readout = readout
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            // Worked out from where the pointer is rather than remembered, so
            // that as new readings scroll in under a still pointer, the readout
            // keeps describing whatever is under it now.
            let index = nearestIndex(to: pointerX, width: width)
            chart(index)
                .overlay(alignment: .topLeading) {
                    if let index {
                        let x = position(of: index, width: width)
                        Rectangle()
                            .fill(Color.primary.opacity(0.35))
                            .frame(width: 1, height: height)
                            .offset(x: x - 0.5)
                        bubble(for: index, at: x, width: width)
                    }
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location): pointerX = location.x
                    case .ended: pointerX = nil
                    }
                }
        }
        .frame(height: height)
    }

    private func bubble(for index: Int, at x: CGFloat, width: CGFloat) -> some View {
        let onLeftHalf = x < width / 2
        let time = times[index]
        return VStack(alignment: .leading, spacing: 2) {
            readout(index)
            Text("\(Format.clock(time)) \u{00B7} \(Format.ago(time))")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        // Solid rather than frosted: the readout sits over the card's heading,
        // and a translucent one lets that text show through behind the numbers.
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.primary.opacity(0.18), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
        .fixedSize()
        // A zero-sized frame pins one corner of the bubble to a single point;
        // the bubble then grows away from it, up and to whichever side has room.
        .frame(width: 0, height: 0, alignment: onLeftHalf ? .bottomLeading : .bottomTrailing)
        .offset(x: x + (onLeftHalf ? 8 : -8), y: -4)
        .allowsHitTesting(false)
    }

    private func nearestIndex(to x: CGFloat?, width: CGFloat) -> Int? {
        guard let x, times.count > 1, width > 0 else { return nil }
        let step = width / CGFloat(times.count - 1)
        let raw = Int((x / step).rounded())
        return min(max(raw, 0), times.count - 1)
    }

    /// The same spacing `Sparkline` uses, so the hairline lands on the reading.
    private func position(of index: Int, width: CGFloat) -> CGFloat {
        guard times.count > 1 else { return 0 }
        return CGFloat(index) * width / CGFloat(times.count - 1)
    }
}

/// A single trend, scrubbable.
struct ScrubbableSparkline: View {
    let history: History
    var tint: Color = Palette.series1
    var maximum: Double?
    var height: CGFloat = 34
    let format: (Double) -> String

    var body: some View {
        ScrubFrame(times: history.times, height: height) { index in
            Sparkline(values: history.values, tint: tint, maximum: maximum,
                      height: height, highlight: index, breaks: history.breaks)
        } readout: { index in
            // The value leads; the chart's own title already says what it is.
            Text(format(history.values[index]))
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
    }
}

/// Two directions of one measure, scrubbable. The readout always gives both
/// at once, so there is no hunting for the second line.
struct ScrubbableMirroredSparkline: View {
    let upper: History
    let lower: History
    let upperLabel: String
    let lowerLabel: String
    var upperTint: Color = Palette.series1
    var lowerTint: Color = Palette.series2
    var height: CGFloat = 48
    let format: (Double) -> String

    var body: some View {
        ScrubFrame(times: upper.times, height: height) { index in
            MirroredSparkline(upper: upper.values, lower: lower.values,
                              upperTint: upperTint, lowerTint: lowerTint,
                              height: height, highlight: index,
                              breaks: upper.breaks)
        } readout: { index in
            VStack(alignment: .leading, spacing: 2) {
                seriesLine(tint: upperTint, values: upper.values, index: index, label: upperLabel)
                seriesLine(tint: lowerTint, values: lower.values, index: index, label: lowerLabel)
            }
        }
    }

    /// Keyed with a short stroke of the series colour, like the line it names,
    /// rather than a filled box.
    private func seriesLine(tint: Color, values: [Double], index: Int, label: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 1)
                .fill(tint)
                .frame(width: 10, height: 2)
            Text(values.indices.contains(index) ? format(values[index]) : "\u{2013}")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Stacked bar

/// What a total is made of. Segments are separated by a real gap rather than a
/// border, so neighbouring colours never touch and the eye can count them.
struct StackedBar: View {
    struct Segment: Identifiable {
        let label: String
        let bytes: UInt64
        let color: Color
        var id: String { label }
    }

    let segments: [Segment]
    let total: UInt64
    var height: CGFloat = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geometry in
                let gap: CGFloat = 2
                let drawn = segments.filter { $0.bytes > 0 }
                let gaps = CGFloat(max(drawn.count - 1, 0)) * gap
                let usable = max(geometry.size.width - gaps, 1)
                HStack(spacing: gap) {
                    ForEach(drawn) { segment in
                        Capsule()
                            .fill(segment.color)
                            .frame(width: width(for: segment, usable: usable))
                    }
                }
            }
            .frame(height: height)

            // Every segment is named and valued, so identity never rests on
            // colour alone.
            VStack(alignment: .leading, spacing: 2) {
                ForEach(segments) { segment in
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(segment.color)
                            .frame(width: 7, height: 7)
                        Text(segment.label)
                            .font(.system(size: 10))
                        Spacer(minLength: 6)
                        Text(Format.bytes(segment.bytes))
                            .font(.system(size: 10))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func width(for segment: Segment, usable: CGFloat) -> CGFloat {
        guard total > 0 else { return 0 }
        let share = Double(segment.bytes) / Double(total)
        return max(usable * CGFloat(min(share, 1)), 2)
    }
}

/// A direct label for one series of a chart.
///
/// The arrow takes the series colour and the words do not. Colour is for marks;
/// text that wears a series colour gets hard to read and stops looking like
/// text, so the swatch carries the identity and the ink stays ink.
struct SeriesLabel: View {
    let symbol: String
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(tint)
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 10, weight: .medium))
                .monospacedDigit()
        }
    }
}

// MARK: - Collapsible card

/// A section that can be folded away. Collapsed, it still shows its headline
/// number and its trend, so closing a section you do not need right now does
/// not mean losing sight of it.
struct CollapsibleCard<Content: View>: View {
    let title: String
    var subtitle: String?
    var headline: String?
    var spark: [Double]?
    var sparkMaximum: Double?
    var sparkBreaks: Set<Int> = []
    @Binding var isExpanded: Bool
    /// Opens the section's Inspect page. The button sits at the foot of the
    /// open section, under everything the section already shows.
    var onInspect: (() -> Void)?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: { isExpanded.toggle() }) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Text(title.uppercased())
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .tracking(0.6)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 6)
                    if !isExpanded, let spark, spark.count > 1 {
                        Sparkline(values: spark, maximum: sparkMaximum, height: 14,
                                  breaks: sparkBreaks)
                            .frame(width: 54)
                    }
                    if let headline {
                        Text(headline)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .monospacedDigit()
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                content

                if let onInspect {
                    Divider()
                    Button(action: onInspect) {
                        HStack(spacing: 4) {
                            Text("Inspect \(title.lowercased())")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }
}
