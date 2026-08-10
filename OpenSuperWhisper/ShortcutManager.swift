import AppKit
import ApplicationServices
import Carbon
import Cocoa
import Foundation
import KeyboardShortcuts
import SwiftUI

extension KeyboardShortcuts.Name {
    static let toggleRecord = Self("toggleRecord", default: .init(.backtick, modifiers: .option))
    static let escape = Self("escape", default: .init(.escape))
}

class ShortcutManager {
    static let shared = ShortcutManager()

    private var activeVm: IndicatorViewModel?
    private var holdWorkItem: DispatchWorkItem?
    private let holdThreshold: TimeInterval = 0.3

    /// Upper bound on a single Dictation.
    ///
    /// Upstream has no bound at all, which is tolerable when the Trigger is a key:
    /// a dropped stop press is unlikely, and the user is sitting at the keyboard. A
    /// stem press travels over Bluetooth and can be lost, which would leave a
    /// recording running until the app quits and then insert an enormous
    /// Transcription into whatever holds focus.
    private var maxDurationWorkItem: DispatchWorkItem?
    private let maxRecordingDuration: TimeInterval = 60
    private var holdMode = false
    private var useModifierOnlyHotkey = false
    private var useMouseButtonHotkey = false
    private var lastPressDownTime: CFAbsoluteTime = 0
    private var pressConsumed = false

    private init() {
        print("ShortcutManager init")

        setupKeyboardShortcuts()
        setupRecordingTrigger()
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(hotkeySettingsChanged),
            name: .hotkeySettingsChanged,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(indicatorWindowDidHide),
            name: .indicatorWindowDidHide,
            object: nil
        )
    }
    
    @objc private func indicatorWindowDidHide() {
        activeVm = nil
        holdMode = false
        cancelMaxDurationStop()
    }
    
    @objc private func hotkeySettingsChanged() {
        setupRecordingTrigger()
    }
    
    private func setupKeyboardShortcuts() {
        KeyboardShortcuts.onKeyDown(for: .toggleRecord) { [weak self] in
            self?.handleKeyDown()
        }

        KeyboardShortcuts.onKeyUp(for: .toggleRecord) { [weak self] in
            self?.handleKeyUp()
        }

        KeyboardShortcuts.onKeyUp(for: .escape) { [weak self] in
            Task { @MainActor in
                if self?.activeVm != nil, IndicatorWindowManager.shared.requestCancel() {
                    self?.activeVm = nil
                }
            }
        }
        KeyboardShortcuts.disable(.escape)
    }
    
    private func setupRecordingTrigger() {
        let modifierKey = ModifierKey(rawValue: AppPreferences.shared.modifierOnlyHotkey) ?? .none
        let mouseButton = MouseButton(rawValue: AppPreferences.shared.mouseButtonHotkey) ?? .none

        // The three trigger modes are mutually exclusive. Tear all of them down
        // first, then enable exactly one. A configured mouse button takes priority
        // over a modifier key, which takes priority over the regular shortcut.
        ModifierKeyMonitor.shared.stop()
        MouseButtonMonitor.shared.stop()

        if mouseButton != .none {
            useMouseButtonHotkey = true
            useModifierOnlyHotkey = false
            KeyboardShortcuts.disable(.toggleRecord)

            MouseButtonMonitor.shared.onButtonDown = { [weak self] in
                self?.handleKeyDown()
            }

            MouseButtonMonitor.shared.onButtonUp = { [weak self] in
                self?.handleKeyUp()
            }

            MouseButtonMonitor.shared.start(mouseButton: mouseButton)
            print("ShortcutManager: Using mouse-button hotkey: \(mouseButton.displayName)")
        } else if modifierKey != .none {
            useMouseButtonHotkey = false
            useModifierOnlyHotkey = true
            KeyboardShortcuts.disable(.toggleRecord)

            ModifierKeyMonitor.shared.onKeyDown = { [weak self] in
                self?.handleKeyDown()
            }

            ModifierKeyMonitor.shared.onKeyUp = { [weak self] in
                self?.handleKeyUp()
            }

            ModifierKeyMonitor.shared.onComboDetected = { [weak self] in
                self?.abandonDictationStartedByChord()
            }

            lastPressDownTime = 0
            pressConsumed = false
            ModifierKeyMonitor.shared.start(modifierKey: modifierKey)
            print("ShortcutManager: Using modifier-only hotkey: \(modifierKey.displayName) (double-press: \(AppPreferences.shared.doublePressToTrigger))")
        } else {
            useMouseButtonHotkey = false
            useModifierOnlyHotkey = false
            KeyboardShortcuts.enable(.toggleRecord)
            print("ShortcutManager: Using regular keyboard shortcut")
        }

        setupStemPressTrigger()
    }

    /// Configured *in addition to* whichever Trigger above is active, not instead of
    /// it.
    ///
    /// The three above are mutually exclusive because they all deliver key-like
    /// down/up pairs into the same handlers and would double-fire each other. The
    /// AirPods stem is a separate device reporting completed gestures, so it cannot
    /// collide with them — and forcing the user to surrender their keyboard shortcut
    /// as the price of using AirPods would be a poor trade.
    private func setupStemPressTrigger() {
        RemoteCommandMonitor.shared.stop()

        guard AppPreferences.shared.stemPressEnabled else { return }

        let route = StemPressRoute(rawValue: AppPreferences.shared.stemPressRoute) ?? .nowPlaying

        // Debug builds log every media key and transport command seen, accepted or
        // ignored, so the behaviour of unfamiliar remotes can be established the same
        // way the AirPods behaviour was.
        #if DEBUG
        RemoteCommandMonitor.shared.isDiagnosticLoggingEnabled = true
        #endif

        RemoteCommandMonitor.shared.onPress = { [weak self] in
            self?.handleDiscretePress()
        }

        RemoteCommandMonitor.shared.start(route: route)
        NSLog("ShortcutManager: Using stem-press trigger via \(route.displayName)")
    }
    
    private func handleKeyDown() {
        holdWorkItem?.cancel()
        holdMode = false

        // Require a double-tap only when starting a new recording. Once recording is
        // active, a single press stops it so the user isn't forced to double-tap again.
        if AppPreferences.shared.doublePressToTrigger && activeVm == nil {
            let now = CFAbsoluteTimeGetCurrent()
            let threshold = NSEvent.doubleClickInterval
            if lastPressDownTime > 0 && now - lastPressDownTime <= threshold {
                lastPressDownTime = 0
            } else {
                lastPressDownTime = now
                pressConsumed = false
                return
            }
        }
        pressConsumed = true

        let holdToRecordEnabled = AppPreferences.shared.holdToRecord
        let isStartingRecording = activeVm == nil

        toggleRecording(respectHoldMode: true)

        // Arm hold mode only when this press starts a recording. Arming it on the
        // stopping press would trigger a second stop on key-up.
        if holdToRecordEnabled && isStartingRecording {
            let workItem = DispatchWorkItem { [weak self] in
                self?.holdMode = true
            }
            holdWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + holdThreshold, execute: workItem)
        }
    }

    /// Starts a Dictation, or stops the one already in progress.
    ///
    /// `respectHoldMode` is false for Triggers that report a completed gesture rather
    /// than a key transition: no key-up is coming to end a hold, so such a press must
    /// always be allowed to stop recording.
    private func toggleRecording(respectHoldMode: Bool) {
        Task { @MainActor in
            if self.activeVm == nil {
                // Capture the Target App first, before any window is presented, so
                // Insertion can refuse to paste if focus moves while transcribing.
                // Safe here because the Indicator is a non-activating panel and so
                // never makes this app frontmost.
                TargetAppGuard.shared.capture()

                // Start recording immediately: resolving the caret position talks to
                // the focused app via AX IPC and can hang for seconds if that app
                // is busy — the first words must not be lost because of it.
                let vm = IndicatorWindowManager.shared.prepare()
                vm.startRecording()
                self.activeVm = vm

                let cursorPosition = FocusUtils.getCurrentCursorPosition()
                let anchorPoint = await Self.resolveAnchorPoint(timeoutNanoseconds: 150_000_000)
                let indicatorPoint = anchorPoint ?? cursorPosition

                IndicatorWindowManager.shared.presentWindow(for: vm, nearPoint: indicatorPoint)
                self.scheduleMaxDurationStop()
            } else if !respectHoldMode || !self.holdMode {
                self.cancelMaxDurationStop()
                IndicatorWindowManager.shared.stopRecording()
                self.activeVm = nil
            }
        }
    }

    private func scheduleMaxDurationStop() {
        cancelMaxDurationStop()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            Task { @MainActor in
                guard self.activeVm != nil else { return }
                print("ShortcutManager: max recording duration reached, stopping")
                IndicatorWindowManager.shared.stopRecording()
                self.activeVm = nil
            }
        }
        maxDurationWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + maxRecordingDuration, execute: workItem)
    }

    private func cancelMaxDurationStop() {
        maxDurationWorkItem?.cancel()
        maxDurationWorkItem = nil
    }

    /// Discards a Dictation that was started by a modifier press which turned out to
    /// be part of a chord.
    ///
    /// The modifier monitor fires on key-down, so it cannot know yet whether the user
    /// is starting a Dictation or typing ⌘C. Starting and then abandoning is the only
    /// order available: delaying the start instead would cost the opening words of
    /// every genuine Dictation, which the anchor-resolution timeout above exists to
    /// protect.
    ///
    /// `requestCancel` discards the audio without transcribing. Its confirmation
    /// prompt only applies to recordings past ten seconds, so a chord abort — which
    /// happens within milliseconds — is always immediate.
    private func abandonDictationStartedByChord() {
        holdWorkItem?.cancel()
        holdWorkItem = nil
        holdMode = false
        pressConsumed = false
        cancelMaxDurationStop()

        Task { @MainActor in
            guard self.activeVm != nil else { return }
            if IndicatorWindowManager.shared.requestCancel() {
                self.activeVm = nil
                NSLog("ShortcutManager: modifier was part of a chord, dictation discarded")
            }
        }
    }

    /// Entry point for a Trigger with no press-and-hold dimension — currently the
    /// AirPods stem, whose firmware reports a completed gesture and keeps
    /// press-and-hold for Noise Control or Siri.
    ///
    /// `doublePressToTrigger` is deliberately not consulted: the firmware already
    /// disambiguated a double press into its own transport command, so gating on
    /// interval as well would demand four squeezes to start recording.
    private func handleDiscretePress() {
        holdWorkItem?.cancel()
        holdWorkItem = nil
        holdMode = false
        toggleRecording(respectHoldMode: false)
    }

    /// Resolves the input anchor without letting a slow focused app delay the
    /// indicator: whichever finishes first wins — the AX resolution or the
    /// deadline. On timeout the caller falls back to the mouse position; the
    /// late AX result is simply discarded.
    private static func resolveAnchorPoint(timeoutNanoseconds: UInt64) async -> NSPoint? {
        await withCheckedContinuation { (continuation: CheckedContinuation<NSPoint?, Never>) in
            let gate = AnchorGate(continuation)
            Task.detached {
                let point = FocusUtils.getInputAnchorPoint()
                await gate.resume(point)
            }
            Task.detached {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                await gate.resume(nil)
            }
        }
    }

    private actor AnchorGate {
        private var continuation: CheckedContinuation<NSPoint?, Never>?

        init(_ continuation: CheckedContinuation<NSPoint?, Never>) {
            self.continuation = continuation
        }

        func resume(_ value: NSPoint?) {
            continuation?.resume(returning: value)
            continuation = nil
        }
    }

    private func handleKeyUp() {
        holdWorkItem?.cancel()
        holdWorkItem = nil

        guard pressConsumed else { return }
        pressConsumed = false

        let holdToRecordEnabled = AppPreferences.shared.holdToRecord

        Task { @MainActor in
            if holdToRecordEnabled && self.holdMode && self.activeVm != nil {
                IndicatorWindowManager.shared.stopRecording()
                self.activeVm = nil
            }
            self.holdMode = false
        }
    }
}