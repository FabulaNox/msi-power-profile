#!/bin/bash
# Power profile monitor for MSI Thin 15 B12UCX
# Handles: AC transitions, low battery, Ultra thermal watchdog
# Install: /usr/local/bin/power-profile-monitor (root:root, 0755)
# Runs as: root, via power-profile-monitor.service

set -u

# Tunables: sourced from /etc/msi-power-profile.conf if present. Fallback
# defaults below match the MSI Thin 15 B12UCX. See the config file for the
# documented knobs.
# shellcheck disable=SC1091
[ -r /etc/msi-power-profile.conf ] && . /etc/msi-power-profile.conf

: "${LOW_BAT_THRESHOLD:=15}"
: "${PERFORMANCE_BAT_THRESHOLD:=60}"
: "${THERMAL_TRIP:=85}"
: "${THERMAL_READINGS:=3}"

STATE_DIR=/run/power-profile
LOW_BAT_OVERRIDE_FILE=$STATE_DIR/low-bat-override
LOG_TAG=power-profile-monitor
PROFILE_CMD=/usr/local/bin/power-profile

heat_count=0
last_ac=""

mkdir -p "$STATE_DIR"
chmod 1777 "$STATE_DIR"

REQUEST_FILE=$STATE_DIR/request

notify_users() {
    local title=$1 body=$2 icon=$3
    local seen=""
    local sid uid user
    while read -r sid uid user _rest; do
        [ -z "${user:-}" ] && continue
        [ ! -d "/run/user/${uid}" ] && continue
        case " $seen " in *" $uid "*) continue ;; esac
        seen="$seen $uid"

        local stype display_arg=""
        stype=$(loginctl show-session "$sid" -p Type --value 2>/dev/null || echo "")
        case "$stype" in
            wayland)
                local wsock
                wsock=$(find "/run/user/${uid}" -maxdepth 1 -name 'wayland-*' \
                    -not -name '*.lock' 2>/dev/null | head -n1)
                [ -n "$wsock" ] && display_arg="WAYLAND_DISPLAY=$(basename "$wsock")"
                ;;
            x11|*)
                display_arg="DISPLAY=${DISPLAY:-:0}"
                ;;
        esac

        # shellcheck disable=SC2086  # display_arg is intentionally word-split
        sudo -u "$user" env $display_arg \
            DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${uid}/bus" \
            notify-send -i "$icon" -a "Power Profile" -u normal -t 6000 \
                "$title" "$body" >/dev/null 2>&1 || true
    done < <(loginctl list-sessions --no-legend)
}

current_profile() {
    cat "$STATE_DIR/state" 2>/dev/null || echo "performance"
}

# ---------- initial setup on service start ----------

init_profile() {
    local bat
    bat=$(cat /sys/class/power_supply/BAT1/capacity 2>/dev/null || echo 100)
    if [ "$bat" -lt "$LOW_BAT_THRESHOLD" ]; then
        "$PROFILE_CMD" eco
        logger -t "$LOG_TAG" "init: low battery (${bat}%) -> eco"
    else
        "$PROFILE_CMD" performance
        logger -t "$LOG_TAG" "init: boot -> performance"
    fi
    last_ac=$(cat /sys/class/power_supply/ADP1/online 2>/dev/null || echo "1")
}

# ---------- main loop ----------

init_profile

while true; do
    # --- manual request from genmon click (checked first, no sleep delay) ---
    if [ -f "$REQUEST_FILE" ]; then
        req=$(cat "$REQUEST_FILE" 2>/dev/null || true)
        rm -f "$REQUEST_FILE"
        if [ -n "$req" ]; then
            # shellcheck disable=SC2086  # $req may be "next --force" or just a
            # profile name; word-splitting is intentional so both forms work.
            "$PROFILE_CMD" $req
            logger -t "$LOG_TAG" "manual request: $req"
        fi
    fi

    ac=$(cat /sys/class/power_supply/ADP1/online 2>/dev/null || echo "1")
    bat=$(cat /sys/class/power_supply/BAT1/capacity 2>/dev/null || echo 100)
    profile=$(current_profile)
    cpu_temp=$(cat /sys/devices/platform/msi-ec/cpu/realtime_temperature 2>/dev/null || echo 0)

    # --- AC state change ---
    if [ "$ac" != "$last_ac" ]; then
        if [ "$ac" = "1" ]; then
            "$PROFILE_CMD" ultra
            notify_users "Plugged in - Ultra" \
                "Switched to Ultra profile (turbo + advanced fan)" \
                "ac-adapter"
            logger -t "$LOG_TAG" "AC connected -> ultra"
            heat_count=0
        else
            if [ "$bat" -ge "$PERFORMANCE_BAT_THRESHOLD" ]; then
                "$PROFILE_CMD" performance
                notify_users "On battery - Performance" \
                    "Switched to Performance profile (battery: ${bat}%)" \
                    "battery"
                logger -t "$LOG_TAG" "AC disconnected -> performance"
            elif [ "$bat" -ge "$LOW_BAT_THRESHOLD" ]; then
                "$PROFILE_CMD" balanced
                notify_users "On battery - Balanced" \
                    "Switched to Balanced profile (battery: ${bat}%)" \
                    "battery"
                logger -t "$LOG_TAG" "AC disconnected -> balanced (bat ${bat}% < ${PERFORMANCE_BAT_THRESHOLD})"
            fi
        fi
        last_ac=$ac
    fi

    # --- low battery watchdog ---
    profile=$(current_profile)
    if [ "$bat" -lt "$LOW_BAT_THRESHOLD" ] && \
       [ "$profile" != "eco" ] && \
       [ ! -f "$LOW_BAT_OVERRIDE_FILE" ]; then
        "$PROFILE_CMD" eco
        notify_users "Low battery - Eco" \
            "Battery at ${bat}% - switched to Eco, brightness reduced. Click panel to override." \
            "battery-caution"
        logger -t "$LOG_TAG" "low battery (${bat}%) -> eco"
    fi

    # --- Ultra thermal watchdog ---
    profile=$(current_profile)
    if [ "$profile" = "ultra" ]; then
        if [ "$cpu_temp" -ge "$THERMAL_TRIP" ]; then
            heat_count=$(( heat_count + 1 ))
            logger -t "$LOG_TAG" "thermal: ${cpu_temp}°C (${heat_count}/${THERMAL_READINGS})"
            if [ "$heat_count" -ge "$THERMAL_READINGS" ]; then
                "$PROFILE_CMD" performance
                notify_users "Ultra throttled to Performance" \
                    "CPU held above ${THERMAL_TRIP}°C - dropped to Performance. Switch back manually when cool." \
                    "dialog-warning"
                logger -t "$LOG_TAG" "thermal watchdog tripped -> performance"
                heat_count=0
            fi
        else
            heat_count=0
        fi
    else
        heat_count=0
    fi

    sleep 3

done
