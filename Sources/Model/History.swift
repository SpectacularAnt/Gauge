import Foundation

/// A fixed-length window of recent values, for drawing a trend line.
///
/// Older readings fall off the front as new ones arrive, so the array is always
/// at most `capacity` long and the newest value is always last. That ordering is
/// what lets a chart draw it left to right without thinking about it.
struct History {
    private(set) var values: [Double] = []
    /// When each value was read, one for one with `values`. Kept rather than
    /// worked out from the refresh rate, because the rate can change mid-window
    /// and a tick can run late — and "when did that spike happen" deserves the
    /// real answer.
    private(set) var times: [Date] = []
    private(set) var capacity: Int

    init(capacity: Int = 120) {
        self.capacity = capacity
        values.reserveCapacity(capacity)
        times.reserveCapacity(capacity)
    }

    /// A trend built from readings that are already known — rows out of the
    /// archive, rather than readings arriving one at a time.
    init(values: [Double], times: [Date]) {
        self.values = values
        self.times = times
        self.capacity = max(values.count, 2)
    }

    /// Where the line should be cut because nothing was recorded in between:
    /// the index of each reading that follows a gap.
    ///
    /// Gauge only records while it is running, so quitting it, or closing the
    /// lid, leaves a hole. Drawing straight across one would invent a smooth
    /// afternoon that nobody watched. A step more than two and a half times the
    /// usual one counts as a hole, which lets a late tick pass without being
    /// mistaken for one.
    var breaks: Set<Int> {
        guard times.count > 2 else { return [] }
        var steps: [TimeInterval] = []
        steps.reserveCapacity(times.count - 1)
        for index in 1..<times.count {
            steps.append(times[index].timeIntervalSince(times[index - 1]))
        }
        let typical = steps.sorted()[steps.count / 2]
        guard typical > 0 else { return [] }
        var result: Set<Int> = []
        for (offset, step) in steps.enumerated() where step > typical * 2.5 {
            result.insert(offset + 1)
        }
        return result
    }

    /// Changing the window keeps whatever history still fits, so widening it
    /// does not wipe the trend and narrowing it drops the oldest readings.
    mutating func setCapacity(_ newCapacity: Int) {
        capacity = max(newCapacity, 2)
        trim()
    }

    mutating func append(_ value: Double, at time: Date = Date()) {
        values.append(value.isFinite ? value : 0)
        times.append(time)
        trim()
    }

    private mutating func trim() {
        let excess = values.count - capacity
        if excess > 0 {
            values.removeFirst(excess)
            times.removeFirst(excess)
        }
    }

    var latest: Double { values.last ?? 0 }
    var peak: Double { values.max() ?? 0 }
    var isEmpty: Bool { values.isEmpty }
}

/// Every trend Gauge keeps, named so they can be stored and looked up.
///
/// The order is the order they are written to the archive file, so cases are
/// only ever added at the end.
enum Series: String, CaseIterable {
    case cpu, memory, gpu, temperature
    case networkDown, networkUp, diskRead, diskWrite, power
}

/// How far back a chart reaches.
///
/// `live` is the trend length from Settings, drawn from readings held in
/// memory at full detail. The rest come out of the archive on disk at a point
/// a minute, and keep working across a restart.
enum TrendRange: String, CaseIterable, Identifiable {
    case live, hour, sixHours, day, week

    var id: String { rawValue }

    var label: String {
        switch self {
        case .live:     return "Live"
        case .hour:     return "1h"
        case .sixHours: return "6h"
        case .day:      return "24h"
        case .week:     return "7d"
        }
    }

    /// The range in a sentence: "the last 6 hours".
    func phrase(liveMinutes: Int) -> String {
        switch self {
        case .live:     return liveMinutes == 1 ? "the last minute" : "the last \(liveMinutes) minutes"
        case .hour:     return "the last hour"
        case .sixHours: return "the last 6 hours"
        case .day:      return "the last 24 hours"
        case .week:     return "the last 7 days"
        }
    }

    /// How far back it reaches, or nil for the live window, whose length is
    /// the user's own trend-length setting.
    var duration: TimeInterval? {
        switch self {
        case .live:     return nil
        case .hour:     return 60 * 60
        case .sixHours: return 6 * 60 * 60
        case .day:      return 24 * 60 * 60
        case .week:     return 7 * 24 * 60 * 60
        }
    }
}

/// Every trend Gauge keeps. One place to add a new one.
struct Histories {
    /// Fractions, 0...1.
    var cpu = History()
    var memory = History()
    var gpu = History()
    /// Degrees Celsius.
    var temperature = History()
    /// Bytes per second.
    var networkDown = History()
    var networkUp = History()
    var diskRead = History()
    var diskWrite = History()
    /// Watts.
    var power = History()

    subscript(series: Series) -> History {
        switch series {
        case .cpu:         return cpu
        case .memory:      return memory
        case .gpu:         return gpu
        case .temperature: return temperature
        case .networkDown: return networkDown
        case .networkUp:   return networkUp
        case .diskRead:    return diskRead
        case .diskWrite:   return diskWrite
        case .power:       return power
        }
    }

    mutating func setCapacity(_ capacity: Int) {
        cpu.setCapacity(capacity)
        memory.setCapacity(capacity)
        gpu.setCapacity(capacity)
        temperature.setCapacity(capacity)
        networkDown.setCapacity(capacity)
        networkUp.setCapacity(capacity)
        diskRead.setCapacity(capacity)
        diskWrite.setCapacity(capacity)
        power.setCapacity(capacity)
    }

    mutating func record(_ snapshot: Snapshot) {
        let time = snapshot.takenAt
        cpu.append(snapshot.cpu.total, at: time)
        memory.append(snapshot.memory.usedFraction, at: time)
        gpu.append(snapshot.gpu.utilization ?? 0, at: time)
        temperature.append(snapshot.temperatures.hottestDie ?? 0, at: time)
        networkDown.append(snapshot.network.downRate, at: time)
        networkUp.append(snapshot.network.upRate, at: time)
        diskRead.append(snapshot.storage.readRate, at: time)
        diskWrite.append(snapshot.storage.writeRate, at: time)
        power.append(snapshot.power.watts ?? 0, at: time)
    }
}
