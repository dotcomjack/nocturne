import AppKit

/// Draws an opaque strip over Control Center's clock.
///
/// This is the experimental half of Nocturne. It has to keep re-finding the
/// clock, because the menu bar reflows whenever an item appears, a display is
/// attached, or an app takes over the bar in full screen.
///
/// One deliberate design choice: `gone` mode turns the clock analog *first*, so
/// the rect we have to cover is 44pt instead of 142pt. A colour mismatch across
/// 44pt reads as a smudge; across 142pt it reads as a bug. Shrinking the target
/// before covering it is most of what makes this mode survivable.
@MainActor
final class OverlayController {

    /// How the covering strip is filled.
    ///
    /// Neither option matches the bar exactly, and that is a real limit rather
    /// than an unfinished edge. The Tahoe menu bar is translucent over the
    /// wallpaper, so any window drawn *above* it blurs an already-translucent
    /// layer and tints on top, which always lands darker.
    ///
    /// Eight materials were measured against a live menu bar of rgb(124,106,33)
    /// by rendering swatches and sampling the screenshot. Lower is better:
    ///
    ///     hudWindow              36.7   <- shipped default
    ///     popover                54.7
    ///     titlebar               64.5
    ///     menu                   65.9
    ///     sidebar                77.4
    ///     underWindowBackground  77.4
    ///     headerView             89.0
    ///     windowBackground      110.3
    ///
    /// An exact match would mean sampling the real pixels, which costs a Screen
    /// Recording prompt. Reading the wallpaper file instead does not work: the
    /// stock Tahoe wallpaper is dynamic, and its first frame decoded to
    /// rgb(21,89,153) while the bar on screen was rgb(124,106,33).
    enum Fill: String, CaseIterable, Identifiable, Sendable {
        /// Blurred menu bar material. Adapts to any wallpaper and to light or
        /// dark mode, at the cost of reading slightly darker than the bar.
        case material
        /// Flat colour tracking light/dark appearance. Measurably worse on a
        /// colourful wallpaper, but cleaner on a plain or solid-colour one.
        case solid

        var id: String { rawValue }

        var title: String {
            switch self {
            case .material: return "Blend with wallpaper"
            case .solid:    return "Flat colour"
            }
        }

        var detail: String {
            switch self {
            case .material: return "Best on photo and colour wallpapers."
            case .solid:    return "Best on plain or solid-colour wallpapers."
            }
        }
    }

    /// How much of the menu bar the strip covers.
    enum Coverage {
        /// Just Control Center's clock.
        case clock
        /// The entire bar, on every screen.
        case entireBar
    }

    var fill: Fill = .material {
        didSet { guard fill != oldValue else { return }; rebuild() }
    }

    var coverage: Coverage = .clock {
        didSet { guard coverage != oldValue else { return }; rebuild() }
    }

    private var windows: [NSWindow] = []
    private var tracker: Timer?
    private(set) var isActive = false

    // MARK: - Lifecycle

    func activate() {
        guard !isActive else { return }
        isActive = true

        // The menu bar reflows on its own schedule, so poll rather than trust a
        // single placement. Two seconds is invisible to the user and costs a
        // window-list read, which is cheap.
        tracker = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sync() }
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil)

        sync()
    }

    func deactivate() {
        guard isActive else { return }
        isActive = false

        tracker?.invalidate()
        tracker = nil
        NotificationCenter.default.removeObserver(
            self,
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil)

        teardown()
    }

    @objc private func screensChanged() { sync() }

    // MARK: - Placement

    /// Reconciles the live clock rects with the windows we are showing.
    ///
    /// When the locator returns nothing the clock is genuinely not on screen,
    /// which is the normal state in full screen. Tearing the windows down there
    /// is what stops a stray strip floating over a video.
    private func sync() {
        let rects: [CGRect]
        switch coverage {
        case .clock:     rects = ClockWindowLocator.rects()
        case .entireBar: rects = ClockWindowLocator.menuBarRects()
        }

        guard !rects.isEmpty else {
            teardown()
            return
        }

        if windows.count != rects.count {
            teardown()
            windows = rects.map { makeWindow(frame: $0) }
        } else {
            for (window, rect) in zip(windows, rects) where window.frame != rect {
                window.setFrame(rect, display: false)
            }
        }

        for window in windows where !window.isVisible {
            window.orderFrontRegardless()
        }
    }

    private func rebuild() {
        guard isActive else { return }
        teardown()
        sync()
    }

    private func teardown() {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
    }

    // MARK: - Window construction

    private func makeWindow(frame: CGRect) -> NSWindow {
        let window = NSWindow(contentRect: frame,
                              styleMask: .borderless,
                              backing: .buffered,
                              defer: false)

        // One step above the status bar puts us over Control Center's items but
        // still under menus and popovers, so opening a menu is not obstructed.
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 1)

        // Clicks fall through to the real clock underneath. Covering it should
        // not mean disabling it.
        window.ignoresMouseEvents = true

        window.isOpaque = false
        window.hasShadow = false
        window.backgroundColor = .clear
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        window.contentView = makeContentView()
        window.setFrame(frame, display: false)
        window.orderFrontRegardless()
        return window
    }

    private func makeContentView() -> NSView {
        switch fill {
        case .material:
            let view = NSVisualEffectView()
            view.material = .hudWindow   // measured closest of eight, see Fill
            view.blendingMode = .behindWindow
            view.state = .active
            return view

        case .solid:
            let view = NSView()
            view.wantsLayer = true
            view.layer?.backgroundColor = Self.menuBarApproximation().cgColor
            return view
        }
    }

    /// Best-effort menu bar colour without reading a single pixel of the screen.
    private static func menuBarApproximation() -> NSColor {
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return isDark
            ? NSColor(calibratedWhite: 0.14, alpha: 1.0)
            : NSColor(calibratedWhite: 0.96, alpha: 1.0)
    }
}
