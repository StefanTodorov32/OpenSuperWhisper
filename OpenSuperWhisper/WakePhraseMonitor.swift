import AVFoundation
import AppKit
import CoreAudio
import Foundation
import Speech

/// Listens for a spoken Wake Phrase, and while a Dictation is running, a Stop Phrase.
///
/// See `docs/adr/0005-spoken-triggers-amend-discrete-only.md` for why passive listening
/// is permitted at all, and `docs/adr/0006-two-audio-consumers.md` for why this holds
/// its own microphone rather than sharing whisper's.
///
/// Two properties of this class are load-bearing rather than incidental, because they
/// are what contain the hazard ADR-0001 objected to:
///
/// - **Listening only happens while an Allowed App is frontmost**, so a false positive
///   inserts into an application the user had already chosen.
/// - **A phrase must be an entire utterance.** The default phrases are "start
///   dictation" and "stop dictation", which occur naturally in conversation about this
///   feature; substring matching would fire constantly.
@available(macOS 26.0, *)
final class WakePhraseMonitor {
    static let shared = WakePhraseMonitor()

    /// The Wake Phrase was heard as a complete utterance.
    var onWakePhrase: (() -> Void)?

    /// The Stop Phrase was heard as a complete utterance.
    var onStopPhrase: (() -> Void)?

    /// Logs every finalised utterance the recogniser produces. Off by default; noisy,
    /// and it is a transcript of everything said near the machine.
    var isDiagnosticLoggingEnabled = false

    private(set) var isListening = false

    private let engine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var converter: AVAudioConverter?
    private var analysisFormat: AVAudioFormat?
    private var configObserver: NSObjectProtocol?

    private init() {}

    // MARK: - Lifecycle

    func startListening() {
        guard !isListening else { return }

        isListening = true
        NSLog("WakePhraseMonitor: starting")

        // Observed once and kept: a Dictation reconfigures the input device twice, at
        // start and at stop, and each reconfiguration stops the engine outright.
        // Measured in the ADR-0006 spike — pinning the device does not prevent it.
        if configObserver == nil {
            configObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange,
                object: engine,
                queue: .main
            ) { [weak self] _ in
                guard let self = self, self.isListening else { return }
                NSLog("WakePhraseMonitor: audio configuration changed, restarting engine")
                self.teardownEngine()
                self.startEngine()
            }
        }

        Task { await self.startAnalyzer() }
    }

    func stopListening() {
        guard isListening else { return }
        isListening = false

        teardownEngine()

        resultsTask?.cancel()
        resultsTask = nil

        inputContinuation?.finish()
        inputContinuation = nil

        let analyzer = self.analyzer
        self.analyzer = nil
        self.transcriber = nil
        Task { await analyzer?.cancelAndFinishNow() }

        NSLog("WakePhraseMonitor: stopped")
    }

    // MARK: - Recognition

    private func startAnalyzer() async {
        guard let locale = await Self.resolveLocale() else {
            NSLog("WakePhraseMonitor: no supported locale available; Spoken Triggers unavailable")
            isListening = false
            return
        }

        let transcriber = SpeechTranscriber(
            locale: locale,
            // volatileResults gives partial hypotheses, which arrive sooner than
            // finalised ones. Matching still happens only on finalised results — a
            // partial cannot establish that an utterance is complete — but asking for
            // them keeps the recogniser responsive.
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange]
        )

        // Gates the transcriber on speech presence so nothing runs during silence,
        // which is most of the day.
        let detector = SpeechDetector(
            detectionOptions: .init(sensitivityLevel: .medium),
            reportResults: false
        )

        let modules: [any SpeechModule] = [transcriber, detector]

        guard await Self.ensureAssetsInstalled(for: modules) else {
            NSLog("WakePhraseMonitor: speech assets unavailable; Spoken Triggers disabled")
            isListening = false
            return
        }

        let analyzer = SpeechAnalyzer(modules: modules)

        let naturalFormat = engine.inputNode.inputFormat(forBus: 0)
        analysisFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: modules,
            considering: naturalFormat.sampleRate > 0 ? naturalFormat : nil
        )

        guard analysisFormat != nil else {
            NSLog("WakePhraseMonitor: no compatible audio format; Spoken Triggers disabled")
            isListening = false
            return
        }

        self.transcriber = transcriber
        self.analyzer = analyzer

        let stream = AsyncStream<AnalyzerInput> { continuation in
            self.inputContinuation = continuation
        }

        resultsTask = Task { [weak self] in
            await self?.consumeResults(from: transcriber)
        }

        do {
            try await analyzer.start(inputSequence: stream)
        } catch {
            NSLog("WakePhraseMonitor: analyzer.start failed: \(error.localizedDescription)")
            isListening = false
            return
        }

        await MainActor.run { self.startEngine() }
    }

    private func consumeResults(from transcriber: SpeechTranscriber) async {
        do {
            for try await result in transcriber.results {
                // Only finalised results can establish that an utterance is complete.
                // A volatile hypothesis is still mid-sentence by definition, and
                // matching one would defeat complete-utterance matching entirely.
                guard result.isFinal else { continue }

                let spoken = String(result.text.characters)

                if isDiagnosticLoggingEnabled {
                    NSLog("WakePhraseMonitor: heard \"\(spoken)\"")
                }

                handle(utterance: spoken)
            }
        } catch {
            NSLog("WakePhraseMonitor: results stream ended: \(error.localizedDescription)")
        }
    }

    private func handle(utterance: String) {
        let prefs = AppPreferences.shared
        let normalised = Self.normalise(utterance)

        // Equality, never containment: "and then it should start dictation
        // automatically" must not fire, while a deliberate "Start dictation." must.
        if normalised == Self.normalise(prefs.wakePhrase) {
            NSLog("WakePhraseMonitor: Wake Phrase matched")
            DispatchQueue.main.async { self.onWakePhrase?() }
            return
        }

        if normalised == Self.normalise(prefs.stopPhrase) {
            NSLog("WakePhraseMonitor: Stop Phrase matched")
            DispatchQueue.main.async { self.onStopPhrase?() }
        }
    }

    /// Lowercases and strips everything that is not a letter, digit or single space, so
    /// "Start dictation." and "start dictation" compare equal.
    static func normalise(_ text: String) -> String {
        let filtered = text.lowercased().map { character -> Character in
            character.isLetter || character.isNumber ? character : " "
        }
        return String(filtered)
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }

    // MARK: - Assets and locale

    private static func resolveLocale() async -> Locale? {
        let installed = await SpeechTranscriber.installedLocales
        let supported = await SpeechTranscriber.supportedLocales
        let current = Locale.current

        // Prefer an already-installed locale matching the user's language, so the
        // common case needs no download at all.
        if let match = installed.first(where: { $0.identifier(.bcp47) == current.identifier(.bcp47) }) {
            return match
        }
        if let sameLanguage = installed.first(where: { $0.language.languageCode == current.language.languageCode }) {
            return sameLanguage
        }
        if let supportedMatch = supported.first(where: { $0.language.languageCode == current.language.languageCode }) {
            return supportedMatch
        }
        return installed.first ?? supported.first
    }

    private static func ensureAssetsInstalled(for modules: [any SpeechModule]) async -> Bool {
        let status = await AssetInventory.status(forModules: modules)

        switch status {
        case .installed:
            return true
        case .unsupported:
            NSLog("WakePhraseMonitor: speech assets unsupported on this system")
            return false
        case .supported, .downloading:
            // A first run may need a download. Reported rather than silently waited on,
            // because on a slow connection this is the difference between "broken" and
            // "not ready yet".
            do {
                guard let request = try await AssetInventory.assetInstallationRequest(supporting: modules) else {
                    return true
                }
                NSLog("WakePhraseMonitor: downloading speech assets…")
                try await request.downloadAndInstall()
                NSLog("WakePhraseMonitor: speech assets installed")
                return true
            } catch {
                NSLog("WakePhraseMonitor: asset installation failed: \(error.localizedDescription)")
                return false
            }
        @unknown default:
            return false
        }
    }

    // MARK: - Engine

    private func startEngine() {
        guard let analysisFormat else { return }

        guard let deviceID = Self.builtInDeviceID(), pinEngineInput(to: deviceID) else {
            NSLog("WakePhraseMonitor: could not pin to the built-in microphone")
            return
        }

        let inputNode = engine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)

        guard inputFormat.sampleRate > 0 else {
            NSLog("WakePhraseMonitor: input format unusable (0 Hz)")
            return
        }

        converter = AVAudioConverter(from: inputFormat, to: analysisFormat)

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, _ in
            self?.feed(buffer)
        }

        engine.prepare()

        do {
            try engine.start()
            NSLog("WakePhraseMonitor: listening on the built-in microphone")
        } catch {
            NSLog("WakePhraseMonitor: engine.start failed: \(error.localizedDescription)")
        }
    }

    private func teardownEngine() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
    }

    private func feed(_ buffer: AVAudioPCMBuffer) {
        guard let continuation = inputContinuation else { return }

        guard let analysisFormat, let converter else {
            continuation.yield(AnalyzerInput(buffer: buffer))
            return
        }

        if converter.inputFormat == analysisFormat {
            continuation.yield(AnalyzerInput(buffer: buffer))
            return
        }

        // Frame capacity is scaled by the sample-rate ratio, otherwise conversion to a
        // higher rate silently truncates.
        let ratio = analysisFormat.sampleRate / converter.inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024

        guard let converted = AVAudioPCMBuffer(pcmFormat: analysisFormat, frameCapacity: capacity) else { return }

        var consumed = false
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }

        if let error {
            NSLog("WakePhraseMonitor: conversion failed: \(error.localizedDescription)")
            return
        }

        continuation.yield(AnalyzerInput(buffer: converted))
    }

    /// CoreAudio device ID of the built-in microphone.
    ///
    /// Pinned explicitly rather than following the system default, because
    /// `AudioRecorder` changes that default during every Dictation — which would drag
    /// this engine onto another device exactly when it needs to hear the Stop Phrase.
    private static func builtInDeviceID() -> AudioDeviceID? {
        let service = MicrophoneService.shared
        guard let builtIn = service.availableMicrophones.first(where: { $0.isBuiltIn }) else { return nil }
        return service.getCoreAudioDeviceID(for: builtIn)
    }

    private func pinEngineInput(to deviceID: AudioDeviceID) -> Bool {
        guard let audioUnit = engine.inputNode.audioUnit else { return false }

        var device = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &device,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        return status == noErr
    }
}
