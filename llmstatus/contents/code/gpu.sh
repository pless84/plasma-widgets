#!/bin/sh
# Prints one "load %, used MiB, total MiB, name" line per GPU, for the LLM Status widget:
# NVIDIA cards through nvidia-smi, otherwise AMD cards through their sysfs counters.
# Prints nothing when there is no supported GPU.

if command -v nvidia-smi >/dev/null 2>&1 \
    && nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.total,name --format=csv,noheader,nounits 2>/dev/null; then
    exit 0
fi

for dev in /sys/class/drm/card*/device; do
    [ -r "$dev/gpu_busy_percent" ] || continue
    used=$(cat "$dev/mem_info_vram_used" 2>/dev/null || echo 0)
    total=$(cat "$dev/mem_info_vram_total" 2>/dev/null || echo 0)
    echo "$(cat "$dev/gpu_busy_percent"), $((used / 1048576)), $((total / 1048576)), AMD GPU"
done
exit 0
