// █ dcj · dotcomjack.com · MIT
import AppKit
import CoreGraphics

/// Finds Control Center's clock on every attached display.
///
/// Uses only `CGWindowListCopyWindowInfo`, and deliberately reads **geometry
/// only**. That distinction is the whole design:
///
/// - `kCGWindowBounds` is available to any process, no permission required.
/// - `kCGWindowName` is gated behind Screen Recording (TCC).
///
/// An earlier version filtered on `kCGWindowName == "Clock"`. It appeared to
/// work during development purely because the binary was launched from a
/// terminal and inherited that terminal's Screen Recording grant. Launched
/// normally as an app bundle, the name field came back nil for every window, so
/// the locator returned nothing and Gone mode silently drew nothing at all.
/// Measured on the same build, same machine:
///
///     launched as                 windows with a readable name    rects()
///     bare binary from Terminal   10                              1
///     .app via `open`              0                              0
///
/// So: identify the clock by where it sits, not by what it is called. The clock
/// is the right-most item Control Center owns in a given menu bar, which is a
/// position macOS does not let the user change.
enum ClockWindowLocator {

    private static let ownerName = "Control Center"

    /// Anything taller than this is not a menu bar item.
    private static let maxMenuBarItemHeight: CGFloat = 60

    /// Tolerance when matching a window's top edge to a screen's top edge.
    private static let topEdgeSlop: CGFloat = 3

    /// One read of the window list, and everything a placement pass needs
    /// from it.
    ///
    /// `CGWindowListCopyWindowInfo` is a round trip to the window server and
    /// the only expensive thing the tracker does: 0.45ms per call, measured on
    /// 26.6.2. The 1.4.1 tracker made four of them every 2s in Only the clock
    /// with Hover to show (the strip, the beacon check twice, the hover bands),
    /// all describing the same instant. Taking one snapshot and asking it every
    /// question makes that one, and it also means the strip, the beacon and
    /// the hover bands can never disagree about a bar that reflowed between
    /// two reads.
    struct Snapshot {

        /// Control Center's menu bar items, Quartz coordinates, bucketed by
        /// the index of the screen whose bar they sit in.
        fileprivate let itemsByScreen: [Int: [CGRect]]

        /// Every Control Center window, unfiltered, for `hasMenuBarItem`.
        fileprivate let ownWindows: [CGRect]

        fileprivate let screens: [NSScreen]

        /// Reads the window list once.
        ///
        /// Walked as `NSArray` and `NSDictionary` rather than bridged to
        /// `[[String: Any]]`, which would copy every key of every window on the
        /// system into Swift only to throw all but two away.
        static func current() -> Snapshot {
            let screens = NSScreen.screens
            let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
            guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as NSArray? else {
                return Snapshot(itemsByScreen: [:], ownWindows: [], screens: screens)
            }

            var byScreen: [Int: [CGRect]] = [:]
            var own: [CGRect] = []
            for case let window as NSDictionary in raw {
                guard window[kCGWindowOwnerName] as? String == ownerName,
                      let boundsValue = window[kCGWindowBounds] as? NSDictionary,
                      let rect = CGRect(dictionaryRepresentation: boundsValue)
                else { continue }

                own.append(rect)

                guard rect.height > 0, rect.height <= maxMenuBarItemHeight,
                      let screenIndex = menuBarIndex(containing: rect, screens: screens)
                else { continue }
                byScreen[screenIndex, default: []].append(rect)
            }
            return Snapshot(itemsByScreen: byScreen, ownWindows: own, screens: screens)
        }

        /// Whether a real menu bar item is drawn at this Cocoa rect.
        ///
        /// AppKit keeps reporting a plausible on-bar frame for a status item
        /// macOS has dropped for menu bar overflow, so `NSStatusItem` cannot be
        /// trusted about its own position. The window list can: every status
        /// item, ours included, is hosted by Control Center as a real window,
        /// and if no such window exists at that rect then nothing is drawn
        /// there.
        ///
        /// Geometry only, so no Screen Recording permission is involved.
        func hasMenuBarItem(at cocoaRect: CGRect) -> Bool {
            guard let primary = screens.first else { return false }
            let quartzY = primary.frame.maxY - cocoaRect.origin.y - cocoaRect.height

            return ownWindows.contains { rect in
                abs(rect.minX - cocoaRect.minX) <= 2
                    && abs(rect.minY - quartzY) <= 2
                    && abs(rect.width - cocoaRect.width) <= 2
            }
        }

        /// Clock rects in Cocoa screen coordinates, one per menu bar, ready to
        /// hand to `NSWindow`.
        func clockRects() -> [CGRect] {
            itemsByScreen.values
                .compactMap { $0.max(by: { $0.maxX < $1.maxX }) }
                .map { cocoaRect(fromQuartz: $0, screens: screens) }
        }

        /// The full menu bar strip, but only on screens that currently *have* a
        /// menu bar showing.
        ///
        /// The geometry itself comes from `NSScreen`, because the Window
        /// Server's own menu bar window is identified by its name and the name
        /// field is the TCC-gated one. But `NSScreen` always reports every
        /// screen, whether or not a bar is drawn on it. Deriving the rects from
        /// `NSScreen` alone therefore never returns empty, the caller's teardown
        /// guard never fires, and the strip stays put in full screen: a solid
        /// band across the top of whatever video you are watching.
        ///
        /// So gate on the same signal the clock path uses. If Control Center is
        /// not drawing items into a screen's bar, that bar is hidden, and there
        /// is nothing there to cover.
        func menuBarRects() -> [CGRect] {
            itemsByScreen.compactMap { index, itemRects in
                guard index < screens.count else { return nil }
                return barRect(for: screens[index], items: itemRects)
            }
        }

        /// The menu bar minus its clock, one strip per bar, for Only the clock.
        ///
        /// Same gate as `menuBarRects()`: a screen Control Center is not
        /// drawing into has no bar showing, so it gets no strip. And the clock
        /// is the same right-most item `clockRects()` returns, so the two can
        /// never disagree about where it is. The arithmetic lives in
        /// `MenuBarGeometry` where it can be tested without a window server.
        func menuBarRectsExcludingClock() -> [CGRect] {
            itemsByScreen.compactMap { index, itemRects in
                guard index < screens.count,
                      let clock = itemRects.max(by: { $0.maxX < $1.maxX })
                else { return nil }
                return MenuBarGeometry.barExcludingClock(
                    bar: barRect(for: screens[index], items: itemRects),
                    clock: cocoaRect(fromQuartz: clock, screens: screens))
            }
        }
    }

    /// Clock rects from a fresh read. For callers that ask one question once,
    /// such as the settle wait after a Control Center restart.
    static func rects() -> [CGRect] {
        Snapshot.current().clockRects()
    }

    /// The full strip of a screen's menu bar, in Cocoa coordinates.
    private static func barRect(for screen: NSScreen, items: [CGRect]) -> CGRect {
        let height = barHeight(for: screen, items: items)
        return CGRect(x: screen.frame.minX,
                      y: screen.frame.maxY - height,
                      width: screen.frame.width,
                      height: height)
    }

    /// Menu bar thickness for a screen.
    ///
    /// Measured from the menu bar items actually drawn into it, because they are
    /// exactly as tall as the bar. Everything else is an approximation:
    ///
    /// - `frame.maxY - visibleFrame.maxY` reads 34 on a notched display where
    ///   the bar is really 33, so a strip built from it overhangs by a point.
    ///   Two device pixels at 2x, full width, and the fill is measurably darker
    ///   than the bar, so it renders as a hairline rule under the menu bar.
    /// - That inset also swallows the Dock when the Dock is docked to the top,
    ///   which would make the strip far too tall.
    /// - `NSStatusBar.thickness` reads 22 here, well short of the real 33.
    ///
    /// The items are the ground truth, so use them and keep the rest as a
    /// fallback for the moment before Control Center has drawn anything.
    private static func barHeight(for screen: NSScreen, items: [CGRect]) -> CGFloat {
        if let measured = items.map(\.height).max(), measured > 0 {
            return measured
        }

        let inset = screen.frame.maxY - screen.visibleFrame.maxY
        let thickness = NSStatusBar.system.thickness
        guard inset > 0 else { return thickness }
        return min(max(inset, thickness), thickness * 2)
    }

    /// Which screen's menu bar this window is sitting in, if any.
    ///
    /// A menu bar item's top edge is flush with the top edge of its screen. That
    /// is what separates a status item from Control Center's own popover panel,
    /// which is also owned by "Control Center" but hangs below the bar. The top
    /// edge is compared in Quartz (top-left origin) coordinates.
    private static func menuBarIndex(containing rect: CGRect, screens: [NSScreen]) -> Int? {
        guard let primary = screens.first else { return nil }
        for (index, screen) in screens.enumerated() {
            let quartzTop = primary.frame.maxY - screen.frame.maxY
            guard abs(rect.minY - quartzTop) <= topEdgeSlop else { continue }
            guard rect.midX >= screen.frame.minX, rect.midX <= screen.frame.maxX else { continue }
            return index
        }
        return nil
    }

    /// Quartz window bounds use a top-left origin anchored to the primary
    /// display. Cocoa uses bottom-left. Flipping against the primary screen's
    /// height is the conversion, and it has to be the *primary* screen even when
    /// the clock lives on a secondary one.
    private static func cocoaRect(fromQuartz rect: CGRect, screens: [NSScreen]) -> CGRect {
        guard let primary = screens.first else { return rect }
        let flippedY = primary.frame.maxY - rect.origin.y - rect.height
        return CGRect(x: rect.origin.x, y: flippedY, width: rect.width, height: rect.height)
    }
}
