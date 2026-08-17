# MicPin

A menubar app that pins one audio **input** device as the macOS default.

macOS has no device-priority setting: whatever was plugged in or paired most
recently wins the default input, so connecting AirPods or a headset silently
takes the microphone away from a good mic. MicPin puts it back.

Output selection is never touched, so the two stay independent: listen through
Bluetooth headphones while a USB or XLR mic keeps the input.

Built for a DJI Mic receiver losing the input to a pair of Bluetooth headphones,
but nothing is hardcoded — pick any input device from the menu.

## How it works

It registers CoreAudio property listeners on the system object for
`kAudioHardwarePropertyDefaultInputDevice` and `kAudioHardwarePropertyDevices`,
so it reacts to a change rather than polling for one. The switch back happens in
the same run loop turn the steal did — fast enough that an app opening the mic
won't see the wrong device.

macOS sometimes assigns the default input a beat *after* the device-list
notification, overwriting whatever was just set, so each event also re-checks at
0.4s, 1.0s and 2.5s. Waking from sleep triggers the same re-check.

The pinned device is matched by CoreAudio UID, falling back to its name. The UID
of a USB device embeds the port it is plugged into
(`AppleUSBAudioEngine:DJI Technology Co., Ltd.:Wireless Mic Rx:…:3`), so moving
the receiver to another port changes it — the name fallback covers that.

## Menu

| Item | |
|---|---|
| *Holding &lt;device&gt;* | current state, also shows when the pinned device is unplugged |
| device list | pick which input to pin (radio) |
| Pin nothing | stop pinning, keep the app running |
| Pause pinning | temporary escape hatch when another mic is genuinely wanted |
| Open at login | `SMAppService` registration, mirrors System Settings → Login Items |
| Sound Settings… | opens the Sound pane |

Icon reflects state: `mic.fill` holding, `mic.badge.xmark.fill` pinned device
missing, `mic.slash.fill` paused, `mic` nothing pinned.

## Build

```sh
./build.sh                        # → /Applications/MicPin.app
./build.sh ~/Applications/MicPin.app
UNIVERSAL=1 ./build.sh            # fat binary, arm64 + x86_64
```

Single-file `swiftc` build, ad-hoc signed. No Xcode project, no dependencies.
Requires the Xcode command line tools; builds for the host architecture.

macOS 13 is the floor because the login item uses `SMAppService`, and one status
icon (`mic.badge.xmark.fill`) needs macOS 14 — it falls back to a plain mic
symbol on older releases. Only tested on macOS 27 (Tahoe), Apple silicon.

An ad-hoc signed build is fine on the machine that built it, but macOS will warn
on any other machine. For that, build a notarized release.

## Signed and notarized release

Check the prerequisites first — it reports the toolchain, whether a usable
certificate is installed, whether stored notary credentials actually
authenticate, and whether the built app passes Gatekeeper:

```sh
./doctor.sh              # toolchain and certificates
./doctor.sh micpin       # also validate the "micpin" notary profile
```

Then:

```sh
SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" \
NOTARY_PROFILE=micpin \
./build.sh
```

`SIGN_IDENTITY` alone signs with the hardened runtime and a secure timestamp.
Adding `NOTARY_PROFILE` also submits to Apple, waits for the verdict, staples the
ticket, re-zips so the archive carries it, and asserts the result with `spctl`.

Store the notary credentials once:

```sh
xcrun notarytool store-credentials micpin \
    --apple-id you@example.com --team-id TEAMID --password <app-specific-password>
```

The password is an [app-specific password](https://support.apple.com/en-us/102654),
not the Apple ID password.

**The certificate must be `Developer ID Application`.** An `Apple Distribution`
certificate is for the Mac App Store and is rejected for direct distribution —
it signs cleanly and still fails `spctl --assess`, so the failure only surfaces
at notarization. Create one in Xcode via *Settings → Accounts → select team →
Manage Certificates → + → Developer ID Application*; only the team's Account
Holder can, as Admin is not sufficient for this certificate type.

The private key exists only on the Mac that generated it. Export it as a `.p12`
and keep it somewhere safe — if it is lost the certificate has to be revoked and
reissued, and Apple caps how many a team may hold.

No entitlements are needed. MicPin never opens an audio stream — it only reads
and sets CoreAudio device properties — so it requires no microphone permission
and triggers no TCC prompt.

## Releases

Publishing a GitHub release triggers `.github/workflows/release.yml`, which builds
a **universal** (arm64 + x86_64) binary, signs it with Developer ID, notarizes it,
staples the ticket and attaches `MicPin-<version>-universal.zip` to the release.
So a download needs no Gatekeeper right-click and no build tools.

The workflow re-verifies independently of `build.sh`: it staples, asserts with
`spctl`, then unpacks the archive a user would actually download and asserts
*that* passes — a ticket can be stapled to the app and still be lost by a bad
archiving step.

`CFBundleShortVersionString` is stamped from the tag (`v1.2.0` → `1.2.0`), so
version numbers come from the tag rather than being edited by hand.

`workflow_dispatch` runs everything and uploads a workflow artifact without
touching a release — use it to test signing changes.

### Required repository secrets

| Secret | What |
|---|---|
| `DEVELOPER_ID_P12` | base64 of a `.p12` holding the Developer ID Application cert **and** its private key |
| `DEVELOPER_ID_P12_PASSWORD` | the password set when exporting that `.p12` |
| `NOTARY_KEY_P8` | base64 of the App Store Connect API `.p8` key |
| `NOTARY_KEY_ID` | that key's ID |
| `NOTARY_ISSUER_ID` | the issuer UUID from App Store Connect |

Export the certificate from Keychain Access (right-click the identity → Export →
`.p12`), then:

```sh
base64 -i Certificates.p12 | pbcopy
base64 -i AuthKey_XXXXXXXXXX.p8 | pbcopy
```

The keychain password is generated per run, so it is not a secret. The workflow
creates a throwaway keychain and deletes it in an `always()` step, so a failed
build never leaves the signing key on the runner.

## CLI

The binary answers a few flags without starting the menubar app, so state can be
checked or scripted from a terminal:

```sh
/Applications/MicPin.app/Contents/MacOS/MicPin --status
/Applications/MicPin.app/Contents/MacOS/MicPin --register-login-item
/Applications/MicPin.app/Contents/MacOS/MicPin --unregister-login-item
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

## Prior art

Based on the idea in <https://www.bbss.dev/posts/macos-default-input/>, which
solves the inverse problem — a shell `while` loop polling `SwitchAudioSource`
once a second to *ban* one bad device. Banning doesn't scale: ban the headset and
AirPods still steal the input, ban those and the Continuity Camera mic does.
MicPin pins a chosen device instead, and uses CoreAudio notifications rather
than a poll.

MicPin has no dependency on `switchaudio-osx` or anything else — it talks to the
CoreAudio HAL directly. That tool was only used while testing.
