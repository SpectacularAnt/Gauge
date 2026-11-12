import AppKit
import SwiftUI
import Combine

/// Owns the menu bar item: what it says, and what happens when you click it.
///
/// It is the panel's delegate so that it hears about every close, including
/// the ones the panel decides on itself, and can fade each one out.
final class StatusItemController: NSObject, NSPopoverDelegate {

    private let item: NSStatusItem
    private let popover = NSPopover()
    private let engine: MetricsEngine
    private let preferences: Preferences
    private var observers: [AnyCancellable] = []
    /// Runs while the panel is fading out; nil the rest of the time.
    private var fadeTimer: Timer?

    init(engine: MetricsEngine, preferences: Preferences) {
        self.engine = engine
        self.preferences = preferences
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = item.button {
            button.target = self
            button.action = #selector(buttonClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        popover.behavior = .transient
        // The panel's own animation is off: it plays when opening too, and its
        // fade cuts out partway through. `fadeOut()` does the closing instead.
        popover.animates = false
        popover.delegate = self
        popover.contentViewController = NSHostingController(
            rootView: DetailPanel(engine: engine, preferences: preferences)
        )
        popover.contentSize = NSSize(width: 400, height: 600)

        // Redraw whenever a new reading arrives or a setting changes.
        engine.$snapshot
            .receive(on: RunLoop.main)
            .sink { [weak self] snapshot in self?.redraw(snapshot) }
            .store(in: &observers)

        engine.$devices
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.redraw(self.engine.snapshot)
            }
            .store(in: &observers)

        engine.$alertCount
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.redraw(self.engine.snapshot)
            }
            .store(in: &observers)

        preferences.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                // The alert count needs the per-app helpers running even with
                // the panel shut, so the engine has to know whether anyone is
                // still asking for it.
                self.engine.needsAlertCount = self.preferences.shows(.appAlerts)
                self.engine.needsDeviceBatteries = !self.preferences.menuBarDevices.isEmpty
                self.engine.alertLimits = self.preferences.alertLimits
                self.engine.setNotificationSettings(self.preferences.notificationSettings)
                self.redraw(self.engine.snapshot)
            }
            .store(in: &observers)

        engine.needsAlertCount = preferences.shows(.appAlerts)
        engine.needsDeviceBatteries = !preferences.menuBarDevices.isEmpty
        engine.alertLimits = preferences.alertLimits
        engine.setNotificationSettings(preferences.notificationSettings)
        // Picked up only after the settings above are applied: applying them
        // counts as a change and would otherwise wipe this memory at launch,
        // and every worn part would be announced again at each login.
        engine.watcher.healthSaid = preferences.healthAlertsSaid
        engine.watcher.healthSaidChanged = { [weak preferences] said in
            preferences?.healthAlertsSaid = said
        }

        redraw(engine.snapshot)
    }

    // MARK: - Drawing the bar

    private func redraw(_ snapshot: Snapshot) {
        guard let button = item.button else { return }

        // Each piece is a glyph, a short label and a value; which of the
        // first two is drawn depends on the style.
        let readouts = Metric.allCases
            .filter { preferences.shows($0) }
            .compactMap { metric -> (symbol: String, label: String, value: String, tint: NSColor?)? in
                guard let value = metric.value(from: snapshot,
                                               fahrenheit: preferences.useFahrenheit,
                                               alertCount: engine.alertCount)
                else { return nil }
                return (metric.symbolName, metric.shortLabel, value, nil)
            }
        // Device batteries chosen on their pages, after the readouts: only
        // while connected, and for "when low" devices only below their level.
        // Each is coloured by its level, green full to red empty.
        let batteries = preferences.menuBarDevices
            .compactMap { id in engine.devices?.first { $0.id == id } }
            .compactMap { device -> (symbol: String, label: String, value: String, tint: NSColor?)? in
                guard let level = device.menuBarLevel,
                      preferences.menuBarWants(device: device.id, level: level)
                else { return nil }
                return (device.symbol, device.menuBarLabel, "\(level)%", BatteryTint.nsColor(level))
            }
        let pieces = readouts + batteries

        // With nothing switched on, or nothing this Mac can report, fall back to
        // the app's own icon so the item stays visible and clickable.
        guard !pieces.isEmpty else {
            button.attributedTitle = NSAttributedString(string: "")
            button.image = NSImage(systemSymbolName: "gauge.with.dots.needle.67percent",
                                   accessibilityDescription: "Gauge")
            button.image?.isTemplate = true
            return
        }

        button.image = nil
        let style = preferences.menuBarStyle
        // Bare values are packed tighter, since that style exists to save room.
        let separator = style == .values ? " " : "  "

        let line = NSMutableAttributedString()
        for (index, piece) in pieces.enumerated() {
            if index > 0 {
                line.append(NSAttributedString(string: separator, attributes: Self.textAttributes))
            }
            switch style {
            case .icons:
                if let icon = Self.iconAttachment(named: piece.symbol, tint: piece.tint) {
                    line.append(icon)
                    line.append(NSAttributedString(string: "\u{2009}", attributes: Self.textAttributes))
                }
            case .labels:
                line.append(NSAttributedString(string: piece.label + " ",
                                               attributes: Self.labelAttributes))
            case .values:
                break
            }
            // Without a glyph to colour, the value itself carries the colour.
            var attributes = Self.textAttributes
            if style != .icons, let tint = piece.tint { attributes[.foregroundColor] = tint }
            line.append(NSAttributedString(string: piece.value, attributes: attributes))
        }
        button.attributedTitle = line
    }

    /// Digits are monospaced so the item stops jiggling as the numbers change.
    private static let textAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
    ]

    private static let labelAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold),
        .foregroundColor: NSColor.secondaryLabelColor,
    ]

    /// Wraps an SF Symbol in an attachment so it can sit inline with the text.
    private static func iconAttachment(named name: String, tint: NSColor? = nil) -> NSAttributedString? {
        var configuration = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        if let tint {
            configuration = configuration.applying(NSImage.SymbolConfiguration(paletteColors: [tint]))
        }
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration)
        else { return nil }
        // A plain glyph follows the menu bar's light or dark style; a coloured
        // one keeps its colour.
        image.isTemplate = tint == nil

        let attachment = NSTextAttachment()
        attachment.image = image
        // Nudged down so the glyph's centre lines up with the digits beside it.
        attachment.bounds = CGRect(x: 0, y: -2,
                                   width: image.size.width, height: image.size.height)
        return NSAttributedString(attachment: attachment)
    }

    // MARK: - Clicks

    @objc private func buttonClicked() {
        let isRightClick = NSApp.currentEvent?.type == .rightMouseUp
        if isRightClick {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        // Clicking again while it fades brings it straight back, so a quick
        // close-and-reopen is not left waiting for the fade.
        if fadeTimer != nil {
            cancelFade()
            return
        }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let button = item.button else { return }
        engine.isDetailVisible = true
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // Without this the popover opens behind whatever app is in front.
        popover.contentViewController?.view.window?.makeKey()
    }

    // MARK: - Closing

    /// Every close asks here first: clicking the item, clicking elsewhere, and
    /// pressing Escape. Each is turned down, and a fade is started that closes
    /// the panel when it finishes.
    func popoverShouldClose(_ popover: NSPopover) -> Bool {
        fadeOut()
        return false
    }

    /// Matched to the system's own menus, measured on this Mac: they fade over
    /// about a fifth of a second, most of the way in the first half.
    private static let fadeDuration: TimeInterval = 0.2

    /// Steps the panel's opacity down about sixty times a second, then closes
    /// it. AppKit's own animation for this occasionally skipped straight to
    /// the end; working each step out from the clock can't.
    private func fadeOut() {
        guard fadeTimer == nil else { return }
        guard let window = popover.contentViewController?.view.window else {
            popover.close()
            return
        }
        let start = Date()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            // How far through the fade we are, 0 to 1. Taken from the clock
            // rather than by counting steps, so a slow step can't stretch it.
            let progress = min(Date().timeIntervalSince(start) / Self.fadeDuration, 1)
            // Quick at first and gentle at the end, the curve the menus follow.
            let eased = 1 - (1 - progress) * (1 - progress)
            window.alphaValue = 1 - eased
            guard progress >= 1 else { return }
            self.stopFade()
            // `close()`, unlike `performClose`, doesn't ask the delegate again.
            self.popover.close()
            // Back to fully visible, ready for the next time it opens.
            window.alphaValue = 1
        }
        // The common modes keep it stepping even while a menu is open.
        RunLoop.main.add(timer, forMode: .common)
        fadeTimer = timer
    }

    private func stopFade() {
        fadeTimer?.invalidate()
        fadeTimer = nil
    }

    private func cancelFade() {
        stopFade()
        guard let window = popover.contentViewController?.view.window else { return }
        window.alphaValue = 1
        window.makeKey()
    }

    private func showContextMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Gauge", action: #selector(openFromMenu), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Gauge", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // Showing a menu this way pops it immediately and clears it afterwards,
        // so the item goes back to responding to ordinary clicks.
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    @objc private func openFromMenu() {
        togglePopover()
    }

    func popoverDidClose(_ notification: Notification) {
        engine.isDetailVisible = false
    }
}
