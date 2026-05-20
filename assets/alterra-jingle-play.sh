#!/bin/bash
# Boot-jingle player. Invoked by Ly's BootJingle widget at greeter
# init when the user didn't hold a shift to silence.
#
# Dual-mode audio (the hard-won lesson — 2026-05-20):
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

set -u

USER_UID=1000
USER_NAME=mikolaj
JINGLE=/usr/local/share/alterra/jingle.mp3

if [ ! -r "$JINGLE" ]; then
    exit 0
fi

if [ -S "/run/user/$USER_UID/pipewire-0" ] || \
   [ -S "/run/user/$USER_UID/pulse/native" ]; then
    # User pipewire/pulse socket exists — route through it as the
    # owning user so audio mixes with their session output. mpv
    # auto-selects pulse/pipewire AO when XDG_RUNTIME_DIR points at
    # a live runtime dir.
    nohup runuser -u "$USER_NAME" -- env \
        "XDG_RUNTIME_DIR=/run/user/$USER_UID" \
        mpv --no-config --no-video --really-quiet "$JINGLE" \
        </dev/null >/dev/null 2>&1 &
else
    # No user session live — must be greeter time (real boot). Raw
    # ALSA default device is the hardware itself.
    nohup mpv --no-config --no-video --audio-device=alsa --really-quiet "$JINGLE" \
        </dev/null >/dev/null 2>&1 &
fi
disown
exit 0
