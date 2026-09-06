<!-- █ dcj · dotcomjack.com · MIT -->
# Changelog

Every release is on the [releases page](https://github.com/dotcomjack/nocturne/releases)
with its full notes and a signed, notarized download. This file is the short
version.

## 1.4.0

### Only the clock

A fifth mode, and the inverse of Hide everything. **Everything but the clock
goes blank.** The strip covers the menu bar from its left edge to the clock's
left edge and stops there, so every icon disappears and the time stays exactly
as readable as it was. Clicks still pass through. For the person whose problem
is the twenty icons rather than the time.

It is offered everywhere the other modes are: the menu bar menu, Settings, and
the Focus filter picker in System Settings, so a Focus can now put every icon
away and leave the clock.

Three things measured rather than assumed:

- **There is nothing to the right of the clock, so nothing is drawn there.** On
  macOS 26.6.2 the clock's window runs to the screen edge on a notched MacBook
  (x=1588, 142pt wide on a 1728pt screen, which is 2pt past the edge) and sits
  flush on an external display. A second strip to the right would be a dark
  sliver beside the clock with nothing under it, which reads as a bug.
- **It leaves one seam, and only one.** Hide everything has none because its
  only edge is the bar's own bottom edge. Only the clock adds a vertical edge
  where the strip stops at the clock, and the fill picker is offered for it
  for the same reason it is offered for Gone.
- **It is the one covering mode that wants a digital clock**, so arriving here
  from Blind, Gone or Hide everything puts the readout back first and waits for
  Control Center to settle before the strip goes up, on the same path the
  analog swap already used.

Hover to show works here too, and on more than one display only the bar you
are pointing at uncovers. Nocturne's own icon is redrawn on top of the strip,
as in Hide everything, so the way out stays visible.

### Tests

The suite grew from 74 checks to 103. The arithmetic behind the new mode lives
in `MenuBarGeometry`, which is Foundation-only so it can be checked without a
window server, and it is fuzzed: 20,000 random bar and clock layouts, and the
strip never reaches the clock and never leaves the bar. The mode table is now
pinned per case, so a future mode cannot inherit somebody else's coverage from
a `default:` branch. Validated by mutation, as before: three deliberate defects
(cover the whole bar, turn the clock analog, borrow Hide everything's coverage)
and all three caught.

### One limit worth stating

A display whose current Space is a full-screen app keeps its menu bar
uncovered, in every covering mode, if the menu bar is set to stay visible in
full screen. The strip is built with `fullScreenNone` so it never floats over a
video, and that is the trade. Measured on a two display setup with Safari full
screen on the external panel: the strip exists at alpha 1 and the window server
reports it off screen. Not new in this release, but not written down before.

## 1.3.0

### Follow Focus

Nocturne is now a **Focus filter**. Add it under System Settings, Focus, pick a
Focus, Add Filter, Nocturne, and choose a mode. Turn that Focus on from anywhere
signed into your iCloud account, including your iPhone, and this Mac's menu bar
goes with it. End the Focus and the mode you were on comes back.

**It costs no permission.** Not Full Disk Access, not Accessibility, not Screen
Recording, not a Focus prompt. macOS hands the event to Nocturne the same way it
hands it to Mail and Safari. Measured, 18ms from the system recording the Focus
to Nocturne's code running.

**The mode comes back, and it knows when not to.** The pre-Focus mode is
remembered across a quit or a crash, because the app can be killed while a Focus
is running. But if you pick a mode by hand while the Focus is on, that choice is
left alone when the Focus ends.

Three things were measured rather than assumed, and two of them cost a rewrite:

- **`~/Library/DoNotDisturb/DB/Assertions.json` needs Full Disk Access.** It is
  the answer every search result gives, it names the exact Focus, and the first
  implementation of this feature used it. It reads perfectly from a shell and
  fails with `EPERM` from a real `.app`, because Terminal already holds that
  permission. That is the **same trap this project already documents** for
  `kCGWindowName` one section up in the README, walked into a second time in the
  same codebase. Caught before release only because the feature was tested as an
  installed app rather than from the terminal that built it.
- **`INFocusStatusCenter` lies when it is not authorised.** Apple's public Focus
  API prompts for permission, reports one optional boolean so it can never say
  which Focus is on, and unauthorised it returns `Optional(false)` continuously
  while Do Not Disturb is genuinely on, rather than failing.
- **A Focus filter cannot tell "started" from "ended" unless its parameter is
  optional.** Apple promises the app is notified "when this Focus turns on or
  off" and never says how to distinguish them. Both arrive as the same
  `perform()`. With `@Parameter(default:)` they are byte for byte identical.
  With `@Parameter var mode: FocusFilterMode?` the deactivation arrives as
  `nil`, and that is the only signal there is. macOS also calls `perform()`
  twice per transition, 588ms apart, so the handler has to be idempotent.

### One defect the review caught, worth naming

"Restore clock to how it was" used to be undone within 30 seconds, and the first
round of tests did not catch it.

Restore ends Nocturne's *engagement* with the running Focus, but it does not end
the Focus. The backstop sweep kept reading the same live Focus every 30 seconds,
found nothing engaged, and could not tell an hours-old Do Not Disturb from a
brand new one. So it re-hid the menu bar the user had just explicitly un-hidden,
over and over, for as long as the Focus ran. Sleep or a screen unlock brought it
back sooner still.

The state machine now records that *this* Focus was offered and declined, and
the suppression is spent the moment the Focus genuinely ends, so the next one
engages normally.

Worth stating plainly: the whole test suite passed while this bug existed,
because the bug lived in the seam between the state machine and the controller
that feeds it, and every test pointed at the state machine alone. A green suite
is evidence about what you thought to check.

### Tests

The project had none. It now has a suite: 74 checks over the Follow Focus state
machine, including a 50,000 operation fuzz pass, run with `./Tests/run.sh` and
no XCTest target. It was validated by mutation testing rather than by trusting a
green bar: 16 deliberate defects were introduced one at a time and all 16 were
caught, including a re-run of the Restore defect above.

## 1.2.0

### Hover to show

The cover can now hand the bar back on demand. Turn on **Hover to show** and the
strip drops away while the pointer is on the menu bar, then comes back when the
pointer leaves. Off by default.

It exists so you can read the time by going to look for it, which is a
deliberate act, rather than by changing a mode and then remembering to change it
back. The point of the app is to stop the clock catching your eye when you were
not asking. It was never to stop you asking.

Offered in **Gone** and **Hide everything** only. **Blind** hides the time by
writing Control Center's own `IsAnalog` preference, and undoing that costs a
Control Center restart, which is a KeepAlive job on a 1s throttle. Half a second
and a menu bar blink in each direction is not a hover.

**It costs no permission.** Nocturne still asks for nothing. The pointer is read
with a global mouse monitor, and macOS gates key events behind accessibility
while leaving mouse events alone. Measured on macOS 26.3.1 from an ad-hoc signed
`.app` launched with `open`, so with no inherited terminal grant and
`AXIsProcessTrusted()` returning false: 131 of 131 `mouseMoved` events were
delivered. Polling the pointer on a timer was the alternative and is strictly
worse, because it wakes the CPU 20 times a second forever to notice a pointer
that is usually not moving.

Three details that are less obvious than they look:

- **The hover region is the whole menu bar, not the covered rect.** In Gone the
  patch is a 44pt dial in the corner, and requiring the pointer to land on it
  exactly would read as broken. Moving to the bar at all is the gesture.
- **The strip goes transparent rather than being ordered out.** A 2s tracker
  re-shows any window that is not visible, so ordering the strip out would put
  it back within two seconds while the pointer was still resting on the bar.
- **On more than one display, only the bar you are pointing at uncovers.**
  Verified in one pass: laptop strip at alpha 0.0, external strip at alpha 1.0.

## 1.1.1

The shimmer moved the icon, and the sweep became icy dark blue.

## 1.1.0

The menu bar icon can shimmer, and the settings panel got a pass.

## 1.0.8

The quit-safety confirmation could never fail, and raising the window height in
1.0.6 turned out to be a regression.

## 1.0.7

The safety guard in Hide everything was doing nothing, the same guard could make
the bar flash forever, and Settings could show the wrong switch position and
then act inverted.

## 1.0.6

Hide everything uncovered the menu bar for up to 2 seconds, quitting from the
menu blanked the bar for about 1.8 seconds, and Settings hid its own undo
control.

## 1.0.5

Changing one Clock Option silently reverted the others, the Hide everything
strip was 1pt too tall, the beacon could be a decoy, and launch at login failed
silently.

## 1.0.4, 1.0.3, 1.0.2

Packaging and release plumbing.

## 1.0.1

Quitting could leave your clock analog, and Hide everything covered full screen.

## 1.0.0

First release. Four modes, one Apple preference key, no permissions and no
private APIs.
