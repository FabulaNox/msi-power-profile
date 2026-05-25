#!/bin/bash
# power-profile-request: drop a "next" cycle request for power-profile-monitor.
#
# Two callers:
#   1. XFCE keyboard shortcut (recommended, reliable)
#   2. xfce4-genmon <click> XML tag (works on older genmon; flaky on 4.3.0+ for
#      silent scripts because the spawn handler treats fast non-GUI exits as
#      "did not fire". The setsid + notify-send wrapping below makes the spawn
#      look "visible enough" to satisfy genmon's heuristic in most cases.)

set -u

REQUEST_FILE=/run/power-profile/request

# setsid -f fully detaches us from the caller's process group/session, which
# both fixes the genmon-4.3.0 silent-fail and prevents the caller from being
# blocked if anything in this script slows down (notify-send DBUS hiccup, etc).
if [ -z "${POWER_PROFILE_REQUEST_DETACHED:-}" ]; then
    export POWER_PROFILE_REQUEST_DETACHED=1
    exec setsid -f "$0" "$@"
fi

logger -t power-profile-request "click fired uid=$(id -u)"
echo next > "$REQUEST_FILE"

# Brief visible feedback - also serves as the "visible effect" cue that
# xfce4-genmon 4.3.0 looks for before considering the click handled. Failing
# this (no DBUS, no notification daemon) is fine; the file write is the real
# action.
notify-send -t 800 -a "Power profile" "Cycling profile..." 2>/dev/null || true
