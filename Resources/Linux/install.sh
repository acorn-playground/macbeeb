#!/bin/sh
# Installs MacBeeb for Linux from the folder this script is in (a release's
# .tar.xz, unpacked, or what scripts/install-linux.sh has built): for you
# alone in ~/.local (the default), or with --prefix for everyone (sudo,
# /usr/local). Uninstalls with --uninstall (and the same --prefix).
#
#   ./install.sh                         # ~/.local
#   sudo ./install.sh --prefix /usr/local
#   ./install.sh --uninstall
#
# It lays out:
#   PREFIX/lib/macbeeb/          MacBeeb, macbeeb-mcp, beeb, beebasm, baron,
#                                their resource bundles, and share/ (the
#                                guides, credits, release notes, licences)
#   PREFIX/bin/                  macbeeb, macbeeb-mcp, beeb (links)
#   PREFIX/share/applications, icons, mime, metainfo: the desktop's files
#
# --destdir DIR puts them in DIR as though it were / (a package's files: the
# .deb, by scripts/package-linux.sh), leaving the desktop's caches to the
# package manager.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)

PREFIX="$HOME/.local"
DESTDIR=
UNINSTALL=
while [ $# -gt 0 ]; do
    case "$1" in
        --prefix) PREFIX="$2"; shift 2 ;;
        --prefix=*) PREFIX="${1#*=}"; shift ;;
        --destdir) DESTDIR="$2"; shift 2 ;;
        --destdir=*) DESTDIR="${1#*=}"; shift ;;
        --uninstall) UNINSTALL=1; shift ;;
        *) echo "usage: $0 [--prefix DIR] [--uninstall]" >&2; exit 2 ;;
    esac
done
case "$PREFIX" in
    /*) ;;
    *) echo "install: the prefix must be a full path (not $PREFIX)" >&2; exit 2 ;;
esac

APP=com.accidentalfish.MacBeeb
LIB="$PREFIX/lib/macbeeb"
SHARE="$PREFIX/share"

update_caches() {
    [ -z "$DESTDIR" ] || return 0
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

[ -x "$HERE/lib/macbeeb/MacBeeb" ] || { echo "install: MacBeeb isn't beside this script (in $HERE/lib/macbeeb)" >&2; exit 1; }

rm -rf "$DESTDIR$LIB"
mkdir -p "$DESTDIR$PREFIX/lib" "$DESTDIR$PREFIX/bin"
cp -R "$HERE/lib/macbeeb" "$DESTDIR$PREFIX/lib/"
ln -sf "$LIB/MacBeeb" "$DESTDIR$PREFIX/bin/macbeeb"
ln -sf "$LIB/macbeeb-mcp" "$DESTDIR$PREFIX/bin/macbeeb-mcp"
ln -sf "$LIB/beeb" "$DESTDIR$PREFIX/bin/beeb"

# The desktop's files: the launcher, icons, file types, app store details.
mkdir -p "$DESTDIR$SHARE/applications" "$DESTDIR$SHARE/metainfo" "$DESTDIR$SHARE/mime/packages" \
    "$DESTDIR$SHARE/icons/hicolor/scalable/apps" "$DESTDIR$SHARE/icons/hicolor/symbolic/apps"
sed "s|@EXEC@|$LIB/MacBeeb|g" "$HERE/share/applications/$APP.desktop" > "$DESTDIR$SHARE/applications/$APP.desktop"
cp "$HERE/share/metainfo/$APP.metainfo.xml" "$DESTDIR$SHARE/metainfo/"
cp "$HERE/share/mime/packages/$APP.xml" "$DESTDIR$SHARE/mime/packages/"
cp "$HERE/share/icons/hicolor/scalable/apps/$APP.svg" "$DESTDIR$SHARE/icons/hicolor/scalable/apps/"
cp "$HERE/share/icons/hicolor/symbolic/apps/$APP-symbolic.svg" "$DESTDIR$SHARE/icons/hicolor/symbolic/apps/"
update_caches

echo "Installed MacBeeb $(cat "$HERE/lib/macbeeb/share/version") in $DESTDIR$PREFIX: run macbeeb, or find MacBeeb in your applications"
