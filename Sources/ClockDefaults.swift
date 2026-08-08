import AppKit
import Foundation

/// Thin wrapper over Apple's `com.apple.menuextra.clock` preference domain.
///
/// Every key here was verified on macOS 26.3.1 by measuring the on-screen width
/// of Control Center's `Clock` window before and after the write, rather than by
/// reading documentation or eyeballing a screenshot:
///
///     baseline "Sat Aug 8 2:43 AM"   142pt
///     ShowDayOfWeek = false          119pt
///     ShowDate      = .never          76pt
///     ShowAMPM      = false           55pt
///     IsAnalog      = true            44pt
///
/// Three other routes were tested and do nothing on 26.3.1, so do not add them
/// back on the assumption that a blog post is still accurate:
/// `com.apple.controlcenter Clock = 8` (per-host), `NSStatusItem VisibleCC
/// Clock = false`, and a blank `DateFormat`. All three leave the clock at 142pt.
enum ClockDefaults {

    static let domain = "com.apple.menuextra.clock" as CFString

    enum Key: String {
        case isAnalog      = "IsAnalog"
        case showDayOfWeek = "ShowDayOfWeek"
        case showDate      = "ShowDate"
        case showAMPM      = "ShowAMPM"
        case showSeconds   = "ShowSeconds"
    }

    /// `ShowDate` is tri-state, not a boolean. Writing `false` to it silently
    /// means "when space allows", which is why it looks like it does nothing.
    enum DateVisibility: Int, CaseIterable, Identifiable, Sendable {
        case whenSpaceAllows = 0
        case always          = 1
        case never           = 2

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .whenSpaceAllows: return "When space allows"
            case .always:          return "Always"
            case .never:           return "Never"
            }
        }
    }

    // MARK: - Reading

    private static func value(_ key: Key) -> CFPropertyList? {
        CFPreferencesCopyValue(key.rawValue as CFString,
                               domain,
                               kCFPreferencesCurrentUser,
                               kCFPreferencesAnyHost)
    }

    static func bool(_ key: Key, fallback: Bool) -> Bool {
        (value(key) as? NSNumber)?.boolValue ?? fallback
    }

    static func int(_ key: Key, fallback: Int) -> Int {
        (value(key) as? NSNumber)?.intValue ?? fallback
    }

    static var dateVisibility: DateVisibility {
        DateVisibility(rawValue: int(.showDate, fallback: 0)) ?? .whenSpaceAllows
    }

    /// Whatever the user's clock looked like before Nocturne touched it.
    struct Snapshot: Codable, Sendable {
        var isAnalog: Bool
        var showDayOfWeek: Bool
        var showAMPM: Bool
        var showSeconds: Bool
        var showDate: Int
    }

    /// Reads the live system values.
    ///
    /// The fallbacks match what macOS itself shows when a key is absent, so a
    /// user who has never opened Clock Options still snapshots correctly.
    static func snapshot() -> Snapshot {
        Snapshot(isAnalog: bool(.isAnalog, fallback: false),
                 showDayOfWeek: bool(.showDayOfWeek, fallback: true),
                 showAMPM: bool(.showAMPM, fallback: true),
                 showSeconds: bool(.showSeconds, fallback: false),
                 showDate: int(.showDate, fallback: 0))
    }

    // MARK: - Writing

    /// Writes the key without applying it.
    ///
    /// Control Center caches this domain at launch, so a write alone changes
    /// nothing on screen. Callers batch their writes and then call
    /// `ControlCenter.reload()` once, which keeps a settings change to a single
    /// menu bar flicker instead of one per toggle.
    static func set(_ key: Key, _ newValue: CFPropertyList?) {
        CFPreferencesSetValue(key.rawValue as CFString,
                              newValue,
                              domain,
                              kCFPreferencesCurrentUser,
                              kCFPreferencesAnyHost)
        CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }

    static func set(_ key: Key, _ flag: Bool)  { set(key, flag as CFBoolean) }
    static func set(_ key: Key, _ number: Int) { set(key, number as CFNumber) }

    /// Writes a key and does not return until the preferences daemon has taken
    /// it, or a short deadline passes.
    ///
    /// `CFPreferencesSynchronize` can return before the value is durably
    /// committed, so calling `exit(0)` straight afterwards is a race. Measured
    /// on the shipped 1.0.0 build: quitting via SIGTERM left the clock analog in
    /// 2 of 21 runs, roughly 10%, because the process died before the write
    /// landed. That is the one thing this app must never do, since the app is
    /// then gone and cannot undo it.
    ///
    /// Only worth using on the quit path. Everywhere else the run loop keeps
    /// living and the ordinary `set` is fine.
    @discardableResult
    static func setAndConfirm(_ key: Key, _ flag: Bool, attempts: Int = 4) -> Bool {
        for attempt in 0..<max(1, attempts) {
            set(key, flag)

            // `CFPreferencesAppSynchronize` is the confirmation, not a read-back.
            //
            // An earlier version looped until `bool(key) == flag` and treated
            // that as proof the write had landed. It never could be:
            // `CFPreferencesCopyValue` is served from this process's own cache,
            // so the comparison is true on the first iteration whether or not
            // the daemon has committed anything. Measured across 8 runs, that
            // loop exited on iteration 1 every time, in 0.22ms to 0.37ms, which
            // means the retry and the timeout were decorative and a fixed sleep
            // was doing all the work.
            //
            // This call actually pushes to `cfprefsd` and reports whether the
            // flush succeeded, so a false return is a real signal worth retrying.
            if CFPreferencesAppSynchronize(domain) {
                // Small settle before the caller exits. The flush is
                // acknowledged, but the process is about to die, and this is the
                // one write that must survive.
                usleep(80_000)
                return true
            }

            usleep(UInt32(40_000 * (attempt + 1)))
        }
        return false
    }
}

/// Control Center owns the clock. Nothing in this domain applies until it
/// restarts, and it is a KeepAlive launch agent so it comes straight back.
enum ControlCenter {

    static let bundleIdentifier = "com.apple.controlcenter"

    /// Force-terminate rather than `terminate()`. Control Center is a UI agent
    /// with no quit handler, so the polite AppleEvent is simply ignored.
    static func reload() {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier) {
            app.forceTerminate()
        }
    }


}
