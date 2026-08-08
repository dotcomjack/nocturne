import Foundation

/// What Nocturne is currently doing to the menu bar clock.
///
/// The three modes are deliberately ordered by how much they intervene. `blind`
/// is the default because it is the only one that cannot break: it flips a
/// preference macOS has shipped for years and then gets out of the way.
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

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off:   return "Clock visible"
        case .blind: return "Blind"
        case .gone:  return "Gone"
        }
    }

    var detail: String {
        switch self {
        case .off:   return "Normal macOS clock."
        case .blind: return "Analog dial. The time is there, you just cannot read it."
        case .gone:  return "Covered completely. Experimental."
        }
    }

    /// Menu bar glyph. SF Symbols, so it inherits menu bar tinting for free.
    var symbolName: String {
        switch self {
        case .off:   return "clock"
        case .blind: return "clock.badge.xmark"
        case .gone:  return "moon.stars"
        }
    }
}
