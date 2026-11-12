import AppKit

/// Gauge's entry point.
///
/// There is no window and no Dock icon: the whole app is a menu bar item plus
/// the panel it opens.  `.accessory` is what tells macOS that, and it has to be
/// set before the app finishes launching.
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let preferences = Preferences()
    private lazy var engine = MetricsEngine()
    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = StatusItemController(engine: engine, preferences: preferences)
        engine.setHistoryWindow(minutes: preferences.historyMinutes,
                                interval: preferences.refreshInterval)
        engine.start(interval: preferences.refreshInterval)
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine.stop()
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
