import Foundation

/// Reads the Mac's built-in temperature sensors.
///
/// macOS reports these through the HID event system, the same machinery behind
/// the trackpad and the ambient light sensor.  The five functions that walk it
/// are exported from IOKit but declared in no public header, so we look them up
/// by name once at launch.  If a future macOS withdraws any of them, `isReady`
/// turns false and Gauge simply stops offering temperatures instead of crashing.
///
/// Every handle stays an opaque raw pointer on purpose.  Swift's automatic
/// reference counting would otherwise try to retain and release objects whose
/// ownership rules it cannot see, which is a reliable way to corrupt memory.
final class TemperatureSampler {

    // The HID event system groups sensors by a vendor page and a usage number.
    private static let appleVendorPage = 0xff00
    private static let temperatureUsage = 0x0005
    /// `kIOHIDEventTypeTemperature`.  The reading lives in field `type << 16`.
    private static let temperatureEvent: Int32 = 15

    private typealias ClientCreate   = @convention(c) (CFAllocator?) -> UnsafeMutableRawPointer?
    private typealias ClientMatching = @convention(c) (UnsafeMutableRawPointer?, CFDictionary?) -> Int32
    private typealias CopyServices   = @convention(c) (UnsafeMutableRawPointer?) -> Unmanaged<CFArray>?
    private typealias CopyProperty   = @convention(c) (UnsafeRawPointer?, CFString?) -> Unmanaged<CFTypeRef>?
    private typealias CopyEvent      = @convention(c) (UnsafeRawPointer?, Int64, Int32, Int64) -> UnsafeMutableRawPointer?
    private typealias GetFloatValue  = @convention(c) (UnsafeMutableRawPointer?, Int32) -> Double

    private let createClient: ClientCreate
    private let setMatching: ClientMatching
    private let copyServices: CopyServices
    private let copyProperty: CopyProperty
    private let copyEvent: CopyEvent
    private let floatValue: GetFloatValue

    private let client: UnsafeMutableRawPointer

    /// The sensor list does not change while the Mac is running, so we find the
    /// services once and re-read them on every tick.
    private let services: [UnsafeRawPointer]
    private let names: [String]

    var isReady: Bool { !services.isEmpty }

    init?() {
        guard let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW) else {
            return nil
        }
        func symbol<T>(_ name: String, as type: T.Type) -> T? {
            guard let pointer = dlsym(iokit, name) else { return nil }
            return unsafeBitCast(pointer, to: type)
        }
        guard let create   = symbol("IOHIDEventSystemClientCreate", as: ClientCreate.self),
              let matching = symbol("IOHIDEventSystemClientSetMatching", as: ClientMatching.self),
              let services = symbol("IOHIDEventSystemClientCopyServices", as: CopyServices.self),
              let property = symbol("IOHIDServiceClientCopyProperty", as: CopyProperty.self),
              let event    = symbol("IOHIDServiceClientCopyEvent", as: CopyEvent.self),
              let value    = symbol("IOHIDEventGetFloatValue", as: GetFloatValue.self),
              let client   = create(kCFAllocatorDefault)
        else { return nil }

        self.createClient = create
        self.setMatching  = matching
        self.copyServices = services
        self.copyProperty = property
        self.copyEvent    = event
        self.floatValue   = value
        self.client       = client

        // Ask for temperature sensors and hold on to whatever came back.
        let filter: [String: Int] = [
            "PrimaryUsagePage": Self.appleVendorPage,
            "PrimaryUsage": Self.temperatureUsage,
        ]
        _ = matching(client, filter as CFDictionary)

        var foundServices: [UnsafeRawPointer] = []
        var foundNames: [String] = []
        if let array = services(client)?.takeRetainedValue() {
            for index in 0..<CFArrayGetCount(array) {
                guard let service = CFArrayGetValueAtIndex(array, index) else { continue }
                let name = property(service, "Product" as CFString)?
                    .takeRetainedValue() as? String ?? "Sensor \(index)"
                // The array is released when this initialiser returns, which
                // would release the services with it.  We keep the pointers, so
                // we take our own reference to each one and never give it back:
                // the sensor list has to outlive this function.
                _ = Unmanaged<CFTypeRef>.fromOpaque(service).retain()
                foundServices.append(service)
                foundNames.append(name)
            }
        }
        self.services = foundServices
        self.names = foundNames
    }

    func sample() -> TemperatureReading {
        var reading = TemperatureReading()
        guard isReady else { return reading }

        var dieValues: [Double] = []
        var batteryValues: [Double] = []
        var storageValues: [Double] = []

        for (service, name) in zip(services, names) {
            guard let event = copyEvent(service, Int64(Self.temperatureEvent), 0, 0) else { continue }
            let celsius = floatValue(event, Self.temperatureEvent << 16)

            // Discard the sensors that are not really reporting a temperature:
            // unused channels read far below freezing, and the calibration
            // channels sit at a fixed value that never moves.
            guard celsius > 1, celsius < 150 else { continue }
            guard !name.lowercased().contains("tcal") else { continue }

            let kind = Self.classify(name)
            switch kind {
            case .die:     dieValues.append(celsius)
            case .battery: batteryValues.append(celsius)
            case .storage: storageValues.append(celsius)
            case .other:   break
            }
            reading.all.append(TemperatureSample(name: name, celsius: celsius, kind: kind))
        }

        reading.all.sort { $0.celsius > $1.celsius }
        reading.hottestDie = dieValues.max()
        if !dieValues.isEmpty {
            reading.averageDie = dieValues.reduce(0, +) / Double(dieValues.count)
        }
        // Several sensors sit around the battery pack; their mean is steadier
        // than any single one.
        if !batteryValues.isEmpty {
            reading.battery = batteryValues.reduce(0, +) / Double(batteryValues.count)
        }
        reading.storage = storageValues.max()
        return reading
    }

    /// Sorts a sensor by its name.  Apple's naming is terse and undocumented:
    /// `tdie` channels sit on the chip itself, `tdev` channels on the board
    /// around it, and the battery and flash sensors say so plainly.
    private static func classify(_ name: String) -> TemperatureSample.Kind {
        let lowered = name.lowercased()
        if lowered.contains("tdie") { return .die }
        if lowered.contains("battery") || lowered.contains("gas gauge") { return .battery }
        if lowered.contains("nand") || lowered.contains("ssd") { return .storage }
        return .other
    }
}
