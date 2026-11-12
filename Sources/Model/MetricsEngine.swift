import Foundation
import Combine

/// Takes a reading on a timer and publishes it.
///
/// Reading the sensors means dozens of trips into the kernel, so it happens on a
/// background queue and only the finished `Snapshot` is handed back to the main
/// thread.  That keeps the menu bar responsive even if a sensor is slow to
/// answer.  Every sampler that remembers a previous value lives on that one
/// queue and is never touched from anywhere else, which is what makes this safe
/// without any locks.
final class MetricsEngine: ObservableObject {

    @Published private(set) var snapshot = Snapshot()
    /// Recent readings, so the panel can draw trends rather than just numbers.
    @Published private(set) var histories = Histories()
    /// The same readings kept on disk, a point a minute, for looking back
    /// further than memory reaches. Not published: it changes once a minute,
    /// and the panel redraws on every reading anyway.
    let archive: HistoryArchive
    /// How worn the drives are. Read at launch and every few minutes after,
    /// since wear changes over months rather than seconds.
    @Published private(set) var health = HealthReading()
    /// Decides when something is worth a notification.
    let watcher = AlertWatcher()
    /// The unchanging facts about this Mac, filled in after the first reading.
    @Published private(set) var system = SystemInfo()
    /// Thermal pressure, mounted volumes, network interfaces, displays.
    @Published private(set) var systemReading = SystemReading()
    /// Per-app figures. Empty unless something is asking for them.
    @Published private(set) var apps: [AppRow] = []
    /// How many apps are currently over a threshold.
    @Published private(set) var alertCount = 0
    /// Everything paired or plugged in. Nil until the first look, so the
    /// Devices tab can tell "still looking" from "found nothing".
    @Published private(set) var devices: [DeviceInfo]?

    /// Set while the Devices tab is on screen. Devices are only looked for
    /// then: the Bluetooth report takes a moment and nothing else needs it.
    var isDevicesTabVisible = false {
        didSet {
            guard isDevicesTabVisible != oldValue else { return }
            if isDevicesTabVisible { refreshDevices() }
            updateDeviceSampling()
        }
    }
    /// Set while any device's battery is in the menu bar, which needs the
    /// devices looked at with the panel shut too, though less often.
    var needsDeviceBatteries = false {
        didSet {
            guard needsDeviceBatteries != oldValue else { return }
            if needsDeviceBatteries && devices == nil { refreshDevices() }
            updateDeviceSampling()
        }
    }
    private var deviceTimer: Timer?
    private var devicesReadAt: Date?
    /// Often enough to catch headphones connecting while the tab is open; the
    /// report is cheap but not free.
    private static let deviceInterval: TimeInterval = 10
    /// For the menu bar alone. Batteries fall about a percent every few
    /// minutes, so once a minute is plenty.
    private static let menuBarDeviceInterval: TimeInterval = 60

    /// One timer serves both: it ticks every ten seconds while either wants
    /// devices, and each tick looks again only if one of them is due.
    private func updateDeviceSampling() {
        let wanted = isDevicesTabVisible || needsDeviceBatteries
        guard wanted != (deviceTimer != nil) else { return }
        deviceTimer?.invalidate()
        deviceTimer = nil
        guard wanted else { return }
        let timer = Timer(timeInterval: Self.deviceInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            // The tab stays selected while the panel is shut; it only counts
            // while the panel is open.
            let tabDue = self.isDevicesTabVisible && self.isDetailVisible
            let menuBarDue = self.needsDeviceBatteries
                && (self.devicesReadAt.map { Date().timeIntervalSince($0) >= Self.menuBarDeviceInterval } ?? true)
            if tabDue || menuBarDue { self.refreshDevices() }
        }
        RunLoop.main.add(timer, forMode: .common)
        deviceTimer = timer
    }
    /// Its own queue, so a slow Bluetooth report never holds up the gauges.
    private let deviceQueue = DispatchQueue(label: "local.gauge.devices", qos: .utility)

    /// Looks again now, in the background.
    func refreshDevices() {
        devicesReadAt = Date()
        deviceQueue.async { [weak self] in
            let found = DeviceSampler.sample()
            DispatchQueue.main.async {
                guard let self, found != self.devices else { return }
                self.devices = found
            }
        }
    }

    /// True once temperatures are known to be unavailable, so the UI can say so
    /// rather than showing a permanently empty reading.
    @Published private(set) var temperaturesAvailable = true

    /// Set while the Apps tab is on screen.
    var isAppsTabVisible = false {
        didSet { if isAppsTabVisible != oldValue { updateAppSampling() } }
    }
    /// Set when the menu bar is showing the alert count, which needs the same
    /// data even with the panel shut.
    var needsAlertCount = false {
        didSet { if needsAlertCount != oldValue { updateAppSampling() } }
    }
    /// Notifying about a program over a limit means watching every program all
    /// the time, panel open or not — the same cost as the menu bar count.
    private(set) var notifiesAppAlerts = false
    /// The panel being open at all, for anything cheaper than the app list.
    var isDetailVisible = false
    /// Copied in from Preferences on the main thread, and read when each tick
    /// starts, so the sampling queue never touches Preferences itself.
    var alertLimits = AlertLimits()

    private let queue = DispatchQueue(label: "local.gauge.sampling", qos: .utility)
    private var timer: Timer?

    // Owned by `queue` only.
    private let cpu = CPUSampler()
    private let memory = MemorySampler()
    private let gpu = GPUSampler()
    private let storage = StorageSampler()
    private let network = NetworkSampler()
    private let power = PowerSampler()
    private let appSampler = AppSampler()
    private let temperature = TemperatureSampler()
    private let healthSampler = HealthSampler()
    /// When drive health was last read. Owned by `queue`.
    private var healthReadAt: Date?
    private static let healthInterval: TimeInterval = 10 * 60
    private let staticInfo = SystemInfo.gather()
    private lazy var systemState = SystemSampler(bootedAt: staticInfo.bootedAt)

    /// Counts ticks so the process list can refresh more slowly than the gauges.
    private var tickCount = 0

    /// What Gauge is allowed to interrupt you about.
    func setNotificationSettings(_ settings: AlertWatcher.Settings) {
        guard settings != watcher.settings else { return }
        let healthChanged = settings.healthDiffers(from: watcher.settings)
        watcher.settings = settings
        if healthChanged { watcher.forgetHealthAlerts() }
        // Otherwise turning a notification on would fire straight away for
        // something that had already been going on while it was off.
        watcher.reset()
        if notifiesAppAlerts != settings.appAlerts {
            notifiesAppAlerts = settings.appAlerts
            updateAppSampling()
        }
    }

    /// Starts or stops the per-app helpers to match what is actually wanted.
    private func updateAppSampling() {
        let wanted = isAppsTabVisible || needsAlertCount || notifiesAppAlerts
        queue.async { [weak self] in
            guard let self else { return }
            if wanted {
                self.appSampler.start()
            } else {
                self.appSampler.stop()
                DispatchQueue.main.async {
                    self.apps = []
                    self.alertCount = 0
                }
            }
        }
    }

    /// How many readings to keep, from the chosen window and refresh rate.
    func setHistoryWindow(minutes: Double, interval: Double) {
        let samples = Int((minutes * 60 / max(interval, 0.5)).rounded())
        histories.setCapacity(max(samples, 2))
    }

    /// One trend, over whichever stretch of time is being looked at. The live
    /// window comes from memory at full detail; everything longer comes out of
    /// the archive.
    func trend(_ series: Series, range: TrendRange) -> History {
        guard let duration = range.duration else { return histories[series] }
        return archive.history(for: series, since: Date().addingTimeInterval(-duration))
    }

    /// `archive` is only ever replaced by tests, which must not write into the
    /// real history file that the installed Gauge is appending to.
    init(archive: HistoryArchive = HistoryArchive()) {
        self.archive = archive
        if temperature == nil {
            temperaturesAvailable = false
        }
        system = staticInfo
        watcher.deliver = { title, body in
            SystemNotifier.post(title: title, body: body)
        }
    }

    func start(interval: Double) {
        timer?.invalidate()
        // The first reading of the CPU has nothing to compare against, so take
        // one immediately and let the timer produce the first real percentage.
        tick()
        let timer = Timer(timeInterval: max(interval, 0.5), repeats: true) { [weak self] _ in
            self?.tick()
        }
        // A menu bar that freezes while a menu is open looks broken, so the
        // timer is added in the common run loop mode rather than the default.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        appSampler.stop()
    }

    private func tick() {
        let wantsApps = isAppsTabVisible || needsAlertCount
        let limits = alertLimits
        queue.async { [weak self] in
            guard let self else { return }

            var next = Snapshot()
            next.cpu = self.cpu.sample()
            next.memory = self.memory.sample()
            next.gpu = self.gpu.sample()
            next.storage = self.storage.sample()
            next.network = self.network.sample()
            next.power = self.power.sample()
            next.temperatures = self.temperature?.sample() ?? TemperatureReading()
            var systemNext = self.systemState.sample()

            self.tickCount += 1
            let appRows: [AppRow]? = wantsApps ? self.appSampler.sample(limits: limits) : nil

            var healthNext: HealthReading?
            if self.healthReadAt.map({ Date().timeIntervalSince($0) >= Self.healthInterval }) ?? true {
                healthNext = self.healthSampler.sample()
                self.healthReadAt = Date()
            }

            DispatchQueue.main.async {
                // NSScreen has to be read here, on the main thread.
                systemNext.displays = SystemSampler.currentDisplays()
                self.systemReading = systemNext
                self.histories.record(next)
                self.archive.record(next)
                self.snapshot = next
                if let appRows {
                    self.apps = appRows
                    self.alertCount = appRows.reduce(0) { $0 + ($1.isAlerting ? 1 : 0) }
                }
                if let healthNext { self.health = healthNext }
                self.watcher.evaluate(apps: appRows ?? [],
                                      snapshot: next,
                                      system: systemNext,
                                      drives: self.health.drives,
                                      limits: limits)
            }
        }
    }
}
