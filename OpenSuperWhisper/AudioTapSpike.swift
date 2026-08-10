#if DEBUG
import AVFoundation
import CoreAudio
import Foundation

/// Answers the one question ADR-0006 leaves open: can an `AVAudioEngine` tap and
/// `AVAudioRecorder` capture the same input device simultaneously, in one process?
///
/// The Wake Phrase listener depends on the answer being yes. `SpeechAnalyzer` consumes
/// `AVAudioPCMBuffer`s from an engine tap, while whisper keeps recording through
/// `AVAudioRecorder` — so unless both can hold the microphone at once, ADR-0006's
/// rejected alternative (unify everything onto one tap, rewriting `AudioRecorder`)
/// becomes mandatory rather than optional.
///
/// **How to read the result.** A buffer count is logged every second. Start a normal
/// Dictation while it runs:
///
/// - Counter keeps climbing throughout the Dictation → concurrent capture works.
/// - Counter stalls when recording starts, or `engine.start()` throws → it does not.
///
/// The engine is pinned to the built-in microphone rather than following the system
/// default, both because that is where Listening will live (ADR-0005) and because
/// `AudioRecorder` changes the system default mid-Dictation, which would otherwise
/// make this measurement ambiguous.
///
/// Temporary. Delete once the question is settled.
final class AudioTapSpike {
    static let shared = AudioTapSpike()

    private let engine = AVAudioEngine()
    private var bufferCount = 0
    private var totalFrames: AVAudioFramePosition = 0
    private var lastReportedCount = 0
    private var timer: Timer?
    private let lock = NSLock()
    private var configObserver: NSObjectProtocol?
    private var restartCount = 0

    private init() {}

    func start() {
        // A HAL reconfiguration stops the engine outright, and pinning the device does
        // not prevent it: starting a Dictation switches the *system default* input,
        // which reconfigures the built-in device this engine is bound to. Measured
        // 2026-08-10 — "Abandoning I/O cycle because reconfig pending" six milliseconds
        // after the default input changed. The listener must therefore be able to
        // restart itself, which is what the real Wake Phrase monitor will need too.
        if configObserver == nil {
            configObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange,
                object: engine,
                queue: .main
            ) { [weak self] _ in
                self?.handleConfigurationChange()
            }
        }

        startEngine()
    }

    private func handleConfigurationChange() {
        restartCount += 1
        NSLog("AudioTapSpike: configuration changed (restart #\(restartCount)); engine running=\(engine.isRunning) — restarting")

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        // The device must be re-pinned: the reconfiguration is usually a *default
        // device* change, and the input node may have followed it.
        startEngine()
    }

    private func startEngine() {
        guard let deviceID = builtInDeviceID() else {
            NSLog("AudioTapSpike: no built-in microphone found, cannot run")
            return
        }

        guard pinEngineInput(to: deviceID) else { return }

        let inputNode = engine.inputNode
        let format = inputNode.inputFormat(forBus: 0)
        NSLog("AudioTapSpike: pinned to device \(deviceID), format \(format.sampleRate)Hz \(format.channelCount)ch")

        guard format.sampleRate > 0 else {
            NSLog("AudioTapSpike: input format has zero sample rate — device not usable")
            return
        }

        // format: nil takes the node's own format, which avoids a mismatch crash when
        // the device runs at something other than the engine default.
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, _ in
            guard let self = self else { return }
            self.lock.lock()
            self.bufferCount += 1
            self.totalFrames += AVAudioFramePosition(buffer.frameLength)
            self.lock.unlock()
        }

        engine.prepare()

        do {
            try engine.start()
            NSLog("AudioTapSpike: engine started — now trigger a Dictation and watch the counter")
        } catch {
            NSLog("AudioTapSpike: engine.start() FAILED: \(error.localizedDescription)")
            return
        }

        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                self?.report()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        NSLog("AudioTapSpike: stopped")
    }

    private func report() {
        lock.lock()
        let count = bufferCount
        let frames = totalFrames
        lock.unlock()

        let delta = count - lastReportedCount
        lastReportedCount = count

        // `delta` is the number that matters: a stall shows up as 0. `restarts` tells a
        // genuine concurrency failure apart from an engine that merely needed
        // restarting after a device reconfiguration.
        NSLog("AudioTapSpike: buffers=\(count) (+\(delta)/s) frames=\(frames) running=\(engine.isRunning) restarts=\(restartCount)")
    }

    /// CoreAudio device ID of the built-in microphone, via the existing service so the
    /// definition of "built-in" stays in one place.
    private func builtInDeviceID() -> AudioDeviceID? {
        let service = MicrophoneService.shared
        guard let builtIn = service.availableMicrophones.first(where: { $0.isBuiltIn }) else {
            return nil
        }
        return service.getCoreAudioDeviceID(for: builtIn)
    }

    /// Binds the engine's input to a specific device instead of the system default.
    private func pinEngineInput(to deviceID: AudioDeviceID) -> Bool {
        guard let audioUnit = engine.inputNode.audioUnit else {
            NSLog("AudioTapSpike: input node has no audio unit")
            return false
        }

        var device = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &device,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )

        if status != noErr {
            NSLog("AudioTapSpike: failed to pin input device, OSStatus \(status)")
            return false
        }
        return true
    }
}
#endif
