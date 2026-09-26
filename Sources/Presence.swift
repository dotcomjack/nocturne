// █ dcj · dotcomjack.com · MIT
import AppKit

/// Whether anyone can currently see a screen.
///
/// Everything Nocturne does on a schedule, the placement tick, the hover
/// monitor and the icon shimmer, exists for a pair of eyes. With the displays
/// asleep or the session switched away there are none, and the work is pure
/// cost. That state is also where the hours are: a Mac on a charger with its
/// displays asleep is still an awake Mac, so its timers keep firing all night
/// for a menu bar nobody can see.
///
/// Deliberately **not** driven by the screen lock notifications. A missed
/// "unlocked" would leave everything paused with the menu bar in plain view,
/// which is the one failure worse than the cost it saves. Display sleep and
/// fast user switching arrive in reliable pairs, and a full system wake clears
/// the display flag as well, so nothing here can stick.
@MainActor
enum Presence {

    /// Posted on the default center when `isAway` flips.
    static let didChange = Notification.Name("com.dcj.nocturne.presenceDidChange")

    private(set) static var isAway = false

    private static var displaysAsleep = false
    private static var sessionInactive = false
    private static var isStarted = false

    static func start() {
        guard !isStarted else { return }
        isStarted = true

        observe(NSWorkspace.screensDidSleepNotification) { displaysAsleep = true }
        observe(NSWorkspace.screensDidWakeNotification) { displaysAsleep = false }
        observe(NSWorkspace.didWakeNotification) { displaysAsleep = false }
        observe(NSWorkspace.sessionDidResignActiveNotification) { sessionInactive = true }
        observe(NSWorkspace.sessionDidBecomeActiveNotification) { sessionInactive = false }
    }

    private static func observe(_ name: Notification.Name,
                                _ update: @escaping @Sendable @MainActor () -> Void) {
        NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil,
                                                          queue: .main) { _ in
            MainActor.assumeIsolated {
                update()
                let away = displaysAsleep || sessionInactive
                guard away != isAway else { return }
                isAway = away
                NotificationCenter.default.post(name: didChange, object: nil)
            }
        }
    }
}
