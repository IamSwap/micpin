# Releasing MicPin

Notes for maintainers. Using MicPin needs none of this — see the [README](../README.md).

## Cutting a release

```sh
gh release create v1.2.0 --generate-notes --title "MicPin 1.2.0"
```

Publishing a release triggers [`release.yml`](../.github/workflows/release.yml), which
builds a universal binary, signs it with Developer ID, notarizes it, staples the
ticket and attaches `MicPin-<version>-universal.zip` to the release.

`CFBundleShortVersionString` is stamped from the tag (`v1.2.0` → `1.2.0`) and
`CFBundleVersion` from the run number, so versions come from tags rather than
hand-edited `Info.plist` entries.

`workflow_dispatch` runs the whole pipeline and uploads a workflow artifact
without touching a release — use it to test signing changes:

```sh
gh workflow run Release
gh run watch
```

The workflow verifies independently of `build.sh`: it staples, asserts with
`spctl`, then unpacks the archive a user would actually download and asserts
*that* copy passes. A ticket can be correctly stapled to the app and still be
lost by a bad archiving step, so checking the app alone is not enough.

## The Homebrew cask

Nothing to do. [IamSwap/homebrew-tap](https://github.com/IamSwap/homebrew-tap)
polls for new releases every 30 minutes and commits the version and sha256
itself.

It runs there rather than here because a workflow's `GITHUB_TOKEN` only has write
access to its own repository — bumping the tap from this side would mean keeping
a personal access token as a secret. Releases are public, so polling needs none.

For an instant bump instead of waiting:

```sh
gh workflow run update-cask.yml -R IamSwap/homebrew-tap
```

A published release can briefly have no asset attached, since this workflow
uploads it a few minutes later. The tap treats that as "not ready yet" and picks
it up on the next run rather than failing.

## Required repository secrets

| Secret | What |
|---|---|
| `DEVELOPER_ID_P12` | base64 of a `.p12` holding the Developer ID Application cert **and** its private key |
| `DEVELOPER_ID_P12_PASSWORD` | the password set when exporting that `.p12` |
| `NOTARY_KEY_P8` | base64 of the App Store Connect API `.p8` key |
| `NOTARY_KEY_ID` | that key's ID |
| `NOTARY_ISSUER_ID` | the issuer UUID from App Store Connect |

Export the certificate from Keychain Access — sidebar **login** → **My Certificates**
→ right-click the identity → **Export** → Personal Information Exchange (`.p12`).
Being listed under *My Certificates* is the guarantee the private key is included;
a `.p12` without it imports fine but yields no signing identity.

macOS then asks for two different passwords in a row: first one to protect the
`.p12` (this becomes `DEVELOPER_ID_P12_PASSWORD`), then your macOS login password
to authorise the export.

Set them without the values touching your shell history:

```sh
base64 -i Certificates.p12 | gh secret set DEVELOPER_ID_P12
gh secret set DEVELOPER_ID_P12_PASSWORD                        # prompts, hidden
base64 -i AuthKey_XXXXXXXXXX.p8 | gh secret set NOTARY_KEY_P8
gh secret set NOTARY_KEY_ID --body "XXXXXXXXXX"
gh secret set NOTARY_ISSUER_ID --body "<issuer-uuid>"
```

The signing keychain password is generated per run, so it is not a secret. The
workflow creates a throwaway keychain and deletes it in an `always()` step, so a
failed build never leaves the signing key on the runner.

## Building a signed release locally

Check the prerequisites first — `doctor.sh` reports the toolchain, whether a
usable certificate is installed, whether stored notary credentials actually
authenticate against Apple, and whether the built app passes Gatekeeper:

```sh
./doctor.sh              # toolchain and certificates
./doctor.sh micpin       # also validate the "micpin" notary profile
```

Then:

```sh
SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" \
NOTARY_PROFILE=micpin \
UNIVERSAL=1 \
./build.sh
```

`SIGN_IDENTITY` alone signs with the hardened runtime and a secure timestamp.
Adding `NOTARY_PROFILE` also submits to Apple, waits for the verdict, staples the
ticket, re-zips so `dist/MicPin.zip` carries it, and asserts with `spctl`.

Store notary credentials once. An App Store Connect API key is preferable to an
app-specific password — it is team-scoped, revocable without touching anyone's
personal Apple ID, and works unchanged in CI:

```sh
xcrun notarytool store-credentials micpin \
    --key AuthKey_XXXXXXXXXX.p8 --key-id XXXXXXXXXX --issuer <issuer-uuid>
```

The app-specific password form also works:

```sh
xcrun notarytool store-credentials micpin \
    --apple-id you@example.com --team-id TEAMID --password <app-specific-password>
```

That must be an [app-specific password](https://support.apple.com/en-us/102654),
not the Apple ID password.

## Certificate gotchas

**The certificate must be `Developer ID Application`.** An `Apple Distribution`
certificate is for the Mac App Store and is rejected for direct distribution. The
trap is that it signs *cleanly* — correct hardened runtime, valid timestamp — and
only fails later at `spctl --assess` or on the user's Mac. Check what you have:

```sh
security find-identity -v -p codesigning
```

Create one in Xcode via *Settings → Accounts → select the team → Manage
Certificates → + → Developer ID Application*. **Only the team's Account Holder
can create these**; Admin is not sufficient for this certificate type, and the
option simply will not appear.

The private key exists only on the Mac that generated it. Export a `.p12` backup
and keep it somewhere durable — losing it means revoking and reissuing, and Apple
caps how many a team may hold. An App Store Connect `.p8` can only be downloaded
once, so back that up too.

## Entitlements

None are needed. MicPin never opens an audio stream — it only reads and sets
CoreAudio device properties — so it requires no microphone permission and
triggers no TCC prompt. Adding a microphone entitlement would make macOS prompt
users for access the app does not need.
