#!/bin/bash
# Boot-jingle player. Invoked by Ly's BootJingle widget at greeter
# init when the user didn't hold a shift to silence.
#
# Dual-mode audio:
#   * REAL BOOT: ly-dm runs as root; pipewire/wireplumber haven't
#     started for any user yet. The ALSA "default" PCM is configured
#     on this machine to route through the pipewire shim, so opening
#     "default" without pipewire running fails with "Host is down"
#     (proven via /var/log/alterra-jingle.log on the 2026-05-21
#     boot). Bypass with the hardware-direct sysdefault PCM, which
#     speaks straight to the codec without the shim.
#   * TEST (tty3 harness): ly-dm runs as root inside kmscon while
#     sway+pipewire are LIVE on tty1 owned by uid 1000. Pipewire
#     holds ALSA exclusive. We detect the user pipewire socket and
#     route mpv through it as the user, sharing the same audio
#     stack their session uses.
#
# Daemonisation: nohup+disown so the parent (ly-dm) reaps the bash
# exit immediately and mpv lives on, reparented to init.
#
# DIAGNOSTIC LOG: every invocation appends to /var/log/alterra-jingle.log
# with a timestamp + which path was taken + mpv's full stdout/stderr.

set -u

LOG=/var/log/alterra-jingle.log
USER_UID=1000
USER_NAME=mikolaj
JINGLE=/usr/local/share/alterra/jingle.mp3

# Hardware-direct ALSA device. `aplay -L` on this machine reports
# this as the only sysdefault entry. Bypasses the pipewire-alsa
# shim that "default" routes through, so opening it succeeds even
# when no audio server is running.
ALSA_HW_DEVICE="alsa/sysdefault:CARD=Generic_1"

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
    echo "$(ts) [launcher] path=raw-alsa device=$ALSA_HW_DEVICE" >> "$LOG"
    nohup mpv --no-config --no-video --audio-device="$ALSA_HW_DEVICE" "$JINGLE" \
        </dev/null >> "$LOG" 2>&1 &
fi
disown

echo "$(ts) [launcher] exit 0" >> "$LOG"
exit 0
