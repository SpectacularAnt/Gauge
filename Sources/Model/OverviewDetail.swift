import Foundation

/// One of an Overview section's usual lines under its chart.
///
/// Each is also a fact on the section's Inspect page; ticking that fact while
/// editing the page turns the line on. The Overview draws these its own way,
/// with the bars and combined values it always had, rather than as the
/// page's plainer rows. Anything else on the page can be ticked too, and is
/// then shown as the page shows it. The charts, core bars and memory bar are not on the
/// menu: they are what the section is, and always stay.
///
/// Everything here is drawn from readings the engine already takes every tick,
/// so showing more of them costs nothing extra. The slower facts that are only
/// gathered while an Inspect page is open stay on that page.
///
/// The raw values are what is saved, so renaming a case would forget it was
/// chosen.
enum OverviewDetail: String, CaseIterable, Identifiable {

    // Processor
    case cpuUser, cpuSystem, cpuIdle, cpuLoad, cpuBusiestCore
    case cpuPerformance, cpuEfficiency, cpuPrograms

    // Memory
    case memoryUsed, memoryPressure, memorySwap, memoryInstalled
    case memoryApp, memoryWired, memoryCompressed, memoryCached

    // Graphics
    case gpuBusy, gpuMemoryInUse, gpuMemoryAllocated, gpuCores, gpuDisplays

    // Temperature
    case temperatureHottest, temperatureAverage, temperatureBattery, temperatureSSD
    case temperatureThermalState

    // Power
    case powerCharge, powerDrawing, powerRemaining, powerHealth, powerCycles
    case powerVoltage, powerCurrent, powerBatteryTemperature, powerLowPowerMode

    // Storage
    case storageVolumes, storageDriveHealth, storageReadTotal, storageWriteTotal
    case storageDriveWritten, storageDrivePoweredOn, storageDriveUnsafeShutdowns
    case storageDriveTemperature

    // Network
    case networkInterfaces, networkReceived, networkSent, networkDownNow, networkUpNow

    // System
    case systemModel, systemIdentifier, systemChip, systemCPUCores, systemGPUCores
    case systemMemory, systemMacOS, systemBooted, systemUptime
    case systemThermalState, systemLowPowerMode

    var id: String { rawValue }

    var section: OverviewSection {
        switch self {
        case .cpuUser, .cpuSystem, .cpuIdle, .cpuLoad, .cpuBusiestCore,
             .cpuPerformance, .cpuEfficiency, .cpuPrograms:
            return .processor
        case .memoryUsed, .memoryPressure, .memorySwap, .memoryInstalled,
             .memoryApp, .memoryWired, .memoryCompressed, .memoryCached:
            return .memory
        case .gpuBusy, .gpuMemoryInUse, .gpuMemoryAllocated, .gpuCores, .gpuDisplays:
            return .graphics
        case .temperatureHottest, .temperatureAverage, .temperatureBattery, .temperatureSSD,
             .temperatureThermalState:
            return .temperature
        case .powerCharge, .powerDrawing, .powerRemaining, .powerHealth, .powerCycles,
             .powerVoltage, .powerCurrent, .powerBatteryTemperature, .powerLowPowerMode:
            return .power
        case .storageVolumes, .storageDriveHealth, .storageReadTotal, .storageWriteTotal,
             .storageDriveWritten, .storageDrivePoweredOn, .storageDriveUnsafeShutdowns,
             .storageDriveTemperature:
            return .storage
        case .networkInterfaces, .networkReceived, .networkSent, .networkDownNow, .networkUpNow:
            return .network
        case .systemModel, .systemIdentifier, .systemChip, .systemCPUCores, .systemGPUCores,
             .systemMemory, .systemMacOS, .systemBooted, .systemUptime,
             .systemThermalState, .systemLowPowerMode:
            return .system
        }
    }

    /// Where this line appears on the section's Inspect page: which block,
    /// and which label in it. Ticking that fact while editing the page turns
    /// this line on, so the Overview keeps its own way of drawing it.
    private var onPage: (group: GroupMatch, labels: [String]) {
        switch self {
        case .cpuUser:                     return (.titled("Right now"), ["Your programs"])
        case .cpuSystem:                   return (.titled("Right now"), ["macOS itself"])
        case .cpuIdle:                     return (.titled("Right now"), ["Idle"])
        case .cpuLoad:                     return (.titled("Right now"), ["Load average"])
        case .cpuBusiestCore:              return (.titled("Right now"), ["Busiest core"])
        case .cpuPerformance:              return (.titled("Right now"), ["Performance cores, average"])
        case .cpuEfficiency:               return (.titled("Right now"), ["Efficiency cores, average"])
        case .cpuPrograms:                 return (.titled("Right now"), ["Programs running"])
        case .memoryUsed:                  return (.titled("Right now"), ["In use"])
        case .memoryPressure:              return (.titled("Right now"), ["Pressure"])
        case .memorySwap:                  return (.titled("Right now"), ["Swap used"])
        case .memoryInstalled:             return (.titled("Right now"), ["Installed"])
        case .memoryApp:                   return (.titled("Right now"), ["App memory"])
        case .memoryWired:                 return (.titled("Right now"), ["Wired"])
        case .memoryCompressed:            return (.titled("Right now"), ["Compressed"])
        case .memoryCached:                return (.titled("Right now"), ["Cached files"])
        case .gpuBusy:                     return (.titled("Right now"), ["Busy"])
        case .gpuMemoryInUse:              return (.titled("Right now"), ["Memory in use"])
        case .gpuMemoryAllocated:          return (.titled("Right now"), ["Memory set aside"])
        case .gpuCores:                    return (.titled("The GPU"), ["Cores"])
        case .gpuDisplays:                 return (.kind("display"), ["Looks like"])
        case .temperatureHottest:          return (.titled("Summary"), ["Chip, hottest sensor"])
        case .temperatureAverage:          return (.titled("Summary"), ["Chip, average"])
        case .temperatureBattery:          return (.titled("Summary"), ["Battery"])
        case .temperatureSSD:              return (.titled("Summary"), ["SSD, sensor"])
        case .temperatureThermalState:     return (.titled("Summary"), ["macOS thermal state"])
        case .powerCharge:                 return (.titled("Right now"), ["Charge"])
        case .powerDrawing:                return (.titled("Right now"), ["Drawing", "Charging at"])
        case .powerRemaining:              return (.titled("Right now"), ["Time left", "Until full"])
        case .powerHealth:                 return (.titled("Battery health"), ["Health, as macOS reports it"])
        case .powerCycles:                 return (.titled("Battery health"), ["Charge cycles"])
        case .powerVoltage:                return (.titled("Right now"), ["Voltage"])
        case .powerCurrent:                return (.titled("Right now"), ["Current"])
        case .powerBatteryTemperature:     return (.titled("Right now"), ["Temperature"])
        case .powerLowPowerMode:           return (.titled("Right now"), ["Low Power Mode"])
        case .storageVolumes:              return (.kind("volume"), ["Used"])
        case .storageDriveHealth:          return (.kind("drive"), ["Health"])
        case .storageReadTotal:            return (.titled("Activity"), ["Read since the Mac started"])
        case .storageWriteTotal:           return (.titled("Activity"), ["Written since the Mac started"])
        case .storageDriveWritten:         return (.kind("drive"), ["Written in its lifetime"])
        case .storageDrivePoweredOn:       return (.kind("drive"), ["Powered on for"])
        case .storageDriveUnsafeShutdowns: return (.kind("drive"), ["Unsafe shutdowns"])
        case .storageDriveTemperature:     return (.kind("drive"), ["Temperature"])
        case .networkInterfaces:           return (.connection, ["Status"])
        case .networkReceived:             return (.titled("Right now"), ["Received since the Mac started"])
        case .networkSent:                 return (.titled("Right now"), ["Sent since the Mac started"])
        case .networkDownNow:              return (.titled("Right now"), ["Downloading"])
        case .networkUpNow:                return (.titled("Right now"), ["Uploading"])
        case .systemModel:                 return (.titled("This Mac"), ["Model"])
        case .systemIdentifier:            return (.titled("This Mac"), ["Model identifier"])
        case .systemChip:                  return (.titled("This Mac"), ["Chip"])
        case .systemCPUCores:              return (.titled("This Mac"), ["CPU cores"])
        case .systemGPUCores:              return (.titled("This Mac"), ["GPU cores"])
        case .systemMemory:                return (.titled("This Mac"), ["Memory"])
        case .systemMacOS:                 return (.titled("macOS"), ["Version"])
        case .systemBooted:                return (.titled("macOS"), ["Started"])
        case .systemUptime:                return (.titled("macOS"), ["Running for"])
        case .systemThermalState:          return (.titled("macOS"), ["Thermal state"])
        case .systemLowPowerMode:          return (.titled("macOS"), ["Low Power Mode"])
        }
    }

    /// Which blocks on a page a line can come from. Drives, volumes, displays
    /// and connections are one block each, named after the thing itself, so
    /// those are matched by kind and the line covers every one of them.
    private enum GroupMatch {
        case titled(String)
        case kind(String)
        /// A network connection's block, labelled with its port, like "en0".
        case connection

        func matches(_ group: FactGroup) -> Bool {
            switch self {
            case .titled(let title): return group.title == title
            case .kind(let kind):    return group.subtitle == kind
            case .connection:        return group.subtitle?.hasPrefix("en") == true
            }
        }
    }

    func matches(_ group: FactGroup, _ fact: Fact) -> Bool {
        let place = onPage
        return place.group.matches(group) && place.labels.contains(fact.label)
    }

    /// The usual line a fact on a section's page stands for, if it is one.
    static func line(for fact: Fact, in group: FactGroup, of section: OverviewSection) -> OverviewDetail? {
        options(for: section).first { $0.matches(group, fact) }
    }

    /// The menu for one section, in the order the section lists them.
    static func options(for section: OverviewSection) -> [OverviewDetail] {
        allCases.filter { $0.section == section }
    }

    /// What each section showed before any of this was choosable, so nothing
    /// moves until you change it.
    static let defaults: Set<OverviewDetail> = [
        .cpuUser, .cpuSystem, .cpuLoad, .cpuBusiestCore,
        .memoryUsed, .memoryPressure, .memorySwap,
        .gpuMemoryInUse, .gpuMemoryAllocated, .gpuDisplays,
        .temperatureHottest, .temperatureAverage, .temperatureBattery, .temperatureSSD,
        .temperatureThermalState,
        .powerCharge, .powerDrawing, .powerRemaining, .powerHealth, .powerCycles,
        .powerVoltage, .powerCurrent,
        .storageVolumes, .storageDriveHealth, .storageReadTotal, .storageWriteTotal,
        .networkInterfaces, .networkReceived, .networkSent,
        .systemModel, .systemIdentifier, .systemChip, .systemCPUCores, .systemGPUCores,
        .systemMemory, .systemMacOS, .systemBooted, .systemUptime,
    ]
}
