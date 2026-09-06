// █ dcj · dotcomjack.com · MIT
//
// Logic tests for Follow Focus.
//
// Run with:  ./Tests/run.sh
//
// Named `main.swift` because Swift only allows top-level statements in a file
// with that name.
//
// What is and is not covered, stated plainly rather than implied:
//
// - `FocusEngagement` is covered exhaustively, including a fuzz pass. It is the
//   whole decision-making half of the feature and none of its interesting
//   orderings (engage twice, release after the user takes over, retarget
//   mid-Focus, quit and relaunch) are reachable by hand in useful time.
// - `ClockMode` is pinned: what each mode asks of the clock and of the overlay
//   is asserted per mode, so a new case cannot inherit the wrong answer from a
//   default branch.
// - `MenuBarGeometry` is covered, including a fuzz pass. It is the arithmetic
//   behind Only the clock, and the one property that matters, that the strip
//   never reaches the clock, is cheap to prove and expensive to eyeball.
// - `NocturneFocusFilter` is NOT unit tested and cannot usefully be. Its
//   behaviour is entirely "what does macOS pass to `perform()`", which is a
//   property of the system, not of this code. It was established by measurement
//   instead, on a real Do Not Disturb toggle, and the measurements are recorded
//   in that file's doc comment.
//
// The mutation testing that this suite was built against lives in the release
// notes for 1.3.0: ten deliberate defects, each one caught.
import Foundation

// MARK: - Tiny harness

final class Harness {
    private var passed = 0
    private var failed: [String] = []

    func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
        if condition {
            passed += 1
        } else {
            let extra = detail()
            failed.append(extra.isEmpty ? name : "\(name)  [\(extra)]")
            print("FAIL  \(name)\(extra.isEmpty ? "" : "  [\(extra)]")")
        }
    }

    func equal<T: Equatable>(_ name: String, _ lhs: T, _ rhs: T) {
        check(name, lhs == rhs, "got \(lhs), want \(rhs)")
    }

    func finish() -> Never {
        print("")
        print("\(passed) passed, \(failed.count) failed, \(passed + failed.count) total")
        if failed.isEmpty {
            print("PROVEN  all Follow Focus checks green")
            exit(0)
        }
        print("NOT PROVEN  \(failed.count) failing:")
        failed.forEach { print("  - \($0)") }
        exit(1)
    }
}

let t = Harness()

// MARK: - 1. The modes a Focus may select

print("== modes ==")

t.equal("Focus can select four modes", ClockMode.focusTargets.count, 4)
t.check("Focus can never select Clock visible", !ClockMode.focusTargets.contains(.off))
t.check("every non-off mode is selectable",
        Set(ClockMode.focusTargets) == Set([.blind, .gone, .naked, .clockOnly]))

// What each mode asks of the system, stated once per mode. A `default:` branch
// in the app would let a new case inherit the wrong answer silently; the
// switches there are exhaustive and these pin the answers.
t.check("Clock visible touches nothing",
        !ClockMode.off.wantsAnalogClock && ClockMode.off.coverage == nil)
t.check("Blind is the analog swap and nothing else",
        ClockMode.blind.wantsAnalogClock && ClockMode.blind.coverage == nil)
t.check("Gone shrinks the clock, then covers it",
        ClockMode.gone.wantsAnalogClock && ClockMode.gone.coverage == .clock)
t.check("Hide everything shrinks the clock, then covers the bar",
        ClockMode.naked.wantsAnalogClock && ClockMode.naked.coverage == .entireBar)
t.check("Only the clock leaves the clock digital", !ClockMode.clockOnly.wantsAnalogClock)
t.check("Only the clock covers the bar and stops at the clock",
        ClockMode.clockOnly.coverage == .barExceptClock)
t.check("usesOverlay means exactly 'has something to cover'",
        ClockMode.allCases.allSatisfy { $0.usesOverlay == ($0.coverage != nil) })
t.check("the two modes that blank the bar are the two that draw a beacon",
        ClockMode.allCases.filter { $0.coverage?.blanksBar == true } == [.naked, .clockOnly])
t.check("only the two partial covers admit to a seam",
        ClockMode.allCases.filter(\.hasSeam) == [.gone, .clockOnly])
t.equal("every mode has its own glyph",
        Set(ClockMode.allCases.map(\.symbolName)).count, ClockMode.allCases.count)
t.equal("every mode has its own title",
        Set(ClockMode.allCases.map(\.title)).count, ClockMode.allCases.count)
t.check("every mode survives a round trip through its stored form",
        ClockMode.allCases.allSatisfy { ClockMode(rawValue: $0.rawValue) == $0 })

// MARK: - 2. The straight line

print("== engage and release ==")

do {
    var e = FocusEngagement()
    t.equal("engage from Blind to Hide everything switches", e.engage(currentMode: .blind, target: .naked), .naked)
    t.check("engaged", e.isEngaged)
    t.equal("remembers Blind", e.modeBefore, .blind)
    t.equal("records what it applied", e.target, .naked)
    t.equal("release returns to Blind", e.release(currentMode: .naked), .blind)
    t.check("released", !e.isEngaged)
    t.check("forgets the saved mode", e.modeBefore == nil)
    t.check("forgets the target", e.target == nil)
}

do {
    var e = FocusEngagement()
    t.check("release without engage is a no-op", e.release(currentMode: .blind) == nil)
    t.check("release without engage does not mark engaged", !e.isEngaged)
}

do {
    var e = FocusEngagement()
    // Already sitting in the target when the Focus starts.
    t.check("engage when already in the target changes nothing", e.engage(currentMode: .naked, target: .naked) == nil)
    t.check("but it IS engaged", e.isEngaged)
    t.equal("and remembers the target as the mode to return to", e.modeBefore, .naked)
    t.check("release is then a no-op too", e.release(currentMode: .naked) == nil)
}

// MARK: - 3. Idempotence
//
// The 30 second sweep calls this unconditionally, and so do wake and unlock, so
// a single continuous Focus produces a long run of identical engage calls.

print("== idempotence ==")

do {
    var e = FocusEngagement()
    _ = e.engage(currentMode: .blind, target: .naked)
    t.check("second engage with the same target is a no-op", e.engage(currentMode: .naked, target: .naked) == nil)
    t.equal("second engage does not clobber the saved mode", e.modeBefore, .blind)

    for _ in 0..<200 { _ = e.engage(currentMode: .naked, target: .naked) }
    t.equal("200 sweeps do not clobber the saved mode", e.modeBefore, .blind)
    t.equal("release still returns Blind", e.release(currentMode: .naked), .blind)
}

do {
    var e = FocusEngagement()
    _ = e.engage(currentMode: .blind, target: .naked)
    for _ in 0..<50 { _ = e.release(currentMode: .blind) }
    t.check("repeated release stays released", !e.isEngaged)
    t.check("repeated release leaves nothing saved", e.modeBefore == nil && e.target == nil)
}

// MARK: - 4. The user taking the wheel

print("== the user takes over ==")

do {
    var e = FocusEngagement()
    _ = e.engage(currentMode: .blind, target: .naked)
    // The user picks Gone by hand while the Focus is running.
    t.check("release leaves a hand-picked mode alone", e.release(currentMode: .gone) == nil)
    t.check("but the session is still closed", !e.isEngaged)
    t.check("and the saved mode is dropped", e.modeBefore == nil)
}

do {
    var e = FocusEngagement()
    _ = e.engage(currentMode: .blind, target: .naked)
    // User turns Nocturne off entirely from the menu bar icon mid-Focus.
    t.check("release after the user chose Clock visible leaves it alone",
            e.release(currentMode: .off) == nil)
}

do {
    var e = FocusEngagement()
    _ = e.engage(currentMode: .blind, target: .naked)
    // User takes over, THEN the filter is retargeted in System Settings.
    t.check("retarget does not move a user who has taken over",
            e.retarget(currentMode: .gone, to: .blind) == nil)
    t.equal("but the new target is recorded", e.target, .blind)
    t.check("and release still respects their choice", e.release(currentMode: .gone) == nil)
}

// MARK: - 5. Retargeting

print("== retarget ==")

do {
    var e = FocusEngagement()
    _ = e.engage(currentMode: .blind, target: .naked)
    t.equal("retarget mid-Focus moves you now", e.retarget(currentMode: .naked, to: .gone), .gone)
    t.equal("release after retarget still returns Blind", e.release(currentMode: .gone), .blind)
}

do {
    var e = FocusEngagement()
    t.check("retarget while not engaged does nothing", e.retarget(currentMode: .blind, to: .gone) == nil)
    t.check("retarget while not engaged does not engage", !e.isEngaged)
}

do {
    // One Focus hands straight over to another with a different mode. The app
    // sees engage(gone) with no release in between.
    var e = FocusEngagement()
    _ = e.engage(currentMode: .blind, target: .naked)
    t.equal("a Focus handover retargets rather than re-engaging",
            e.engage(currentMode: .naked, target: .gone), .gone)
    t.equal("and the original pre-Focus mode survives the handover", e.modeBefore, .blind)
    t.equal("release after a handover still returns Blind", e.release(currentMode: .gone), .blind)
}

// MARK: - 6. Abandon

print("== abandon ==")

do {
    var e = FocusEngagement()
    _ = e.engage(currentMode: .blind, target: .naked)
    e.abandon()
    t.check("abandon clears engagement", !e.isEngaged && e.modeBefore == nil && e.target == nil)
    t.check("release after abandon is a no-op", e.release(currentMode: .naked) == nil)
}

do {
    // The defect a code review caught, and the reason `isSuppressed` exists.
    //
    // Pressing Restore does not end the Focus. The backstop sweep keeps reading
    // the same live mode every 30 seconds, and on wake and unlock. Without
    // suppression the machine sees "not engaged, Focus wants naked" and treats
    // an hours-old Focus as a brand new activation, silently re-hiding the menu
    // bar the user just un-hid. For an all-day Do Not Disturb that is every 30
    // seconds, all day.
    var e = FocusEngagement()
    _ = e.engage(currentMode: .blind, target: .naked)
    e.abandon()                     // user presses Restore, mode goes to .off
    t.check("suppressed after Restore during a Focus", e.isSuppressed)

    // Ten sweeps while the same Focus is still running.
    for _ in 0..<10 {
        t.check("a sweep during a suppressed Focus does not re-engage",
                e.engage(currentMode: .off, target: .naked) == nil)
    }
    t.check("and it never marks itself engaged", !e.isEngaged)

    // The Focus finally ends.
    t.check("the ending Focus changes nothing", e.release(currentMode: .off) == nil)
    t.check("and the suppression is spent", !e.isSuppressed)

    // The NEXT Focus must work normally.
    t.equal("the next Focus engages normally", e.engage(currentMode: .off, target: .naked), .naked)
    t.equal("and remembers the mode it found", e.modeBefore, .off)
}

do {
    // Restore with no Focus running must not deafen us to the next one.
    var e = FocusEngagement()
    e.abandon()
    t.check("abandon with nothing engaged does not suppress", !e.isSuppressed)
    t.equal("so the next Focus still engages", e.engage(currentMode: .blind, target: .naked), .naked)
}

do {
    // Restore pressed twice during one Focus must not clear its own suppression.
    var e = FocusEngagement()
    _ = e.engage(currentMode: .blind, target: .naked)
    e.abandon()
    e.abandon()
    t.check("a second Restore keeps the suppression", e.isSuppressed)
    t.check("still suppressed against the sweep", e.engage(currentMode: .off, target: .naked) == nil)
}

do {
    // Suppression has to survive a quit, or a relaunch inside the same Focus
    // undoes Restore just as surely as a sweep would.
    var e = FocusEngagement()
    _ = e.engage(currentMode: .blind, target: .naked)
    e.abandon()
    var revived = FocusEngagement(isEngaged: e.isEngaged,
                                  modeBefore: e.modeBefore,
                                  isSuppressed: e.isSuppressed,
                                  target: e.target)
    t.check("suppression survives a quit", revived.isSuppressed)
    t.check("and still holds after relaunch", revived.engage(currentMode: .off, target: .naked) == nil)
}

// MARK: - 7. Surviving a quit
//
// The three fields are persisted, so a quit and relaunch is exactly a
// round trip through their raw string forms.

print("== persistence ==")

func roundTrip(_ e: FocusEngagement) -> FocusEngagement {
    let engagedRaw = e.isEngaged
    let suppressedRaw = e.isSuppressed
    let beforeRaw = e.modeBefore?.rawValue ?? ""
    let targetRaw = e.target?.rawValue ?? ""
    return FocusEngagement(isEngaged: engagedRaw,
                           modeBefore: ClockMode(rawValue: beforeRaw),
                           isSuppressed: suppressedRaw,
                           target: ClockMode(rawValue: targetRaw))
}

do {
    var e = FocusEngagement()
    _ = e.engage(currentMode: .blind, target: .naked)
    let revived = roundTrip(e)
    t.equal("engagement survives a quit intact", revived, e)
    var after = revived
    t.equal("and releases correctly after relaunch", after.release(currentMode: .naked), .blind)
}

do {
    // Killed mid-Focus, Focus ended while the app was gone, app relaunches and
    // the launch read reports "no Focus".
    var e = FocusEngagement()
    _ = e.engage(currentMode: .gone, target: .naked)
    var revived = roundTrip(e)
    t.equal("a Focus that ended while the app was dead still restores",
            revived.release(currentMode: .naked), .gone)
}

do {
    let empty = roundTrip(FocusEngagement())
    t.equal("an empty engagement round-trips to empty", empty, FocusEngagement())
    t.check("an unrecognised stored mode reads as nothing saved",
            ClockMode(rawValue: "some-mode-from-a-future-version") == nil)
}

// MARK: - 8. Long runs and fuzzing

print("== long runs ==")

do {
    // The defect this design exists to prevent: drift. After N Focus cycles the
    // user must still land on the mode they chose.
    var e = FocusEngagement()
    var mode = ClockMode.blind
    for _ in 0..<1000 {
        if let next = e.engage(currentMode: mode, target: .naked) { mode = next }
        if let next = e.release(currentMode: mode) { mode = next }
    }
    t.equal("1,000 Focus cycles land back on the mode the user chose", mode, .blind)
    t.check("and leave nothing engaged", !e.isEngaged)
}

do {
    // Same, but with the sweep firing repeatedly inside every Focus and the
    // target changing under us, which is the realistic shape.
    var e = FocusEngagement()
    var mode = ClockMode.blind
    var rng = SystemRandomNumberGenerator()
    for _ in 0..<1000 {
        let target = ClockMode.focusTargets.randomElement(using: &rng)!
        if let next = e.engage(currentMode: mode, target: target) { mode = next }
        for _ in 0..<Int.random(in: 0...4, using: &rng) {
            if let next = e.engage(currentMode: mode, target: target) { mode = next }
        }
        if let next = e.release(currentMode: mode) { mode = next }
    }
    t.equal("1,000 cycles with random targets and sweeps still land on Blind", mode, .blind)
}

do {
    // Every path, in every order. The machine must never reach a state where it
    // is engaged with nothing saved, or holds a saved mode while released.
    var e = FocusEngagement()
    var mode = ClockMode.blind
    var rng = SystemRandomNumberGenerator()
    var illegal = 0
    var releasedButHolding = 0
    var suppressedWhileEngaged = 0
    for _ in 0..<50_000 {
        switch Int.random(in: 0..<6, using: &rng) {
        case 0:
            let target = ClockMode.focusTargets.randomElement(using: &rng)!
            if let n = e.engage(currentMode: mode, target: target) { mode = n }
        case 1:
            if let n = e.release(currentMode: mode) { mode = n }
        case 2:
            let target = ClockMode.focusTargets.randomElement(using: &rng)!
            if let n = e.retarget(currentMode: mode, to: target) { mode = n }
        case 3:
            e.abandon()
        case 4:
            mode = ClockMode.allCases.randomElement(using: &rng)!   // user picks a mode
        default:
            e = roundTrip(e)                                        // quit and relaunch
        }
        if e.isEngaged && (e.modeBefore == nil || e.target == nil) { illegal += 1 }
        if !e.isEngaged && (e.modeBefore != nil || e.target != nil) { releasedButHolding += 1 }
        if e.isEngaged && e.isSuppressed { suppressedWhileEngaged += 1 }
    }
    t.equal("50,000 random operations never engage with nothing saved", illegal, 0)
    t.equal("50,000 random operations never hold state while released", releasedButHolding, 0)
    t.equal("50,000 random operations are never suppressed and engaged at once", suppressedWhileEngaged, 0)

    // A suppression must always be escapable, or Follow Focus is dead for good.
    var stuck = e
    _ = stuck.release(currentMode: .blind)
    t.check("a release always clears suppression, whatever the history", !stuck.isSuppressed)
}

do {
    // A Focus must never be able to leave the user somewhere they cannot get
    // back from: whatever happens, `release` either restores or leaves alone,
    // and never invents a mode nobody asked for.
    var e = FocusEngagement()
    var rng = SystemRandomNumberGenerator()
    var invented = 0
    for _ in 0..<20_000 {
        let start = ClockMode.allCases.randomElement(using: &rng)!
        let target = ClockMode.focusTargets.randomElement(using: &rng)!
        var mode = start
        if let n = e.engage(currentMode: mode, target: target) { mode = n }
        if Bool.random(using: &rng) { mode = ClockMode.allCases.randomElement(using: &rng)! }
        let before = mode
        if let n = e.release(currentMode: mode) { mode = n }
        // The mode after release is either untouched, or exactly the mode the
        // user was on when the Focus began. Never a third thing.
        if mode != before && mode != start { invented += 1 }
        e.abandon()
    }
    t.equal("release never invents a mode the user was not already on", invented, 0)
}

// MARK: - 9. Only the clock: the strip that stops at the clock
//
// Pure arithmetic on two rects, pulled out of the locator so it can be checked
// without a window server. The numbers are the ones measured on macOS 26.6.2.

print("== geometry ==")

do {
    // The MacBook bar: 1728pt wide, 33pt tall, clock at x=1588 and 142pt
    // wide, which runs 2pt past the screen edge. So there is nothing to the
    // right of the clock, and the strip is everything to its left.
    let bar = CGRect(x: 0, y: 1084, width: 1728, height: 33)
    let clock = CGRect(x: 1588, y: 1084, width: 142, height: 33)
    let strip = MenuBarGeometry.barExcludingClock(bar: bar, clock: clock)
    t.equal("the strip starts at the bar's left edge", strip?.minX, 0)
    t.equal("and stops exactly at the clock", strip?.maxX, 1588)
    t.equal("full bar height", strip?.height, 33)
    t.equal("same baseline as the bar", strip?.minY, 1084)
}

do {
    // The external display: origin is not zero, bar is 30pt, clock ends flush
    // with the screen edge.
    let bar = CGRect(x: 121, y: 2527, width: 2560, height: 30)
    let clock = CGRect(x: 2539, y: 2527, width: 142, height: 30)
    let strip = MenuBarGeometry.barExcludingClock(bar: bar, clock: clock)
    t.equal("a bar with a non-zero origin keeps it", strip?.minX, 121)
    t.equal("and still stops at the clock", strip?.maxX, 2539)
    t.equal("width is measured from the bar's own origin", strip?.width, 2418)
    t.equal("the shorter bar keeps its own height", strip?.height, 30)
}

do {
    let bar = CGRect(x: 0, y: 1084, width: 1728, height: 33)
    t.check("a clock on another screen produces no strip",
            MenuBarGeometry.barExcludingClock(bar: bar, clock: CGRect(x: 2539, y: 2527, width: 142, height: 30)) == nil)
    t.check("a clock below the bar produces no strip",
            MenuBarGeometry.barExcludingClock(bar: bar, clock: CGRect(x: 1588, y: 500, width: 142, height: 33)) == nil)
    t.check("a clock at the bar's left edge leaves nothing to cover",
            MenuBarGeometry.barExcludingClock(bar: bar, clock: CGRect(x: 0, y: 1084, width: 142, height: 33)) == nil)
    t.check("a clock wider than the bar leaves nothing to cover",
            MenuBarGeometry.barExcludingClock(bar: bar, clock: CGRect(x: -10, y: 1084, width: 2000, height: 33)) == nil)
    t.check("an empty clock rect produces no strip",
            MenuBarGeometry.barExcludingClock(bar: bar, clock: .zero) == nil)
    t.check("an empty bar produces no strip",
            MenuBarGeometry.barExcludingClock(bar: .zero, clock: CGRect(x: 100, y: 0, width: 142, height: 33)) == nil)
}

do {
    // The property the mode is named for: whatever the layout, the strip never
    // reaches the clock and never leaves the bar.
    var rng = SystemRandomNumberGenerator()
    var covered = 0
    var escaped = 0
    var produced = 0
    for _ in 0..<20_000 {
        let barX = CGFloat(Int.random(in: -3000...3000, using: &rng))
        let barW = CGFloat(Int.random(in: 800...5000, using: &rng))
        let h = CGFloat(Int.random(in: 22...40, using: &rng))
        let bar = CGRect(x: barX, y: CGFloat(Int.random(in: -2000...2000, using: &rng)), width: barW, height: h)
        let clock = CGRect(x: CGFloat(Int.random(in: Int(barX - 200)...Int(barX + barW + 200), using: &rng)),
                           y: bar.minY, width: CGFloat(Int.random(in: 40...160, using: &rng)), height: h)
        guard let strip = MenuBarGeometry.barExcludingClock(bar: bar, clock: clock) else { continue }
        produced += 1
        if strip.maxX > clock.minX { covered += 1 }
        if strip.minX < bar.minX || strip.maxX > bar.maxX || strip.minY != bar.minY || strip.height != bar.height { escaped += 1 }
    }
    t.check("the fuzz produced strips at all", produced > 10_000, "only \(produced) of 20,000")
    t.equal("20,000 random layouts never cover the clock", covered, 0)
    t.equal("20,000 random layouts never leave the bar", escaped, 0)
}

t.finish()
