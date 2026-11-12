import Foundation
import IOKit

/// What one running program is costing the machine.
struct AppRow: Identifiable {
    let pid: Int32
    let name: String
    /// Percent of a single core. A program using four cores flat reads 400.
    let cpuPercent: Double
    /// macOS's own "energy impact" figure, the one Activity Monitor shows.
    let energyImpact: Double
    /// Share of the GPU over the last interval, 0...100.
    let gpuPercent: Double
    /// The memory this app is holding: the same "memory footprint" figure
    /// Activity Monitor's Memory column shows.
    let memoryBytes: UInt64
    var alerts: Set<AppAlert>
    /// Recent CPU readings for this one program, oldest first, so an opened
    /// row can show whether it has been busy all along or has just started.
    var cpuHistory: [Double] = []

    var id: Int32 { pid }
    var isAlerting: Bool { !alerts.isEmpty }
}

/// The four things an app can be told off for.
enum AppAlert: String, CaseIterable, Identifiable {
    case cpu, gpu, power, memory
    var id: String { rawValue }
}

/// Where each alert trips. Adjustable in Settings; these are the defaults.
///
/// The defaults are deliberately high. An alert should mean "this is why the
/// Mac is hot", not "this app is awake" — a warning that fires all day is one
/// you stop reading.
struct AlertLimits: Equatable {
    // Just under a whole core rather than a whole one: a single-threaded
    // program stuck in a loop sits at about 99.8% and would sail past a
    // threshold of 100 for ever, which is exactly the case worth catching.
    var cpu: Double = 80
    var gpu: Double = 50
    // Energy impact tracks CPU closely for compute-bound work, so it starts at
    // the same level; below that the two would fire at different times for the
    // same cause.
    var power: Double = 80
    /// Bytes. 4 GB is an eighth of this Mac's 32 GB, and several times what
    /// even a heavy app like Final Cut Pro holds while idle, so it catches an
    /// app that has grown out of hand rather than one that is merely big.
    var memory: Double = AlertLimits.memorySteps[4]

    static let cpuRange: ClosedRange<Double> = 20...400
    static let gpuRange: ClosedRange<Double> = 10...100
    static let powerRange: ClosedRange<Double> = 20...400

    /// Memory limits run from half a gigabyte to sixteen, which a plain slider
    /// handles badly: every useful setting ends up crammed into its first few
    /// pixels. So it steps through these. They are in the same binary units
    /// the rest of Gauge displays, so a "4 GB" limit is exactly what the Apps
    /// tab calls 4 GB.
    static let memorySteps: [Double] = [
        512 * 1_048_576,
        1 * 1_073_741_824, 2 * 1_073_741_824, 3 * 1_073_741_824,
        4 * 1_073_741_824, 6 * 1_073_741_824, 8 * 1_073_741_824,
        12 * 1_073_741_824, 16 * 1_073_741_824,
    ]

    func threshold(for alert: AppAlert) -> Double {
        switch alert {
        case .cpu:    return cpu
        case .gpu:    return gpu
        case .power:  return power
        case .memory: return memory
        }
    }

    func label(for alert: AppAlert) -> String {
        switch alert {
        case .cpu:    return "CPU over \(Int(cpu))%"
        case .gpu:    return "GPU over \(Int(gpu))%"
        case .power:  return "Energy impact over \(Int(power))"
        case .memory: return "RAM over \(Self.describe(memory))"
        }
    }

    /// "512 MB", "4 GB", "1.5 GB".
    static func describe(_ bytes: Double) -> String {
        if bytes >= 1_073_741_824 {
            let gigabytes = bytes / 1_073_741_824
            return gigabytes == gigabytes.rounded()
                ? "\(Int(gigabytes)) GB"
                : String(format: "%.1f GB", gigabytes)
        }
        return "\(Int(bytes / 1_048_576)) MB"
    }

    /// Pulls stored values back inside their ranges, in case a setting was
    /// saved by a version with different limits.
    func clamped() -> AlertLimits {
        var limits = self
        limits.cpu = min(max(cpu, Self.cpuRange.lowerBound), Self.cpuRange.upperBound)
        limits.gpu = min(max(gpu, Self.gpuRange.lowerBound), Self.gpuRange.upperBound)
        limits.power = min(max(power, Self.powerRange.lowerBound), Self.powerRange.upperBound)
        let nearest = Self.memorySteps.min { abs($0 - memory) < abs($1 - memory) }
        limits.memory = nearest ?? Self.memorySteps[4]
        return limits
    }
}

/// Gathers the per-app numbers.
///
/// Two sources, because neither has everything:
///
/// - `top` knows CPU, memory and energy impact for every process, including
///   ones belonging to other users. Nothing public gives an app's energy impact
///   except this.
/// - The IOKit registry knows GPU time per process, which `top` does not
///   report.
///
/// `top` is left running, printing a screen every two seconds, which costs
/// about 3% of one core. It only runs while something wants this data, and
/// stops the moment nothing does.
final class AppSampler {

    private let lock = NSLock()

    // Guarded by `lock`.
    private var topRows: [Int32: TopRow] = [:]

    /// How many readings of its own each program keeps. At the usual rate
    /// that is a couple of minutes, which is all the opened row shows.
    static let perAppHistoryLength = 60

    // Only touched from `sample()`, which the engine calls on its one queue.
    private var cpuHistory: [Int32: [Double]] = [:]
    private var previousGPUTime: [Int32: UInt64] = [:]
    private var gpuSampledAt: Date?
    private var gpuPercent: [Int32: Double] = [:]

    private var top: Process?

    private(set) var isRunning = false

    /// Gauge's own helpers have Gauge as their parent. They are hidden from
    /// the list: nobody needs to be told the monitor is monitoring.
    private let ownPid = getpid()

    private struct TopRow {
        let name: String
        let cpu: Double
        let power: Double
        let memory: UInt64
    }

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true

        top = launch("/usr/bin/top",
                     ["-l", "0", "-s", "2", "-o", "power",
                      "-stats", "pid,ppid,command,cpu,power,mem"],
                     handler: { [weak self] line in self?.consumeTopLine(line) })
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        lock.lock()
        topRows.removeAll()
        lock.unlock()
        cpuHistory.removeAll()

        if let top {
            (top.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
            if top.isRunning { top.terminate() }
        }
        top = nil
        topSample = [:]
    }

    deinit { stop() }

    /// Runs a command and calls `handler` with each line it prints.
    ///
    /// The pipe hands us whatever bytes have arrived, which will not line up
    /// with line boundaries, so a partial line is kept until its newline shows.
    private func launch(_ path: String,
                        _ arguments: [String],
                        handler: @escaping (String) -> Void) -> Process? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        var pending = Data()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 0x0A) {
                let lineData = pending[pending.startIndex..<newline]
                pending.removeSubrange(pending.startIndex...newline)
                if let line = String(data: lineData, encoding: .utf8) {
                    handler(line)
                }
            }
        }
        do { try process.run() } catch { return nil }
        return process
    }

    // MARK: - Parsing top

    /// The screenful currently being read. Only the pipe's handler touches it.
    private var topSample: [Int32: TopRow] = [:]

    private func consumeTopLine(_ line: String) {
        // A header line means the previous screenful is complete.
        if line.hasPrefix("PID") {
            lock.lock()
            if !topSample.isEmpty { topRows = topSample }
            lock.unlock()
            topSample = [:]
            return
        }
        // Fields are: pid, ppid, command (may contain spaces), cpu, power,
        // memory. Reading from both ends avoids guessing where the command
        // stops.
        let fields = line.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count >= 6,
              let pid = Int32(fields[0]),
              let parent = Int32(fields[1])
        else { return }
        guard parent != ownPid, pid != ownPid else { return }

        let memoryField = String(fields[fields.count - 1])
        guard let power = Double(fields[fields.count - 2]),
              let cpu = Double(fields[fields.count - 3])
        else { return }
        let name = fields[2..<(fields.count - 3)].joined(separator: " ")
        topSample[pid] = TopRow(name: name,
                                cpu: cpu,
                                power: power,
                                memory: Self.parseMemory(memoryField))
    }

    /// top writes memory as "590M", "7200K", "2.1G", sometimes with a trailing
    /// + or - meaning it grew or shrank since the last screen.
    static func parseMemory(_ text: String) -> UInt64 {
        var value = text
        if let last = value.last, last == "+" || last == "-" { value.removeLast() }
        guard let unit = value.last else { return 0 }
        let multiplier: Double
        switch unit {
        case "K": multiplier = 1024
        case "M": multiplier = 1024 * 1024
        case "G": multiplier = 1024 * 1024 * 1024
        case "T": multiplier = 1024 * 1024 * 1024 * 1024
        default:  multiplier = 1
        }
        if multiplier > 1 { value.removeLast() }
        return UInt64((Double(value) ?? 0) * multiplier)
    }

    // MARK: - GPU, read straight from the registry

    /// Each process that has touched the GPU leaves a user client behind, and
    /// the driver records how long it has had the GPU for. Two readings and the
    /// time between them give a percentage.
    private func gpuTimeByPid() -> [Int32: UInt64] {
        var totals: [Int32: UInt64] = [:]
        var iterator: io_iterator_t = 0
        let matching = IOServiceMatching("IOAccelerator")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return totals
        }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            var children: io_iterator_t = 0
            guard IORegistryEntryGetChildIterator(service, kIOServicePlane, &children) == KERN_SUCCESS else {
                continue
            }
            defer { IOObjectRelease(children) }

            var child = IOIteratorNext(children)
            while child != 0 {
                defer {
                    IOObjectRelease(child)
                    child = IOIteratorNext(children)
                }
                var properties: Unmanaged<CFMutableDictionary>?
                guard IORegistryEntryCreateCFProperties(child, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                      let dictionary = properties?.takeRetainedValue() as? [String: Any],
                      let creator = dictionary["IOUserClientCreator"] as? String,
                      let usage = dictionary["AppUsage"] as? [[String: Any]],
                      let pid = Self.parseCreatorPid(creator)
                else { continue }

                var nanoseconds: UInt64 = 0
                for entry in usage {
                    if let time = entry["accumulatedGPUTime"] as? UInt64 {
                        nanoseconds += time
                    }
                }
                if nanoseconds > 0 { totals[pid, default: 0] += nanoseconds }
            }
        }
        return totals
    }

    /// "pid 602, WindowServer" -> 602
    static func parseCreatorPid(_ creator: String) -> Int32? {
        guard creator.hasPrefix("pid ") else { return nil }
        let digits = creator.dropFirst(4).prefix { $0.isNumber }
        return Int32(digits)
    }

    // MARK: - The merged answer

    func sample(limits: AlertLimits) -> [AppRow] {
        guard isRunning else { return [] }

        let now = Date()
        let gpuNow = gpuTimeByPid()
        if let last = gpuSampledAt {
            let elapsed = now.timeIntervalSince(last)
            if elapsed > 0.2 {
                var percentages: [Int32: Double] = [:]
                for (pid, total) in gpuNow {
                    guard let was = previousGPUTime[pid], total >= was else { continue }
                    let seconds = Double(total - was) / 1_000_000_000
                    percentages[pid] = min(seconds / elapsed * 100, 100)
                }
                gpuPercent = percentages
                previousGPUTime = gpuNow
                gpuSampledAt = now
            }
        } else {
            previousGPUTime = gpuNow
            gpuSampledAt = now
        }

        lock.lock()
        let rows = topRows
        lock.unlock()

        // Each program's own recent CPU, for the opened row in the Apps tab.
        // Programs that have gone are dropped rather than left to accumulate.
        cpuHistory = cpuHistory.filter { rows[$0.key] != nil }
        for (pid, row) in rows {
            var recent = cpuHistory[pid] ?? []
            recent.append(row.cpu)
            if recent.count > Self.perAppHistoryLength {
                recent.removeFirst(recent.count - Self.perAppHistoryLength)
            }
            cpuHistory[pid] = recent
        }

        return rows.map { pid, row in
            let gpu = gpuPercent[pid] ?? 0
            var alerts: Set<AppAlert> = []
            if row.cpu >= limits.cpu { alerts.insert(.cpu) }
            if gpu >= limits.gpu { alerts.insert(.gpu) }
            if row.power >= limits.power { alerts.insert(.power) }
            if Double(row.memory) >= limits.memory { alerts.insert(.memory) }

            return AppRow(pid: pid,
                          name: Self.fullName(for: pid, shortName: row.name) ?? row.name,
                          cpuPercent: row.cpu,
                          energyImpact: row.power,
                          gpuPercent: gpu,
                          memoryBytes: row.memory,
                          alerts: alerts,
                          cpuHistory: cpuHistory[pid] ?? [])
        }
    }

    /// top clips the command to about fifteen characters, which turns useful
    /// names into guesses. The kernel still knows the real one.
    ///
    /// The cache is keyed on the pid *and* the name top currently reports for
    /// it, because a pid is not a stable identity. When a process execs another
    /// program — a shell starting `curl`, a launcher becoming its app — it keeps
    /// its pid but becomes something else entirely. Caching on the pid alone
    /// went on calling a download "zsh" for as long as it ran.
    private static var nameCache: [Int32: (short: String, full: String)] = [:]

    static func fullName(for pid: Int32, shortName: String) -> String? {
        if let cached = nameCache[pid], cached.short == shortName {
            return cached.full
        }
        var buffer = [CChar](repeating: 0, count: 256)
        let length = proc_name(pid, &buffer, 256)
        guard length > 0 else { return nil }
        let name = String(cString: buffer)
        guard !name.isEmpty else { return nil }
        // pids get reused too, so the cache is dropped wholesale once it is
        // clearly stale rather than allowed to grow for ever.
        if nameCache.count > 2000 { nameCache.removeAll() }
        nameCache[pid] = (short: shortName, full: name)
        return name
    }
}
