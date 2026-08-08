import AppKit

@main
enum NocturneApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var menuBar: MenuBarController?
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBar = MenuBarController()
        installSignalHandlers()

        // Keep the glyph honest when the mode is changed from the Settings
        // window rather than the menu.
        NocturneController.shared.onModeChange = { [weak self] in
            self?.menuBar?.refreshIcon()
        }

        // Hide everything blanks the bar, and our icon is the only way back,
        // so it gets redrawn on top of the strip.
        NocturneController.shared.onShimmerChange = { [weak self] cadence in
            self?.menuBar?.applyShimmerCadence(cadence)
            // Show what the choice does the moment it is made.
            if cadence != .off { self?.menuBar?.previewShimmer() }
        }

        NocturneController.shared.overlay.beacon = { [weak self] in
            guard let frame = self?.menuBar?.statusItemFrame else { return nil }
            return (frame, NocturneController.shared.mode.symbolName)
        }

        // Re-assert the saved mode at launch. Control Center may have been
        // restarted, the user may have changed things in System Settings, or
        // this may be a fresh login. Whatever the reason, the state on screen
        // should match the state in the menu.
        NocturneController.shared.apply()
        menuBar?.refreshIcon()
    }

    func applicationWillTerminate(_ notification: Notification) {
        NocturneController.shared.restoreSystemClock()
    }

    /// Opening Nocturne again while it is already running shows Settings.
    ///
    /// It is an agent app with no Dock icon and no window, so double clicking it
    /// in Applications would otherwise appear to do nothing at all.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindow.shared.show()
        return true
    }

    /// Restore the clock on signals too, not just on a clean AppKit quit.
    ///
    /// `applicationWillTerminate` never runs for `pkill`, Activity Monitor's
    /// Quit, or a crash, and without this the clock stays analog with the app
    /// gone. That is the one failure mode that would genuinely earn a utility a
    /// bad reputation: the user cannot undo it without knowing the defaults key.
    ///
    /// `signal(_:SIG_IGN)` plus a `DispatchSource` is the safe pattern here.
    /// Calling AppKit from a raw C signal handler is not async-signal-safe;
    /// dispatch delivers the event on a normal queue instead.
    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                MainActor.assumeIsolated {
                    NocturneController.shared.restoreSystemClock()
                }
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}
