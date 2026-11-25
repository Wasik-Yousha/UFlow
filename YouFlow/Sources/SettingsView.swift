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
                    Text("\(GlobalShortcut.Combo.pasteLast.symbol) pastes your last dictation again, if a paste didn't land.")
                    if app.settings.triggerKeyCode == nil {
                        Text("A modifier alone always holds — as a toggle it would fire on every incidental tap.")
                        if app.settings.modifierKeyCode == kVK_Function {
                            Text("A quick tap of Fn stays macOS's own (the emoji picker, by default); only a hold starts dictation.")
                        }
                    }
                }
                .foregroundStyle(.secondary)
            }

            Section {
                Picker("Language", selection: Binding(
                    get: { app.settings.language },
                    set: { app.settings.language = $0 }
                )) {
                    ForEach(SpeechLanguage.allCases, id: \.self) { language in
                        Text(language.label).tag(language)
                    }
                }
                .pickerStyle(.radioGroup) // four long labels don't fit segmented
                Text(app.settings.language.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if app.settings.language.usesWhisper {
                    Text(app.engineDetailText)
                        .font(.callout)
                        .foregroundStyle(Tok.C.accent)
                }

                Picker("Model", selection: Binding(
                    get: { app.settings.backend },
                    set: { app.settings.backend = $0 }
                )) {
                    ForEach(BackendPreference.allCases, id: \.self) { preference in
                        Text(preference.label).tag(preference)
                    }
                }
                .disabled(app.settings.language == .banglaOnly) // the only mode with no Apple model
                Text(app.settings.backend.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Model")
            } footer: {
                Text("Changing this reloads the on-device model, which takes a moment before the next recording.")
                    .foregroundStyle(.secondary)
            }

            CleanupSection(cleanup: app.cleanup)

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

                Toggle("Learn from my corrections", isOn: Binding(
                    get: { app.settings.learnFromCorrections },
                    set: { app.settings.learnFromCorrections = $0 }
                ))
                Text("When you fix a word UFlow misheard right after dictating — \u{201C}cloud code\u{201D} to \u{201C}Claude Code\u{201D} — it suggests a correction in the Dictionary tab for you to add or dismiss. To spot the fix it reads the text field once after pasting and again about 25 seconds later, or when you next dictate. Only the corrected word pairs are kept, never the text around them, and nothing leaves your Mac. Password fields are never read. Uses the Accessibility permission.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        // Fixed height, scrolling: the full form is taller than a laptop
        // screen, and a window sized to fit it left the bottom unreachable.
        .frame(width: 460, height: formHeight)
        .fixedSize(horizontal: false, vertical: formHeight == nil)
    }

    /// 640 pt and scrolling; a debug snapshot can ask for the whole form.
    private var formHeight: CGFloat? {
        #if DEBUG
        if ProcessInfo.processInfo.environment["UFLOW_SNAPSHOT_FULL"] != nil { return nil }
        #endif
        return 640
    }
}

/// Settings → Clean-up: the one model this Mac's memory suits, and its download.
private struct CleanupSection: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject var cleanup: CleanupController

    var body: some View {
        Section {
            Toggle("Clean up what I say", isOn: Binding(
                // Shown off until the model is installed: it can't run before.
                get: { app.settings.cleanupEnabled && cleanup.isReady },
                set: { app.settings.cleanupEnabled = $0 }
            ))
            .disabled(!cleanup.isReady)

            if cleanup.choices.count > 1 {
                Picker("Model", selection: Binding(
                    get: { cleanup.model },
                    set: { cleanup.choose($0) }
                )) {
                    ForEach(cleanup.choices, id: \.self) { choice in
                        Text("\(choice.displayName) — \(choice.tradeoff)").tag(choice)
                    }
                }
                LabeledContent("Download size") { Text(cleanup.sizeText).monospacedDigit() }
            } else {
                LabeledContent("Model") {
                    Text("\(cleanup.model.displayName) · \(cleanup.sizeText)")
                        .monospacedDigit()
                }
            }

            switch cleanup.phase {
            case .notDownloaded:
                LabeledContent("Status") {
                    Button("Download") { cleanup.startDownload() }
                }
                if let standIn = cleanup.standIn {
                    Text("Using \(standIn.displayName), already on this Mac, until this one is downloaded.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            case .downloading(let fraction):
                LabeledContent("Downloading") {
                    HStack(spacing: 8) {
                        ProgressView(value: fraction).frame(width: 140)
                        Text("\(Int(fraction * 100))%").monospacedDigit().foregroundStyle(.secondary)
                        Button("Cancel") { cleanup.cancelDownload() }
                    }
                }
            case .ready:
                LabeledContent("Status") {
                    HStack(spacing: 8) {
                        Text("Installed").foregroundStyle(Tok.C.accent)
                        Button("Remove") { cleanup.remove() }
                    }
                }
            case .failed(let reason):
                LabeledContent("Status") {
                    Button("Try again") { cleanup.startDownload() }
                }
                Text(reason)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Clean-up")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Removes stutters, false starts and corrected slips (\u{201C}at five, no sorry, six\u{201D} → \u{201C}at six\u{201D}), adds punctuation, and turns spoken lists into numbered ones. It only ever deletes words it can prove were slips — anything else stays exactly as you said it.")
                Text("Runs on your Mac. Picked for your \(cleanup.memoryText) of memory: 8 GB Macs get Gemma 4 E2B, 16 GB get E4B, and 18 GB and up can also choose 12B. Downloaded once from Hugging Face and checked; it loads while you talk and unloads when idle or when memory runs low.")
            }
            .foregroundStyle(.secondary)
        }
    }
}
