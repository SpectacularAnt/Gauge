import Foundation

/// Everything Gauge can put in the menu bar.
///
/// Each case carries its own name, icon and formatting rule, so adding a new
/// readout means adding one case here and one line in `value(from:)` — the
/// settings list and the menu bar both build themselves from `allCases`.
enum Metric: String, CaseIterable, Codable, Identifiable {
    case cpuUsage
    case chipTemperature
    case gpuUsage
    case memoryUsage
    case memoryPressure
    case swapUsed
    case diskUsage
    case diskActivity
    case networkActivity
    case batteryLevel
    case batteryPower
    case batteryTemperature
    case storageTemperature
    case loadAverage
    case appAlerts

    var id: String { rawValue }

    /// Which section of the settings list this belongs under.
    enum Group: String, CaseIterable {
        case processor = "Processor"
        case memory    = "Memory"
        case storage   = "Storage"
        case network   = "Network"
        case power     = "Power"
    }

    var group: Group {
        switch self {
        case .cpuUsage, .chipTemperature, .gpuUsage, .loadAverage,
             .appAlerts:                                             return .processor
        case .memoryUsage, .memoryPressure, .swapUsed:               return .memory
        case .diskUsage, .diskActivity, .storageTemperature:         return .storage
        case .networkActivity:                                       return .network
        case .batteryLevel, .batteryPower, .batteryTemperature:      return .power
        }
    }

    /// The name shown in the settings list.
    var title: String {
        switch self {
        case .cpuUsage:           return "CPU usage"
        case .chipTemperature:    return "Chip temperature"
        case .gpuUsage:           return "GPU usage"
        case .memoryUsage:        return "Memory used"
        case .memoryPressure:     return "Memory pressure"
        case .swapUsed:           return "Swap used"
        case .diskUsage:          return "Disk used"
        case .diskActivity:       return "Disk activity"
        case .networkActivity:    return "Network activity"
        case .batteryLevel:       return "Battery charge"
        case .batteryPower:       return "Power draw"
        case .batteryTemperature: return "Battery temperature"
        case .storageTemperature: return "SSD temperature"
        case .loadAverage:        return "Load average"
        case .appAlerts:          return "App alerts"
        }
    }

    /// A short sentence under the title, for anything that needs explaining.
    var explanation: String? {
        switch self {
        case .chipTemperature:
            return "Hottest sensor on the chip. The CPU and GPU share one die, "
                 + "so this covers both."
        case .memoryPressure:
            return "How hard memory is being squeezed, not how full it is."
        case .batteryPower:
            return "Watts in or out of the battery. Blank while fully charged "
                 + "on mains power."
        case .diskActivity:
            return "Read and write rate for the internal drive."
        case .loadAverage:
            return "Work waiting to run, averaged over one minute."
        case .appAlerts:
            return "How many apps are over a limit. Keeps a background sampler "
                 + "running, so leave it off unless you want it."
        default:
            return nil
        }
    }

    /// SF Symbol drawn beside the value in the menu bar.
    var symbolName: String {
        switch self {
        case .cpuUsage:           return "cpu"
        case .chipTemperature:    return "thermometer.medium"
        case .gpuUsage:           return "display"
        case .memoryUsage:        return "memorychip"
        case .memoryPressure:     return "gauge.with.dots.needle.67percent"
        case .swapUsed:           return "arrow.left.arrow.right.square"
        case .diskUsage:          return "internaldrive"
        case .diskActivity:       return "arrow.up.arrow.down.circle"
        case .networkActivity:    return "network"
        case .batteryLevel:       return "battery.100percent"
        case .batteryPower:       return "bolt"
        case .batteryTemperature: return "thermometer.low"
        case .storageTemperature: return "thermometer.variable"
        case .loadAverage:        return "chart.line.uptrend.xyaxis"
        case .appAlerts:          return "exclamationmark.triangle.fill"
        }
    }

    /// A two or three letter prefix, used when icons are turned off.
    var shortLabel: String {
        switch self {
        case .cpuUsage:           return "CPU"
        case .chipTemperature:    return "CHIP"
        case .gpuUsage:           return "GPU"
        case .memoryUsage:        return "RAM"
        case .memoryPressure:     return "PRES"
        case .swapUsed:           return "SWAP"
        case .diskUsage:          return "DISK"
        case .diskActivity:       return "I/O"
        case .networkActivity:    return "NET"
        case .batteryLevel:       return "BAT"
        case .batteryPower:       return "PWR"
        case .batteryTemperature: return "BAT"
        case .storageTemperature: return "SSD"
        case .loadAverage:        return "LOAD"
        case .appAlerts:          return "ALERT"
        }
    }

    /// The compact text for the menu bar, or nil when this machine has nothing
    /// to report — a Mac with no battery never shows a charge percentage.
    func value(from s: Snapshot, fahrenheit: Bool, alertCount: Int = 0) -> String? {
        switch self {
        case .cpuUsage:
            return percent(s.cpu.total)
        case .chipTemperature:
            return s.temperatures.hottestDie.map { temperature($0, fahrenheit) }
        case .gpuUsage:
            return s.gpu.utilization.map { percent($0) }
        case .memoryUsage:
            return percent(s.memory.usedFraction)
        case .memoryPressure:
            return percent(s.memory.pressureFraction)
        case .swapUsed:
            return Format.bytes(s.memory.swapUsed, decimals: 1)
        case .diskUsage:
            return percent(s.storage.usedFraction)
        case .diskActivity:
            return "\(Format.rate(s.storage.readRate))/\(Format.rate(s.storage.writeRate))"
        case .networkActivity:
            return "\u{2193}\(Format.rate(s.network.downRate)) \u{2191}\(Format.rate(s.network.upRate))"
        case .batteryLevel:
            return s.power.percentage.map { percent($0 / 100) }
        case .batteryPower:
            guard let w = s.power.watts, w > 0.05 else { return nil }
            return String(format: "%.1fW", w)
        case .batteryTemperature:
            return s.temperatures.battery.map { temperature($0, fahrenheit) }
        case .storageTemperature:
            return s.temperatures.storage.map { temperature($0, fahrenheit) }
        case .loadAverage:
            return String(format: "%.2f", s.cpu.loadAverage[0])
        case .appAlerts:
            // Only there while something is over a limit, so its appearing is
            // itself the alert. The rest of the bar shifts along when it does.
            return alertCount > 0 ? "\(alertCount)" : nil
        }
    }

    private func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    private func temperature(_ celsius: Double, _ fahrenheit: Bool) -> String {
        let value = fahrenheit ? celsius * 9 / 5 + 32 : celsius
        return "\(Int(value.rounded()))\u{00B0}"
    }
}

/// Shared number formatting, kept in one place so the menu bar and the detail
/// panel always phrase the same quantity the same way.
enum Format {
    /// Sizes people read as powers of two: memory, and anything the kernel
    /// counts in pages.
    static func bytes(_ value: UInt64, decimals: Int = 1) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var amount = Double(value)
        var unit = 0
        while amount >= 1024, unit < units.count - 1 {
            amount /= 1024
            unit += 1
        }
        if unit == 0 { return "\(Int(amount)) B" }
        return String(format: "%.\(decimals)f %@", amount, units[unit])
    }

    /// Disk and network rates, short enough for the menu bar: "1.2M", "340K".
    static func rate(_ bytesPerSecond: Double) -> String {
        let value = max(bytesPerSecond, 0)
        if value < 1024 { return "0K" }
        if value < 1024 * 1024 { return "\(Int(value / 1024))K" }
        let megabytes = value / (1024 * 1024)
        return megabytes < 10
            ? String(format: "%.1fM", megabytes)
            : "\(Int(megabytes))M"
    }

    /// The same rates spelled out for the detail panel.
    static func rateLong(_ bytesPerSecond: Double) -> String {
        bytes(UInt64(max(bytesPerSecond, 0)), decimals: 1) + "/s"
    }

    /// An app's memory, short enough for a table column: "846 MB", "1.5 GB".
    static func memory(_ bytes: UInt64) -> String {
        let megabytes = Double(bytes) / 1_048_576
        if megabytes < 1024 { return "\(Int(megabytes)) MB" }
        return String(format: "%.1f GB", megabytes / 1024)
    }

    static func temperature(_ celsius: Double, fahrenheit: Bool) -> String {
        let value = fahrenheit ? celsius * 9 / 5 + 32 : celsius
        return String(format: "%.1f\u{00B0}%@", value, fahrenheit ? "F" : "C")
    }

    /// "6:41:03 AM" — seconds included, because in a one-minute window the
    /// minute alone does not tell two readings apart.
    static func clock(_ date: Date) -> String {
        clockFormatter.string(from: date)
    }

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()

    /// "now" / "12s ago" / "2m 14s ago" / "14m ago". Seconds are dropped once
    /// the reading is more than ten minutes old, where they are just noise.
    static func ago(_ date: Date, from now: Date = Date()) -> String {
        let seconds = Int(max(now.timeIntervalSince(date), 0))
        if seconds < 3 { return "now" }
        if seconds < 60 { return "\(seconds)s ago" }
        let minutes = seconds / 60
        if minutes >= 10 { return "\(minutes)m ago" }
        return "\(minutes)m \(seconds % 60)s ago"
    }

    /// "3d 4h" / "4h 12m" / "12m" — long spans lose the minutes, which nobody
    /// reads, and short ones keep them.
    static func uptime(_ seconds: TimeInterval) -> String {
        let total = Int(max(seconds, 0))
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    /// Sizes the way drive makers state them, in powers of a thousand, so a
    /// drive sold as 1 TB reads as 1 TB rather than as 932 GB. Used for drives
    /// and the data written to them; everything else in Gauge counts in powers
    /// of 1,024, as memory always has.
    static func decimalBytes(_ value: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var amount = Double(value)
        var unit = 0
        while amount >= 1000, unit < units.count - 1 {
            amount /= 1000
            unit += 1
        }
        if unit == 0 { return "\(Int(amount)) B" }
        return amount >= 100 || amount == amount.rounded()
            ? "\(Int(amount.rounded())) \(units[unit])"
            : String(format: "%.1f %@", amount, units[unit])
    }

    /// A count with thousands separators: "1,234,567".
    static func count<T: BinaryInteger>(_ value: T) -> String {
        Int64(clamping: value).formatted()
    }

    /// When something happened, short: the time alone if it was today, the
    /// day and time if not. A week-long chart needs the day; an hour-long one
    /// would only be cluttered by it.
    static func moment(_ date: Date, now: Date = Date()) -> String {
        if Calendar.current.isDate(date, inSameDayAs: now) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    /// A length of time at a glance: "42m", "6h", "3d 4h". Used for "how far
    /// back does this go", where the exact seconds never matter.
    static func span(_ seconds: TimeInterval) -> String {
        let minutes = Int(max(seconds, 0) / 60)
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }
        let days = hours / 24
        let spareHours = hours % 24
        return spareHours == 0 ? "\(days)d" : "\(days)d \(spareHours)h"
    }

    static func duration(minutes: Int) -> String {
        let hours = minutes / 60
        let remainder = minutes % 60
        return hours == 0 ? "\(remainder)m" : "\(hours)h \(remainder)m"
    }
}
