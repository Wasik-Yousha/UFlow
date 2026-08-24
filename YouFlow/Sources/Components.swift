import AppKit
import SwiftUI

// =============================================================================
// MARK: - Brand assets
// =============================================================================

/// The two shipped marks. Loaded from loose bundle resources rather than an
/// asset catalog, because the project predates one and two PNGs do not justify
/// adding it.
enum BrandAsset {
    static let logo = load("LogoMark")
    static let namePlate = load("NamePlate")

    private static func load(_ name: String) -> Image? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
              let image = NSImage(contentsOf: url) else {
            Log.app.error("Missing bundle resource \(name, privacy: .public).png")
            return nil
        }
        return Image(nsImage: image)
    }
}

// =============================================================================
// MARK: - Silkscreen label
// =============================================================================

/// A module label with a hairline running out to each side — the way a deck
/// silkscreens "TRANSPORT" across the top of a section.
struct SilkLabel: View {
    let text: String
    var body: some View {
        HStack(spacing: Tok.S.s8) {
            rule
            Text(text)
                .tokType(Tok.T.hardware)
                .foregroundStyle(Tok.C.textSecondary)
                .fixedSize()
            rule
        }
    }

    private var rule: some View {
        Rectangle()
            .fill(Tok.C.panelRule)
            .frame(height: Tok.W.meterTick)
    }
}

// =============================================================================
// MARK: - Deck module
// =============================================================================

/// One recessed panel on the chassis: a labelled well holding an instrument.
struct DeckModule<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: Tok.S.s8) {
            SilkLabel(text: title)
            content
        }
        .padding(.horizontal, Tok.S.s12)
        .padding(.top, Tok.S.s8)
        .padding(.bottom, Tok.S.s12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Tok.C.panelFace, in: RoundedRectangle(cornerRadius: Tok.R.panel, style: .continuous))
        .emboss(Tok.R.panel)
    }
}

// =============================================================================
// MARK: - Speaker grille
// =============================================================================

/// The round speaker at each end of the deck. Drawn rather than shipped as an
/// image so it stays crisp at any size and follows the palette.
struct SpeakerGrille: View {
    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            ZStack {
                // Chrome surround.
                Circle()
                    .strokeBorder(
                        LinearGradient(
                            colors: [Tok.C.chassisEdgeHi, Tok.C.grilleRing, Tok.C.chassisEdgeLo],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ),
                        lineWidth: side * 0.055
                    )

                // Mesh: a hex lattice of perforations, clipped to the cone.
                Canvas { context, size in
                    let radius = size.width / 2
                    let spacing = max(3.0, size.width / 34)
                    let dot = spacing * 0.42
                    var row = 0
                    var y = -radius
                    while y <= radius {
                        let offset = row.isMultiple(of: 2) ? 0 : spacing / 2
                        var x = -radius + offset
                        while x <= radius {
                            if x * x + y * y <= radius * radius {
                                let rect = CGRect(x: radius + x - dot / 2, y: radius + y - dot / 2,
                                                  width: dot, height: dot)
                                context.fill(Path(ellipseIn: rect), with: .color(Tok.C.grille))
                            }
                            x += spacing
                        }
                        y += spacing * 0.86
                        row += 1
                    }
                }
                .clipShape(Circle().inset(by: side * 0.075))

                // Dust cap: flush with the cone, not a sphere sitting on it.
                Circle()
                    .fill(Tok.C.grilleRing.opacity(0.55))
                    .overlay {
                        Circle().strokeBorder(Tok.C.chassisEdgeHi.opacity(0.35), lineWidth: Tok.W.hairline)
                    }
                    .frame(width: side * 0.15, height: side * 0.15)
            }
            .frame(width: side, height: side)
        }
        .aspectRatio(1, contentMode: .fit)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// =============================================================================
// MARK: - Hardware key
// =============================================================================

/// A transport key. Presses translate down and drop their shadow, which is the
/// whole illusion: a key that only changes colour reads as a web button.
struct HardwareKey<Label: View>: View {
    enum Style { case record, stop }

    let style: Style
    var isLatched = false
    var isEnabled = true
    let sound: Tok.Sfx
    let action: () -> Void
    @ViewBuilder var label: Label

    @State private var isDown = false

    var body: some View {
        Button {
            SoundKit.play(sound)
            action()
        } label: {
            label
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(fill, in: RoundedRectangle(cornerRadius: Tok.R.card, style: .continuous))
                .emboss(Tok.R.card)
                .overlay {
                    if style == .record {
                        RoundedRectangle(cornerRadius: Tok.R.card + 2, style: .continuous)
                            .strokeBorder(Tok.C.recordBezel, lineWidth: Tok.W.bezel)
                            .padding(-3)
                    }
                }
                .offset(y: pressed ? 2 : 0)
                .tokShadow(pressed ? Tok.ShadowStyle(color: .clear, radius: 0, x: 0, y: 0) : Tok.Sh.raised)
                .animation(Tok.M.press, value: pressed)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
        .onLongPressGesture(minimumDuration: 0, pressing: { isDown = $0 }, perform: {})
    }

    private var pressed: Bool { isDown || isLatched }

    private var fill: LinearGradient {
        style == .record ? Tok.Grad.record : Tok.Grad.stop
    }
}

// =============================================================================
// MARK: - Search field
// =============================================================================

/// The recessed search well used at the top of both tabs.
struct SearchField: View {
    let placeholder: String
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: Tok.S.s8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Tok.C.textTertiary)

            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .tokType(Tok.T.body)
                .foregroundStyle(Tok.C.textPrimary)
                .focused($focused)

            if !text.isEmpty {
                Button {
                    text = ""
                    SoundKit.play(.tabSwitch)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Tok.C.textTertiary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.horizontal, Tok.S.s12)
        .frame(height: Tok.L.searchHeight)
        .background(Tok.C.field, in: RoundedRectangle(cornerRadius: Tok.R.control, style: .continuous))
        .emboss(Tok.R.control, inset: true)
        .overlay {
            if focused {
                RoundedRectangle(cornerRadius: Tok.R.control, style: .continuous)
                    .strokeBorder(Tok.C.focusRing, lineWidth: Tok.W.focus)
            }
        }
        .animation(Tok.M.hover, value: focused)
    }
}

// =============================================================================
// MARK: - Text buttons
// =============================================================================

/// The small uppercase actions on rows and footers: COPY, DELETE ALL, + ADD.
struct TokTextButton: View {
    let title: String
    var tint: Color = Tok.C.accent
    var sound: Tok.Sfx = .copy
    var bordered = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button {
            SoundKit.play(sound)
            action()
        } label: {
            Text(title)
                .tokType(Tok.T.button)
                .foregroundStyle(hovering ? Tok.C.accentPressed : tint)
                .padding(.horizontal, bordered ? Tok.S.s8 : 0)
                .padding(.vertical, bordered ? Tok.S.s4 : 0)
                .background {
                    if bordered {
                        RoundedRectangle(cornerRadius: Tok.R.chip, style: .continuous)
                            .strokeBorder(tint.opacity(hovering ? 0.9 : 0.45), lineWidth: Tok.W.hairline)
                    }
                }
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Tok.M.hover, value: hovering)
    }
}
