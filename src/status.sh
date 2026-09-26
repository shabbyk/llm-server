#!/usr/bin/env bash
# Show server state: process, health, GPU memory, and available RAM.

set -uo pipefail
# shellcheck disable=SC1091
. "${LLM_DIR:-$HOME/llm}/common.sh"

# Memory reporting needs care on at least some drivers. On amdgpu the model
# buffer can be backed by VRAM or by GTT (an aperture over system RAM), and it
# can migrate between the two *while the process runs*: one server here read
# 7.13 GB of VRAM at startup, 6.92 GB mid-generation, then 0.02 GB later, all
# without restarting and all while serving at full GPU speed. So both counters
# are shown, and neither is trusted as proof of GPU residency.
#
# The only trustworthy signal is throughput. For a 9B Q6_K on an 8 GB card,
# roughly 19 tok/s means the GPU is doing the work and roughly 4.5 tok/s means
# it silently fell back to the CPU.
memory() {
    local d
    if ! d="$(llm_drm_device_dir 2>/dev/null)"; then
        echo "  GPU       (no DRM device with memory counters found)"
        return
    fi
    local vram vram_total gtt gtt_total
    vram="$(cat "$d/mem_info_vram_used" 2>/dev/null || echo 0)"
    vram_total="$(cat "$d/mem_info_vram_total" 2>/dev/null || echo 0)"
    gtt="$(cat "$d/mem_info_gtt_used" 2>/dev/null || echo 0)"
    gtt_total="$(cat "$d/mem_info_gtt_total" 2>/dev/null || echo 0)"
    awk -v v="$vram" -v vt="$vram_total" -v g="$gtt" -v gt="$gtt_total" 'BEGIN{
        if (vt > 0) printf "  VRAM      %6.2f / %6.2f GB\n", v/1e9, vt/1e9
        if (gt > 0) printf "  GTT       %6.2f / %6.2f GB   (may back the model instead of VRAM)\n", g/1e9, gt/1e9
    }'
}

pids="$(pgrep -x llama-server | tr '\n' ' ')"
if [ -z "$pids" ]; then
    echo "llama-server   not running"
else
    echo "llama-server   running (pid $pids)"
    args="$(tr '\0' ' ' < "/proc/${pids%% *}/cmdline" 2>/dev/null)"
    echo "               $args"
fi

memory

free -h 2>/dev/null | awk '/^Mem:/ {printf "  RAM       %s total, %s available\n", $2, $7}'

if [ -n "$pids" ]; then
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://$LLM_HOST:$LLM_PORT/health" 2>/dev/null)
    case "$code" in
        200) echo "  health     OK (http://$LLM_HOST:$LLM_PORT)" ;;
        000) echo "  health     unreachable on $LLM_HOST:$LLM_PORT (still loading?)" ;;
        *)   echo "  health     HTTP $code" ;;
    esac
fi
