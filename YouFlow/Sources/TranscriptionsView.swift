import AppKit
import SwiftUI

/// Past transcriptions: searchable, copyable, and honest about what the
/// dictionary changed.
struct TranscriptionsView: View {
    /// What the control beside the search field offers.
    enum Filter: String, CaseIterable, Identifiable {
        case newest, oldest, corrected
        var id: String { rawValue }
        var label: String {
            switch self {
            case .newest: "Newest first"
            case .oldest: "Oldest first"
            case .corrected: "Only corrected"
            }
        }
    }

    @EnvironmentObject private var app: AppState
    @State private var query = ""
    @State private var filter: Filter = .newest

    private var results: [TranscriptRecord] {
        var records = app.transcripts.records

        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            records = records.filter {
                $0.text.localizedCaseInsensitiveContains(trimmed)
                    || $0.engine.localizedCaseInsensitiveContains(trimmed)
            }
        }

        switch filter {
        case .newest: break                                    // already newest-first
        case .oldest: records.reverse()
        case .corrected: records = records.filter { !$0.corrections.isEmpty }
        }
        return records
    }

    private var emptyDetail: String {
        if app.transcripts.records.isEmpty {
            return "Press RECORD, or use \(app.hotkeyDescription) from any app."
        }
        if filter == .corrected {
            return "No transcription here has been changed by the dictionary yet."
        }
        return "No transcription contains \u{201C}\(query)\u{201D}."
    }

    var body: some View {
        VStack(spacing: Tok.S.s12) {
            HStack(spacing: Tok.S.s12) {
                SearchField(placeholder: "Search transcriptions", text: $query)
                FilterButton(selection: $filter)
            }

            if results.isEmpty {
                EmptyState(
                    icon: "waveform",
                    title: app.transcripts.records.isEmpty ? "No recordings yet" : "Nothing matches",
                    detail: emptyDetail
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: Tok.S.s8) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, record in
                            TranscriptRow(record: record, accent: Tok.Brand.cycled(index))
                                .transition(.opacity)
                        }
                    }
                    .padding(.bottom, Tok.S.s8)
                }
                .scrollContentBackground(.hidden)
            }

            Spacer(minLength: 0)

            Footer(
                count: app.transcripts.records.count,
                noun: ("recording", "recordings"),
                action: app.transcripts.records.isEmpty ? nil : ("Delete all", .delete, {
                    withAnimation(Tok.M.listRow) { app.transcripts.deleteAll() }
                })
            )
        }
        .animation(Tok.M.listRow, value: results.count)
    }
}

// MARK: - Row

private struct TranscriptRow: View {
    let record: TranscriptRecord
    let accent: Color

    @State private var hovering = false
    @State private var justCopied = false
    @State private var copyHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: Tok.S.s12) {
            ZStack {
                Circle().fill(accent.opacity(0.16))
                Circle().strokeBorder(accent.opacity(0.45), lineWidth: Tok.W.hairline)
                Image(systemName: "mic.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(accent)
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: Tok.S.s6) {
                HStack(alignment: .firstTextBaseline, spacing: Tok.S.s8) {
                    Text(record.engine)
                        .tokType(Tok.T.meta)
                        .foregroundStyle(Tok.C.engineTag)
                    Text(record.durationLabel)
                        .tokType(Tok.T.caption)
                        .foregroundStyle(Tok.C.textSecondary)
                        .monospacedDigit()

                    Spacer(minLength: Tok.S.s12)

                    Text(record.timeLabel)
                        .tokType(Tok.T.caption)
                        .foregroundStyle(Tok.C.textSecondary)
                        .monospacedDigit()

                    Button {
                        SoundKit.play(.copy)
                        copy()
                    } label: {
                        Image(systemName: justCopied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(copyHovering ? Tok.C.danger : Tok.C.textSecondary)
                            .frame(width: 20, height: 20)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .help("Copy")
                    .onHover { copyHovering = $0 }
                    .animation(Tok.M.hover, value: copyHovering)

                    RowMenu(record: record)
                        .opacity(hovering ? 1 : 0.35)
                }

                if !record.text.isEmpty {
                    Text(record.text)
                        .tokType(Tok.T.body)
                        .foregroundStyle(Tok.C.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }

                if !record.corrections.isEmpty {
                    CorrectionStrip(corrections: record.corrections)
                }
            }
        }
        .padding(Tok.S.s12)
        .background(
            hovering ? Tok.C.surfaceRaised : Tok.C.surface,
            in: RoundedRectangle(cornerRadius: Tok.R.card, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: Tok.R.card, style: .continuous)
                .strokeBorder(Tok.C.hairline, lineWidth: Tok.W.hairline)
        }
        .tokShadow(Tok.Sh.card)
        .onHover { hovering = $0 }
        .animation(Tok.M.hover, value: hovering)
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(record.text, forType: .string)
        justCopied = true
        Task {
            try? await Task.sleep(for: .seconds(1.4))
            justCopied = false
        }
    }
}

/// What the dictionary changed on this transcript, and how often.
private struct CorrectionStrip: View {
    let corrections: [AppliedCorrection]

    var body: some View {
        HStack(alignment: .center, spacing: Tok.S.s8) {
            Text("Corrected")
                .tokType(Tok.T.meta)
                .foregroundStyle(Tok.C.corrected)

            ForEach(corrections) { correction in
                HStack(spacing: Tok.S.s6) {
                    Text(correction.heard)
                        .foregroundStyle(Tok.C.textSecondary)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Tok.C.textTertiary)
                    Text(correction.written)
                        .foregroundStyle(Tok.C.textPrimary)
                    if correction.count > 1 {
                        Text("\u{00D7}\(correction.count)")
                            .foregroundStyle(Tok.C.textTertiary)
                    }
                }
                .tokType(Tok.T.caption)
                .padding(.horizontal, Tok.S.s8)
                .padding(.vertical, Tok.S.s4)
                .background(
                    Tok.C.corrected.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: Tok.R.chip, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: Tok.R.chip, style: .continuous)
                        .strokeBorder(Tok.C.corrected.opacity(0.35), lineWidth: Tok.W.hairline)
                }
            }
        }
    }
}

private struct RowMenu: View {
    @EnvironmentObject private var app: AppState
    let record: TranscriptRecord

    var body: some View {
        Menu {
            Button("Copy text") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(record.text, forType: .string)
                SoundKit.play(.copy)
            }
            Divider()
            Button("Delete", role: .destructive) {
                SoundKit.play(.delete)
                withAnimation(Tok.M.listRow) { app.transcripts.delete(record) }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .rotationEffect(.degrees(90))
                .foregroundStyle(Tok.C.textSecondary)
                .frame(width: 20, height: 20)
                .contentShape(.rect)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 20)
    }
}

// =============================================================================
// MARK: - Shared list furniture
// =============================================================================

/// The count-and-action bar under both lists.
struct Footer: View {
    let count: Int
    /// Singular and plural given explicitly — "entry" does not pluralise by
    /// bolting an s on the end.
    let noun: (one: String, many: String)
    let action: (title: String, sound: Tok.Sfx, run: () -> Void)?

    var body: some View {
        HStack {
            Text("\(count) \(count == 1 ? noun.one : noun.many)")
                .tokType(Tok.T.count)
                .foregroundStyle(Tok.C.textSecondary)
            Spacer()
            if let action {
                TokTextButton(title: action.title, tint: Tok.C.danger, sound: action.sound, action: action.run)
            }
        }
        .padding(.horizontal, Tok.S.s12)
        .frame(height: Tok.L.footerHeight)
        .background(Tok.C.surface, in: RoundedRectangle(cornerRadius: Tok.R.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Tok.R.card, style: .continuous)
                .strokeBorder(Tok.C.hairline, lineWidth: Tok.W.hairline)
        }
    }
}

struct EmptyState: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: Tok.S.s8) {
            Image(systemName: icon)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(Tok.C.textTertiary)
            Text(title)
                .tokType(Tok.T.meta)
                .foregroundStyle(Tok.C.textSecondary)
            Text(detail)
                .tokType(Tok.T.body)
                .foregroundStyle(Tok.C.textTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Tok.S.s32)
    }
}

/// Sort and filter, in the square control the reference puts beside search.
private struct FilterButton: View {
    @Binding var selection: TranscriptionsView.Filter
    @State private var hovering = false

    var body: some View {
        Menu {
            Picker("", selection: $selection) {
                ForEach(TranscriptionsView.Filter.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(selection == .newest ? Tok.C.textSecondary : Tok.C.accent)
                .frame(width: Tok.L.searchHeight, height: Tok.L.searchHeight)
                .background(
                    hovering ? Tok.C.surfaceRaised : Tok.C.surface,
                    in: RoundedRectangle(cornerRadius: Tok.R.control, style: .continuous)
                )
                .emboss(Tok.R.control)
                .contentShape(.rect)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: Tok.L.searchHeight)
        .onHover { hovering = $0 }
        .onChange(of: selection) { _, _ in SoundKit.play(.tabSwitch) }
        .help("Sort and filter")
    }
}
