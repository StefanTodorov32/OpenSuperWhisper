# Spike: is an AirPods stem press observable?

Everything in the stem-press Trigger rests on one unverified assumption: that a
double squeeze of the AirPods stem produces an event a third-party Mac app can see.
It may not. A stem press is an AVRCP transport command, and macOS may deliver it
only to the app holding Now Playing status rather than placing it on the HID event
stream.

**Time-box: 2 hours across both routes.** If neither yields an event, stop and use
the mouse-button Trigger that already ships (`MouseButtonMonitor`) or a foot pedal
sending ⌥\`. A pedal that works beats a weekend of MediaRemote archaeology.

## Prerequisites

The Trigger uses a `CGEventTap`, so **Input Monitoring** is required. Build and run
from Xcode with your own signing team selected, not via `./run.sh` — `run.sh`
passes `CODE_SIGNING_ALLOWED=NO`, and an unsigned binary's TCC grant is keyed to
its hash, so it resets on every rebuild. See ADR-0002.

Keep the stock `OpenSuperWhisper.app` quit while testing, or both apps will respond
to ⌥\`.

Debug builds enable diagnostic logging automatically
(`RemoteCommandMonitor.isDiagnosticLoggingEnabled`), so every media key and
transport command is printed whether or not it matches the bound gesture.

## Route A — media key tap (default)

Settings → AirPods Stem → Gesture: **Double press**, Interception: **Media key tap**.

Squeeze the stem twice and watch the Xcode console.

- `RemoteCommandMonitor[tap]: keyCode=17 state=down` → the press is observable.
  17 is `NX_KEYTYPE_NEXT`, which is what a double press should produce. Done: this
  route is preferred because unbound gestures pass through, so a single press still
  pauses Spotify.
- Nothing at all → the commands are not reaching the HID event stream. Go to Route B.
- `Failed to create event tap` → Input Monitoring is not granted; fix that first,
  this is not a result.

Worth also pressing once and three times, to confirm the firmware really does emit
16 / 17 / 18 separately as assumed.

## Route B — Now Playing

Switch Interception to **Now Playing**. This claims Now Playing status, which is a
precondition for receiving transport commands on this route, not a cosmetic choice.

- `RemoteCommandMonitor[nowPlaying]: received nextTrack` → observable here.
  Accept that media apps lose the stem entirely while this is enabled; there is no
  selective pass-through on this route.
- Only `togglePlayPause` ever arrives → the firmware is not forwarding
  next/previous over this transport. Fall back to binding the single press and
  accept losing play/pause, or abandon per the time-box.
- Nothing on either route → **stop.** Adopt the pedal or mouse button.

## Recording the outcome

Whichever way it goes, write it down — a negative result is the most valuable thing
this spike can produce, because it stops the question being reopened in six months.
If a route works, note which and delete the other. If neither does, add an ADR
recording that the stem is not reachable on this macOS version, and revert the
feature commit; the mic fix, the duration cap and the Target App guard all stand on
their own and should be kept.
