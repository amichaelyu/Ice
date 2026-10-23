#!/bin/bash
#
# Builds a release of Ice for distribution: archived, signed with a Developer ID, notarized, stapled,
# and zipped, with a Sparkle appcast to go beside it.
#
# Leaves exactly two files in $DIST, Ice.zip and appcast.xml, ready to attach to a GitHub release
# tagged with the marketing version. It does not create that release or tag anything; that is done
# by hand once the artifacts have been looked over.
#
# Settings, all from the environment:
#   DEVELOPMENT_TEAM  the team whose "Developer ID Application" certificate signs the app
#                     (default SNC2X5N2CY)
#   NOTARY_PROFILE    the keychain profile `xcrun notarytool store-credentials` saved (default notary)
#   SPARKLE_ACCOUNT   the keychain account holding the Sparkle EdDSA private key that matches
#                     SUPublicEDKey in Info.plist (default "Ice (amichaelyu fork)")
#   DIST              where the artifacts go (default dist/ in the repository, which git ignores);
#                     it is emptied first
#   DERIVED           derived data and scratch files (default /tmp/ice-release)
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-SNC2X5N2CY}"
NOTARY_PROFILE="${NOTARY_PROFILE:-notary}"
SPARKLE_ACCOUNT="${SPARKLE_ACCOUNT:-Ice (amichaelyu fork)}"
DIST="${DIST:-$ROOT/dist}"
DERIVED="${DERIVED:-/tmp/ice-release}"

ARCHIVE="$DERIVED/Ice.xcarchive"
WORK="$DERIVED/release-work"
APP="$DIST/Ice.app"
ZIP="$DIST/Ice.zip"
SPARKLE_BIN="$DERIVED/SourcePackages/artifacts/sparkle/Sparkle/bin"

# The version the project says it is, for the Ice target alone. MenuBarItemService has its own
# (1.0), so the first match is not good enough; the app built from it is checked against this below.
project_setting() {
    awk -v key="$1" '
        /PRODUCT_BUNDLE_IDENTIFIER = com.jordanbaird.Ice;/ { if (value != "") { print value; exit } }
        /buildSettings = \{/ { value = "" }
        $1 == key { value = $3; sub(/;$/, "", value); gsub(/"/, "", value) }
    ' "$ROOT/Ice.xcodeproj/project.pbxproj"
}
VERSION="$(project_setting MARKETING_VERSION)"
BUILD="$(project_setting CURRENT_PROJECT_VERSION)"
[ -n "$VERSION" ] && [ -n "$BUILD" ] || { echo "error: no version for the Ice target in the project" >&2; exit 1; }
echo "==> Releasing Ice $VERSION ($BUILD), team $DEVELOPMENT_TEAM"

rm -rf "$DIST" "$WORK" "$ARCHIVE"
mkdir -p "$DIST" "$WORK"

# xcodebuild says a great deal. Keep it out of the way, but keep it: on a failure the end of the
# log is printed and the rest stays in $DIST.
run_logged() {
    local name="$1" log="$DIST/$1.log"; shift
    if ! "$@" >"$log" 2>&1; then
        echo "error: $name failed; the last lines of $log follow" >&2
        tail -40 "$log" >&2
        exit 1
    fi
}

echo "==> Archiving"
# Signing comes from here, not the project: the targets name no team, which Scripts/install.sh
# needs for its ad-hoc fallback on Macs without a certificate.
run_logged archive xcodebuild archive \
    -project "$ROOT/Ice.xcodeproj" -scheme Ice -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath "$DERIVED" -archivePath "$ARCHIVE" \
    -skipPackagePluginValidation -skipMacroValidation \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Developer ID Application" \
    DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" ENABLE_HARDENED_RUNTIME=YES

echo "==> Exporting"
sed "s/__DEVELOPMENT_TEAM__/$DEVELOPMENT_TEAM/" "$ROOT/Scripts/ExportOptions.plist" > "$WORK/ExportOptions.plist"
run_logged export xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" -exportOptionsPlist "$WORK/ExportOptions.plist" -exportPath "$WORK/export"
ditto "$WORK/export/Ice.app" "$APP"

# What was built has to be what the project says, or the appcast and the zip would disagree.
BUILT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BUILT_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
if [ "$BUILT_VERSION" != "$VERSION" ] || [ "$BUILT_BUILD" != "$BUILD" ]; then
    echo "error: built $BUILT_VERSION ($BUILT_BUILD), but the project says $VERSION ($BUILD)" >&2
    exit 1
fi

echo "==> Verifying the signature"
codesign --verify --deep --strict --verbose=2 "$APP"
TEAM_SIGNED="$(codesign -dv "$APP" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
if [ "$TEAM_SIGNED" != "$DEVELOPMENT_TEAM" ]; then
    echo "error: signed by team '$TEAM_SIGNED', expected $DEVELOPMENT_TEAM" >&2
    exit 1
fi

echo "==> Notarizing (this usually takes a few minutes)"
ditto -c -k --keepParent "$APP" "$WORK/Ice-unstapled.zip"
xcrun notarytool submit "$WORK/Ice-unstapled.zip" --keychain-profile "$NOTARY_PROFILE" \
    --wait --output-format json > "$WORK/notary.json" || true
SUBMISSION="$(plutil -extract id raw -o - "$WORK/notary.json" 2>/dev/null || true)"
STATUS="$(plutil -extract status raw -o - "$WORK/notary.json" 2>/dev/null || true)"
echo "    submission ${SUBMISSION:-unknown}: ${STATUS:-no status}"
if [ "$STATUS" != "Accepted" ]; then
    echo "error: notarization was not accepted" >&2
    cat "$WORK/notary.json" >&2
    if [ -n "$SUBMISSION" ]; then
        xcrun notarytool log "$SUBMISSION" --keychain-profile "$NOTARY_PROFILE" >&2 || true
    fi
    exit 1
fi
rm -f "$WORK/Ice-unstapled.zip"

echo "==> Stapling"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl -a -vv -t exec "$APP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> Writing the appcast"
# generate_appcast works on a whole directory and leaves things behind in it (deltas, old_updates/),
# so it gets one holding only this zip, and only the appcast comes back.
mkdir -p "$WORK/appcast"
cp "$ZIP" "$WORK/appcast/Ice.zip"
"$SPARKLE_BIN/generate_appcast" --account "$SPARKLE_ACCOUNT" \
    --download-url-prefix "https://github.com/amichaelyu/Ice/releases/download/$VERSION/" \
    -o "$DIST/appcast.xml" "$WORK/appcast"
grep -q "<sparkle:version>$BUILD</sparkle:version>" "$DIST/appcast.xml" \
    || { echo "error: appcast.xml does not offer build $BUILD" >&2; exit 1; }
grep -q 'sparkle:edSignature=' "$DIST/appcast.xml" \
    || { echo "error: appcast.xml carries no EdDSA signature" >&2; exit 1; }

# Only the two artifacts stay. The app and the logs move next to the archive, for looking at later.
rm -rf "$WORK/Ice.app" "$WORK/logs"
mv "$APP" "$WORK/Ice.app"
mkdir -p "$WORK/logs" && mv "$DIST"/*.log "$WORK/logs/"

echo "==> Done"
echo "    version    $VERSION"
echo "    build      $BUILD"
echo "    notarized  $SUBMISSION"
echo "    sha256     $(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
echo "    $ZIP"
echo "    $DIST/appcast.xml"
