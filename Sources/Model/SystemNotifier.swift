import AppKit
import UserNotifications

/// Puts a message in Notification Centre.
///
/// Separated from `AlertWatcher`, which decides *whether* to say something,
/// so that the deciding can be tested without anything appearing on screen.
enum SystemNotifier {

    /// `UNUserNotificationCenter` requires a real app bundle and takes the
    /// process down rather than returning an error when there is not one. Test
    /// harnesses built from these sources are bare executables, so every entry
    /// point checks first.
    static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    /// Asks macOS for permission, which shows the system's own prompt the
    /// first time. Answers on the main thread.
    static func requestPermission(_ completion: @escaping (Bool) -> Void) {
        guard isAvailable else {
            completion(false)
            return
        }
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { granted, _ in
                DispatchQueue.main.async { completion(granted) }
            }
    }

    /// Whether macOS will currently let anything through.
    static func permissionGranted(_ completion: @escaping (Bool) -> Void) {
        guard isAvailable else {
            completion(false)
            return
        }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let allowed = settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional
            DispatchQueue.main.async { completion(allowed) }
        }
    }

    static func post(title: String, body: String) {
        guard isAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        // No trigger means deliver it now.
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content,
                                            trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// The Notifications pane of System Settings, for when macOS is the thing
    /// blocking them rather than Gauge.
    static func openSystemSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
        guard let url else { return }
        NSWorkspace.shared.open(url)
    }
}
