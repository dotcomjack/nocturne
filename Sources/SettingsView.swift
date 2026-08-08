import ServiceManagement
import SwiftUI

struct SettingsView: View {

    @ObservedObject private var controller = NocturneController.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section("Mode") {
                Picker("Clock", selection: $controller.mode) {
                    ForEach(ClockMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()

                Text(controller.mode.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if controller.mode == .gone {
                Section("Experimental") {
                    Picker("Cover", selection: $controller.overlayFill) {
                        ForEach(OverlayController.Fill.allCases) { fill in
                            Text(fill.title).tag(fill)
                        }
                    }
                    Text(controller.overlayFill.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    Text("Gone draws a patch over Control Center's clock, so it leaves a faint seam where the bar shows through. Matching the bar exactly would mean asking for Screen Recording, which Nocturne will not do. Blind is cleaner if the seam bothers you.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Clock options") {
                Picker("Date", selection: $controller.dateVisibility) {
                    ForEach(ClockDefaults.DateVisibility.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                Toggle("Day of the week", isOn: $controller.showDayOfWeek)
                Toggle("AM/PM", isOn: $controller.showAMPM)
                Toggle("Seconds", isOn: $controller.showSeconds)

                Text("These are the same switches as System Settings \u{203A} Menu Bar \u{203A} Clock Options. Changing one restarts Control Center, so the menu bar blinks once.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        controller.launchAtLogin = newValue
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
            }
        }
        .formStyle(.grouped)
        .tint(Color(red: 0.549, green: 0.416, blue: 0.184)) // #8C6A2F
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
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
