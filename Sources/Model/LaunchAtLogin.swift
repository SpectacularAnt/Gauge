import AppKit
import Foundation
import ServiceManagement

/// Asks macOS to start Gauge when you log in.
///
/// There is deliberately no stored setting behind this.  The real answer lives
/// with the system — the user can turn Gauge off in System Settings > General >
/// Login Items without telling the app — so the switch reads the system's
/// status every time rather than remembering what it was last told.
enum LaunchAtLogin {

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// True when the user has switched Gauge off in System Settings.  macOS
    /// will not let the app undo that on its own; the person has to do it.
    static var needsApprovalInSystemSettings: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    /// Turns the login item on or off.  Returns nil when it worked, or a
    /// sentence to show the user when it did not.
    static func setEnabled(_ enabled: Bool) -> String? {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            if needsApprovalInSystemSettings {
                return "macOS needs you to allow this in System Settings."
            }
            return "macOS refused: \(error.localizedDescription)"
        }
    }

    /// Opens the Login Items pane, for when macOS wants the user's say-so.
    static func openSystemSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")
        if let url {
            NSWorkspace.shared.open(url)
        }
    }

    /// macOS remembers the login item by the app's path. Inside iCloud Drive
    /// that is a shaky promise: moving the app, or letting iCloud evict it to
    /// save space, leaves the system pointing at a file that is not there.
    static var isInRiskyLocation: Bool {
        let path = Bundle.main.bundleURL.path
        return path.contains("/Library/Mobile Documents/")
            || path.contains("/Documents/")
            || path.contains("/Desktop/")
    }
}
