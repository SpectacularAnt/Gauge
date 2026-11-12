import SwiftUI

/// The panel that opens when you click the menu bar item.
struct DetailPanel: View {

    @ObservedObject var engine: MetricsEngine
    @ObservedObject var preferences: Preferences
    @State private var tab: Tab
    /// The Overview section whose Inspect page is showing, if one is.
    @State private var inspecting: OverviewSection?
    /// The device whose page is showing, by id, if one is.
    @State private var openDevice: String?

    init(engine: MetricsEngine, preferences: Preferences, initialTab: Tab = .overview) {
        self.engine = engine
        self.preferences = preferences
        _tab = State(initialValue: initialTab)
    }

    enum Tab: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case devices  = "Devices"
        case sensors  = "Sensors"
        case apps     = "Apps"
        case settings = "Settings"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            TabBar(selection: $tab)
                .padding(10)

            Divider()

            ScrollViewReader { scroller in
                ScrollView {
                    Group {
                        switch tab {
                        case .overview:
                            if let inspecting {
                                InspectPage(section: inspecting, engine: engine,
                                            preferences: preferences,
                                            onBack: { self.inspecting = nil })
                            } else {
                                OverviewTab(engine: engine, preferences: preferences,
                                            onInspect: { inspecting = $0 })
                            }
                        case .devices:
                            Group {
                                // A device that has gone from the list (unpaired,
                                // or a cable pulled) drops back to the list.
                                if let id = openDevice,
                                   let device = engine.devices?.first(where: { $0.id == id }) {
                                    DevicePage(device: device, preferences: preferences,
                                               onBack: { openDevice = nil })
                                } else {
                                    DevicesTab(engine: engine, onOpen: { openDevice = $0 })
                                }
                            }
                            // On the group, so going from the list to a device's
                            // page keeps the devices up to date.
                            .onAppear { engine.isDevicesTabVisible = true }
                            .onDisappear { engine.isDevicesTabVisible = false }
                        case .sensors:  SensorsTab(engine: engine, preferences: preferences)
                        case .apps:     AppsTab(engine: engine, preferences: preferences)
                        case .settings: SettingsTab(preferences: preferences, engine: engine)
                        }
                    }
                    .padding(10)
                    .id(Self.top)
                }
                // Going in starts the page at the top; coming back returns to
                // the section you left from, rather than to the top of a
                // long Overview.
                .onChange(of: openDevice) { _, _ in
                    DispatchQueue.main.async { scroller.scrollTo(Self.top, anchor: .top) }
                }
                .onChange(of: inspecting) { previous, current in
                    DispatchQueue.main.async {
                        if current != nil {
                            scroller.scrollTo(Self.top, anchor: .top)
                        } else if let previous {
                            scroller.scrollTo(previous.rawValue, anchor: .top)
                        }
                    }
                }
            }
        }
        .frame(width: 400, height: 600)
        // Another tab, then back to the Overview, starts on the Overview.
        .onChange(of: tab) { _, _ in
            inspecting = nil
            openDevice = nil
        }
    }

    private static let top = "top"
}

/// The row of tabs across the top.
///
/// Drawn by hand rather than with the system's segmented control, which
/// sizes each segment to its word and re-lays them out as the selection
/// moves, so the tabs shuffled about on every switch. Here every tab is the
/// same width and nothing moves but the highlight.
struct TabBar: View {
    @Binding var selection: DetailPanel.Tab

    var body: some View {
        HStack(spacing: 2) {
            ForEach(DetailPanel.Tab.allCases) { tab in
                let isSelected = tab == selection
                Button { selection = tab } label: {
                    Text(tab.rawValue)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                        .background {
                            if isSelected {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.primary.opacity(0.12))
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Overview

struct OverviewTab: View {
    @ObservedObject var engine: MetricsEngine
    @ObservedObject var preferences: Preferences
    /// Opens a section's Inspect page.
    let onInspect: (OverviewSection) -> Void
    /// The Inspect facts behind any picked lines, kept for one reading.
    @State private var factCache = FactCache()
    /// While true, the sections give way to a list for putting them in order.
    @State private var rearranging: Bool

    init(engine: MetricsEngine, preferences: Preferences, rearranging: Bool = false,
         onInspect: @escaping (OverviewSection) -> Void) {
        self.engine = engine
        self.preferences = preferences
        self.onInspect = onInspect
        _rearranging = State(initialValue: rearranging)
    }

    private var snapshot: Snapshot { engine.snapshot }

    /// One trend, over whichever stretch of time the range picker is set to.
    /// Every chart below goes through here, so switching the range switches
    /// all of them at once.
    private func trend(_ series: Series) -> History {
        engine.trend(series, range: preferences.trendRange)
    }
    private var system: SystemInfo { engine.system }
    private var state: SystemReading { engine.systemReading }

    var body: some View {
        VStack(spacing: 8) {
            glanceCard
            TrendRangePicker(engine: engine, preferences: preferences)
            if rearranging {
                rearrangeCard
            } else {
                sectionControls
                ForEach(visibleSections) { section in
                    card(for: section).id(section.rawValue)
                }
                rearrangeButton
            }
        }
    }

    /// The sections in the order chosen, leaving out any this Mac has nothing
    /// for: a desktop has no battery, so no Power.
    private var visibleSections: [OverviewSection] {
        preferences.sectionOrder.filter { $0 != .power || snapshot.power.hasBattery }
    }

    @ViewBuilder
    private func card(for section: OverviewSection) -> some View {
        switch section {
        case .processor:   processorCard
        case .memory:      memoryCard
        case .graphics:    graphicsCard
        case .temperature: temperatureCard
        case .power:       powerCard
        case .storage:     storageCard
        case .network:     networkCard
        case .system:      systemCard
        }
    }

    // MARK: Rearranging

    private var rearrangeButton: some View {
        Button { rearranging = true } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 9, weight: .semibold))
                Text("Rearrange sections")
            }
            .font(.system(size: 11))
            .foregroundStyle(Color.accentColor)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Each section on one line, with arrows to move it. The sections
    /// themselves are folded away meanwhile, so the whole order fits on
    /// screen at once.
    private var rearrangeCard: some View {
        let sections = visibleSections
        return Card(title: "Rearrange sections") {
            ForEach(Array(sections.enumerated()), id: \.element) { index, section in
                HStack(spacing: 8) {
                    Text(section.rawValue)
                        .font(.system(size: 12))
                    Spacer(minLength: 8)
                    moveButton("chevron.up", enabled: index > 0) {
                        preferences.swapSections(section, sections[index - 1])
                    }
                    moveButton("chevron.down", enabled: index < sections.count - 1) {
                        preferences.swapSections(section, sections[index + 1])
                    }
                }
                .padding(.vertical, 3)
                if index < sections.count - 1 { Divider() }
            }
            HStack {
                Button("Reset order") { preferences.sectionOrder = OverviewSection.allCases }
                    .controlSize(.small)
                    .disabled(preferences.sectionOrder == OverviewSection.allCases)
                Spacer()
                Button { rearranging = false } label: {
                    Text("Done")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 4)
        }
    }

    private func moveButton(_ symbol: String, enabled: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 24, height: 20)
                .background(Color.primary.opacity(enabled ? 0.08 : 0.03),
                            in: RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Color.primary : Color.secondary.opacity(0.4))
        .disabled(!enabled)
    }

    /// Open or closed, remembered per section.
    private func expanded(_ name: String) -> Binding<Bool> {
        Binding(
            get: { !preferences.collapsedSections.contains(name) },
            set: { isOpen in
                if isOpen {
                    preferences.collapsedSections.remove(name)
                } else {
                    preferences.collapsedSections.insert(name)
                }
            }
        )
    }

    private var sectionControls: some View {
        HStack(spacing: 8) {
            Spacer()
            Button("Expand all") { preferences.collapsedSections = [] }
            Button("Collapse all") {
                preferences.collapsedSections = Set(OverviewSection.allCases.map(\.rawValue))
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: 9))
        .foregroundStyle(.secondary)
    }

    // MARK: At a glance

    private var glanceCard: some View {
        let cpu = snapshot.cpu.total
        let memory = snapshot.memory.usedFraction
        let gpu = snapshot.gpu.utilization
        let temperature = snapshot.temperatures.hottestDie

        return VStack(spacing: 10) {
            HStack(spacing: 0) {
                RingGauge(label: "CPU",
                          value: "\(Int((cpu * 100).rounded()))%",
                          fraction: cpu,
                          tint: Severity.tint(for: cpu))
                    .frame(maxWidth: .infinity)
                RingGauge(label: "Memory",
                          value: "\(Int((memory * 100).rounded()))%",
                          fraction: memory,
                          tint: Severity.tint(for: memory))
                    .frame(maxWidth: .infinity)
                RingGauge(label: "GPU",
                          value: gpu.map { "\(Int(($0 * 100).rounded()))%" } ?? "\u{2013}",
                          fraction: gpu ?? 0,
                          tint: Severity.tint(for: gpu ?? 0))
                    .frame(maxWidth: .infinity)
                RingGauge(label: "Chip",
                          value: temperature.map { shortTemperature($0) } ?? "\u{2013}",
                          fraction: ((temperature ?? 30) - 30) / 65,
                          tint: temperature.map { Severity.temperatureTint(celsius: $0) } ?? .gray)
                    .frame(maxWidth: .infinity)
            }

            Divider()

            HStack(spacing: 0) {
                glanceFact("Thermals", state.thermalDescription)
                glanceFact("Power", powerSummary)
                glanceFact("Uptime", Format.uptime(state.uptime))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    private func glanceFact(_ label: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 10, weight: .medium))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
    }

    private var powerSummary: String {
        let power = snapshot.power
        guard power.hasBattery, let percentage = power.percentage else { return "Mains" }
        if power.isCharging { return "\(Int(percentage))% charging" }
        if power.isPluggedIn { return "\(Int(percentage))% on mains" }
        return "\(Int(percentage))% battery"
    }

    private func shortTemperature(_ celsius: Double) -> String {
        let value = preferences.useFahrenheit ? celsius * 9 / 5 + 32 : celsius
        return "\(Int(value.rounded()))\u{00B0}"
    }

    // MARK: Processor

    private var processorCard: some View {
        let cpu = snapshot.cpu
        return CollapsibleCard(
            title: "Processor",
            subtitle: "\(cpu.performanceCoreCount)P + \(cpu.efficiencyCoreCount)E",
            headline: "\(Int((cpu.total * 100).rounded()))%",
            spark: trend(.cpu).values,
            sparkMaximum: 1,
            sparkBreaks: trend(.cpu).breaks,
            isExpanded: expanded("Processor"),
            onInspect: { onInspect(.processor) }
        ) {
            ScrubbableSparkline(history: trend(.cpu), maximum: 1, format: percent)

            HStack(alignment: .bottom, spacing: 16) {
                if !cpu.performanceCores.isEmpty {
                    CoreBars(values: cpu.performanceCores,
                             label: "Performance \(Int((cpu.performanceAverage * 100).rounded()))%",
                             tint: Palette.series1)
                }
                if !cpu.efficiencyCores.isEmpty {
                    CoreBars(values: cpu.efficiencyCores,
                             label: "Efficiency \(Int((cpu.efficiencyAverage * 100).rounded()))%",
                             tint: Palette.series2)
                }
            }

            detailRows(OverviewDetail.options(for: .processor), divided: true)
            pickedFacts(.processor)
        }
    }

    // MARK: Memory

    private var memoryCard: some View {
        let memory = snapshot.memory
        let segments: [StackedBar.Segment] = [
            .init(label: "App memory", bytes: memory.app, color: Palette.series1),
            .init(label: "Wired", bytes: memory.wired, color: Palette.series2),
            .init(label: "Compressed", bytes: memory.compressed, color: Palette.series3),
            .init(label: "Cached files", bytes: memory.cached, color: Palette.neutral),
        ]
        return CollapsibleCard(
            title: "Memory",
            subtitle: Format.bytes(memory.total, decimals: 0),
            headline: "\(Int((memory.usedFraction * 100).rounded()))%",
            spark: trend(.memory).values,
            sparkMaximum: 1,
            sparkBreaks: trend(.memory).breaks,
            isExpanded: expanded("Memory"),
            onInspect: { onInspect(.memory) }
        ) {
            ScrubbableSparkline(history: trend(.memory), maximum: 1, format: percent)
            StackedBar(segments: segments, total: memory.total)

            detailRows(OverviewDetail.options(for: .memory), divided: true)
            pickedFacts(.memory)
        }
    }

    // MARK: Graphics

    private var graphicsCard: some View {
        let gpu = snapshot.gpu
        return CollapsibleCard(
            title: "Graphics",
            subtitle: system.gpuCores > 0 ? "\(system.gpuCores) cores" : nil,
            headline: gpu.utilization.map { "\(Int(($0 * 100).rounded()))%" } ?? "\u{2013}",
            spark: trend(.gpu).values,
            sparkMaximum: 1,
            sparkBreaks: trend(.gpu).breaks,
            isExpanded: expanded("Graphics"),
            onInspect: { onInspect(.graphics) }
        ) {
            ScrubbableSparkline(history: trend(.gpu), maximum: 1, format: percent)
            detailRows(OverviewDetail.options(for: .graphics))
            pickedFacts(.graphics)
        }
    }

    // MARK: Temperature

    private var temperatureCard: some View {
        let temperatures = snapshot.temperatures
        return CollapsibleCard(
            title: "Temperature",
            subtitle: temperatures.all.isEmpty ? nil : "\(temperatures.all.count) sensors",
            headline: temperatures.hottestDie.map { shortTemperature($0) } ?? "\u{2013}",
            spark: trend(.temperature).values,
            sparkMaximum: 100,
            sparkBreaks: trend(.temperature).breaks,
            isExpanded: expanded("Temperature"),
            onInspect: { onInspect(.temperature) }
        ) {
            if !engine.temperaturesAvailable {
                Text("This version of macOS did not let Gauge read the sensors.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                // Fixed 0-100 degree scale on purpose. Scaling to whatever
                // the last two minutes happened to contain would turn half a
                // degree of drift into a cliff.
                ScrubbableSparkline(history: trend(.temperature),
                                    tint: Palette.series2,
                                    maximum: 100,
                                    format: scrubTemperature)
                detailRows(OverviewDetail.options(for: .temperature))
                pickedFacts(.temperature)
                Text("The CPU and GPU share one die on Apple Silicon, so macOS "
                     + "reports no separate GPU temperature. Every sensor is "
                     + "listed in the Sensors tab.")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Power

    private var powerCard: some View {
        let power = snapshot.power
        return CollapsibleCard(
            title: "Power",
            subtitle: state.lowPowerMode ? "Low Power Mode" : nil,
            headline: power.watts.map { String(format: "%.1fW", $0) }
                ?? power.percentage.map { "\(Int($0))%" },
            spark: trend(.power).values,
            sparkBreaks: trend(.power).breaks,
            isExpanded: expanded("Power"),
            onInspect: { onInspect(.power) }
        ) {
            // At least a 10 W scale, so idle drift of a tenth of a watt
            // stays the flat line it really is.
            ScrubbableSparkline(history: trend(.power),
                                tint: Palette.series2,
                                maximum: max(trend(.power).peak, 10),
                                format: { String(format: "%.2f W", $0) })
            detailRows(OverviewDetail.options(for: .power))
            pickedFacts(.power)
        }
    }

    private func batteryState(_ power: PowerReading) -> String {
        if power.isCharging { return "Charging" }
        if power.isPluggedIn { return "On mains power" }
        return "On battery"
    }

    // MARK: Storage

    private var storageCard: some View {
        let storage = snapshot.storage
        return CollapsibleCard(
            title: "Storage",
            subtitle: state.volumes.count > 1 ? "\(state.volumes.count) volumes" : nil,
            headline: "\(Int((storage.usedFraction * 100).rounded()))%",
            spark: trend(.diskWrite).values,
            sparkBreaks: trend(.diskWrite).breaks,
            isExpanded: expanded("Storage"),
            onInspect: { onInspect(.storage) }
        ) {
            detailRows(Self.storageAboveChart)

            if Self.storageAboveChart.contains(where: preferences.shows) {
                Divider().padding(.vertical, 1)
            }
            Text("Read and write, same scale")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            ScrubbableMirroredSparkline(upper: trend(.diskRead), lower: trend(.diskWrite),
                                        upperLabel: "Read", lowerLabel: "Write",
                                        format: Format.rateLong)
            HStack {
                SeriesLabel(symbol: "arrow.down", title: "Read",
                            value: Format.rateLong(storage.readRate), tint: Palette.series1)
                Spacer()
                SeriesLabel(symbol: "arrow.up", title: "Write",
                            value: Format.rateLong(storage.writeRate), tint: Palette.series2)
            }

            detailRows(OverviewDetail.options(for: .storage).filter { !Self.storageAboveChart.contains($0) })
            pickedFacts(.storage)
        }
    }

    // MARK: Network

    private var networkCard: some View {
        let network = snapshot.network
        return CollapsibleCard(
            title: "Network",
            headline: Format.rate(network.downRate + network.upRate) + "/s",
            spark: trend(.networkDown).values,
            sparkBreaks: trend(.networkDown).breaks,
            isExpanded: expanded("Network"),
            onInspect: { onInspect(.network) }
        ) {
            Text("Download and upload, same scale")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            ScrubbableMirroredSparkline(upper: trend(.networkDown), lower: trend(.networkUp),
                                        upperLabel: "Down", lowerLabel: "Up",
                                        format: Format.rateLong)
            HStack {
                SeriesLabel(symbol: "arrow.down", title: "Down",
                            value: Format.rateLong(network.downRate), tint: Palette.series1)
                Spacer()
                SeriesLabel(symbol: "arrow.up", title: "Up",
                            value: Format.rateLong(network.upRate), tint: Palette.series2)
            }

            detailRows(OverviewDetail.options(for: .network), divided: true)
            pickedFacts(.network)
        }
    }

    // MARK: System

    private var systemCard: some View {
        CollapsibleCard(
            title: "System",
            headline: system.chip,
            isExpanded: expanded("System"),
            onInspect: { onInspect(.system) }
        ) {
            detailRows(OverviewDetail.options(for: .system))
            pickedFacts(.system)
        }
    }

    // MARK: The chosen details

    /// Facts picked from the section's Inspect page, under a small heading
    /// naming the block each came from, since "Health" or "Status" alone would
    /// not say whose.
    @ViewBuilder
    private func pickedFacts(_ section: OverviewSection) -> some View {
        let groups = pickedGroups(section)
        if !groups.isEmpty {
            Divider().padding(.vertical, 1)
            ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                // Everything in the Overview is "right now", so that heading
                // would add nothing.
                if group.title != "Right now" {
                    Text(group.title.uppercased())
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .tracking(0.5)
                        .padding(.top, 2)
                }
                ForEach(Array(group.facts.enumerated()), id: \.offset) { _, fact in
                    FactRow(fact: fact)
                }
            }
        }
    }

    /// Only gathered while the section is open and something is picked: a
    /// shut section shows none of its lines, and gathering costs a few system
    /// calls apiece.
    private func pickedGroups(_ section: OverviewSection) -> [FactGroup] {
        let keys = preferences.factKeys(for: section)
        guard !keys.isEmpty,
              !preferences.collapsedSections.contains(section.rawValue)
        else { return [] }
        return factCache.groups(for: section, engine: engine, preferences: preferences)
            .compactMap { group in
                var picked = group
                picked.facts = group.facts.filter { fact in
                    keys.contains(Inspector.key(section, group, fact))
                        && OverviewDetail.line(for: fact, in: group, of: section) == nil
                }
                return picked.facts.isEmpty ? nil : picked
            }
    }

    /// Storage's space and health bars sit above its chart, as they always
    /// have; the rest of its lines go underneath.
    private static let storageAboveChart: [OverviewDetail] = [.storageVolumes, .storageDriveHealth]

    /// The lines from `options` that are switched on, in the order given. With
    /// `divided`, a rule separates them from what is above, but only if there
    /// is anything to separate.
    @ViewBuilder
    private func detailRows(_ options: [OverviewDetail], divided: Bool = false) -> some View {
        let shown = options.filter(preferences.shows)
        if divided && !shown.isEmpty {
            Divider().padding(.vertical, 1)
        }
        ForEach(shown) { item in
            detail(item)
        }
    }

    private func degrees(_ celsius: Double) -> String {
        Format.temperature(celsius, fahrenheit: preferences.useFahrenheit)
    }

    /// "SSD" for the Mac's own drive, its name for anything plugged in.
    private func driveName(_ drive: DriveHealth) -> String {
        drive.isInternal ? "SSD" : drive.name
    }

    /// How each line is drawn. A line with nothing to say on this Mac, like a
    /// battery temperature on a desktop, draws nothing.
    @ViewBuilder
    private func detail(_ item: OverviewDetail) -> some View {
        let cpu = snapshot.cpu
        let memory = snapshot.memory
        let gpu = snapshot.gpu
        let temperatures = snapshot.temperatures
        let power = snapshot.power
        let storage = snapshot.storage
        let network = snapshot.network
        let drives = engine.health.drives

        switch item {
        // Processor
        case .cpuUser:
            StatRow(label: "Your programs", value: percent(cpu.user))
        case .cpuSystem:
            StatRow(label: "macOS itself", value: percent(cpu.system))
        case .cpuIdle:
            StatRow(label: "Idle", value: percent(max(1 - cpu.total, 0)))
        case .cpuLoad:
            StatRow(label: "Load average",
                    value: cpu.loadAverage.map { String(format: "%.2f", $0) }.joined(separator: "  "))
        case .cpuBusiestCore:
            StatRow(label: "Busiest core", value: percent(cpu.perCore.max() ?? 0))
        case .cpuPerformance:
            if !cpu.performanceCores.isEmpty {
                StatRow(label: "Performance cores", value: percent(cpu.performanceAverage))
            }
        case .cpuEfficiency:
            if !cpu.efficiencyCores.isEmpty {
                StatRow(label: "Efficiency cores", value: percent(cpu.efficiencyAverage))
            }
        case .cpuPrograms:
            StatRow(label: "Programs running", value: Format.count(Inspector.processCount()))

        // Memory
        case .memoryUsed:
            StatRow(label: "In use", value: Format.bytes(memory.used), emphasised: true)
        case .memoryPressure:
            LabeledBar(label: "Pressure (\(memory.pressureDescription))",
                       value: "\(Int((memory.pressureFraction * 100).rounded()))%",
                       fraction: memory.pressureFraction,
                       tint: memory.pressureLevel > 1
                           ? .red : Severity.tint(for: memory.pressureFraction))
        case .memorySwap:
            StatRow(label: "Swap used",
                    value: memory.swapTotal == 0
                        ? "none"
                        : "\(Format.bytes(memory.swapUsed)) of \(Format.bytes(memory.swapTotal))")
        case .memoryInstalled:
            StatRow(label: "Installed", value: Format.bytes(memory.total, decimals: 0))
        case .memoryApp:
            StatRow(label: "App memory", value: Format.bytes(memory.app))
        case .memoryWired:
            StatRow(label: "Wired", value: Format.bytes(memory.wired))
        case .memoryCompressed:
            StatRow(label: "Compressed", value: Format.bytes(memory.compressed))
        case .memoryCached:
            StatRow(label: "Cached files", value: Format.bytes(memory.cached))

        // Graphics
        case .gpuBusy:
            if let utilization = gpu.utilization {
                StatRow(label: "Busy", value: percent(utilization))
            }
        case .gpuMemoryInUse:
            StatRow(label: "Memory in use", value: Format.bytes(gpu.inUseMemory))
        case .gpuMemoryAllocated:
            StatRow(label: "Memory set aside", value: Format.bytes(gpu.allocatedMemory))
        case .gpuCores:
            if system.gpuCores > 0 {
                StatRow(label: "Cores", value: "\(system.gpuCores)")
            }
        case .gpuDisplays:
            ForEach(state.displays) { display in
                StatRow(label: display.name,
                        value: "\(display.width)\u{00D7}\(display.height) "
                             + "@\(Int(display.scale))x \(display.refreshHz)Hz")
            }

        // Temperature
        case .temperatureHottest:
            if let hottest = temperatures.hottestDie {
                LabeledBar(label: "Chip (hottest sensor)",
                           value: degrees(hottest),
                           fraction: (hottest - 30) / 65,
                           tint: Severity.temperatureTint(celsius: hottest))
            }
        case .temperatureAverage:
            if let average = temperatures.averageDie {
                StatRow(label: "Chip average", value: degrees(average))
            }
        case .temperatureBattery:
            if let battery = temperatures.battery {
                StatRow(label: "Battery", value: degrees(battery))
            }
        case .temperatureSSD:
            if let ssd = temperatures.storage {
                StatRow(label: "SSD", value: degrees(ssd))
            }
        case .temperatureThermalState:
            StatRow(label: "macOS thermal state", value: state.thermalDescription)

        // Power
        case .powerCharge:
            if let percentage = power.percentage {
                LabeledBar(label: batteryState(power),
                           value: "\(Int(percentage.rounded()))%",
                           fraction: percentage / 100,
                           tint: percentage < 20 && !power.isPluggedIn ? .red : .green)
            }
        case .powerDrawing:
            if let watts = power.watts, watts > 0.05 {
                StatRow(label: power.isCharging ? "Charging at" : "Drawing",
                        value: String(format: "%.2f W", watts),
                        emphasised: true)
            }
        case .powerRemaining:
            if let minutes = power.minutesRemaining {
                StatRow(label: power.isCharging ? "Until full" : "Remaining",
                        value: Format.duration(minutes: minutes))
            }
        case .powerHealth:
            if let health = power.healthPercentage {
                StatRow(label: "Battery health", value: "\(Int(health.rounded()))%")
            }
        case .powerCycles:
            if let cycles = power.cycleCount {
                StatRow(label: "Charge cycles", value: "\(cycles)")
            }
        case .powerVoltage:
            if let voltage = power.voltage {
                StatRow(label: "Voltage", value: String(format: "%.2f V", voltage))
            }
        case .powerCurrent:
            if let amperage = power.amperage {
                StatRow(label: "Current", value: String(format: "%.3f A", amperage))
            }
        case .powerBatteryTemperature:
            if let battery = temperatures.battery {
                StatRow(label: "Battery temperature", value: degrees(battery))
            }
        case .powerLowPowerMode:
            StatRow(label: "Low Power Mode", value: state.lowPowerMode ? "On" : "Off")

        // Storage
        case .storageVolumes:
            ForEach(state.volumes) { volume in
                LabeledBar(label: volume.name,
                           value: "\(Format.bytes(volume.free)) free",
                           fraction: volume.usedFraction,
                           tint: Severity.tint(for: volume.usedFraction))
            }
        case .storageDriveHealth:
            // How worn each drive is, by its own report. Full means healthy,
            // so this bar is read the other way from the space bars.
            ForEach(drives) { drive in
                LabeledBar(label: "\(driveName(drive)) health",
                           value: drive.warnings.isEmpty
                               ? "\(drive.healthPercent)%"
                               : "\(drive.healthPercent)%  \u{26A0}\u{FE0F} reporting a problem",
                           fraction: Double(drive.healthPercent) / 100,
                           tint: !drive.warnings.isEmpty || drive.healthPercent < 50 ? .red
                               : drive.healthPercent < 80 ? .orange : .green)
            }
        case .storageReadTotal:
            StatRow(label: "Read since boot", value: Format.bytes(storage.readTotal))
        case .storageWriteTotal:
            StatRow(label: "Written since boot", value: Format.bytes(storage.writeTotal))
        case .storageDriveWritten:
            ForEach(drives) { drive in
                StatRow(label: "\(driveName(drive)), written in its lifetime",
                        value: Format.decimalBytes(drive.dataWritten))
            }
        case .storageDrivePoweredOn:
            ForEach(drives) { drive in
                StatRow(label: "\(driveName(drive)), powered on for",
                        value: Format.span(Double(drive.powerOnHours) * 3600))
            }
        case .storageDriveUnsafeShutdowns:
            ForEach(drives) { drive in
                StatRow(label: "\(driveName(drive)), unsafe shutdowns",
                        value: Format.count(drive.unsafeShutdowns))
            }
        case .storageDriveTemperature:
            ForEach(drives) { drive in
                if let celsius = drive.temperature {
                    StatRow(label: "\(driveName(drive)) temperature", value: degrees(celsius))
                }
            }

        // Network
        case .networkInterfaces:
            ForEach(state.interfaces) { interface in
                StatRow(label: interface.address.map { "\(interface.name)  \($0)" } ?? interface.name,
                        value: interface.linkSpeedMbit > 0
                            ? "\(interface.linkSpeedMbit) Mbit/s" : "no link")
            }
        case .networkReceived:
            StatRow(label: "Received since boot", value: Format.bytes(network.downTotal))
        case .networkSent:
            StatRow(label: "Sent since boot", value: Format.bytes(network.upTotal))
        case .networkDownNow:
            StatRow(label: "Downloading now", value: Format.rateLong(network.downRate))
        case .networkUpNow:
            StatRow(label: "Uploading now", value: Format.rateLong(network.upRate))

        // System
        case .systemModel:
            StatRow(label: "Model", value: system.modelName, emphasised: true)
        case .systemIdentifier:
            StatRow(label: "Identifier", value: system.modelIdentifier)
        case .systemChip:
            StatRow(label: "Chip", value: system.chip)
        case .systemCPUCores:
            StatRow(label: "CPU cores",
                    value: "\(system.totalCores)  "
                         + "(\(system.performanceCores) performance, \(system.efficiencyCores) efficiency)")
        case .systemGPUCores:
            if system.gpuCores > 0 {
                StatRow(label: "GPU cores", value: "\(system.gpuCores)")
            }
        case .systemMemory:
            StatRow(label: "Memory", value: Format.bytes(system.memoryBytes, decimals: 0))
        case .systemMacOS:
            StatRow(label: "macOS", value: "\(system.osVersion) (\(system.osBuild))")
        case .systemBooted:
            StatRow(label: "Started", value: system.bootedAt.formatted(date: .abbreviated, time: .shortened))
        case .systemUptime:
            StatRow(label: "Running for", value: Format.uptime(state.uptime))
        case .systemThermalState:
            StatRow(label: "Thermal state", value: state.thermalDescription)
        case .systemLowPowerMode:
            StatRow(label: "Low Power Mode", value: state.lowPowerMode ? "On" : "Off")
        }
    }

    private func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    /// History records a missing temperature as 0, which is not the same as a
    /// reading of 0 degrees.
    private func scrubTemperature(_ celsius: Double) -> String {
        celsius > 0
            ? Format.temperature(celsius, fahrenheit: preferences.useFahrenheit)
            : "no reading"
    }
}

/// Holds each section's Inspect facts for one reading.
///
/// SwiftUI redraws far more often than readings arrive (every mouse move over
/// a chart, for one), and some facts take a system call or a quick run of
/// `netstat`. So they are gathered once per reading and handed back until the
/// next one, or until a setting they depend on changes.
final class FactCache {
    private struct Entry {
        let takenAt: Date
        let settings: String
        let groups: [FactGroup]
    }
    private var entries: [OverviewSection: Entry] = [:]

    func groups(for section: OverviewSection, engine: MetricsEngine,
                preferences: Preferences) -> [FactGroup] {
        let settings = "\(preferences.useFahrenheit) \(preferences.trendRange.rawValue) "
            + "\(Int(preferences.historyMinutes))"
        let takenAt = engine.snapshot.takenAt
        if let entry = entries[section], entry.takenAt == takenAt, entry.settings == settings {
            return entry.groups
        }
        let groups = Inspector.everything(for: section, engine: engine,
                                          range: preferences.trendRange,
                                          liveMinutes: Int(preferences.historyMinutes),
                                          fahrenheit: preferences.useFahrenheit)
        entries[section] = Entry(takenAt: takenAt, settings: settings, groups: groups)
        return groups
    }
}

// MARK: - Sensors

private struct SensorsTab: View {
    @ObservedObject var engine: MetricsEngine
    @ObservedObject var preferences: Preferences

    var body: some View {
        let samples = engine.snapshot.temperatures.all
        VStack(spacing: 8) {
            if samples.isEmpty {
                Card(title: "Sensors") {
                    Text(engine.temperaturesAvailable
                         ? "Waiting for the first reading\u{2026}"
                         : "Gauge could not open the sensor system on this Mac.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            } else {
                Card(title: "All sensors", subtitle: "\(samples.count) reporting") {
                    ForEach(samples) { sample in
                        HStack {
                            Circle()
                                .fill(Severity.temperatureTint(celsius: sample.celsius))
                                .frame(width: 5, height: 5)
                            Text(sample.name)
                                .font(.system(size: 10))
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text(Format.temperature(sample.celsius,
                                                    fahrenheit: preferences.useFahrenheit))
                                .font(.system(size: 10))
                                .monospacedDigit()
                        }
                    }
                }
                Card(title: "Reading the names") {
                    Text("""
                         Apple does not document these labels. In practice \
                         `tdie` sensors sit on the chip itself, `tdev` sensors \
                         on the board around it, `gas gauge` on the battery \
                         pack, and `NAND` on the flash storage. Channels that \
                         read far below freezing are unused, and calibration \
                         channels are hidden because they never move.
                         """)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Apps

private struct AppsTab: View {
    @ObservedObject var engine: MetricsEngine
    @ObservedObject var preferences: Preferences

    /// The one row opened, if any. Only one at a time: the panel is 600
    /// points tall and the list is long.
    @State private var openedPID: Int32?
    /// Set while a Quit is waiting to be confirmed, so that the button that
    /// ends a program is never the one you reach first.
    @State private var confirmingPID: Int32?
    /// Why the last Show did nothing, for the row it was pressed on.
    @State private var cannotShow: (pid: Int32, reason: String)?

    var body: some View {
        VStack(spacing: 8) {
            if engine.apps.isEmpty {
                Card(title: "Apps") {
                    Text("Starting the samplers\u{2026} the first figures take a "
                         + "few seconds to arrive.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                alertSummary
                table
                footnote
            }
        }
        .onAppear { engine.isAppsTabVisible = true }
        .onDisappear { engine.isAppsTabVisible = false }
    }

    private var sorted: [AppRow] {
        let rows = engine.apps.filter { row in
            // Hide the great mass of idle daemons. Anything doing something at
            // all still shows, and so does anything holding a real amount of
            // memory, busy or not: an idle app sitting on 2 GB is exactly what
            // the RAM column is for.
            row.cpuPercent >= 0.1 || row.gpuPercent >= 0.1
                || row.energyImpact >= 0.1 || row.memoryBytes >= 100 * 1_048_576
        }
        let ordered = rows.sorted { left, right in
            value(left) < value(right)
        }
        return preferences.appSortDescending ? ordered.reversed() : ordered
    }

    private func value(_ row: AppRow) -> Double {
        switch preferences.appSortColumn {
        case .cpu:     return row.cpuPercent
        case .gpu:     return row.gpuPercent
        case .power:   return row.energyImpact
        case .memory:  return Double(row.memoryBytes)
        }
    }

    /// What a row is flagged for. Nothing at all while app alerts are
    /// switched off in Settings, whatever the limits say.
    private func flags(_ row: AppRow) -> Set<AppAlert> {
        preferences.appAlertsEnabled ? row.alerts : []
    }

    private var alerting: [AppRow] {
        engine.apps.filter { !flags($0).isEmpty }
    }

    private var alertSummary: some View {
        Group {
            if alerting.isEmpty {
                EmptyView()
            } else {
                Card(title: "Using a lot", subtitle: "\(alerting.count)") {
                    ForEach(alerting.sorted { $0.energyImpact > $1.energyImpact }) { row in
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 4) {
                                Text("\u{26A0}\u{FE0F}").font(.system(size: 10))
                                Text(row.name)
                                    .font(.system(size: 11, weight: .medium))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 6)
                            }
                            Text(row.alerts.sorted { $0.rawValue < $1.rawValue }
                                    .map { preferences.alertLimits.label(for: $0) }
                                    .joined(separator: ", "))
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var table: some View {
        Card(title: "All apps", subtitle: "\(sorted.count) in use") {
            header
            Divider().padding(.vertical, 1)
            ForEach(sorted.prefix(25)) { row in
                VStack(alignment: .leading, spacing: 0) {
                    Button {
                        openedPID = openedPID == row.pid ? nil : row.pid
                        confirmingPID = nil
                        cannotShow = nil
                    } label: {
                        appRow(row)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if openedPID == row.pid {
                        appDetail(row)
                    }
                }
                .background(openedPID == row.pid
                            ? Color.primary.opacity(0.05) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 5))
            }
        }
    }

    /// Tapping a column sorts by it; tapping the one already in use turns the
    /// order around.
    private var header: some View {
        HStack(spacing: 0) {
            Text("")
                .frame(width: 12)
            Text("App")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(AppSortColumn.allCases) { column in
                Button {
                    if preferences.appSortColumn == column {
                        preferences.appSortDescending.toggle()
                    } else {
                        preferences.appSortColumn = column
                        preferences.appSortDescending = true
                    }
                } label: {
                    HStack(spacing: 1) {
                        Text(column.rawValue)
                            .font(.system(size: 9,
                                          weight: preferences.appSortColumn == column
                                              ? .bold : .semibold))
                        if preferences.appSortColumn == column {
                            Image(systemName: preferences.appSortDescending
                                  ? "chevron.down" : "chevron.up")
                                .font(.system(size: 6, weight: .bold))
                        }
                    }
                    .foregroundStyle(preferences.appSortColumn == column
                                     ? Color.accentColor : Color.secondary)
                    .frame(width: 52, alignment: .trailing)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func appRow(_ row: AppRow) -> some View {
        HStack(spacing: 0) {
            Text(flags(row).isEmpty ? "" : "\u{26A0}\u{FE0F}")
                .font(.system(size: 9))
                .frame(width: 12, alignment: .leading)
            Text(row.name)
                .font(.system(size: 10))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            cell(String(format: "%.1f", row.cpuPercent), flagged: flags(row).contains(.cpu))
            cell(row.gpuPercent >= 0.1 ? String(format: "%.1f", row.gpuPercent) : "\u{2013}",
                 flagged: flags(row).contains(.gpu))
            cell(String(format: "%.1f", row.energyImpact), flagged: flags(row).contains(.power))
            cell(Format.memory(row.memoryBytes), flagged: flags(row).contains(.memory))
        }
    }

    /// What an opened row shows: where the program came from, how long it has
    /// been running, what it has been doing, and the two things you might want
    /// to do about it.
    private func appDetail(_ row: AppRow) -> some View {
        let details = ProcessInspector.details(for: row.pid)
        let owner = ProcessOwner.find(pid: row.pid, details: details)
        return VStack(alignment: .leading, spacing: 5) {
            Divider()

            if row.cpuHistory.count > 1 {
                HStack(spacing: 8) {
                    Text("Recent CPU")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Sparkline(values: row.cpuHistory,
                              maximum: max(row.cpuHistory.max() ?? 100, 100),
                              height: 22)
                    Text(String(format: "peak %.0f", row.cpuHistory.max() ?? 0))
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
            }

            // What it is, for the ones whose names say nothing: a helper is
            // part of an app, a script was started by one.
            if let owner, owner.relation != .itself {
                StatRow(label: "What it is", value: owner.description.prefix(1).uppercased()
                                                    + owner.description.dropFirst())
            }
            StatRow(label: "Process ID", value: "\(row.pid)")
            if let started = details.startedAt {
                StatRow(label: "Running since",
                        value: "\(Format.clock(started)) \u{00B7} \(Format.span(Date().timeIntervalSince(started)))")
            }
            if let path = details.path {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Where")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text(path)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if confirmingPID == row.pid {
                HStack(spacing: 6) {
                    Text("Quit \(row.name)?")
                        .font(.system(size: 10))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Button("Cancel") { confirmingPID = nil }
                        .controlSize(.small)
                    Button("Quit") {
                        ProcessControl.quit(pid: row.pid)
                        confirmingPID = nil
                        openedPID = nil
                    }
                    .controlSize(.small)
                }
            } else {
                HStack(spacing: 6) {
                    Button(showLabel(owner)) {
                        if let reason = ProcessControl.reasonCannotShow(owner, processName: row.name) {
                            cannotShow = (row.pid, reason)
                        } else if let owner {
                            cannotShow = nil
                            ProcessControl.show(owner)
                        }
                    }
                    .controlSize(.small)
                    if let url = details.revealURL {
                        Button("Reveal in Finder") { ProcessControl.revealInFinder(url) }
                            .controlSize(.small)
                    }
                    Spacer(minLength: 4)
                    if details.isYours {
                        Button("Quit\u{2026}") { confirmingPID = row.pid }
                            .controlSize(.small)
                    } else {
                        // The window server runs as its own user, and ending it
                        // logs you out. Nothing that is not yours is offered.
                        Text("Belongs to macOS")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                }
                if let cannotShow, cannotShow.pid == row.pid {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 9))
                        Text(cannotShow.reason)
                            .font(.system(size: 9))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 6)
        .padding(.top, 2)
    }

    /// Says which app will come forward when that is not the row itself.
    private func showLabel(_ owner: ProcessOwner?) -> String {
        guard let owner, owner.relation != .itself, owner.relation != .macOS,
              owner.hasWindows, owner.isRunning
        else { return "Show" }
        return "Show \(owner.name)"
    }

    private func cell(_ text: String, flagged: Bool) -> some View {
        Text(text)
            .font(.system(size: 10, weight: flagged ? .semibold : .regular))
            .monospacedDigit()
            .foregroundStyle(flagged ? Color.orange : Color.primary)
            .frame(width: 52, alignment: .trailing)
    }

    private var footnote: some View {
        let limits = preferences.alertLimits
        return Card(title: "About these numbers") {
            Text("""
                 CPU is percent of one core, so a program using four cores at \
                 once reads 400. Power is the energy impact figure macOS itself \
                 computes, on roughly the same scale. GPU is this app's share of \
                 the graphics chip. RAM is the memory the app is holding, the \
                 same figure Activity Monitor shows; apps split into helper \
                 processes, like Chrome, list each one separately. A dash means \
                 nothing measurable.
                 """)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Click any row to see where the program came from, how long "
                 + "it has been running, and to quit it.")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if preferences.appAlertsEnabled {
                Text("An app is flagged at \(Int(limits.cpu))% CPU, \(Int(limits.gpu))% GPU, "
                     + "\(Int(limits.power)) energy impact, or "
                     + "\(AlertLimits.describe(limits.memory)) of RAM. "
                     + "Change these in Settings.")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Settings

struct SettingsTab: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var engine: MetricsEngine
    @ObservedObject var updater = Updater.shared

    /// Mirrors the system's own answer rather than a saved setting, because the
    /// user can change this in System Settings without the app hearing about it.
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var launchFailure: String?
    /// nil until macOS has been asked. False means macOS is blocking them,
    /// whatever the toggles below say.
    @State private var notificationsAllowed: Bool?

    var body: some View {
        VStack(spacing: 8) {
            Card(title: "Show in menu bar") {
                ForEach(Metric.Group.allCases, id: \.rawValue) { group in
                    // App alerts has its own card, beside the limits it counts.
                    let metrics = Metric.allCases.filter { $0.group == group && $0 != .appAlerts }
                    if !metrics.isEmpty {
                        Text(group.rawValue)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                        ForEach(metrics) { metric in
                            toggleRow(metric)
                        }
                    }
                }
            }

            Card(title: "Appearance") {
                Picker("", selection: $preferences.menuBarStyle) {
                    ForEach(MenuBarStyle.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text("Bare values take the least room, so more fit in the menu bar.")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 2)

                Toggle(isOn: $preferences.useFahrenheit) {
                    Text("Show temperatures in Fahrenheit")
                        .font(.system(size: 11))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.mini)

            Card(title: "Updates",
                 subtitle: String(format: "every %.1f s", preferences.refreshInterval)) {
                Slider(value: $preferences.refreshInterval, in: 0.5...10, step: 0.5) {
                    EmptyView()
                } minimumValueLabel: {
                    Text("0.5s").font(.system(size: 9)).foregroundStyle(.secondary)
                } maximumValueLabel: {
                    Text("10s").font(.system(size: 9)).foregroundStyle(.secondary)
                }
                .controlSize(.mini)
                .onChange(of: preferences.refreshInterval) { _, interval in
                    engine.start(interval: interval)
                    engine.setHistoryWindow(minutes: preferences.historyMinutes,
                                            interval: interval)
                }
                Text("Faster updates cost a little more battery.")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }

            Card(title: "Trend length",
                 subtitle: "\(Int(preferences.historyMinutes)) min") {
                Slider(value: $preferences.historyMinutes, in: 1...30, step: 1) {
                    EmptyView()
                } minimumValueLabel: {
                    Text("1").font(.system(size: 9)).foregroundStyle(.secondary)
                } maximumValueLabel: {
                    Text("30").font(.system(size: 9)).foregroundStyle(.secondary)
                }
                .controlSize(.mini)
                .onChange(of: preferences.historyMinutes) { _, minutes in
                    engine.setHistoryWindow(minutes: minutes,
                                            interval: preferences.refreshInterval)
                }
                Text("How far back the Overview's \u{201C}Live\u{201D} view reaches. "
                     + "The 1h, 6h, 24h and 7d views are not affected.")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            appAlertsCard

            notificationsCard

            healthAlertsCard

            Card(title: "Starting up") {
                Toggle(isOn: Binding(
                    get: { launchAtLogin },
                    set: { wanted in
                        launchFailure = LaunchAtLogin.setEnabled(wanted)
                        // Trust the system's answer over the click: if macOS
                        // refused, the switch flips back by itself.
                        launchAtLogin = LaunchAtLogin.isEnabled
                    }
                )) {
                    Text("Open Gauge at login")
                        .font(.system(size: 11))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .toggleStyle(.switch)
                .controlSize(.mini)

                if let launchFailure {
                    Text(launchFailure)
                        .font(.system(size: 9))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if LaunchAtLogin.needsApprovalInSystemSettings {
                    Button("Open Login Items settings") { LaunchAtLogin.openSystemSettings() }
                        .controlSize(.small)
                }
                if launchAtLogin && LaunchAtLogin.isInRiskyLocation {
                    Text("macOS remembers this app by its location. Gauge is in a "
                         + "folder that syncs to iCloud, so move it to your "
                         + "Applications folder if it stops opening at login.")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .onAppear { launchAtLogin = LaunchAtLogin.isEnabled }

            Card(title: "Gauge") {
                HStack {
                    Button("Check for Updates") { updater.check() }
                        .controlSize(.small)
                        .disabled(updater.state == .checking || updater.state == .installing)
                    Spacer()
                    Button("Quit Gauge") { NSApplication.shared.terminate(nil) }
                        .controlSize(.small)
                }
                updateStatus
            }
        }
        .environment(\.prominentCardTitles, true)
    }

    // MARK: Updates

    /// What the last check found, and the button to install a newer version.
    /// Nothing is shown until a check has been asked for.
    @ViewBuilder private var updateStatus: some View {
        switch updater.state {
        case .idle:
            EmptyView()
        case .checking:
            statusLine("Checking for updates\u{2026}", color: .secondary)
        case .upToDate(let version):
            statusLine("Gauge \(version) is the newest version.", color: .secondary)
        case .available(let version, let tag):
            HStack(alignment: .firstTextBaseline) {
                statusLine("Gauge \(version) is available.", color: .primary)
                Spacer(minLength: 8)
                Button("Install and Relaunch") { updater.install(tag: tag, version: version) }
                    .controlSize(.small)
            }
        case .installing:
            statusLine("Downloading and checking the update\u{2026} Gauge will reopen by itself.",
                       color: .secondary)
        case .failed(let message):
            statusLine(message, color: .orange)
        }
    }

    private func statusLine(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Notifications

    private var notificationsCard: some View {
        Card(title: "Notifications") {
            notifyToggle("Disk space runs low",
                         isOn: $preferences.notifyLowDisk)
            notifyToggle("The Mac is hot enough to slow down",
                         isOn: $preferences.notifyThermal)

            if preferences.notifyLowDisk || preferences.notifyThermal {
                permissionWarning
            }
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .onAppear { refreshNotificationPermission() }
    }

    /// Shown only when a switch is on and macOS is refusing to deliver, which
    /// is the one case where the switch would otherwise be silently useless.
    @ViewBuilder private var permissionWarning: some View {
        if notificationsAllowed == false {
            HStack(alignment: .top, spacing: 6) {
                Text("macOS is not letting Gauge show notifications, so "
                     + "these will stay silent until it is allowed.")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button("Open Settings") { SystemNotifier.openSystemSettings() }
                    .controlSize(.small)
            }
            .padding(.top, 2)
        }
    }

    // MARK: Health alerts

    /// Worn parts rather than busy ones. A notification when a part's health
    /// drops below the limit set here, then a reminder once a week while it
    /// stays there.
    ///
    /// Only settings live here. The parts' actual health is on the Overview
    /// and the Inspect pages, not repeated in Settings.
    @ViewBuilder private var healthAlertsCard: some View {
        let hasBattery = engine.snapshot.power.hasBattery
        let hasDrive = !engine.health.drives.isEmpty
        if hasBattery || hasDrive {
            Card(title: "Health alerts") {
                if hasBattery {
                    healthRow("Battery health drops below",
                              isOn: $preferences.notifyBatteryHealth,
                              limit: $preferences.batteryHealthLimit,
                              range: Preferences.batteryHealthRange)
                }
                if hasDrive {
                    healthRow("Drive health drops below",
                              isOn: $preferences.notifyDriveHealth,
                              limit: $preferences.driveHealthLimit,
                              range: Preferences.driveHealthRange)
                }

                Text("You are told once when a part drops below its limit, then "
                     + "once a week while it stays there. A drive that reports a "
                     + "fault is mentioned straight away.")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)

                if preferences.notifyBatteryHealth || preferences.notifyDriveHealth {
                    permissionWarning
                }
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .onAppear { refreshNotificationPermission() }
        }
    }

    private func healthRow(_ title: String,
                           isOn: Binding<Bool>,
                           limit: Binding<Double>,
                           range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            notifyToggle(title, isOn: isOn)
            if isOn.wrappedValue {
                HStack {
                    Slider(value: limit, in: range, step: 5)
                        .controlSize(.mini)
                    Text("\(Int(limit.wrappedValue))%")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .frame(width: 34, alignment: .trailing)
                }
                .padding(.leading, 2)
            }
        }
        .padding(.bottom, 2)
    }

    /// Turning any of these on for the first time is what asks macOS for
    /// permission. Nothing asks at launch, because an app that demands
    /// permissions before it has been given a job is a nuisance.
    private func notifyToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: Binding(
            get: { isOn.wrappedValue },
            set: { wanted in
                isOn.wrappedValue = wanted
                guard wanted else { return }
                SystemNotifier.requestPermission { granted in
                    notificationsAllowed = granted
                }
            }
        )) {
            Text(title)
                .font(.system(size: 11))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func refreshNotificationPermission() {
        guard !preferences.notificationsAllOff else {
            notificationsAllowed = nil
            return
        }
        SystemNotifier.permissionGranted { granted in
            notificationsAllowed = granted
        }
    }

    // MARK: Alert limits

    /// Everything about busy programs in one place: the switch, what it shows,
    /// when it speaks up, and the limits behind all three. The limits only
    /// appear while the switch is on, since they do nothing otherwise.
    private var appAlertsCard: some View {
        Card(title: "App alerts") {
            Toggle(isOn: $preferences.appAlertsEnabled) {
                Text("Flag programs that use a lot")
                    .font(.system(size: 11))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("A program over any limit gets a \u{26A0}\u{FE0F} in the Apps tab.")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            if preferences.appAlertsEnabled {
                Divider().padding(.vertical, 2)

                Toggle(isOn: Binding(
                    get: { preferences.enabled.contains(.appAlerts) },
                    set: { preferences.toggle(.appAlerts, on: $0) }
                )) {
                    Text("Show the count in the menu bar")
                        .font(.system(size: 11))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                notifyToggle("Notify when one stays over a limit",
                             isOn: $preferences.notifyAppAlerts)
                if preferences.notifyAppAlerts {
                    HStack {
                        Text("After")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Slider(value: $preferences.notifyAfterMinutes, in: 1...30, step: 1)
                            .controlSize(.mini)
                        Text("\(Int(preferences.notifyAfterMinutes)) min")
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                    .padding(.leading, 2)
                    Text("Each program is mentioned at most once an hour.")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    permissionWarning
                }
                if preferences.shows(.appAlerts) || preferences.notifyAppAlerts {
                    Text("Both keep a sampler watching every program in the "
                         + "background, which costs a few percent of one core.")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider().padding(.vertical, 2)

                limitSlider(title: "CPU",
                            value: "\(Int(preferences.alertLimits.cpu))%",
                            binding: $preferences.alertLimits.cpu,
                            range: AlertLimits.cpuRange, step: 10,
                            ends: ("20%", "400%"))
                limitSlider(title: "GPU",
                            value: "\(Int(preferences.alertLimits.gpu))%",
                            binding: $preferences.alertLimits.gpu,
                            range: AlertLimits.gpuRange, step: 5,
                            ends: ("10%", "100%"))
                limitSlider(title: "Energy impact",
                            value: "\(Int(preferences.alertLimits.power))",
                            binding: $preferences.alertLimits.power,
                            range: AlertLimits.powerRange, step: 10,
                            ends: ("20", "400"))
                limitSlider(title: "RAM",
                            value: AlertLimits.describe(preferences.alertLimits.memory),
                            binding: memoryStepBinding,
                            range: 0...Double(AlertLimits.memorySteps.count - 1), step: 1,
                            ends: ("512 MB", "16 GB"))

                HStack(alignment: .top) {
                    Text("CPU is percent of one core, so 100 is one core flat out.")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("Reset limits") { preferences.alertLimits = AlertLimits() }
                        .controlSize(.small)
                        .disabled(preferences.alertLimits == AlertLimits())
                }
            }
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .onAppear { refreshNotificationPermission() }
    }

    private func limitSlider(title: String,
                             value: String,
                             binding: Binding<Double>,
                             range: ClosedRange<Double>,
                             step: Double,
                             ends: (String, String)) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text(title).font(.system(size: 11))
                Spacer()
                Text(value)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .monospacedDigit()
            }
            // The end labels get a fixed width so that all four tracks start
            // and stop in the same place, whatever "20%" or "512 MB" takes up.
            Slider(value: binding, in: range, step: step) {
                EmptyView()
            } minimumValueLabel: {
                Text(ends.0)
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .leading)
            } maximumValueLabel: {
                Text(ends.1)
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .trailing)
            }
            .controlSize(.mini)
        }
    }

    /// The RAM slider moves through `AlertLimits.memorySteps` by position, so
    /// it reads and writes an index rather than a byte count.
    private var memoryStepBinding: Binding<Double> {
        Binding(
            get: {
                let steps = AlertLimits.memorySteps
                let current = preferences.alertLimits.memory
                let index = steps.indices.min { abs(steps[$0] - current) < abs(steps[$1] - current) } ?? 4
                return Double(index)
            },
            set: { position in
                let steps = AlertLimits.memorySteps
                let index = min(max(Int(position.rounded()), 0), steps.count - 1)
                preferences.alertLimits.memory = steps[index]
            }
        )
    }

    private func toggleRow(_ metric: Metric) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Toggle(isOn: Binding(
                get: { preferences.enabled.contains(metric) },
                set: { preferences.toggle(metric, on: $0) }
            )) {
                Text(metric.title)
                    .font(.system(size: 11))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)

            if let explanation = metric.explanation {
                Text(explanation)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
