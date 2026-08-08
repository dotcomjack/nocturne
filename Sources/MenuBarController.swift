import AppKit

/// Nocturne's own menu bar item.
///
/// Left click toggles between off and the last chosen mode, because the common
/// case at 2am is "kill it now" and that should not cost a menu. Right click, or
/// holding the button, opens the menu with the modes and settings in it.
@MainActor
final class MenuBarController: NSObject {

    private let statusItem: NSStatusItem
    private let controller = NocturneController.shared
    private let menu = NSMenu()

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        statusItem.button?.target = self
        statusItem.button?.action = #selector(buttonClicked(_:))
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        menu.delegate = self
        refreshIcon()
    }

    // MARK: - Icon

    func refreshIcon() {
        guard let button = statusItem.button else { return }
        let mode = controller.mode
        button.image = NSImage(systemSymbolName: mode.symbolName,
                               accessibilityDescription: "Nocturne: \(mode.title)")
        button.image?.isTemplate = true
        button.toolTip = "Nocturne \u{2014} \(mode.title)"
    }

    // MARK: - Interaction

    @objc private func buttonClicked(_ sender: NSStatusBarButton) {
        let isRightClick = NSApp.currentEvent?.type == .rightMouseUp

        if isRightClick {
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            controller.toggle()
            refreshIcon()
        }
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        for mode in ClockMode.allCases {
            let item = NSMenuItem(title: mode.title,
                                  action: #selector(selectMode(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = mode
            item.state = (mode == controller.mode) ? .on : .off
            if mode == .gone { item.toolTip = mode.detail }
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
        // Leaving someone's clock analog after they uninstalled the app that did
        // it is the kind of thing that gets a utility distrusted.
        controller.restoreSystemClock()
        NSApp.terminate(nil)
    }
}

extension MenuBarController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
    }
}
