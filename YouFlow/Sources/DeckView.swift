import SwiftUI

// =============================================================================
// MARK: - The deck
// =============================================================================

/// The hardware strip across the top of the window: brand plate, transport,
/// level meter, counter, and the mic/logo plate.
struct DeckView: View {
    @EnvironmentObject private var app: AppState

    var previewLevel: Double = 0

    var body: some View {
        // Widths are proportional, measured off the reference deck: the level
        // meter is the widest instrument and the brand plate the narrowest.
        GeometryReader { geo in
            let width = geo.size.width
            HStack(spacing: Tok.S.s8) {
                BrandPlate()
                    .frame(width: width * 0.115)

                TransportModule()
                    .frame(width: width * 0.205)

                DeckModule(title: "Level") {
                    VUMeterView(
                        level: previewLevel > 0 ? previewLevel : app.level,
                        isLive: previewLevel > 0 || app.isRecording
                    )
                }
                .frame(width: width * 0.305)

                DeckModule(title: "Counter") {
                    CounterModule(elapsed: previewLevel > 0 ? 83 : app.elapsed)
                }
                .frame(width: width * 0.175)

                MicPlate(isLive: app.isRecording)
            }
        }
        .frame(height: Tok.L.deckHeight)
        .padding(Tok.S.s12)
        .background(Tok.Grad.chassis, in: RoundedRectangle(cornerRadius: Tok.R.deck, style: .continuous))
        .emboss(Tok.R.deck)
        .tokShadow(Tok.Sh.deck)
    }
}

// =============================================================================
// MARK: - Brand plate
// =============================================================================

/// Where a cassette deck puts the manufacturer's badge and model number.
private struct BrandPlate: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Tok.S.s8) {
            if let plate = BrandAsset.namePlate {
                plate
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: Tok.L.namePlateHeight)
                    .offset(x: Tok.L.namePlateNudge)
                    .accessibilityLabel("UFlow")
            } else {
                Text("UFlow")
                    .tokType(Tok.T.wordmark)
                    .foregroundStyle(Tok.C.textPrimary)
            }

            VStack(alignment: .leading, spacing: Tok.S.s4) {
                Text("UF-715S")
                    .tokType(Tok.T.hardware)
                    .foregroundStyle(Tok.C.textSecondary)
                Text("On-device")
                    .tokType(Tok.T.plate)
                    .foregroundStyle(Tok.C.textTertiary)
                Text("Speech transcriber")
                    .tokType(Tok.T.plate)
                    .foregroundStyle(Tok.C.textTertiary)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, Tok.S.s4)
        .padding(.top, Tok.S.s8)
    }
}

// =============================================================================
// MARK: - Transport
// =============================================================================

private struct TransportModule: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        DeckModule(title: "Transport") {
            VStack(spacing: Tok.S.s8) {
                HStack(spacing: Tok.S.s12) {
                    HardwareKey(
                        style: .record,
                        isLatched: app.isRecording,
                        isEnabled: !app.isRecording && !app.isBusy,
                        sound: .recordDown,
                        action: { app.startFromWindow() }
                    ) {
                        VStack(spacing: Tok.S.s6) {
                            Circle()
                                .fill(Tok.C.recordCap)
                                .frame(width: 17, height: 17)
                            Text("Record")
                                .tokType(Tok.T.button)
                                .foregroundStyle(Tok.C.textOnAccent)
                        }
                    }
                    .frame(width: 82, height: 62)
                    .help("Start recording  (\(app.hotkeyDescription) anywhere)")

                    HardwareKey(
                        style: .stop,
                        isEnabled: app.isRecording,
                        sound: .stopDown,
                        action: { app.stopFromWindow() }
                    ) {
                        VStack(spacing: Tok.S.s6) {
                            Text("Stop")
                                .tokType(Tok.T.button)
                                .foregroundStyle(Tok.C.textOnAccent)
                            RoundedRectangle(cornerRadius: 1)
                                .fill(Tok.C.stopCap)
                                .frame(width: 15, height: 15)
                        }
                    }
                    .frame(width: 74, height: 62)
                    .help("Stop and transcribe")
                }

                RecLamp(isOn: app.isRecording)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// The lamp under the transport keys: blinks while recording, dark otherwise.
///
/// The blink is driven off the clock rather than a `repeatForever` animation,
/// because such an animation outlives the flag that started it — the lamp
/// could keep pulsing after the deck had stopped. Here the schedule only
/// exists while `isOn`, so "not recording" is a genuinely static dark lamp.
private struct RecLamp: View {
    let isOn: Bool

    var body: some View {
        HStack(spacing: Tok.S.s6) {
            if isOn {
                TimelineView(.periodic(from: .now, by: Tok.M.lampBlink / 2)) { context in
                    let phase = context.date.timeIntervalSinceReferenceDate
                        .truncatingRemainder(dividingBy: Tok.M.lampBlink)
                    dot(lit: phase < Tok.M.lampBlink / 2)
                }
            } else {
                dot(lit: false)
            }

            Text("Rec")
                .tokType(Tok.T.hardwareSm)
                .foregroundStyle(isOn ? Tok.C.accent : Tok.C.textSecondary)
        }
        .padding(.leading, Tok.S.s4)
    }

    private func dot(lit: Bool) -> some View {
        Circle()
            .fill(lit ? Tok.C.ledLamp : Tok.C.ledLampOff)
            .frame(width: 9, height: 9)
            .shadow(
                color: lit ? Tok.C.ledLamp.opacity(Tok.Sh.ledGlowOpacity) : .clear,
                radius: Tok.Sh.ledGlowRadius
            )
    }
}

// =============================================================================
// MARK: - VU meter
// =============================================================================

/// Needle ballistics.
///
/// A real VU meter is not a linear follower: it snaps toward a peak and falls
/// back slowly, which is why quiet speech still looks alive. Attack and release
/// are separate one-pole time constants, both tokenised so the feel can be
/// tuned without touching this code.
@MainActor
private final class NeedleBallistics: ObservableObject {
    @Published private(set) var value: Double = 0

    var target: Double = 0 {
        didSet { if target > 0 { ensureRunning() } }
    }

    private var timer: Timer?
    private var lastTick = Date()

    private func ensureRunning() {
        guard timer == nil else { return }
        lastTick = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 1 / Tok.M.needleRefreshHz, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        let now = Date()
        let dt = min(now.timeIntervalSince(lastTick), 0.25)
        lastTick = now

        let tau = target > value ? Tok.M.needleAttack : Tok.M.needleRelease
        value += (target - value) * (1 - exp(-dt / tau))

        // Park the timer once the needle has come to rest.
        if target <= 0.0001, value < 0.002 {
            value = 0
            timer?.invalidate()
            timer = nil
        }
    }

    deinit { timer?.invalidate() }
}

struct VUMeterView: View {
    let level: Double
    let isLive: Bool

    @StateObject private var needle = NeedleBallistics()

    /// Scale marks, as fractions along the sweep. Everything past `redZone` is
    /// the overload arc.
    private static let marks: [(String, Double)] = [
        ("-20", 0.00), ("10", 0.16), ("7", 0.28), ("5", 0.38),
        ("3", 0.48), ("1", 0.58), ("0", 0.66), ("3", 0.82), ("+", 0.97),
    ]
    private static let redZone = 0.66
    private static let sweep = 52.0

    var body: some View {
        Canvas { context, size in
            let pivot = CGPoint(x: size.width / 2, y: size.height * 0.94)
            let arc = min(size.width * 0.42, size.height * 0.72)

            func point(_ t: Double, _ radius: Double) -> CGPoint {
                let degrees = -Self.sweep + t * (Self.sweep * 2)
                let radians = (degrees - 90) * .pi / 180
                return CGPoint(x: pivot.x + cos(radians) * radius, y: pivot.y + sin(radians) * radius)
            }

            // Ticks, dense minor with a major every fourth.
            for i in 0...32 {
                let t = Double(i) / 32
                let major = i.isMultiple(of: 4)
                var path = Path()
                path.move(to: point(t, arc))
                path.addLine(to: point(t, arc - (major ? 11 : 7)))
                context.stroke(
                    path,
                    with: .color(t > Self.redZone ? Tok.C.meterDanger : Tok.C.meterInk),
                    lineWidth: major ? 1.4 : Tok.W.meterTick
                )
            }

            // The arc itself, red past 0.
            for (range, color) in [((0.0, Self.redZone), Tok.C.meterInk),
                                   ((Self.redZone, 1.0), Tok.C.meterDanger)] {
                var path = Path()
                path.move(to: point(range.0, arc))
                for step in stride(from: range.0, through: range.1, by: 0.01) {
                    path.addLine(to: point(step, arc))
                }
                context.stroke(path, with: .color(color), lineWidth: range.1 == 1.0 ? 2.5 : 1.2)
            }

            // Numerals.
            for (label, t) in Self.marks {
                let position = point(t, arc - 22)
                context.draw(
                    Text(label)
                        .font(Tok.T.hardwareSm.font)
                        .foregroundStyle(t > Self.redZone ? Tok.C.meterDanger : Tok.C.meterInk),
                    at: position, anchor: .center
                )
            }

            context.draw(
                Text("VU")
                    .font(Tok.T.hardware.font)
                    .tracking(Tok.T.hardware.tracking)
                    .foregroundStyle(Tok.C.meterInk),
                at: CGPoint(x: pivot.x, y: pivot.y - arc * 0.30), anchor: .center
            )

            // Needle.
            let degrees = -Self.sweep + needle.value * (Self.sweep * 2)
            var stem = Path()
            stem.move(to: pivot)
            stem.addLine(to: CGPoint(x: pivot.x, y: pivot.y - arc - 6))
            context.stroke(
                stem.applying(
                    CGAffineTransform(translationX: pivot.x, y: pivot.y)
                        .rotated(by: degrees * .pi / 180)
                        .translatedBy(x: -pivot.x, y: -pivot.y)
                ),
                with: .color(Tok.C.meterInk),
                style: StrokeStyle(lineWidth: Tok.W.meterNeedle, lineCap: .round)
            )
        }
        .background(Tok.Grad.meter)
        .overlay(alignment: .top) {
            // Glass sheen.
            LinearGradient(colors: [Tok.C.meterGlass, .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 18)
                .allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: Tok.R.panel, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Tok.R.panel, style: .continuous)
                .strokeBorder(Tok.C.meterBezel, lineWidth: Tok.W.hairline)
        }
        .onChange(of: level, initial: true) { _, new in needle.target = isLive ? new : 0 }
        .onChange(of: isLive) { _, live in if !live { needle.target = 0 } }
        .accessibilityLabel("Input level")
        .accessibilityValue("\(Int(needle.value * 100)) percent")
    }
}

// =============================================================================
// MARK: - Counter
// =============================================================================

private struct CounterModule: View {
    let elapsed: TimeInterval

    var body: some View {
        VStack(spacing: Tok.S.s6) {
            SevenSegmentClock(seconds: elapsed)
                .frame(height: Tok.T.ledDigitHeight + Tok.S.s16)
                .frame(maxWidth: .infinity)
                .background(Tok.C.ledWindow, in: RoundedRectangle(cornerRadius: Tok.R.panel, style: .continuous))
                .emboss(Tok.R.panel, inset: true)

            HStack {
                Text("Min").tokType(Tok.T.hardwareSm).foregroundStyle(Tok.C.textSecondary)
                Spacer()
                Text("Sec").tokType(Tok.T.hardwareSm).foregroundStyle(Tok.C.textSecondary)
            }
            .padding(.horizontal, Tok.S.s20)
        }
    }
}

/// A four-digit seven-segment display.
///
/// The segments are drawn rather than typeset so the unlit ones stay faintly
/// visible — the "ghost eight" behind the numbers is most of what makes a real
/// LED readout look like one.
struct SevenSegmentClock: View {
    let seconds: TimeInterval

    /// Which segments each digit lights: a top, b upper-right, c lower-right,
    /// d bottom, e lower-left, f upper-left, g middle.
    private static let map: [Int: Set<Character>] = [
        0: ["a", "b", "c", "d", "e", "f"], 1: ["b", "c"],
        2: ["a", "b", "g", "e", "d"],      3: ["a", "b", "g", "c", "d"],
        4: ["f", "g", "b", "c"],           5: ["a", "f", "g", "c", "d"],
        6: ["a", "f", "g", "e", "d", "c"], 7: ["a", "b", "c"],
        8: ["a", "b", "c", "d", "e", "f", "g"], 9: ["a", "f", "g", "b", "c", "d"],
    ]

    /// Segment outlines inside a 20 × 34 digit box, matching Tok.T.ledSegment.
    private static let shapes: [Character: [CGPoint]] = [
        "a": [.init(x: 3, y: 1), .init(x: 17, y: 1), .init(x: 14, y: 4), .init(x: 6, y: 4)],
        "d": [.init(x: 3, y: 33), .init(x: 17, y: 33), .init(x: 14, y: 30), .init(x: 6, y: 30)],
        "g": [.init(x: 3, y: 17), .init(x: 6, y: 15), .init(x: 14, y: 15),
              .init(x: 17, y: 17), .init(x: 14, y: 19), .init(x: 6, y: 19)],
        "f": [.init(x: 1, y: 3), .init(x: 4, y: 6), .init(x: 4, y: 14), .init(x: 1, y: 16)],
        "b": [.init(x: 19, y: 3), .init(x: 16, y: 6), .init(x: 16, y: 14), .init(x: 19, y: 16)],
        "e": [.init(x: 1, y: 18), .init(x: 4, y: 20), .init(x: 4, y: 28), .init(x: 1, y: 31)],
        "c": [.init(x: 19, y: 18), .init(x: 16, y: 20), .init(x: 16, y: 28), .init(x: 19, y: 31)],
    ]

    var body: some View {
        Canvas { context, size in
            let total = max(0, Int(seconds))
            let digits = [total / 600 % 10, total / 60 % 10, total % 60 / 10, total % 10]

            let scale = size.height / 40
            let digitWidth = 20 * scale
            let gap = 4 * scale
            let colonWidth = 10 * scale
            let contentWidth = digitWidth * 4 + gap * 3 + colonWidth
            var x = (size.width - contentWidth) / 2
            let y = (size.height - 34 * scale) / 2

            for (index, digit) in digits.enumerated() {
                let lit = Self.map[digit] ?? []
                for (segment, points) in Self.shapes {
                    var path = Path()
                    path.move(to: points[0])
                    points.dropFirst().forEach { path.addLine(to: $0) }
                    path.closeSubpath()
                    let placed = path.applying(
                        CGAffineTransform(translationX: x, y: y).scaledBy(x: scale, y: scale)
                    )
                    context.fill(placed, with: .color(lit.contains(segment) ? Tok.C.ledOn : Tok.C.ledOff))
                }
                x += digitWidth + gap
                if index == 1 {
                    for offset in [12.0, 24.0] {
                        let dot = CGRect(x: x + colonWidth / 2 - 2 * scale,
                                         y: y + offset * scale,
                                         width: 4 * scale, height: 4 * scale)
                        context.fill(Path(ellipseIn: dot), with: .color(Tok.C.ledOn))
                    }
                    x += colonWidth
                }
            }
        }
        .accessibilityLabel("Elapsed")
        .accessibilityValue("\(Int(seconds)) seconds")
    }
}

// =============================================================================
// MARK: - Mic / logo plate
// =============================================================================

private struct MicPlate: View {
    /// The mic hole doubles as the "input is open" indicator, so the plate
    /// needs to know whether the microphone is actually running.
    let isLive: Bool

    var body: some View {
        HStack(alignment: .top, spacing: Tok.S.s12) {
            VStack(spacing: Tok.S.s6) {
                Text("Mic")
                    .tokType(Tok.T.hardwareSm)
                    .foregroundStyle(Tok.C.textSecondary)
                Circle()
                    .fill(isLive ? Tok.C.micLive : Tok.C.micIdle)
                    .frame(width: 8, height: 8)
                    .emboss(4, inset: true)
                    .shadow(
                        color: isLive ? Tok.C.micLive.opacity(Tok.Sh.ledGlowOpacity) : .clear,
                        radius: Tok.Sh.ledGlowRadius
                    )

                // The moulded vent slots beside the mic hole.
                VStack(spacing: 3) {
                    ForEach(0..<6, id: \.self) { _ in
                        Capsule()
                            .fill(Tok.C.panelWell)
                            .frame(width: 30, height: 3)
                    }
                }
                .padding(.top, Tok.S.s4)
                Spacer(minLength: 0)
            }
            .padding(.top, Tok.S.s8)

            // Uncaptioned, the mark reads as a stamped badge: it takes the
            // same top inset as the MIC column so the two line up, and keeps
            // the flexible width so the plate still claims the deck remainder.
            if let logo = BrandAsset.logo {
                logo
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: Tok.L.logoMarkSize, height: Tok.L.logoMarkSize)
                    .clipShape(RoundedRectangle(cornerRadius: Tok.R.deck, style: .continuous))
                    .padding(.top, Tok.S.s8)
                    .frame(maxWidth: .infinity)
                    .accessibilityHidden(true)
            }
        }
    }
}
