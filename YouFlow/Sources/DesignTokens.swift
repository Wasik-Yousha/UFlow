import AppKit
import SwiftUI

// =============================================================================
// UFlow Design Tokens
//
// The single source of truth for every visual value in the app. Views pull
// from `Tok.*` and never inline a literal color, size, radius, or duration.
//
// Palette anchors are sampled from the shipped brand assets:
//   Asssets/LOGO/UFlow_logo.png  -> vermilion / teal / amber / cream
//   Asssets/APP UI inspiration/* -> chassis, panel, screen and meter values
//
// Two zones exist and are named separately because they are different
// materials, not different shades:
//   CHASSIS - the boombox hardware deck at the top of the window.
//   SCREEN  - the content area below it (list, search, dictionary).
// =============================================================================

// MARK: - Plumbing

extension NSColor {
    fileprivate convenience init(rgb: UInt32) {
        self.init(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}

/// A color that resolves against the active appearance. Using one dynamic
/// palette means no theme object has to be threaded through the view tree.
private func dyn(_ light: UInt32, _ dark: UInt32) -> Color {
    Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(rgb: dark)
            : NSColor(rgb: light)
    })
}

private func fixed(_ rgb: UInt32) -> Color { Color(nsColor: NSColor(rgb: rgb)) }

// MARK: - Tokens

enum Tok {

    // -------------------------------------------------------------------------
    // MARK: Brand — fixed in both appearances, sampled from UFlow_logo.png
    // -------------------------------------------------------------------------

    enum Brand {
        static let vermilion = fixed(0xD5391B)
        static let teal      = fixed(0x0A444F)
        static let amber     = fixed(0xE88E14)
        static let cream     = fixed(0xFDF1D3)
        static let umber     = fixed(0x7A4A2B)

        /// Row accent cycle (dictionary dots, transcript mic avatars).
        static let cycle: [Color] = [vermilion, teal, amber, umber]
        static func cycled(_ index: Int) -> Color { cycle[abs(index) % cycle.count] }
    }

    // -------------------------------------------------------------------------
    // MARK: Color
    // -------------------------------------------------------------------------

    enum C {

        // --- Chassis: the hardware deck -------------------------------------
        static let chassisTop    = dyn(0xF7EEE0, 0x2A2724)
        static let chassisBottom = dyn(0xE8D9C2, 0x171614)
        static let chassisEdgeHi = dyn(0xFFFBF2, 0x6E655C)   // emboss highlight
        static let chassisEdgeLo = dyn(0xC9B79C, 0x000000)   // emboss shadow
        static let panelFace     = dyn(0xEFE3D1, 0x2C2925)   // recessed module
        static let panelWell     = dyn(0xE2D3BC, 0x1A1815)   // deep inset well
        static let panelRule     = dyn(0xD3C0A3, 0x3A3632)   // module divider
        static let grille        = dyn(0xB9A98F, 0x3A3733)   // speaker mesh
        static let grilleRing    = dyn(0x9C8A6E, 0x5A544D)   // speaker chrome ring
        static let plateFace     = dyn(0xEDE0CB, 0x201E1B)   // nameplate metal

        // --- Screen: the content area ---------------------------------------
        static let appBg         = dyn(0xF6ECDE, 0x141312)
        static let surface       = dyn(0xF4EADC, 0x1B1A18)   // card / row
        static let surfaceRaised = dyn(0xEFE4D2, 0x232120)   // hover / selected
        static let field         = dyn(0xFBF4E9, 0x0F0F0E)   // search input
        static let divider       = dyn(0xDCCBB1, 0x2A2825)
        static let hairline      = dyn(0xE3D5BE, 0x262421)   // card border

        // --- Text ------------------------------------------------------------
        static let textPrimary   = dyn(0x2B2018, 0xE8E8E3)
        static let textSecondary = dyn(0x6F6154, 0xA09A93)
        static let textTertiary  = dyn(0xA8967F, 0x6E6862)   // placeholder
        static let textOnAccent  = fixed(0xFDF1D3)

        // --- Accent & semantic ------------------------------------------------
        static let accent        = dyn(0xCC330D, 0xF4452A)   // active tab, COPY
        static let accentPressed = dyn(0xA82708, 0xD63A22)
        static let engineTag     = dyn(0x26747E, 0xA8C4C9)   // "APPLE (STREAMING)"
        static let corrected     = dyn(0xC87A0C, 0xEDAB59)   // "CORRECTED"
        static let warning       = dyn(0xB5651D, 0xE8A33C)   // risky dictionary entry
        static let danger        = dyn(0xCC330D, 0xF4452A)   // DELETE
        static let focusRing     = dyn(0xCC330D, 0xF4452A).opacity(0.45)

        // --- Transport hardware -----------------------------------------------
        static let recordTop     = dyn(0xD2542C, 0xB5301B)
        static let recordBottom  = dyn(0xA83A1B, 0x7E2011)
        static let recordBezel   = dyn(0x8E5A3E, 0x4A423C)
        static let recordCap     = dyn(0xF2E7D6, 0xE24A32)   // the round center cap
        static let stopTop       = dyn(0x8A8276, 0x3E3C3A)
        static let stopBottom    = dyn(0x6E665C, 0x2A2927)
        static let stopCap       = dyn(0xE6DDD0, 0xBDB8B2)   // the square glyph

        // --- LED / counter -----------------------------------------------------
        static let ledWindow     = dyn(0x26221E, 0x1C1917)   // black plastic
        static let ledOn         = fixed(0xFE4A29)
        static let ledOff        = fixed(0xFE4A29).opacity(0.09)
        static let ledLamp       = fixed(0xFF3B1E)           // the REC lamp
        static let ledLampOff    = dyn(0x8A5A4C, 0x4A2A22)
        /// The mic indicator on the right-hand plate: lit green while the
        /// microphone is actually open, dark otherwise.
        static let micLive       = dyn(0x3E8E52, 0x5FBE72)
        static let micIdle       = dyn(0xB9A98F, 0x2A2724)

        // --- VU meter -----------------------------------------------------------
        static let meterFace     = dyn(0xEAD6B3, 0xCDB289)
        static let meterInk      = dyn(0x3B2F20, 0x33291C)   // scale, needle, "VU"
        static let meterDanger   = dyn(0xC02A12, 0xD03217)   // the 0 -> + red zone
        static let meterGlass    = Color.white.opacity(0.16) // top sheen
        static let meterBezel    = dyn(0xB09A78, 0x151310)
    }

    // -------------------------------------------------------------------------
    // MARK: Gradients — hardware surfaces only
    // -------------------------------------------------------------------------

    enum Grad {
        static let chassis = LinearGradient(
            colors: [C.chassisTop, C.chassisBottom], startPoint: .top, endPoint: .bottom)
        static let record = LinearGradient(
            colors: [C.recordTop, C.recordBottom], startPoint: .top, endPoint: .bottom)
        static let stop = LinearGradient(
            colors: [C.stopTop, C.stopBottom], startPoint: .top, endPoint: .bottom)
        static let meter = LinearGradient(
            colors: [C.meterFace, C.meterFace.opacity(0.82)], startPoint: .top, endPoint: .bottom)
    }

    // -------------------------------------------------------------------------
    // MARK: Type
    //
    // Hardware labels use a condensed system face with wide tracking, matching
    // silkscreen printing on a cassette deck. Body copy uses the plain system
    // face so long transcripts stay readable.
    // -------------------------------------------------------------------------

    struct TypeStyle {
        let size: CGFloat
        let weight: NSFont.Weight
        let width: NSFont.Width
        let tracking: CGFloat
        let uppercase: Bool
        let lineSpacing: CGFloat

        var font: Font { Font(NSFont.systemFont(ofSize: size, weight: weight, width: width)) }
    }

    enum T {
        private static func s(_ size: CGFloat, _ weight: NSFont.Weight,
                              width: NSFont.Width = .standard, tracking: CGFloat = 0,
                              upper: Bool = false, line: CGFloat = 0) -> TypeStyle {
            TypeStyle(size: size, weight: weight, width: width,
                      tracking: tracking, uppercase: upper, lineSpacing: line)
        }

        /// "UFLOW" in the window title bar.
        static let wordmark   = s(14, .semibold, width: .standard, tracking: 5.5, upper: true)
        /// "TRANSPORT", "LEVEL", "COUNTER" — silkscreened module labels.
        static let hardware   = s(9.5, .medium, width: .condensed, tracking: 2.2, upper: true)
        /// "MIC", "MIN", "SEC", "REC" — the smallest deck labels.
        static let hardwareSm = s(8, .medium, width: .condensed, tracking: 1.4, upper: true)
        /// "TRANSCRIPTIONS" / "DICTIONARY" tabs.
        static let tab        = s(11.5, .semibold, tracking: 1.3, upper: true)
        /// "APPLE (STREAMING)" engine label, "CORRECTED".
        static let meta       = s(11, .semibold, tracking: 0.7, upper: true)
        /// Transcript body copy.
        static let body       = s(13, .regular, line: 4)
        /// Dictionary term / replacement text.
        static let term       = s(13, .medium)
        /// "3:19PM" — timestamps and inline figures.
        static let caption    = s(10.5, .medium, tracking: 0.5)
        /// "5 RECORDINGS", "11 ENTRIES" — the count in a list footer.
        static let count      = s(10.5, .medium, tracking: 1.0, upper: true)
        /// "COPY", "+ ADD", "DELETE ALL", "EDIT", "OFF".
        static let button     = s(10.5, .semibold, tracking: 1.0, upper: true)
        /// "TERM" / "FIX" type badges.
        static let micro      = s(9, .medium, width: .condensed, tracking: 1.6, upper: true)
        /// Model plate text under the nameplate.
        static let plate      = s(7.5, .medium, width: .condensed, tracking: 1.2, upper: true)

        /// Counter digits are drawn as seven-segment shapes, not glyphs.
        static let ledDigitHeight: CGFloat = 34
        static let ledDigitWidth: CGFloat = 20
        static let ledSegment: CGFloat = 4       // segment thickness
    }

    // -------------------------------------------------------------------------
    // MARK: Space — 2pt base grid
    // -------------------------------------------------------------------------

    enum S {
        static let s2: CGFloat = 2
        static let s4: CGFloat = 4
        static let s6: CGFloat = 6
        static let s8: CGFloat = 8
        static let s12: CGFloat = 12
        static let s16: CGFloat = 16
        static let s20: CGFloat = 20
        static let s24: CGFloat = 24
        static let s32: CGFloat = 32
        static let s40: CGFloat = 40
    }

    // -------------------------------------------------------------------------
    // MARK: Radius
    // -------------------------------------------------------------------------

    enum R {
        static let chip: CGFloat = 2      // correction chips, TERM/FIX badges
        static let panel: CGFloat = 4     // deck modules, LED window
        static let card: CGFloat = 6      // list rows, transport buttons
        static let control: CGFloat = 8   // search field, tabs
        static let deck: CGFloat = 12     // window / chassis outer
        static let pill: CGFloat = 999
    }

    // -------------------------------------------------------------------------
    // MARK: Stroke
    // -------------------------------------------------------------------------

    enum W {
        static let hairline: CGFloat = 1
        static let medium: CGFloat = 1.5
        static let bezel: CGFloat = 2      // transport button surround
        static let focus: CGFloat = 2
        static let meterNeedle: CGFloat = 1.5
        static let meterTick: CGFloat = 1
    }

    // -------------------------------------------------------------------------
    // MARK: Shadow
    // -------------------------------------------------------------------------

    struct ShadowStyle {
        let color: Color
        let radius: CGFloat
        let x: CGFloat
        let y: CGFloat
    }

    enum Sh {
        /// List rows and cards.
        static let card = ShadowStyle(
            color: dyn(0x2B2018, 0x000000).opacity(0.06), radius: 2, x: 0, y: 1)
        /// A raised hardware key at rest.
        static let raised = ShadowStyle(
            color: dyn(0x2B2018, 0x000000).opacity(0.22), radius: 4, x: 0, y: 2)
        /// The chassis dropping onto the screen area.
        static let deck = ShadowStyle(
            color: dyn(0x2B2018, 0x000000).opacity(0.18), radius: 10, x: 0, y: 3)
        /// Menus, the add/edit sheet.
        static let popover = ShadowStyle(
            color: dyn(0x2B2018, 0x000000).opacity(0.25), radius: 20, x: 0, y: 6)
        /// Inset depth for wells and pressed keys (drawn as an inner shadow).
        static let wellRadius: CGFloat = 3
        static let wellColor = dyn(0x2B2018, 0x000000).opacity(0.25)
        /// LED bloom.
        static let ledGlowRadius: CGFloat = 6
        static let ledGlowOpacity: Double = 0.55
    }

    // -------------------------------------------------------------------------
    // MARK: Motion
    // -------------------------------------------------------------------------

    enum M {
        static let press   = Animation.easeOut(duration: 0.07)
        static let hover   = Animation.easeOut(duration: 0.14)
        static let tab     = Animation.spring(response: 0.22, dampingFraction: 0.9)
        static let sheet   = Animation.spring(response: 0.28, dampingFraction: 0.86)
        static let listRow = Animation.easeOut(duration: 0.24)

        /// REC lamp blink period while recording.
        static let lampBlink: Double = 1.1

        // VU ballistics. A real meter is not a linear follower: it snaps toward
        // a peak and falls back slowly. These are the calibration knobs — raise
        // `needleRelease` for a lazier needle, lower `needleAttack` for a
        // twitchier one.
        static let needleAttack: Double = 0.045
        static let needleRelease: Double = 0.32
        /// Level meter sample rate for the needle (Hz).
        static let needleRefreshHz: Double = 60
    }

    // -------------------------------------------------------------------------
    // MARK: Sound — every transport and list action has a mechanical response
    // -------------------------------------------------------------------------

    enum Sfx: String, CaseIterable {
        case recordDown   // heavy latching key going down
        case stopDown     // shorter, harder clunk
        case keyUp        // soft release
        case tabSwitch    // small detent tick
        case copy         // light click
        case add          // click with a rising tail
        case delete       // dull thunk
        case error        // low buzz

        static let volume: Float = 0.35
    }

    // -------------------------------------------------------------------------
    // MARK: Layout — fixed hardware geometry
    // -------------------------------------------------------------------------

    enum L {
        static let windowMinWidth: CGFloat = 880
        static let windowMinHeight: CGFloat = 620
        static let deckHeight: CGFloat = 200      // chassis module strip

        static let namePlateHeight: CGFloat = 34
        /// The badge carries its own internal margin, so its wordmark sits in
        /// from the metal edge. This shifts the badge left to compensate.
        /// Purely visual — it does not move anything else on the deck.
        static let namePlateNudge: CGFloat = -8
        static let tabStripHeight: CGFloat = 44
        static let searchHeight: CGFloat = 36
        static let footerHeight: CGFloat = 34
        static let speakerDiameter: CGFloat = 268 // the round grilles
        static let rowMinHeight: CGFloat = 44
        /// The logo mark on the right-hand plate.
        static let logoMarkSize: CGFloat = 72

        // The floating recorder bar shown while dictating into another app.
        static let hudWidth: CGFloat = 276
        static let hudHeight: CGFloat = 38
        static let hudBarCount = 28
        static let hudBarWidth: CGFloat = 2.5
        static let hudWaveHeight: CGFloat = 18
    }
}

// MARK: - View helpers

extension View {
    func tokShadow(_ s: Tok.ShadowStyle) -> some View {
        shadow(color: s.color, radius: s.radius, x: s.x, y: s.y)
    }

    /// Applies a full type token: font, tracking, casing and line spacing
    /// together, so no component sets any of them individually.
    func tokType(_ t: Tok.TypeStyle) -> some View {
        font(t.font)
            .tracking(t.tracking)
            .lineSpacing(t.lineSpacing)
            .textCase(t.uppercase ? .uppercase : nil)
    }

    /// The 1px light-on-top, dark-underneath edge that makes a surface read as
    /// a moulded piece of hardware rather than a rectangle.
    func emboss(_ radius: CGFloat, inset: Bool = false) -> some View {
        overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: inset
                            ? [Tok.C.chassisEdgeLo, Tok.C.chassisEdgeHi]
                            : [Tok.C.chassisEdgeHi, Tok.C.chassisEdgeLo],
                        startPoint: .top, endPoint: .bottom
                    ),
                    lineWidth: Tok.W.hairline
                )
        )
    }
}
