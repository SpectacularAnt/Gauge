import AppKit
import Foundation

struct VolumeReading: Identifiable {
    let name: String
    let total: UInt64
    let free: UInt64
    let isInternal: Bool
    var id: String { name }

    var used: UInt64 { total > free ? total - free : 0 }
    var usedFraction: Double { total == 0 ? 0 : Double(used) / Double(total) }
}

struct InterfaceDetail: Identifiable {
    let name: String
    let address: String?
    /// Negotiated link speed in megabits per second, 0 when the link is down.
    let linkSpeedMbit: UInt64
    var id: String { name }
}

struct DisplayInfo: Identifiable {
    let name: String
    let width: Int
    let height: Int
    let scale: Double
    let refreshHz: Int
    var id: String { name }
}

struct SystemReading {
    /// macOS's own verdict on how hot things are, which is not the same as a
    /// temperature: it reflects whether the system is about to start slowing
    /// itself down.
    var thermalState: ProcessInfo.ThermalState = .nominal
    var lowPowerMode = false
    var uptime: TimeInterval = 0
    var volumes: [VolumeReading] = []
    var interfaces: [InterfaceDetail] = []
    var displays: [DisplayInfo] = []

    var thermalDescription: String {
        switch thermalState {
        case .nominal:  return "Normal"
        case .fair:     return "Warm"
        case .serious:  return "Hot"
        case .critical: return "Throttling"
        @unknown default: return "Unknown"
        }
    }
}

/// The odds and ends that describe the machine's current situation rather than
/// its load: how hot macOS thinks it is, what is mounted, what is plugged in.
struct SystemSampler {

    let bootedAt: Date

    func sample() -> SystemReading {
        var reading = SystemReading()
        let process = ProcessInfo.processInfo
        reading.thermalState = process.thermalState
        reading.lowPowerMode = process.isLowPowerModeEnabled
        reading.uptime = Date().timeIntervalSince(bootedAt)
        reading.volumes = volumes()
        reading.interfaces = interfaces()
        // Displays are deliberately not filled in here. NSScreen is only safe to
        // read from the main thread, and this runs on a background queue, so the
        // engine fills them in when it publishes.
        return reading
    }

    private func volumes() -> [VolumeReading] {
        let keys: [URLResourceKey] = [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeIsInternalKey,
        ]
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) ?? []

        var found: [VolumeReading] = []
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            let total = UInt64(max(values.volumeTotalCapacity ?? 0, 0))
            guard total > 0 else { continue }
            let free = UInt64(max(values.volumeAvailableCapacityForImportantUsage ?? 0, 0))
            found.append(VolumeReading(name: values.volumeName ?? url.lastPathComponent,
                                       total: total,
                                       free: free,
                                       isInternal: values.volumeIsInternal ?? false))
        }
        // Internal drives first, then biggest first, so the boot disk leads.
        return found.sorted { left, right in
            if left.isInternal != right.isInternal { return left.isInternal }
            return left.total > right.total
        }
    }

    private func interfaces() -> [InterfaceDetail] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var speeds: [String: UInt64] = [:]
        var addresses: [String: String] = [:]

        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = pointer {
            pointer = entry.pointee.ifa_next
            let name = String(cString: entry.pointee.ifa_name)
            guard name.hasPrefix("en"), let address = entry.pointee.ifa_addr else { continue }

            if address.pointee.sa_family == UInt8(AF_LINK), let data = entry.pointee.ifa_data {
                let stats = data.assumingMemoryBound(to: if_data.self).pointee
                speeds[name] = UInt64(stats.ifi_baudrate) / 1_000_000
            }
            if address.pointee.sa_family == UInt8(AF_INET), addresses[name] == nil {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let length = socklen_t(address.pointee.sa_len)
                if getnameinfo(address, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    addresses[name] = String(cString: host)
                }
            }
        }

        // Only the interfaces doing something: one with no address and no link
        // is a port with nothing in it.
        var found: [InterfaceDetail] = []
        for name in Set(speeds.keys).union(addresses.keys).sorted() {
            let speed = speeds[name] ?? 0
            let address = addresses[name]
            guard address != nil || speed > 0 else { continue }
            found.append(InterfaceDetail(name: name, address: address, linkSpeedMbit: speed))
        }
        return found
    }

    /// Main thread only.
    static func currentDisplays() -> [DisplayInfo] {
        NSScreen.screens.map { screen in
            DisplayInfo(name: screen.localizedName,
                        width: Int(screen.frame.width),
                        height: Int(screen.frame.height),
                        scale: Double(screen.backingScaleFactor),
                        refreshHz: screen.maximumFramesPerSecond)
        }
    }
}
