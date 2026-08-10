import AppKit
import Foundation

/// Remembers which application a Dictation was started for, so a Transcription is
/// never inserted into an application the user did not choose.
///
/// Insertion synthesises Cmd+V into whatever holds focus, and transcription is not
/// instantaneous — a large model takes seconds. A keyboard Trigger makes a mismatch
/// unlikely, because pressing a key proves the user was at the keyboard looking at
/// the target. A hands-free Trigger proves nothing of the sort. See
/// `docs/adr/0003-insertion-targets-captured-app.md`.
///
/// Safe to consult from any Trigger: the Indicator is a non-activating panel, so
/// showing it never makes OpenSuperWhisper itself the frontmost application.
final class TargetAppGuard {
    static let shared = TargetAppGuard()

    private(set) var bundleIdentifier: String?
    private(set) var localizedName: String?

    private init() {}

    /// Records the Target App. Call as a Dictation starts, before any window is
    /// presented.
    func capture() {
        let app = NSWorkspace.shared.frontmostApplication
        bundleIdentifier = app?.bundleIdentifier
        localizedName = app?.localizedName
        print("TargetAppGuard: captured \(localizedName ?? "unknown") (\(bundleIdentifier ?? "no bundle id"))")
    }

    func clear() {
        bundleIdentifier = nil
        localizedName = nil
    }

    /// `true` when the Target App still holds focus, `false` when focus has moved,
    /// and `nil` when no Target App was captured at all — as when transcribing a
    /// dropped file, where there is no meaningful target and the caller should keep
    /// its previous behaviour.
    var isTargetStillFrontmost: Bool? {
        guard let captured = bundleIdentifier else { return nil }
        return NSWorkspace.shared.frontmostApplication?.bundleIdentifier == captured
    }
}
