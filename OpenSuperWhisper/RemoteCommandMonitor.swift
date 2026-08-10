import AppKit
import Foundation
import MediaPlayer

/// How an AirPods stem press is intercepted.
///
/// Determined empirically, not by preference — see
/// `docs/adr/0004-stem-press-arrives-via-now-playing.md`. A stem press is an AVRCP
/// transport command routed by MediaRemote to the app holding Now Playing status; it
/// never enters the HID event stream, so the event-tap route observes nothing on
/// AirPods Pro. It is kept only because other remotes (wired headsets, some
/// keyboards) do emit real media keys.
enum StemPressRoute: String, CaseIterable, Identifiable, Codable {
    /// Become the Now Playing app and receive transport commands directly. The only
    /// route that works for AirPods. Takes every transport command, so media apps
    /// stop responding to the stem while it is active.
    case nowPlaying = "nowPlaying"

    /// Observe the media-key event stream. Verified *not* to receive AirPods presses
    /// on macOS 26; retained for remotes that emit genuine media keys.
    case eventTap = "eventTap"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .nowPlaying: return "Now Playing"
        case .eventTap: return "Media key tap"
        }
    }
}

/// Turns an AirPods stem press into a Dictation Trigger.
///
/// Mirrors `MouseButtonMonitor`'s shape (shared instance, `start`/`stop`, event tap
/// re-enabled after timeout) but exposes a single `onPress` rather than down/up
/// callbacks: a stem press is a completed gesture, not a key transition, so there is
/// no "up" to report.
///
/// Any transport command counts as a press. Distinguishing single from double from
/// triple squeezes is impossible here — every gesture arrives as the same command
/// (`play` in testing), so gesture identity simply is not in the signal.
class RemoteCommandMonitor {
    static let shared = RemoteCommandMonitor()

    /// Fires once per accepted stem press.
    var onPress: (() -> Void)?

    /// Logs every media key and transport command seen, accepted or ignored.
    var isDiagnosticLoggingEnabled = false

    /// Minimum gap between two accepted presses.
    ///
    /// One squeeze can produce more than one transport command — measured at 0.527s
    /// and 0.524s apart on AirPods Pro — and because every press toggles, an
    /// un-cooled second command would start a Dictation and immediately stop it.
    /// Deliberately wider than the ~0.5s double-click interval for that reason.
    /// The cost is that a deliberate stop within 0.8s of starting is ignored, which
    /// no one does.
    private let pressCooldown: TimeInterval = 0.8
    private var lastAcceptedPress: CFAbsoluteTime = 0

    /// `NX_KEYTYPE_PLAY`, `_NEXT`, `_PREVIOUS`.
    private let watchedMediaKeyCodes: Set<Int32> = [16, 17, 18]

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var route: StemPressRoute = .nowPlaying
    private var commandTargets: [(command: MPRemoteCommand, target: Any)] = []
    private var claimedNowPlaying = false

    private init() {}

    func start(route: StemPressRoute) {
        stop()

        self.route = route
        lastAcceptedPress = 0

        switch route {
        case .eventTap:
            startEventTap()
        case .nowPlaying:
            startNowPlaying()
        }
    }

    func stop() {
        stopEventTap()
        stopNowPlaying()
    }

    /// Debounces, then reports a press. See `pressCooldown`.
    private func acceptPress(_ source: String) {
        let now = CFAbsoluteTimeGetCurrent()
        let sinceLast = now - lastAcceptedPress

        if lastAcceptedPress > 0 && sinceLast < pressCooldown {
            if isDiagnosticLoggingEnabled {
                NSLog("RemoteCommandMonitor: ignored \(source) (\(String(format: "%.3f", sinceLast))s since last, cooldown \(pressCooldown)s)")
            }
            return
        }

        lastAcceptedPress = now
        NSLog("RemoteCommandMonitor: press accepted via \(source)")

        DispatchQueue.main.async {
            self.onPress?()
        }
    }

    // MARK: - Route: Now Playing

    private func startNowPlaying() {
        // A transport command is only delivered to the app holding Now Playing
        // status, so claiming it is a precondition for receiving anything — not
        // cosmetic. The cost is that every transport command lands here and media
        // apps stop responding to the stem.
        let info = MPNowPlayingInfoCenter.default()
        info.nowPlayingInfo = [
            MPMediaItemPropertyTitle: "Dictation",
            MPMediaItemPropertyArtist: "OpenSuperWhisper",
            MPNowPlayingInfoPropertyPlaybackRate: 1.0
        ]
        info.playbackState = .playing
        claimedNowPlaying = true

        let center = MPRemoteCommandCenter.shared()

        // Every transport command is bound, because gesture identity is not
        // recoverable: in testing a single, double and triple squeeze all arrived as
        // `play`. Whichever command turns up, the user squeezed the stem.
        let commands: [(String, MPRemoteCommand)] = [
            ("togglePlayPause", center.togglePlayPauseCommand),
            ("play", center.playCommand),
            ("pause", center.pauseCommand),
            ("nextTrack", center.nextTrackCommand),
            ("previousTrack", center.previousTrackCommand)
        ]

        for (name, command) in commands {
            command.isEnabled = true
            let target = command.addTarget { [weak self] _ in
                guard let self = self else { return .commandFailed }
                self.acceptPress(name)
                return .success
            }
            commandTargets.append((command, target))
        }

        NSLog("RemoteCommandMonitor: Claimed Now Playing; any transport command triggers")
    }

    private func stopNowPlaying() {
        for (command, target) in commandTargets {
            command.removeTarget(target)
        }
        commandTargets.removeAll()

        guard claimedNowPlaying else { return }
        claimedNowPlaying = false

        // Release Now Playing so media apps regain stem control immediately rather
        // than at quit.
        let info = MPNowPlayingInfoCenter.default()
        info.playbackState = .stopped
        info.nowPlayingInfo = nil
    }

    // MARK: - Route: media key event tap

    private func startEventTap() {
        // NSEvent.EventType.systemDefined. CGEventType has no case for it, so the
        // mask is built from the raw value.
        let eventMask = CGEventMask(1 << 14)

        // A default (not listen-only) tap: a matched key must be consumed so it does
        // not also act on the user's media app.
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else {
                    return Unmanaged.passUnretained(event)
                }

                let monitor = Unmanaged<RemoteCommandMonitor>.fromOpaque(refcon).takeUnretainedValue()

                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    monitor.reenableTap()
                    return Unmanaged.passUnretained(event)
                }

                if monitor.handleSystemDefinedEvent(event) {
                    return nil
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            NSLog("RemoteCommandMonitor: Failed to create event tap. Check Input Monitoring permission.")
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)

        if let source = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            NSLog("RemoteCommandMonitor: Started media key tap")
        }
    }

    private func stopEventTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            }
        }
        eventTap = nil
        runLoopSource = nil
    }

    fileprivate func reenableTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
            NSLog("RemoteCommandMonitor: Re-enabled tap after timeout")
        }
    }

    /// Returns `true` when the event is a watched media key and should be consumed.
    private func handleSystemDefinedEvent(_ event: CGEvent) -> Bool {
        guard let nsEvent = NSEvent(cgEvent: event) else { return false }

        // Subtype 8 is NX_SUBTYPE_AUX_CONTROL_BUTTONS, which carries the media keys.
        // Other system-defined events (screen changes, power) share the event type
        // and must be ignored.
        guard nsEvent.subtype.rawValue == 8 else { return false }

        // data1 packs the key identity and its state:
        //   bits 16-31  key code (NX_KEYTYPE_*)
        //   bits 8-15   key state, 0xA = down, 0xB = up
        let data = nsEvent.data1
        let keyCode = Int32((data & 0xFFFF_0000) >> 16)
        let isKeyDown = ((data & 0xFF00) >> 8) == 0xA

        if isDiagnosticLoggingEnabled {
            NSLog("RemoteCommandMonitor[tap]: keyCode=\(keyCode) state=\(isKeyDown ? "down" : "up")")
        }

        guard isKeyDown, watchedMediaKeyCodes.contains(keyCode) else { return false }

        acceptPress("mediaKey \(keyCode)")
        return true
    }

    deinit {
        stop()
    }
}
