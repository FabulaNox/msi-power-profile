#!/bin/bash
# XFCE genmon: show CPU/battery/profile status in panel.
# Install: /usr/local/bin/tlp-genmon (root:root, 0755)
# Genmon command: /usr/local/bin/tlp-genmon
# Genmon period: 5s

ADP_ONLINE=$(cat /sys/class/power_supply/ADP1/online 2>/dev/null)
BAT_CAP=$(cat /sys/class/power_supply/BAT1/capacity 2>/dev/null)
BAT_STATUS=$(cat /sys/class/power_supply/BAT1/status 2>/dev/null)
GOV=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)
EPP=$(cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference 2>/dev/null)
NO_TURBO=$(cat /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null)
MAX_PCT=$(cat /sys/devices/system/cpu/intel_pstate/max_perf_pct 2>/dev/null)
CUR_FREQ_KHZ=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null)
CUR_FREQ_GHZ=$(awk -v f="$CUR_FREQ_KHZ" 'BEGIN{printf "%.2f", f/1000000}')
SHIFT=$(cat /sys/devices/platform/msi-ec/shift_mode 2>/dev/null || echo "unknown")
POWER_PROFILE=$(cat /run/power-profile/state 2>/dev/null || echo "unknown")

ICONS=/usr/share/icons/hicolor/scalable/status

if [ "$ADP_ONLINE" = "1" ]; then
    source="AC"
    img="${ICONS}/msi-power-source-ac.svg"
else
    source="BAT"
    img="${ICONS}/msi-power-source-battery.svg"
fi

if [ "$NO_TURBO" = "0" ]; then turbo="on"; else turbo="off"; fi

# Color the percentage by source (AC=green, BAT=yellow, BAT<20=red)
if [ "$source" = "AC" ]; then
    color="#7CB342"
elif [ "${BAT_CAP:-100}" -lt 20 ]; then
    color="#E53935"
else
    color="#FDD835"
fi

txt_inner="${BAT_CAP}%"
tool="Power source : ${source} (${BAT_STATUS})
Battery     : ${BAT_CAP}%
Profile     : ${POWER_PROFILE} (EC: ${SHIFT})
Governor    : ${GOV}
EPP         : ${EPP}
Turbo boost : ${turbo}
Max perf    : ${MAX_PCT}%
Current CPU : ${CUR_FREQ_GHZ} GHz"

# Escape XML-special chars in tooltip just in case
tool_escaped=$(printf '%s' "$tool" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')

printf '<img>%s</img>\n' "$img"
printf '<txt><span foreground="%s" weight="bold">%s</span></txt>\n' "$color" "$txt_inner"
printf '<tool>%s</tool>\n' "$tool_escaped"
printf '<click>xfce4-terminal --hold --title=TLP-status -x sh -c "tlp-stat -s; echo; tlp-stat -p"</click>\n'
