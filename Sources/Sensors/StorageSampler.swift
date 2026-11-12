import Foundation
import IOKit

/// Reads free space on the boot volume and how hard the drive is working.
///
/// Like the CPU counters, the byte totals only ever rise, so a rate is the
/// difference between two readings divided by the time between them.
final class StorageSampler {

    private var previousRead: UInt64?
    private var previousWrite: UInt64?
    private var previousTime: Date?

    func sample() -> StorageReading {
        var reading = StorageReading()

        // Capacity. `volumeAvailableCapacityForImportantUsage` is the number
        // Finder shows: it counts space macOS would free by clearing caches and
        // purgeable snapshots, which is space you can actually use.
        let keys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ]
        if let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys) {
            reading.total = UInt64(max(values.volumeTotalCapacity ?? 0, 0))
            reading.free = UInt64(max(values.volumeAvailableCapacityForImportantUsage ?? 0, 0))
        }

        // Throughput, summed over every block device the kernel knows about.
        var totalRead: UInt64 = 0
        var totalWrite: UInt64 = 0
        var iterator: io_iterator_t = 0
        let matching = IOServiceMatching("IOBlockStorageDriver")
        if IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS {
            var service = IOIteratorNext(iterator)
            while service != 0 {
                var properties: Unmanaged<CFMutableDictionary>?
                if IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                   let dictionary = properties?.takeRetainedValue() as? [String: Any],
                   let statistics = dictionary["Statistics"] as? [String: Any] {
                    if let read = statistics["Bytes (Read)"] as? Int {
                        totalRead += UInt64(max(read, 0))
                    }
                    if let written = statistics["Bytes (Write)"] as? Int {
                        totalWrite += UInt64(max(written, 0))
                    }
                }
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            IOObjectRelease(iterator)
        }

        reading.readTotal = totalRead
        reading.writeTotal = totalWrite

        let now = Date()
        if let lastRead = previousRead, let lastWrite = previousWrite, let lastTime = previousTime {
            let seconds = now.timeIntervalSince(lastTime)
            if seconds > 0.01 {
                // A counter that went backwards means a drive was unplugged, so
                // report nothing rather than a nonsense negative rate.
                reading.readRate = totalRead >= lastRead
                    ? Double(totalRead - lastRead) / seconds : 0
                reading.writeRate = totalWrite >= lastWrite
                    ? Double(totalWrite - lastWrite) / seconds : 0
            }
        }
        previousRead = totalRead
        previousWrite = totalWrite
        previousTime = now
        return reading
    }
}
