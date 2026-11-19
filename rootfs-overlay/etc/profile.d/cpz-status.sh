# /etc/profile.d/cpz-status.sh — battery + SoC temp in the shell prompt
# (Stage 06 goal, shipped from day one — cheap and useful for testing)

cpz_batt() {
    v=$(cat /sys/class/power_supply/bq27220-0/capacity 2>/dev/null)
    echo "${v:--}"
}

PS1='[$(cpz_batt)% $(cut -c1-2 /sys/class/thermal/thermal_zone0/temp 2>/dev/null || echo ??).0°C \W]\$ '
