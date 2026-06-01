#!/bin/bash
# /usr/local/bin/ly-via-kmscon — auth-only loop, kmscon-detached.
#
# When ly@tty1.service is restarted while the user is in sway, the
# user's logind session lives in a separate cgroup (user@$UID.service)
# and survives. That orphan sway keeps DRM master on the iGPU. The
# next kmscon launch then falls back to 80×24 (no DRM master → soft
# fallback) and any new runuser→sway dies with EBUSY on the GPU.
#
# Adaptive recovery: at wrapper startup, AND before each runuser
# invocation, terminate any existing graphical session for the
# target user via loginctl, wait briefly, then proceed. Idempotent;
# if no orphan exists, it's a fast no-op.
#
# See project_kmscon_libseat_drm_busy_2026_05_17 and
# project_ly_kmscon_adaptive_recovery_2026_05_17 for the broader
# architecture.

set -u

TTY_NAME="${1:-tty1}"
VT_NUM="${TTY_NAME#tty}"
STATE_DIR="/run/ly"
STATE_FILE="${STATE_DIR}/state-${TTY_NAME}"

mkdir -p "$STATE_DIR"
chmod 0700 "$STATE_DIR"

# Pre-flight (Layer 2 of adaptive recovery).
if ! /usr/local/bin/ly-dm --help 2>&1 | grep -q -- '--auth-only'; then
    echo "ly-via-kmscon: ly-dm lacks --auth-only support; falling back to vanilla ly-dm" >&2
    exec /usr/local/bin/ly-dm
fi
if ! [ -x /usr/bin/kmscon ]; then
    echo "ly-via-kmscon: /usr/bin/kmscon missing; falling back to vanilla ly-dm" >&2
    exec /usr/local/bin/ly-dm
fi

# Adaptive cleanup helper. Terminates any active graphical session
# for $1 (target username) so subsequent DRM master grabs can
# succeed. Returns 0 always; logs to journal on best-effort basis.
cleanup_orphan_sessions() {
    local target_user="$1"
    [ -z "$target_user" ] && return 0

    # Any active session belonging to target_user? loginctl
    # tab-separated columns: SESSION UID USER SEAT TTY ...
    local sessions
    sessions=$(loginctl --no-legend list-sessions 2>/dev/null \
        | awk -v u="$target_user" '$3==u {print $1}')
    [ -z "$sessions" ] && return 0

    echo "ly-via-kmscon: terminating orphan session(s) for $target_user: $sessions" >&2
    for s in $sessions; do
        loginctl terminate-session "$s" 2>/dev/null || true
    done

    # Wait up to 3s for sway/wayland processes to actually die so
    # DRM master is released before our caller tries to acquire.
    local n
    for n in 1 2 3 4 5 6; do
        sleep 0.5
        if ! pgrep -u "$target_user" -x sway >/dev/null 2>&1; then
            return 0
        fi
    done

    # Still alive after 3s — fall back to SIGKILL.
    echo "ly-via-kmscon: orphan sway didn't exit cleanly, SIGKILL" >&2
    pkill -9 -u "$target_user" -x sway 2>/dev/null || true
    pkill -9 -u "$target_user" -x swaybg 2>/dev/null || true
    sleep 0.5
    return 0
}

# Discover the default user (the one most recently logged in, or
# the user whose ~/.local/state/ly-session.log exists). Used for
# the startup cleanup pass before we know which user will auth.
default_user=$(loginctl --no-legend list-users 2>/dev/null | awk '$2!="root" {print $2; exit}')
[ -n "$default_user" ] && cleanup_orphan_sessions "$default_user"

while :; do
    rm -f "$STATE_FILE"

    /usr/bin/kmscon \
        --vt="$VT_NUM" \
        --seats=seat0 \
        --gpus=all \
        --no-switchvt \
        --login \
        -- /bin/sh -c "exec /usr/local/bin/ly-dm --take-tty=$VT_NUM --auth-only --state=$STATE_FILE" &
    KMSCON_PID=$!

    while kill -0 "$KMSCON_PID" 2>/dev/null; do
        if [ -s "$STATE_FILE" ]; then
            kill -TERM "$KMSCON_PID" 2>/dev/null || true
            # Reap any ly-dm grandchildren that ignored kmscon's
            # death — they would busy-loop on a deleted pty fd.
            pkill -9 -P 1 -f '^/usr/local/bin/ly-dm ' 2>/dev/null || true
            break
        fi
        sleep 0.1
    done

    wait "$KMSCON_PID" 2>/dev/null || true

    if ! [ -s "$STATE_FILE" ]; then
        sleep 0.5
        continue
    fi

    # shellcheck disable=SC1090
    . "$STATE_FILE"
    rm -f "$STATE_FILE"

    # Keyring-unlock diagnostic trace. ly-dm --auth-only has run PAM
    # (auth + open_session) for /etc/pam.d/ly; pam_gnome_keyring should
    # have delivered the password to gnome-keyring-daemon by now. This
    # trace records the post-auth daemon state so we can see whether
    # credential delivery worked. Query with:
    #   journalctl -t ly-via-kmscon -t pam_gnome_keyring -b
    {
        echo "keyring-trace user=$LY_USER session=$LY_SESSION_CMD"
        RUNTIME="/run/user/$(id -u "$LY_USER")"
        if [ -S "$RUNTIME/keyring/control" ]; then
            echo "control socket present at $RUNTIME/keyring/control"
        else
            echo "control socket MISSING (daemon not running)"
        fi
        if command -v busctl >/dev/null 2>&1; then
            for coll in login Default_5fkeyring; do
                locked=$(runuser -u "$LY_USER" -- env XDG_RUNTIME_DIR="$RUNTIME" \
                    busctl --user --quiet call \
                    org.freedesktop.secrets \
                    "/org/freedesktop/secrets/collection/$coll" \
                    org.freedesktop.DBus.Properties Get ss \
                    org.freedesktop.Secret.Collection Locked 2>&1 \
                    | tr -d '\n')
                echo "collection $coll Locked=$locked"
            done
        fi
    } | systemd-cat -t ly-via-kmscon -p info

    sleep 0.3

    # Adaptive: in case ly@tty1 was restarted while the user was
    # logged in, terminate the orphaned session for this user before
    # starting a new one. Without this, libseat-logind returns EBUSY
    # on /dev/dri/by-name/igpu-card and the new sway exits instantly.
    cleanup_orphan_sessions "$LY_USER"

    export XDG_VTNR="$VT_NUM"
    export XDG_SEAT=seat0
    export XDG_SESSION_TYPE="${LY_SESSION_TYPE:-wayland}"
    export XDG_SESSION_CLASS=user
    export XDG_SESSION_DESKTOP="${LY_SESSION_DESK:-sway}"

    LY_HOME="$(getent passwd "$LY_USER" | cut -d: -f6)"
    if [ -n "$LY_HOME" ] && [ -d "$LY_HOME" ]; then
        cd "$LY_HOME" || true
    fi

    runuser \
        --whitelist-environment=XDG_VTNR,XDG_SEAT,XDG_SESSION_TYPE,XDG_SESSION_CLASS,XDG_SESSION_DESKTOP \
        -u "$LY_USER" \
        -- "$LY_SHELL" -c "$LY_SESSION_CMD"

    sleep 0.5
done
