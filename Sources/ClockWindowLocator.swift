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

    /// Control Center's menu bar windows, bucketed by which screen's bar they
    /// are sitting in. Bucketing matters on a multi display setup, where two
    /// bars are present at once.
    private static func itemsByScreen() -> [Int: [CGRect]] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return [:]
        }

        var byScreen: [Int: [CGRect]] = [:]
        for window in raw {
            guard window[kCGWindowOwnerName as String] as? String == ownerName,
                  let boundsValue = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: boundsValue),
                  rect.height > 0, rect.height <= maxMenuBarItemHeight,
                  let screenIndex = menuBarIndex(containing: rect)
            else { continue }

            byScreen[screenIndex, default: []].append(rect)
        }
        return byScreen
    }

    /// Clock rects in Cocoa screen coordinates, one per menu bar, ready to hand
    /// to `NSWindow`.
    static func rects() -> [CGRect] {
        itemsByScreen().values
            .compactMap { $0.max(by: { $0.maxX < $1.maxX }) }
            .map(cocoaRect(fromQuartz:))
    }

    /// The full menu bar strip, but only on screens that currently *have* a
    /// menu bar showing.
    ///
    /// The geometry itself comes from `NSScreen`, because the Window Server's
    /// own menu bar window is identified by its name and the name field is the
    /// TCC-gated one. But `NSScreen` always reports every screen, whether or not
    /// a bar is drawn on it. Deriving the rects from `NSScreen` alone therefore
    /// never returns empty, the caller's teardown guard never fires, and the
    /// strip stays put in full screen: a solid band across the top of whatever
    /// video you are watching.
    ///
    /// So gate on the same signal the clock path uses. If Control Center is not
    /// drawing items into a screen's bar, that bar is hidden, and there is
    /// nothing there to cover.
    static func menuBarRects() -> [CGRect] {
        let populated = Set(itemsByScreen().keys)
        let screens = NSScreen.screens

        return populated.compactMap { index in
            guard index < screens.count else { return nil }
            let screen = screens[index]
            let height = barHeight(for: screen)
            return CGRect(x: screen.frame.minX,
                          y: screen.frame.maxY - height,
                          width: screen.frame.width,
                          height: height)
        }
    }

    /// Menu bar thickness for a screen.
    ///
    /// `frame.maxY - visibleFrame.maxY` is the honest measurement and accounts
    /// for a notch, but it also swallows the Dock when the Dock is docked to the
    /// top. `NSStatusBar.thickness` is the floor that keeps that case sane.
    private static func barHeight(for screen: NSScreen) -> CGFloat {
        let inset = screen.frame.maxY - screen.visibleFrame.maxY
        let thickness = NSStatusBar.system.thickness
        guard inset > 0 else { return thickness }
        return min(max(inset, thickness), thickness * 2)
    }

    /// Which screen's menu bar this window is sitting in, if any.
    ///
    /// A menu bar item's top edge is flush with the top edge of its screen. That
    /// is what separates a status item from Control Center's own popover panel,
    /// which is also owned by "Control Center" but hangs below the bar.
    private static func menuBarIndex(containing rect: CGRect) -> Int? {
        for (index, screen) in NSScreen.screens.enumerated() {
            let quartzTop = quartzTopEdge(of: screen)
            guard abs(rect.minY - quartzTop) <= topEdgeSlop else { continue }
            guard rect.midX >= screen.frame.minX, rect.midX <= screen.frame.maxX else { continue }
            return index
        }
        return nil
    }

    /// A screen's top edge expressed in Quartz (top-left origin) coordinates.
    private static func quartzTopEdge(of screen: NSScreen) -> CGFloat {
        guard let primary = NSScreen.screens.first else { return 0 }
        return primary.frame.maxY - screen.frame.maxY
    }

    /// Quartz window bounds use a top-left origin anchored to the primary
    /// display. Cocoa uses bottom-left. Flipping against the primary screen's
    /// height is the conversion, and it has to be the *primary* screen even when
    /// the clock lives on a secondary one.
    private static func cocoaRect(fromQuartz rect: CGRect) -> CGRect {
        guard let primary = NSScreen.screens.first else { return rect }
        let flippedY = primary.frame.maxY - rect.origin.y - rect.height
        return CGRect(x: rect.origin.x, y: flippedY, width: rect.width, height: rect.height)
    }
}
