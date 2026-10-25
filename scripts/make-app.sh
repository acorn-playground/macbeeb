#!/bin/sh
# Builds MacBeeb.app in .build/app.
#
#   scripts/make-app.sh            ad-hoc signed, this Mac's architecture
#   UNIVERSAL=1 SIGN_IDENTITY="Developer ID Application: ..." scripts/make-app.sh
#
# With a signing identity, everything is signed for notarisation: hardened
# runtime and secure timestamps, inside out (scripts/release.sh does this).
set -e
cd "$(dirname "$0")/.."

if [ -n "$UNIVERSAL" ]; then
    ARCHS="--arch arm64 --arch x86_64"
fi
swift build -c release $ARCHS --product MacBeeb
swift build -c release $ARCHS --product macbeeb-mcp
swift build -c release $ARCHS --product MacBeebQuickLook
BIN=$(swift build -c release $ARCHS --show-bin-path)

APP=.build/app/MacBeeb.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN/MacBeeb" "$APP/Contents/MacOS/"
# The MCP server, for agents: claude mcp add macbeeb -- .../MacBeeb.app/Contents/MacOS/macbeeb-mcp
cp "$BIN/macbeeb-mcp" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
cp -R "$BIN/macbeeb_BeebROMs.bundle" "$APP/Contents/Resources/"
# The bookshelf's catalogue and covers.
cp -R "$BIN/macbeeb_BeebLibrary.bundle" "$APP/Contents/Resources/"
# The Hardware Expansion Guide (Help menu), from docs/.
mkdir -p "$APP/Contents/Resources/Guides"
cp -R docs/hardware-expansions "$APP/Contents/Resources/Guides/"
cp docs/network-studio/README.md "$APP/Contents/Resources/Guides/hardware-expansions/network-studio.md"
# The icon: Icon Composer's AppIcon.icon (drawn by Tools/icon/draw.py),
# compiled to Assets.car for macOS 26 and AppIcon.icns.
xcrun actool Resources/AppIcon.icon --compile "$APP/Contents/Resources" --platform macosx \
    --minimum-deployment-target 26.0 --app-icon AppIcon \
    --output-partial-info-plist .build/app/AppIcon-partial.plist > /dev/null
rm .build/app/AppIcon-partial.plist
# BeebAsm, for assembling from VS Code and the agent tools (GPLv3, like
# MacBeeb; its source is the ThirdParty/beebasm submodule).
rm -f .build/beebasm/beebasm
make beebasm UNIVERSAL=$UNIVERSAL
cp .build/beebasm/beebasm "$APP/Contents/MacOS/"
cp ThirdParty/beebasm/COPYING.txt "$APP/Contents/Resources/BeebAsm-COPYING.txt"
# Baron, the other assembler (MIT; the ThirdParty/baron submodule).
rm -f .build/baron/baron
make baron UNIVERSAL=$UNIVERSAL
cp .build/baron/baron "$APP/Contents/MacOS/"
cp ThirdParty/baron/LICENSE "$APP/Contents/Resources/Baron-LICENSE.txt"
cp ThirdParty/baron/extern/richc/LICENSE "$APP/Contents/Resources/richc-LICENSE.txt"
cp LICENSE "$APP/Contents/Resources/LICENSE.txt"
# The release notes, for Help > What's New.
cp WHATSNEW.md "$APP/Contents/Resources/WhatsNew.md"
# The Quick Look preview of disc images, an app extension.
APPEX="$APP/Contents/PlugIns/MacBeebQuickLook.appex"
mkdir -p "$APPEX/Contents/MacOS"
cp "$BIN/MacBeebQuickLook" "$APPEX/Contents/MacOS/"
cp Resources/QuickLook/Info.plist "$APPEX/Contents/"
# ditto keeps the framework's symlinks.
ditto "$BIN/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"

if [ -n "$SPARKLE_PUBLIC_KEY" ]; then
    plutil -replace SUPublicEDKey -string "$SPARKLE_PUBLIC_KEY" "$APP/Contents/Info.plist"
fi
# The extension's version is the app's.
for PLIST in "$APP/Contents/Info.plist" "$APPEX/Contents/Info.plist"; do
    if [ -n "$VERSION" ]; then
        plutil -replace CFBundleShortVersionString -string "$VERSION" "$PLIST"
    fi
    if [ -n "$BUILD_NUMBER" ]; then
        plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$PLIST"
    fi
done

IDENTITY="${SIGN_IDENTITY:--}"
if [ "$IDENTITY" = "-" ]; then
    # Ad hoc: no hardened runtime, whose library validation would reject
    # the (also ad hoc, so "different team") Sparkle framework.
    OPTIONS="--timestamp=none"
else
    OPTIONS="--options runtime --timestamp"
fi
sign() {
    codesign --force $OPTIONS --sign "$IDENTITY" "$@"
}

# Sparkle's helpers first (as Sparkle's documentation describes), then the
# framework, the MCP server, the Quick Look extension (sandboxed, as
# extensions must be) and the app.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
sign "$SPARKLE/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$SPARKLE/XPCServices/Downloader.xpc"
sign "$SPARKLE/Autoupdate"
sign "$SPARKLE/Updater.app"
sign "$APP/Contents/Frameworks/Sparkle.framework"
sign "$APP/Contents/MacOS/macbeeb-mcp"
sign "$APP/Contents/MacOS/beebasm"
sign "$APP/Contents/MacOS/baron"
sign --entitlements Resources/QuickLook/QuickLook.entitlements "$APPEX"
sign "$APP"
codesign --verify --deep --strict "$APP"
echo "Built $APP"
