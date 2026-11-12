import AppKit

/// Finds and installs newer versions of Gauge from its GitHub releases.
///
/// The repository is private, so GitHub only answers someone signed in. Rather
/// than keep a password or token of its own, Gauge asks the GitHub command-line
/// tool, `gh`, which is already signed in on this Mac and keeps its token in
/// the keychain. Each release carries a `Gauge.zip` made by `release.sh`.
///
/// Installing never happens without a click, and never touches the running
/// copy directly: the new app is downloaded and checked first, then a small
/// script waits for Gauge to quit, swaps the apps, and opens the new one. If
/// the swap fails, the old copy is put back.
final class Updater: ObservableObject {

    enum State: Equatable {
        case idle
        case checking
        case upToDate(String)
        case available(version: String, tag: String)
        case installing
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    /// One for the whole app, so an install keeps going, and still quits and
    /// relaunches Gauge, if Settings is closed partway through.
    static let shared = Updater()

    static let repository = "SpectacularAnt/Gauge"
    /// The file each release carries.
    static let assetName = "Gauge.zip"

    /// The version of the copy that is running, from its Info.plist.
    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    private let queue = DispatchQueue(label: "local.gauge.updater", qos: .utility)

    // MARK: Checking

    func check() {
        guard state != .checking, state != .installing else { return }
        state = .checking
        let current = currentVersion
        queue.async { [weak self] in
            let result = Self.latestRelease()
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .failure(let problem):
                    self.state = .failed(problem.message)
                case .success(let release):
                    if Self.compare(release.version, current) == .orderedDescending {
                        self.state = .available(version: release.version, tag: release.tag)
                    } else {
                        self.state = .upToDate(current)
                    }
                }
            }
        }
    }

    struct Release: Equatable {
        let tag: String
        let version: String
        let hasAsset: Bool
    }

    struct Problem: Error, Equatable {
        let message: String
    }

    /// The newest release, according to GitHub.
    static func latestRelease() -> Result<Release, Problem> {
        let run = gh(["release", "view", "--repo", repository, "--json", "tagName,assets"])
        switch run {
        case .failure(let problem): return .failure(problem)
        case .success(let output): return parseRelease(output)
        }
    }

    static func parseRelease(_ output: Data) -> Result<Release, Problem> {
        guard let json = try? JSONSerialization.jsonObject(with: output) as? [String: Any],
              let tag = json["tagName"] as? String
        else { return .failure(Problem(message: "GitHub's answer could not be read.")) }
        let assets = json["assets"] as? [[String: Any]] ?? []
        let hasAsset = assets.contains { $0["name"] as? String == assetName }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard hasAsset else {
            return .failure(Problem(message: "The newest release, \(tag), has no \(assetName) to install."))
        }
        return .success(Release(tag: tag, version: version, hasAsset: hasAsset))
    }

    /// Compares dotted version numbers piece by piece, so 1.10 is newer than
    /// 1.9 and 1.2 equals 1.2.0.
    static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let left = a.split(separator: ".").map { Int($0) ?? 0 }
        let right = b.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(left.count, right.count) {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    // MARK: Installing

    /// Downloads the release, checks it is really Gauge and properly signed,
    /// then hands over to the swap script and quits.
    func install(tag: String, version: String) {
        guard state != .installing else { return }
        state = .installing
        let destination = Bundle.main.bundleURL
        queue.async { [weak self] in
            let result = Self.prepare(tag: tag, version: version)
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .failure(let problem):
                    self.state = .failed(problem.message)
                case .success(let newApp):
                    do {
                        try Self.startSwap(newApp: newApp, replacing: destination,
                                           waitingFor: ProcessInfo.processInfo.processIdentifier)
                        NSApplication.shared.terminate(nil)
                    } catch {
                        self.state = .failed("The update could not be started.")
                    }
                }
            }
        }
    }

    /// Downloads and unpacks the release into a fresh temporary folder and
    /// returns the Gauge.app inside, once it has passed every check.
    static func prepare(tag: String, version: String) -> Result<URL, Problem> {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("gauge-update-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            return .failure(Problem(message: "There was nowhere to download the update to."))
        }
        let download = gh(["release", "download", tag, "--repo", repository,
                           "--pattern", assetName, "--dir", folder.path])
        if case .failure(let problem) = download { return .failure(problem) }

        let zip = folder.appendingPathComponent(assetName)
        let unpacked = folder.appendingPathComponent("unpacked")
        guard run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path]).status == 0 else {
            return .failure(Problem(message: "The download could not be unpacked."))
        }
        let app = unpacked.appendingPathComponent("Gauge.app")
        return verify(app, expectedVersion: version).map { app }
    }

    /// The checks a downloaded app must pass before it may replace the
    /// running one: it is Gauge, it is the version promised, and its
    /// signature is intact, so nothing was damaged or swapped on the way.
    static func verify(_ app: URL, expectedVersion: String) -> Result<Void, Problem> {
        guard let bundle = Bundle(url: app), bundle.bundleIdentifier == "local.gauge" else {
            return .failure(Problem(message: "The download is not Gauge."))
        }
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        guard version == expectedVersion else {
            return .failure(Problem(message: "The download says it is version \(version ?? "unknown"), "
                                    + "not \(expectedVersion)."))
        }
        guard run("/usr/bin/codesign", ["--verify", "--deep", app.path]).status == 0 else {
            return .failure(Problem(message: "The download's signature does not check out."))
        }
        return .success(())
    }

    /// Starts the script that finishes the job after Gauge quits. It keeps a
    /// copy of the old app until the new one is in place, and puts it back if
    /// anything goes wrong, so a failed update leaves Gauge as it was.
    /// `reopen` is only ever false in tests, which swap a copy in a
    /// temporary folder and must not launch it.
    static func startSwap(newApp: URL, replacing destination: URL, waitingFor pid: Int32,
                          reopen: Bool = true) throws {
        let script = """
            while kill -0 "$3" 2>/dev/null; do sleep 0.2; done
            old="$2.previous"
            rm -rf "$old"
            if mv "$2" "$old" && ditto --noextattr --norsrc "$1" "$2"; then
              rm -rf "$old"
            else
              rm -rf "$2"
              mv "$old" "$2"
            fi
            [ "$4" = "reopen" ] && open "$2"
            rm -rf "$(dirname "$(dirname "$1")")"
            """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "gauge-update", newApp.path, destination.path, String(pid),
                             reopen ? "reopen" : "stay"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    // MARK: Running other programs

    /// Where `gh` usually lives. Apps opened from the Finder do not get the
    /// Terminal's search path, so each is tried in turn.
    static func findGH() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.local/bin/gh", "/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func gh(_ arguments: [String]) -> Result<Data, Problem> {
        guard let path = findGH() else {
            return .failure(Problem(message: "Checking for updates needs the GitHub command-line "
                                    + "tool, gh, installed and signed in."))
        }
        let result = run(path, arguments)
        guard result.status == 0 else {
            let said = String(data: result.errors, encoding: .utf8)?.lowercased() ?? ""
            if said.contains("release not found") {
                return .failure(Problem(message: "No versions of Gauge have been published yet."))
            }
            if said.contains("auth") || said.contains("login") {
                return .failure(Problem(message: "gh is not signed in to GitHub. Run "
                                        + "\u{201C}gh auth login\u{201D} in Terminal, then try again."))
            }
            if said.contains("could not resolve") || said.contains("connect") || said.contains("network") {
                return .failure(Problem(message: "GitHub could not be reached. Check the internet "
                                        + "connection and try again."))
            }
            return .failure(Problem(message: "GitHub did not answer as expected."))
        }
        return .success(result.output)
    }

    /// Runs a program and collects what it prints. Only ever called on the
    /// updater's own queue, never while the panel is being drawn.
    @discardableResult
    static func run(_ path: String, _ arguments: [String]) -> (status: Int32, output: Data, errors: Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        do { try process.run() } catch { return (-1, Data(), Data()) }
        // Read both before waiting, so a chatty program cannot fill a pipe
        // and stall.
        var errorData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            errorData = errors.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        return (process.terminationStatus, outputData, errorData)
    }
}
