import AppKit
import Darwin

/// The facts about a running program that only matter once you have singled it
/// out: where it came from, how long it has been there, and whose it is.
///
/// These are three more trips into the kernel, so they are asked for one
/// process at a time, when a row in the Apps tab is opened — never for the
/// whole list.
struct ProcessDetails {
    var path: String?
    var startedAt: Date?
    var uid: uid_t?
    /// The process that started this one. 1 is launchd, which starts
    /// everything that nothing else did.
    var parentPID: Int32?

    /// Whether this is one of your own programs. Anything else belongs to
    /// macOS or another account, and Gauge will not offer to quit it: the
    /// window server runs as its own user, and ending it logs you out.
    var isYours: Bool { uid == getuid() }

    var name: String? {
        path.map { URL(fileURLWithPath: $0).lastPathComponent }
    }

    /// The enclosing `.app`, when the executable is buried inside one, so that
    /// revealing it in the Finder lands on the program rather than three
    /// folders deep inside its bundle.
    var revealURL: URL? {
        guard let path else { return nil }
        var url = URL(fileURLWithPath: path)
        var enclosing: URL?
        while url.pathComponents.count > 1 {
            url = url.deletingLastPathComponent()
            if url.pathExtension == "app" { enclosing = url }
        }
        return enclosing ?? URL(fileURLWithPath: path)
    }
}

enum ProcessInspector {

    static func details(for pid: Int32) -> ProcessDetails {
        var details = ProcessDetails()
        details.path = executablePath(for: pid)
        if let info = kernelInfo(for: pid) {
            details.uid = info.kp_eproc.e_ucred.cr_uid
            details.parentPID = info.kp_eproc.e_ppid
            let started = info.kp_proc.p_un.__p_starttime
            details.startedAt = Date(timeIntervalSince1970: Double(started.tv_sec)
                                        + Double(started.tv_usec) / 1_000_000)
        }
        return details
    }

    private static func executablePath(for pid: Int32) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE, which Swift does not import.
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        let path = String(cString: buffer)
        return path.isEmpty ? nil : path
    }

    /// Owner and start time, asked of the kernel's process table.
    ///
    /// `proc_pidinfo` would be the obvious way and is the one Gauge tried
    /// first, but it answers only for processes belonging to you: every system
    /// process came back blank, so every row of theirs lost its owner and its
    /// start time. `sysctl` answers for all of them without any privilege.
    static func kernelInfo(for pid: Int32) -> kinfo_proc? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        let result = sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0)
        // A process that has gone answers successfully with nothing in it.
        guard result == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
        return info
    }
}

/// Which app a process belongs to, for the many that are not apps
/// themselves: Chrome runs a dozen "Google Chrome Helper"s, and a script run
/// from Terminal shows up under its own name.
struct ProcessOwner: Equatable {
    enum Relation: Equatable {
        /// The process is the app.
        case itself
        /// The process lives inside the app's bundle.
        case partOf
        /// The app started it, directly or through a shell.
        case startedBy
        /// It belongs to macOS itself and has no app.
        case macOS
    }

    let name: String
    let relation: Relation
    /// The app to bring forward. Nil for macOS.
    let bundleURL: URL?
    /// Whether the app has windows to show at all. Menu bar apps and
    /// background agents do not.
    let hasWindows: Bool
    /// Whether the app is running now. Showing never launches anything.
    let isRunning: Bool

    /// One line for the opened row: what this process is part of.
    var description: String {
        switch relation {
        case .itself:    return "itself"
        case .partOf:    return "part of \(name)"
        case .startedBy: return "started by \(name)"
        case .macOS:     return "part of macOS"
        }
    }

    /// Works out the owner, trying the most certain answer first: the process
    /// is a running app; it sits inside an app's bundle; an app started it.
    /// Failing all three, a program in a system folder is macOS's own.
    static func find(pid: Int32, details: ProcessDetails) -> ProcessOwner? {
        // Only an ordinary app counts as itself. Helpers register as apps too,
        // but with no windows, and the answer wanted for them is their app.
        if let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular,
           let url = app.bundleURL {
            return ProcessOwner(name: app.localizedName ?? url.deletingPathExtension().lastPathComponent,
                                relation: .itself, bundleURL: url, hasWindows: true, isRunning: true)
        }
        if let path = details.path, let bundle = outermostApp(in: path) {
            // A menu bar app's own program is the app, not a part of it.
            let isMain = Bundle(url: bundle)?.executableURL?.resolvingSymlinksInPath().path
                == URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            return owner(for: bundle, relation: isMain ? .itself : .partOf)
        }
        // Up through whoever started it, a few steps at most: a script's
        // parent is a shell, whose parent is Terminal.
        var parent = details.parentPID
        for _ in 0..<6 {
            guard let current = parent, current > 1 else { break }
            if let app = NSRunningApplication(processIdentifier: current),
               app.activationPolicy == .regular, let url = app.bundleURL {
                return ProcessOwner(name: app.localizedName ?? url.deletingPathExtension().lastPathComponent,
                                    relation: .startedBy, bundleURL: url,
                                    hasWindows: true, isRunning: true)
            }
            parent = ProcessInspector.kernelInfo(for: current)?.kp_eproc.e_ppid
        }
        if let path = details.path, isSystemPath(path) {
            return ProcessOwner(name: "macOS", relation: .macOS, bundleURL: nil,
                                hasWindows: false, isRunning: true)
        }
        return nil
    }

    /// The outermost `.app` a path is inside. Chrome's helpers are apps
    /// inside Chrome, and the answer wanted is Chrome.
    static func outermostApp(in path: String) -> URL? {
        let parts = URL(fileURLWithPath: path).pathComponents
        guard let index = parts.firstIndex(where: { $0.hasSuffix(".app") }) else { return nil }
        return URL(fileURLWithPath: NSString.path(withComponents: Array(parts[...index])))
    }

    static func isSystemPath(_ path: String) -> Bool {
        ["/System/", "/usr/", "/sbin/", "/bin/", "/Library/Apple/"].contains { path.hasPrefix($0) }
    }

    private static func owner(for bundleURL: URL, relation: Relation) -> ProcessOwner {
        let bundle = Bundle(url: bundleURL)
        let info = bundle?.infoDictionary ?? [:]
        let name = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String)
            ?? bundleURL.deletingPathExtension().lastPathComponent
        // Apps that declare themselves menu bar or background only never
        // have a window to bring forward.
        let hidden = (info["LSUIElement"] as? Bool) == true || (info["LSUIElement"] as? String) == "1"
            || (info["LSBackgroundOnly"] as? Bool) == true || (info["LSBackgroundOnly"] as? String) == "1"
        let running = bundle?.bundleIdentifier.map {
            !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty
        } ?? false
        return ProcessOwner(name: name, relation: relation, bundleURL: bundleURL,
                            hasWindows: !hidden, isRunning: running)
    }
}

/// Ending a program, politely where possible.
enum ProcessControl {

    /// Why a process could not be shown, in words for the panel. Nil when
    /// there is something to show.
    static func reasonCannotShow(_ owner: ProcessOwner?, processName: String) -> String? {
        guard let owner else {
            return "\(processName) runs in the background without a window, so there is "
                + "nothing to show. Reveal in Finder shows where it lives."
        }
        switch owner.relation {
        case .macOS:
            return "\(processName) is part of macOS and works in the background without a "
                + "window, so there is nothing to show."
        case .itself, .partOf, .startedBy:
            if !owner.hasWindows {
                return "\(owner.name) lives in the menu bar or runs in the background, so it "
                    + "has no window to bring forward."
            }
            if !owner.isRunning {
                return "\(owner.name) is not open; this part of it runs on its own in the "
                    + "background, so there is no window to show."
            }
            return nil
        }
    }

    /// Brings the program's app to the front, the way clicking it in the Dock
    /// does: hidden windows come back, and an app with every window closed
    /// opens a fresh one. Only ever an app that is already running; this
    /// never launches anything.
    static func show(_ owner: ProcessOwner) {
        guard let url = owner.bundleURL, owner.isRunning, owner.hasWindows else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    /// Asks a program to quit the way the Dock does, which gives it the chance
    /// to save and to put up a "do you want to save?" box. Only processes with
    /// a user interface can be asked this way; anything else gets the plain
    /// signal, which is the same thing `kill` sends by default.
    ///
    /// Returns false when macOS refused — almost always because the process
    /// belongs to someone else.
    @discardableResult
    static func quit(pid: Int32) -> Bool {
        if let app = NSRunningApplication(processIdentifier: pid) {
            return app.terminate()
        }
        return kill(pid, SIGTERM) == 0
    }

    static func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
