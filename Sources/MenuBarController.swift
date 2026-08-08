import AppKit

/// Nocturne's own menu bar item.
///
/// Left click opens the menu, which is what every other menu bar app on the
/// system does. An earlier version made left click a silent toggle and hid the
/// menu behind a right click; nobody found it, and an icon whose only affordance
/// is invisible may as well not be there.
@MainActor
final class MenuBarController: NSObject {

    private let statusItem: NSStatusItem
    private let controller = NocturneController.shared
    private let menu = NSMenu()

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        menu.delegate = self
        statusItem.menu = menu
        statusItem.button?.toolTip = "Nocturne"

        refreshIcon()
    }

    /// Where our own icon currently sits, in Cocoa screen coordinates.
    ///
    /// Read live rather than cached, because the menu bar reflows whenever an
    /// item appears or a display is attached.
    var statusItemFrame: CGRect? {
        statusItem.button?.window?.frame
    }

    // MARK: - Icon

    func refreshIcon() {
        guard let button = statusItem.button else { return }
        let mode = controller.mode

        let image = NSImage(systemSymbolName: mode.symbolName,
                            accessibilityDescription: "Nocturne, \(mode.title)")
        // Fall back to a symbol that has existed since Big Sur. A nil image here
        // would render an invisible menu bar item, which is worse than a plain
        // glyph on an older macOS.
            ?? NSImage(systemSymbolName: "clock", accessibilityDescription: "Nocturne")

        image?.isTemplate = true
        button.image = image
        button.toolTip = "Nocturne, \(mode.title)"
    }

    // MARK: - Menu

    private func rebuildMenu() {
        menu.removeAllItems()

        let header = NSMenuItem(title: "Menu bar clock", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        for mode in ClockMode.allCases {
            let item = NSMenuItem(title: mode.title,
                                  action: #selector(selectMode(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = mode
            item.state = (mode == controller.mode) ? .on : .off
            item.toolTip = mode.detail
            item.indentationLevel = 1
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings\u{2026}",
                                  action: #selector(openSettings),
                                  keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let quit = NSMenuItem(title: "Quit Nocturne",
                              action: #selector(quit),
                              keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    @objc private func selectMode(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? ClockMode else { return }
        controller.mode = mode
        refreshIcon()
    }

    @objc private func openSettings() {
        SettingsWindow.shared.show()
    }

    @objc private func quit() {
        // Leaving someone's clock analog after they quit the app that did it is
        // the kind of thing that gets a utility distrusted.
        controller.restoreSystemClock()
        NSApp.terminate(nil)
    }
}

extension MenuBarController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
    }
}
