import Foundation

/// One complete reading of the machine, taken at a single moment.
///
/// Every sampler fills in its own piece, the engine assembles them into a
/// `Snapshot`, and the whole user interface reads from that one value.  Nothing
/// in the UI talks to a sensor directly, so there is only ever one answer to
/// "what is the CPU doing right now" on screen at a time.
struct Snapshot {
    var takenAt = Date()
    var cpu = CPUReading()
    var memory = MemoryReading()
    var gpu = GPUReading()
    var temperatures = TemperatureReading()
    var storage = StorageReading()
    var network = NetworkReading()
    var power = PowerReading()
}

// MARK: - CPU

struct CPUReading {
    /// Share of every core that was busy, 0...1.
    var total: Double = 0
    /// The part of `total` spent running your programs.
    var user: Double = 0
    /// The part of `total` spent inside the kernel on their behalf.
    var system: Double = 0
    /// Busy share per core, in the order the kernel reports them.
    var perCore: [Double] = []
    /// Apple Silicon lists its efficiency cores first, then its performance
    /// cores.  These two counts say where the boundary falls.
    var efficiencyCoreCount = 0
    var performanceCoreCount = 0
    /// One, five and fifteen minute load averages.
    var loadAverage: [Double] = [0, 0, 0]

    var efficiencyCores: [Double] {
        Array(perCore.prefix(efficiencyCoreCount))
    }
    var performanceCores: [Double] {
        Array(perCore.dropFirst(efficiencyCoreCount).prefix(performanceCoreCount))
    }
    private func mean(_ values: [Double]) -> Double {
        values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }
    var efficiencyAverage: Double { mean(efficiencyCores) }
    var performanceAverage: Double { mean(performanceCores) }
}

// MARK: - Memory

struct MemoryReading {
    var total: UInt64 = 0
    /// What macOS counts as used: your apps, plus memory the kernel has wired
    /// down, plus whatever the compressor is holding.
    var used: UInt64 = 0
    var app: UInt64 = 0
    var wired: UInt64 = 0
    var compressed: UInt64 = 0
    /// File contents kept around in case they are wanted again.  This is spare
    /// memory doing something useful, not memory under strain.
    var cached: UInt64 = 0
    var swapUsed: UInt64 = 0
    var swapTotal: UInt64 = 0
    /// The kernel's own verdict: 1 normal, 2 warning, 4 critical.
    var pressureLevel: Int = 1

    var usedFraction: Double {
        total == 0 ? 0 : Double(used) / Double(total)
    }
    /// An approximation of Activity Monitor's pressure graph.  The kernel only
    /// publishes the three coarse levels above, so this estimates the curve
    /// between them from the memory that cannot simply be reclaimed.
    var pressureFraction: Double {
        total == 0 ? 0 : Double(wired + compressed) / Double(total)
    }
    var pressureDescription: String {
        switch pressureLevel {
        case 2: return "Warning"
        case 4: return "Critical"
        default: return "Normal"
        }
    }
}

// MARK: - GPU

struct GPUReading {
    /// 0...1, or nil when the driver did not report a figure.
    var utilization: Double?
    var inUseMemory: UInt64 = 0
    var allocatedMemory: UInt64 = 0
}

// MARK: - Temperature

struct TemperatureSample: Identifiable {
    enum Kind { case die, battery, storage, other }
    let name: String
    let celsius: Double
    let kind: Kind
    var id: String { name }
}

struct TemperatureReading {
    /// Every sensor that returned a believable number this tick.
    var all: [TemperatureSample] = []
    /// The hottest sensor on the chip's die.  On Apple Silicon the CPU and GPU
    /// share one piece of silicon and macOS does not label which sensor sits
    /// over which block, so this is the chip as a whole rather than the CPU.
    var hottestDie: Double?
    var averageDie: Double?
    var battery: Double?
    var storage: Double?
}

// MARK: - Storage

struct StorageReading {
    var total: UInt64 = 0
    var free: UInt64 = 0
    /// Bytes per second, measured across the gap between two ticks.
    var readRate: Double = 0
    var writeRate: Double = 0
    var readTotal: UInt64 = 0
    var writeTotal: UInt64 = 0

    var used: UInt64 { total > free ? total - free : 0 }
    var usedFraction: Double {
        total == 0 ? 0 : Double(used) / Double(total)
    }
}

// MARK: - Network

struct InterfaceRate: Identifiable {
    let name: String
    let downRate: Double
    let upRate: Double
    var id: String { name }
}

struct NetworkReading {
    var downRate: Double = 0
    var upRate: Double = 0
    var downTotal: UInt64 = 0
    var upTotal: UInt64 = 0
    var interfaces: [InterfaceRate] = []
    /// Bytes in and out since startup for each connection carrying traffic,
    /// exact as of the last `netstat` run and counted on from there.
    var totalsByInterface: [String: (down: UInt64, up: UInt64)] = [:]
    /// Real hardware (MAC) addresses, when `netstat` was given them. Kept here
    /// so the Network page never has to run `netstat` itself while drawing.
    var hardwareAddresses: [String: String] = [:]
}

// MARK: - Power

struct PowerReading {
    var hasBattery = false
    /// 0...100
    var percentage: Double?
    var isCharging = false
    var isPluggedIn = false
    var minutesRemaining: Int?
    /// How fast the battery is draining or filling, in watts.
    var watts: Double?
    var cycleCount: Int?
    /// Current full charge as a share of the capacity it shipped with, 0...100.
    var healthPercentage: Double?
    var voltage: Double?
    var amperage: Double?
}
