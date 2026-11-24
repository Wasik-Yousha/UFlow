import SwiftUI

/// Teach it words it keeps getting wrong.
struct DictionaryView: View {
    @EnvironmentObject private var app: AppState
    @State private var query = ""
    @State private var editing: DictionaryEntry?
    @State private var isAdding = false

    private var results: [DictionaryEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return app.dictionary.entries }
        return app.dictionary.entries.filter {
            $0.match.localizedCaseInsensitiveContains(trimmed)
                || $0.replacement.localizedCaseInsensitiveContains(trimmed)
        }
    }

    var body: some View {
        VStack(spacing: Tok.S.s12) {
            HStack(spacing: Tok.S.s12) {
                SearchField(placeholder: "Search dictionary", text: $query)
                TokTextButton(title: "+ Add", sound: .add, bordered: true) { isAdding = true }
                    .padding(.horizontal, Tok.S.s8)
                    .frame(height: Tok.L.searchHeight)
                    .background(Tok.C.surface, in: RoundedRectangle(cornerRadius: Tok.R.control, style: .continuous))
                    .emboss(Tok.R.control)
            }

            if !app.suggestions.suggestions.isEmpty {
                SuggestionsCard()
            }

            if results.isEmpty {
                EmptyState(
                    icon: "character.book.closed",
                    title: app.dictionary.entries.isEmpty ? "Nothing taught yet" : "Nothing matches",
                    detail: app.dictionary.entries.isEmpty
                        ? "Add a name, a product, or a phrase it keeps mishearing."
                        : "No entry contains \u{201C}\(query)\u{201D}."
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, entry in
                            DictionaryRow(
                                entry: entry,
                                accent: Tok.Brand.cycled(index),
                                isLast: index == results.count - 1,
                                edit: { editing = entry }
                            )
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .background(Tok.C.surface, in: RoundedRectangle(cornerRadius: Tok.R.card, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Tok.R.card, style: .continuous)
                        .strokeBorder(Tok.C.hairline, lineWidth: Tok.W.hairline)
                }
            }

            Spacer(minLength: 0)

            Footer(
                count: app.dictionary.entries.count,
                noun: ("entry", "entries"),
                action: ("Reveal dictionary.txt", .copy, { Store.reveal(app.dictionary.fileURL) })
            )
        }
        .animation(Tok.M.listRow, value: results.count)
        .sheet(isPresented: $isAdding) {
            EntryEditor(entry: nil) { app.dictionary.add($0) }
        }
        .sheet(item: $editing) { entry in
            EntryEditor(entry: entry) { app.dictionary.update($0) }
        }
    }
}

// MARK: - Row

private struct DictionaryRow: View {
    @EnvironmentObject private var app: AppState
    let entry: DictionaryEntry
    let accent: Color
    let isLast: Bool
    let edit: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: Tok.S.s12) {
            Circle()
                .fill(entry.isEnabled ? accent : Tok.C.textTertiary.opacity(0.4))
                .frame(width: 7, height: 7)

            Text(entry.kind.label)
                .tokType(Tok.T.micro)
                .foregroundStyle(Tok.C.textSecondary)
                .frame(width: 34, alignment: .leading)

            HStack(spacing: Tok.S.s8) {
                Text(entry.match)
                    .tokType(Tok.T.term)
                    .foregroundStyle(entry.kind == .fix ? Tok.C.textSecondary : Tok.C.textPrimary)

                if entry.kind == .fix {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Tok.C.textTertiary)
                    Text(entry.replacement)
                        .tokType(Tok.T.term)
                        .foregroundStyle(Tok.C.textPrimary)
                }
            }
            .opacity(entry.isEnabled ? 1 : 0.5)

            Spacer(minLength: Tok.S.s12)

            if hovering {
                HStack(spacing: Tok.S.s16) {
                    TokTextButton(title: "Edit", tint: Tok.C.textSecondary, sound: .tabSwitch, action: edit)
                    TokTextButton(
                        title: entry.isEnabled ? "Off" : "On",
                        tint: Tok.C.textSecondary,
                        sound: .tabSwitch
                    ) {
                        app.dictionary.toggle(entry)
                    }
                    TokTextButton(title: "Delete", tint: Tok.C.danger, sound: .delete) {
                        withAnimation(Tok.M.listRow) { app.dictionary.delete(entry) }
                    }
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, Tok.S.s12)
        .frame(minHeight: Tok.L.rowMinHeight)
        .background(hovering ? Tok.C.surfaceRaised : .clear)
        .overlay(alignment: .bottom) {
            if !isLast {
                Rectangle()
                    .fill(Tok.C.hairline)
                    .frame(height: Tok.W.hairline)
                    .padding(.horizontal, Tok.S.s12)
            }
        }
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .onTapGesture(count: 2, perform: edit)
        .animation(Tok.M.hover, value: hovering)
    }
}

// MARK: - Suggestions

/// Fixes proposed from the user's own corrections ("Learn from my
/// corrections"). Nothing joins the dictionary until Add is pressed.
private struct SuggestionsCard: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Suggested from your corrections")
                .tokType(Tok.T.micro)
                .foregroundStyle(Tok.C.textSecondary)
                .padding(.horizontal, Tok.S.s12)
                .padding(.top, Tok.S.s8)
                .padding(.bottom, Tok.S.s4)

            // Up to three rows as they are; beyond that they scroll, so the
            // dictionary below stays in view.
            if app.suggestions.suggestions.count <= 3 {
                rows
            } else {
                ScrollView { rows }
                    .frame(height: Tok.L.rowMinHeight * 3.5)
            }
        }
        .background(Tok.C.surface, in: RoundedRectangle(cornerRadius: Tok.R.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Tok.R.card, style: .continuous)
                .strokeBorder(Tok.C.corrected.opacity(0.5), lineWidth: Tok.W.hairline)
        }
    }

    private var rows: some View {
        LazyVStack(spacing: 0) {
            ForEach(app.suggestions.suggestions) { suggestion in
                SuggestionRow(suggestion: suggestion)
            }
        }
    }
}

private struct SuggestionRow: View {
    @EnvironmentObject private var app: AppState
    let suggestion: CorrectionSuggestion

    /// The same check the editor shows before saving an entry.
    private var risk: DictionaryEntry.Risk? {
        DictionaryEntry.risk(kind: .fix, match: suggestion.heard, replacement: suggestion.written)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Tok.S.s12) {
            VStack(alignment: .leading, spacing: Tok.S.s2) {
                HStack(spacing: Tok.S.s8) {
                    Text(suggestion.heard)
                        .tokType(Tok.T.term)
                        .foregroundStyle(Tok.C.textSecondary)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Tok.C.textTertiary)
                    Text(suggestion.written)
                        .tokType(Tok.T.term)
                        .foregroundStyle(Tok.C.textPrimary)
                    if suggestion.count > 1 {
                        Text("\(suggestion.count)\u{00D7}")
                            .tokType(Tok.T.count)
                            .foregroundStyle(Tok.C.corrected)
                    }
                }
                if let risk {
                    Text(risk.message)
                        .tokType(Tok.T.caption)
                        .foregroundStyle(Tok.C.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: Tok.S.s12)

            HStack(spacing: Tok.S.s16) {
                TokTextButton(title: "Add", sound: .add) {
                    withAnimation(Tok.M.listRow) { app.acceptSuggestion(suggestion) }
                }
                TokTextButton(title: "Dismiss", tint: Tok.C.textSecondary, sound: .delete) {
                    withAnimation(Tok.M.listRow) { app.dismissSuggestion(suggestion) }
                }
            }
        }
        .padding(.horizontal, Tok.S.s12)
        .padding(.vertical, Tok.S.s6)
        .frame(minHeight: Tok.L.rowMinHeight)
    }
}

// =============================================================================
// MARK: - Editor
// =============================================================================

/// Add or edit one entry, with the risk check live under the fields.
private struct EntryEditor: View {
    let entry: DictionaryEntry?
    let commit: (DictionaryEntry) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var kind: DictionaryEntry.Kind
    @State private var match: String
    @State private var replacement: String

    init(entry: DictionaryEntry?, commit: @escaping (DictionaryEntry) -> Void) {
        self.entry = entry
        self.commit = commit
        _kind = State(initialValue: entry?.kind ?? .term)
        _match = State(initialValue: entry?.match ?? "")
        _replacement = State(initialValue: entry.map { $0.kind == .fix ? $0.replacement : "" } ?? "")
    }

    private var risk: DictionaryEntry.Risk? {
        DictionaryEntry.risk(kind: kind, match: match, replacement: replacement)
    }

    private var canSave: Bool {
        let source = match.trimmingCharacters(in: .whitespaces)
        guard !source.isEmpty else { return false }
        if kind == .fix { return !replacement.trimmingCharacters(in: .whitespaces).isEmpty }
        return true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tok.S.s16) {
            Text(entry == nil ? "New entry" : "Edit entry")
                .tokType(Tok.T.tab)
                .foregroundStyle(Tok.C.textPrimary)

            Picker("", selection: $kind) {
                Text("Word or phrase").tag(DictionaryEntry.Kind.term)
                Text("Correction").tag(DictionaryEntry.Kind.fix)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: kind) { _, _ in SoundKit.play(.tabSwitch) }

            VStack(alignment: .leading, spacing: Tok.S.s8) {
                Field(
                    label: kind == .term ? "Word or phrase" : "When you hear",
                    placeholder: kind == .term ? "Anthropic" : "cloud code",
                    text: $match
                )
                if kind == .fix {
                    Field(label: "Write", placeholder: "Claude Code", text: $replacement)
                }
            }

            Text(kind == .term
                 ? "Fed to the speech engine as a hint, and its spelling is enforced afterwards."
                 : "Matched whole-word and case-insensitively. Spaces, hyphens or nothing at all between the words all count.")
                .tokType(Tok.T.caption)
                .foregroundStyle(Tok.C.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            if let risk {
                HStack(alignment: .top, spacing: Tok.S.s8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Tok.C.warning)
                    Text(risk.message)
                        .tokType(Tok.T.caption)
                        .foregroundStyle(Tok.C.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(Tok.S.s8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    Tok.C.warning.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: Tok.R.chip, style: .continuous)
                )
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(entry == nil ? "Add" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(Tok.S.s20)
        .frame(width: 420)
        .background(Tok.C.appBg)
    }

    private func save() {
        let source = match.trimmingCharacters(in: .whitespaces)
        let target = kind == .fix ? replacement.trimmingCharacters(in: .whitespaces) : source
        SoundKit.play(.add)
        commit(
            DictionaryEntry(
                id: entry?.id ?? UUID(),
                kind: kind,
                match: source,
                replacement: target,
                isEnabled: entry?.isEnabled ?? true
            )
        )
        dismiss()
    }
}

private struct Field: View {
    let label: String
    let placeholder: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: Tok.S.s4) {
            Text(label)
                .tokType(Tok.T.micro)
                .foregroundStyle(Tok.C.textSecondary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .tokType(Tok.T.body)
                .foregroundStyle(Tok.C.textPrimary)
                .padding(.horizontal, Tok.S.s8)
                .frame(height: Tok.L.searchHeight)
                .background(Tok.C.field, in: RoundedRectangle(cornerRadius: Tok.R.panel, style: .continuous))
                .emboss(Tok.R.panel, inset: true)
        }
    }
}
