import Carbon.HIToolbox
import SwiftUI

/// Cmd+, — the hotkey and the model, plus the two switches the interface added.
struct SettingsView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        Form {
            Section {
                Picker("Hold", selection: Binding(
                    get: { app.settings.modifierKeyCode },
                    set: { app.settings.modifierKeyCode = $0 }
                )) {
                    ForEach(HotkeyManager.Trigger.modifierKeys, id: \.code) { modifier in
                        Text(modifier.name).tag(modifier.code)
                    }
                }

                Picker("And press", selection: Binding(
                    get: { app.settings.triggerKeyCode },
                    set: { app.settings.triggerKeyCode = $0 }
                )) {
                    Text("Nothing — \(HotkeyManager.Trigger.modifierName(app.settings.modifierKeyCode)) alone").tag(Int?.none)
                    ForEach(HotkeyManager.Trigger.letterKeys, id: \.code) { key in
                        Text(key.name).tag(Optional(key.code))
                    }
                }

                LabeledContent("Currently") {
                    Text(app.hotkeyDescription)
                        .foregroundStyle(Tok.C.accent)
                        .monospacedDigit()
                }

                Picker("Behavior", selection: Binding(
                    get: { app.settings.hotkeyMode },
                    set: { app.settings.hotkeyMode = $0 }
                )) {
                    ForEach(HotkeyMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(app.settings.triggerKeyCode == nil)
            } header: {
                Text("Hotkey")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(app.settings.effectiveHotkeyMode.detail + " Works in any app; the text is typed where you were.")
                    if app.settings.triggerKeyCode == nil {
                        Text("A modifier alone always holds — as a toggle it would fire on every incidental tap.")
                        if app.settings.modifierKeyCode == kVK_Function {
                            Text("Fn alone also triggers macOS's own Globe-key action (Emoji & Symbols, by default). Pick Control, Option, or Command above to avoid that, or turn it off in System Settings → Keyboard → Press 🌐 key to → No Action.")
                        }
                    }
                }
                .foregroundStyle(.secondary)
            }

            Section {
                Picker("Model", selection: Binding(
                    get: { app.settings.backend },
                    set: { app.settings.backend = $0 }
                )) {
                    ForEach(BackendPreference.allCases, id: \.self) { preference in
                        Text(preference.label).tag(preference)
                    }
                }
                Text(app.settings.backend.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                if app.settings.backend.usesParakeet {
                    parakeetModelRow
                }
            } header: {
                Text("Model")
            } footer: {
                Text("Changing this reloads the on-device model, which takes a moment before the next recording.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Appearance", selection: Binding(
                    get: { app.settings.appearance },
                    set: { app.settings.appearance = $0 }
                )) {
                    ForEach(AppearancePreference.allCases, id: \.self) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.segmented)

                Text(app.settings.appearance.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Toggle("Transport sounds", isOn: Binding(
                    get: { app.settings.soundEnabled },
                    set: { app.settings.soundEnabled = $0 }
                ))
                Toggle("Show menu bar item", isOn: Binding(
                    get: { app.settings.showMenuBarItem },
                    set: { app.settings.showMenuBarItem = $0 }
                ))
                Toggle("Launch at login", isOn: Binding(
                    get: { app.settings.launchAtLogin },
                    set: { app.settings.launchAtLogin = $0 }
                ))
            } header: {
                Text("Interface")
            } footer: {
                Text("Appearance applies to the window and the floating recorder bar together.")
                    .foregroundStyle(.secondary)
            }

            Section("Dictionary") {
                LabeledContent("File") {
                    Button("Reveal dictionary.txt") {
                        Store.reveal(app.dictionary.fileURL)
                    }
                }
                Text("\(app.dictionary.entries.count) entries. Edit the file in any text editor — UFlow re-reads it when you come back.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Parakeet's weights are a 600 MB download that happens once. Without this
    /// the transfer starts silently on the next recording, which reads as a hang.
    @ViewBuilder
    private var parakeetModelRow: some View {
        if let fraction = app.modelDownloadProgress {
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: fraction)
                Text("Downloading model… \(Int(fraction * 100))%")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } else if app.parakeetModelIsDownloaded {
            Label("Model downloaded", systemImage: "checkmark.circle.fill")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            HStack {
                Text("Model not downloaded yet")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Download") { app.downloadParakeetModel() }
            }
        }
    }

}
