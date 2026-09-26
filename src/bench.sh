#!/usr/bin/env bash
# Benchmark the local models.
#
#   ./bench.sh          # both models
#   ./bench.sh q6       # one model
#
# Stops the server first. A live llama-server holds GPU memory and pushes
# llama-bench into partial offload, which reports numbers several times too low.
#
# Read the result with care. llama-bench amortises a fixed warmup cost over
# however many tokens you ask for, so short generations flatter the smaller
# model most. On an RX 6600, Q4_K_M measured 36.4 tok/s at -n 128, 28.5 at
# -n 512, and 21.3 through the live server over ~310 tokens. For a number you
# intend to quote, start the server and time it with ask.sh instead.

set -euo pipefail
# shellcheck disable=SC1091
. "${LLM_DIR:-$HOME/llm}/common.sh"

if pgrep -x llama-server >/dev/null; then
    echo "stopping the running server first..."
    "$LLM_DIR/stop.sh"
fi

# Wait for the GPU to actually drain before measuring. Both counters matter: the
# model may be backed by GTT rather than VRAM, so a VRAM-only check can read
# "free" while the GPU is still fully occupied. See status.sh.
gpu_busy() {
    local d vram gtt
    d="$(llm_drm_device_dir 2>/dev/null)" || return 1
    vram=$(cat "$d/mem_info_vram_used" 2>/dev/null || echo 0)
    gtt=$(cat "$d/mem_info_gtt_used" 2>/dev/null || echo 0)
    [ "$vram" -ge 200000000 ] || [ "$gtt" -ge 200000000 ]
}

for _ in $(seq 1 40); do
    gpu_busy || break
    sleep 0.5
done

if d="$(llm_drm_device_dir 2>/dev/null)"; then
    printf 'VRAM %s MB   GTT %s MB\n' \
        "$(( $(cat "$d/mem_info_vram_used" 2>/dev/null || echo 0) / 1000000 ))" \
        "$(( $(cat "$d/mem_info_gtt_used"  2>/dev/null || echo 0) / 1000000 ))"
fi
echo

echo "=== devices ==="
llm_run "$LLM_BIN/llama-cli" --list-devices
echo

presets=("$@")
if [ ${#presets[@]} -eq 0 ]; then
    presets=(q6 q4)
fi

for p in "${presets[@]}"; do
    model="$(llm_model_path "$p")"
    [ -f "$model" ] || { echo "skip $p: $model missing"; continue; }
    echo "=== $p  $(basename "$model")  $(( $(stat -c%s "$model") / 1000000 )) MB ==="
    # Short flags only: llama-bench accepts -ngl/-fa but not the server's
    # --gpu-layers/--flash-attn long forms, and prints its whole usage text.
    llm_run "$LLM_BIN/llama-bench" \
        -m "$model" \
        -ngl "$LLM_NGL" \
        -t "$LLM_THREADS" \
        -fa on \
        -ctk q8_0 \
        -ctv q8_0 \
        -p 512 -n 128 -r 3
    echo
done
