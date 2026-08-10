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

Whether macOS permits two concurrent input clients here is verified by spike before anything is
built on it. If it does not, unifying on one tap becomes the fallback rather than the opening move.

## Consequences

- **The two capture paths have independent clocks.** Mapping a recognised phrase's
  `audioTimeRange` onto a position in whisper's file requires a wall-clock reference and is only
  accurate to tens of milliseconds. This is why the Stop Phrase is removed from the transcribed
  *text* rather than trimmed from the audio: a drifting mapping would clip the user's last real
  word, which is worse than the problem it solves. See ADR-0007.
- The microphone is opened twice while a Dictation is in progress, which is visible in system
  audio state and doubles the input clients for that period.
