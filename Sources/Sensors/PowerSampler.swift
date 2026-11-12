import Foundation
import IOKit
import IOKit.ps

/// Reads the battery.
///
/// Two sources are needed.  The power-sources API gives the friendly numbers
/// macOS shows in the menu bar, and the `AppleSmartBattery` registry entry gives
/// the electrical detail — cycle count, volts and milliamps — that the friendly
/// API leaves out.  Multiplying volts by amps is how we get a wattage, which is
/// the honest answer to "how much power is this machine drawing right now".
struct PowerSampler {

    func sample() -> PowerReading {
        var reading = PowerReading()
        readPowerSources(into: &reading)
        readSmartBattery(into: &reading)
        return reading
    }

    private func readPowerSources(into reading: inout PowerReading) {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?
                    .takeUnretainedValue() as? [String: Any] else { continue }
            guard description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }

            reading.hasBattery = true
            if let current = description[kIOPSCurrentCapacityKey] as? Int,
               let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 {
                reading.percentage = Double(current) / Double(maximum) * 100
            }
            reading.isCharging = description[kIOPSIsChargingKey] as? Bool ?? false
            reading.isPluggedIn = (description[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue

            // Both keys use -1 to mean "still working it out" and -2 to mean
            // "unknown", so anything below zero is not a time.
            let key = reading.isCharging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey
            if let minutes = description[key] as? Int, minutes > 0 {
                reading.minutesRemaining = minutes
            }
        }
    }

    private func readSmartBattery(into reading: inout PowerReading) {
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                  IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }

        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dictionary = properties?.takeRetainedValue() as? [String: Any]
        else { return }

        reading.hasBattery = true
        reading.cycleCount = dictionary["CycleCount"] as? Int

        // Millivolts and milliamps, so their product is in microwatts.  Amperage
        // is negative while discharging; the sign tells us the direction, which
        // we already know from `isCharging`, so the wattage itself is absolute.
        if let millivolts = dictionary["Voltage"] as? Int {
            reading.voltage = Double(millivolts) / 1000
        }
        if let milliamps = dictionary["Amperage"] as? Int {
            reading.amperage = Double(milliamps) / 1000
            if let millivolts = dictionary["Voltage"] as? Int {
                reading.watts = abs(Double(milliamps) * Double(millivolts)) / 1_000_000
            }
        }

        // Battery health. Newer Macs report `MaxCapacity` already as a
        // percentage of the original; older ones report raw milliamp-hours that
        // have to be compared against the design figure.
        if let raw = dictionary["AppleRawMaxCapacity"] as? Int,
           let design = dictionary["DesignCapacity"] as? Int, design > 0 {
            reading.healthPercentage = Double(raw) / Double(design) * 100
        } else if let maximum = dictionary["MaxCapacity"] as? Int, maximum > 0, maximum <= 100 {
            reading.healthPercentage = Double(maximum)
        }
    }
}
