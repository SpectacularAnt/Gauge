import Foundation

/// One network interface's counters: traffic, packets, errors, link speed.
///
/// Read through `sysctl` as a list of variable-length messages, one per
/// interface. The message has room for 64-bit counts, but macOS only fills it
/// in fully for its own tools: an ordinary app like Gauge gets the byte counts
/// cut down to 32 bits, so they wrap round to zero every 4 GB, and the
/// hardware address blanked to `02:00:00:00:00:00`. `netstat` holds a private
/// permission that sees the real figures, which is why `NetstatTotals` exists.
struct InterfaceCounters {
    let name: String
    let hardwareAddress: [UInt8]
    let isUp: Bool
    let mtu: UInt32
    /// Negotiated link speed in bits per second, 0 when there is no link.
    let baudRate: UInt64
    let bytesIn: UInt64
    let bytesOut: UInt64
    let packetsIn: UInt64
    let packetsOut: UInt64
    let errorsIn: UInt64
    let errorsOut: UInt64

    /// The real network interfaces only. Loopback traffic never leaves the
    /// machine, and the bridge and AirDrop interfaces carry copies of packets
    /// already counted on en0.
    var carriesRealTraffic: Bool {
        name.hasPrefix("en") || name.hasPrefix("ppp") || name.hasPrefix("ipsec")
    }

    static func readAll() -> [InterfaceCounters] {
        // NET_RT_IFLIST2: one RTM_IFINFO2 message per interface, each carrying
        // the 64-bit statistics and followed by the interface's link address.
        var request: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&request, UInt32(request.count), nil, &length, nil, 0) == 0, length > 0 else {
            return []
        }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&request, UInt32(request.count), &buffer, &length, nil, 0) == 0 else { return [] }

        var found: [InterfaceCounters] = []
        buffer.withUnsafeBytes { raw in
            var offset = 0
            let headerSize = MemoryLayout<if_msghdr>.size
            while offset + headerSize <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                let messageLength = Int(header.ifm_msglen)
                guard messageLength > 0 else { break }
                defer { offset += messageLength }

                guard Int32(header.ifm_type) == RTM_IFINFO2,
                      offset + MemoryLayout<if_msghdr2>.size <= length
                else { continue }
                let message = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)

                // The link address follows the message. Its name and hardware
                // address sit side by side in `sdl_data`, which begins eight
                // bytes in and runs on past the twelve bytes the struct declares.
                let link = offset + MemoryLayout<if_msghdr2>.size
                guard link + 8 <= length else { continue }
                let nameLength = Int(raw[link + 5])
                let addressLength = Int(raw[link + 6])
                guard link + 8 + nameLength + addressLength <= length else { continue }
                let nameBytes = (0..<nameLength).map { raw[link + 8 + $0] }
                let addressBytes = (0..<addressLength).map { raw[link + 8 + nameLength + $0] }

                let data = message.ifm_data
                found.append(InterfaceCounters(
                    name: String(decoding: nameBytes, as: UTF8.self),
                    hardwareAddress: addressBytes,
                    isUp: (message.ifm_flags & IFF_UP) != 0 && (message.ifm_flags & IFF_RUNNING) != 0,
                    mtu: data.ifi_mtu,
                    baudRate: data.ifi_baudrate,
                    bytesIn: data.ifi_ibytes,
                    bytesOut: data.ifi_obytes,
                    packetsIn: data.ifi_ipackets,
                    packetsOut: data.ifi_opackets,
                    errorsIn: data.ifi_ierrors,
                    errorsOut: data.ifi_oerrors))
            }
        }
        return found
    }
}

/// The true traffic totals, borrowed from `netstat`.
///
/// macOS lets `netstat` see the full 64-bit byte counts (it carries Apple's
/// private `network.statistics` permission); apps only get 32-bit counts that
/// wrap every 4 GB. So for the exact figures, Gauge asks `netstat` — about a
/// hundredth of a second's work. Hardware addresses are another matter: macOS
/// decides those by which app is ultimately asking, and run on Gauge's behalf
/// `netstat` gets the same blank `02:00:00:00:00:00` that Gauge would. A blank
/// is reported as no address rather than passed on as if it were real.
enum NetstatTotals {
    struct Entry {
        let bytesIn: UInt64
        let bytesOut: UInt64
        let hardwareAddress: String?
    }

    static func read() -> [String: Entry]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/netstat")
        process.arguments = ["-ibn"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8) else { return nil }
        return parse(text)
    }

    /// Each interface has one `<Link#n>` row carrying its totals, alongside
    /// rows for its addresses that repeat the same counts. The address column
    /// is empty for interfaces without one, so columns are counted from the
    /// right: …, Ibytes, Opkts, Oerrs, Obytes, Coll.
    static func parse(_ text: String) -> [String: Entry] {
        var entries: [String: Entry] = [:]
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 10, fields[2].hasPrefix("<Link#"),
                  let bytesIn = UInt64(fields[fields.count - 5]),
                  let bytesOut = UInt64(fields[fields.count - 2])
            else { continue }
            var address = fields.count >= 11 && fields[3].contains(":") ? String(fields[3]) : nil
            if address == "02:00:00:00:00:00" || address == "00:00:00:00:00:00" { address = nil }
            entries[String(fields[0])] = Entry(bytesIn: bytesIn, bytesOut: bytesOut,
                                               hardwareAddress: address)
        }
        return entries
    }
}

/// Measures network throughput by reading each interface's byte counters.
///
/// Rates come from the counters macOS hands to apps, read every tick. Those
/// wrap round every 4 GB, so a fall in a counter is checked: a fall from near
/// the top is the wrap, and the traffic is worked out across it; a fall from
/// anywhere else is the interface restarting its count. Totals since the Mac
/// started come from `netstat` instead, refreshed once a minute, with each
/// tick's traffic added on in between.
final class NetworkSampler {

    private var previousCounters: [String: (down: UInt64, up: UInt64)] = [:]
    private var previousTime: Date?
    private var totals: [String: (down: UInt64, up: UInt64)] = [:]
    private var totalsCheckedAt: Date?
    private var hardwareAddresses: [String: String] = [:]
    private static let netstatInterval: TimeInterval = 60

    /// Traffic between two readings of a counter that may have wrapped.
    static func traffic(from was: UInt64, to now: UInt64) -> UInt64 {
        if now >= was { return now - was }
        let wrapped = (UInt64(1) << 32) - was + now
        // Over a couple of seconds no link carries a gigabyte, so a wrap can
        // only explain a fall that started within that of the top.
        return wrapped < (UInt64(1) << 30) ? wrapped : now
    }

    func sample() -> NetworkReading {
        var reading = NetworkReading()

        var counters: [String: (down: UInt64, up: UInt64)] = [:]
        for interface in InterfaceCounters.readAll() where interface.carriesRealTraffic {
            counters[interface.name] = (down: interface.bytesIn, up: interface.bytesOut)
        }

        let now = Date()
        let elapsed = previousTime.map { now.timeIntervalSince($0) } ?? 0

        var rates: [InterfaceRate] = []
        for (name, current) in counters.sorted(by: { $0.key < $1.key }) {
            guard let was = previousCounters[name] else {
                totals[name] = totals[name] ?? current
                continue
            }
            let down = Self.traffic(from: was.down, to: current.down)
            let up = Self.traffic(from: was.up, to: current.up)
            let running = totals[name] ?? was
            totals[name] = (down: running.down &+ down, up: running.up &+ up)

            guard elapsed > 0.01 else { continue }
            let downRate = Double(down) / elapsed
            let upRate = Double(up) / elapsed
            reading.downRate += downRate
            reading.upRate += upRate
            if downRate > 128 || upRate > 128 {
                rates.append(InterfaceRate(name: name, downRate: downRate, upRate: upRate))
            }
        }

        // Once a minute, replace the running totals with the exact ones.
        if totalsCheckedAt.map({ now.timeIntervalSince($0) >= Self.netstatInterval }) ?? true {
            totalsCheckedAt = now
            if let exact = NetstatTotals.read() {
                for name in counters.keys {
                    if let entry = exact[name] { totals[name] = (down: entry.bytesIn, up: entry.bytesOut) }
                }
                hardwareAddresses = exact.compactMapValues(\.hardwareAddress)
            }
        }
        for name in counters.keys {
            reading.downTotal += totals[name]?.down ?? 0
            reading.upTotal += totals[name]?.up ?? 0
            if let total = totals[name] { reading.totalsByInterface[name] = total }
        }
        reading.hardwareAddresses = hardwareAddresses

        reading.interfaces = rates.sorted { ($0.downRate + $0.upRate) > ($1.downRate + $1.upRate) }
        previousCounters = counters
        previousTime = now
        return reading
    }
}
