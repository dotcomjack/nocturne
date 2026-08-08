// █ dcj · dotcomjack.com · MIT
import AppKit

/// How often the menu bar icon shimmers.
///
/// Named rather than numeric because the honest answer to "how many seconds"
/// is a feel, not a number. Nocturne exists to stop the menu bar catching your
/// eye, so the default is deliberately unhurried and `off` is a real choice
/// rather than a buried one.
enum ShimmerCadence: String, CaseIterable, Identifiable, Sendable {
    case off
    case often
    case occasionally
    case rarely

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off:          return "Off"
        case .often:        return "Often"
        case .occasionally: return "Occasionally"
        case .rarely:       return "Rarely"
        }
    }

    /// Seconds between sweeps.
    var interval: TimeInterval? {
        switch self {
        case .off:          return nil
        case .often:        return 10
        case .occasionally: return 30
        case .rarely:       return 120
        }
    }

    var detail: String {
        switch self {
        case .off:          return "The icon stays still."
        case .often:        return "A sweep every 10 seconds."
        case .occasionally: return "A sweep every 30 seconds."
        case .rarely:       return "A sweep every 2 minutes."
        }
    }
}

/// Sweeps an icy blue highlight down the menu bar icon.
///
/// The frames are **not** template images. A template is tinted wholesale by
/// AppKit, which is exactly what you want for a static glyph and exactly what
/// makes a coloured band impossible. So the frames carry their own colour: the
/// glyph is painted in the menu bar's own text colour and the band in
/// `Palette.icyDarkBlue`, and the resting glyph stays a template so it keeps
/// adapting for free when nothing is sweeping.
///
/// Because the colour is baked in, frames are cached per glyph *and*
/// appearance, and the cache is dropped when the appearance changes.
///
/// The frames are drawn from the resting image itself rather than re-derived
/// from the symbol name. That is not a shortcut, it is the fix for a real bug:
/// building them with `SymbolConfiguration(pointSize: 15)` produced glyphs 3pt
/// wider and 2pt taller than the resting one, so the status item resized on
/// every sweep and the icon visibly jumped.
@MainActor
final class ShimmerAnimator {

    /// One sweep, top to bottom.
    static let duration: TimeInterval = 0.7

    /// Enough frames to read as motion, few enough to stay cheap. 24 over 700ms
    /// is a frame every ~29ms.
    private static let frameCount = 24

    /// How much of the glyph the bright band covers, as a fraction of height.
    private static let bandHeight: CGFloat = 0.45

    /// Icy dark blue, the colour of the band.
    static let icyDarkBlue = NSColor(srgbRed: 0.247, green: 0.529, blue: 0.702, alpha: 1)  // #3F87B3

    private var cache: [String: [NSImage]] = [:]
    private var sweepTimer: Timer?
    private var scheduleTimer: Timer?
    private var frameIndex = 0

    /// Called with the image to show, or nil to restore the resting glyph.
    private let apply: (NSImage?) -> Void
    /// The symbol currently in the menu bar, used only as a cache key.
    private let currentSymbol: () -> String?
    /// The exact image the menu bar is showing at rest. Frames are drawn from
    /// this so they cannot differ in size from it.
    private let restingImage: () -> NSImage?
    /// Whether the menu bar is currently dark.
    private let isDark: () -> Bool

    init(currentSymbol: @escaping () -> String?,
         restingImage: @escaping () -> NSImage?,
         isDark: @escaping () -> Bool,
         apply: @escaping (NSImage?) -> Void) {
        self.currentSymbol = currentSymbol
        self.restingImage = restingImage
        self.isDark = isDark
        self.apply = apply
    }

    // MARK: - Scheduling

    private(set) var cadence: ShimmerCadence = .occasionally

    func setCadence(_ cadence: ShimmerCadence) {
        self.cadence = cadence
        reschedule()
    }

    func reschedule() {
        scheduleTimer?.invalidate()
        scheduleTimer = nil
        stopSweep()

        guard let interval = cadence.interval else { return }

        scheduleTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sweep() }
        }
        // A timer that only matters when it fires should not wake a sleeping
        // Mac to do it. The shimmer is decoration; the battery is not.
        scheduleTimer?.tolerance = interval * 0.25
    }

    func stop() {
        scheduleTimer?.invalidate()
        scheduleTimer = nil
        stopSweep()
    }

    // MARK: - The sweep

    /// Drop cached frames, for when the appearance changes and the baked-in
    /// colours are no longer right.
    func invalidate() { cache.removeAll() }

    /// Run one sweep now, whatever the cadence. Used to preview a change.
    func sweep() {
        guard let source = restingImage(), let symbol = currentSymbol(),
              let frames = frames(for: source, symbol: symbol), !frames.isEmpty
        else { return }

        stopSweep()
        frameIndex = 0

        let interval = Self.duration / Double(frames.count)
        sweepTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                guard self.frameIndex < frames.count else {
                    self.stopSweep()
                    self.apply(nil)          // back to the resting glyph
                    return
                }
                self.apply(frames[self.frameIndex])
                self.frameIndex += 1
            }
        }
    }

    private func stopSweep() {
        sweepTimer?.invalidate()
        sweepTimer = nil
    }

    // MARK: - Frames

    private func frames(for source: NSImage, symbol: String) -> [NSImage]? {
        let dark = isDark()
        let key = "\(symbol)|\(dark)"
        if let cached = cache[key] { return cached }

        // The menu bar tints a template with its own text colour. Since these
        // frames are not templates, resolve that colour ourselves.
        let glyphColor: NSColor = dark ? .white : .black

        let built = (0..<Self.frameCount).map { index in
            Self.frame(of: source,
                       progress: CGFloat(index) / CGFloat(Self.frameCount - 1),
                       glyphColor: glyphColor)
        }
        cache[key] = built
        return built
    }

    /// One frame: the glyph at full strength, with a soft band dipped at `progress`.
    ///
    /// `progress` runs 0 (band above the glyph) to 1 (band below it), so the
    /// highlight enters and leaves rather than appearing and vanishing.
    private static func frame(of glyph: NSImage, progress: CGFloat, glyphColor: NSColor) -> NSImage {
        let size = glyph.size

        let image = NSImage(size: size, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return true }

            // The glyph is the clip, so the gradient only ever paints the mark.
            glyph.draw(in: rect)
            context.setBlendMode(.sourceIn)

            // Travel from just above the top to just below the bottom.
            let travel = rect.height * (1 + bandHeight)
            let centre = rect.maxY - (progress * travel) + (rect.height * bandHeight / 2)
            let half = rect.height * bandHeight / 2

            let colors = [
                glyphColor.cgColor,
                icyDarkBlue.cgColor,
                glyphColor.cgColor,
            ] as CFArray

            guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                            colors: colors,
                                            locations: [0, 0.5, 1])
            else {
                glyphColor.setFill()
                rect.fill()
                return true
            }

            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: rect.midX, y: centre + half),
                end: CGPoint(x: rect.midX, y: centre - half),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            return true
        }

        // Deliberately NOT a template: a template would be repainted in a
        // single colour and the blue would vanish.
        image.isTemplate = false
        return image
    }
}
