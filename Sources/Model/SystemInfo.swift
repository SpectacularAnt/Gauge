import Foundation
import IOKit

/// The facts about this Mac that never change while it is running.
///
/// Gathered once and kept, rather than re-read on every tick: the chip does not
/// grow cores, and asking `system_profiler` two hundred times an hour would be
/// rude to a machine whose whole job here is to look idle.
struct SystemInfo {
    var modelName = "Mac"              // "MacBook Air"
    var modelIdentifier = ""           // "Mac16,13"
    var chip = ""                      // "Apple M4"
    var performanceCores = 0
    var efficiencyCores = 0
    var gpuCores = 0
    var memoryBytes: UInt64 = 0
    var osVersion = ""                 // "27.0.1"
    var osBuild = ""                   // "26A434"
    var bootedAt = Date()

    var totalCores: Int { performanceCores + efficiencyCores }

    static func gather() -> SystemInfo {
        var info = SystemInfo()

        info.chip = sysctlString("machdep.cpu.brand_string") ?? "Unknown"
        info.modelIdentifier = sysctlString("hw.model") ?? ""
        info.osVersion = sysctlString("kern.osproductversion") ?? ""
        info.osBuild = sysctlString("kern.osversion") ?? ""
        info.performanceCores = sysctlInt("hw.perflevel0.logicalcpu")
            ?? sysctlInt("hw.logicalcpu") ?? 0
        info.efficiencyCores = sysctlInt("hw.perflevel1.logicalcpu") ?? 0
        info.memoryBytes = sysctlUInt64("hw.memsize") ?? 0
        info.bootedAt = bootTime()
        info.gpuCores = gpuCoreCount()
        info.modelName = marketingName() ?? info.modelIdentifier
        return info
    }

    // MARK: - The pieces

    private static func sysctlString(_ key: String) -> String? {
        var size = 0
        guard sysctlbyname(key, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(key, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    private static func sysctlInt(_ key: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(key, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }

    private static func sysctlUInt64(_ key: String) -> UInt64? {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname(key, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }

    private static func bootTime() -> Date {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0 else { return Date() }
        return Date(timeIntervalSince1970: TimeInterval(boot.tv_sec))
    }

    /// The graphics driver publishes its core count in the IOKit registry.
    private static func gpuCoreCount() -> Int {
        var iterator: io_iterator_t = 0
        let matching = IOServiceMatching("IOAccelerator")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return 0
        }
        defer { IOObjectRelease(iterator) }

        var cores = 0
        var service = IOIteratorNext(iterator)
        while service != 0 {
            let key = "gpu-core-count" as CFString
            if let value = IORegistryEntryCreateCFProperty(service, key, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Int {
                cores = max(cores, value)
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return cores
    }

    /// The name Apple sells the machine under. Nothing in `sysctl` knows it, and
    /// the registry only has the model identifier, so this asks the same tool
    /// System Information uses. It takes about a tenth of a second, which is why
    /// it happens once on a background queue rather than on every reading.
    private static func marketingName() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPHardwareDataType", "-json"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hardware = root["SPHardwareDataType"] as? [[String: Any]],
              let name = hardware.first?["machine_name"] as? String
        else { return nil }
        return name
    }
}
