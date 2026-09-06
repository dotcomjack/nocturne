// █ dcj · dotcomjack.com · MIT
import CoreGraphics
import Foundation

/// How much of the menu bar the overlay covers.
///
/// Foundation-only on purpose, so `ClockMode` can name its coverage and the
/// test harness can pin the answer per mode without linking AppKit.
enum MenuBarCoverage: Equatable, Sendable {
    /// Just Control Center's clock. Gone.
    case clock
    /// The entire bar, on every screen. Hide everything.
    case entireBar
    /// The entire bar up to the clock's left edge, and not a point further.
    /// Only the clock.
    case barExceptClock

    /// True for the coverages that put the whole bar out of sight, which are
    /// the ones that have to redraw Nocturne's own glyph so the way out stays
    /// visible. See `OverlayController.beacon`.
    var blanksBar: Bool { self != .clock }
}

/// The arithmetic behind Only the clock.
///
/// Pulled out of `ClockWindowLocator` because it is the one part of that mode
/// that can be checked without a window server, and the property that matters,
/// that the strip never reaches the clock, is cheap to prove here and
/// expensive to eyeball on a live bar.
enum MenuBarGeometry {

    /// The part of `bar` to cover so that `clock` stays readable.
    ///
    /// Runs from the bar's left edge to the clock's left edge. Nothing is
    /// returned for the right of the clock, and that is deliberate rather than
    /// lazy: measured on macOS 26.6.2, the clock's window runs to the screen
    /// edge on both a notched MacBook (x=1588, 142pt wide on a 1728pt screen,
    /// so it actually overhangs by 2pt) and an external display (flush). A
    /// second strip there would be a dark sliver beside the clock with nothing
    /// under it, which reads as a bug.
    ///
    /// Returns nil when there is nothing to cover, or when `clock` is not in
    /// `bar` at all. The locator buckets items by screen before calling this,
    /// so the second case is a guard against a stale rect, not a normal path.
    static func barExcludingClock(bar: CGRect, clock: CGRect) -> CGRect? {
        guard !bar.isEmpty, !clock.isEmpty else { return nil }

        // Same bar: the clock's vertical span sits inside the bar's. A point of
        // slop each way, because the two rects come from different sources
        // (`NSScreen` for the bar, the window list for the clock).
        guard clock.minY >= bar.minY - 1, clock.maxY <= bar.maxY + 1 else { return nil }

        // The clock's LEFT edge is the only edge that matters, and it has to be
        // strictly inside the bar. Its right edge is allowed to overhang; see
        // above.
        guard clock.minX > bar.minX, clock.minX < bar.maxX else { return nil }

        return CGRect(x: bar.minX, y: bar.minY, width: clock.minX - bar.minX, height: bar.height)
    }
}
