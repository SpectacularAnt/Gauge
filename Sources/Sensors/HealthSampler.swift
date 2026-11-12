import Foundation
import IOKit

/// One drive's own report on how worn it is.
///
/// Every NVMe drive keeps a health log — the SMART log — that it updates as it
/// goes. This is the same report iStat Menus and DriveDx read. macOS's Disk
/// Utility only ever summarises it as a pass or fail ("Verified"), which is how
/// a drive can be most of the way through its life with nobody noticing.
struct DriveHealth: Identifiable {
    var name = "Drive"              // "APPLE SSD AP1024Z"
    var firmware: String?
    var capacity: UInt64 = 0
    var isInternal = true
    var interconnect: String?       // "Apple Fabric", "PCI-Express"

    /// How much of its rated endurance the drive thinks it has used. It is an
    /// estimate by the drive's own maker, and can go past 100.
    var percentUsed = 0
    /// Reserve flash kept back to replace cells that wear out, 0...100.
    var availableSpare = 100
    /// Below this much spare, the drive raises a warning of its own.
    var spareThreshold = 0
    /// The drive's own alarm bits; zero means it has nothing to complain about.
    var criticalWarning: UInt8 = 0
    var temperature: Double?

    var dataRead: UInt64 = 0
    var dataWritten: UInt64 = 0
    var powerCycles: UInt64 = 0
    var powerOnHours: UInt64 = 0
    var unsafeShutdowns: UInt64 = 0
    var mediaErrors: UInt64 = 0
    var errorLogEntries: UInt64 = 0

    var id: String { name + (firmware ?? "") }

    /// The figure iStat Menus shows as "health": what is left of the rated
    /// endurance.
    var healthPercent: Int { max(100 - percentUsed, 0) }

    /// The drive's alarm bits, in words. Each bit is defined by the NVMe
    /// standard, so these mean the same on every maker's drive.
    var warnings: [String] {
        var found: [String] = []
        if criticalWarning & 0x01 != 0 { found.append("Spare capacity is below the drive's own safe level") }
        if criticalWarning & 0x02 != 0 { found.append("Temperature is outside the drive's safe range") }
        if criticalWarning & 0x04 != 0 { found.append("Reliability is degraded by internal errors") }
        if criticalWarning & 0x08 != 0 { found.append("The drive has switched itself to read-only") }
        if criticalWarning & 0x10 != 0 { found.append("The drive's backup power for its cache has failed") }
        return found
    }
}

/// Everything Gauge knows about wear, as opposed to load. Changes over months,
/// so it is read every few minutes rather than on every tick.
struct HealthReading {
    var drives: [DriveHealth] = []
    var readAt: Date?
}

/// Reads the health log of every drive that offers one.
///
/// Apple does not publish this interface, but it ships with macOS as a plug-in
/// (`NVMeSMARTLib.plugin`) that any program may load, and it needs no
/// administrator password. It is the same route `smartctl` takes. The
/// plug-in hands back a table of C function pointers; Gauge reads the two it
/// needs out of that table by their position in it.
struct HealthSampler {

    // The plug-in's identifiers. They are fixed by Apple and listed against the
    // drive in the IO registry, which is where these were checked.
    private static let userClientType = CFUUIDCreateFromString(nil, "AA0FA6F9-C2D6-457F-B10B-59A13253292F" as CFString)
    private static let smartInterface = CFUUIDCreateFromString(nil, "CCD1DB19-FD9A-4DAF-BF95-12454B230AB6" as CFString)
    private static let plugInInterface = CFUUIDCreateFromString(nil, "C244E858-109C-11D4-91D4-0050E4C6426F" as CFString)

    // Positions in the plug-in's function table. The first four slots are the
    // standard COM header (a reserved pointer, then QueryInterface, AddRef and
    // Release), then two 16-bit version numbers padded out to eight bytes, then
    // the drive-specific functions, starting with the one that reads the log.
    private static let releaseOffset = 24
    private static let readLogOffset = 40

    private typealias ReadLog = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> IOReturn
    private typealias Release = @convention(c) (UnsafeMutableRawPointer?) -> UInt32

    func sample() -> HealthReading {
        var reading = HealthReading()
        reading.readAt = Date()

        let matching = ["IOPropertyMatch": ["NVMe SMART Capable": true]] as CFDictionary
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return reading
        }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            if var drive = describe(service), let log = readLog(service) {
                Self.fill(&drive, from: log)
                reading.drives.append(drive)
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return reading
    }

    // MARK: - What the drive is

    private func describe(_ service: io_service_t) -> DriveHealth? {
        var drive = DriveHealth()
        if let device = property(service, "Device Characteristics") as? [String: Any] {
            if let name = device["Product Name"] as? String, !name.isEmpty { drive.name = name }
            drive.firmware = device["Product Revision Level"] as? String
        }
        if let proto = property(service, "Protocol Characteristics") as? [String: Any] {
            drive.interconnect = proto["Physical Interconnect"] as? String
            drive.isInternal = (proto["Physical Interconnect Location"] as? String) != "External"
        }
        // The whole-disk entry sits below this one and carries the size.
        let size = IORegistryEntrySearchCFProperty(service, kIOServicePlane, "Size" as CFString,
                                                   kCFAllocatorDefault,
                                                   IOOptionBits(kIORegistryIterateRecursively))
        if let bytes = size as? UInt64 { drive.capacity = bytes }
        else if let bytes = size as? Int { drive.capacity = UInt64(max(bytes, 0)) }
        return drive
    }

    private func property(_ service: io_service_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
    }

    // MARK: - Reading the log

    /// The raw 512-byte NVMe health log, or nil if the drive would not give it.
    private func readLog(_ service: io_service_t) -> [UInt8]? {
        var plugin: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>?
        var score: Int32 = 0
        guard IOCreatePlugInInterfaceForService(service, Self.userClientType, Self.plugInInterface,
                                                &plugin, &score) == KERN_SUCCESS,
              let plugin, let table = plugin.pointee
        else { return nil }
        defer { IODestroyPlugInInterface(plugin) }

        var raw: LPVOID?
        guard table.pointee.QueryInterface(plugin, CFUUIDGetUUIDBytes(Self.smartInterface), &raw) == S_OK,
              let interface = raw
        else { return nil }

        let functions = interface.load(as: UnsafeRawPointer.self)
        let readLog = functions.load(fromByteOffset: Self.readLogOffset, as: ReadLog.self)
        let release = functions.load(fromByteOffset: Self.releaseOffset, as: Release.self)
        defer { _ = release(interface) }

        var log = [UInt8](repeating: 0, count: 512)
        let status = log.withUnsafeMutableBytes { readLog(interface, $0.baseAddress) }
        return status == kIOReturnSuccess ? log : nil
    }

    /// Unpacks the log. The layout is fixed by the NVMe standard: single bytes
    /// for the percentages, then a run of 16-byte counters, of which the low
    /// eight bytes are plenty — they would take millions of years to overflow.
    static func fill(_ drive: inout DriveHealth, from log: [UInt8]) {
        guard log.count >= 192 else { return }
        func counter(_ offset: Int) -> UInt64 {
            (0..<8).reduce(UInt64(0)) { $0 | (UInt64(log[offset + $1]) << (8 * UInt64($1))) }
        }

        drive.criticalWarning = log[0]
        let kelvin = Int(log[1]) | (Int(log[2]) << 8)
        drive.temperature = kelvin > 0 ? Double(kelvin) - 273.15 : nil
        drive.availableSpare = Int(log[3])
        drive.spareThreshold = Int(log[4])
        drive.percentUsed = Int(log[5])

        // Data is counted in units of a thousand 512-byte sectors.
        drive.dataRead = counter(32) &* 512_000
        drive.dataWritten = counter(48) &* 512_000
        drive.powerCycles = counter(112)
        drive.powerOnHours = counter(128)
        drive.unsafeShutdowns = counter(144)
        drive.mediaErrors = counter(160)
        drive.errorLogEntries = counter(176)
    }
}
