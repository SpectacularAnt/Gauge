import AppKit
import IOKit
import IOKit.ps
import Metal
import SystemConfiguration

/// The eight sections of the Overview, each of which has an Inspect page.
enum OverviewSection: String, CaseIterable, Identifiable {
    case processor = "Processor"
    case memory = "Memory"
    case graphics = "Graphics"
    case temperature = "Temperature"
    case power = "Power"
    case storage = "Storage"
    case network = "Network"
    case system = "System"

    var id: String { rawValue }
}

/// One line on an Inspect page.
struct Fact {
    /// How the value should be read. `normal` lets a bar take its colour from
    /// how full it is; the others say outright that something is fine or not.
    enum Tone { case normal, good, warning, critical }

    let label: String
    let value: String
    /// Draws a bar under the line, 0...1, when there is a natural maximum.
    var fraction: Double?
    var tone: Tone = .normal
    /// A battery's bar, coloured green when full through yellow to red when
    /// empty, the same as the device rings.
    var isBattery = false

    init(_ label: String, _ value: String, fraction: Double? = nil, tone: Tone = .normal,
         isBattery: Bool = false) {
        self.label = label
        self.value = value
        self.fraction = fraction
        self.tone = tone
        self.isBattery = isBattery
    }
}

/// A titled block of facts on an Inspect page.
struct FactGroup: Identifiable {
    let title: String
    /// What the group is remembered by when one of its facts is picked for
    /// the Overview. The title, unless the title changes with the settings, as
    /// "Over the last hour" does.
    var key: String?
    var id: String { key ?? title }
    var subtitle: String?
    var facts: [Fact]
    /// A sentence or two saying what the numbers mean.
    var footnote: String?

    init(_ title: String, key: String? = nil, subtitle: String? = nil, footnote: String? = nil,
         _ facts: [Fact]) {
        self.title = title
        self.key = key
        self.subtitle = subtitle
        self.facts = facts
        self.footnote = footnote
    }
}

/// Fills in the Inspect pages.
///
/// Each page is nothing more than a list of `FactGroup`s, and every one of them
/// is built here. Most come straight from the reading the engine already took;
/// the rest are asked for on the spot, since they only matter while the page is
/// open and cost a few system calls apiece. Nothing in here is ever run while
/// the Inspect pages are shut.
enum Inspector {

    static func facts(for section: OverviewSection,
                      engine: MetricsEngine,
                      fahrenheit: Bool) -> [FactGroup] {
        let snapshot = engine.snapshot
        switch section {
        case .processor:
            return processor(snapshot.cpu, engine.system)
        case .memory:
            return memory(snapshot.memory)
        case .graphics:
            return graphics(snapshot.gpu, engine.system, engine.systemReading.displays)
        case .temperature:
            return temperature(snapshot.temperatures, engine.systemReading, engine.health,
                               fahrenheit: fahrenheit)
        case .power:
            return power(snapshot.power, snapshot.temperatures.battery, engine.systemReading,
                         fahrenheit: fahrenheit)
        case .storage:
            return storage(snapshot.storage, engine.health, fahrenheit: fahrenheit)
        case .network:
            return network(snapshot.network)
        case .system:
            return system(engine.system, engine.systemReading, engine.archive)
        }
    }

    /// Everything on a section's Inspect page: the summaries of its chart,
    /// then every fact. The Overview draws its picked lines from this too, so
    /// anything on the page can be shown there.
    static func everything(for section: OverviewSection,
                           engine: MetricsEngine,
                           range: TrendRange,
                           liveMinutes: Int,
                           fahrenheit: Bool) -> [FactGroup] {
        summaries(for: section, engine: engine, range: range,
                  liveMinutes: liveMinutes, fahrenheit: fahrenheit)
            + facts(for: section, engine: engine, fahrenheit: fahrenheit)
    }

    /// What one fact is saved as when it is picked for the Overview: its
    /// section, its group and its own label.
    static func key(_ section: OverviewSection, _ group: FactGroup, _ fact: Fact) -> String {
        "\(section.rawValue)|\(group.id)|\(fact.label)"
    }

    /// Average, highest and lowest across the chart, so a week can be read
    /// without scrubbing every inch of it.
    static func summaries(for section: OverviewSection,
                          engine: MetricsEngine,
                          range: TrendRange,
                          liveMinutes: Int,
                          fahrenheit: Bool) -> [FactGroup] {
        let over = range.phrase(liveMinutes: liveMinutes)
        func trend(_ series: Series) -> History { engine.trend(series, range: range) }
        func percent(_ fraction: Double) -> String { "\(Int((fraction * 100).rounded()))%" }
        func watts(_ value: Double) -> String { String(format: "%.2f W", value) }
        // History records a missing temperature as 0, which is not the same
        // as a reading of 0 degrees.
        func degrees(_ celsius: Double) -> String {
            celsius > 0 ? Format.temperature(celsius, fahrenheit: fahrenheit) : "no reading"
        }

        let found: [FactGroup?]
        switch section {
        case .processor:
            found = [rangeSummary(trend(.cpu), title: "Over \(over)", key: "summary", format: percent)]
        case .memory:
            found = [rangeSummary(trend(.memory), title: "Over \(over)", key: "summary", format: percent)]
        case .graphics:
            found = [rangeSummary(trend(.gpu), title: "Over \(over)", key: "summary", format: percent)]
        case .temperature:
            found = [rangeSummary(trend(.temperature), title: "Over \(over)", key: "summary",
                                  ignoringZero: true, format: degrees)]
        case .power:
            found = [rangeSummary(trend(.power), title: "Over \(over)", key: "summary", format: watts)]
        case .storage:
            found = [rangeSummary(trend(.diskRead), title: "Reading, over \(over)", key: "summary-read",
                                  format: Format.rateLong),
                     rangeSummary(trend(.diskWrite), title: "Writing, over \(over)", key: "summary-write",
                                  format: Format.rateLong)]
        case .network:
            found = [rangeSummary(trend(.networkDown), title: "Downloading, over \(over)",
                                  key: "summary-down", format: Format.rateLong),
                     rangeSummary(trend(.networkUp), title: "Uploading, over \(over)",
                                  key: "summary-up", format: Format.rateLong)]
        case .system:
            found = []
        }
        return found.compactMap { $0 }
    }

    /// Average, highest and lowest over whatever stretch the chart is showing,
    /// with when the extremes happened.
    static func rangeSummary(_ history: History,
                             title: String,
                             key: String,
                             ignoringZero: Bool = false,
                             format: (Double) -> String) -> FactGroup? {
        // A missing reading is stored as zero; for temperatures that would
        // otherwise be reported as the coldest moment of the week.
        let points = zip(history.values, history.times).filter { !ignoringZero || $0.0 > 0 }
        guard points.count > 1,
              let highest = points.max(by: { $0.0 < $1.0 }),
              let lowest = points.min(by: { $0.0 < $1.0 })
        else { return nil }
        let average = points.reduce(0) { $0 + $1.0 } / Double(points.count)
        return FactGroup(title, key: key, [
            Fact("Average", format(average)),
            Fact("Highest", "\(format(highest.0))  \u{00B7}  \(Format.moment(highest.1))"),
            Fact("Lowest", "\(format(lowest.0))  \u{00B7}  \(Format.moment(lowest.1))"),
        ])
    }

    // MARK: - Processor

    static func processor(_ cpu: CPUReading, _ system: SystemInfo) -> [FactGroup] {
        let cores = max(system.totalCores, 1)
        let now = FactGroup("Right now", footnote:
            "Load is how many threads were ready to run, on average over the last 1, 5 and "
            + "15 minutes. With \(cores) cores, "
            + "anything under \(cores) means nothing had to wait its turn.", [
            Fact("Total", percent(cpu.total), fraction: cpu.total),
            Fact("Your programs", percent(cpu.user), fraction: cpu.user),
            Fact("macOS itself", percent(cpu.system), fraction: cpu.system),
            Fact("Idle", percent(max(1 - cpu.total, 0))),
            Fact("Busiest core", percent(cpu.perCore.max() ?? 0)),
            Fact("Performance cores, average", percent(cpu.performanceAverage)),
            Fact("Efficiency cores, average", percent(cpu.efficiencyAverage)),
            Fact("Load average", "\(load(cpu, 0))  \(load(cpu, 1))  \(load(cpu, 2))"),
            Fact("Programs running", Format.count(processCount())),
        ])

        var coreFacts: [Fact] = []
        for (index, value) in cpu.performanceCores.enumerated() {
            coreFacts.append(Fact("Performance core \(index + 1)", percent(value), fraction: value))
        }
        for (index, value) in cpu.efficiencyCores.enumerated() {
            coreFacts.append(Fact("Efficiency core \(index + 1)", percent(value), fraction: value))
        }
        let everyCore = FactGroup("Every core", subtitle: "\(coreFacts.count)", coreFacts)

        var chip = [
            Fact("Chip", system.chip),
            Fact("Architecture", Sysctl.string("hw.machine") ?? "arm64"),
            Fact("Performance cores", "\(system.performanceCores)"),
            Fact("Efficiency cores", "\(system.efficiencyCores)"),
        ]
        // perflevel0 is the performance cluster, perflevel1 the efficiency one.
        for (level, name) in [(0, "Performance"), (1, "Efficiency")] {
            for (key, what) in [("l1icachesize", "L1 instruction cache"),
                                ("l1dcachesize", "L1 data cache"),
                                ("l2cachesize", "L2 cache")] {
                if let size = Sysctl.integer("hw.perflevel\(level).\(key)"), size > 0 {
                    chip.append(Fact("\(name) \(what)", Format.bytes(UInt64(size), decimals: 0)))
                }
            }
        }
        if let line = Sysctl.integer("hw.cachelinesize") {
            chip.append(Fact("Cache line", "\(line) bytes"))
        }
        return [now, everyCore, FactGroup("The chip", chip)]
    }

    private static func load(_ cpu: CPUReading, _ index: Int) -> String {
        cpu.loadAverage.indices.contains(index) ? String(format: "%.2f", cpu.loadAverage[index]) : "\u{2013}"
    }

    /// How many processes exist, yours and the system's. Cheap enough for the
    /// Overview to ask on every reading.
    static func processCount() -> Int {
        var pids = [Int32](repeating: 0, count: 8192)
        let found = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        return Int(max(found, 0))
    }

    // MARK: - Memory

    static func memory(_ memory: MemoryReading) -> [FactGroup] {
        let total = Double(max(memory.total, 1))
        func share(_ bytes: UInt64) -> Double { Double(bytes) / total }

        var now = [
            Fact("Installed", Format.bytes(memory.total, decimals: 0)),
            Fact("In use", Format.bytes(memory.used), fraction: memory.usedFraction),
            Fact("App memory", Format.bytes(memory.app), fraction: share(memory.app)),
            Fact("Wired", Format.bytes(memory.wired), fraction: share(memory.wired)),
            Fact("Compressed", Format.bytes(memory.compressed), fraction: share(memory.compressed)),
            Fact("Cached files", Format.bytes(memory.cached), fraction: share(memory.cached)),
        ]
        let statistics = vmStatistics()
        let page = UInt64(vm_kernel_page_size)
        if let statistics {
            now.append(Fact("Completely unused", Format.bytes(UInt64(statistics.free_count) * page)))
        }
        now.append(Fact("Pressure", memory.pressureDescription,
                        tone: memory.pressureLevel >= 4 ? .critical
                            : memory.pressureLevel >= 2 ? .warning : .good))
        now.append(Fact("Swap used", memory.swapTotal == 0
                        ? "none"
                        : "\(Format.bytes(memory.swapUsed)) of \(Format.bytes(memory.swapTotal))"))

        var groups = [FactGroup("Right now", footnote:
            "Wired memory is held by macOS itself and can never be moved out. Cached files are "
            + "spare memory doing something useful, and are handed back the moment a program "
            + "needs room.", now)]

        if let statistics {
            groups.append(FactGroup("Since the Mac started", footnote:
                "Page-outs and swap-outs that keep climbing are the sign of a Mac short of memory, "
                + "using the SSD to make up the difference. The rest is ordinary housekeeping and "
                + "climbs all day.", [
                Fact("Swap-outs", Format.count(statistics.swapouts)),
                Fact("Swap-ins", Format.count(statistics.swapins)),
                Fact("Page-outs", Format.count(statistics.pageouts)),
                Fact("Page-ins", Format.count(statistics.pageins)),
                Fact("Compressions", Format.count(statistics.compressions)),
                Fact("Decompressions", Format.count(statistics.decompressions)),
                Fact("Page faults", Format.count(statistics.faults)),
                Fact("Copy-on-write faults", Format.count(statistics.cow_faults)),
                Fact("Purges", Format.count(statistics.purges)),
            ]))
        }
        groups.append(FactGroup("How it is counted", [
            Fact("Page size", Format.bytes(page, decimals: 0)),
        ]))
        return groups
    }

    private static func vmStatistics() -> vm_statistics64? {
        var statistics = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride
                                           / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        return result == KERN_SUCCESS ? statistics : nil
    }

    // MARK: - Graphics

    /// Made once and kept: asking Metal for the GPU sets up a connection to the
    /// driver, which is not something to repeat on every tick.
    private static let metal = MTLCreateSystemDefaultDevice()

    static func graphics(_ gpu: GPUReading, _ system: SystemInfo, _ displays: [DisplayInfo]) -> [FactGroup] {
        let statistics = gpuStatistics()
        func share(_ key: String) -> Double? {
            (statistics[key] as? Int).map { min(Double($0) / 100, 1) }
        }

        var now: [Fact] = []
        if let utilization = gpu.utilization {
            now.append(Fact("Busy", percent(utilization), fraction: utilization))
        }
        if let renderer = share("Renderer Utilization %") {
            now.append(Fact("Drawing", percent(renderer), fraction: renderer))
        }
        if let tiler = share("Tiler Utilization %") {
            now.append(Fact("Sorting geometry", percent(tiler), fraction: tiler))
        }
        now.append(Fact("Memory in use", Format.bytes(gpu.inUseMemory)))
        now.append(Fact("Memory set aside", Format.bytes(gpu.allocatedMemory)))

        var chip = [Fact("Graphics", metal?.name ?? system.chip)]
        if system.gpuCores > 0 { chip.append(Fact("Cores", "\(system.gpuCores)")) }
        if let metal {
            chip.append(Fact("Shares memory with the CPU", metal.hasUnifiedMemory ? "Yes" : "No"))
            chip.append(Fact("Memory it may use", Format.bytes(metal.recommendedMaxWorkingSetSize, decimals: 0)))
            chip.append(Fact("Largest single buffer", Format.bytes(UInt64(metal.maxBufferLength), decimals: 0)))
            chip.append(Fact("Metal", metalFamily(metal)))
            chip.append(Fact("Hardware ray tracing", metal.supportsRaytracing ? "Yes" : "No"))
        }

        var groups = [
            FactGroup("Right now", footnote:
                "Drawing is the shading of pixels; sorting geometry is the work of deciding which "
                + "shapes land where on screen before they are drawn.", now),
            FactGroup("The GPU", chip),
        ]
        for display in displays {
            groups.append(FactGroup(display.name, subtitle: "display", [
                Fact("Looks like", "\(display.width) \u{00D7} \(display.height)"),
                Fact("Actual pixels", "\(Int(Double(display.width) * display.scale)) \u{00D7} "
                     + "\(Int(Double(display.height) * display.scale))"),
                Fact("Scale", "\(Int(display.scale))\u{00D7}"),
                Fact("Refresh rate", "\(display.refreshHz) Hz"),
            ]))
        }
        return groups
    }

    /// The newest Apple GPU family the chip belongs to. Families are numbered
    /// upwards with each chip generation, so this counts down from well past
    /// the newest one known and stops at the first that fits.
    private static func metalFamily(_ device: MTLDevice) -> String {
        var parts: [String] = []
        if device.supportsFamily(.metal3) { parts.append("Metal 3") }
        for raw in stride(from: 1020, through: 1001, by: -1) {
            if let family = MTLGPUFamily(rawValue: raw), device.supportsFamily(family) {
                parts.append("Apple family \(raw - 1000)")
                break
            }
        }
        return parts.isEmpty ? "Supported" : parts.joined(separator: ", ")
    }

    private static func gpuStatistics() -> [String: Any] {
        var busiest: [String: Any] = [:]
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"),
                                           &iterator) == KERN_SUCCESS else { return busiest }
        defer { IOObjectRelease(iterator) }
        var service = IOIteratorNext(iterator)
        while service != 0 {
            if let statistics = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString,
                                                                kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any],
               (statistics["Device Utilization %"] as? Int ?? -1)
                   >= (busiest["Device Utilization %"] as? Int ?? -1) {
                busiest = statistics
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return busiest
    }

    // MARK: - Temperature

    static func temperature(_ temperatures: TemperatureReading,
                            _ state: SystemReading,
                            _ health: HealthReading,
                            fahrenheit: Bool) -> [FactGroup] {
        func degrees(_ celsius: Double) -> String { Format.temperature(celsius, fahrenheit: fahrenheit) }

        var summary: [Fact] = []
        if let hottest = temperatures.hottestDie {
            summary.append(Fact("Chip, hottest sensor", degrees(hottest),
                                fraction: heat(hottest), tone: heatTone(hottest)))
        }
        if let average = temperatures.averageDie {
            summary.append(Fact("Chip, average", degrees(average)))
        }
        if let battery = temperatures.battery { summary.append(Fact("Battery", degrees(battery))) }
        if let storage = temperatures.storage { summary.append(Fact("SSD, sensor", degrees(storage))) }
        for drive in health.drives {
            if let celsius = drive.temperature {
                summary.append(Fact("SSD, its own report", degrees(celsius)))
            }
        }
        summary.append(Fact("macOS thermal state", state.thermalDescription,
                            tone: state.thermalState == .critical ? .critical
                                : state.thermalState == .serious ? .warning : .good))

        var groups = [FactGroup("Summary", footnote:
            "The thermal state is macOS's own verdict, and the one that matters: \u{201C}Hot\u{201D} "
            + "and \u{201C}Throttling\u{201D} mean it is slowing the Mac down to cool it.", summary)]

        if !temperatures.all.isEmpty {
            // macOS gives some sensors the same name. Those are numbered in
            // the order macOS lists them, which does not change, so each
            // keeps its own name when picked for the Overview, however the
            // hottest-first order shuffles them.
            let totals = Dictionary(temperatures.all.map { ($0.name, 1) }, uniquingKeysWith: +)
            var seen: [String: Int] = [:]
            let named = temperatures.all.map { sample -> (name: String, celsius: Double) in
                seen[sample.name, default: 0] += 1
                let name = totals[sample.name, default: 1] > 1
                    ? "\(sample.name) #\(seen[sample.name]!)" : sample.name
                return (name, sample.celsius)
            }
            let sensors = named
                .sorted { $0.celsius > $1.celsius }
                .map { Fact($0.name, degrees($0.celsius), fraction: heat($0.celsius), tone: heatTone($0.celsius)) }
            groups.append(FactGroup("Every sensor", subtitle: "\(sensors.count), hottest first", footnote:
                "Apple does not say which sensor sits over which part of the chip, so these keep "
                + "the names macOS gives them. The CPU and GPU share one piece of silicon, which is "
                + "why there is no separate GPU temperature.", sensors))
        }
        return groups
    }

    /// Chips idle in the thirties and throttle near a hundred, so bars run
    /// over that range rather than from zero.
    private static func heat(_ celsius: Double) -> Double { min(max((celsius - 30) / 65, 0), 1) }

    private static func heatTone(_ celsius: Double) -> Fact.Tone {
        celsius >= 90 ? .critical : celsius >= 75 ? .warning : .good
    }

    // MARK: - Power

    static func power(_ power: PowerReading,
                      _ batteryTemperature: Double?,
                      _ state: SystemReading,
                      fahrenheit: Bool) -> [FactGroup] {
        let battery = smartBattery()
        var groups: [FactGroup] = []

        var now: [Fact] = []
        if let percentage = power.percentage {
            now.append(Fact("Charge", "\(Int(percentage.rounded()))%", fraction: percentage / 100,
                            tone: percentage < 20 && !power.isPluggedIn ? .critical : .good))
        }
        now.append(Fact("State", power.isCharging ? "Charging"
                        : power.isPluggedIn ? "On mains power" : "On battery"))
        if let minutes = power.minutesRemaining {
            now.append(Fact(power.isCharging ? "Until full" : "Time left",
                            Format.duration(minutes: minutes)))
        }
        if let watts = power.watts {
            now.append(Fact(power.isCharging ? "Charging at" : "Drawing", String(format: "%.2f W", watts)))
        }
        if let voltage = power.voltage { now.append(Fact("Voltage", String(format: "%.2f V", voltage))) }
        if let amperage = power.amperage { now.append(Fact("Current", String(format: "%.3f A", amperage))) }
        if let celsius = batteryTemperature {
            now.append(Fact("Temperature", Format.temperature(celsius, fahrenheit: fahrenheit)))
        }
        now.append(Fact("Low Power Mode", state.lowPowerMode ? "On" : "Off"))
        groups.append(FactGroup("Right now", now))

        var health: [Fact] = []
        if let percent = power.healthPercentage {
            health.append(Fact("Health, as macOS reports it", "\(Int(percent.rounded()))%",
                               fraction: percent / 100, tone: percent < 80 ? .warning : .good))
        }
        if let condition = batteryCondition() {
            health.append(Fact("Condition", condition.text, tone: condition.isWorn ? .warning : .good))
        }
        if let cycles = power.cycleCount {
            let rated = battery["DesignCycleCount9C"] as? Int ?? 1000
            health.append(Fact("Charge cycles", "\(Format.count(cycles)) of \(Format.count(rated))",
                               fraction: Double(cycles) / Double(max(rated, 1))))
        }
        let data = battery["BatteryData"] as? [String: Any] ?? [:]
        func milliampHours(_ key: String) -> Int? { battery[key] as? Int ?? data[key] as? Int }
        let design = milliampHours("DesignCapacity")
        if let design { health.append(Fact("Capacity when new", "\(Format.count(design)) mAh")) }
        if let full = milliampHours("AppleRawMaxCapacity") {
            var text = "\(Format.count(full)) mAh"
            if let design, design > 0 { text += "  (\(Int((Double(full) / Double(design) * 100).rounded()))%)" }
            health.append(Fact("Holds when full, now", text))
        }
        if let current = milliampHours("AppleRawCurrentCapacity") {
            health.append(Fact("Holding right now", "\(Format.count(current)) mAh"))
        }
        if let maker = battery["Manufacturer"] as? String ?? data["Manufacturer"] as? String {
            health.append(Fact("Made by", maker))
        }
        if let chip = battery["DeviceName"] as? String {
            health.append(Fact("Charge-measuring chip", chip))
        }
        if !health.isEmpty {
            groups.append(FactGroup("Battery health", footnote:
                "macOS rounds its health figure and keeps it steady; the milliamp-hours come "
                + "straight from the battery's own measuring chip, which is why the two can differ "
                + "by a few points. Apple rates its current Mac batteries for \(battery["DesignCycleCount9C"] as? Int ?? 1000) "
                + "cycles, and considers one worn below 80%.", health))
        }

        if let adapter = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any] {
            var facts: [Fact] = []
            if let name = adapter["Name"] as? String {
                facts.append(Fact("Adapter", name.trimmingCharacters(in: .whitespaces)))
            }
            if let watts = adapter["Watts"] as? Int { facts.append(Fact("Supplying up to", "\(watts) W")) }
            if let millivolts = adapter["AdapterVoltage"] as? Int ?? adapter["Voltage"] as? Int {
                facts.append(Fact("At", String(format: "%.0f V", Double(millivolts) / 1000)))
            }
            if let milliamps = adapter["Current"] as? Int {
                facts.append(Fact("Current", String(format: "%.2f A", Double(milliamps) / 1000)))
            }
            if !facts.isEmpty { groups.append(FactGroup("Power adapter", facts)) }
        } else {
            groups.append(FactGroup("Power adapter", [Fact("Adapter", "not connected")]))
        }
        return groups
    }

    /// The battery's registry entry: the raw figures the friendly power API
    /// leaves out.
    private static func smartBattery() -> [String: Any] {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return [:] }
        defer { IOObjectRelease(service) }
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS
        else { return [:] }
        return properties?.takeRetainedValue() as? [String: Any] ?? [:]
    }

    /// The same verdict System Settings gives, in its words.
    private static func batteryCondition() -> (text: String, isWorn: Bool)? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?
                    .takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
            else { continue }
            if let condition = description["BatteryHealthCondition"] as? String, !condition.isEmpty {
                return (condition, true)
            }
            switch description[kIOPSBatteryHealthKey] as? String {
            case "Good": return ("Normal", false)
            case "Fair": return ("Fair", true)
            case "Poor": return ("Service recommended", true)
            default: return nil
            }
        }
        return nil
    }

    // MARK: - Storage

    static func storage(_ storage: StorageReading,
                        _ health: HealthReading,
                        fahrenheit: Bool) -> [FactGroup] {
        var groups: [FactGroup] = []

        for (index, drive) in health.drives.enumerated() {
            var facts = [
                Fact("Health", "\(drive.healthPercent)%", fraction: Double(drive.healthPercent) / 100,
                     tone: drive.healthPercent < 50 ? .critical : drive.healthPercent < 80 ? .warning : .good),
            ]
            if drive.warnings.isEmpty {
                facts.append(Fact("Its own alarms", "none", tone: .good))
            } else {
                for warning in drive.warnings { facts.append(Fact("Alarm", warning, tone: .critical)) }
            }
            facts += [
                Fact("Rated life used", "\(drive.percentUsed)%"),
                Fact("Spare capacity", "\(drive.availableSpare)%  (warns below \(drive.spareThreshold)%)",
                     tone: drive.availableSpare <= drive.spareThreshold ? .critical : .normal),
                Fact("Written in its lifetime", Format.decimalBytes(drive.dataWritten)),
                Fact("Read in its lifetime", Format.decimalBytes(drive.dataRead)),
                Fact("Powered on for", poweredOn(hours: drive.powerOnHours)),
                Fact("Times switched on", Format.count(drive.powerCycles)),
                Fact("Unsafe shutdowns", Format.count(drive.unsafeShutdowns)),
                Fact("Media errors", Format.count(drive.mediaErrors),
                     tone: drive.mediaErrors > 0 ? .critical : .good),
                Fact("Error log entries", Format.count(drive.errorLogEntries)),
            ]
            if let celsius = drive.temperature {
                facts.append(Fact("Temperature", Format.temperature(celsius, fahrenheit: fahrenheit)))
            }
            facts.append(Fact("Size", Format.decimalBytes(drive.capacity)))
            if let firmware = drive.firmware { facts.append(Fact("Firmware", firmware)) }
            facts.append(Fact("Connection", [drive.interconnect, drive.isInternal ? "internal" : "external"]
                .compactMap { $0 }.joined(separator: ", ")))

            groups.append(FactGroup(drive.name, subtitle: "drive",
                                    footnote: index == 0 ? driveFootnote : nil, facts))
        }
        if health.drives.isEmpty {
            groups.append(FactGroup("Drive health", footnote:
                "No drive here offers the NVMe health log. Drives on USB rarely do; Apple's internal "
                + "SSDs and most Thunderbolt NVMe drives do.", [Fact("Health report", "not available")]))
        }

        for volume in volumeDetails() { groups.append(volume) }

        groups.append(FactGroup("Activity", [
            Fact("Reading now", Format.rateLong(storage.readRate)),
            Fact("Writing now", Format.rateLong(storage.writeRate)),
            Fact("Read since the Mac started", Format.bytes(storage.readTotal)),
            Fact("Written since the Mac started", Format.bytes(storage.writeTotal)),
        ]))
        return groups
    }

    private static let driveFootnote =
        "Health is how much of its rated endurance the drive estimates it has left \u{2014} the "
        + "figure iStat Menus calls health. SSDs wear by being written to, so the lifetime total "
        + "written is what wears it down. Unsafe shutdowns are times the power went without the Mac "
        + "shutting down first; a few are harmless. Media errors are data the drive could not "
        + "recover, and any at all mean it is time to back up. Drive sizes use the thousands "
        + "drive makers use, so 1 TB here is a trillion bytes."

    private static func poweredOn(hours: UInt64) -> String {
        let days = Double(hours) / 24
        if days < 2 { return "\(Format.count(hours)) hours" }
        return "\(Format.count(hours)) hours (about \(Int(days.rounded())) days)"
    }

    private static func volumeDetails() -> [FactGroup] {
        let keys: [URLResourceKey] = [
            .volumeNameKey, .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeIsInternalKey, .volumeLocalizedFormatDescriptionKey,
            .volumeIsEncryptedKey, .volumeIsReadOnlyKey,
        ]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                         options: [.skipHiddenVolumes]) ?? []
        var groups: [(internal: Bool, size: Int, group: FactGroup)] = []
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  let total = values.volumeTotalCapacity, total > 0
            else { continue }
            let free = max(Int(values.volumeAvailableCapacityForImportantUsage ?? 0), 0)
            let used = max(total - free, 0)
            let fraction = Double(used) / Double(total)
            let isInternal = values.volumeIsInternal ?? false
            var facts = [
                Fact("Used", "\(Format.decimalBytes(UInt64(used))) of \(Format.decimalBytes(UInt64(total)))",
                     fraction: fraction),
                Fact("Free", Format.decimalBytes(UInt64(free))),
            ]
            if let format = values.volumeLocalizedFormatDescription { facts.append(Fact("Format", format)) }
            facts.append(Fact("Mounted at", url.path))
            facts.append(Fact("Location", isInternal ? "Internal" : "External"))
            // On an internal drive this is FileVault. Apple Silicon encrypts its
            // internal storage in hardware regardless; what FileVault adds is
            // that the key needs your password, so "No" here does not mean the
            // data sits on the drive in the clear.
            if let encrypted = values.volumeIsEncrypted {
                facts.append(Fact(isInternal ? "FileVault" : "Encrypted",
                                  encrypted ? (isInternal ? "On" : "Yes") : (isInternal ? "Off" : "No")))
            }
            if values.volumeIsReadOnly == true { facts.append(Fact("Read-only", "Yes")) }
            groups.append((isInternal, total,
                           FactGroup(values.volumeName ?? url.lastPathComponent, subtitle: "volume", facts)))
        }
        // The boot disk first, then biggest first, as in the Overview.
        return groups.sorted { left, right in
            left.internal != right.internal ? left.internal : left.size > right.size
        }.map(\.group)
    }

    // MARK: - Network

    static func network(_ network: NetworkReading) -> [FactGroup] {
        var groups = [FactGroup("Right now", [
            Fact("Downloading", Format.rateLong(network.downRate)),
            Fact("Uploading", Format.rateLong(network.upRate)),
            Fact("Received since the Mac started", Format.bytes(network.downTotal)),
            Fact("Sent since the Mac started", Format.bytes(network.upTotal)),
        ])]

        let store = SCDynamicStoreCreate(nil, "Gauge" as CFString, nil, nil)
        let global = store.flatMap { SCDynamicStoreCopyValue($0, "State:/Network/Global/IPv4" as CFString) }
            as? [String: Any] ?? [:]
        let dns = store.flatMap { SCDynamicStoreCopyValue($0, "State:/Network/Global/DNS" as CFString) }
            as? [String: Any] ?? [:]
        let names = friendlyInterfaceNames()

        var connection: [Fact] = []
        if let primary = global["PrimaryInterface"] as? String {
            connection.append(Fact("Using", names[primary].map { "\($0) (\(primary))" } ?? primary))
        }
        if let router = global["Router"] as? String { connection.append(Fact("Router", router)) }
        if let servers = dns["ServerAddresses"] as? [String], !servers.isEmpty {
            connection.append(Fact(servers.count == 1 ? "DNS server" : "DNS servers",
                                   servers.prefix(3).joined(separator: ", ")))
        }
        if let store, let host = SCDynamicStoreCopyLocalHostName(store) as String? {
            connection.append(Fact("This Mac on the network", "\(host).local"))
        }
        if !connection.isEmpty {
            groups.append(FactGroup("Connection", footnote:
                "The Wi-Fi network's name is not shown: macOS only reveals it to apps that are "
                + "allowed to know your location, and Gauge does not ask. For the same kind of "
                + "privacy reason macOS hides hardware (MAC) addresses from apps, so those are "
                + "left out.", connection))
        }

        let addresses = interfaceAddresses()
        // The exact totals and real hardware addresses, which only netstat
        // is allowed to see. The network sampler runs it in the background
        // once a minute; it must never run here, because this is built while
        // the panel is being drawn, and waiting on another program then makes
        // SwiftUI abort. Without it, the cut-down 32-bit counts are shown and
        // the hardware address is left out rather than shown as a fake.
        var idle: [String] = []

        for interface in InterfaceCounters.readAll() where interface.name.hasPrefix("en") {
            let known = addresses[interface.name]
            let name = names[interface.name] ?? interface.name
            let isConnected = interface.isUp && interface.baudRate > 0
            // Thunderbolt ports and adapters with nothing plugged in are listed
            // by name at the end rather than given a block of zeros each.
            guard isConnected || known != nil || interface.packetsIn > 0 else {
                idle.append(name)
                continue
            }

            var facts = [Fact("Status", isConnected ? "Connected" : "No link",
                              tone: isConnected ? .good : .normal)]
            if let ipv4 = known?.ipv4.first { facts.append(Fact("IPv4 address", ipv4)) }
            if let ipv6 = known?.ipv6.first { facts.append(Fact("IPv6 address", ipv6)) }
            if let hardware = network.hardwareAddresses[interface.name] {
                facts.append(Fact("Hardware address", hardware))
            }
            if interface.baudRate > 0 {
                facts.append(Fact("Link speed", "\(Format.count(interface.baudRate / 1_000_000)) Mbit/s"))
            }
            let received = network.totalsByInterface[interface.name]?.down ?? interface.bytesIn
            let sent = network.totalsByInterface[interface.name]?.up ?? interface.bytesOut
            facts += [
                Fact("Largest packet (MTU)", "\(interface.mtu) bytes"),
                Fact("Received since the Mac started", Format.bytes(received)),
                Fact("Sent since the Mac started", Format.bytes(sent)),
                Fact("Packets in / out", "\(Format.count(interface.packetsIn)) / \(Format.count(interface.packetsOut))"),
                Fact("Errors in / out", "\(Format.count(interface.errorsIn)) / \(Format.count(interface.errorsOut))",
                     tone: interface.errorsIn + interface.errorsOut > 0 ? .warning : .normal),
            ]
            groups.append(FactGroup(name, subtitle: interface.name, facts))
        }
        if !idle.isEmpty {
            groups.append(FactGroup("Not connected", [Fact(idle.count == 1 ? "Port" : "Ports",
                                                           idle.sorted().joined(separator: ", "))]))
        }
        return groups
    }

    /// "Wi-Fi" for en0, "Thunderbolt Bridge" for bridge0, and so on: the names
    /// System Settings shows rather than the kernel's.
    private static func friendlyInterfaceNames() -> [String: String] {
        guard let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return [:] }
        var names: [String: String] = [:]
        for interface in interfaces {
            if let bsd = SCNetworkInterfaceGetBSDName(interface) as String?,
               let name = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String? {
                names[bsd] = name
            }
        }
        return names
    }

    private static func interfaceAddresses() -> [String: (ipv4: [String], ipv6: [String])] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [:] }
        defer { freeifaddrs(head) }

        var result: [String: (ipv4: [String], ipv6: [String])] = [:]
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = pointer {
            pointer = entry.pointee.ifa_next
            guard let address = entry.pointee.ifa_addr else { continue }
            let family = Int32(address.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length = socklen_t(family == AF_INET ? MemoryLayout<sockaddr_in>.size
                                                      : MemoryLayout<sockaddr_in6>.size)
            guard getnameinfo(address, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0
            else { continue }
            // Link-local IPv6 addresses carry a "%en0" suffix that says nothing new.
            let text = String(cString: host).components(separatedBy: "%").first ?? ""
            let name = String(cString: entry.pointee.ifa_name)
            var known = result[name] ?? ([], [])
            if family == AF_INET {
                known.ipv4.append(text)
            } else if text.hasPrefix("fe80") {
                known.ipv6.append(text)            // link-local: only if nothing better
            } else {
                known.ipv6.insert(text, at: 0)     // a routable address leads
            }
            result[name] = known
        }
        return result
    }

    // MARK: - System

    static func system(_ info: SystemInfo, _ state: SystemReading, _ archive: HistoryArchive) -> [FactGroup] {
        var mac = [
            Fact("Model", info.modelName),
            Fact("Model identifier", info.modelIdentifier),
        ]
        if let serial = platformSerial() { mac.append(Fact("Serial number", serial)) }
        mac += [
            Fact("Chip", info.chip),
            Fact("CPU cores", "\(info.totalCores) (\(info.performanceCores) performance, "
                 + "\(info.efficiencyCores) efficiency)"),
        ]
        if info.gpuCores > 0 { mac.append(Fact("GPU cores", "\(info.gpuCores)")) }
        mac.append(Fact("Memory", Format.bytes(info.memoryBytes, decimals: 0)))

        let macOS = [
            Fact("Version", "macOS \(info.osVersion)"),
            Fact("Build", info.osBuild),
            Fact("Kernel", "Darwin \(Sysctl.string("kern.osrelease") ?? "")"),
            Fact("Started", info.bootedAt.formatted(date: .abbreviated, time: .shortened)),
            Fact("Running for", Format.uptime(state.uptime)),
            Fact("Thermal state", state.thermalDescription),
            Fact("Low Power Mode", state.lowPowerMode ? "On" : "Off"),
        ]

        var you: [Fact] = []
        let store = SCDynamicStoreCreate(nil, "Gauge" as CFString, nil, nil)
        if let name = SCDynamicStoreCopyComputerName(store, nil) as String? {
            you.append(Fact("Computer name", name))
        }
        if let store, let host = SCDynamicStoreCopyLocalHostName(store) as String? {
            you.append(Fact("Network name", "\(host).local"))
        }
        you.append(Fact("Signed in as", "\(NSFullUserName()) (\(NSUserName()))"))

        var gauge = [
            Fact("Version", Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "\u{2013}"),
            Fact("Installed at", Bundle.main.bundlePath),
        ]
        let file = archive.fileLocation
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)??.uint64Value
        if let earliest = archive.earliest {
            gauge.append(Fact("History kept since", earliest.formatted(date: .abbreviated, time: .shortened)))
        }
        gauge.append(Fact("History saved", "\(Format.count(archive.rows.count)) minutes"
                          + (size.map { ", \(Format.bytes($0))" } ?? "")))
        gauge.append(Fact("History file", file.path))

        return [
            FactGroup("This Mac", mac),
            FactGroup("macOS", macOS),
            FactGroup("You", you),
            FactGroup("Gauge", gauge),
        ]
    }

    private static func platformSerial() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(service, "IOPlatformSerialNumber" as CFString,
                                               kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
    }

    private static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }
}

/// Small helpers for reading kernel settings by name.
enum Sysctl {
    static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    /// Some of these are 32 bits wide and some 64, depending on the name; the
    /// size the kernel reports says which.
    static func integer(_ name: String) -> Int64? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0 else { return nil }
        if size == 4 {
            var value: Int32 = 0
            guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
            return Int64(value)
        }
        var value: Int64 = 0
        size = 8
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }
}
