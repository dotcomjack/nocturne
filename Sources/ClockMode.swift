// █ dcj · dotcomjack.com · MIT
import Foundation

/// What Nocturne is currently doing to the menu bar clock.
///
/// The modes are deliberately ordered by how much they intervene, with one
/// exception at the end. `blind` is the default because it is the only one
/// that cannot break: it flips a preference macOS has shipped for years and
/// then gets out of the way.
enum ClockMode: String, CaseIterable, Identifiable, Sendable {

    /// Leave the clock exactly as macOS drew it.
    case off

    /// Swap the digital readout for an analog dial.
    ///
    /// The time is still on screen, it is simply not legible at 44pt. That is
    /// the whole trick: your eye stops catching "3:14 AM" in the corner without
    /// anything being hidden, moved, or drawn over.
    case blind

    /// Cover the clock's window rect with an opaque strip.
    ///
    /// Experimental. This one draws over another process's window, so it has to
    /// re-find the clock whenever the menu bar reflows.
    case gone

    /// Cover the entire menu bar, so nothing shows at all.
    ///
    /// Counterintuitively this looks *better* than `gone`, not worse. A patch
    /// over part of the bar has to colour-match its neighbours or it reads as a
    /// band. A patch over the whole bar has no neighbours: its only edge is the
    /// bar's own bottom edge, which is already a boundary.
    ///
    /// Clicks still pass through, so the Apple menu and app menus keep working.
    /// You just cannot read them.
    case naked

    /// Cover the entire menu bar except the clock, which stays digital.
    ///
    /// The inverse of `naked`, for the person whose problem is the twenty
    /// icons rather than the time. It sits last because it is the one mode
    /// that intervenes with the *bar* fully and with the *clock* not at all.
    ///
    /// The strip runs from the bar's left edge to the clock's left edge and
    /// stops. Nothing is drawn to the right of the clock because there is
    /// nothing there: measured on macOS 26.6.2, the clock's window runs to the
    /// screen edge on a notched MacBook and on an external display alike, see
    /// `MenuBarGeometry.barExcludingClock`.
    ///
    /// This is the only mode besides `off` that leaves `IsAnalog` false. The
    /// clock has to be readable, so arriving here from any other mode puts the
    /// digital clock back before the strip goes up.
    case clockOnly

    var id: String { rawValue }

    /// The modes Follow Focus is allowed to switch you into.
    ///
    /// `off` is excluded on purpose. "When a Focus starts, show the clock" is a
    /// setting that does nothing for anyone who wanted this feature, and having
    /// it in the list mostly produces people who picked it by accident and then
    /// report that Follow Focus is broken.
    static var focusTargets: [ClockMode] { allCases.filter { $0 != .off } }

    var title: String {
        switch self {
        case .off:       return "Clock visible"
        case .blind:     return "Blind"
        case .gone:      return "Gone"
        case .naked:     return "Hide everything"
        case .clockOnly: return "Only the clock"
        }
    }

    var detail: String {
        switch self {
        case .off:       return "Normal macOS clock."
        case .blind:     return "Analog dial. The time is there, you just cannot read it."
        case .gone:      return "Just the clock, covered. Experimental."
        case .naked:     return "The whole menu bar goes blank. Clicks still work, you just cannot read it."
        case .clockOnly: return "Everything but the clock goes blank. Clicks still work, you just cannot read them."
        }
    }

    /// What the overlay has to cover for this mode, or nil when the mode does
    /// not draw anything.
    ///
    /// Exhaustive on purpose. A `default:` here would let a future mode inherit
    /// somebody else's coverage without anyone noticing; `Tests/main.swift`
    /// pins the answer per case.
    var coverage: MenuBarCoverage? {
        switch self {
        case .off, .blind: return nil
        case .gone:        return .clock
        case .naked:       return .entireBar
        case .clockOnly:   return .barExceptClock
        }
    }

    /// True when this mode needs the overlay running.
    var usesOverlay: Bool { coverage != nil }

    /// True when this mode wants the clock swapped to analog underneath.
    ///
    /// `gone` and `naked` want it too, not just `blind`: shrinking the clock to
    /// 44pt before covering it is most of what makes a cover survivable, and
    /// it means a strip that is torn down for full screen leaves an unreadable
    /// dial behind rather than the time.
    var wantsAnalogClock: Bool {
        switch self {
        case .off, .clockOnly:      return false
        case .blind, .gone, .naked: return true
        }
    }

    /// True for the modes whose strip has a neighbour it cannot colour-match.
    ///
    /// Settings shows the fill picker for these and only these. `naked` has
    /// no seam because its only edge is the bar's own bottom edge; `clockOnly`
    /// has exactly one, the vertical edge where the strip stops at the clock.
    var hasSeam: Bool { self == .gone || self == .clockOnly }

    /// Menu bar glyph. SF Symbols, so it inherits menu bar tinting for free.
    var symbolName: String {
        switch self {
        case .off:       return "clock"
        case .blind:     return "clock.badge.xmark"
        case .gone:      return "moon.stars"
        case .naked:     return "moon.fill"
        case .clockOnly: return "moon.circle.fill"
        }
    }
}
