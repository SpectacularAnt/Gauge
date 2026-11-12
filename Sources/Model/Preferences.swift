import Foundation
import Combine

/// Which column the Apps tab is ordered by.
enum AppSortColumn: String, CaseIterable, Identifiable {
    case cpu     = "CPU"
    case gpu     = "GPU"
    case power   = "Power"
    case memory  = "RAM"
    var id: String { rawValue }
}

/// How each reading is drawn in the menu bar.  The menu bar has very little
/// room — especially on a Mac with a notch — so this is really a width control:
/// icons are narrower than text labels, and bare values are narrower still.
enum MenuBarStyle: String, CaseIterable, Identifiable {
    case icons  = "Icons"
    case labels = "Labels"
    case values = "Values only"
    var id: String { rawValue }
}

/// What the user has chosen, remembered across launches in `UserDefaults`.
final class Preferences: ObservableObject {

    /// Which readouts appear in the menu bar.  They are drawn in the order
    /// `Metric.allCases` declares, so the bar stays in a predictable order no
    /// matter which order they were switched on.
    @Published var enabled: Set<Metric> {
        didSet { save() }
    }
    /// Seconds between readings.
    @Published var refreshInterval: Double {
        didSet { save() }
    }
    @Published var useFahrenheit: Bool {
        didSet { save() }
    }
    @Published var menuBarStyle: MenuBarStyle {
        didSet { save() }
    }
    /// Overview sections the user has folded away. Stored as the closed ones so
    /// that a section added in a later version starts open rather than hidden.
    @Published var collapsedSections: Set<String> {
        didSet { save() }
    }
    /// Minutes of history the trend lines cover.
    @Published var historyMinutes: Double {
        didSet { save() }
    }
    @Published var appSortColumn: AppSortColumn {
        didSet { save() }
    }
    /// Largest first, which is what you want for "who is eating my battery".
    @Published var appSortDescending: Bool {
        didSet { save() }
    }
    /// The switch over everything to do with busy programs: the warning signs
    /// in the Apps tab, the count in the menu bar, and the notifications.
    /// Off, the limits below do nothing, so Settings stops offering them.
    @Published var appAlertsEnabled: Bool {
        didSet { save() }
    }
    /// Where an app earns a warning sign.
    @Published var alertLimits: AlertLimits {
        didSet { save() }
    }
    /// How far back the Overview charts are showing.
    @Published var trendRange: TrendRange {
        didSet { save() }
    }
    /// When Gauge is allowed to interrupt you.
    @Published var notifyAppAlerts: Bool {
        didSet { save() }
    }
    /// Minutes a program must stay over a limit before it is mentioned.
    @Published var notifyAfterMinutes: Double {
        didSet { save() }
    }
    @Published var notifyLowDisk: Bool {
        didSet { save() }
    }
    @Published var notifyThermal: Bool {
        didSet { save() }
    }
    /// Health alerts: tell me when a part wears below a limit.
    @Published var notifyBatteryHealth: Bool {
        didSet { save() }
    }
    /// Percent of the battery's original capacity.
    @Published var batteryHealthLimit: Double {
        didSet { save() }
    }
    @Published var notifyDriveHealth: Bool {
        didSet { save() }
    }
    /// Percent of the drive's rated life left.
    @Published var driveHealthLimit: Double {
        didSet { save() }
    }
    /// When each health alert last went out. Saved so that a restart does not
    /// set them all off again.
    @Published var healthAlertsSaid: [String: Date] {
        didSet { save() }
    }

    /// Devices whose battery is shown in the menu bar, by `DeviceInfo.id`,
    /// in the order they were added. Chosen on each device's page.
    @Published var menuBarDevices: [String] {
        didSet { save() }
    }

    /// For devices that should only appear when their battery is low: the
    /// level they must be below. A device not in here shows whenever it is
    /// connected.
    @Published var menuBarDeviceLimits: [String: Int] {
        didSet { save() }
    }

    static let deviceLimitRange: ClosedRange<Double> = 5...95
    static let defaultDeviceLimit = 20

    func showsInMenuBar(device id: String) -> Bool {
        menuBarDevices.contains(id)
    }

    func setInMenuBar(device id: String, _ shown: Bool) {
        menuBarDevices.removeAll { $0 == id }
        if shown { menuBarDevices.append(id) }
    }

    /// Whether a device in the menu bar should be drawn at this level.
    func menuBarWants(device id: String, level: Int) -> Bool {
        guard showsInMenuBar(device: id) else { return false }
        guard let limit = menuBarDeviceLimits[id] else { return true }
        return level < limit
    }

    /// The order the Overview's sections come in, top to bottom. Always holds
    /// every section exactly once; one this Mac cannot show, like Power on a
    /// desktop, keeps its place but is skipped when drawing.
    @Published var sectionOrder: [OverviewSection] {
        didSet { save() }
    }

    /// Swaps two sections' places.
    func swapSections(_ first: OverviewSection, _ second: OverviewSection) {
        guard let a = sectionOrder.firstIndex(of: first),
              let b = sectionOrder.firstIndex(of: second) else { return }
        sectionOrder.swapAt(a, b)
    }

    /// A saved order, repaired: anything unknown or repeated is dropped, and a
    /// section added in a later version of Gauge goes on the end.
    static func completeOrder(_ stored: [OverviewSection]) -> [OverviewSection] {
        var order: [OverviewSection] = []
        for section in stored where !order.contains(section) { order.append(section) }
        for section in OverviewSection.allCases where !order.contains(section) { order.append(section) }
        return order
    }

    /// Which lines each Overview section lists under its chart, chosen on the
    /// section's Inspect page.
    @Published var overviewDetails: Set<OverviewDetail> {
        didSet { save() }
    }

    /// Facts from the Inspect pages picked to be shown in the Overview too,
    /// by `Inspector.key`. Each section draws its own from here.
    @Published var overviewFacts: Set<String> {
        didSet { save() }
    }

    func showsFact(_ key: String) -> Bool {
        overviewFacts.contains(key)
    }

    func setFactShown(_ key: String, _ shown: Bool) {
        if shown {
            overviewFacts.insert(key)
        } else {
            overviewFacts.remove(key)
        }
    }

    /// The picked facts belonging to one section.
    func factKeys(for section: OverviewSection) -> Set<String> {
        overviewFacts.filter { $0.hasPrefix("\(section.rawValue)|") }
    }

    func shows(_ detail: OverviewDetail) -> Bool {
        overviewDetails.contains(detail)
    }

    func setShown(_ detail: OverviewDetail, _ shown: Bool) {
        if shown {
            overviewDetails.insert(detail)
        } else {
            overviewDetails.remove(detail)
        }
    }

    /// Puts one section back to what it showed out of the box, leaving the
    /// others alone.
    func resetDetails(for section: OverviewSection) {
        let theirs = Set(OverviewDetail.options(for: section))
        overviewDetails = overviewDetails.subtracting(theirs)
            .union(OverviewDetail.defaults.intersection(theirs))
        overviewFacts.subtract(factKeys(for: section))
    }

    func detailsAreDefault(for section: OverviewSection) -> Bool {
        let theirs = Set(OverviewDetail.options(for: section))
        return overviewDetails.intersection(theirs) == OverviewDetail.defaults.intersection(theirs)
            && factKeys(for: section).isEmpty
    }

    static let batteryHealthRange: ClosedRange<Double> = 50...95
    static let driveHealthRange: ClosedRange<Double> = 10...95

    /// Whether a readout is actually drawn. The App alerts count also needs
    /// app alerts as a whole to be on, without forgetting it was chosen.
    func shows(_ metric: Metric) -> Bool {
        enabled.contains(metric) && (metric != .appAlerts || appAlertsEnabled)
    }

    /// App notifications only go out while app alerts as a whole are on.
    private var notifiesAppAlerts: Bool { appAlertsEnabled && notifyAppAlerts }

    var notificationSettings: AlertWatcher.Settings {
        AlertWatcher.Settings(appAlerts: notifiesAppAlerts,
                              sustained: notifyAfterMinutes * 60,
                              lowDisk: notifyLowDisk,
                              thermal: notifyThermal,
                              batteryHealth: notifyBatteryHealth,
                              batteryHealthLimit: batteryHealthLimit,
                              driveHealth: notifyDriveHealth,
                              driveHealthLimit: driveHealthLimit)
    }

    /// True when nothing is asking to be notified, which is what lets the
    /// Settings card explain the cost only when it is actually being paid.
    var notificationsAllOff: Bool {
        !notifiesAppAlerts && !notifyLowDisk && !notifyThermal
            && !notifyBatteryHealth && !notifyDriveHealth
    }

    private enum Key {
        static let enabled = "enabledMetrics"
        static let interval = "refreshInterval"
        static let fahrenheit = "useFahrenheit"
        static let style = "menuBarStyle"
        static let collapsed = "collapsedSections"
        static let historyMinutes = "historyMinutes"
        static let appSort = "appSortColumn"
        static let appSortDescending = "appSortDescending"
        static let appAlertsEnabled = "appAlertsEnabled"
        static let alertCPU = "alertLimitCPU"
        static let alertGPU = "alertLimitGPU"
        static let alertPower = "alertLimitPower"
        static let alertMemory = "alertLimitMemory"
        static let trendRange = "trendRange"
        static let notifyAppAlerts = "notifyAppAlerts"
        static let notifyAfterMinutes = "notifyAfterMinutes"
        static let notifyLowDisk = "notifyLowDisk"
        static let notifyThermal = "notifyThermal"
        static let notifyBatteryHealth = "notifyBatteryHealth"
        static let batteryHealthLimit = "batteryHealthLimit"
        static let notifyDriveHealth = "notifyDriveHealth"
        static let driveHealthLimit = "driveHealthLimit"
        static let healthAlertsSaid = "healthAlertsSaid"
        static let overviewDetails = "overviewDetails"
        static let overviewFacts = "overviewFacts"
        static let sectionOrder = "sectionOrder"
        static let menuBarDevices = "menuBarDevices"
        static let menuBarDeviceLimits = "menuBarDeviceLimits"
    }

    /// What a new install starts with: enough to be useful, few enough to fit.
    static let defaultMetrics: Set<Metric> = [.cpuUsage, .chipTemperature, .memoryUsage]

    /// Everything is present, but the sections people glance at least often
    /// start folded, so the panel opens on something readable rather than on a
    /// wall. A folded section still shows its headline and its trend.
    static let defaultCollapsedSections: Set<String> = ["Storage", "Network", "System"]

    init() {
        let defaults = UserDefaults.standard

        if let stored = defaults.array(forKey: Key.enabled) as? [String] {
            let restored = stored.compactMap(Metric.init(rawValue:))
            enabled = Set(restored)
        } else {
            enabled = Self.defaultMetrics
        }

        let storedInterval = defaults.double(forKey: Key.interval)
        refreshInterval = storedInterval > 0 ? storedInterval : 2
        useFahrenheit = defaults.bool(forKey: Key.fahrenheit)
        menuBarStyle = (defaults.string(forKey: Key.style)).flatMap(MenuBarStyle.init(rawValue:)) ?? .icons
        if let stored = defaults.array(forKey: Key.collapsed) as? [String] {
            collapsedSections = Set(stored)
        } else {
            collapsedSections = Self.defaultCollapsedSections
        }
        let storedMinutes = defaults.double(forKey: Key.historyMinutes)
        historyMinutes = storedMinutes > 0 ? min(max(storedMinutes, 1), 30) : 4
        appSortColumn = defaults.string(forKey: Key.appSort)
            .flatMap(AppSortColumn.init(rawValue:)) ?? .cpu
        appSortDescending = defaults.object(forKey: Key.appSortDescending) as? Bool ?? true

        trendRange = defaults.string(forKey: Key.trendRange)
            .flatMap(TrendRange.init(rawValue:)) ?? .live

        // All off to begin with: notifications are the one thing here that
        // interrupts, so they are opted into rather than out of.
        notifyAppAlerts = defaults.bool(forKey: Key.notifyAppAlerts)
        notifyLowDisk = defaults.bool(forKey: Key.notifyLowDisk)
        notifyThermal = defaults.bool(forKey: Key.notifyThermal)
        let storedAfter = defaults.double(forKey: Key.notifyAfterMinutes)
        notifyAfterMinutes = storedAfter > 0 ? min(max(storedAfter, 1), 30) : 5

        // 80% for the battery is the line Apple itself uses for a worn
        // battery. Half for the drive is earlier than strictly necessary —
        // drives often outlive their rating — but it leaves plenty of time to
        // plan, which is the point of being told.
        notifyBatteryHealth = defaults.bool(forKey: Key.notifyBatteryHealth)
        notifyDriveHealth = defaults.bool(forKey: Key.notifyDriveHealth)
        let storedBattery = defaults.double(forKey: Key.batteryHealthLimit)
        batteryHealthLimit = storedBattery > 0
            ? min(max(storedBattery, Self.batteryHealthRange.lowerBound), Self.batteryHealthRange.upperBound)
            : 80
        let storedDrive = defaults.double(forKey: Key.driveHealthLimit)
        driveHealthLimit = storedDrive > 0
            ? min(max(storedDrive, Self.driveHealthRange.lowerBound), Self.driveHealthRange.upperBound)
            : 50
        healthAlertsSaid = defaults.dictionary(forKey: Key.healthAlertsSaid) as? [String: Date] ?? [:]
        if let stored = defaults.array(forKey: Key.overviewDetails) as? [String] {
            overviewDetails = Set(stored.compactMap(OverviewDetail.init(rawValue:)))
        } else {
            overviewDetails = OverviewDetail.defaults
        }
        overviewFacts = Set(defaults.stringArray(forKey: Key.overviewFacts) ?? [])
        menuBarDevices = defaults.stringArray(forKey: Key.menuBarDevices) ?? []
        menuBarDeviceLimits = (defaults.dictionary(forKey: Key.menuBarDeviceLimits) as? [String: Int] ?? [:])
            .mapValues { min(max($0, Int(Self.deviceLimitRange.lowerBound)), Int(Self.deviceLimitRange.upperBound)) }
        sectionOrder = Self.completeOrder(
            (defaults.stringArray(forKey: Key.sectionOrder) ?? []).compactMap(OverviewSection.init(rawValue:)))

        // On to begin with, because flagging busy programs in the Apps tab is
        // what Gauge has always done. It interrupts nobody.
        appAlertsEnabled = defaults.object(forKey: Key.appAlertsEnabled) as? Bool ?? true
        var limits = AlertLimits()
        if let value = defaults.object(forKey: Key.alertCPU) as? Double { limits.cpu = value }
        if let value = defaults.object(forKey: Key.alertGPU) as? Double { limits.gpu = value }
        if let value = defaults.object(forKey: Key.alertPower) as? Double { limits.power = value }
        if let value = defaults.object(forKey: Key.alertMemory) as? Double { limits.memory = value }
        alertLimits = limits.clamped()
    }

    private func save() {
        let defaults = UserDefaults.standard
        defaults.set(enabled.map(\.rawValue), forKey: Key.enabled)
        defaults.set(refreshInterval, forKey: Key.interval)
        defaults.set(useFahrenheit, forKey: Key.fahrenheit)
        defaults.set(menuBarStyle.rawValue, forKey: Key.style)
        defaults.set(Array(collapsedSections), forKey: Key.collapsed)
        defaults.set(historyMinutes, forKey: Key.historyMinutes)
        defaults.set(appSortColumn.rawValue, forKey: Key.appSort)
        defaults.set(appSortDescending, forKey: Key.appSortDescending)
        defaults.set(appAlertsEnabled, forKey: Key.appAlertsEnabled)
        defaults.set(alertLimits.cpu, forKey: Key.alertCPU)
        defaults.set(alertLimits.gpu, forKey: Key.alertGPU)
        defaults.set(alertLimits.power, forKey: Key.alertPower)
        defaults.set(alertLimits.memory, forKey: Key.alertMemory)
        defaults.set(trendRange.rawValue, forKey: Key.trendRange)
        defaults.set(notifyAppAlerts, forKey: Key.notifyAppAlerts)
        defaults.set(notifyAfterMinutes, forKey: Key.notifyAfterMinutes)
        defaults.set(notifyLowDisk, forKey: Key.notifyLowDisk)
        defaults.set(notifyThermal, forKey: Key.notifyThermal)
        defaults.set(notifyBatteryHealth, forKey: Key.notifyBatteryHealth)
        defaults.set(batteryHealthLimit, forKey: Key.batteryHealthLimit)
        defaults.set(notifyDriveHealth, forKey: Key.notifyDriveHealth)
        defaults.set(driveHealthLimit, forKey: Key.driveHealthLimit)
        defaults.set(healthAlertsSaid, forKey: Key.healthAlertsSaid)
        defaults.set(overviewDetails.map(\.rawValue), forKey: Key.overviewDetails)
        defaults.set(Array(overviewFacts), forKey: Key.overviewFacts)
        defaults.set(sectionOrder.map(\.rawValue), forKey: Key.sectionOrder)
        defaults.set(menuBarDevices, forKey: Key.menuBarDevices)
        defaults.set(menuBarDeviceLimits, forKey: Key.menuBarDeviceLimits)
    }

    func toggle(_ metric: Metric, on: Bool) {
        if on {
            enabled.insert(metric)
        } else {
            enabled.remove(metric)
        }
    }
}
