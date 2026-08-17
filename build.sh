#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

# Build MicPin.app.
#
#   ./build.sh                        ad-hoc signed, for local use
#   ./build.sh ~/Applications/MicPin.app
#
# Signed / notarized release, for distribution to other machines:
#
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" \
#   NOTARY_PROFILE=micpin \
#   ./build.sh
#
# SIGN_IDENTITY alone signs with the hardened runtime and a secure timestamp.
# Adding NOTARY_PROFILE also submits to Apple, waits, and staples the ticket.
# Create the profile once with:
#
#   xcrun notarytool store-credentials micpin \
#       --apple-id you@example.com --team-id TEAMID --password <app-specific-password>
#
# Notarization requires a "Developer ID Application" certificate. An
# "Apple Distribution" certificate is for the App Store and will be rejected.

APP="${1:-/Applications/MicPin.app}"
CONTENTS="$APP/Contents"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

# Refuse to clobber a Homebrew-managed install. Overwriting it silently leaves
# `brew list` claiming a version that is no longer on disk, and the next
# `brew upgrade` would quietly replace the local build.
#
# Homebrew keeps a symlink in the Caskroom pointing at wherever it put the app,
# so resolving that is exact — no need to assume /Applications.
if [[ -z ${FORCE:-} ]] && command -v brew >/dev/null 2>&1; then
    for link in "$(brew --caskroom 2>/dev/null)"/micpin/*/MicPin.app; do
        [[ -L $link ]] || continue

        if [[ "$(readlink "$link")" == "$APP" ]]; then
            cat >&2 <<EOF
Refusing to build over $APP — Homebrew manages it.

Overwriting it would leave Homebrew's records pointing at a version that is no
longer there, and the next \`brew upgrade\` would silently replace your build.

  ./build.sh ~/Applications/MicPin.app   build alongside it, leave brew alone
  brew uninstall --cask micpin           hand the path back to this script
  FORCE=1 ./build.sh                     overwrite it anyway
EOF
            exit 1
        fi
    done
fi

if pgrep -x MicPin >/dev/null; then
    echo "Stopping running MicPin…"
    pkill -x MicPin
    while pgrep -x MicPin >/dev/null; do sleep 0.2; done
fi

rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

compile() {
    xcrun swiftc \
        -O \
        -target "$1-apple-macos13.0" \
        -framework AppKit \
        -framework CoreAudio \
        -framework ServiceManagement \
        -o "$2" \
        Sources/MicPin.swift
}

if [[ -n ${UNIVERSAL:-} ]]; then
    echo "Compiling universal (arm64 + x86_64)…"
    slices=$(mktemp -d)
    trap 'rm -rf "$slices"' EXIT

    for arch in arm64 x86_64; do
        compile "$arch" "$slices/MicPin-$arch"
    done

    lipo -create -output "$CONTENTS/MacOS/MicPin" "$slices/MicPin-arm64" "$slices/MicPin-x86_64"
else
    echo "Compiling for $(uname -m)…"
    compile "$(uname -m)" "$CONTENTS/MacOS/MicPin"
fi

lipo -archs "$CONTENTS/MacOS/MicPin"

cp Info.plist "$CONTENTS/Info.plist"
cp Resources/MicPin.icns "$CONTENTS/Resources/MicPin.icns"

if [[ $SIGN_IDENTITY == "-" ]]; then
    echo "Signing ad-hoc…"
    codesign --force --sign - "$APP"
else
    echo "Signing as ${SIGN_IDENTITY}…"
    codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" "$APP"
fi

codesign --verify --strict --verbose=1 "$APP"

if [[ -z $NOTARY_PROFILE ]]; then
    echo "Built $APP"
    exit 0
fi

if [[ $SIGN_IDENTITY == "-" ]]; then
    echo "Refusing to notarize an ad-hoc signed build; set SIGN_IDENTITY." >&2
    exit 1
fi

# Next to the script, not next to the installed app — $APP is usually
# /Applications, which is no place for a build artifact.
ZIP="dist/MicPin.zip"
mkdir -p dist
rm -f "$ZIP"

echo "Zipping for submission…"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "Submitting to Apple…"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait

echo "Stapling…"
xcrun stapler staple "$APP"

# Rebuild the zip so the distributed archive carries the stapled ticket.
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

spctl --assess --type execute --verbose=2 "$APP"

echo "Built and notarized $APP"
echo "Distributable archive: $ZIP"
