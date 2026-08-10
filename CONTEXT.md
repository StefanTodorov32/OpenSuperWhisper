# OpenSuperWhisper (Dev)

A fork of [starmel/OpenSuperWhisper](https://github.com/starmel/OpenSuperWhisper) that adds a
hands-free Trigger, so a Dictation can be started without touching the keyboard.

## Language

### Dictation flow

**Dictation**:
One complete cycle from Trigger to Insertion: audio capture, transcription, and delivery of the text.
_Avoid_: recording, session

**Recording**:
The persisted artifact of a Dictation — its audio file together with the Transcription, duration and status.
_Avoid_: clip, entry, history item

**Transcription**:
The text produced from a Dictation's audio.
_Avoid_: transcript, result, output

**Target App**:
The application that was frontmost when a Dictation began. Insertion may only write into the Target App.
_Avoid_: focused app, active app, destination

**Insertion**:
Delivery of a Transcription into the Target App.
_Avoid_: paste, auto-paste, output

**Indicator**:
The floating window shown near the caret for the duration of a Dictation.
_Avoid_: HUD, overlay, popup

### Triggering

**Trigger**:
The deliberate action that starts or ends a Dictation. Kinds: keyboard shortcut, modifier-only
hotkey, mouse button, Stem Press.
_Avoid_: hotkey, shortcut — each names one kind of Trigger, not the concept

**Stem Press**:
A double squeeze of the AirPods stem — the Trigger this fork adds.
_Avoid_: tap, click, button press

### Transcription backend

**Engine**:
The interchangeable implementation that turns audio into a Transcription. Either Whisper or Parakeet.
_Avoid_: backend, model

**Model**:
The weights file an Engine loads, e.g. `ggml-large-v3-turbo.bin`.
_Avoid_: engine
