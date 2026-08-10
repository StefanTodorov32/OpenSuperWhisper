import AppKit
import Foundation
import MediaPlayer

/// Which AirPods stem gesture starts and stops a Dictation.
///
/// The AirPods firmware disambiguates these itself and emits a *different*
/// transport command for each, so there is deliberately no press-timing logic
/// anywhere in this file — unlike `AppPreferences.doublePressToTrigger`, which
/// has to measure intervals because a keyboard reports raw key transitions.
///
/// Press-and-hold is absent on purpose: the firmware consumes it for Noise
/// Control or Siri and never forwards it to the Mac, so hold-to-record cannot
/// be expressed through this Trigger.
enum StemPressGesture: String, CaseIterable, Identifiable, Codable {
    case none = "none"
    case single = "single"
    case double = "double"
    case triple = "triple"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: return "None"
        case .single: return "Single press"
        case .double: return "Double press"
        case .triple: return "Triple press"
        }
    }

    /// Claiming the single press costs the user system-wide play/pause, which is
    /// a far bigger daily loss than next- or previous-track. Surfaced in the UI
    /// so the trade-off is visible at the point of choosing.
    var stealsPlayPause: Bool { self == .single }

    /// The `MPRemoteCommand` this gesture arrives as on the Now Playing route.
    var remoteCommand: MPRemoteCommand? {
        let center = MPRemoteCommandCenter.shared()
        switch self {
        case .none: return nil
        case .single: return center.togglePlayPauseCommand
        case .double: return center.nextTrackCommand
        case .triple: return center.previousTrackCommand
        }
    }

    /// The `NX_KEYTYPE_*` code this gesture arrives as on the event-tap route.
    var mediaKeyCode: Int32? {
        switch self {
        case .none: return nil
        case .single: return 16   // NX_KEYTYPE_PLAY
        case .double: return 17   // NX_KEYTYPE_NEXT
        case .triple: return 18   // NX_KEYTYPE_PREVIOUS
        }
    }
}

/// How the stem press is intercepted.
///
/// Which of these actually works is an empirical question — AVRCP transport
/// commands from a Bluetooth headset may be delivered only to the Now Playing
/// app rather than placed on the HID event stream. Both are implemented so the
/// question can be answered by observation instead of speculation.
enum StemPressRoute: String, CaseIterable, Identifiable, Codable {
    /// Observe the media-key event stream. Can pass unclaimed gestures through
    /// to whatever media app would normally receive them, so a double press can
    /// drive Dictation while a single press still pauses Spotify.
    case eventTap = "eventTap"

    /// Become the Now Playing app and receive transport commands directly.
    /// More likely to receive the event at all, but it takes *every* transport
    /// command, so media apps stop responding to the stem entirely.
    case nowPlaying = "nowPlaying"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .eventTap: return "Media key tap"
        case .nowPlaying: return "Now Playing"
        }
    }
}

/// Turns an AirPods stem press into a Dictation Trigger.
///
/// Mirrors `MouseButtonMonitor`'s shape (shared instance, `start`/`stop`, event
/// tap re-enabled after timeout) but exposes a single `onPress` rather than
/// down/up callbacks: a stem press is a completed gesture, not a key transition,
/// so there is no "up" to report.
class RemoteCommandMonitor {
    static let shared = RemoteCommandMonitor()

    /// Fires once per matched stem gesture.
    var onPress: (() -> Void)?

    /// Logs every media-key event and transport command seen, matched or not.
    /// This is how to establish whether the stem is observable at all, and which
    /// route sees it. Off by default because it is noisy.
    var isDiagnosticLoggingEnabled = false

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var gesture: StemPressGesture = .none
    private var route: StemPressRoute = .eventTap
    private var commandTargets: [(command: MPRemoteCommand, target: Any)] = []
    private var claimedNowPlaying = false

    private init() {}

    func start(gesture: StemPressGesture, route: StemPressRoute) {
        stop()

        guard gesture != .none else { return }

        self.gesture = gesture
        self.route = route

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
        gesture = .none
    }

    // MARK: - Route: media key event tap

    private func startEventTap() {
        // NSEvent.EventType.systemDefined. CGEventType has no case for it, so the
        // mask is built from the raw value.
        let eventMask = CGEventMask(1 << 14)

        // A default (not listen-only) tap: a matched gesture must be consumed so
        // it does not *also* skip the current track in the user's media app.
        // Unmatched gestures are passed through untouched, which is what keeps a
        // single press working as play/pause while a double press drives Dictation.
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
            print("RemoteCommandMonitor: Failed to create event tap. Check Input Monitoring permission.")
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)

        if let source = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            print("RemoteCommandMonitor: Started media key tap for \(gesture.displayName)")
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
            print("RemoteCommandMonitor: Re-enabled tap after timeout")
        }
    }

    /// Returns `true` when the event is the bound gesture and should be consumed.
    private func handleSystemDefinedEvent(_ event: CGEvent) -> Bool {
        guard let nsEvent = NSEvent(cgEvent: event) else { return false }

        // Subtype 8 is NX_SUBTYPE_AUX_CONTROL_BUTTONS, which carries the media
        // keys. Other system-defined events (screen changes, power) share the
        // event type and must be ignored.
        guard nsEvent.subtype.rawValue == 8 else { return false }

        // data1 packs the key identity and its state:
        //   bits 16-31  key code (NX_KEYTYPE_*)
        //   bits 8-15   key state, 0xA = down, 0xB = up
        let data = nsEvent.data1
        let keyCode = Int32((data & 0xFFFF_0000) >> 16)
        let keyState = (data & 0xFF00) >> 8
        let isKeyDown = keyState == 0xA

        if isDiagnosticLoggingEnabled {
            print("RemoteCommandMonitor[tap]: keyCode=\(keyCode) state=\(isKeyDown ? "down" : "up") data1=\(data)")
        }

        guard isKeyDown, let target = gesture.mediaKeyCode, keyCode == target else { return false }

        DispatchQueue.main.async {
            self.onPress?()
        }
        return true
    }

    // MARK: - Route: Now Playing

    private func startNowPlaying() {
        // A transport command is only delivered to the app holding Now Playing
        // status, so claiming it is a precondition for receiving anything on this
        // route — not merely cosmetic. The cost is that every transport command
        // now lands here and media apps stop responding to the stem.
        let info = MPNowPlayingInfoCenter.default()
        info.nowPlayingInfo = [
            MPMediaItemPropertyTitle: "Dictation",
            MPMediaItemPropertyArtist: "OpenSuperWhisper",
            MPNowPlayingInfoPropertyPlaybackRate: 1.0
        ]
        info.playbackState = .playing
        claimedNowPlaying = true

        let center = MPRemoteCommandCenter.shared()

        // Every transport command is observed, not just the bound one: on this
        // route we cannot pass anything through anyway, and knowing which
        // commands a stem press produces is the whole point of the exercise.
        let observed: [(String, MPRemoteCommand)] = [
            ("togglePlayPause", center.togglePlayPauseCommand),
            ("play", center.playCommand),
            ("pause", center.pauseCommand),
            ("nextTrack", center.nextTrackCommand),
            ("previousTrack", center.previousTrackCommand)
        ]

        let boundCommand = gesture.remoteCommand

        for (name, command) in observed {
            command.isEnabled = true
            let target = command.addTarget { [weak self] _ in
                guard let self = self else { return .commandFailed }

                if self.isDiagnosticLoggingEnabled {
                    print("RemoteCommandMonitor[nowPlaying]: received \(name)")
                }

                if command === boundCommand {
                    DispatchQueue.main.async {
                        self.onPress?()
                    }
                }
                return .success
            }
            commandTargets.append((command, target))
        }

        print("RemoteCommandMonitor: Claimed Now Playing for \(gesture.displayName)")
    }

    private func stopNowPlaying() {
        for (command, target) in commandTargets {
            command.removeTarget(target)
        }
        commandTargets.removeAll()

        guard claimedNowPlaying else { return }
        claimedNowPlaying = false

        // Release Now Playing so media apps regain stem control immediately
        // rather than at quit.
        let info = MPNowPlayingInfoCenter.default()
        info.playbackState = .stopped
        info.nowPlayingInfo = nil
    }

    deinit {
        stop()
    }
}
