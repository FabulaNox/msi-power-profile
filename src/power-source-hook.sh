#!/bin/bash
# Fires on AC/BAT change (called by udev via systemd-run).
# TLP's own udev rule already handles the profile switch - this only notifies + logs.
# Install: /usr/local/bin/power-source-hook (root:root, 0755)

set -u

ADP_ONLINE=$(cat /sys/class/power_supply/ADP1/online 2>/dev/null || echo "?")
BAT_CAP=$(cat /sys/class/power_supply/BAT1/capacity 2>/dev/null || echo "?")
BAT_STATUS=$(cat /sys/class/power_supply/BAT1/status 2>/dev/null || echo "?")

# Debounce: udev fires multiple change events per real transition.
# Only act when ADP1/online actually flips vs the last recorded value.
STATE_FILE=/run/power-source-hook.state
PREV=$(cat "$STATE_FILE" 2>/dev/null || true)
if [ "$ADP_ONLINE" = "$PREV" ]; then
    exit 0
fi
printf '%s' "$ADP_ONLINE" > "$STATE_FILE"

if [ "$ADP_ONLINE" = "1" ]; then
    title="On AC Power"
    body="Switched to performance profile (battery: ${BAT_CAP}% / ${BAT_STATUS})"
    icon="ac-adapter"
else
    title="On Battery"
    body="Switched to power-saving profile (battery: ${BAT_CAP}% / ${BAT_STATUS})"
    icon="battery"
fi

logger -t power-hook "AC=${ADP_ONLINE} bat=${BAT_CAP}% status=${BAT_STATUS}"

# Notify each unique user once.
# loginctl returns one row per session (often user + manager for the same uid),
# so dedupe by uid to avoid N notifications for the same human.
seen=""
while read -r sid uid user _rest; do
    [ -z "${user:-}" ] && continue
    [ ! -d "/run/user/${uid}" ] && continue
    case " $seen " in *" $uid "*) continue ;; esac
    seen="$seen $uid"

    stype=$(loginctl show-session "$sid" -p Type --value 2>/dev/null || echo "")
    display_arg=""
    case "$stype" in
        wayland)
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
        notify-send -i "$icon" -a "Power" -u normal -t 4000 "$title" "$body" \
        >/dev/null 2>&1 || true
done < <(loginctl list-sessions --no-legend)
