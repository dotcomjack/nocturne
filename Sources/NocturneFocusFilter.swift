// █ dcj · dotcomjack.com · MIT
import AppIntents
import Foundation

/// What a Focus can switch Nocturne to. `ClockMode` minus `off`.
///
/// `off` is not offered on purpose. "When a Focus starts, show the clock" is a
/// setting that does nothing for anyone who wanted this feature, and having it
/// in the list mostly produces people who pick it by accident and then report
/// that Focus filters are broken.
enum FocusFilterMode: String, AppEnum {
    case blind
    case gone
    case hideEverything

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Nocturne mode" }

    static var caseDisplayRepresentations: [FocusFilterMode: DisplayRepresentation] { [
        .blind: DisplayRepresentation(title: "Blind",
                                      subtitle: "An analog dial. The time is there, you just cannot read it."),
        .gone: DisplayRepresentation(title: "Gone",
                                     subtitle: "Just the clock, covered."),
        .hideEverything: DisplayRepresentation(title: "Hide everything",
                                               subtitle: "The whole menu bar goes blank."),
    ] }

    var clockMode: ClockMode {
        switch self {
        case .blind: return .blind
        case .gone: return .gone
        case .hideEverything: return .naked
        }
    }
}

/// Nocturne's Focus filter.
///
/// This is the whole of Follow Focus. Turn on a Focus that has this filter and
/// macOS runs it; end that Focus and macOS runs it again. Because Focus syncs
/// over iCloud, switching Do Not Disturb on from an iPhone turns it on here and
/// the filter fires on this Mac, which is the cross-device half of the feature
/// with nothing built for it.
///
/// ## Why this and not the two obvious alternatives
///
/// **Reading `~/Library/DoNotDisturb/DB/Assertions.json` is a trap.** It is the
/// answer every search result gives, it is plain JSON, and it works perfectly
/// right up until you ship. That directory is TCC protected, so the read needs
/// **Full Disk Access**. Measured on macOS 26.4 with the identical binary in
/// two launch contexts:
///
///     launched as                    isReadableFile   open(O_EVTONLY)
///     bare binary from Terminal      true             fd 3
///     .app via `open`                false            -1, EPERM
///
/// and the kernel agrees, in `log show`:
///
///     System Policy: Nocturne(99186) deny(1) file-read-data
///       /Users/…/Library/DoNotDisturb/DB/Assertions.json
///
/// It reads fine from a shell only because Terminal already holds Full Disk
/// Access, which is the *same trap this project already documents* for
/// `kCGWindowName` in `ClockWindowLocator`. Test it as a real app bundle, not
/// from your shell. A clock utility asking for Full Disk Access is absurd, so
/// that route is closed rather than inconvenient.
///
/// **`INFocusStatusCenter` costs a permission and answers too little.** It
/// prompts, it reports only a single optional boolean so it can never say
/// *which* Focus, and unauthorised it does not fail, it lies: measured on 26.4,
/// `focusStatus.isFocused` returned `Optional(false)` continuously while Do Not
/// Disturb was genuinely on.
///
/// A Focus filter costs no permission at all, and it puts Nocturne in System
/// Settings under Focus beside Mail, Messages and Safari.
///
/// ## The undocumented part: telling "Focus started" from "Focus ended"
///
/// Apple's docs say the system notifies you "when this Focus turns on or off"
/// and never say how to tell which. Measured, both calls are otherwise
/// identical, so with a non-optional parameter they are genuinely
/// indistinguishable:
///
///     @Parameter(default: .hideEverything) var mode: FocusFilterMode
///     Focus ON   perform() mode=hideEverything
///     Focus OFF  perform() mode=hideEverything      <- same, useless
///
/// Make the parameter **optional** and the difference appears:
///
///     @Parameter var mode: FocusFilterMode?
///     Focus ON   perform() mode=Optional(hideEverything)
///     Focus OFF  perform() mode=nil
///
/// So `mode == nil` is the deactivation signal, and that is the only reason
/// this parameter is optional. Do not give it a default value to tidy up the
/// System Settings picker: it would restore the first behaviour, the app would
/// engage on both edges and never release, and a Focus would put the menu bar
/// away permanently.
///
/// `current` follows the same rule, which is what makes a pull-based check
/// possible at launch and after sleep. It also had to be measured, because with
/// the non-optional parameter it kept reporting the configured mode long after
/// the Focus had ended.
struct NocturneFocusFilter: SetFocusFilterIntent {

    static var title: LocalizedStringResource = "Hide the menu bar"

    static var description: IntentDescription? = IntentDescription(
        "Put the menu bar clock away while this Focus is on, and bring it back when the Focus ends.")

    /// Optional, load-bearing. See the type comment: `nil` is how the Focus
    /// ending is detected. There is no other signal.
    @Parameter(title: "Mode")
    var mode: FocusFilterMode?

    var displayRepresentation: DisplayRepresentation {
        guard let mode else { return DisplayRepresentation(title: "Off") }
        return DisplayRepresentation(title: FocusFilterMode.caseDisplayRepresentations[mode]?.title
                                     ?? "\(mode.rawValue)")
    }

    func perform() async throws -> some IntentResult {
        await FocusFilterBridge.apply(mode)
        return .result()
    }
}

/// Connects the Focus filter to the controller, and covers the cases where the
/// filter cannot call us.
///
/// `perform()` is the fast path and it is reliable while the app is running.
/// It cannot cover two situations, and both are ordinary rather than exotic:
///
/// 1. **Nocturne was not running when the Focus changed.** Nothing is delivered
///    later, so the state has to be read at launch.
/// 2. **The machine was asleep.** Close the lid inside a Focus, open it after
///    the Focus has ended, and there is no call to catch up on.
///
/// `refresh()` handles both by asking the system directly. The periodic sweep
/// is a backstop rather than the mechanism: measured, a `current` read costs
/// 1ms to 11ms, so once every 30 seconds is not worth optimising away for the
/// certainty it buys.
enum FocusFilterBridge {

    /// Backstop cadence. Not the mechanism, see the type comment.
    static let sweepInterval: TimeInterval = 30

    /// Push the live filter state into the controller.
    ///
    /// `current` throws `SetFocusFilterIntentError.notFound` when the filter is
    /// not configured on any Focus at all, and returns a `nil` mode when it is
    /// configured but no such Focus is running. Both mean the same thing to us,
    /// so both collapse to `nil` rather than being told apart.
    static func refresh() {
        Task { @MainActor in
            let live = try? await NocturneFocusFilter.current
            apply(live?.mode)
        }
    }

    @MainActor
    static func apply(_ mode: FocusFilterMode?) {
        NocturneController.shared.focusFilterChanged(to: mode?.clockMode)
    }
}
