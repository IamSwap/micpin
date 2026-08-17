#!/bin/bash
set -uo pipefail

# Checks everything needed to ship a notarized MicPin release, and says what to
# do next. Safe to run repeatedly; changes nothing.
#
#   ./doctor.sh                 check the toolchain and certificates
#   ./doctor.sh <profile-name>  also validate stored notary credentials

PROFILE="${1:-}"
problems=0

ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; problems=$((problems + 1)); }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }
note() { printf '    %s\n' "$1"; }

echo
echo "Toolchain"

if xcrun --find swiftc >/dev/null 2>&1; then
    ok "swiftc $(swift --version 2>/dev/null | sed -n 's/.*Apple Swift version \([^ ]*\).*/\1/p')"
else
    bad "swiftc not found — install the Xcode command line tools"
fi

if xcrun --find notarytool >/dev/null 2>&1; then
    ok "notarytool present"
else
    bad "notarytool not found — needs Xcode 13 or newer"
fi

echo
echo "Signing certificate"

identities=$(security find-identity -v -p codesigning 2>/dev/null)
devid=$(echo "$identities" | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)
appledist=$(echo "$identities" | sed -n 's/.*"\(Apple Distribution: [^"]*\)".*/\1/p' | head -1)

if [[ -n $devid ]]; then
    ok "$devid"
    note "SIGN_IDENTITY=\"$devid\""
else
    bad "no \"Developer ID Application\" certificate in the keychain"

    if [[ -n $appledist ]]; then
        warn "found \"$appledist\""
        note "That is a Mac App Store certificate. It signs without error but is"
        note "rejected for direct distribution — it cannot be notarized."
    fi

    note "Create one in Xcode: Settings → Accounts → select the team →"
    note "Manage Certificates → + → Developer ID Application."
    note "Only the Account Holder can create these; Admin is not enough."
fi

echo
echo "Notary credentials"

if [[ -z $PROFILE ]]; then
    warn "no profile name given — pass one to validate it, e.g. ./doctor.sh micpin"
    note "Store credentials once with either:"
    note "  xcrun notarytool store-credentials <name> --apple-id <email> \\"
    note "      --team-id <TEAMID> --password <app-specific-password>"
    note "  xcrun notarytool store-credentials <name> --key <AuthKey.p8> \\"
    note "      --key-id <KEY_ID> --issuer <ISSUER_UUID>"
elif xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    ok "profile \"$PROFILE\" authenticates against Apple"
else
    bad "profile \"$PROFILE\" missing or rejected by Apple"
    note "Re-run notarytool store-credentials for this profile."
fi

echo
echo "Installed app"

APP=/Applications/MicPin.app

if [[ -d $APP ]]; then
    ok "$APP"

    # Authority lines need verbose=2; plain -dv omits them.
    siginfo=$(codesign -dv --verbose=2 "$APP" 2>&1)

    if grep -q 'Signature=adhoc' <<<"$siginfo"; then
        note "signed by: ad-hoc — local use only"
    else
        signer=$(sed -n 's/^Authority=//p' <<<"$siginfo" | head -1)
        note "signed by: ${signer:-unknown}"
    fi

    if xcrun stapler validate "$APP" >/dev/null 2>&1; then
        note "notarization ticket: stapled"
    fi

    if spctl --assess --type execute "$APP" >/dev/null 2>&1; then
        ok "Gatekeeper accepts it — safe to distribute"
    else
        warn "Gatekeeper rejects it — fine locally, will warn on other Macs"
    fi
else
    warn "not built yet — run ./build.sh"
fi

echo
if [[ $problems -eq 0 ]]; then
    echo "Ready. Build a release with:"
    echo "  SIGN_IDENTITY=\"${devid:-Developer ID Application: ...}\" NOTARY_PROFILE=${PROFILE:-<name>} ./build.sh"
else
    echo "$problems blocking issue(s) above."
fi
echo

exit "$((problems > 0))"
