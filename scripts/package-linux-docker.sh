#!/bin/sh
# Packages MacBeeb for Linux in Docker containers (Ubuntu 26.04), for Arm and
# Intel, from the Mac: what scripts/release.sh attaches to a release beside
# the Mac's disk image.
#
#   scripts/package-linux-docker.sh VERSION [ARCH...]   ARCH: arm64, amd64
#
# Builds the committed files (and the submodules'), not the working tree's
# others, with scripts/package-linux.sh, into .build/releases/VERSION/linux.
# Arm's builds in this Mac's Docker. Intel's builds in the Docker of an
# Intel Linux computer over ssh, LINUX_INTEL_HOST (by default linuxdev, as
# ssh knows it): Docker's emulation of Intel here, Rosetta, can't run
# Ubuntu 26.04. LINUX_ARM_HOST, likewise, builds Arm's elsewhere. They
# build at once, each logging with its processor's name.
#
# The image, scripts/linux-build.Dockerfile, is built the first time on each
# computer, and SwiftPM's downloads are kept in a volume between runs.
set -e
cd "$(dirname "$0")/.."

VERSION=$1
[ -n "$VERSION" ] || { echo "usage: scripts/package-linux-docker.sh VERSION [arm64|amd64...]" >&2; exit 2; }
shift
ARCHS=${*:-arm64 amd64}
INTEL_HOST=${LINUX_INTEL_HOST-linuxdev}
ARM_HOST=${LINUX_ARM_HOST-}

OUT=.build/releases/$VERSION/linux
rm -rf "$OUT"
mkdir -p "$OUT"

# Builds and packages for $1 in the Docker at $2 (or this Mac's), and
# unpacks what it makes into $OUT.
package() {
    arch=$1
    if [ -n "$2" ]; then DOCKER_HOST=ssh://$2; export DOCKER_HOST; fi
    where=${2:-this Mac}
    docker info >/dev/null 2>&1 || { echo "Docker isn't running on $where"; return 1; }
    IMAGE=macbeeb-linux-build:$arch
    echo "the build image, on $where..."
    docker build --quiet --platform "linux/$arch" -t "$IMAGE" - < scripts/linux-build.Dockerfile || return 1

    echo "packaging, on $where..."
    # (The files go in on standard input, so the Mac's .build stays out of
    # it, and the packages come out on standard output, the build's
    # messages on standard error.)
    git ls-files -z --recurse-submodules | COPYFILE_DISABLE=1 tar --null -T - -cf - |
        docker run --rm -i --platform "linux/$arch" \
            --label macbeeb-linux-build \
            -v "macbeeb-swiftpm-$arch:/root/.cache" \
            -e VERSION="$VERSION" \
            "$IMAGE" sh -c '
                set -e
                mkdir /work && cd /work
                tar -xf - --no-same-owner
                scripts/package-linux.sh "$VERSION" >&2
                tar -C .build/releases/"$VERSION"/linux -cf - .' |
        tar -C "$OUT" -xf - || return 1
    # (The pipeline's status is the last tar's, so: did the .deb come out?)
    [ -f "$OUT/macbeeb_${VERSION}_$arch.deb" ] || { echo "no .deb came out"; return 1; }
    echo "done"
}

PIDS=
for arch in $ARCHS; do
    case "$arch" in
        arm64) host=$ARM_HOST ;;
        amd64) host=$INTEL_HOST ;;
        *) echo "package-linux-docker: no processor $arch (arm64 or amd64)" >&2; exit 2 ;;
    esac
    (
        # (Its status kept apart, as the pipeline's is sed's.)
        { if package "$arch" "$host" 2>&1; then status=0; else status=1; fi
          echo "$status" > "$OUT/.$arch.status"; } |
            sed -u "s/^/[$arch] /"
    ) &
    PIDS="$PIDS $!"
done
# shellcheck disable=SC2086
wait $PIDS

FAILED=
for arch in $ARCHS; do
    [ "$(cat "$OUT/.$arch.status" 2>/dev/null)" = 0 ] || FAILED="$FAILED $arch"
    rm -f "$OUT/.$arch.status"
done
if [ -n "$FAILED" ]; then
    echo "package-linux-docker: the packages for$FAILED didn't build" >&2
    exit 1
fi
ls -l "$OUT"
echo "Built $OUT"
