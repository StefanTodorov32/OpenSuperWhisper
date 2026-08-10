import AppKit
import Carbon
import Foundation

enum ModifierKey: String, CaseIterable, Identifiable, Codable {
    case none = "none"
    case leftCommand = "leftCommand"
    case rightCommand = "rightCommand"
    case leftOption = "leftOption"
    case rightOption = "rightOption"
    case leftShift = "leftShift"
    case rightShift = "rightShift"
    case leftControl = "leftControl"
    case rightControl = "rightControl"
    case fn = "fn"
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .none: return "None"
        case .leftCommand: return "Left ⌘ Command"
        case .rightCommand: return "Right ⌘ Command"
        case .leftOption: return "Left ⌥ Option"
        case .rightOption: return "Right ⌥ Option"
        case .leftShift: return "Left ⇧ Shift"
        case .rightShift: return "Right ⇧ Shift"
        case .leftControl: return "Left ⌃ Control"
        case .rightControl: return "Right ⌃ Control"
        case .fn: return "Fn"
        }
    }
    
    var shortSymbol: String {
        switch self {
        case .none: return ""
        case .leftCommand: return "⌘"
        case .rightCommand: return "⌘"
        case .leftOption: return "⌥"
        case .rightOption: return "⌥"
        case .leftShift: return "⇧"
        case .rightShift: return "⇧"
        case .leftControl: return "⌃"
        case .rightControl: return "⌃"
        case .fn: return "fn"
        }
    }
    
    var keyCode: UInt16 {
        switch self {
        case .none: return 0
        case .leftCommand: return 55
        case .rightCommand: return 54
        case .leftOption: return 58
        case .rightOption: return 61
        case .leftShift: return 56
        case .rightShift: return 60
        case .leftControl: return 59
        case .rightControl: return 62
        case .fn: return 63
        }
    }
    
    var modifierFlag: NSEvent.ModifierFlags {
        switch self {
        case .none: return []
        case .leftCommand, .rightCommand: return .command
        case .leftOption, .rightOption: return .option
        case .leftShift, .rightShift: return .shift
        case .leftControl, .rightControl: return .control
        case .fn: return .function
        }
    }
    
    var cgEventFlag: CGEventFlags {
        switch self {
        case .none: return []
        case .leftCommand, .rightCommand: return .maskCommand
        case .leftOption, .rightOption: return .maskAlternate
        case .leftShift, .rightShift: return .maskShift
        case .leftControl, .rightControl: return .maskControl
        case .fn: return .maskSecondaryFn
        }
    }
    
    var isCommandOrOption: Bool {
        switch self {
        case .leftCommand, .rightCommand, .leftOption, .rightOption:
            return true
        default:
            return false
        }
    }
}

class ModifierKeyMonitor {
    static let shared = ModifierKeyMonitor()
    
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var selectedModifierKey: ModifierKey = .none
    private var isModifierPressed = false

    /// Set when other input arrived while the bound modifier was held, meaning the
    /// press was part of a chord rather than a solitary tap.
    private var comboDetected = false

    var onKeyDown: (() -> Void)?
    var onKeyUp: (() -> Void)?

    /// The held modifier turned out to be part of a chord (⌘C, ⌘-click, ⌘⇧…), so
    /// whatever `onKeyDown` started should be abandoned.
    var onComboDetected: (() -> Void)?

    private init() {}

    func start(modifierKey: ModifierKey) {
        guard modifierKey != .none else {
            stop()
            return
        }

        stop()

        selectedModifierKey = modifierKey
        isModifierPressed = false
        comboDetected = false

        // Key and mouse events are observed alongside flagsChanged for one purpose:
        // to tell a solitary modifier tap from a chord. Without this, binding a
        // modifier that appears in everyday shortcuts means ⌘C starts a Dictation.
        //
        // These events are never inspected. The callback below reads nothing from
        // them — no keycode, no character, no click location — it only records that
        // input happened. The tap is listen-only, so nothing is intercepted either.
        let eventMask = CGEventMask(
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.otherMouseDown.rawValue)
        )

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else {
                    return Unmanaged.passUnretained(event)
                }
                
                let monitor = Unmanaged<ModifierKeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    monitor.reenableTap()
                    return Unmanaged.passUnretained(event)
                }
                
                if type == .flagsChanged {
                    monitor.handleFlagsChanged(event: event)
                } else {
                    // Deliberately does not receive the event: only the fact that
                    // some input occurred is of interest.
                    monitor.handleUnrelatedInput()
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("ModifierKeyMonitor: Failed to create event tap. Check accessibility permissions.")
            return
        }
        
        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        
        if let source = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            print("ModifierKeyMonitor: Started monitoring for \(modifierKey.displayName)")
        }
    }
    
    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            }
        }
        eventTap = nil
        runLoopSource = nil
        isModifierPressed = false
        print("ModifierKeyMonitor: Stopped")
    }
    
    fileprivate func reenableTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
            print("ModifierKeyMonitor: Re-enabled tap after timeout")
        }
    }
    
    /// Records that input unrelated to the bound modifier arrived while it was held.
    ///
    /// Takes no event parameter by design: the only fact needed is *that* something
    /// was pressed. Nothing about the input is read, logged or stored.
    fileprivate func handleUnrelatedInput() {
        guard isModifierPressed, !comboDetected else { return }

        comboDetected = true
        DispatchQueue.main.async {
            self.onComboDetected?()
        }
    }

    private func handleFlagsChanged(event: CGEvent) {
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags

        guard keyCode == selectedModifierKey.keyCode else {
            // A different modifier changed state. If ours is held, this is a chord
            // such as ⌘⇧ — caught here without needing to look at key events.
            handleUnrelatedInput()
            return
        }

        let cgFlag = selectedModifierKey.cgEventFlag
        let isPressed = flags.contains(cgFlag)

        if isPressed && !isModifierPressed {
            isModifierPressed = true
            comboDetected = false
            DispatchQueue.main.async {
                self.onKeyDown?()
            }
        } else if !isPressed && isModifierPressed {
            isModifierPressed = false

            // A chord already abandoned the Dictation, so there is nothing for
            // key-up to stop. Reporting it would stop the *next* one.
            let wasCombo = comboDetected
            comboDetected = false
            guard !wasCombo else { return }

            DispatchQueue.main.async {
                self.onKeyUp?()
            }
        }
    }
    
    deinit {
        stop()
    }
}
