<!-- █ dcj · dotcomjack.com · MIT -->
# Changelog

Every release is on the [releases page](https://github.com/dotcomjack/nocturne/releases)
with its full notes and a signed, notarized download. This file is the short
version.

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
