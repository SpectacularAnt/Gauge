import Foundation

/// Measures how busy the processor is.
///
/// The kernel does not track a percentage; it counts "ticks" each core has spent
/// in each state since boot, and those counters only ever rise.  A percentage is
/// the difference between two readings, so the first sample after launch has
/// nothing to compare against and reports zero.
final class CPUSampler {

    private var previous: [CoreTicks] = []

    /// Apple Silicon reports its efficiency cores first and its performance
    /// cores after them.  `sysctl` tells us how many of each there are, which is
    /// all we need to split the list.
    let efficiencyCoreCount: Int
    let performanceCoreCount: Int

    private struct CoreTicks {
        var user = 0
        var system = 0
        var nice = 0
        var idle = 0
        var busy: Int { user + system + nice }
        var all: Int { busy + idle }
    }

    init() {
        // perflevel0 is the fastest tier the chip has, perflevel1 the slower
        // one.  An Intel Mac has a single tier, so the second lookup fails and
        // every core counts as a performance core.
        let fast = Self.sysctlInt("hw.perflevel0.logicalcpu") ?? Self.sysctlInt("hw.logicalcpu") ?? 0
        let slow = Self.sysctlInt("hw.perflevel1.logicalcpu") ?? 0
        performanceCoreCount = fast
        efficiencyCoreCount = slow
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }

    func sample() -> CPUReading {
        var reading = CPUReading()
        reading.efficiencyCoreCount = efficiencyCoreCount
        reading.performanceCoreCount = performanceCoreCount

        var load = [Double](repeating: 0, count: 3)
        getloadavg(&load, 3)
        reading.loadAverage = load

        guard let current = readTicks() else { return reading }
        defer { previous = current }

        // Nothing to subtract from yet, or the core count changed underneath us.
        guard previous.count == current.count, !previous.isEmpty else { return reading }

        var totalBusy = 0, totalAll = 0, totalUser = 0, totalSystem = 0
        reading.perCore = zip(previous, current).map { was, now in
            let busy = now.busy - was.busy
            let all = now.all - was.all
            totalBusy += busy
            totalAll += all
            totalUser += now.user - was.user
            totalSystem += now.system - was.system
            // A core that reported no new ticks at all was asleep, not busy.
            return all > 0 ? min(Double(busy) / Double(all), 1) : 0
        }

        if totalAll > 0 {
            reading.total = min(Double(totalBusy) / Double(totalAll), 1)
            reading.user = Double(totalUser) / Double(totalAll)
            reading.system = Double(totalSystem) / Double(totalAll)
        }
        return reading
    }

    private func readTicks() -> [CoreTicks]? {
        var coreCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0

        let result = host_processor_info(mach_host_self(),
                                        PROCESSOR_CPU_LOAD_INFO,
                                        &coreCount,
                                        &info,
                                        &infoCount)
        guard result == KERN_SUCCESS, let info else { return nil }

        // host_processor_info hands back memory we have to give back ourselves.
        defer {
            let bytes = vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), bytes)
        }

        let values = UnsafeBufferPointer(start: info, count: Int(infoCount))
        let stateCount = Int(CPU_STATE_MAX)
        let userIndex = Int(CPU_STATE_USER)
        let systemIndex = Int(CPU_STATE_SYSTEM)
        let niceIndex = Int(CPU_STATE_NICE)
        let idleIndex = Int(CPU_STATE_IDLE)

        var cores: [CoreTicks] = []
        cores.reserveCapacity(Int(coreCount))
        for core in 0..<Int(coreCount) {
            let base = core * stateCount
            guard base + idleIndex < values.count else { break }
            var ticks = CoreTicks()
            ticks.user = Int(values[base + userIndex])
            ticks.system = Int(values[base + systemIndex])
            ticks.nice = Int(values[base + niceIndex])
            ticks.idle = Int(values[base + idleIndex])
            cores.append(ticks)
        }
        return cores
    }
}
