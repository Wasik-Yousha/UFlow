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
                    ForEach(HotkeyManager.Trigger.letterKeys, id: \.code) { key in
                        Text(key.name).tag(key.code)
                    }
                }

                LabeledContent("Currently") {
                    Text(app.hotkeyDescription)
                        .foregroundStyle(Tok.C.accent)
                        .monospacedDigit()
                }
            } header: {
                Text("Hotkey")
            } footer: {
                Text("Tap once to start, tap again to stop. Works in any app; the text is typed where you were.")
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
}
