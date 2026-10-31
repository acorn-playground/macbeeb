#!/bin/sh
# Packages MacBeeb for Linux, for a release: what the Linux release workflow
# (.github/workflows/release-linux.yml) attaches to the GitHub release,
# beside the Mac's disk image.
#
#   scripts/package-linux.sh VERSION
#
# Produces, in .build/releases/VERSION/linux, for this computer's processor:
#   MacBeeb-VERSION-linux-ARCH.tar.xz   to unpack anywhere, then ./install.sh
#   macbeeb_VERSION_DEBARCH.deb         for Ubuntu and Debian: sudo apt install ./…
#
# Swift's own libraries are linked in, so neither needs Swift. GTK 4,
# libadwaita, SDL 3 and GStreamer are the system's: the .deb depends on the
# versions it was built against (Ubuntu 26.04's), so apt installs them, and
# recommends GStreamer's encoders, for recordings. Needs dpkg-dev and
# xz-utils besides what MacBeeb builds with (scripts/linux-deps.sh).
set -e
cd "$(dirname "$0")/.."

VERSION=$1
[ -n "$VERSION" ] || { echo "usage: scripts/package-linux.sh VERSION" >&2; exit 2; }
case "$VERSION" in
    [0-9]*) ;;
    *) echo "package-linux: the version is a number, such as 1.6 (not $VERSION)" >&2; exit 2 ;;
esac

ARCH=$(uname -m)
DEB_ARCH=$(dpkg --print-architecture)
NAME=MacBeeb-$VERSION-linux-$ARCH
OUT=.build/releases/$VERSION/linux
WORK=.build/linux/package
rm -rf "$OUT" "$WORK"
mkdir -p "$OUT" "$WORK"

VERSION=$VERSION scripts/install-linux.sh --stage "$WORK/$NAME"
STAGE=$WORK/$NAME
# (Writable by their owner only, whatever the umask.)
chmod -R go-w "$STAGE"

# Nothing of Swift's should be left for the system to find, and the
# system's own libraries should all be there.
for program in MacBeeb macbeeb-mcp beeb beebasm baron; do
    if ldd "$STAGE/lib/macbeeb/$program" | grep -E 'libswift|libFoundation|lib_Foundation|libdispatch|libBlocksRuntime|not found'; then
        echo "package-linux: $program links libraries a user won't have" >&2
        exit 1
    fi
done

echo "Making the archive..."
tar -C "$WORK" --owner=0 --group=0 -cJf "$OUT/$NAME.tar.xz" "$NAME"

echo "Making the .deb..."
# (Its files where a Debian source package would have them, for
# dpkg-shlibdeps: in debian/macbeeb, beside a debian/control.)
ROOT=$WORK/debian/macbeeb
"$STAGE/install.sh" --prefix /usr --destdir "$ROOT"
mkdir -p "$ROOT/DEBIAN"
chmod -R go-w "$ROOT"
printf 'Source: macbeeb\n\nPackage: macbeeb\nArchitecture: any\n' > "$WORK/debian/control"
# Its dependencies, from the libraries the programs link, as Debian's own
# packages work them out. (It warns of libraries linked but unused: GTK's
# pkg-config names them all.)
DEPENDS=$(cd "$WORK" && dpkg-shlibdeps -O --warnings=0 \
    debian/macbeeb/usr/lib/macbeeb/MacBeeb debian/macbeeb/usr/lib/macbeeb/macbeeb-mcp \
    debian/macbeeb/usr/lib/macbeeb/beeb debian/macbeeb/usr/lib/macbeeb/beebasm \
    debian/macbeeb/usr/lib/macbeeb/baron | sed -n 's/^shlibs:Depends=//p')
[ -n "$DEPENDS" ] || { echo "package-linux: dpkg-shlibdeps found no dependencies" >&2; exit 1; }

cat > "$ROOT/DEBIAN/control" <<EOF
Package: macbeeb
Version: $VERSION
Architecture: $DEB_ARCH
Maintainer: James Randall <james@accidentalfish.com>
Installed-Size: $(du -sk "$ROOT/usr" | cut -f1)
Depends: $DEPENDS
Recommends: gstreamer1.0-plugins-good, gstreamer1.0-plugins-bad, gstreamer1.0-plugins-ugly, gstreamer1.0-libav
Section: otherosfs
Priority: optional
Homepage: https://github.com/acorn-playground/macbeeb
Description: cycle-exact BBC Micro emulator
 MacBeeb emulates the BBC Micro cycle by cycle: the Model A and B, the B+,
 the Master 128 and Master Compact, with the 6502, Z80, 80186 and ARM
 second processors, discs and tapes, sound and joysticks. It has a game
 library, Econet networks of BBC Micros, a debugger for machine code and
 BBC BASIC, and an MCP server for AI agents (macbeeb-mcp).
EOF
DEB="$OUT/macbeeb_${VERSION}_$DEB_ARCH.deb"
dpkg-deb --root-owner-group -Zxz --build "$ROOT" "$DEB"

ls -l "$OUT"
echo "Built $OUT"
