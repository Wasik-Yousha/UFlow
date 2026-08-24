import AppKit
import SwiftUI

/// Borderless, non-activating panel subclass that can never become key or
/// main — the structural guarantee that showing the HUD cannot steal focus
/// from the user's active application.
final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Observable state driving the HUD's SwiftUI content.
@MainActor
final class HUDViewModel: ObservableObject {
    enum Phase {
        case recording
        case transcribing
    }

    /// Bars in the scrolling waveform.
    static let barCount = Tok.L.hudBarCount

    @Published var phase: Phase = .recording
    @Published var levels: [CGFloat] = Array(repeating: 0, count: barCount)
    @Published var startedAt = Date()

    func reset() {
        levels = Array(repeating: 0, count: Self.barCount)
        startedAt = Date()
    }

    /// Shifts one new normalized level (0…1) into the rolling waveform.
    func push(_ level: CGFloat) {
        var next = levels
        next.removeFirst()
        next.append(min(max(level, 0), 1))
        levels = next
    }
}

/// Owns the floating recording indicator: a miniature deck — REC lamp, cream
/// level well, seven-segment counter — that reads as a module detached from
/// the main window's chassis and floating over whatever the user is typing in.
///
/// Focus-safety contract:
/// - Style mask `[.borderless, .nonactivatingPanel]` plus a
///   `canBecomeKey == false` panel subclass.
/// - Shown exclusively via `orderFrontRegardless()` — never
///   `makeKeyAndOrderFront`, never `NSApp.activate`.
/// - `.canJoinAllSpaces` + `.fullScreenAuxiliary` make it visible above
///   fullscreen applications without disturbing them.
/// - Mouse events are ignored entirely (`ignoresMouseEvents`) so the HUD can
///   never intercept a click meant for the destination app.
@MainActor
final class HUDPanelController {
    private static let panelSize = NSSize(width: Tok.L.hudWidth, height: Tok.L.hudHeight)

    private let panel: HUDPanel
    private let viewModel = HUDViewModel()
    private var fadeOutTask: Task<Void, Never>?

    init() {
        let panel = HUDPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = .floating
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.alphaValue = 0

        let hostingView = NSHostingView(rootView: HUDContentView(viewModel: viewModel))
        hostingView.frame = NSRect(origin: .zero, size: Self.panelSize)
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView

        self.panel = panel
    }

    // MARK: - Show / hide

    func showRecording() {
        viewModel.reset()
        show(phase: .recording)
    }

    func showTranscribing() {
        show(phase: .transcribing)
    }

    /// Feeds a normalized microphone level (0…1) into the waveform.
    func push(level: CGFloat) {
        guard panel.isVisible, viewModel.phase == .recording else { return }
        viewModel.push(level)
    }

    func hide() {
        guard panel.isVisible || panel.alphaValue > 0 else { return }
        fadeOutTask?.cancel()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.allowsImplicitAnimation = true
            panel.animator().alphaValue = 0
        }
        fadeOutTask = Task { [panel] in
            try? await Task.sleep(for: .milliseconds(130))
            guard !Task.isCancelled else { return }
            panel.orderOut(nil)
            panel.alphaValue = 0
            Log.hud.info("HUD hidden")
        }
    }

    private func show(phase: HUDViewModel.Phase) {
        fadeOutTask?.cancel()
        fadeOutTask = nil
        viewModel.phase = phase
        positionOnActiveScreen()

        // Non-activating order-front; the active app keeps focus. A short fade
        // runs concurrently — it never delays recording start.
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.allowsImplicitAnimation = true
            panel.animator().alphaValue = 1
        }
        Log.hud.info("HUD shown (\(phase == .recording ? "recording" : "transcribing", privacy: .public))")
    }

    /// Bottom-center of the screen hosting the frontmost app's window,
    /// falling back to the mouse's screen, then the main screen.
    private func positionOnActiveScreen() {
        let screen = targetScreen() ?? NSScreen.main
        guard let screen else { return }

        let size = Self.panelSize
        let visibleFrame = screen.visibleFrame
        let origin = NSPoint(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.minY + 32
        )
        panel.setFrameOrigin(origin)
    }

    private func targetScreen() -> NSScreen? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return nil }
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        for info in windowList {
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? Int32,
                  ownerPID == frontApp.processIdentifier else { continue }
            guard let bounds = info[kCGWindowBounds as String] as? [String: NSNumber] else { continue }
            guard let x = bounds["X"]?.doubleValue,
                  let y = bounds["Y"]?.doubleValue,
                  let width = bounds["Width"]?.doubleValue,
                  let height = bounds["Height"]?.doubleValue,
                  width > 0, height > 0 else { continue }

            // Skip tiny helper windows (menus, tooltips).
            if height < 40 { continue }

            let center = CGPoint(x: x + width / 2, y: y + height / 2)
            // CG coordinates are bottom-left origin; NSScreen frames too, but
            // containment checks are equivalent under either convention here.
            if let match = NSScreen.screens.first(where: { $0.frame.contains(center) }) {
                return match
            }
        }
        return NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
    }
}

// MARK: - SwiftUI content

/// The HUD chassis: the same moulded plastic body, embossed edge and
/// instrument well as the main deck, shrunk to a single strip.
///
/// The two phases share the chassis and the level well so the object stays
/// recognisably one piece of hardware; only what is mounted on it changes.
private struct HUDContentView: View {
    @ObservedObject var viewModel: HUDViewModel

    var body: some View {
        HStack(spacing: Tok.S.s8) {
            switch viewModel.phase {
            case .recording:
                // The lamp is phase-locked to the take, so the first blink
                // lands the instant the panel appears rather than mid-cycle.
                // Both ends size to their own content and the well takes the
                // rest, so every gap in the bar is the same 8pt. Pinning the
                // ends to a common width was tried and reverted: it reserved
                // 160pt for 92pt of content, which pushed the bar's minimum
                // width to 340pt inside a 276pt panel — the content outgrew
                // its own window, and the slack showed up as dead chassis
                // beside the lamp.
                PhaseLamp(label: "Rec", blinkingSince: viewModel.startedAt)
                LevelWell(levels: viewModel.levels)
                CounterReadout(since: viewModel.startedAt)

            case .transcribing:
                PhaseLamp(label: "Transcribing", blinkingSince: nil)
                ScanWell()
            }
        }
        // A slim bezel. The bar carries one framed instrument and a bare
        // readout, so the chassis needs only enough margin to read as moulded
        // plastic — any more and three compartments start competing again.
        .padding(.horizontal, Tok.S.s12)
        .padding(.vertical, Tok.S.s2)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Tok.Grad.chassis, in: RoundedRectangle(cornerRadius: Tok.R.control, style: .continuous))
        .emboss(Tok.R.control)
    }
}

// MARK: - REC lamp

/// The tally lamp and its silkscreened caption.
///
/// The blink is driven by a `TimelineView` rather than a repeating animation
/// precisely so it can be stopped: when the phase leaves `.recording` the
/// timeline is not built at all, so nothing is left ticking in the background.
/// A `repeatForever` attached to state would outlive the phase that started it.
private struct PhaseLamp: View {
    let label: String
    /// The take's start instant while recording; `nil` parks the lamp dark.
    let blinkingSince: Date?

    var body: some View {
        HStack(spacing: Tok.S.s6) {
            if let since = blinkingSince {
                // A tally lamp switches hard rather than fading, so a plain
                // half-period tick is the whole animation.
                TimelineView(.periodic(from: since, by: Tok.M.lampBlink / 2)) { context in
                    let half = Tok.M.lampBlink / 2
                    lens(lit: Int(context.date.timeIntervalSince(since) / half).isMultiple(of: 2))
                }
            } else {
                lens(lit: false)
            }

            Text(label)
                .tokType(Tok.T.hardwareSm)
                .foregroundStyle(blinkingSince == nil ? Tok.C.textSecondary : Tok.C.accent)
                .fixedSize()
        }
    }

    /// The LED itself, set into the plastic behind a dark bezel ring.
    private func lens(lit: Bool) -> some View {
        Circle()
            .fill(lit ? Tok.C.ledLamp : Tok.C.ledLampOff)
            .overlay { Circle().strokeBorder(Tok.C.recordBezel, lineWidth: Tok.W.hairline) }
            .frame(width: Tok.S.s8, height: Tok.S.s8)
            .shadow(
                color: lit ? Tok.C.ledLamp.opacity(Tok.Sh.ledGlowOpacity) : .clear,
                radius: Tok.Sh.ledGlowRadius
            )
    }
}

// MARK: - Level well

/// Fraction of full scale where the meter's red zone begins — the same "0"
/// mark the deck's VU face turns red at. Dimensionless, so it is a calibration
/// constant rather than a design value.
private let overloadPoint: Double = 0.66

/// The cream instrument face the waveform is recessed into.
///
/// Cream rather than a dark window on purpose: it is the bar's only framed
/// instrument, and pairing a cream meter with a bare red readout beside it is
/// exactly what the main deck does, so the HUD reads as the same machine.
/// The face is left unprinted — the trace is the only thing on it.
private struct MeterWell<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ZStack {
            Tok.Grad.meter
            // The trace is inset from the glass. Run flush to the bezel it
            // reads as clipped — as though the face were cut off mid-scale —
            // which is the one thing that stops a small meter looking finished.
            content.padding(.horizontal, Tok.S.s8)
        }
        .frame(maxWidth: .infinity)
        .frame(height: Tok.L.hudWaveHeight + Tok.S.s8)
        .overlay(alignment: .top) {
            // Sheen across the top of the glass, as on the deck's VU meter.
            LinearGradient(colors: [Tok.C.meterGlass, .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: Tok.S.s8)
        }
        .clipShape(RoundedRectangle(cornerRadius: Tok.R.panel, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Tok.R.panel, style: .continuous)
                .strokeBorder(Tok.C.meterBezel, lineWidth: Tok.W.hairline)
        }
        .emboss(Tok.R.panel, inset: true)
    }
}

/// Height of one overload band, measured in from the top (and bottom) of the
/// scale. The red zone is shown purely by tinting the bar tips that cross it —
/// printed rules were tried and removed: at this size they sat against the
/// bezel and read as a broken border rather than as meter marks.
private var overloadBand: CGFloat {
    Tok.L.hudWaveHeight / 2 * (1 - overloadPoint)
}

/// The scrolling microphone trace. Newest sample enters at the right.
private struct LevelWell: View {
    let levels: [CGFloat]

    var body: some View {
        MeterWell {
            BarRow(levels: levels)
                .animation(Tok.M.press, value: levels)
        }
    }
}

/// A symmetric bar trace whose tips go red once they run past the 0 mark.
private struct BarRow: View {
    let levels: [CGFloat]

    var body: some View {
        ZStack {
            bars.foregroundStyle(Tok.C.meterInk)
            // Only the part of a bar that crosses into the overload band is
            // tinted, so a loud syllable reddens its tips the way a real meter
            // does instead of recolouring the whole trace.
            overloadBands.mask { bars }
        }
    }

    private var bars: some View {
        HStack(alignment: .center, spacing: Tok.S.s2) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                // A silent sample collapses to a dot of the bar's own width,
                // which keeps the baseline continuous instead of blank.
                Capsule()
                    .frame(width: Tok.L.hudBarWidth,
                           height: max(Tok.L.hudBarWidth, level * Tok.L.hudWaveHeight))
            }
        }
        .frame(height: Tok.L.hudWaveHeight)
    }

    private var overloadBands: some View {
        Color.clear
            .frame(height: Tok.L.hudWaveHeight)
            .overlay(alignment: .top) { Tok.C.meterDanger.frame(height: overloadBand) }
            .overlay(alignment: .bottom) { Tok.C.meterDanger.frame(height: overloadBand) }
    }
}

// MARK: - Transcribing

/// The same well with the tape still under the head: one slow hump travelling
/// across the scale. It peaks exactly at the 0 mark, so the calm phase can
/// never flash red — nothing is being captured, so nothing can overload.
private struct ScanWell: View {
    /// Width of the travelling hump, in bars.
    private static let span = 6.0
    /// One full sweep takes two lamp blinks — deliberately slower than the
    /// recording trace so the HUD visibly settles down.
    private static let period = Tok.M.lampBlink * 2

    var body: some View {
        MeterWell {
            TimelineView(.animation) { context in
                let elapsed = context.date.timeIntervalSinceReferenceDate
                let progress = elapsed.truncatingRemainder(dividingBy: Self.period) / Self.period
                BarRow(levels: Self.hump(at: progress))
            }
        }
    }

    /// A raised-cosine bump centred on `progress`, entering and leaving off the
    /// ends of the scale so it never pops into existence mid-face.
    private static func hump(at progress: Double) -> [CGFloat] {
        let count = Tok.L.hudBarCount
        let centre = -span + progress * (Double(count - 1) + span * 2)
        return (0..<count).map { index in
            let distance = abs(Double(index) - centre)
            guard distance < span else { return 0 }
            return CGFloat((cos(distance / span * .pi) + 1) / 2 * overloadPoint)
        }
    }
}

// MARK: - Counter

/// The elapsed readout: the deck's COUNTER module in miniature.
///
/// Bare digits on the chassis were tried and reverted. They look lighter in
/// isolation, but this readout is the bar's right-hand bookend, and unframed
/// it could not hold that end against the lamp block opposite — the whole
/// composition leaned. The window gives the right side the weight the left
/// already had, which is what puts the level well on the centre line.
private struct CounterReadout: View {
    let since: Date

    var body: some View {
        // A four-digit MM:SS readout has no sub-second resolution to show, so
        // the timeline ticks once a second and no faster.
        TimelineView(.periodic(from: since, by: 1)) { context in
            SevenSegmentClock(seconds: context.date.timeIntervalSince(since))
        }
        .frame(height: Tok.L.hudWaveHeight)
        .padding(.vertical, Tok.S.s4)
        .padding(.horizontal, Tok.S.s6)
        .background(Tok.C.ledWindow, in: RoundedRectangle(cornerRadius: Tok.R.panel, style: .continuous))
        .emboss(Tok.R.panel, inset: true)
    }
}
