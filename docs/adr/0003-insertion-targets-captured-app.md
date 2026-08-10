# Insertion targets the app that was frontmost when the Dictation started

The frontmost application is captured when a Dictation begins and becomes its Target App. If the
Target App is no longer frontmost when the Transcription is ready, Insertion is skipped: the text is
left on the clipboard and shown in the Indicator instead.

Upstream has no such notion — `IndicatorWindow.insertText(_:)` fires ⌘V into whatever holds focus at
completion time. That is safe for a keyboard Trigger, because pressing a key proves you were at the
keyboard looking at the target. A Stem Press proves nothing of the sort, and `large-v3-turbo` takes
seconds, so focus can easily move in between.

## Considered options

Re-activating the Target App before pasting was rejected. It steals focus from whatever the user moved
on to, and it races the synthetic ⌘V — timing around that paste is already fragile, as the existing
1.5s `clipboardRestoreDelay` for slow Electron consumers shows. Refusing to paste is the safe failure
mode: a Transcription may be left on the clipboard for the user to place, but it is never deposited
into an application they did not choose.
