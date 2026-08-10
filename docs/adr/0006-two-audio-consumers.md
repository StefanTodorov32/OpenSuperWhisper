# The microphone is captured twice, deliberately

Whisper keeps recording through `AVAudioRecorder` straight to a file, while the Wake Phrase
recogniser runs from a separate `AVAudioEngine` tap. Two independent clients on the input device,
by choice.

This looks like an oversight and is not. The alternative — one `AVAudioEngine` tap that both writes
PCM for whisper and feeds `SpeechAnalyzer` — is cleaner in the abstract and would unlock live VAD
and metering later. It was rejected because it rewrites `AudioRecorder`, which is the component
carrying the accommodations that make Bluetooth microphones work at all: `startConnectionMonitoring`
polls file growth every 50ms to distinguish "connecting" from "recording", because an AirPods mic
does not start producing audio immediately. That behaviour was hard won, is easy to break silently,
and a rewrite would have to re-derive it while also being the change most likely to break every
Dictation.

**Verified 2026-08-10 on macOS 26.5.1.** Concurrent capture works. An `AVAudioEngine` tap pinned to
the built-in microphone sustained 10 buffers/second for the full 31 seconds of a Dictation while
`AVAudioRecorder` recorded from another device, and the Transcription came back correct. Unifying
onto one tap is therefore not required.

The same measurement produced a second, less obvious result: **each Dictation reconfigures the
device twice**, and each reconfiguration stops the engine outright. `AudioRecorder` switches the
system default input when recording starts and restores it when recording ends; both changes reach
the built-in device the listener is bound to, producing `"Abandoning I/O cycle because reconfig
pending"` within six milliseconds. Pinning the device does **not** prevent this.

A listener must therefore observe `AVAudioEngineConfigurationChange`, re-pin its device and restart.
Restarting costs about 50ms, so the listener is deaf for roughly that long at the start and end of
every Dictation. That is harmless for a Stop Phrase, which arrives later, but it rules out
expecting the listener to hear anything spoken in the instant a Dictation begins.

## Consequences

- **The two capture paths have independent clocks.** Mapping a recognised phrase's
  `audioTimeRange` onto a position in whisper's file requires a wall-clock reference and is only
  accurate to tens of milliseconds. This is why the Stop Phrase is removed from the transcribed
  *text* rather than trimmed from the audio: a drifting mapping would clip the user's last real
  word, which is worse than the problem it solves. See ADR-0007.
- The microphone is opened twice while a Dictation is in progress, which is visible in system
  audio state and doubles the input clients for that period.
