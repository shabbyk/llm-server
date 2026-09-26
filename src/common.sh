#!/usr/bin/env bash
# Shared configuration and helpers. Sourced by every other script.
# Not executable on purpose — source it, don't run it.
#
# Every setting can be overridden by exporting it before the script runs, and
# persistently by creating $LLM_DIR/config.env (see config.env.example). The
# order is: built-in default -> config.env -> environment.

LLM_DIR="${LLM_DIR:-$HOME/llm}"

# Load persistent config if present. It may set anything in this file.
if [ -f "$LLM_DIR/config.env" ]; then
    # shellcheck disable=SC1091
    . "$LLM_DIR/config.env"
fi

LLM_BIN="${LLM_BIN:-$LLM_DIR/llama}"
LLM_MODELS="${LLM_MODELS:-$LLM_DIR/models}"
LLM_LOGS="${LLM_LOGS:-$LLM_DIR/logs}"

# Pick a routable LAN address, preferring the interface with a default route.
# Prints 127.0.0.1 if it cannot work one out, which is a safe default: it means
# "loopback only" rather than "accidentally world reachable".
#
# Defined before it is called below, because this file executes top to bottom.
llm_detect_host() {
    local ip=""
    if command -v ip >/dev/null 2>&1; then
        local dev
        dev="$(ip -o route show default 2>/dev/null | awk '{print $5; exit}')"
        if [ -n "$dev" ]; then
            ip="$(ip -o -4 addr show dev "$dev" scope global 2>/dev/null \
                  | awk '{print $4}' | cut -d/ -f1 | head -1)"
        fi
    fi
    if [ -z "$ip" ] && command -v hostname >/dev/null 2>&1; then
        ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    fi
    printf '%s' "${ip:-127.0.0.1}"
}

# Where to bind. 0.0.0.0 would expose this to anything that can route to the
# host, so the default is a detected LAN address and the documented fallback is
# 127.0.0.1 (tunnel-only). There is no API key: see the security note in README.
LLM_HOST="${LLM_HOST:-$(llm_detect_host)}"
LLM_PORT="${LLM_PORT:-8080}"

# Context length. 16384 is a safe default on an 8 GB card. KV cache costs
# roughly 17 MiB per 1024 tokens for Qwen3.5-9B at q8_0, and it does not slow
# decode — it only costs prefill time on very long prompts. Verified to load at
# 16384 / 24576 / 32768 on an RX 6600; 32768 is not guaranteed on smaller cards.
#
# Do NOT size this against the VRAM counter. amdgpu backs the model with either
# VRAM or GTT and migrates between them at runtime, so mem_info_vram_used is not
# a usable capacity signal on at least some drivers. See README.
LLM_CTX="${LLM_CTX:-16384}"
LLM_THREADS="${LLM_THREADS:-$(nproc 2>/dev/null || echo 4)}"
LLM_NGL="${LLM_NGL:-99}"

# Group that owns /dev/dri/renderD*. Usually "render", sometimes "video".
LLM_RENDER_GROUP_NAME="${LLM_RENDER_GROUP_NAME:-render}"
LLM_SESSION="${LLM_SESSION:-llm}"

llm_model_path() {
    case "$1" in
        q6|Q6) echo "$LLM_MODELS/Qwen3.5-9B-Q6_K.gguf" ;;
        q4|Q4) echo "$LLM_MODELS/Qwen3.5-9B-Q4_K_M.gguf" ;;
        *) return 1 ;;
    esac
}

# Can this process open the render node right now?
llm_render_ok() {
    python3 - <<'PY' 2>/dev/null
import glob, os, sys
nodes = sorted(glob.glob("/dev/dri/renderD*"))
if not nodes:
    sys.exit(1)
try:
    fd = os.open(nodes[0], os.O_RDWR)
    os.close(fd)
except OSError:
    sys.exit(1)
PY
}

# The first DRM card that exposes amdgpu-style memory counters. Prints nothing
# if none does (e.g. an iGPU with a different driver), so callers must handle
# the empty case rather than assuming card0 exists.
llm_drm_device_dir() {
    local d
    for d in /sys/class/drm/card*/device; do
        [ -r "$d/mem_info_vram_used" ] && { echo "$d"; return 0; }
    done
    for d in /sys/class/drm/card*/device; do
        [ -d "$d" ] && { echo "$d"; return 0; }
    done
    return 1
}

# Run a command with the render group active, preserving argv. `llm-run` is a
# separate script rather than a function because newgrp(1) re-execs its command
# with an empty argv — see the comments in llm-run for the full story.
#
# This one does NOT replace the current process, so it is safe to call in the
# middle of a script. Use llm_with_render_group only as the final statement.
llm_run() { "$LLM_DIR/llm-run" "$@"; }

llm_with_render_group() { exec "$LLM_DIR/llm-run" "$@"; }
