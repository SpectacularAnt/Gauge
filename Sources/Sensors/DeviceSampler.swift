import Foundation
import IOKit
import IOKit.ps

/// One device connected to, or paired with, this Mac: headphones, a mouse, a
/// phone, a drive plugged in by cable.
struct DeviceInfo: Identifiable, Equatable {
    enum Kind: String {
        case headphones = "Headphones"
        case headset = "Headset"
        case speaker = "Speaker"
        case mouse = "Mouse"
        case keyboard = "Keyboard"
        case trackpad = "Trackpad"
        case gameController = "Game controller"
        case phone = "Phone"
        case watch = "Watch"
        case tablet = "Tablet"
        case computer = "Computer"
        case storage = "Storage"
        case other = "Device"

        /// SF Symbol for the row.
        var symbol: String {
            switch self {
            case .headphones:     return "headphones"
            case .headset:        return "headphones"
            case .speaker:        return "hifispeaker"
            case .mouse:          return "computermouse"
            case .keyboard:       return "keyboard"
            case .trackpad:       return "rectangle.and.hand.point.up.left"
            case .gameController: return "gamecontroller"
            case .phone:          return "iphone"
            case .watch:          return "applewatch"
            case .tablet:         return "ipad"
            case .computer:       return "laptopcomputer"
            case .storage:        return "externaldrive"
            case .other:          return "dot.radiowaves.left.and.right"
            }
        }
    }

    enum Link: String {
        case bluetooth = "Bluetooth"
        case usb = "USB"
    }

    struct Battery: Equatable {
        /// "Left", "Right", "Case", or "Battery" for a device with just one.
        let part: String
        let percent: Int
        var isCharging = false
    }

    let id: String
    let name: String
    let kind: Kind
    let link: Link
    let isConnected: Bool
    var maker: String?
    /// The maker's and model's numbers, used to match a device with the
    /// battery macOS reports for it.
    var vendorID: Int?
    var productID: Int?
    var batteries: [Battery] = []
    /// True when the batteries come from macOS's live list rather than the
    /// Bluetooth report's memory of the last time it was connected.
    var batteryIsLive = false
    /// Bluetooth signal strength in dBm, when the device is in range. A phone
    /// or watch that is nearby but not connected still reports one.
    var signal: Int?
    /// Everything else, as label and value, in the order to show it.
    var details: [(label: String, value: String)] = []

    static func == (lhs: DeviceInfo, rhs: DeviceInfo) -> Bool {
        lhs.id == rhs.id && lhs.isConnected == rhs.isConnected && lhs.batteries == rhs.batteries
            && lhs.signal == rhs.signal && lhs.name == rhs.name
            && lhs.details.map(\.value) == rhs.details.map(\.value)
    }

    /// The one level that stands for the device: its only battery, or the
    /// lower earbud, which runs out first. The case is not counted.
    var headlineBattery: Int? {
        let buds = batteries.filter { $0.part != "Case" }
        return (buds.isEmpty ? batteries : buds).map(\.percent).min()
    }

    /// The level for the menu bar: only while the device is connected to
    /// this Mac. AirPods in their case nearby still report a live battery,
    /// but a pair you are not using has no business in the menu bar.
    var menuBarLevel: Int? {
        isConnected ? headlineBattery : nil
    }

    /// A few letters for the menu bar's Labels style: the name without the
    /// owner's name in front ("Sam's AirPods"), first word only.
    var menuBarLabel: String {
        var text = name
        for mark in ["\u{2019}s ", "'s "] {
            if let range = text.range(of: mark) { text = String(text[range.upperBound...]) }
        }
        let word = text.split(separator: " ").first.map(String.init) ?? text
        return String(word.prefix(7)).uppercased()
    }

    /// The glyph for the row. AirPods get Apple's own drawing of them; the
    /// rest go by kind.
    var symbol: String {
        if link == .usb { return "cable.connector" }
        let lower = name.lowercased()
        if lower.contains("airpods max") { return "airpodsmax" }
        if lower.contains("airpods pro") { return "airpodspro" }
        if lower.contains("airpods") { return "airpods" }
        return kind.symbol
    }

    /// In words, for a signal reading. Bluetooth signal is a negative number:
    /// nearer zero is stronger.
    static func describe(signal: Int) -> String {
        switch signal {
        case (-55)...:      return "Strong"
        case (-70)...(-56): return "Good"
        case (-85)...(-71): return "Weak"
        default:            return "Very weak"
        }
    }
}

/// Finds every device this Mac knows about.
///
/// Bluetooth comes from `system_profiler`, the same report System Information
/// shows, which lists every paired device whether or not it is connected and
/// includes the batteries macOS knows about. It takes a moment, so it is only
/// run while the Devices tab is open, and never while the panel is being
/// drawn. USB devices come from the I/O registry, which is instant.
enum DeviceSampler {

    static func sample() -> [DeviceInfo] {
        merge(bluetooth(), with: accessoryBatteries()) + usb()
    }

    // MARK: Batteries

    /// A battery macOS is keeping track of for an accessory: the levels it
    /// shows in Control Center's Bluetooth menu and in the Batteries widget.
    struct AccessoryBattery: Equatable {
        let name: String
        let vendorID: Int?
        let productID: Int?
        let parts: [DeviceInfo.Battery]
    }

    /// Batteries from macOS's list of power sources, which holds the Mac's
    /// own battery and, separately, every accessory's: headphones, mice,
    /// keyboards. That list is where the levels for most non-Apple devices
    /// live, since the Bluetooth report leaves them out.
    ///
    /// Reading the accessory half takes `IOPSCopyPowerSourcesByType`, which
    /// `pmset` uses but Apple has not put in the public headers. It is looked
    /// up by name, so if a future macOS removes it, batteries simply go back
    /// to what the Bluetooth report has, rather than Gauge failing.
    static func accessoryBatteries() -> [AccessoryBattery] {
        typealias ByType = @convention(c) (Int32) -> Unmanaged<CFTypeRef>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "IOPSCopyPowerSourcesByType")
        else { return [] }
        let copyByType = unsafeBitCast(symbol, to: ByType.self)
        // 4 is "sources provided by accessories" in IOKit's own numbering.
        guard let info = copyByType(4)?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return [] }
        let descriptions = list.compactMap {
            IOPSGetPowerSourceDescription(info, $0)?.takeUnretainedValue() as? [String: Any]
        }
        return parseAccessories(descriptions)
    }

    /// Earbuds come as two sources sharing a group: the buds, with a left and
    /// right part inside, and the case. Everything else is a single source.
    static func parseAccessories(_ descriptions: [[String: Any]]) -> [AccessoryBattery] {
        var groups: [String: [[String: Any]]] = [:]
        var order: [String] = []
        for description in descriptions where description["Type"] as? String == "Accessory Source" {
            let key = (description["Group Identifier"] as? String)
                ?? (description["Accessory Identifier"] as? String)
                ?? (description["Name"] as? String) ?? UUID().uuidString
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(description)
        }

        return order.compactMap { key in
            let sources = groups[key] ?? []
            let main = sources.first { $0["Part Identifier"] as? String != "Case" } ?? sources.first
            guard let main, let name = main["Name"] as? String else { return nil }
            var parts: [DeviceInfo.Battery] = []
            for source in sources {
                let charging = (source["Is Charging"] as? Int ?? 0) != 0
                switch source["Part Identifier"] as? String {
                case "Combined":
                    for piece in source["Combined Parts"] as? [[String: Any]] ?? [] {
                        guard let level = piece["Current Capacity"] as? Int else { continue }
                        parts.append(.init(part: piece["Part Identifier"] as? String ?? "Battery",
                                           percent: level, isCharging: charging))
                    }
                case "Case":
                    if let level = source["Current Capacity"] as? Int {
                        parts.append(.init(part: "Case", percent: level, isCharging: charging))
                    }
                default:
                    if let level = source["Current Capacity"] as? Int {
                        parts.append(.init(part: "Battery", percent: level, isCharging: charging))
                    }
                }
            }
            let order = ["Battery", "Left", "Right", "Case"]
            parts.sort { (order.firstIndex(of: $0.part) ?? 9) < (order.firstIndex(of: $1.part) ?? 9) }
            return AccessoryBattery(name: name, vendorID: main["Vendor ID"] as? Int,
                                    productID: main["Product ID"] as? Int, parts: parts)
        }
    }

    /// Gives each Bluetooth device the batteries macOS is tracking for it,
    /// which are fresher than the Bluetooth report's and cover far more
    /// makers. Matched by maker and model number, and by name where two of the
    /// same model are paired.
    static func merge(_ devices: [DeviceInfo], with accessories: [AccessoryBattery]) -> [DeviceInfo] {
        var unused = accessories
        return devices.map { device in
            let sameModel = unused.indices.filter {
                unused[$0].vendorID != nil && unused[$0].vendorID == device.vendorID
                    && unused[$0].productID == device.productID
            }
            let byName = unused.indices.filter { unused[$0].name == device.name }
            let pick = sameModel.first { unused[$0].name == device.name }
                ?? (sameModel.count == 1 && device.isConnected ? sameModel.first : nil)
                ?? byName.first
            guard let index = pick, !unused[index].parts.isEmpty else { return device }
            var updated = device
            updated.batteries = unused[index].parts
            updated.batteryIsLive = true
            unused.remove(at: index)
            return updated
        }
    }

    // MARK: Bluetooth

    static func bluetooth() -> [DeviceInfo] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType", "-json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return parseBluetooth(data)
    }

    /// The report lists connected devices and paired-but-not-connected ones
    /// in two lists, each an array of one-entry dictionaries keyed by name.
    static func parseBluetooth(_ data: Data) -> [DeviceInfo] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let report = (root["SPBluetoothDataType"] as? [[String: Any]])?.first
        else { return [] }

        var devices: [DeviceInfo] = []
        for (listKey, connected) in [("device_connected", true), ("device_not_connected", false)] {
            for entry in report[listKey] as? [[String: Any]] ?? [] {
                for (name, value) in entry {
                    guard let info = value as? [String: String] ?? (value as? [String: Any])?
                            .compactMapValues({ $0 as? String })
                    else { continue }
                    devices.append(bluetoothDevice(name: name, info: info, connected: connected))
                }
            }
        }
        // Connected first, then by name.
        return devices.sorted {
            $0.isConnected != $1.isConnected ? $0.isConnected
                : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    static func bluetoothDevice(name: String, info: [String: String], connected: Bool) -> DeviceInfo {
        let vendor = info["device_vendorID"].flatMap(hexNumber)
        var device = DeviceInfo(
            id: "bt-" + (info["device_address"] ?? name),
            name: name,
            kind: kind(minorType: info["device_minorType"], name: name),
            link: .bluetooth,
            isConnected: connected,
            maker: vendor.flatMap { bluetoothMakers[$0] } ?? appleByName(name))
        device.vendorID = vendor
        device.productID = info["device_productID"].flatMap(hexNumber)

        // Batteries: one plain level, or the parts of a set of earbuds.
        let parts: [(key: String, part: String)] = [
            ("device_batteryLevelMain", "Battery"), ("device_batteryLevel", "Battery"),
            ("device_batteryLevelLeft", "Left"), ("device_batteryLevelRight", "Right"),
            ("device_batteryLevelCase", "Case"),
        ]
        for (key, part) in parts {
            if let text = info[key], let percent = Int(text.filter(\.isNumber)) {
                device.batteries.append(.init(part: part, percent: percent))
            }
        }
        device.signal = info["device_rssi"].flatMap { Int($0) }

        var details: [(String, String)] = []
        if let address = info["device_address"] { details.append(("Address", address)) }
        if let firmware = info["device_firmwareVersion"] { details.append(("Firmware", firmware)) }
        if let caseFirmware = info["device_caseVersion"] { details.append(("Case firmware", caseFirmware)) }
        if let serial = info["device_serialNumber"] { details.append(("Serial number", serial)) }
        if let left = info["device_serialNumberLeft"] { details.append(("Left serial number", left)) }
        if let right = info["device_serialNumberRight"] { details.append(("Right serial number", right)) }
        if let vendorText = info["device_vendorID"] { details.append(("Vendor ID", vendorText)) }
        if let product = info["device_productID"] { details.append(("Product ID", product)) }
        if let services = info["device_services"] {
            // "0x800019 < HFP AVRCP A2DP ACL >": the names are the useful part.
            let names = services.split(separator: "<").last.map {
                $0.replacingOccurrences(of: ">", with: "").trimmingCharacters(in: .whitespaces)
            }
            if let names, !names.isEmpty {
                details.append(("Bluetooth profiles", names.split(separator: " ").joined(separator: ", ")))
            }
        }
        device.details = details
        return device
    }

    /// What kind of thing it is. macOS says for most devices; phones and
    /// watches paired for Continuity come with no type at all, so their names
    /// are the only clue.
    static func kind(minorType: String?, name: String) -> DeviceInfo.Kind {
        switch minorType?.lowercased() {
        case "headphones":                       return .headphones
        case "headset":                          return .headset
        case "speaker", "loudspeaker", "portable audio", "hifi audio device":
            return .speaker
        case "mouse":                            return .mouse
        case "keyboard":                         return .keyboard
        case "trackpad", "digitizer tablet":     return .trackpad
        case "gamepad", "joystick":              return .gameController
        case "smartphone", "cellular", "phone":  return .phone
        case "wearable", "wrist watch":          return .watch
        case "desktop", "laptop", "computer":    return .computer
        default: break
        }
        let lower = name.lowercased()
        if lower.contains("iphone") { return .phone }
        if lower.contains("watch") { return .watch }
        if lower.contains("ipad") { return .tablet }
        if lower.contains("airpods") || lower.contains("beats") { return .headphones }
        if lower.contains("macbook") || lower.contains("imac") || lower.contains("mac mini") { return .computer }
        return .other
    }

    /// Phones and watches paired for Continuity come without a maker, but
    /// only Apple makes an iPhone, iPad or Apple Watch.
    static func appleByName(_ name: String) -> String? {
        // Device names often hold a no-break space, as in "Apple Watch".
        let lower = name.lowercased().replacingOccurrences(of: "\u{00A0}", with: " ")
        return ["iphone", "ipad", "apple watch", "airpods"].contains { lower.contains($0) } ? "Apple" : nil
    }

    /// Bluetooth company numbers for the makers most likely to turn up. The
    /// full list runs to thousands; anything else is shown as its number.
    static let bluetoothMakers: [Int: String] = [
        0x004C: "Apple", 0x054C: "Sony", 0x046D: "Logitech", 0x045E: "Microsoft",
        0x009E: "Bose", 0x0075: "Samsung", 0x00E0: "Google", 0x0057: "Harman",
        0x0087: "Garmin", 0x0310: "SteelSeries", 0x1532: "Razer", 0x0002: "Intel",
        0x000A: "Qualcomm", 0x0499: "Ruuvi", 0x0006: "Microsoft",
    ]

    static func hexNumber(_ text: String) -> Int? {
        let digits = text.split(separator: " ").first.map(String.init) ?? text
        return Int(digits.replacingOccurrences(of: "0x", with: ""), radix: 16)
    }

    // MARK: USB

    /// Everything plugged in by cable, from the I/O registry. Hubs and the
    /// Mac's own built-in parts are left out: they are not things you plugged
    /// in.
    static func usb() -> [DeviceInfo] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"),
                                           &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var devices: [DeviceInfo] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var unmanaged: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let properties = unmanaged?.takeRetainedValue() as? [String: Any]
            else { continue }
            var entryID: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(service, &entryID)
            if let device = usbDevice(properties, entryID: entryID) { devices.append(device) }
        }
        return devices.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func usbDevice(_ properties: [String: Any], entryID: UInt64) -> DeviceInfo? {
        let deviceClass = properties["bDeviceClass"] as? Int ?? 0
        let builtIn = properties["Built-In"] as? Bool ?? false
        guard deviceClass != 9, !builtIn else { return nil }      // 9 is a hub

        let name = (properties["USB Product Name"] as? String)
            ?? (properties["kUSBProductString"] as? String) ?? "USB device"
        let maker = (properties["USB Vendor Name"] as? String) ?? (properties["kUSBVendorString"] as? String)
        var device = DeviceInfo(id: "usb-\(entryID)", name: name,
                                kind: usbKind(properties, name: name),
                                link: .usb, isConnected: true, maker: maker)

        var details: [(String, String)] = []
        if let speed = properties["Device Speed"] as? Int {
            let speeds = [0: "Low speed (1.5 Mbit/s)", 1: "Full speed (12 Mbit/s)",
                          2: "High speed (480 Mbit/s)", 3: "SuperSpeed (5 Gbit/s)",
                          4: "SuperSpeed+ (10 Gbit/s)", 5: "SuperSpeed+ (20 Gbit/s)"]
            if let text = speeds[speed] { details.append(("Speed", text)) }
        }
        if let serial = (properties["USB Serial Number"] as? String) ?? (properties["kUSBSerialNumberString"] as? String),
           !serial.isEmpty {
            details.append(("Serial number", serial))
        }
        if let vendor = properties["idVendor"] as? Int { details.append(("Vendor ID", String(format: "0x%04X", vendor))) }
        if let product = properties["idProduct"] as? Int { details.append(("Product ID", String(format: "0x%04X", product))) }
        if let version = properties["bcdDevice"] as? Int {
            details.append(("Version", String(format: "%X.%02X", version >> 8, version & 0xFF)))
        }
        device.details = details
        return device
    }

    private static func usbKind(_ properties: [String: Any], name: String) -> DeviceInfo.Kind {
        let lower = name.lowercased()
        if lower.contains("iphone") { return .phone }
        if lower.contains("ipad") { return .tablet }
        if lower.contains("keyboard") { return .keyboard }
        if lower.contains("mouse") { return .mouse }
        if lower.contains("drive") || lower.contains("disk") || lower.contains("ssd")
            || (properties["bDeviceClass"] as? Int) == 8 { return .storage }
        return .other
    }
}
