import SwiftUI

/// The main window: hardware deck on top, tabs, then the working area.
struct MainWindowView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case transcriptions, dictionary
        var id: String { rawValue }
        var title: String { self == .transcriptions ? "Transcriptions" : "Dictionary" }
    }

    @EnvironmentObject private var app: AppState
    @State private var tab: Tab

    /// Non-zero only when rendering a snapshot, so the meter has something to
    /// show in a still image.
    private let previewLevel: Double

    init() {
        #if DEBUG
        _tab = State(initialValue: Snapshot.isActive ? Snapshot.tab : .transcriptions)
        previewLevel = Snapshot.level
        #else
        _tab = State(initialValue: .transcriptions)
        previewLevel = 0
        #endif
    }

    var body: some View {
        ZStack(alignment: .top) {
            Tok.C.appBg.ignoresSafeArea()

            // The speakers sit behind the chassis and run past its lower edge,
            // exactly as they do on the real cabinet.
            SpeakerLayer()

            VStack(spacing: Tok.S.s8) {
                DeckView(previewLevel: previewLevel)
                TabStrip(selection: $tab)

                Group {
                    switch tab {
                    case .transcriptions: TranscriptionsView()
                    case .dictionary: DictionaryView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.horizontal, Tok.S.s40 + Tok.S.s32)
            .padding(.top, Tok.S.s12)
            .padding(.bottom, Tok.S.s16)
        }
        .frame(minWidth: Tok.L.windowMinWidth, minHeight: Tok.L.windowMinHeight)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Picks up edits made to dictionary.txt in a text editor.
            app.dictionary.reloadIfChanged()
        }
    }
}

// MARK: - Speakers

private struct SpeakerLayer: View {
    var body: some View {
        HStack {
            SpeakerGrille()
                .frame(width: Tok.L.speakerDiameter, height: Tok.L.speakerDiameter)
                .offset(x: -Tok.L.speakerDiameter * 0.34)
            Spacer()
            SpeakerGrille()
                .frame(width: Tok.L.speakerDiameter, height: Tok.L.speakerDiameter)
                .offset(x: Tok.L.speakerDiameter * 0.34)
        }
        .padding(.top, Tok.S.s20)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Tabs

private struct TabStrip: View {
    @Binding var selection: MainWindowView.Tab

    var body: some View {
        HStack(spacing: Tok.S.s8) {
            ForEach(MainWindowView.Tab.allCases) { tab in
                TabButton(tab: tab, isSelected: selection == tab) {
                    guard selection != tab else { return }
                    withAnimation(Tok.M.tab) { selection = tab }
                }
            }

            Spacer()

            HStack(spacing: Tok.S.s8) {
                Text("UFlow")
                    .tokType(Tok.T.tab)
                    .foregroundStyle(Tok.C.accent)
                Image(systemName: "waveform")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(Tok.C.accent)
                SettingsButton()
            }
            .padding(.trailing, -Tok.S.s12)
        }
        .padding(.horizontal, Tok.S.s12)
        .frame(height: Tok.L.tabStripHeight)
        .background(Tok.Grad.chassis, in: RoundedRectangle(cornerRadius: Tok.R.panel, style: .continuous))
        .emboss(Tok.R.panel)
    }
}

private struct SettingsButton: View {
    @Environment(\.openSettings) private var openSettings
    @State private var hovering = false

    var body: some View {
        Button {
            SoundKit.play(.tabSwitch)
            openSettings()
        } label: {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(hovering ? Tok.C.accent : Tok.C.textSecondary)
                .frame(width: Tok.L.searchHeight, height: Tok.L.searchHeight)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Settings\u{2026}")
        .onHover { hovering = $0 }
        .animation(Tok.M.hover, value: hovering)
    }
}

private struct TabButton: View {
    let tab: MainWindowView.Tab
    let isSelected: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button {
            SoundKit.play(.tabSwitch)
            action()
        } label: {
            Text(tab.title)
                .tokType(Tok.T.tab)
                .foregroundStyle(isSelected ? Tok.C.accent : Tok.C.textSecondary)
                .padding(.horizontal, Tok.S.s16)
                .frame(height: 30)
                .background(
                    isSelected || hovering ? Tok.C.panelFace : .clear,
                    in: RoundedRectangle(cornerRadius: Tok.R.panel, style: .continuous)
                )
                .overlay(alignment: .bottom) {
                    if isSelected {
                        Rectangle()
                            .fill(Tok.C.accent)
                            .frame(height: Tok.W.medium)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Tok.R.panel, style: .continuous))
                .emboss(Tok.R.panel)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Tok.M.hover, value: hovering)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
