import Foundation

/// Reads how memory is being spent.
///
/// The kernel counts memory in pages rather than bytes, and on Apple Silicon a
/// page is 16 KB.  Page counts are 32-bit, so every multiplication here widens
/// to `UInt64` first — 11 GB of active pages overflows a `UInt32` long before
/// you reach the answer.
struct MemorySampler {

    private let pageSize = UInt64(vm_kernel_page_size)
    private let totalBytes: UInt64 = {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &value, &size, nil, 0)
        return value
    }()

    func sample() -> MemoryReading {
        var reading = MemoryReading()
        reading.total = totalBytes

        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride
                                           / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, reboundPointer, &count)
            }
        }
        guard result == KERN_SUCCESS else { return reading }

        func bytes(_ pages: UInt32) -> UInt64 { UInt64(pages) * pageSize }

        // This is the split Activity Monitor shows.  "Internal" pages belong to
        // running programs; "external" pages are file contents the kernel is
        // keeping in case they are read again.  Purgeable pages can be thrown
        // away on demand, so they count as cache rather than as app memory.
        let purgeable = bytes(stats.purgeable_count)
        let internalPages = bytes(stats.internal_page_count)

        reading.app = internalPages > purgeable ? internalPages - purgeable : 0
        reading.wired = bytes(stats.wire_count)
        reading.compressed = bytes(stats.compressor_page_count)
        reading.cached = bytes(stats.external_page_count) + purgeable
        reading.used = reading.app + reading.wired + reading.compressed

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 {
            reading.swapUsed = swap.xsu_used
            reading.swapTotal = swap.xsu_total
        }

        var level: Int32 = 0
        var levelSize = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &levelSize, nil, 0) == 0 {
            reading.pressureLevel = Int(level)
        }
        return reading
    }
}
