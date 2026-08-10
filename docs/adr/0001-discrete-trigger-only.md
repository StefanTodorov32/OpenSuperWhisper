# Discrete Trigger only — no passive voice activation

A Dictation is always started by a deliberate Trigger. We rejected passive voice activation
(listening continuously and starting capture on speech onset) even though the Silero VAD needed to
build it is already bundled and loaded by `WhisperEngine`.

The reason is Insertion, not accuracy. Insertion synthesises ⌘V into the Target App, and the primary
Target App here is a terminal running Claude Code. A false positive under passive activation is not a
stray word in a text field — it is arbitrary transcribed speech deposited at a shell prompt, one
Return away from execution. A Discrete Trigger makes false positives structurally impossible rather
than merely unlikely.

## Consequences

- The bundled Silero VAD stays in its current post-hoc role: `detectSpeech(in:)` drops non-speech
  from an already-captured buffer. There is deliberately no live VAD path.
- Because a Trigger must be deliberate, hands-free operation costs one physical action. That is
  accepted; the original complaint was about the *keyboard*, not about acting at all.
