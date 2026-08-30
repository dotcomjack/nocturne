// █ dcj · dotcomjack.com · MIT
import Foundation

/// The Follow Focus state machine.
///
/// Deliberately a plain value type with no AppKit, no preferences and no clock,
/// because this is where the subtle bugs in the feature live and none of them
/// are reachable through the UI in a reasonable amount of time. Pulling it out
/// of `NocturneController` means `Tests/main.swift` can drive every ordering of
/// engage, release, retarget and abandon in a few microseconds.
///
/// The controller owns persistence: all three fields survive a quit, because
/// the app can be killed while a Focus is on and the user should still get
/// their own mode back afterwards.
///
/// Every method returns **the mode to switch to, or `nil` for leave it alone**.
/// Returning nil rather than the current mode matters: the controller's `mode`
/// setter can restart Control Center, and a redundant assignment would be a
/// visible menu bar blink for no reason.
struct FocusEngagement: Equatable {

    /// True while a Focus is currently driving the mode.
    var isEngaged = false

    /// The mode to come back to when the Focus ends. Nil when nothing is saved.
    var modeBefore: ClockMode?

    /// True when the user has explicitly opted out of the Focus that is
    /// *currently running*, by pressing "Restore clock to how it was".
    ///
    /// Without this, Restore is undone within 30 seconds and the user is never
    /// told why. `abandon()` clears `isEngaged`, but the Focus itself is still
    /// on, so the next backstop sweep reads the same live mode, sees nothing
    /// engaged, and treats a Focus that has been running for hours as a brand
    /// new activation. It re-hides the menu bar the user just un-hid. Sleeping
    /// or locking the screen brings it back even sooner, since those force a
    /// re-read.
    ///
    /// So the state machine has to remember that this particular Focus was
    /// offered and declined. The suppression is spent the moment the Focus
    /// genuinely ends, which is what `release` clears, so the *next* Focus
    /// engages normally.
    var isSuppressed = false

    /// The mode this engagement put on screen.
    ///
    /// Held here rather than read back from settings because the Focus filter's
    /// mode lives in System Settings, not in Nocturne, and the user can change
    /// it there while a Focus is running. `release` compares against this to
    /// decide whether the mode on screen is still ours to take back, so it has
    /// to be what we actually applied, not what is configured now.
    var target: ClockMode?

    /// A Focus started, or one was already running when we started looking.
    ///
    /// Idempotent, and it has to be. One continuous Focus can produce several
    /// engage calls: a wake from sleep, a relaunch, the backstop poll.
    /// Re-engaging would overwrite `modeBefore` with the Focus mode itself, and
    /// the user's own mode would be gone for good.
    mutating func engage(currentMode: ClockMode, target newTarget: ClockMode) -> ClockMode? {
        // The user turned this Focus's effect off by hand. Stay out of the way
        // until it actually ends.
        guard !isSuppressed else { return nil }
        guard !isEngaged else { return retarget(currentMode: currentMode, to: newTarget) }
        isEngaged = true
        modeBefore = currentMode
        target = newTarget
        return currentMode == newTarget ? nil : newTarget
    }

    /// The Focus ended.
    ///
    /// Only takes the mode back if it is still the one Focus put there. If the
    /// user picked something else while the Focus was on they have taken the
    /// wheel, and yanking it away the moment their Focus ends is the single
    /// most irritating thing an automation like this can do.
    mutating func release(currentMode: ClockMode) -> ClockMode? {
        // Cleared before the guard, not after. When the user has suppressed the
        // running Focus, `isEngaged` is already false, so a `guard` that
        // returned first would leave the suppression set forever and every
        // later Focus would be ignored.
        isSuppressed = false

        guard isEngaged else { return nil }
        isEngaged = false

        let previous = modeBefore
        let applied = target
        modeBefore = nil
        target = nil

        guard currentMode == applied, let previous, previous != currentMode else { return nil }
        return previous
    }

    /// The Focus is still on but now asks for a different mode.
    ///
    /// Happens when the filter is edited in System Settings mid-Focus, and also
    /// when one Focus hands straight over to another with a different mode set.
    ///
    /// Only moves the user if the mode on screen is still the one we applied.
    /// If they have changed it by hand, the new target is recorded so that
    /// `release` stays honest, but their choice is left alone.
    mutating func retarget(currentMode: ClockMode, to newTarget: ClockMode) -> ClockMode? {
        guard isEngaged else { return nil }
        let wasOurs = (currentMode == target)
        target = newTarget
        guard wasOurs, currentMode != newTarget else { return nil }
        return newTarget
    }

    /// Forget the session without touching the mode.
    ///
    /// For "Restore clock to how it was", which explicitly puts the clock back
    /// and makes any remembered pre-Focus mode meaningless. Without it, pressing
    /// Restore during a Focus and then letting that Focus end would put the
    /// clock straight back to what Restore was just used to get away from.
    mutating func abandon() {
        // Suppress only when a Focus is actually driving right now. Pressing
        // Restore with no Focus running must not deafen us to the next one.
        // Written as an OR rather than an assignment so that pressing Restore
        // twice during one Focus does not clear the suppression the first press
        // established.
        if isEngaged { isSuppressed = true }
        isEngaged = false
        modeBefore = nil
        target = nil
    }
}
