import AppKit
import Combine
import ServiceManagement
import SwiftUI

/// Owns Nocturne's state and is the only thing that writes to the system.
///
/// Everything funnels through `apply()` so there is exactly one place where the
/// clock's on-screen state is decided. Each `apply()` costs one Control Center
/// restart, which is why the writes are batched rather than fired per toggle.
@MainActor
final class NocturneController: ObservableObject {

    static let shared = NocturneController()

    // MARK: - Persisted state

    @AppStorage("mode") var mode: ClockMode = .blind {
        didSet { guard mode != oldValue else { return }; apply() }
    }

    @AppStorage("overlayFill") var overlayFill: OverlayController.Fill = .material {
        didSet { overlay.fill = overlayFill }
    }

    // Clock Options passthrough. These mirror the System Settings pane, so a
    // user who only wants to lose the date never has to touch a mode.
    @AppStorage("showDayOfWeek") var showDayOfWeek = true { didSet { applyClockOptions() } }
    @AppStorage("showAMPM")      var showAMPM      = true { didSet { applyClockOptions() } }
    @AppStorage("showSeconds")   var showSeconds   = false { didSet { applyClockOptions() } }
    @AppStorage("dateVisibility") var dateVisibility: ClockDefaults.DateVisibility = .whenSpaceAllows {
        didSet { applyClockOptions() }
    }

    let overlay = OverlayController()

    private init() {
        overlay.fill = overlayFill
    }

    // MARK: - Applying

    /// Brings the system in line with `mode`.
    func apply() {
        ClockDefaults.set(.isAnalog, mode != .off)
        writeClockOptions()
        ControlCenter.reload()

        if mode == .gone {
            // The rect only exists once Control Center has drawn again, so wait
            // for it rather than placing the strip against stale geometry.
            waitForControlCenter { [weak self] in self?.overlay.activate() }
        } else {
            overlay.deactivate()
        }
    }

    private func applyClockOptions() {
        writeClockOptions()
        ControlCenter.reload()
        if mode == .gone {
            waitForControlCenter { [weak self] in self?.overlay.activate() }
        }
    }

    private func writeClockOptions() {
        ClockDefaults.set(.showDayOfWeek, showDayOfWeek)
        ClockDefaults.set(.showAMPM, showAMPM)
        ClockDefaults.set(.showSeconds, showSeconds)
        ClockDefaults.set(.showDate, dateVisibility.rawValue)
    }

    /// Polls until Control Center has put the clock back on screen, then runs
    /// `body`. Gives up after a few seconds so a failure never wedges the app.
    private func waitForControlCenter(timeout: TimeInterval = 6.0,
                                      then body: @escaping () -> Void) {
        let deadline = Date().addingTimeInterval(timeout)

        func poll() {
            if !ClockWindowLocator.rects().isEmpty || Date() >= deadline {
                body()
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { poll() }
        }
        poll()
    }

    /// Puts the clock back the way macOS ships it. Called on quit so the app
    /// never leaves the menu bar in a state the user cannot undo without us.
    func restoreSystemClock() {
        overlay.deactivate()
        ClockDefaults.set(.isAnalog, false)
        ControlCenter.reload()
    }

    // MARK: - Convenience

    /// What the menu bar icon click cycles between: whatever mode the user last
    /// chose, and off. Toggling should never silently change their chosen mode.
    @AppStorage("preferredMode") private var preferredMode: ClockMode = .blind

    func toggle() {
        if mode == .off {
            mode = preferredMode
        } else {
            preferredMode = mode
            mode = .off
        }
    }

    // MARK: - Launch at login

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
                objectWillChange.send()
            } catch {
                NSLog("Nocturne: launch at login change failed: \(error.localizedDescription)")
            }
        }
    }
}
