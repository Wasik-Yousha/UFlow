import AppKit
import AVFoundation
import ApplicationServices
import CoreGraphics

/// Combined permission snapshot used by the UI and by session gating.
struct PermissionState: Equatable {
    let microphoneGranted: Bool
    let accessibilityGranted: Bool
    let listenEventGranted: Bool
    let postEventGranted: Bool

    /// Permissions that BLOCK dictation sessions. Accessibility is tracked and
    /// displayed for completeness but is not required by the chosen injection
    /// strategy (no AX APIs are used), so it must not gate the pipeline.
    var allGranted: Bool {
        microphoneGranted && listenEventGranted && postEventGranted
    }

    /// Names of the blocking permissions still missing (for status display).
    var missingBlockingNames: [String] {
        var names: [String] = []
        if !microphoneGranted { names.append("Microphone") }
        if !listenEventGranted { names.append("Input Monitoring") }
        if !postEventGranted { names.append("Event Posting") }
        return names
    }

    /// Human-readable summary line for the status-bar menu.
    var summaryLines: [(name: String, granted: Bool)] {
        [
            ("Microphone", microphoneGranted),
            ("Accessibility", accessibilityGranted),
            ("Input Monitoring", listenEventGranted),
            ("Event Posting", postEventGranted),
        ]
    }
}

/// Centralizes macOS permission checking and one-time prompting for everything
/// the dictation pipeline needs: microphone capture, global event listening,
/// synthetic event posting, and (informationally) Accessibility.
///
/// The manager never crashes on denial and never bombards the user: each
/// system prompt is raised at most once per launch, and status is re-checked
/// passively whenever the state is read.
@MainActor
final class PermissionManager: ObservableObject {
    @Published private(set) var state = PermissionState(
        microphoneGranted: false,
        accessibilityGranted: false,
        listenEventGranted: false,
        postEventGranted: false
    )

    private var didPromptMicrophoneThisLaunch = false
    private var didPromptAccessibilityThisLaunch = false
    private var didPromptListenEventsThisLaunch = false
    private var didPromptPostEventsThisLaunch = false

    // MARK: - Status

    func refresh() {
        let mic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let ax = AXIsProcessTrusted()
        let listen = CGPreflightListenEventAccess()
        let post = CGPreflightPostEventAccess()

        state = PermissionState(
            microphoneGranted: mic,
            accessibilityGranted: ax,
            listenEventGranted: listen,
            postEventGranted: post
        )
        Log.permissions.info("Permissions refreshed — mic=\(mic, privacy: .public) ax=\(ax, privacy: .public) listen=\(listen, privacy: .public) post=\(post, privacy: .public)")
    }

    // MARK: - Requests (each prompts at most once per launch)

    /// Requests microphone access. Safe to call repeatedly.
    ///
    /// Uses AVCaptureDevice, not AVAudioApplication.requestRecordPermission():
    /// the latter is the iOS-lineage API and on AppKit it returns immediately
    /// without ever raising the TCC dialog, leaving the app permanently
    /// undetermined and absent from System Settings › Microphone.
    func requestMicrophoneIfNeeded() async -> Bool {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
            refresh()
            return true
        }
        if !didPromptMicrophoneThisLaunch {
            didPromptMicrophoneThisLaunch = true
            Log.permissions.info("Requesting microphone permission")
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
        refresh()
        return state.microphoneGranted
    }

    /// Prompts the Accessibility trust dialog (without granting) once per launch.
    func promptAccessibilityIfNeeded() {
        guard !state.accessibilityGranted else { return }
        guard !didPromptAccessibilityThisLaunch else { return }
        didPromptAccessibilityThisLaunch = true
        Log.permissions.info("Raising Accessibility trust prompt")
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        refresh()
    }

    /// Requests global event-listen access (Input Monitoring family). May show a prompt.
    func requestListenEventAccessIfNeeded() async -> Bool {
        if CGPreflightListenEventAccess() {
            refresh()
            return true
        }
        if !didPromptListenEventsThisLaunch {
            didPromptListenEventsThisLaunch = true
            Log.permissions.info("Requesting event-listen access")
            // The request call may block briefly while the prompt shows; keep it off MainActor.
            _ = await Task.detached(priority: .userInitiated) {
                CGRequestListenEventAccess()
            }.value
        }
        refresh()
        return state.listenEventGranted
    }

    /// Requests synthetic event-post access. May show a prompt.
    func requestPostEventAccessIfNeeded() async -> Bool {
        if CGPreflightPostEventAccess() {
            refresh()
            return true
        }
        if !didPromptPostEventsThisLaunch {
            didPromptPostEventsThisLaunch = true
            Log.permissions.info("Requesting event-post access")
            _ = await Task.detached(priority: .userInitiated) {
                CGRequestPostEventAccess()
            }.value
        }
        refresh()
        return state.postEventGranted
    }

    // MARK: - System Settings navigation

    func openRelevantSettingsPane() {
        if !state.microphoneGranted {
            Self.openPrivacyPane("Privacy_Microphone")
        } else if !state.listenEventGranted {
            Self.openPrivacyPane("Privacy_ListenEvent")
        } else if !state.postEventGranted || !state.accessibilityGranted {
            Self.openPrivacyPane("Privacy_Accessibility")
        } else {
            Self.openPrivacyPane("Privacy_Accessibility")
        }
    }

    private static func openPrivacyPane(_ anchor: String) {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
        if let url {
            NSWorkspace.shared.open(url)
        }
    }
}
