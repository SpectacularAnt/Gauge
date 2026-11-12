import Foundation
import IOKit

/// Reads graphics load from the IOKit registry.
///
/// The driver publishes a `PerformanceStatistics` dictionary under its
/// accelerator service.  "IOAccelerator" is the parent class, so matching on it
/// finds whatever Apple's current driver is called without us hard-coding a name
/// that changes between chip generations.
struct GPUSampler {

    func sample() -> GPUReading {
        var reading = GPUReading()

        var iterator: io_iterator_t = 0
        let matching = IOServiceMatching("IOAccelerator")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return reading
        }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            var properties: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dictionary = properties?.takeRetainedValue() as? [String: Any],
                  let statistics = dictionary["PerformanceStatistics"] as? [String: Any]
            else { continue }

            // A Mac can expose more than one accelerator service for the same
            // hardware, so take the busiest answer rather than the first.
            if let utilization = statistics["Device Utilization %"] as? Int {
                let fraction = min(Double(utilization) / 100, 1)
                reading.utilization = max(reading.utilization ?? 0, fraction)
            }
            if let inUse = statistics["In use system memory"] as? Int {
                reading.inUseMemory = max(reading.inUseMemory, UInt64(max(inUse, 0)))
            }
            if let allocated = statistics["Alloc system memory"] as? Int {
                reading.allocatedMemory = max(reading.allocatedMemory, UInt64(max(allocated, 0)))
            }
        }
        return reading
    }
}
