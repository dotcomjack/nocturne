import ServiceManagement
import SwiftUI

/// Nocturne's palette. Bronze on near-black, matching the app icon.
enum Palette {
    static let accent      = Color(red: 0.784, green: 0.639, blue: 0.400)  // #C8A366
    static let accentDeep  = Color(red: 0.549, green: 0.416, blue: 0.184)  // #8C6A2F

    static func accent(for scheme: ColorScheme) -> Color {
        scheme == .dark ? accent : accentDeep
    }
}

struct SettingsView: View {

    @ObservedObject private var controller = NocturneController.shared
    @Environment(\.colorScheme) private var scheme
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginItemsBlocked = false

    private var accent: Color { Palette.accent(for: scheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider().opacity(0.5)

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    modeSection
                    if controller.mode == .gone { goneSection }
                    clockOptionsSection
                    generalSection
                }
                .padding(20)
            }
        }
        .frame(width: 430, height: 880)   // tallest state is Gone plus the login warning
        // The user may have changed Clock Options in System Settings since we
        // last looked. Pull the live values in so the panel never lies.
        .onAppear {
            controller.resyncClockOptions()
            launchAtLogin = SMAppService.mainApp.status == .enabled
            loginItemsBlocked = false
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Crescent()
                .fill(accent)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text("Nocturne")
                    .font(.system(size: 15, weight: .semibold))
                Text("Stop the clock telling you how late it is")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    // MARK: - Mode

    private var modeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Mode", accent: accent)

            VStack(spacing: 6) {
                ForEach(ClockMode.allCases) { mode in
                    ModeRow(mode: mode,
                            isSelected: controller.mode == mode,
                            accent: accent) {
                        controller.mode = mode
                    }
                }
            }
        }
    }

    // MARK: - Gone

    private var goneSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Cover", accent: accent)

            Picker("", selection: $controller.overlayFill) {
                ForEach(OverlayController.Fill.allCases) { fill in
                    Text(fill.title).tag(fill)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Note(controller.overlayFill.detail)
            Note("Gone draws a patch over the clock, so it leaves a faint seam. Matching the bar exactly would mean asking for Screen Recording, which Nocturne will not do.")
        }
    }

    // MARK: - Clock options

    private var clockOptionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Clock options", accent: accent)

            VStack(spacing: 0) {
                Row {
                    Text("Date")
                    Spacer()
                    Picker("", selection: $controller.dateVisibility) {
                        ForEach(ClockDefaults.DateVisibility.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 168)
                }
                Divider().opacity(0.35)
                SwitchRow("Day of the week", isOn: $controller.showDayOfWeek)
                Divider().opacity(0.35)
                SwitchRow("AM/PM", isOn: $controller.showAMPM)
                Divider().opacity(0.35)
                SwitchRow("Seconds", isOn: $controller.showSeconds)
            }
            .tint(accent)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.09)))

            Note("The same switches as System Settings \u{203A} Menu Bar \u{203A} Clock Options. Nocturne adopts whatever you already had the first time it runs. Changing one restarts Control Center, so the menu bar blinks once.")
        }
    }

    // MARK: - General

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("General", accent: accent)

            VStack(spacing: 0) {
                SwitchRow("Launch at login", isOn: $launchAtLogin)
                    .tint(accent)
                    .onChange(of: launchAtLogin) { _, newValue in
                        // Snapping the switch back re-enters this handler, so
                        // bail on that corrective pass. Without the guard the
                        // second pass recomputed the warning flag to false, so
                        // the "macOS is blocking this" row could never appear,
                        // and worse, it called launchAtLogin = false again,
                        // which unregisters a request that was merely pending
                        // approval.
                        guard newValue != (SMAppService.mainApp.status == .enabled) else { return }

                        controller.launchAtLogin = newValue
                        let actual = SMAppService.mainApp.status == .enabled
                        loginItemsBlocked = (newValue != actual)
                        if launchAtLogin != actual { launchAtLogin = actual }
                    }

                if loginItemsBlocked {
                    Divider().opacity(0.35)
                    Row {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("macOS is blocking this.")
                                .font(.system(size: 12, weight: .medium))
                            Text("Nocturne has to be allowed under Login Items first.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Open") { SMAppService.openSystemSettingsLoginItems() }
                            .controlSize(.small)
                    }
                }
                if controller.canRestoreOriginalClock {
                    Divider().opacity(0.35)
                    Row {
                        Text("Restore clock to how it was")
                        Spacer()
                        Button("Restore") { controller.restoreOriginalClock() }
                            .controlSize(.small)
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.09)))
        }
    }
}

// MARK: - Pieces

private struct SectionLabel: View {
    let text: String
    let accent: Color
    init(_ text: String, accent: Color) { self.text = text; self.accent = accent }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(1.3)
            .foregroundStyle(accent)
    }
}

private struct Note: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct Row<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 10) { content }
            .font(.system(size: 13))
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
    }
}

/// Label hard left, switch hard right. A bare `Toggle` in an `HStack` centres
/// the pair instead, which reads as a mistake.
private struct SwitchRow: View {
    let title: String
    @Binding var isOn: Bool

    init(_ title: String, isOn: Binding<Bool>) {
        self.title = title
        self._isOn = isOn
    }

    var body: some View {
        Row {
            Text(title)
            Spacer(minLength: 0)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }
}

private struct ModeRow: View {
    let mode: ClockMode
    let isSelected: Bool
    let accent: Color
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(isSelected ? accent : Color.secondary.opacity(0.55))
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 2) {
                    Text(mode.title)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    Text(mode.detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? accent.opacity(0.10)
                                     : Color.primary.opacity(hovering ? 0.06 : 0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? accent.opacity(0.55) : Color.primary.opacity(0.09))
            )
        }
        .buttonStyle(.plain)
        // Colour only on hover, never geometry. Nothing moves under the cursor.
        .onHover { hovering = $0 }
    }
}

/// The app mark, drawn rather than shipped as an image so it stays crisp and
/// picks up the current accent colour.
struct Crescent: Shape {
    func path(in rect: CGRect) -> Path {
        let r = min(rect.width, rect.height) / 2
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let bite = CGPoint(x: c.x + r * 0.58, y: c.y)

        var path = Path()
        path.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        path.addEllipse(in: CGRect(x: bite.x - r * 1.02, y: bite.y - r * 1.02,
                                   width: r * 2.04, height: r * 2.04))
        // even-odd over two discs gives XOR; clipping to the moon leaves the
        // crescent. Rotate slightly so it reads as a moon, not a logo.
        return path
            .intersection(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r,
                                                 width: r * 2, height: r * 2)),
                          eoFill: true)
            .applying(CGAffineTransform(translationX: -c.x, y: -c.y)
                .concatenating(CGAffineTransform(rotationAngle: -0.32))
                .concatenating(CGAffineTransform(translationX: c.x, y: c.y)))
    }
}

/// A plain `NSWindow` host. Nocturne is an `LSUIElement` agent, so it has no
/// menu bar of its own and cannot rely on SwiftUI's `Settings` scene showing up.
@MainActor
final class SettingsWindow {

    static let shared = SettingsWindow()

    private var window: NSWindow?

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView())
            let window = NSWindow(contentViewController: hosting)
            window.title = "Nocturne"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }

        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
