import Foundation

/// Decides when something is worth interrupting you for.
///
/// Every rule here exists to stop Gauge becoming the thing you learn to
/// ignore. Two ideas do most of that work:
///
/// - **Sustained, not instantaneous.** A limit crossed for one reading is a
///   compiler starting up. The same limit held for five minutes is something
///   worth knowing about. Nothing is said until a condition has lasted.
/// - **Said once.** Having spoken about a program, it stays quiet about that
///   program for an hour, however long the condition lasts. The Apps tab is
///   there for anyone who wants the running total.
///
/// It deliberately knows nothing about how a notification is delivered — it
/// calls `deliver`. That keeps the decisions testable without putting anything
/// on screen.
final class AlertWatcher {

    struct Settings: Equatable {
        var appAlerts = false
        /// How long a program must stay over a limit before it is mentioned.
        var sustained: TimeInterval = 5 * 60
        var lowDisk = false
        var thermal = false
        /// Health alerts: worn parts rather than busy ones.
        var batteryHealth = false
        var batteryHealthLimit: Double = 80
        var driveHealth = false
        var driveHealthLimit: Double = 50

        /// Whether two settings differ in their health alerts, which are
        /// remembered separately from the rest.
        func healthDiffers(from other: Settings) -> Bool {
            batteryHealth != other.batteryHealth
                || batteryHealthLimit != other.batteryHealthLimit
                || driveHealth != other.driveHealth
                || driveHealthLimit != other.driveHealthLimit
        }
    }

    var settings = Settings()

    /// Called with a title and a body when something deserves saying.
    var deliver: (String, String) -> Void = { _, _ in }

    /// Below this much free space, the disk counts as filling up. Chosen as a
    /// round number large enough that there is still time to do something: an
    /// update needs a few gigabytes of room.
    static let lowDiskBytes: UInt64 = 10 * 1_073_741_824

    /// Having said something, it stays quiet about the same thing this long.
    static let repeatAfter: TimeInterval = 60 * 60

    /// Worn parts do not recover, so a health alert repeats far less often: a
    /// reminder a week, not one an hour.
    static let healthRepeatAfter: TimeInterval = 7 * 24 * 60 * 60

    /// When each health alert last went out, keyed `battery` or `drive:<name>`.
    ///
    /// Unlike everything else here this outlives a restart — the caller saves
    /// it — because otherwise a worn battery would be announced afresh at
    /// every login, which is nagging rather than telling.
    var healthSaid: [String: Date] = [:]
    var healthSaidChanged: ([String: Date]) -> Void = { _ in }

    // Keyed on the program's name rather than its process id, because a
    // program that relaunches gets a new id and is still the same nuisance.
    private var overSince: [String: Date] = [:]
    private var lastSaid: [String: Date] = [:]

    private var diskSaidAt: Date?
    private var thermalSaidAt: Date?

    /// Looks at one reading and says whatever that reading has earned.
    func evaluate(apps: [AppRow],
                  snapshot: Snapshot,
                  system: SystemReading,
                  drives: [DriveHealth] = [],
                  limits: AlertLimits,
                  now: Date = Date()) {
        checkApps(apps, limits: limits, now: now)
        checkDisk(snapshot.storage, now: now)
        checkThermals(system, now: now)
        checkBatteryHealth(snapshot.power, now: now)
        checkDriveHealth(drives, now: now)
    }

    /// Lets a health alert speak again straight away. Used when its switch or
    /// its limit changes, so that turning it on for a part that is already
    /// worn says so at once rather than a week later.
    func forgetHealthAlerts() {
        healthSaid.removeAll()
        healthSaidChanged(healthSaid)
    }

    /// Forgets everything it has seen. Used when the settings change, so that
    /// turning a notification on does not immediately fire for a condition
    /// that was already running while it was off.
    func reset() {
        overSince.removeAll()
        lastSaid.removeAll()
        diskSaidAt = nil
        thermalSaidAt = nil
    }

    // MARK: - Programs over a limit

    private func checkApps(_ apps: [AppRow], limits: AlertLimits, now: Date) {
        guard settings.appAlerts else {
            overSince.removeAll()
            return
        }
        // An app can appear more than once — Chrome's helpers share a name —
        // so the worst offender under each name stands for it.
        var alerting: [String: AppRow] = [:]
        for app in apps where app.isAlerting {
            if let existing = alerting[app.name], existing.cpuPercent >= app.cpuPercent { continue }
            alerting[app.name] = app
        }

        // Anything that has stopped is no longer building up time.
        for name in overSince.keys where alerting[name] == nil {
            overSince.removeValue(forKey: name)
        }

        for (name, app) in alerting {
            let since = overSince[name] ?? now
            overSince[name] = since
            guard now.timeIntervalSince(since) >= settings.sustained else { continue }
            if let said = lastSaid[name], now.timeIntervalSince(said) < Self.repeatAfter { continue }
            lastSaid[name] = now

            let reasons = app.alerts
                .sorted { $0.rawValue < $1.rawValue }
                .map { limits.label(for: $0) }
                .joined(separator: " and ")
            let minutes = Int((settings.sustained / 60).rounded())
            deliver("\(name) is working hard",
                    "\(reasons) for the last \(minutes) minute\(minutes == 1 ? "" : "s").")
        }
    }

    // MARK: - The disk filling up

    private func checkDisk(_ storage: StorageReading, now: Date) {
        guard settings.lowDisk, storage.total > 0 else { return }
        guard storage.free < Self.lowDiskBytes else {
            // Back above the line: ready to speak again if it drops below.
            diskSaidAt = nil
            return
        }
        if let said = diskSaidAt, now.timeIntervalSince(said) < Self.repeatAfter { return }
        diskSaidAt = now
        deliver("Disk space is running low",
                "\(Format.bytes(storage.free)) free of \(Format.bytes(storage.total)).")
    }

    // MARK: - Worn parts

    private func checkBatteryHealth(_ power: PowerReading, now: Date) {
        guard settings.batteryHealth, let health = power.healthPercentage else { return }
        let limit = settings.batteryHealthLimit
        if health < limit {
            sayHealth(key: "battery", now: now,
                      title: "Battery health is down to \(Int(health.rounded()))%",
                      body: "That is below your limit of \(Int(limit))%. Apple considers a "
                          + "battery worn once it holds less than 80% of its original charge.")
        } else if health >= limit + 1 {
            // A battery's estimate wobbles by a point or so after a full
            // charge, so it has to be clearly back above the line before the
            // alert is ready to fire again.
            forgetHealth("battery")
        }
    }

    private func checkDriveHealth(_ drives: [DriveHealth], now: Date) {
        guard settings.driveHealth else { return }
        let limit = settings.driveHealthLimit
        for drive in drives {
            let key = "drive:\(drive.name)"

            // The drive's own alarm comes first and ignores the limit: a
            // drive that says it has gone read-only is in trouble at 99%.
            if let problem = drive.warnings.first {
                sayHealth(key: key + ":fault", now: now,
                          title: "\(drive.name) is reporting a problem",
                          body: "\(problem). Back it up now.")
            } else {
                forgetHealth(key + ":fault")
            }

            if Double(drive.healthPercent) < limit {
                sayHealth(key: key, now: now,
                          title: "Drive health is down to \(drive.healthPercent)%",
                          body: "\(drive.name) has used \(drive.percentUsed)% of its rated life, "
                              + "past your limit of \(Int(limit))%. Keep your backups current "
                              + "and plan for a replacement.")
            } else {
                forgetHealth(key)
            }
        }
    }

    private func sayHealth(key: String, now: Date, title: String, body: String) {
        if let said = healthSaid[key], now.timeIntervalSince(said) < Self.healthRepeatAfter { return }
        healthSaid[key] = now
        healthSaidChanged(healthSaid)
        deliver(title, body)
    }

    private func forgetHealth(_ key: String) {
        guard healthSaid[key] != nil else { return }
        healthSaid.removeValue(forKey: key)
        healthSaidChanged(healthSaid)
    }

    // MARK: - Running hot

    private func checkThermals(_ system: SystemReading, now: Date) {
        guard settings.thermal else { return }
        // Only the two states that mean the Mac is slowing itself down. "Warm"
        // is ordinary under any real load and would fire every day.
        let isHot = system.thermalState == .serious || system.thermalState == .critical
        guard isHot else {
            thermalSaidAt = nil
            return
        }
        if let said = thermalSaidAt, now.timeIntervalSince(said) < Self.repeatAfter { return }
        thermalSaidAt = now
        let body = system.thermalState == .critical
            ? "macOS is slowing the Mac down to cool it off."
            : "macOS says the Mac is hot and may start slowing down."
        deliver("Your Mac is running hot", body)
    }
}
