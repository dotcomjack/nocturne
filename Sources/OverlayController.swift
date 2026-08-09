// █ dcj · dotcomjack.com · MIT
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

    /// Drop the strip while the pointer is on the menu bar, so the bar can be
    /// read by moving to it.
    ///
    /// Only the overlay modes can offer this. `blind` hides the time by writing
    /// Control Center's own `IsAnalog` preference, and undoing that costs a
    /// Control Center restart, which is a KeepAlive job on a 1s throttle. A
    /// hover cannot pay half a second and a menu bar blink each way.
    var hoverToShow = false {
        didSet {
            guard hoverToShow != oldValue else { return }
            if hoverToShow {
                startHoverMonitor()
                refreshHoverBands()
                evaluatePeek()
            } else {
                stopHoverMonitor()
            }
        }
    }

    /// Where Nocturne's own status item is, in Cocoa coordinates, and which
    /// glyph it is currently showing.
    ///
    /// Blanking the whole bar hides the one control that turns it back on,
    /// which leaves someone hunting a menu bar they cannot see. So the glyph is
    /// redrawn on top of the strip.
    ///
    /// Cutting a hole in the strip instead was the first attempt and looked
    /// worse: the hole exposes the real bar, which is lighter than the strip,
    /// so the icon sat in a visibly paler rectangle. Drawing over the top keeps
    /// the bar uniform. Supplied as a closure because the item moves whenever
    /// the bar reflows.
    var beacon: (() -> (frame: CGRect, symbol: String)?)?

    private var windows: [NSWindow] = []
    private var beaconWindow: NSWindow?
    private var currentBeaconSymbol: String?
    private var tracker: Timer?
    private(set) var isActive = false

    /// The menu bar rects that count as a hover, one per bar, cached because
    /// testing them on every mouse move would mean a window list read per event.
    private var hoverBands: [CGRect] = []
    private var hoverMonitor: Any?

    /// The bar the pointer is on, if any. Held as the band rather than a plain
    /// flag so that on a multi display setup only that screen's strip drops:
    /// hovering the laptop should not uncover the clock on the external panel.
    private var hoveredBand: CGRect?

    // MARK: - Lifecycle

    func activate() {
        // Already running means re-place, not ignore.
        //
        // The 2s tracker tears the strip down whenever it ticks while Control
        // Center is restarting, which is a ~500ms window it lands in roughly one
        // time in four. Recovery is supposed to come from the settle-wait
        // callback calling activate() again, but an early return made that
        // callback inert: the strip then stayed down until the next tick, so
        // Hide everything showed the whole menu bar for up to 2 seconds.
        guard !isActive else { sync(); return }
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

        // Light and dark are baked in when the views are built: the flat fill
        // colour goes into a layer once, and the glyph is tinted once with
        // isTemplate off. With Appearance set to Auto, sunset would otherwise
        // leave a white glyph on a light strip, invisible, which is the
        // advertised way out of a blanked bar.
        DistributedNotificationCenter.default.addObserver(
            self,
            selector: #selector(appearanceChanged),
            name: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil)

        startHoverMonitor()
        sync()
    }

    func deactivate() {
        guard isActive else { return }
        isActive = false

        stopHoverMonitor()
        tracker?.invalidate()
        tracker = nil
        NotificationCenter.default.removeObserver(
            self,
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil)
        DistributedNotificationCenter.default.removeObserver(self)

        teardown()
    }

    @objc private func screensChanged() { sync() }

    /// Rebuild rather than sync: the fill colour and the glyph tint are only
    /// computed when the views are constructed, so they have to be remade.
    @objc private func appearanceChanged() {
        DispatchQueue.main.async { [weak self] in self?.rebuild() }
    }

    // MARK: - Placement

    /// Reconciles the live clock rects with the windows we are showing.
    ///
    /// When the locator returns nothing the clock is genuinely not on screen,
    /// which is the normal state in full screen. Tearing the windows down there
    /// is what stops a stray strip floating over a video.
    private func sync() {
        let rects: [CGRect]
        switch coverage {
        case .clock:
            rects = ClockWindowLocator.rects()
        case .entireBar:
            rects = ClockWindowLocator.menuBarRects()
        }

        guard !rects.isEmpty else {
            teardown()
            return
        }

        // Decide about the beacon BEFORE placing anything.
        //
        // Blanking the whole bar hides the one control that turns it back on,
        // so the glyph has to be real. Checking it after placing meant the
        // windows were created and then torn down on the same pass, which on a
        // repeating 2s tracker is a strip that flashes on and off forever.
        if coverage == .entireBar, !beaconIsReal {
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

        syncBeacon()

        // Last, because it only adjusts the alpha of what the lines above have
        // just built. This is also the safety net for the hover state: the
        // monitor is the fast path, but it cannot fire for a pointer that was
        // already sitting on the bar before the mode changed.
        refreshHoverBands()
        evaluatePeek()
    }

    // MARK: - Hover to show

    /// Where the pointer has to be for the strip to drop away.
    ///
    /// The whole menu bar, not the covered rect, and that is deliberate for
    /// `.clock`: the patch there is a 44pt dial in the corner, and asking
    /// someone to land on it exactly would make the feature feel broken. Moving
    /// to the bar at all is the gesture.
    private func refreshHoverBands() {
        guard hoverToShow else {
            hoverBands = []
            return
        }
        // In `.entireBar` the strips already are the menu bars, so reuse them
        // rather than paying for a second window list read every 2s.
        hoverBands = (coverage == .entireBar)
            ? windows.map(\.frame)
            : ClockWindowLocator.menuBarRects()
    }

    /// Mouse-only global monitors need no permission, which is what makes this
    /// feature affordable at all: Nocturne asks for nothing, and the whole
    /// locator is built around avoiding a Screen Recording prompt.
    ///
    /// Measured on macOS 26.3.1 from an ad-hoc signed `.app` launched with
    /// `open`, so no inherited terminal grant, reporting
    /// `AXIsProcessTrusted() == false`: 131 `mouseMoved` events delivered.
    /// Only key events are TCC gated. Polling `NSEvent.mouseLocation` on a
    /// short timer was the alternative and is strictly worse, because it wakes
    /// the CPU 20 times a second forever to notice a pointer that usually is
    /// not moving.
    private func startHoverMonitor() {
        guard hoverToShow, isActive, hoverMonitor == nil else { return }
        hoverMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            // Global monitors are delivered on the main run loop.
            MainActor.assumeIsolated { self?.evaluatePeek() }
        }
    }

    private func stopHoverMonitor() {
        if let hoverMonitor { NSEvent.removeMonitor(hoverMonitor) }
        hoverMonitor = nil
        hoverBands = []
        if hoveredBand != nil {
            hoveredBand = nil
            applyPeek()
        }
    }

    private func evaluatePeek() {
        let point = NSEvent.mouseLocation
        // Expanded a point vertically before testing. `CGRect.contains` excludes
        // its own max edge, and a band's top edge IS the top of the screen,
        // which is exactly where the pointer sits when someone slams it up to
        // reach the menu bar. Without this the topmost row of pixels, the most
        // likely place for the pointer to be, reads as not hovering.
        let band = hoverBands.first { $0.insetBy(dx: 0, dy: -1).contains(point) }

        guard band != hoveredBand else { return }
        hoveredBand = band
        applyPeek()
    }

    /// Alpha rather than `orderOut`, because `sync()` re-shows any window that
    /// is not visible. Ordering out would put the strip back within 2 seconds
    /// while the pointer was still resting on the bar.
    private func applyPeek() {
        for window in windows {
            window.alphaValue = peekAlpha(for: window.frame)
        }
        if let beaconWindow {
            beaconWindow.alphaValue = peekAlpha(for: beaconWindow.frame)
        }
    }

    /// Transparent only for the bar the pointer is actually on.
    ///
    /// Matched by intersection rather than by index. A band spans its whole
    /// screen, so the strip drawn into that bar is the one it overlaps, and
    /// that holds without assuming `windows` and `hoverBands` came back from
    /// the window server in the same order. They do not: both are built from a
    /// dictionary keyed by screen, whose iteration order is not stable.
    private func peekAlpha(for frame: CGRect) -> CGFloat {
        guard let hoveredBand, hoveredBand.intersects(frame) else { return 1 }
        return 0
    }

    // MARK: - Beacon

    /// Redraws our own glyph above the strip so the way out stays visible.
    ///
    /// Only for `.entireBar`. In `.clock` coverage the bar is untouched and the
    /// real status item is already showing.
    /// Whether our status item is genuinely drawn where AppKit claims it is.
    ///
    /// AppKit reports a plausible on-bar frame for a status item macOS has
    /// dropped for menu bar overflow: of 26 test items, 20 were dropped and
    /// every one still claimed `isVisible` with a frame matching no real slot,
    /// running as far left as x=57. Painting the glyph there would advertise a
    /// way out that does nothing when clicked, which is worse than no glyph.
    ///
    /// An earlier version tested the frame against the strip we had placed.
    /// That was vacuous in the one mode it existed for: in Hide everything the
    /// strip spans the full screen width, so any frame in the bar's y-band
    /// intersects it, including x=57. This asks the window list whether an item
    /// is actually drawn there instead.
    private var beaconIsReal: Bool {
        guard let spec = beacon?() else { return false }
        return ClockWindowLocator.hasMenuBarItem(at: spec.frame)
    }

    private func syncBeacon() {
        guard coverage == .entireBar, !windows.isEmpty, let spec = beacon?(), beaconIsReal else {
            beaconWindow?.orderOut(nil)
            beaconWindow = nil
            return
        }

        let window = beaconWindow ?? makeBeaconWindow()
        beaconWindow = window

        if let view = window.contentView as? NSImageView, currentBeaconSymbol != spec.symbol {
            view.image = Self.beaconImage(named: spec.symbol)
            currentBeaconSymbol = spec.symbol
        }
        if window.frame != spec.frame {
            window.setFrame(spec.frame, display: false)
        }
        // After the frame, because the beacon is born at .zero and only learns
        // which bar it belongs to here. Set every pass rather than only on
        // change: a beacon created while the pointer is already resting on the
        // bar would otherwise appear at full opacity over an uncovered bar.
        window.alphaValue = peekAlpha(for: window.frame)
        if !window.isVisible {
            window.orderFrontRegardless()
        }
    }

    private func makeBeaconWindow() -> NSWindow {
        let window = NSWindow(contentRect: .zero, styleMask: .borderless,
                              backing: .buffered, defer: false)
        // One above the strip, so it draws over it. Clicks still fall through
        // to the real status item underneath.
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 2)
        window.ignoresMouseEvents = true
        window.isOpaque = false
        window.hasShadow = false
        window.backgroundColor = .clear
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]

        let view = NSImageView()
        view.imageScaling = .scaleProportionallyDown
        window.contentView = view
        return window
    }

    /// The glyph, tinted to read against the strip rather than against the bar.
    private static func beaconImage(named symbol: String) -> NSImage? {
        guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Nocturne")
                ?? NSImage(systemSymbolName: "moon.fill", accessibilityDescription: "Nocturne")
        else { return nil }

        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        let sized = image.withSymbolConfiguration(config) ?? image
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let tint = isDark ? NSColor.white : NSColor.black

        let tinted = NSImage(size: sized.size, flipped: false) { rect in
            sized.draw(in: rect)
            tint.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        tinted.isTemplate = false
        return tinted
    }

    private func rebuild() {
        guard isActive else { return }
        teardown()
        sync()
    }

    private func teardown() {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        beaconWindow?.orderOut(nil)
        beaconWindow = nil
        currentBeaconSymbol = nil
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
        window.alphaValue = peekAlpha(for: frame)   // see makeBeaconWindow
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
