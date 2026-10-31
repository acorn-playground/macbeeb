#!/bin/sh
# The packages MacBeeb's Linux app builds against (Ubuntu 26.04 and Debian),
# and those it uses at run time: GStreamer's encoders for recordings, and
# Poppler's tools for the printout tests. Swift itself comes from swift.org
# (swiftly).
set -e
sudo apt-get install -y \
    libgtk-4-dev libadwaita-1-dev libepoxy-dev libsdl3-dev \
    libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev libcairo2-dev zlib1g-dev \
    gstreamer1.0-plugins-good gstreamer1.0-plugins-bad gstreamer1.0-plugins-ugly gstreamer1.0-libav \
    poppler-utils
