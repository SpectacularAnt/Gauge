import SwiftUI

/// Everything paired with or plugged into this Mac, connected ones first.
/// Clicking one opens its page.
struct DevicesTab: View {
    @ObservedObject var engine: MetricsEngine
    let onOpen: (String) -> Void

    var body: some View {
        VStack(spacing: 8) {
            if let devices = engine.devices {
                let connected = devices.filter(\.isConnected)
                let away = devices.filter { !$0.isConnected }
                if devices.isEmpty {
                    Card(title: "Devices") {
                        Text("No Bluetooth or USB devices found.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                if !connected.isEmpty {
                    Card(title: "Connected", subtitle: "\(connected.count)") {
                        rows(connected)
                    }
                }
                if !away.isEmpty {
                    Card(title: "Paired, not connected", subtitle: "\(away.count)") {
                        rows(away)
                    }
                }
            } else {
                Card(title: "Devices") {
                    Text("Looking for devices\u{2026}")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func rows(_ devices: [DeviceInfo]) -> some View {
        ForEach(Array(devices.enumerated()), id: \.element.id) { index, device in
            Button { onOpen(device.id) } label: {
                DeviceRow(device: device)
            }
            .buttonStyle(.plain)
            if index < devices.count - 1 { Divider() }
        }
    }
}

/// A device drawn like the rings at the top of the Overview: the ring is its
/// battery, and inside is what it is.
///
/// The ring's colour slides from green when full to yellow at half and red
/// when empty. Earbuds fill to whichever bud is lower, since that is the one
/// that runs out first. Something plugged in by cable shows a cable instead, and
/// anything not connected is drawn in grey, its ring at the last level macOS
/// heard. With no battery known the ring is left as an empty track rather
/// than drawn full, which would claim a reading there isn't.
struct DeviceRing: View {
    let device: DeviceInfo
    var diameter: CGFloat = 38
    var lineWidth: CGFloat = 4

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.1), lineWidth: lineWidth)
            if let level {
                Circle()
                    .trim(from: 0, to: max(0.001, min(Double(level) / 100, 1)))
                    .stroke(tint(level), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            Image(systemName: device.symbol)
                .font(.system(size: diameter * 0.38))
                .foregroundStyle(device.isConnected ? Color.accentColor : Color.secondary)
        }
        .frame(width: diameter, height: diameter)
        .padding(lineWidth / 2)
    }

    /// The level the ring shows: the only battery, or the lower earbud.
    private var level: Int? { device.headlineBattery }

    private func tint(_ percent: Int) -> Color {
        guard device.isConnected else { return Color.secondary.opacity(0.6) }
        return BatteryTint.color(percent)
    }
}

/// One device in the list: what it is, and its battery when that is known.
struct DeviceRow: View {
    let device: DeviceInfo

    var body: some View {
        HStack(spacing: 10) {
            DeviceRing(device: device)
            VStack(alignment: .leading, spacing: 1) {
                Text(device.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if !device.batteries.isEmpty {
                Text(batterySummary)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(device.isConnected ? Color.primary : Color.secondary)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        var parts = [device.kind.rawValue]
        if let maker = device.maker { parts.append(maker) }
        if device.link == .usb { parts.append("USB") }
        // A phone or watch in range but not connected is still worth saying.
        if !device.isConnected, device.signal != nil { parts.append("nearby") }
        return parts.joined(separator: " \u{00B7} ")
    }

    /// "85%", or "L 78%  R 77%  C 97%" for earbuds.
    private var batterySummary: String {
        if device.batteries.count == 1 { return "\(device.batteries[0].percent)%" }
        return device.batteries
            .map { "\($0.part.prefix(1)) \($0.percent)%" }
            .joined(separator: "  ")
    }
}

/// Everything known about one device, laid out like an Inspect page.
struct DevicePage: View {
    let device: DeviceInfo
    @ObservedObject var preferences: Preferences
    let onBack: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Text(device.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 70)
                HStack {
                    Button(action: onBack) {
                        HStack(spacing: 3) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 10, weight: .semibold))
                            Text("Devices")
                                .font(.system(size: 11))
                        }
                        .foregroundStyle(Color.accentColor)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
            }
            .padding(.vertical, 2)

            DeviceRing(device: device, diameter: 72, lineWidth: 7)
                .padding(.vertical, 4)

            // Only offered where there is a battery to show.
            if !device.batteries.isEmpty {
                Card(title: "Menu bar") {
                    Toggle(isOn: Binding(
                        get: { preferences.showsInMenuBar(device: device.id) },
                        set: { preferences.setInMenuBar(device: device.id, $0) }
                    )) {
                        Text("Show battery in the menu bar")
                            .font(.system(size: 11))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    if preferences.showsInMenuBar(device: device.id) {
                        whenControls
                    }
                    Text(device.batteries.count > 1
                         ? "Shows the lower earbud, and only while connected to this Mac."
                         : "Shown only while connected to this Mac.")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            ForEach(Array(DeviceFacts.groups(for: device).enumerated()), id: \.offset) { _, group in
                FactGroupCard(group: group)
            }
        }
    }

    /// Always, or only once the battery drops below a level of your choosing.
    @ViewBuilder private var whenControls: some View {
        let limit = preferences.menuBarDeviceLimits[device.id]
        HStack(spacing: 4) {
            choice("Always", selected: limit == nil) {
                preferences.menuBarDeviceLimits[device.id] = nil
            }
            choice("When low", selected: limit != nil) {
                if limit == nil {
                    preferences.menuBarDeviceLimits[device.id] = Preferences.defaultDeviceLimit
                }
            }
            Spacer()
        }
        if let limit {
            HStack {
                Text("Below")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Slider(value: Binding(
                    get: { Double(limit) },
                    set: { preferences.menuBarDeviceLimits[device.id] = Int($0.rounded()) }
                ), in: Preferences.deviceLimitRange, step: 5)
                    .controlSize(.mini)
                Text("\(limit)%")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .frame(width: 34, alignment: .trailing)
            }
        }
    }

    /// One of the two choices, drawn like the range buttons on the Overview.
    private func choice(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(selected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.05),
                            in: RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A battery's colour, sliding smoothly from green when full through yellow
/// at half to red when empty, so the colour alone says roughly how much is
/// left. Shared by the rings and the menu bar.
enum BatteryTint {
    /// Hue runs from 0 (red) through 1/6 (yellow) to 1/3 (green).
    static func nsColor(_ percent: Int) -> NSColor {
        let fraction = CGFloat(min(max(percent, 0), 100)) / 100
        return NSColor(hue: fraction / 3, saturation: 0.85, brightness: 0.92, alpha: 1)
    }

    static func color(_ percent: Int) -> Color {
        Color(nsColor: nsColor(percent))
    }
}

/// Turns what is known about a device into the blocks its page shows.
enum DeviceFacts {

    static func groups(for device: DeviceInfo) -> [FactGroup] {
        var groups: [FactGroup] = []

        if !device.batteries.isEmpty {
            let facts = device.batteries.map { battery in
                Fact(battery.part, "\(battery.percent)%" + (battery.isCharging ? ", charging" : ""),
                     fraction: Double(battery.percent) / 100,
                     tone: battery.percent <= 10 ? .critical : battery.percent <= 20 ? .warning : .normal,
                     isBattery: true)
            }
            groups.append(FactGroup(device.batteries.count == 1 ? "Battery" : "Batteries",
                                    footnote: device.isConnected || device.batteryIsLive ? nil
                                        : "As last reported, when it was connected to this Mac.",
                                    facts))
        }

        var connection = [
            Fact("Status", device.isConnected ? "Connected" : "Not connected",
                 tone: device.isConnected ? .good : .normal),
            Fact("Connects by", device.link.rawValue),
        ]
        if let signal = device.signal {
            connection.append(Fact("Signal", "\(DeviceInfo.describe(signal: signal))  (\(signal) dBm)"))
        }
        if let address = device.details.first(where: { $0.label == "Address" }) {
            connection.append(Fact("Address", address.value))
        }
        groups.append(FactGroup("Connection",
                                footnote: !device.isConnected && device.signal != nil
                                    ? "In range, but not connected to this Mac. Signal strength is "
                                      + "measured in dBm: the nearer zero, the closer it is."
                                    : nil,
                                connection))

        var about = [Fact("Kind", device.kind.rawValue)]
        if let maker = device.maker { about.append(Fact("Made by", maker)) }
        for detail in device.details where detail.label != "Address" {
            about.append(Fact(detail.label, detail.value))
        }
        groups.append(FactGroup("About", footnote: limitNote(for: device), about))
        return groups
    }

    /// Said plainly where macOS keeps most of a device to itself, so a short
    /// page does not look like Gauge missed something.
    static func limitNote(for device: DeviceInfo) -> String? {
        switch device.kind {
        case .phone, .tablet:
            return "macOS shares only a name and signal strength for an iPhone or iPad with "
                + "apps. Its battery, storage and the rest stay on the device."
        case .watch:
            return "An Apple Watch pairs with your iPhone rather than your Mac, so this Mac "
                + "knows little more than its name and how near it is."
        default:
            guard device.link == .bluetooth, device.batteries.isEmpty, device.isConnected else { return nil }
            return "This device does not share its battery level with macOS, or macOS does "
                + "not pass it on to apps, so there is none to show."
        }
    }
}
