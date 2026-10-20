#!/bin/sh
# Prints one "load %, used MiB, total MiB, temperature °C, power W, power limit W, name" line per
# GPU, for the LLM Status widget: NVIDIA cards through nvidia-smi, otherwise AMD cards through
# their sysfs counters. A value the card doesn't report is empty (or nvidia-smi's "[N/A]").
# NVIDIA cards are followed by a "# apps" line and one "pid, process, used MiB" line per
# compute process, to show who else is using the card's memory.
# Prints nothing when there is no supported GPU.

# nvidia-smi can hang when the driver is stuck, so it gets 5 seconds (where `timeout` exists).
limit=""
command -v timeout >/dev/null 2>&1 && limit="timeout 5"

# A very old driver rejects the extended fields (nvidia-smi exits non-zero), so the original
# four are tried before giving up on NVIDIA.
if command -v nvidia-smi >/dev/null 2>&1 \
    && { out=$($limit nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw,power.limit,name --format=csv,noheader,nounits 2>/dev/null) \
         || out=$($limit nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.total,name --format=csv,noheader,nounits 2>/dev/null); }; then
    [ -n "$out" ] && echo "$out"
    apps=$($limit nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader,nounits 2>/dev/null)
    if [ -n "$apps" ]; then
        echo "# apps"
        echo "$apps"
    fi
    exit 0
fi

# The first readable file among the arguments, or nothing.
first_file() {
    for f in "$@"; do
        [ -r "$f" ] && { cat "$f" 2>/dev/null; return; }
    done
}

for dev in /sys/class/drm/card*/device; do
    [ -r "$dev/gpu_busy_percent" ] || continue
    used=$(cat "$dev/mem_info_vram_used" 2>/dev/null || echo 0)
    total=$(cat "$dev/mem_info_vram_total" 2>/dev/null || echo 0)
    temp=$(first_file "$dev"/hwmon/hwmon*/temp1_input)
    power=$(first_file "$dev"/hwmon/hwmon*/power1_average "$dev"/hwmon/hwmon*/power1_input)
    cap=$(first_file "$dev"/hwmon/hwmon*/power1_cap)
    [ -n "$temp" ] && temp=$((temp / 1000))
    [ -n "$power" ] && power=$((power / 1000000))
    [ -n "$cap" ] && cap=$((cap / 1000000))
    echo "$(cat "$dev/gpu_busy_percent"), $((used / 1048576)), $((total / 1048576)), $temp, $power, $cap, AMD GPU"
done
exit 0
