#!/bin/sh
# Builds MacBeeb for Linux and installs it: for you alone in ~/.local (the
# default), or with --prefix for everyone (sudo, /usr/local). Uninstalls
# with --uninstall.
#
#   scripts/install-linux.sh                    # ~/.local
#   sudo scripts/install-linux.sh --prefix /usr/local
#   scripts/install-linux.sh --uninstall
#   scripts/install-linux.sh --stage DIR        # builds it into DIR only
#
# It builds optimised, with Swift's own libraries linked in (so it runs
# without Swift, and a toolchain changing later doesn't break it), lays the
# files out in .build/linux/stage as a release's .tar.xz has them, then
# installs them with Resources/Linux/install.sh (which says where they go).
# --stage lays them out in DIR and stops there (scripts/package-linux.sh).
set -e
CALLER=$(pwd)
cd "$(dirname "$0")/.."

PREFIX=
STAGE=
UNINSTALL=
while [ $# -gt 0 ]; do
    case "$1" in
        --prefix) PREFIX="$2"; shift 2 ;;
        --prefix=*) PREFIX="${1#*=}"; shift ;;
        --uninstall) UNINSTALL=1; shift ;;
        --stage) STAGE="$2"; shift 2 ;;
        --stage=*) STAGE="${1#*=}"; shift ;;
        *) echo "usage: $0 [--prefix DIR] [--uninstall] [--stage DIR]" >&2; exit 2 ;;
    esac
done

# Runs the installer, with the prefix if one was given.
installer() {
    if [ -n "$PREFIX" ]; then "$@" --prefix "$PREFIX"; else "$@"; fi
}

if [ -n "$UNINSTALL" ]; then
    installer Resources/Linux/install.sh --uninstall
    exit
fi

INSTALL=
if [ -z "$STAGE" ]; then
    STAGE=.build/linux/stage
    INSTALL=1
else
    case "$STAGE" in /*) ;; *) STAGE="$CALLER/$STAGE" ;; esac
    # (It's emptied first: only if it's empty already, or an earlier stage.)
    if [ -d "$STAGE" ] && [ ! -f "$STAGE/install.sh" ] && [ -n "$(ls -A "$STAGE")" ]; then
        echo "install-linux: $STAGE isn't empty" >&2
        exit 1
    fi
fi

VERSION="${VERSION:-$(grep -m1 '^## ' WHATSNEW.md | cut -c4- | tr -d ' ')}"

for product in MacBeeb macbeeb-mcp beeb; do
    swift build -c release --static-swift-stdlib --product "$product"
done
BIN=$(swift build -c release --static-swift-stdlib --show-bin-path)
# BeebAsm and Baron, for assembling from VS Code and the agent tools.
make beebasm baron

LIB="$STAGE/lib/macbeeb"
rm -rf "$STAGE"
mkdir -p "$LIB/share"
cp Resources/Linux/install.sh "$STAGE/"
cp "$BIN/MacBeeb" "$BIN/macbeeb-mcp" "$BIN/beeb" "$LIB/"
# The ROMs, discs and sounds, and the library's catalogue and covers.
for target in BeebROMs BeebLibrary; do
    for bundle in "$BIN/macbeeb_$target.bundle" "$BIN/macbeeb_$target.resources"; do
        [ -e "$bundle" ] && cp -R "$bundle" "$LIB/"
    done
done
cp .build/beebasm/beebasm .build/baron/baron "$LIB/"
# (Without their symbols and debugging information, a third of their size.)
strip "$LIB/MacBeeb" "$LIB/macbeeb-mcp" "$LIB/beeb" "$LIB/beebasm" "$LIB/baron"

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

# The desktop's files (the launcher's @EXEC@ is filled in as it's installed).
APP=com.accidentalfish.MacBeeb
mkdir -p "$STAGE/share/applications" "$STAGE/share/metainfo" "$STAGE/share/mime/packages" \
    "$STAGE/share/icons/hicolor/scalable/apps" "$STAGE/share/icons/hicolor/symbolic/apps"
cp "Resources/Linux/$APP.desktop" "$STAGE/share/applications/"
cp "Resources/Linux/$APP.metainfo.xml" "$STAGE/share/metainfo/"
cp "Resources/Linux/$APP.xml" "$STAGE/share/mime/packages/"
cp "Resources/Linux/icons/hicolor/scalable/apps/$APP.svg" "$STAGE/share/icons/hicolor/scalable/apps/"
cp "Resources/Linux/icons/hicolor/symbolic/apps/$APP-symbolic.svg" "$STAGE/share/icons/hicolor/symbolic/apps/"

if [ -n "$INSTALL" ]; then
    installer "$STAGE/install.sh"
else
    echo "Built MacBeeb $VERSION in $STAGE"
fi
