import SwiftUI

/// Everything Gauge can find out about one part of the Mac, opened from the
/// Inspect button at the bottom of its Overview section.
///
/// A page is a larger chart (for the parts that have one), a summary of what
/// that chart shows, and then every fact `Inspector` gathers, in titled blocks.
/// It is rebuilt on every reading while it is open, so live figures keep moving.
struct InspectPage: View {
    let section: OverviewSection
    @ObservedObject var engine: MetricsEngine
    @ObservedObject var preferences: Preferences
    let onBack: () -> Void
    /// While editing, every fact on the page gets a tick box, and the ticked
    /// ones are what the section shows in the Overview.
    @State private var editing: Bool

    init(section: OverviewSection, engine: MetricsEngine, preferences: Preferences,
         editing: Bool = false, onBack: @escaping () -> Void) {
        self.section = section
        self.engine = engine
        self.preferences = preferences
        self.onBack = onBack
        _editing = State(initialValue: editing)
    }

    var body: some View {
        let summaries = Inspector.summaries(for: section, engine: engine,
                                            range: preferences.trendRange,
                                            liveMinutes: Int(preferences.historyMinutes),
                                            fahrenheit: preferences.useFahrenheit)
        let groups = Inspector.facts(for: section, engine: engine,
                                     fahrenheit: preferences.useFahrenheit)
        VStack(spacing: 8) {
            header
            if section != .system {
                TrendRangePicker(engine: engine, preferences: preferences)
                Card(title: chartTitle) { chart }
                ForEach(Array(summaries.enumerated()), id: \.offset) { _, group in
                    card(group)
                }
            }
            ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                card(group)
            }
        }
    }

    private func card(_ group: FactGroup) -> some View {
        FactGroupCard(group: group,
                      choice: editing ? FactChoice(section: section, group: group,
                                                   preferences: preferences) : nil)
    }

    private var header: some View {
        VStack(spacing: 6) {
            // The title sits in the true centre; the buttons float either side
            // without pushing it off-centre.
            ZStack {
                Text(section.rawValue)
                    .font(.system(size: 13, weight: .semibold))
                HStack {
                    Button(action: onBack) {
                        HStack(spacing: 3) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 10, weight: .semibold))
                            Text("Overview")
                                .font(.system(size: 11))
                        }
                        .foregroundStyle(Color.accentColor)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Button { editing.toggle() } label: {
                        Text(editing ? "Done" : "Edit")
                            .font(.system(size: 11, weight: editing ? .semibold : .regular))
                            .foregroundStyle(Color.accentColor)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            if editing {
                HStack(alignment: .firstTextBaseline) {
                    Text("Ticked lines show under \(section.rawValue) in the Overview.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button("Reset") { preferences.resetDetails(for: section) }
                        .controlSize(.small)
                        .disabled(preferences.detailsAreDefault(for: section))
                }
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: The chart

    private func trend(_ series: Series) -> History {
        engine.trend(series, range: preferences.trendRange)
    }

    private var over: String {
        preferences.trendRange.phrase(liveMinutes: Int(preferences.historyMinutes))
    }

    private var chartTitle: String {
        switch section {
        case .storage: return "Read and write, same scale"
        case .network: return "Download and upload, same scale"
        default:       return "Over \(over)"
        }
    }

    /// The same charts as the Overview's, taller, so a long range has room to
    /// show its shape. Scales match the Overview's for the same reasons.
    @ViewBuilder private var chart: some View {
        switch section {
        case .processor:
            ScrubbableSparkline(history: trend(.cpu), maximum: 1, height: 64, format: percent)
        case .memory:
            ScrubbableSparkline(history: trend(.memory), maximum: 1, height: 64, format: percent)
        case .graphics:
            ScrubbableSparkline(history: trend(.gpu), maximum: 1, height: 64, format: percent)
        case .temperature:
            ScrubbableSparkline(history: trend(.temperature), tint: Palette.series2,
                                maximum: 100, height: 64, format: temperature)
        case .power:
            ScrubbableSparkline(history: trend(.power), tint: Palette.series2,
                                maximum: max(trend(.power).peak, 10), height: 64,
                                format: { String(format: "%.2f W", $0) })
        case .storage:
            ScrubbableMirroredSparkline(upper: trend(.diskRead), lower: trend(.diskWrite),
                                        upperLabel: "Read", lowerLabel: "Write",
                                        height: 80, format: Format.rateLong)
        case .network:
            ScrubbableMirroredSparkline(upper: trend(.networkDown), lower: trend(.networkUp),
                                        upperLabel: "Down", lowerLabel: "Up",
                                        height: 80, format: Format.rateLong)
        case .system:
            EmptyView()
        }
    }

    private func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    /// History records a missing temperature as 0, which is not the same as a
    /// reading of 0 degrees.
    private func temperature(_ celsius: Double) -> String {
        celsius > 0 ? Format.temperature(celsius, fahrenheit: preferences.useFahrenheit) : "no reading"
    }
}

/// A tick box drawn from symbols rather than AppKit's checkbox, so it matches
/// the panel's own buttons and draws the same everywhere.
struct TickBox: View {
    let isOn: Bool

    var body: some View {
        Image(systemName: isOn ? "checkmark.square.fill" : "square")
            .font(.system(size: 12))
            .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
    }
}

/// Whether each fact in one group is shown in the Overview, and the means to
/// change it. A fact that is one of the section's usual lines switches that
/// line, so the Overview keeps drawing it its own way; any other fact is
/// remembered on its own.
struct FactChoice {
    let section: OverviewSection
    let group: FactGroup
    let preferences: Preferences

    private func line(_ fact: Fact) -> OverviewDetail? {
        OverviewDetail.line(for: fact, in: group, of: section)
    }

    func isOn(_ fact: Fact) -> Bool {
        if let line = line(fact) { return preferences.shows(line) }
        return preferences.showsFact(Inspector.key(section, group, fact))
    }

    func toggle(_ fact: Fact) {
        if let line = line(fact) {
            preferences.setShown(line, !preferences.shows(line))
        } else {
            let key = Inspector.key(section, group, fact)
            preferences.setFactShown(key, !preferences.showsFact(key))
        }
    }
}

/// One titled block of facts. Given a `choice`, each fact gets a tick box for
/// showing it in the Overview.
struct FactGroupCard: View {
    let group: FactGroup
    var choice: FactChoice?

    var body: some View {
        Card(title: group.title, subtitle: group.subtitle) {
            ForEach(Array(group.facts.enumerated()), id: \.offset) { _, fact in
                if let choice {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Button { choice.toggle(fact) } label: {
                            TickBox(isOn: choice.isOn(fact))
                        }
                        .buttonStyle(.plain)
                        FactRow(fact: fact)
                    }
                } else {
                    FactRow(fact: fact)
                }
            }
            if let footnote = group.footnote {
                Text(footnote)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
    }
}

/// One fact: a label and its value, with a bar underneath when the value has a
/// natural maximum.
///
/// Values stay in ordinary ink unless something is wrong. Then they turn orange
/// or red and gain an icon, so the warning never rests on colour alone.
struct FactRow: View {
    let fact: Fact

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(fact.label)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize()
                Spacer(minLength: 4)
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    if let icon {
                        Image(systemName: icon)
                            .font(.system(size: 9))
                            .foregroundStyle(alertColor)
                    }
                    Text(fact.value)
                        .font(.system(size: 11, weight: fact.fraction == nil ? .regular : .medium))
                        .monospacedDigit()
                        .foregroundStyle(icon == nil ? Color.primary : alertColor)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                        // Serial numbers, addresses and paths are things people
                        // want to copy into a ticket or a search.
                        .textSelection(.enabled)
                }
            }
            if let fraction = fact.fraction {
                Bar(fraction: fraction, tint: barTint(fraction))
            }
        }
    }

    private var icon: String? {
        switch fact.tone {
        case .warning:  return "exclamationmark.triangle.fill"
        case .critical: return "exclamationmark.octagon.fill"
        default:        return nil
        }
    }

    private var alertColor: Color {
        fact.tone == .critical ? .red : .orange
    }

    private func barTint(_ fraction: Double) -> Color {
        if fact.isBattery { return BatteryTint.color(Int((fraction * 100).rounded())) }
        switch fact.tone {
        case .good:     return .green
        case .warning:  return .orange
        case .critical: return .red
        case .normal:   return Severity.tint(for: fraction)
        }
    }
}

/// How far back the charts reach: Live, or one of the stretches kept on disk.
/// Shared by the Overview and the Inspect pages, so changing it in one place
/// changes it in both.
struct TrendRangePicker: View {
    @ObservedObject var engine: MetricsEngine
    @ObservedObject var preferences: Preferences

    var body: some View {
        HStack(spacing: 4) {
            ForEach(TrendRange.allCases) { range in
                let isSelected = preferences.trendRange == range
                Button(range.label) { preferences.trendRange = range }
                    .buttonStyle(.plain)
                    .font(.system(size: 9, weight: isSelected ? .bold : .regular))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 4))
            }
            Spacer(minLength: 4)
            Text(note)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }

    /// Says what the charts are actually showing, which is not always what was
    /// asked for: a week's view on a Mac that has only been watched since
    /// lunchtime is a lunchtime's view.
    private var note: String {
        guard preferences.trendRange != .live else {
            return "last \(Int(preferences.historyMinutes)) min"
        }
        guard let earliest = engine.archive.earliest else { return "nothing saved yet" }
        let saved = Date().timeIntervalSince(earliest)
        guard let wanted = preferences.trendRange.duration, saved < wanted * 0.95 else {
            return "saved to disk"
        }
        return "only \(Format.span(saved)) saved so far"
    }
}
