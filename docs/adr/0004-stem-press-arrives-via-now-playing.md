# A stem press is only reachable by claiming Now Playing, and carries no gesture identity

Measured on macOS 26.5.1 with AirPods Pro (product ID 0x2027), 2026-08-10.

An AirPods stem press is an AVRCP transport command. macOS hands it to `mediaremoted`,
which routes it to whichever app holds Now Playing status. **It never enters the HID
event stream**, so a `CGEventTap` — the technique both `ModifierKeyMonitor` and
`MouseButtonMonitor` rely on — cannot observe it. Claiming Now Playing via
`MPRemoteCommandCenter` is therefore the only way to receive it.

**Every gesture arrives as the same command.** Single, double and triple squeezes all
delivered `play`. `nextTrack` and `previousTrack` were never received. Gesture identity
is simply not present in the signal, so any squeeze is bound as the Trigger.

## Evidence

With the event tap active and Input Monitoring granted, eighteen
`sendRemoteControlCommand` requests appeared in `mediaremoted`'s log during a squeeze
session, while the tap logged **zero** events and the unified log contained no
`NX_KEYTYPE` records at all. Commands sent while Spotify held Now Playing returned
successfully; commands sent while no app was playing failed with
`MPCPlaybackEngineInternalError Code=1 "Failing due to no content in the player"`.
After claiming Now Playing, the app received eight consecutive `play` commands.

## Consequences

- **Media control is lost while the Trigger is on.** Holding Now Playing means every
  transport command is delivered here and none reaches Spotify or Music. The original
  intent — bind the double press, leave the single press as play/pause — is not
  achievable on this route, and the route that could have done it does not receive
  the press. The setting is off by default and says this plainly.
- **A cooldown is required.** One squeeze can emit more than one command (measured
  0.527s and 0.524s apart), and because every press toggles, an un-debounced second
  command would start a Dictation and immediately stop it. `pressCooldown` is 0.8s,
  deliberately wider than the ~0.5s double-click interval.
- **The event-tap route is retained but not the default**, on the assumption that
  wired remotes and some keyboards do emit genuine media keys. It is verified not to
  work with AirPods.
- This is a behaviour of MediaRemote, not a documented contract, so it may change in
  a future macOS release. The diagnostic logging that established it is kept in debug
  builds so the measurement can be repeated.
