#!/bin/sh
# Builds a notarised MacBeeb release.
#
#   scripts/release.sh VERSION            build, sign, notarise and staple
#   scripts/release.sh VERSION --publish  ...then tag and make a GitHub release
#
# Produces, in .build/releases/VERSION:
#   MacBeeb-VERSION.dmg   for downloading
#   MacBeeb-VERSION.zip   for Sparkle
#   appcast.xml           the update feed, including earlier releases
#   notes.md              this release's section of WHATSNEW.md
#
# WHATSNEW.md must have a "## VERSION" section: it becomes the GitHub
# release's notes, Sparkle's update window, and Help > What's New.
#
# Needs, in .env.local (or the environment): APPLE_ID,
# APPLE_APP_SPECIFIC_PASSWORD, APPLE_TEAM_ID and CSC_NAME (the Developer ID
# Application identity, with or without that prefix). The Sparkle signing
# key lives in the login keychain under the account "macbeeb"; create it
# once with:
#   .build/artifacts/sparkle/Sparkle/bin/generate_keys --account macbeeb
set -e
cd "$(dirname "$0")/.."

VERSION=$1
[ -n "$VERSION" ] || { echo "usage: scripts/release.sh VERSION [--publish]" >&2; exit 2; }
PUBLISH=
[ "$2" = "--publish" ] && PUBLISH=1

if [ -f .env.local ]; then
    set -a
    . ./.env.local
    set +a
fi
for name in APPLE_ID APPLE_APP_SPECIFIC_PASSWORD APPLE_TEAM_ID CSC_NAME; do
    eval "value=\$$name"
    [ -n "$value" ] || { echo "release: $name isn't set" >&2; exit 1; }
done
case "$CSC_NAME" in
    "Developer ID Application:"*) IDENTITY=$CSC_NAME ;;
    *) IDENTITY="Developer ID Application: $CSC_NAME" ;;
esac

# This release's notes: its section of WHATSNEW.md, without the heading.
NOTES=$(awk -v v="$VERSION" '
    /^<!--/ { comment = 1 } comment { if (/-->/) comment = 0; next }
    /^## / { on = ($2 == v); next }
    on' WHATSNEW.md | sed -e '/./,$!d')
[ -n "$NOTES" ] || { echo "release: WHATSNEW.md has no \"## $VERSION\" section" >&2; exit 1; }

REPO=acorn-playground/macbeeb
SPARKLE_BIN=.build/artifacts/sparkle/Sparkle/bin
[ -x "$SPARKLE_BIN/generate_keys" ] || swift package resolve
SPARKLE_PUBLIC_KEY=$("$SPARKLE_BIN/generate_keys" --account macbeeb -p) || {
    echo "release: no Sparkle key; run $SPARKLE_BIN/generate_keys --account macbeeb" >&2
    exit 1
}

if [ -n "$(git status --porcelain)" ]; then
    echo "release: warning: the working tree has uncommitted changes" >&2
    [ -n "$PUBLISH" ] && { echo "release: commit them before publishing" >&2; exit 1; }
fi

BUILD_NUMBER=$(git rev-list --count HEAD)
export UNIVERSAL=1 SIGN_IDENTITY="$IDENTITY" VERSION BUILD_NUMBER SPARKLE_PUBLIC_KEY
scripts/make-app.sh

APP=.build/app/MacBeeb.app
OUT=.build/releases/$VERSION
rm -rf "$OUT"
mkdir -p "$OUT/sparkle"
printf '%s\n' "$NOTES" > "$OUT/notes.md"

notarise() {
    xcrun notarytool submit "$1" --apple-id "$APPLE_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD" \
        --team-id "$APPLE_TEAM_ID" --wait
}

echo "Notarising the app..."
ditto -c -k --keepParent "$APP" "$OUT/notarise.zip"
notarise "$OUT/notarise.zip"
rm "$OUT/notarise.zip"
xcrun stapler staple "$APP"

ZIP="$OUT/MacBeeb-$VERSION.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

echo "Making the disk image..."
STAGING="$OUT/dmg"
mkdir -p "$STAGING"
ditto "$APP" "$STAGING/MacBeeb.app"
ln -s /Applications "$STAGING/Applications"
DMG="$OUT/MacBeeb-$VERSION.dmg"
hdiutil create -quiet -volname "MacBeeb $VERSION" -srcfolder "$STAGING" -format UDZO "$DMG"
rm -rf "$STAGING"
codesign --sign "$IDENTITY" --timestamp "$DMG"
notarise "$DMG"
xcrun stapler staple "$DMG"

echo "Making the appcast..."
# Start from the published feed so earlier releases stay listed.
gh release download --repo "$REPO" --pattern appcast.xml --dir "$OUT/sparkle" 2>/dev/null || true
cp "$ZIP" "$OUT/sparkle/"
# Release notes beside the archive, with its name, are embedded in its item.
cp "$OUT/notes.md" "$OUT/sparkle/MacBeeb-$VERSION.md"
"$SPARKLE_BIN/generate_appcast" --account macbeeb --embed-release-notes \
    --download-url-prefix "https://github.com/$REPO/releases/download/v$VERSION/" \
    "$OUT/sparkle"
cp "$OUT/sparkle/appcast.xml" "$OUT/appcast.xml"

spctl --assess --type open --context context:primary-signature -v "$DMG"
spctl --assess --type execute -v "$APP"
echo "Built $OUT"

if [ -n "$PUBLISH" ]; then
    git tag "v$VERSION"
    git push origin "v$VERSION"
    gh release create "v$VERSION" --repo "$REPO" --title "MacBeeb $VERSION" --notes-file "$OUT/notes.md" \
        "$DMG" "$ZIP" "$OUT/appcast.xml"
    echo "Published https://github.com/$REPO/releases/tag/v$VERSION"
fi
