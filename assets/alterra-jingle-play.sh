#!/bin/bash
# Boot-jingle player. Invoked by Ly's BootJingle widget at greeter
# init when the user didn't hold a shift to silence.
#
# Dual-mode audio:
#   * REAL BOOT: ly-dm runs as root; pipewire/wireplumber haven't
#     started for any user yet. raw ALSA default device IS the
#     hardware. mpv --audio-device=alsa works.
#   * TEST (tty3 harness): ly-dm runs as root inside kmscon while
#     sway+pipewire are LIVE on tty1 owned by uid 1000. Pipewire
#     holds ALSA exclusive → mpv as root sees EBUSY ("Host is down"
#     in ALSA error vocabulary). We detect the user pipewire socket
#     and route mpv through it as the user, sharing the same audio
#     stack their session uses.
#
# Daemonisation: nohup+disown so the parent (ly-dm) reaps the bash
# exit immediately and mpv lives on, reparented to init.
#
# DIAGNOSTIC LOG: every invocation appends to /var/log/alterra-jingle.log
# with a timestamp + which path was taken + mpv's full stdout/stderr.
# Helpful when audio fails silently at real boot (where output is
# otherwise lost to /dev/null).

set -u

LOG=/var/log/alterra-jingle.log
USER_UID=1000
USER_NAME=mikolaj
JINGLE=/usr/local/share/alterra/jingle.mp3

ts() { date +"%Y-%m-%dT%H:%M:%S.%3N"; }

echo "$(ts) [launcher] invoked ppid=$PPID euid=$EUID tty=$(tty 2>/dev/null || echo none)" >> "$LOG"

if [ ! -r "$JINGLE" ]; then
    echo "$(ts) [launcher] FATAL: jingle file missing or unreadable: $JINGLE" >> "$LOG"
    exit 0
fi

if [ -S "/run/user/$USER_UID/pipewire-0" ] || \
   [ -S "/run/user/$USER_UID/pulse/native" ]; then
    echo "$(ts) [launcher] path=user-session (runuser pipewire/pulse)" >> "$LOG"
    nohup runuser -u "$USER_NAME" -- env \
        "XDG_RUNTIME_DIR=/run/user/$USER_UID" \
        mpv --no-config --no-video "$JINGLE" \
        </dev/null >> "$LOG" 2>&1 &
else
    echo "$(ts) [launcher] path=raw-alsa (no user session detected)" >> "$LOG"
    nohup mpv --no-config --no-video --audio-device=alsa "$JINGLE" \
        </dev/null >> "$LOG" 2>&1 &
fi
disown

echo "$(ts) [launcher] exit 0" >> "$LOG"
exit 0
