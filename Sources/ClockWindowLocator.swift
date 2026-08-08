import AppKit
import CoreGraphics

/// Finds Control Center's clock on every attached display.
///
/// This uses only `CGWindowListCopyWindowInfo`, which is public API and needs no
/// Screen Recording permission as long as we read window *geometry* and never
/// window *contents*. Asking for the image would trip the TCC prompt; asking for
/// the rect does not.
///
/// On a two display setup the list contains one `Clock` window per menu bar, so
/// callers get an array and should cover all of them.
enum ClockWindowLocator {

    private static let ownerName = "Control Center"
    private static let windowName = "Clock"

    /// Clock rects in Cocoa screen coordinates, ready to hand to `NSWindow`.
    static func rects() -> [CGRect] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        return raw.compactMap { window -> CGRect? in
            guard window[kCGWindowOwnerName as String] as? String == ownerName,
                  window[kCGWindowName as String] as? String == windowName,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds)
            else { return nil }
            return cocoaRect(fromQuartz: rect)
        }
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
