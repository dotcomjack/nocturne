import AppKit
import Combine
import ServiceManagement
import SwiftUI

/// Owns Nocturne's state and is the only thing that writes to the system.
///
/// Everything funnels through `apply()` so there is exactly one place where the
/// clock's on-screen state is decided.
@MainActor
final class NocturneController: ObservableObject {

    static let shared = NocturneController()

    /// Fires whenever `mode` changes so the menu bar glyph can follow it.
    ///
    /// A callback because the menu bar item is AppKit, not SwiftUI, so nothing
    /// re-renders it on its own. (`@AppStorage` inside an `ObservableObject`
    /// does publish, measured: the view body re-evaluates within 10ms of every
    /// write path. An earlier comment here claimed otherwise and was wrong.)
    var onModeChange: (() -> Void)?

    // MARK: - Persisted state

    @AppStorage("mode") var mode: ClockMode = .blind {
        didSet {
            guard mode != oldValue else { return }
            // Remember the last real mode wherever it was chosen, not just in
            // toggle(), so clicking the icon always returns to what you picked.
            if mode != .off { preferredMode = mode }
            apply()
            onModeChange?()
        }
    }

    @AppStorage("preferredMode") private var preferredMode: ClockMode = .blind

    @AppStorage("overlayFill") var overlayFill: OverlayController.Fill = .material {
        didSet { overlay.fill = overlayFill }
    }

    /// How often the menu bar icon sweeps. See `ShimmerCadence`.
    @AppStorage("shimmerCadence") var shimmerCadence: ShimmerCadence = .occasionally {
        didSet { guard shimmerCadence != oldValue else { return }; onShimmerChange?(shimmerCadence) }
    }

    /// Set by the app delegate so the menu bar item can follow the setting.
    var onShimmerChange: ((ShimmerCadence) -> Void)?

    // Clock Options passthrough. These mirror the System Settings pane, so a
    // user who only wants to lose the date never has to touch a mode.
    @AppStorage("showDayOfWeek") var showDayOfWeek = true {
        didSet { clockOptionChanged(.showDayOfWeek, showDayOfWeek) }
    }
    @AppStorage("showAMPM") var showAMPM = true {
        didSet { clockOptionChanged(.showAMPM, showAMPM) }
    }
    @AppStorage("showSeconds") var showSeconds = false {
        didSet { clockOptionChanged(.showSeconds, showSeconds) }
    }
    @AppStorage("dateVisibility") var dateVisibility: ClockDefaults.DateVisibility = .whenSpaceAllows {
        didSet { clockOptionChanged(.showDate, dateVisibility.rawValue) }
    }

    let overlay = OverlayController()

    /// Guards against a stale `waitForControlCenter` callback activating the
    /// overlay after the mode has already moved on.
    private var applyGeneration = 0

    /// True while we are pulling system values IN, so the `didSet`s do not push
    /// them straight back OUT again.
    ///
    /// The previous approach wrote the raw `UserDefaults` keys to dodge those
    /// `didSet`s. That silently failed for exactly the switches the user had
    /// already touched: `@AppStorage` caches a key in memory once it has been
    /// assigned through the wrapper, and stops reading through to
    /// `UserDefaults`. So the panel kept showing the old position, and the next
    /// click wrote a value the system already had and appeared to do nothing.
    private var isSyncing = false

    /// Coalesces Control Center restarts.
    ///
    /// It is a KeepAlive job with a one second throttle, so several kills in
    /// quick succession leave the menu bar empty for seconds. Flipping three
    /// Clock Options in a row used to do exactly that.
    private var pendingReload: DispatchWorkItem?

    private init() {
        Self.adoptSystemClockSettingsOnFirstRun()
        overlay.fill = overlayFill
    }

    // MARK: - First run

    /// On first run, take the user's existing Clock Options as our starting
    /// values instead of imposing our own.
    ///
    /// Without this, first launch silently overwrites whatever the user had set
    /// in System Settings with this file's hardcoded defaults. Measured on a
    /// real machine before the fix: a user with 24-hour time, no day of week and
    /// seconds showing had all three flipped (`ShowAMPM` 0 to 1,
    /// `ShowDayOfWeek` 0 to 1, `ShowSeconds` 1 to 0) the moment the app opened.
    ///
    /// Writes go straight to `UserDefaults` rather than through the `@AppStorage`
    /// properties on purpose: assigning to those fires their `didSet`, which
    /// would push our values back out to the system and reintroduce the very bug
    /// this is fixing.
    private static func adoptSystemClockSettingsOnFirstRun() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "hasAdoptedSystemClock") else { return }

        var current = ClockDefaults.snapshot()

        // If our own preferences were cleared while Nocturne had the clock
        // analog (a reinstall after `defaults delete`, a migrated account), the
        // analog state is ours, not the user's. Recording it as "original" would
        // make "Restore clock to how it was" restore to analog, permanently.
        current.isAnalog = false

        defaults.set(current.showDayOfWeek, forKey: "showDayOfWeek")
        defaults.set(current.showAMPM, forKey: "showAMPM")
        defaults.set(current.showSeconds, forKey: "showSeconds")
        defaults.set(current.showDate, forKey: "dateVisibility")

        if let encoded = try? JSONEncoder().encode(current) {
            defaults.set(encoded, forKey: "originalClock")
        }
        defaults.set(true, forKey: "hasAdoptedSystemClock")
    }

    /// The clock exactly as it was before Nocturne ever ran, if we captured it.
    private var originalClock: ClockDefaults.Snapshot? {
        guard let data = UserDefaults.standard.data(forKey: "originalClock") else { return nil }
        return try? JSONDecoder().decode(ClockDefaults.Snapshot.self, from: data)
    }

    // MARK: - Applying

    /// Brings the system in line with `mode`.
    ///
    /// Deliberately does **not** write Clock Options. Those are only written when
    /// the user moves one of our switches. Writing them here would silently
    /// revert any change the user made in System Settings, on every launch.
    func apply() {
        applyGeneration &+= 1
        let generation = applyGeneration

        let wantsAnalog = mode.wantsAnalogClock
        let alreadyCorrect = ClockDefaults.bool(.isAnalog, fallback: false) == wantsAnalog

        if !alreadyCorrect {
            ClockDefaults.set(.isAnalog, wantsAnalog)
            ControlCenter.reload()
        }

        guard mode.usesOverlay else {
            overlay.deactivate()
            return
        }

        overlay.coverage = (mode == .naked) ? .entireBar : .clock

        if alreadyCorrect {
            overlay.activate()
        } else {
            // The rect only exists once Control Center has drawn again, so wait
            // for it rather than placing the strip against stale geometry.
            waitForControlCenter { [weak self] in
                guard let self,
                      self.applyGeneration == generation,
                      self.mode.usesOverlay
                else { return }
                self.overlay.activate()
            }
        }
    }

    /// Writes ONE clock option, never all four.
    ///
    /// The old version pushed every key on any change, so flipping "Day of the
    /// week" also rewrote seconds, AM/PM and the date from our own cached
    /// copies. If the user had changed one of those in System Settings since we
    /// last looked, it was silently reverted. Measured: user turns Seconds on in
    /// System Settings, flips an unrelated Nocturne switch, seconds vanish.
    private func clockOptionChanged(_ key: ClockDefaults.Key, _ value: Bool) {
        guard !isSyncing else { return }
        ClockDefaults.set(key, value)
        finishClockOptionChange()
    }

    private func clockOptionChanged(_ key: ClockDefaults.Key, _ value: Int) {
        guard !isSyncing else { return }
        ClockDefaults.set(key, value)
        finishClockOptionChange()
    }

    private func finishClockOptionChange() {
        // Debounce so a run of switch flips costs one restart, not one each.
        pendingReload?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reloadAfterClockOptionChange() }
        pendingReload = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func reloadAfterClockOptionChange() {
        pendingReload = nil
        ControlCenter.reload()
        guard mode.usesOverlay else { return }

        applyGeneration &+= 1
        let generation = applyGeneration
        waitForControlCenter { [weak self] in
            guard let self,
                  self.applyGeneration == generation,
                  self.mode.usesOverlay
            else { return }
            self.overlay.activate()
        }
    }

    /// Pulls the live system values back into our own copies.
    ///
    /// Called whenever Settings is shown, so the panel never displays a stale
    /// picture of a clock the user has since changed in System Settings. Writes
    /// go straight to `UserDefaults` so the `didSet`s do not fire and push the
    /// values back out again.
    func resyncClockOptions() {
        let live = ClockDefaults.snapshot()
        isSyncing = true
        showDayOfWeek = live.showDayOfWeek
        showAMPM = live.showAMPM
        showSeconds = live.showSeconds
        dateVisibility = ClockDefaults.DateVisibility(rawValue: live.showDate) ?? .whenSpaceAllows
        isSyncing = false
    }

    /// Polls until Control Center's geometry has **settled**, then runs `body`.
    ///
    /// Waiting for "the clock is on screen" is not enough, and measuring showed
    /// why. Two things go wrong right after a Control Center restart:
    ///
    /// 1. The dying process's windows are still listed. At t=0.004s after the
    ///    kill, `rects()` returns the pre-restart rect, so a non-empty test
    ///    short-circuits instantly on stale geometry. The windows only actually
    ///    disappear around t=0.03s.
    /// 2. When Control Center comes back, around t=0.6s, its items animate in.
    ///    The clock was measured growing 36 to 38 to 40 to 42 to 44pt wide over
    ///    roughly a third of a second.
    ///
    /// Placing the strip against either one puts it over the wrong menu bar
    /// item until the next 2s poll corrects it. Measured misses of 11pt, 32pt
    /// and a 33pt width error, which is a different icon entirely.
    ///
    /// So require the same rect twice in a row before believing it.
    private func waitForControlCenter(timeout: TimeInterval = 6.0,
                                      then body: @escaping () -> Void) {
        let deadline = Date().addingTimeInterval(timeout)
        var previous: [CGRect]?

        func poll() {
            let current = ClockWindowLocator.rects()
            let settled = !current.isEmpty && current == previous
            previous = current

            if settled || Date() >= deadline {
                body()
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { poll() }
        }
        poll()
    }

    // MARK: - Restoring

    /// Undoes the one thing Nocturne does on its own: the analog swap.
    ///
    /// This always lands on a digital clock, and that is deliberate rather than
    /// an oversight. The snapshot forces `isAnalog` to false at capture time
    /// (see `adoptSystemClockSettingsOnFirstRun`), because our own preferences
    /// can be cleared while the clock is analog, and recording that as
    /// "original" would make Restore put the clock back to analog forever.
    ///
    /// The cost is real and worth stating: someone who deliberately ran the
    /// analog clock before installing Nocturne gets a digital one back.
    func restoreSystemClock() {
        overlay.deactivate()
        // Confirmed rather than fire-and-forget: this runs on the quit path,
        // where the process is about to exit and a lost write means the user is
        // left with an analog clock and no app to undo it.
        ClockDefaults.setAndConfirm(.isAnalog, originalClock?.isAnalog ?? false)
        ControlCenter.reload()
    }

    var canRestoreOriginalClock: Bool { originalClock != nil }

    /// Puts every clock setting back exactly as it was before Nocturne first ran.
    ///
    /// Our own storage is written directly rather than through the properties,
    /// because each `didSet` would otherwise trigger its own Control Center
    /// restart. Control Center is a KeepAlive job with a one second throttle, so
    /// six SIGKILLs in a row can leave the menu bar empty for several seconds.
    /// One restart, at the end.
    func restoreOriginalClock() {
        guard let original = originalClock else { return }

        // `mode` goes through the PROPERTY, never straight to UserDefaults.
        //
        // Writing the raw key leaves `@AppStorage`'s in-memory copy stale: disk
        // said "off" while `self.mode` still read "blind". The menu then refused
        // to re-select the mode you were just on, because `didSet`'s
        // `mode != oldValue` guard saw no change and never called `apply()`.
        // Reproduced: press Restore, then click Blind, and nothing happens.
        //
        // Going through the property also bumps `applyGeneration`, which
        // cancels any overlay callback still in flight from a mode change made
        // moments earlier. Pressing Restore mid-restart used to leave the
        // overlay up with the mode already off.
        // Write the analog key BEFORE flipping mode.
        //
        // `mode = .off` fires its didSet, which calls apply(), which restarts
        // Control Center whenever the clock is currently analog, which is every
        // Restore that has any work to do. Setting the key first means apply()
        // sees it already correct and skips that restart, so this function keeps
        // the single-restart promise its comment below makes. Control Center is
        // a KeepAlive job with a 1s throttle, so stacked kills are expensive.
        ClockDefaults.set(.isAnalog, original.isAnalog)

        mode = .off
        overlay.deactivate()

        // Assign through the properties, under the sync flag so none of them
        // fires its own Control Center restart.
        //
        // Writing the raw keys here instead looked equivalent and was not:
        // `@AppStorage` caches a key in memory once it has been assigned through
        // the wrapper, so a raw write is invisible to any switch the user had
        // already touched this session. Restore then moved the clock but not the
        // switch reporting it, and the next click on that switch wrote a value
        // the system already had and appeared to do nothing.
        isSyncing = true
        showDayOfWeek = original.showDayOfWeek
        showAMPM = original.showAMPM
        showSeconds = original.showSeconds
        dateVisibility = ClockDefaults.DateVisibility(rawValue: original.showDate) ?? .whenSpaceAllows
        isSyncing = false

        ClockDefaults.set(.isAnalog, original.isAnalog)
        ClockDefaults.set(.showDayOfWeek, original.showDayOfWeek)
        ClockDefaults.set(.showAMPM, original.showAMPM)
        ClockDefaults.set(.showSeconds, original.showSeconds)
        ClockDefaults.set(.showDate, original.showDate)
        ControlCenter.reload()

        objectWillChange.send()
        onModeChange?()
    }

    // MARK: - Convenience

    /// What clicking the menu bar icon cycles between: the mode you last chose,
    /// and off.
    func toggle() {
        mode = (mode == .off) ? preferredMode : .off
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
