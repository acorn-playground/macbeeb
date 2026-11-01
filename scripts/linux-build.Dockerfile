# The Ubuntu 26.04 that MacBeeb's Linux packages are built in, with the
# Swift toolchain and what scripts/package-linux.sh needs: the same packages as
# .github/workflows/release-linux.yml sets up. scripts/package-linux-docker.sh
# builds it (once for each processor) and runs the packaging in it.
FROM ubuntu:26.04

ARG SWIFT_VERSION=6.4.1

RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      git curl ca-certificates make gcc g++ libc6-dev pkg-config python3 dpkg-dev xz-utils \
      binutils-gold unzip zip gnupg2 libpython3-dev libncurses-dev libz3-dev \
      libgtk-4-dev libadwaita-1-dev libepoxy-dev libsdl3-dev \
      libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev libcairo2-dev zlib1g-dev \
      libcurl4-openssl-dev libxml2-dev \
 && rm -rf /var/lib/apt/lists/*

# swift.org's toolchain, checked against its signature. (Not swiftly, as the
# workflow uses: under Docker's emulation of Intel on Apple silicon,
# swiftly init stops on an illegal instruction.)
RUN set -e; cd /tmp; \
    case "$(uname -m)" in aarch64) suffix=-aarch64 ;; *) suffix= ;; esac; \
    name="swift-$SWIFT_VERSION-RELEASE-ubuntu26.04$suffix"; \
    url="https://download.swift.org/swift-$SWIFT_VERSION-release/ubuntu2604$suffix/swift-$SWIFT_VERSION-RELEASE/$name.tar.gz"; \
    curl -fsSLO "$url"; curl -fsSLO "$url.sig"; \
    export GNUPGHOME="$(mktemp -d)"; \
    curl -fsSL --compressed https://www.swift.org/keys/all-keys.asc | gpg --batch --quiet --import -; \
    gpg --batch --verify "$name.tar.gz.sig" "$name.tar.gz"; \
    mkdir -p /opt/swift; tar -xzf "$name.tar.gz" -C /opt/swift --strip-components 1; \
    rm -rf "$GNUPGHOME" /tmp/swift-*
ENV PATH=/opt/swift/usr/bin:$PATH
RUN swift --version
