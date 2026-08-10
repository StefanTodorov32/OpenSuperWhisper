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
Anything that starts or ends a Dictation, whether performed or spoken.
_Avoid_: hotkey, shortcut — each names one kind of Trigger, not the concept

**Discrete Trigger**:
A Trigger that is a deliberate physical action: keyboard shortcut, modifier-only hotkey, mouse
button, Stem Press.
_Avoid_: manual trigger, button

**Spoken Trigger**:
A Trigger recognised from speech rather than performed — the Wake Phrase and the Stop Phrase.
_Avoid_: voice command, passive trigger

**Stem Press**:
A squeeze of the AirPods stem. Gesture length is not distinguishable, so any squeeze counts.
_Avoid_: tap, click, button press

**Wake Phrase**:
The spoken phrase that starts a Dictation.
_Avoid_: wake word, hotword, keyword, trigger phrase

**Stop Phrase**:
The spoken phrase that ends a Dictation. Never appears in the Transcription.
_Avoid_: stop word — that means something else in text processing — end word, cancel phrase

**Listening**:
The continuous state in which the app watches for the Wake Phrase. Distinct from a Dictation: no
audio is retained and nothing is transcribed for the user while merely Listening.
_Avoid_: always-on, standby, idle

**Allowed App**:
An application whose focus permits Listening. Listening happens only while an Allowed App is
frontmost, which bounds both battery cost and where a Wake Phrase can be heard.
_Avoid_: whitelist, allowlist entry, enabled app

### Transcription backend

**Engine**:
The interchangeable implementation that turns audio into a Transcription. Either Whisper or Parakeet.
_Avoid_: backend, model

**Model**:
The weights file an Engine loads, e.g. `ggml-large-v3-turbo.bin`.
_Avoid_: engine
