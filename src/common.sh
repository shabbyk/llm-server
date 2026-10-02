#!/usr/bin/env bash
# Shared configuration and helpers for the Ollama-backed LLM server.
# Sourced by every other script. Not executable on purpose — source it.
#
# Every setting can be overridden by exporting it, and persistently by creating
# $LLM_DIR/config.env. Precedence: default -> config.env -> environment.
#
# This replaced a llama.cpp + Vulkan build. Ollama vendors the same ggml Vulkan
# backend, so the GPU story is unchanged; what changed is that the runtime is a
# server you drive by model name rather than a binary you launch against a file.

LLM_DIR="${LLM_DIR:-$HOME/llm}"

# Load persistent config if present. It may set anything in this file.
if [ -f "$LLM_DIR/config.env" ]; then
    # shellcheck disable=SC1091
    . "$LLM_DIR/config.env"
fi

# ---------------------------------------------------------------- the model --
# An Ollama tag, not a file path. `ollama list` shows what is present.
: "${LLM_MODEL:=qwen3.5:9b}"

# --------------------------------------------------------------- the runtime --
# Ollama's binary. The installer drops it in ~/.local/bin so no sudo is needed
# and, deliberately, no systemd service exists to start on boot.
: "${OLLAMA_BIN:=$HOME/.local/bin/ollama}"
: "${OLLAMA_MODELS_DIR:=$HOME/.ollama/models}"

# Pick a routable LAN address, preferring the interface with a default route.
# Prints 127.0.0.1 if it cannot work one out, which is a safe default: it means
# "loopback only" rather than "accidentally world reachable".
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

# Where the server binds, and where clients look for it.
#
# 127.0.0.1 by default, for two reasons. The Ollama CLI talks to 127.0.0.1:11434
# unless told otherwise, so binding elsewhere makes `ollama list` print a
# spurious "could not connect" warning. And this server has no API key, so the
# safe default is that only this machine can reach it.
#
# To serve other machines, set LLM_HOST=0.0.0.0 (everything that can route here)
# or the LAN address, and remember there is no authentication.
: "${LLM_HOST:=127.0.0.1}"
: "${LLM_PORT:=11434}"

# ---------------------------------------------------------------- behaviour --
# Context window. THE setting to get right on migration: Ollama's own default is
# 4096, and an agentic client's system prompt plus tool definitions alone run
# ~6.6k tokens. At 4096 that truncates silently — the failure looks like the
# model ignoring instructions, not like a configuration error.
: "${LLM_CTX:=32768}"

# How long a model stays resident in VRAM after the last request.
: "${LLM_KEEP_ALIVE:=5m}"

# --------------------------------------------------------------------- paths --
LLM_LOGS="${LLM_LOGS:-$LLM_DIR/logs}"
LLM_PID="$LLM_LOGS/ollama.pid"
LLM_LOG="$LLM_LOGS/ollama.log"

llm_url() { printf 'http://%s:%s' "$LLM_HOST" "$LLM_PORT"; }

# The base URL to actually talk to.
#
# Normally this is the configured host. But a server can be bound to loopback
# while the config says otherwise — started by hand, or by a different tool.
# Reporting "OFF" for a server that is answering would be a lie, so fall back to
# 127.0.0.1 before giving up.
llm_base() {
    if curl -sS -o /dev/null --max-time 2 "$(llm_url)/api/version" 2>/dev/null; then
        printf '%s' "$(llm_url)"
    else
        printf 'http://127.0.0.1:%s' "$LLM_PORT"
    fi
}

# Is the server answering? Ask over HTTP rather than checking for a process:
# `ollama` is also the CLI name, so pgrep matches short-lived client runs too.
llm_serving() {
    curl -sS -o /dev/null --max-time 3 "$(llm_base)/api/version" 2>/dev/null
}

# The resolved base as host:port, for OLLAMA_HOST.
llm_hostport() {
    local base; base="$(llm_base)"
    printf '%s' "${base#http://}"
}

# Run the ollama CLI against the server we manage. Without OLLAMA_HOST the CLI
# talks to its own default and prints "could not connect to a running Ollama
# instance" whenever the server is bound anywhere else — a confusing warning
# for a server that is up.
ollama_cli() {
    OLLAMA_HOST="$(llm_hostport)" "$OLLAMA_BIN" "$@"
}

# Which model is resident right now, per the server itself. Empty if none.
llm_loaded_model() {
    curl -sS --max-time 5 "$(llm_base)/api/ps" 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for m in d.get("models", []):
    print(m.get("name") or m.get("model") or "")
    break
' 2>/dev/null
}

# Where the resident model lives: "100% GPU", "41%/59% CPU/GPU", or empty.
llm_processor() {
    curl -sS --max-time 5 "$(llm_base)/api/ps" 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for m in d.get("models", []):
    size = m.get("size") or 0
    vram = m.get("size_vram") or 0
    if not size:
        continue
    pct = round(100 * vram / size)
    print("100% GPU" if pct >= 99 else f"{pct}% GPU, {100 - pct}% CPU")
    break
' 2>/dev/null
}

# The DRM device directory that exposes memory counters, if there is one.
llm_drm_device_dir() {
    local d
    for d in /sys/class/drm/card*/device; do
        [ -r "$d/mem_info_vram_used" ] && { printf '%s' "$d"; return 0; }
    done
    return 1
}

# GPU memory in MB, as "vram gtt".
#
# Both, not just VRAM. On this card the driver puts model allocations in GTT
# (system RAM the GPU can address) and leaves dedicated VRAM nearly empty, so a
# lone "vram: 16 MB" line reads as "nothing is loaded" while 6 GB is in use.
# The previous llama.cpp build printed both for the same reason.
llm_gpu_mem() {
    local d vram gtt
    d="$(llm_drm_device_dir)" || return 1
    vram="$(awk '{printf "%d", $1/1000000}' "$d/mem_info_vram_used" 2>/dev/null)"
    gtt="$(awk '{printf "%d", $1/1000000}' "$d/mem_info_gtt_used" 2>/dev/null)"
    printf 'vram %s MB, gtt %s MB' "${vram:-?}" "${gtt:-?}"
}
