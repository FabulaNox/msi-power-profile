#!/bin/bash
# Power profile switcher for MSI Thin 15 B12UCX
# Manages: msi-ec shift/fan mode, RAPL limits, screen brightness
# Install: /usr/local/bin/power-profile (root:root, 0755)
# Usage: power-profile <ultra|performance|balanced|eco|next> [--force]

set -u

# Tunables: sourced from /etc/msi-power-profile.conf if present. The script
# falls back to MSI Thin 15 B12UCX defaults when a setting is missing, so a
# partial or absent config file still works.
# shellcheck disable=SC1091
[ -r /etc/msi-power-profile.conf ] && . /etc/msi-power-profile.conf

: "${ULTRA_PL1:=35}"
: "${ULTRA_PL2:=64}"
: "${PERFORMANCE_PL1:=28}"
: "${PERFORMANCE_PL2:=55}"
: "${BALANCED_PL1:=20}"
: "${BALANCED_PL2:=40}"
: "${ECO_PL1:=15}"
: "${ECO_PL2:=30}"
: "${MAX_BRIGHTNESS:=96000}"
: "${ECO_BRIGHTNESS_PCT:=25}"

STATE_DIR=/run/power-profile
STATE_FILE=$STATE_DIR/state
PREV_BRIGHTNESS_FILE=$STATE_DIR/prev-brightness
LOW_BAT_OVERRIDE_FILE=$STATE_DIR/low-bat-override
LOG_TAG=power-profile

MSI_EC=/sys/devices/platform/msi-ec
RAPL=/sys/class/powercap/intel-rapl/intel-rapl:0
BACKLIGHT=/sys/class/backlight/intel_backlight
PSTATE=/sys/devices/system/cpu/intel_pstate
BAT_CAPACITY=$(cat /sys/class/power_supply/BAT1/capacity 2>/dev/null || echo 100)

mkdir -p "$STATE_DIR"
chmod 1777 "$STATE_DIR"

# ---------- helpers ----------

restore_tlp_cpu() {
    # Hand turbo/maxperf back to TLP's current AC/battery setting
    local ac
    ac=$(cat /sys/class/power_supply/ADP1/online 2>/dev/null || echo "1")
    if [ "$ac" = "1" ]; then
        echo 0  > "$PSTATE/no_turbo"    2>/dev/null || true
        echo 100 > "$PSTATE/max_perf_pct" 2>/dev/null || true
    else
        echo 1  > "$PSTATE/no_turbo"    2>/dev/null || true
        echo 60 > "$PSTATE/max_perf_pct" 2>/dev/null || true
    fi
}

set_rapl() {
    local pl1_w=$1 pl2_w=$2
    echo $(( pl1_w * 1000000 )) > "$RAPL/constraint_0_power_limit_uw" 2>/dev/null || true
    echo $(( pl2_w * 1000000 )) > "$RAPL/constraint_1_power_limit_uw" 2>/dev/null || true
}

set_brightness() {
    local pct=$1
    local val=$(( MAX_BRIGHTNESS * pct / 100 ))
    echo "$val" > "$BACKLIGHT/brightness" 2>/dev/null || true
}

save_brightness() {
    if [ ! -f "$PREV_BRIGHTNESS_FILE" ]; then
        cat "$BACKLIGHT/brightness" 2>/dev/null > "$PREV_BRIGHTNESS_FILE" || true
    fi
}

restore_brightness() {
    if [ -f "$PREV_BRIGHTNESS_FILE" ]; then
        cat "$PREV_BRIGHTNESS_FILE" > "$BACKLIGHT/brightness" 2>/dev/null || true
        rm -f "$PREV_BRIGHTNESS_FILE"
    fi
}

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
            notify-send -i "$icon" -a "Power Profile" -u normal -t 5000 \
                "$title" "$body" >/dev/null 2>&1 || true
    done < <(loginctl list-sessions --no-legend)
}

current_profile() {
    cat "$STATE_FILE" 2>/dev/null || echo "performance"
}

# ---------- apply profile ----------

apply() {
    local profile=$1
    case "$profile" in
        ultra)
            echo turbo    > "$MSI_EC/shift_mode"
            echo advanced > "$MSI_EC/fan_mode"
            set_rapl "$ULTRA_PL1" "$ULTRA_PL2"
            echo 0   > "$PSTATE/no_turbo"     2>/dev/null || true
            echo 100 > "$PSTATE/max_perf_pct" 2>/dev/null || true
            restore_brightness
            rm -f "$LOW_BAT_OVERRIDE_FILE"
            ;;
        performance)
            echo comfort > "$MSI_EC/shift_mode"
            echo auto    > "$MSI_EC/fan_mode"
            set_rapl "$PERFORMANCE_PL1" "$PERFORMANCE_PL2"
            restore_tlp_cpu
            restore_brightness
            rm -f "$LOW_BAT_OVERRIDE_FILE"
            ;;
        balanced)
            echo eco  > "$MSI_EC/shift_mode"
            echo auto > "$MSI_EC/fan_mode"
            set_rapl "$BALANCED_PL1" "$BALANCED_PL2"
            restore_tlp_cpu
            restore_brightness
            ;;
        eco)
            echo eco    > "$MSI_EC/shift_mode"
            echo silent > "$MSI_EC/fan_mode"
            set_rapl "$ECO_PL1" "$ECO_PL2"
            restore_tlp_cpu
            save_brightness
            set_brightness "$ECO_BRIGHTNESS_PCT"
            ;;
        *)
            echo "Unknown profile: $profile" >&2
            exit 1
            ;;
    esac

    echo "$profile" > "$STATE_FILE"
    chmod 644 "$STATE_FILE"
    logger -t "$LOG_TAG" "profile=$profile bat=${BAT_CAPACITY}%"
}

# ---------- next: cycle logic ----------

next_profile() {
    local force=${1:-}
    local current
    current=$(current_profile)

    if [ "$current" = "eco" ] && [ -z "$force" ]; then
        # Low battery override: allow escape to balanced, mark override
        touch "$LOW_BAT_OVERRIDE_FILE"
        apply balanced
        notify_users "Low battery override" \
            "Switched to Balanced - battery at ${BAT_CAPACITY}%. Eco will not re-engage automatically." \
            "battery"
        return
    fi

    case "$current" in
        ultra)       apply performance ;;
        performance) apply balanced    ;;
        balanced)    apply ultra       ;;
        eco)         apply ultra       ;;  # --force path
    esac
}

# ---------- main ----------

CMD=${1:-}
FORCE=""
[ "${2:-}" = "--force" ] && FORCE="--force"

case "$CMD" in
    ultra|performance|balanced|eco)
        apply "$CMD"
        ;;
    next)
        next_profile "$FORCE"
        ;;
    *)
        echo "Usage: $0 <ultra|performance|balanced|eco|next> [--force]" >&2
        exit 1
        ;;
esac
