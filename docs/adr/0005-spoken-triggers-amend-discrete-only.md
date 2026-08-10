---
status: accepted — amends ADR-0001
---

# Spoken Triggers are permitted, bounded by Allowed Apps and complete-utterance matching

ADR-0001 refused passive listening outright. This amends it: a Dictation may now also be started
by a **Wake Phrase** and ended by a **Stop Phrase**, recognised on-device by Apple's
`SpeechTranscriber` with `SpeechDetector` gating. Discrete Triggers are unchanged and Spoken
Triggers are additive.

## Why this is not simply a reversal

ADR-0001's objection was concrete: Insertion synthesises ⌘V into the focused app, the primary
target is a terminal, and a false positive there is arbitrary text at a shell prompt. That
objection was aimed at bare voice-activity detection, which fires on *any* speech. Two properties
make a Wake Phrase a different proposition, and both are load-bearing rather than incidental:

- **Listening happens only while an Allowed App is frontmost.** You can only be heard in the
  applications you nominated — so a false positive inserts into the app you were already aiming
  at, not an arbitrary one. This bounds the blast radius rather than merely lowering the odds.
- **A phrase fires only as a complete utterance**, bounded by silence either side. The chosen
  phrases are "start dictation" and "stop dictation", which occur naturally when discussing this
  feature; substring matching would fire constantly. Utterance-bounded matching is what makes
  those phrases usable at all.

Silence-based auto-stop was rejected in favour of the Stop Phrase: it never truncates the user
mid-thought, at the cost of the recogniser running throughout the Dictation.

## Consequences

- **A fourth TCC permission** (`NSSpeechRecognitionUsageDescription`) joins Microphone,
  Accessibility and Input Monitoring, and locale assets must be provisioned through
  `AssetInventory`.
- **macOS 26.0 or later.** The deployment target is 15.1, so the feature is gated behind
  `#available` and its setting is hidden — not shown broken — on earlier systems.
- **Listening is pinned to the built-in microphone**, never the AirPods. Holding a Bluetooth mic
  open all day pins the link into bidirectional mode, draining the buds and degrading playback,
  and Listening would die whenever they auto-switch to another device. Pinning is explicit because
  `AudioRecorder` changes the *system default* input during every Dictation, which would otherwise
  drag the recogniser onto another device precisely when it must hear the Stop Phrase.
- **No audio is retained while Listening.** Nothing is written to disk and nothing is transcribed
  for the user until a Wake Phrase starts a Dictation. This is an invariant, not a setting.
- The feature is off by default, and disables itself visibly if permission or assets are missing
  rather than silently failing.
