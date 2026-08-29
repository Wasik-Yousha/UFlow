import AppKit
import Carbon.HIToolbox
import CoreGraphics

/// Global push-to-talk trigger manager.
///
/// Default trigger: hold **Fn/Globe + Y** together. This combination has no
/// system binding, which sidesteps every Globe-alone system action (input
/// source switching, emoji panel) while remaining fully global — it works no
/// matter which application is frontmost.
///
/// Implementation notes:
/// - A session-level `CGEventTap` observes `keyDown`, `keyUp`, and
///   `flagsChanged`. The tap is active (not listen-only) so the chord's Y can be
///   swallowed — otherwise holding Fn+Y types a literal "y" into whatever text
///   field is focused. Only the chord's own Y is consumed: plain Y typing and
///   the Fn flag itself always pass through untouched.
/// - Fn is NOT modeled as a plain keyDown: it is tracked via `flagsChanged`
///   events carrying `keyCode == kVK_Function (63)` and the
///   `.maskSecondaryFn` flag, with explicit edge detection so repeated events
///   cannot start overlapping sessions.
/// - The trigger fires exactly once on the DOWN edge (Fn down AND Y down) and
///   exactly once on the UP edge (either key lifts).
/// - The trigger is data-driven (`HotkeyTrigger`), so the combination can be
///   changed later without touching the state machine.
/// - When Secure Event Input is active, macOS stops delivering events to taps;
///   the manager simply goes quiet, which is the desired behavior around
///   password fields.
@MainActor
final class HotkeyManager {
    /// Describes the push-to-talk combination. Set from Settings.
    struct Trigger: Equatable {
        /// The modifier key tracked via `flagsChanged`. Fn/Globe by default:
        /// it has no system binding of its own when paired with a letter.
        var modifierKeyCode: Int = kVK_Function
        /// The letter that completes the chord. `nil` means the modifier is
        /// the whole trigger — e.g. holding Fn alone with no paired key.
        var triggerKeyCode: Int? = kVK_ANSI_Y

        /// The event flag the chosen modifier raises. Driven off the key code
        /// so the two can never disagree.
        var modifierFlag: CGEventFlags {
            switch modifierKeyCode {
            case kVK_Control: .maskControl
            case kVK_Option: .maskAlternate
            case kVK_Command: .maskCommand
            case kVK_Shift: .maskShift
            default: .maskSecondaryFn
            }
        }

        var displayName: String {
            guard let triggerKeyCode else { return Self.modifierName(modifierKeyCode) }
            return "\(Self.modifierName(modifierKeyCode)) + \(Self.keyName(triggerKeyCode))"
        }

        static func modifierName(_ code: Int) -> String {
            switch code {
            case kVK_Control: "Control"
            case kVK_Option: "Option"
            case kVK_Command: "Command"
            case kVK_Shift: "Shift"
            default: "Fn"
            }
        }

        /// The letter keys offered in Settings, in keyboard order.
        static let letterKeys: [(code: Int, name: String)] = [
            (kVK_ANSI_Q, "Q"), (kVK_ANSI_W, "W"), (kVK_ANSI_E, "E"), (kVK_ANSI_R, "R"),
            (kVK_ANSI_T, "T"), (kVK_ANSI_Y, "Y"), (kVK_ANSI_U, "U"), (kVK_ANSI_I, "I"),
            (kVK_ANSI_O, "O"), (kVK_ANSI_P, "P"), (kVK_ANSI_A, "A"), (kVK_ANSI_S, "S"),
            (kVK_ANSI_D, "D"), (kVK_ANSI_F, "F"), (kVK_ANSI_G, "G"), (kVK_ANSI_H, "H"),
            (kVK_ANSI_J, "J"), (kVK_ANSI_K, "K"), (kVK_ANSI_L, "L"), (kVK_ANSI_Z, "Z"),
            (kVK_ANSI_X, "X"), (kVK_ANSI_C, "C"), (kVK_ANSI_V, "V"), (kVK_ANSI_B, "B"),
            (kVK_ANSI_N, "N"), (kVK_ANSI_M, "M"),
        ]

        static let modifierKeys: [(code: Int, name: String)] = [
            (kVK_Function, "Fn"), (kVK_Control, "Control"),
            (kVK_Option, "Option"), (kVK_Command, "Command"),
        ]

        static func keyName(_ code: Int) -> String {
            letterKeys.first { $0.code == code }?.name ?? "?"
        }
    }

    private(set) var trigger = Trigger()

    /// Swaps the chord. Chord state is reset so a half-held old combination
    /// cannot leave the manager thinking a key is still down.
    func setTrigger(_ newValue: Trigger) {
        guard newValue != trigger else { return }
        trigger = newValue
        resetChordState()
        Log.hotkey.info("Trigger set to \(newValue.displayName, privacy: .public)")
    }

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    // Raw key states (main thread only — the tap source is added to the main run loop).
    private var isModifierDown = false
    private var isTriggerKeyDown = false
    private var isActive = false

    /// Called on the main thread when the chord completes (start dictation).
    var onTriggerDown: (() -> Void)?
    /// Called on the main thread when the chord breaks (stop dictation).
    var onTriggerUp: (() -> Void)?

    var isInstalled: Bool { tap != nil }

    // MARK: - Install / remove

    /// Installs the global event tap. Returns false (and logs) when the system
    /// denies creation — usually missing Input Monitoring access.
    func install() -> Bool {
        if tap != nil { return true }

        let eventMask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)

        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { proxy, type, event, refcon in
                HotkeyManager.tapCallback(proxy: proxy, type: type, event: event, refcon: refcon)
            },
            userInfo: context
        ) else {
            Log.hotkey.error("CGEvent.tapCreate failed — Input Monitoring access likely missing")
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)

        tap = port
        runLoopSource = source
        Log.hotkey.info("Hotkey tap installed (Fn+Y)")
        return true
    }

    func uninstall() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            }
        }
        tap = nil
        runLoopSource = nil
        isModifierDown = false
        isTriggerKeyDown = false
        isActive = false
    }

    /// Re-enables a tap the system disabled (timeout/user-input backpressure).
    private func reenableTap() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
        Log.hotkey.info("Event tap re-enabled")
    }

    // MARK: - Callback plumbing

    private static func tapCallback(
        proxy: CGEventTapProxy,
        type: CGEventType,
        event: CGEvent,
        refcon: UnsafeMutableRawPointer?
    ) -> Unmanaged<CGEvent>? {
        // The tap source lives on the main run loop, so we are on the main
        // thread here and can hop onto MainActor without suspension.
        guard let refcon else { return Unmanaged.passUnretained(event) }
        let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()

        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            Log.hotkey.warning("Event tap disabled (type \(type.rawValue)); re-enabling")
            MainActor.assumeIsolated {
                manager.reenableTap()
            }
            return Unmanaged.passUnretained(event)
        default:
            break
        }

        let consume = MainActor.assumeIsolated {
            manager.handle(event: event, type: type)
        }

        // Swallow only the chord's own Y; everything else passes through.
        return consume ? nil : Unmanaged.passUnretained(event)
    }

    // MARK: - Edge detection

    /// Returns true when the event is part of the chord and must be swallowed
    /// so it never reaches the focused application.
    private func handle(event: CGEvent, type: CGEventType) -> Bool {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        switch type {
        case .flagsChanged:
            guard keyCode == trigger.modifierKeyCode else { return false }
            let modifierNowDown = event.flags.contains(trigger.modifierFlag)
            guard modifierNowDown != isModifierDown else { return false } // ignore duplicate events
            isModifierDown = modifierNowDown
            evaluate()
            // Never swallow the modifier itself — the system needs it for
            // everything else the user does with that key.
            return false

        case .keyDown:
            guard let triggerKeyCode = trigger.triggerKeyCode, keyCode == triggerKeyCode else { return false }
            // Only treat the letter as part of the chord when the modifier is
            // in play. Typing that letter normally passes through untouched.
            guard isModifierDown || event.flags.contains(trigger.modifierFlag) else { return false }
            guard !isTriggerKeyDown else { return true } // key-repeat: swallow too
            isTriggerKeyDown = true
            evaluate()
            return true

        case .keyUp:
            guard let triggerKeyCode = trigger.triggerKeyCode, keyCode == triggerKeyCode else { return false }
            guard isTriggerKeyDown else { return false }
            isTriggerKeyDown = false
            evaluate()
            // The matching keyDown was swallowed, so swallow the keyUp as well.
            return true

        default:
            return false
        }
    }

    /// Recomputes chord state and fires edge callbacks exactly once per transition.
    private func evaluate() {
        let nowActive = trigger.triggerKeyCode == nil ? isModifierDown : (isModifierDown && isTriggerKeyDown)
        guard nowActive != isActive else { return }
        isActive = nowActive

        if nowActive {
            Log.hotkey.info("Trigger DOWN (\(self.trigger.displayName, privacy: .public))")
            onTriggerDown?()
        } else {
            Log.hotkey.info("Trigger UP")
            onTriggerUp?()
        }
    }

    /// Forces the chord open in case a keyUp was lost (e.g. focus change mid-hold).
    /// Called defensively when a dictation session ends.
    func resetChordState() {
        isModifierDown = false
        isTriggerKeyDown = false
        isActive = false
    }
}
