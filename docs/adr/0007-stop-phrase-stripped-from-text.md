# The Stop Phrase is removed from the Transcription text

The Stop Phrase is spoken into the microphone while whisper is still recording, so whisper
transcribes it. It is matched and removed from the end of the Transcription before Insertion, rather
than cut from the audio.

Removing words from a user's own transcription reads like a bug when encountered in the code, which
is the only reason this is written down: the decision itself is trivially reversible.

Trimming the audio instead was rejected. Apple's recogniser does report a `CMTimeRange` for the
matched phrase, so trimming is technically possible — but the recogniser and `AVAudioRecorder` run
as independent capture clients with independent clocks (ADR-0006), so the mapping between them goes
through wall time and drifts. A drifting cut clips the user's last real word; a stray "stop
dictation" at the end of a paste does not. The cheaper mechanism has the better failure mode.

Matching ignores case, punctuation and spacing, and is anchored to the end of the text, so
`"Refactor it.  STOP   DICTATION!!"` reduces to `"Refactor it."`. It compares whole words, so it does
**not** absorb morphological variants: if whisper renders the phrase as "stop dictating" the words
survive into the Transcription. Widening it to stem-match would also start eating "Please don't stop
dictating", which is worse. The residual cost is that deliberately ending a sentence with the exact
Stop Phrase loses those words.
