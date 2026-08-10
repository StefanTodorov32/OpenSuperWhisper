# Fork with a distinct bundle identifier and our own signing identity

The Stem Press Trigger is implemented inside a fork of OpenSuperWhisper rather than as a separate
companion app, and the fork ships as `com.stefantodorov.OpenSuperWhisper.dev` ("OpenSuperWhisper
(Dev)") signed with an Apple Development certificate issued under an Apple ID we control.

## Considered options

A companion app was the alternative: intercept the Stem Press in a ~200-line standalone binary and
post a synthetic ⌥\` to a stock, untouched OpenSuperWhisper. That would have preserved the release
build's TCC grants and survived upstream updates for free. We chose the fork anyway, for a single
integrated app with real Settings UI, no synthetic-keystroke round-trip, and a diff that can be
offered upstream.

## Consequences

- We cannot inherit the release build's TCC grants under any bundle ID, because authorization is keyed
  to a designated requirement derived from the signing certificate, and upstream is signed by
  `Developer ID Application: Kornienko Vyacheslav (8LLDD7HWZK)`, which we cannot reproduce.
- Signing with a *stable* certificate rather than ad-hoc is therefore load-bearing: ad-hoc derives the
  requirement from the binary hash, so every rebuild would reset Accessibility, Input Monitoring and
  Microphone. Switching certificates later has the same effect.
- The distinct bundle ID keeps the stock signed app installed alongside the fork as a known-good
  reference. This exists to answer "is my code broken, or are macOS permissions broken?" — a question
  that has already cost real time on this project.
- Both apps listening for ⌥\` will both respond. Quit one before testing the other.
