#!/bin/sh
# A private, headless GNOME Shell for running MacBeeb's Linux app where no
# one sees it (self-tests, window captures, CI): its own D-Bus session and
# a virtual monitor. Prints the environment to run the app against it,
# then runs until killed.
#
#   scripts/linux-headless.sh NAME &      # NAME: a Wayland display name
#   eval "$(scripts/linux-headless.sh --env NAME)"
#   .build/debug/MacBeeb -MacBeebSelfTest /tmp/out.png -MacBeebSelfTestOpen app.library
set -e
if [ "$1" = "--env" ]; then
    name=${2:-macbeeb-headless}
    state=${XDG_RUNTIME_DIR:-/tmp}/$name.bus
    # (Waits for the shell to have started.)
    for _ in $(seq 1 50); do [ -s "$state" ] && break; sleep 0.2; done
    echo "export WAYLAND_DISPLAY=$name GDK_BACKEND=wayland DBUS_SESSION_BUS_ADDRESS='$(cat "$state")'"
    exit 0
fi
name=${1:-macbeeb-headless}
size=${2:-1440x960}
state=${XDG_RUNTIME_DIR:-/tmp}/$name.bus
rm -f "$state"
exec dbus-run-session -- sh -c 'echo "$DBUS_SESSION_BUS_ADDRESS" > "$1"; exec gnome-shell --headless --virtual-monitor "$2" --wayland-display "$3" --no-x11' sh "$state" "$size" "$name"
