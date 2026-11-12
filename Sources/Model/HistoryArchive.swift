import Foundation

/// One minute of history: the average of every reading taken during it.
struct ArchiveRow {
    let time: Date
    /// One value per `Series`, in `Series.allCases` order.
    let values: [Double]
}

/// Gauge's long memory: a month of readings kept on disk, one point a minute.
///
/// The live `Histories` only reach back as far as the trend length, half an
/// hour at most, and they vanish when Gauge quits. This is what answers "the
/// Mac was slow at four o'clock — what was it doing?" hours or days later.
///
/// A point a minute for thirty days is about 43,000 rows: a file of a couple of
/// megabytes that reads in a few milliseconds. That is small enough that older
/// readings never need thinning out, which keeps the whole thing simple —
/// every row means exactly the same as every other row.
///
/// The file is plain text, one row per line, so it can be read with `cat` or
/// opened in a spreadsheet without Gauge's help:
///
///     1761770400,0.0421,0.6633,0.0012,47.31,1024,1024,0,0,3.82
///
/// The first field is the minute, in seconds since 1970; the rest are the
/// series in a fixed order.
final class HistoryArchive {

    /// How far back the file is allowed to reach.
    static let retention: TimeInterval = 30 * 24 * 60 * 60

    /// Oldest first, exactly as they are stored.
    private(set) var rows: [ArchiveRow] = []

    private let fileURL: URL
    /// Writing happens off the main thread; it is once a minute, but a slow
    /// disk should never be able to stall the menu bar.
    private let queue = DispatchQueue(label: "local.gauge.archive", qos: .background)

    // The minute currently being averaged.
    private var bucketStart: Date?
    private var bucketSums: [Double] = []
    private var bucketCount = 0

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
        load()
    }

    /// `~/Library/Application Support/Gauge/history.csv`, the ordinary place
    /// for a Mac app's own data.
    static func defaultFileURL() -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support")
        let folder = base.appendingPathComponent("Gauge", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("history.csv")
    }

    var fileLocation: URL { fileURL }

    /// The oldest reading still on file, or nil when there is none yet.
    var earliest: Date? { rows.first?.time }

    // MARK: - Collecting

    /// Folds one reading into the minute being gathered, and writes that minute
    /// out once it is over.
    ///
    /// Returns true when a minute just completed, so the caller can tell the
    /// charts there is something new to draw.
    @discardableResult
    func record(_ snapshot: Snapshot) -> Bool {
        let minute = Self.startOfMinute(snapshot.takenAt)
        var completed = false

        if let start = bucketStart, start != minute {
            finishBucket(at: start)
            completed = true
        }
        if bucketStart != minute {
            bucketStart = minute
            bucketSums = Array(repeating: 0, count: Series.allCases.count)
            bucketCount = 0
        }

        let values = Self.values(from: snapshot)
        for index in values.indices {
            bucketSums[index] += values[index]
        }
        bucketCount += 1
        return completed
    }

    private func finishBucket(at start: Date) {
        guard bucketCount > 0 else { return }
        let averages = bucketSums.map { $0 / Double(bucketCount) }
        let row = ArchiveRow(time: start, values: averages)
        rows.append(row)
        dropExpired()
        append(row)
    }

    /// Readings in the order they are stored. Add a case to `Series` and a
    /// value here together, and nothing else needs to change.
    private static func values(from snapshot: Snapshot) -> [Double] {
        Series.allCases.map { series in
            let value: Double
            switch series {
            case .cpu:         value = snapshot.cpu.total
            case .memory:      value = snapshot.memory.usedFraction
            case .gpu:         value = snapshot.gpu.utilization ?? 0
            case .temperature: value = snapshot.temperatures.hottestDie ?? 0
            case .networkDown: value = snapshot.network.downRate
            case .networkUp:   value = snapshot.network.upRate
            case .diskRead:    value = snapshot.storage.readRate
            case .diskWrite:   value = snapshot.storage.writeRate
            case .power:       value = snapshot.power.watts ?? 0
            }
            return value.isFinite ? value : 0
        }
    }

    static func startOfMinute(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded(.down) * 60)
    }

    private func dropExpired() {
        let cutoff = Date().addingTimeInterval(-Self.retention)
        guard let first = rows.first, first.time < cutoff else { return }
        rows.removeAll { $0.time < cutoff }
        rewrite()
    }

    // MARK: - Reading it back

    /// The stored readings for one series, as a `History` the charts can draw.
    ///
    /// A week is 10,000 rows and a chart is 380 points wide, so the rows are
    /// grouped down to at most `maxPoints` averages. Brief spikes flatten out
    /// at that zoom — a ten-minute burst inside a half-hour group reads as a
    /// third of its real height — which is the usual trade for seeing a week at
    /// once, and why the live view stays untouched.
    func history(for series: Series, since cutoff: Date, maxPoints: Int = 360) -> History {
        guard let index = Series.allCases.firstIndex(of: series) else { return History() }
        let start = firstRowIndex(atOrAfter: cutoff)
        guard start < rows.count else { return History(values: [], times: []) }

        let wanted = rows[start...]
        let groupSize = max(Int((Double(wanted.count) / Double(max(maxPoints, 1))).rounded(.up)), 1)

        var values: [Double] = []
        var times: [Date] = []
        values.reserveCapacity(wanted.count / groupSize + 1)
        times.reserveCapacity(wanted.count / groupSize + 1)

        var groupTotal = 0.0
        var groupCount = 0
        var groupTime = wanted.first?.time ?? cutoff
        for row in wanted {
            if groupCount == 0 { groupTime = row.time }
            groupTotal += row.values[index]
            groupCount += 1
            if groupCount == groupSize {
                values.append(groupTotal / Double(groupCount))
                times.append(groupTime)
                groupTotal = 0
                groupCount = 0
            }
        }
        // Whatever is left over is a real, if shorter, final group.
        if groupCount > 0 {
            values.append(groupTotal / Double(groupCount))
            times.append(groupTime)
        }
        return History(values: values, times: times)
    }

    /// Rows are kept in time order, so the start of a range is a binary search
    /// rather than a walk from the beginning of the month.
    private func firstRowIndex(atOrAfter time: Date) -> Int {
        var low = 0
        var high = rows.count
        while low < high {
            let middle = (low + high) / 2
            if rows[middle].time < time {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low
    }

    // MARK: - The file

    private func load() {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        let expected = Series.allCases.count
        let cutoff = Date().addingTimeInterval(-Self.retention)
        var loaded: [ArchiveRow] = []

        for line in text.split(separator: "\n") {
            let fields = line.split(separator: ",")
            guard fields.count == expected + 1,
                  let seconds = Double(fields[0])
            else { continue }
            let time = Date(timeIntervalSince1970: seconds)
            guard time >= cutoff else { continue }
            let values = fields.dropFirst().map { Double($0) ?? 0 }
            loaded.append(ArchiveRow(time: time, values: values))
        }
        // A file written by hand, or two copies of Gauge running at once, could
        // leave these out of order; the binary search above depends on them not
        // being.
        loaded.sort { $0.time < $1.time }
        rows = loaded

        // Rewrite only when something was actually left out, so an ordinary
        // launch does not touch the file at all.
        let onFile = text.split(separator: "\n").count
        if loaded.count != onFile { rewrite() }
    }

    private static func line(for row: ArchiveRow) -> String {
        let seconds = Int(row.time.timeIntervalSince1970)
        let values = row.values.map { String(format: "%.4g", $0) }.joined(separator: ",")
        return "\(seconds),\(values)\n"
    }

    private func append(_ row: ArchiveRow) {
        let text = Self.line(for: row)
        queue.async { [fileURL] in
            guard let data = text.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: fileURL)
            }
        }
    }

    private func rewrite() {
        let text = rows.map(Self.line(for:)).joined()
        queue.async { [fileURL] in
            try? text.data(using: .utf8)?.write(to: fileURL)
        }
    }

    /// Forgets everything, on disk as well as in memory.
    func erase() {
        rows = []
        bucketStart = nil
        bucketCount = 0
        queue.async { [fileURL] in
            try? FileManager.default.removeItem(at: fileURL)
        }
    }
}
