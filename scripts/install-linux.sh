#!/bin/sh
# Builds MacBeeb for Linux and installs it: for you alone in ~/.local (the
# default), or with --prefix for everyone (sudo, /usr/local). Uninstalls
# with --uninstall.
#
#   scripts/install-linux.sh                    # ~/.local
#   sudo scripts/install-linux.sh --prefix /usr/local
#   scripts/install-linux.sh --uninstall
#
# It lays out:
#   PREFIX/lib/macbeeb/          MacBeeb, macbeeb-mcp, beeb, beebasm, baron,
#                                their resource bundles, and share/ (the
#                                guides, credits, release notes, licences)
#   PREFIX/bin/                  macbeeb, macbeeb-mcp, beeb (links)
#   PREFIX/share/applications, icons, mime, metainfo: the desktop's files
set -e
cd "$(dirname "$0")/.."

PREFIX="$HOME/.local"
UNINSTALL=
while [ $# -gt 0 ]; do
    case "$1" in
        --prefix) PREFIX="$2"; shift 2 ;;
        --prefix=*) PREFIX="${1#*=}"; shift ;;
        --uninstall) UNINSTALL=1; shift ;;
        *) echo "usage: $0 [--prefix DIR] [--uninstall]" >&2; exit 2 ;;
    esac
done

APP=com.accidentalfish.MacBeeb
LIB="$PREFIX/lib/macbeeb"
SHARE="$PREFIX/share"

update_caches() {
    command -v update-desktop-database > /dev/null && update-desktop-database -q "$SHARE/applications" || true
    command -v update-mime-database > /dev/null && update-mime-database "$SHARE/mime" > /dev/null || true
    command -v gtk4-update-icon-cache > /dev/null && gtk4-update-icon-cache -q -t -f "$SHARE/icons/hicolor" || true
}

if [ -n "$UNINSTALL" ]; then
    rm -rf "$LIB"
    rm -f "$PREFIX/bin/macbeeb" "$PREFIX/bin/macbeeb-mcp" "$PREFIX/bin/beeb"
    rm -f "$SHARE/applications/$APP.desktop" "$SHARE/metainfo/$APP.metainfo.xml" "$SHARE/mime/packages/$APP.xml"
    rm -f "$SHARE/icons/hicolor/scalable/apps/$APP.svg" "$SHARE/icons/hicolor/symbolic/apps/$APP-symbolic.svg"
    update_caches
    echo "Uninstalled MacBeeb from $PREFIX (your games, settings and networks in ~/.local/share/MacBeeb are kept)"
    exit 0
fi

VERSION="${VERSION:-$(grep -m1 '^## ' WHATSNEW.md | cut -c4- | tr -d ' ')}"

swift build -c release --product MacBeeb
swift build -c release --product macbeeb-mcp
swift build -c release --product beeb
BIN=$(swift build -c release --show-bin-path)
# BeebAsm and Baron, for assembling from VS Code and the agent tools.
make beebasm baron

rm -rf "$LIB"
mkdir -p "$LIB/share" "$PREFIX/bin"
cp "$BIN/MacBeeb" "$BIN/macbeeb-mcp" "$BIN/beeb" "$LIB/"
# The ROMs, discs and sounds, and the library's catalogue and covers.
for target in BeebROMs BeebLibrary; do
    for bundle in "$BIN/macbeeb_$target.bundle" "$BIN/macbeeb_$target.resources"; do
        [ -e "$bundle" ] && cp -R "$bundle" "$LIB/"
    done
done
cp .build/beebasm/beebasm .build/baron/baron "$LIB/"

# The guides (Help), credits and release notes, as the Mac bundles them.
mkdir -p "$LIB/share/guides"
cp -R docs/hardware-expansions "$LIB/share/guides/"
cp docs/network-studio/README.md "$LIB/share/guides/hardware-expansions/network-studio.md"
cp CREDITS.md WHATSNEW.md "$LIB/share/"
cp -R Resources/Linux/icons "$LIB/share/"
cp LICENSE "$LIB/share/LICENSE.txt"
cp ThirdParty/beebasm/COPYING.txt "$LIB/share/BeebAsm-COPYING.txt"
cp ThirdParty/baron/LICENSE "$LIB/share/Baron-LICENSE.txt"
cp ThirdParty/baron/extern/richc/LICENSE "$LIB/share/richc-LICENSE.txt"
echo "$VERSION" > "$LIB/share/version"

ln -sf "$LIB/MacBeeb" "$PREFIX/bin/macbeeb"
ln -sf "$LIB/macbeeb-mcp" "$PREFIX/bin/macbeeb-mcp"
ln -sf "$LIB/beeb" "$PREFIX/bin/beeb"

# The desktop's files: the launcher, icons, file types, app store details.
mkdir -p "$SHARE/applications" "$SHARE/metainfo" "$SHARE/mime/packages" \
    "$SHARE/icons/hicolor/scalable/apps" "$SHARE/icons/hicolor/symbolic/apps"
sed "s|@EXEC@|$LIB/MacBeeb|g" "Resources/Linux/$APP.desktop" > "$SHARE/applications/$APP.desktop"
cp "Resources/Linux/$APP.metainfo.xml" "$SHARE/metainfo/"
cp "Resources/Linux/$APP.xml" "$SHARE/mime/packages/"
cp "Resources/Linux/icons/hicolor/scalable/apps/$APP.svg" "$SHARE/icons/hicolor/scalable/apps/"
cp "Resources/Linux/icons/hicolor/symbolic/apps/$APP-symbolic.svg" "$SHARE/icons/hicolor/symbolic/apps/"
update_caches

echo "Installed MacBeeb $VERSION in $PREFIX: run macbeeb, or find MacBeeb in your applications"
