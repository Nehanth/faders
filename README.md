# Faders

A free, tiny macOS menu bar app for per-app volume control. Turn Netflix up while
FaceTime is ducking it, mute one app, or boost a quiet one up to 400%.

Requires macOS 14.4+. No kernel extension or virtual audio driver — it uses Apple's
Core Audio **process taps** API.

## How it works

For each app you adjust, Faders:

1. creates a private process tap on that app's audio processes, muting the original stream,
2. builds a private aggregate device = your current output device + the tap,
3. copies the tapped audio to the output in a real-time callback, multiplied by your gain
   (with smoothing and a soft clipper so boosts don't crackle).

Apps left at 100% are never touched. Setting an app back to 100% removes its tap.
If Faders quits or crashes, macOS removes the taps automatically and audio goes back to normal.

## Build

```sh
./build.sh          # no Xcode needed, just the Command Line Tools
open build/Faders.app
```

The first time you move a slider, macOS will ask for **System Audio Recording**
permission (System Settings › Privacy & Security › Screen & System Audio Recording).

## Notes

- Browser audio comes from helper processes; Faders groups them under the browser.
  Safari's media plays from the shared WebKit process, so it's attributed to Safari.
- Changing output devices (e.g. connecting AirPods) rebuilds the taps automatically.
- Levels are remembered per app.

## License

MIT
