# MicPin

A tiny macOS menubar app that pins one audio **input** device as the system
default, so nothing can steal your microphone.

macOS has no device-priority setting: whatever was plugged in or paired most
recently wins the default input. Connect AirPods, a headset or a monitor webcam
and your good microphone is silently dropped — usually discovered halfway through
a call. MicPin puts it back, within a fraction of a second.

Output is never touched, so the two stay independent: listen through Bluetooth
headphones while a USB or XLR mic keeps the input.

## Install

Download the latest `MicPin-<version>-universal.zip` from
[**Releases**](https://github.com/IamSwap/micpin/releases), unzip it, and drag
`MicPin.app` into `/Applications`.

Releases are signed with a Developer ID certificate and notarized by Apple, so it
opens normally — no right-click → Open, no "unidentified developer" warning.

Then:

1. A microphone icon appears in the menubar. There is no Dock icon or window.
2. Click it and choose your microphone under **Pinned input device**.
3. Click **Open at login** so it starts with your Mac.

Done. macOS can no longer hand the input to whatever connected last.

**Requirements:** macOS 13 Ventura or later. Universal — Apple silicon and Intel.

**Permissions:** none. MicPin never opens an audio stream, it only reads and sets
CoreAudio device properties, so macOS never prompts for microphone access.

## Using it

| Menu item | |
|---|---|
| *Holding &lt;device&gt;* | current state; also reports when the pinned device is unplugged or paused |
| device list | pick which input to pin (radio) |
| Pin nothing | stop pinning, leave the app running |
| Pause pinning | escape hatch for when you genuinely want another mic |
| Open at login | `SMAppService` registration, mirrors System Settings → Login Items |
| Sound Settings… | opens the Sound pane |
| Quit MicPin | ⌘Q |

The icon reflects state: `mic.fill` holding, `mic.badge.xmark.fill` pinned device
not connected, `mic.slash.fill` paused, `mic` nothing pinned.

If the pinned device is unplugged, MicPin does nothing and lets macOS choose —
it only intervenes when the device it is holding is actually available.

### One caveat worth knowing

Some apps — Zoom, Teams, Google Meet — remember their own input device
independently of the system default. MicPin fixes the system default; if one of
those is explicitly set to another microphone, change it once inside that app.

## How it works

It registers CoreAudio property listeners on the system object for
`kAudioHardwarePropertyDefaultInputDevice` and `kAudioHardwarePropertyDevices`,
so it reacts to a change rather than polling for one. The switch back happens in
the same run loop turn as the steal — fast enough that an app opening the
microphone won't see the wrong device.

macOS sometimes assigns the default input a beat *after* the device-list
notification, overwriting whatever was just set, so each event also re-checks at
0.4s, 1.0s and 2.5s. Waking from sleep triggers the same re-check.

The pinned device is matched by CoreAudio UID, falling back to its name. A USB
device's UID embeds the port it is plugged into
(`AppleUSBAudioEngine:DJI Technology Co., Ltd.:Wireless Mic Rx:…:3`), so moving
the receiver to a different port changes it — the name fallback covers that.

## CLI

The binary answers a few flags without starting the menubar app, so state can be
checked or scripted from a terminal:

```sh
MicPin=/Applications/MicPin.app/Contents/MacOS/MicPin
$MicPin --status
$MicPin --register-login-item
$MicPin --unregister-login-item
```

`--status` prints the pinned device, whether it is connected, paused state, the
live default input, whether the pin is currently being held, whether the app is
running, and every input device (`*` marks the default):

```
pinned:         Wireless Mic Rx
connected:      yes
paused:         no
default input:  Wireless Mic Rx
holding:        yes
running:        yes
inputs:
    iPhone 12 mini Microphone
  * Wireless Mic Rx
    BlackHole 2ch
```

## Preferences

Stored in `~/Library/Preferences/com.chitranu.micpin.plist`:

```sh
defaults read com.chitranu.micpin
defaults write com.chitranu.micpin pinnedInputName -string "Wireless Mic Rx"
```

## Uninstall

```sh
/Applications/MicPin.app/Contents/MacOS/MicPin --unregister-login-item
pkill -x MicPin
rm -rf /Applications/MicPin.app
defaults delete com.chitranu.micpin
```

Release the login item *before* deleting the bundle, or a stale registration
lingers in System Settings → Login Items with nothing behind it.

## Build from source

```sh
./build.sh                        # → /Applications/MicPin.app, ad-hoc signed
./build.sh ~/Applications/MicPin.app
UNIVERSAL=1 ./build.sh            # fat binary, arm64 + x86_64
```

One `swiftc` invocation over a single source file. No Xcode project, no package
manager, no dependencies — just the Xcode command line tools. Builds for the host
architecture unless `UNIVERSAL=1` is set.

macOS 13 is the floor because the login item uses `SMAppService`. One status icon
(`mic.badge.xmark.fill`) needs macOS 14 and falls back to a plain mic symbol on
Ventura.

Developed and tested on macOS 27 (Tahoe) on Apple silicon; release builds are
produced and smoke-tested on macOS 15 in CI. The x86_64 slice is built and
verified present, but has not been run on real Intel hardware — reports welcome.

A locally built app is ad-hoc signed, which is fine on the machine that built it
but will warn on any other Mac. Distribution requires notarization; see
[docs/RELEASING.md](docs/RELEASING.md).

## Contributing

Issues and pull requests are welcome. The whole app is
[one file](Sources/MicPin.swift) — around 470 lines including the CoreAudio
plumbing — so it should be quick to find your way around.

`./doctor.sh` checks your toolchain, certificates and notary credentials and
explains whatever is missing.

## Prior art

Based on the idea in <https://www.bbss.dev/posts/macos-default-input/>, which
solves the inverse problem — a shell `while` loop polling `SwitchAudioSource`
once a second to *ban* one bad device. Banning doesn't scale: ban the headset and
AirPods still steal the input; ban those and the Continuity Camera mic does.
MicPin pins a chosen device instead, and uses CoreAudio notifications rather than
a poll, so it costs nothing while idle.

No dependency on `switchaudio-osx` or anything else — it talks to the CoreAudio
HAL directly.

## License

[MIT](LICENSE)
