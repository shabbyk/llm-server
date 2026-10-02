#!/usr/bin/env bash
# Shared configuration and helpers for the local LLM server.
# Sourced by every other script. Not executable on purpose — source it.
#
# Every setting can be overridden by exporting it, and persistently by creating
# $LLM_DIR/config.env. Precedence: default -> config.env -> environment.
#
# Two engines are supported, selected by LLM_ENGINE:
#
#   ollama     Drive a model by tag. Ollama vendors the same ggml Vulkan backend,
#              so the GPU story is identical; it adds model management and a
#              single binary in ~/.local/bin.
#
#   llamacpp   Launch `llama-server` against a GGUF file. The server also serves
#              the llama.ui chat page on the same port, so no separate UI
#              process is needed. Supports MCP tool servers natively.
#
# Both speak the OpenAI API on /v1, so ask.sh, bench.sh and ask.py are oblivious
# to which one is running.

LLM_DIR="${LLM_DIR:-$HOME/llm}"

# Load persistent config if present. It may set anything in this file.
if [ -f "$LLM_DIR/config.env" ]; then
    # shellcheck disable=SC1091
    . "$LLM_DIR/config.env"
fi

# --------------------------------------------------------------- the engine --
# Which runtime `llm on` starts. Both may be installed; only one runs at a time,
# each on its own port, so switching is `llm restart`.
: "${LLM_ENGINE:=ollama}"

# ---------------------------------------------------------------- the model --
# Ollama identifies a model by tag; llama.cpp by the path to a GGUF file. Both
# are set, so switching engines does not lose the other's setting.
: "${LLM_MODEL:=qwen3.5:9b}"
: "${LLM_GGUF:=$LLM_DIR/models/Qwen3.5-9B-Q4_K_M.gguf}"

# --------------------------------------------------------------- the runtime --
# Ollama's binary. The installer drops it in ~/.local/bin so no sudo is needed
# and, deliberately, no systemd service exists to start on boot.
: "${OLLAMA_BIN:=$HOME/.local/bin/ollama}"
: "${OLLAMA_MODELS_DIR:=$HOME/.ollama/models}"

# llama.cpp. The installer extracts a prebuilt Vulkan tarball under here; the
# binary lives one level down in a tag-named directory, so it is located by
# search rather than assumed.
: "${LLAMACPP_DIR:=$LLM_DIR/llamacpp}"

# Layers to offload. 99 means "all of them"; llama.cpp clamps it to the model.
: "${LLM_NGL:=99}"

# Flash attention. Measured on this box to make no difference to Ollama's
# prefill (8889 vs 8754 tok/s), so it is off by default until it earns its place.
: "${LLM_FA:=0}"

# Whether to let a reasoning model think before answering.
#
# Qwen3.5 is one, and left alone it can put its whole answer in the reasoning
# channel and return an empty content field — which reads as a blank reply.
# Off by default for that reason; ask.py sends `think: false` to Ollama for the
# same purpose.
: "${LLM_THINKING:=0}"

# The name llama.cpp advertises over /v1, so clients that say "qwen3.5:9b" keep
# working when the engine underneath changes. Defaults to LLM_MODEL, which is
# already exactly that.
: "${LLM_ALIAS:=}"

# Extra flags appended verbatim to the llama-server command line.
: "${LLM_EXTRA_ARGS:=}"

# MCP tool servers, as the JSON llama-server expects, e.g.
#   LLM_MCP='{"mcpServers":{"rag":{"url":"http://127.0.0.1:8082/mcp"}}}'
# Empty means no tool servers. Setting it also enables the UI's CORS proxy.
: "${LLM_MCP:=}"

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

# Each engine gets its own port. They are different programs with different
# management APIs, and letting them share a number means `llm status` cannot tell
# you which one is up. Set LLM_PORT to pin it yourself.
if [ "$LLM_ENGINE" = "llamacpp" ]; then
    : "${LLM_PORT:=8090}"
else
    : "${LLM_PORT:=11434}"
fi

# ---------------------------------------------------------------- behaviour --
# Context window. THE setting to get right on migration: Ollama's own default is
# 4096, and an agentic client's system prompt plus tool definitions alone run
# ~6.6k tokens. At 4096 that truncates silently — the failure looks like the
# model ignoring instructions, not like a configuration error.
: "${LLM_CTX:=32768}"

# How long a model stays resident in VRAM after the last request.
: "${LLM_KEEP_ALIVE:=5m}"

# --------------------------------------------------------------------- paths --
# Named after the engine, so switching does not overwrite the other's log. For
# ollama these resolve to exactly the paths the previous version used.
LLM_LOGS="${LLM_LOGS:-$LLM_DIR/logs}"
LLM_PID="$LLM_LOGS/$LLM_ENGINE.pid"
LLM_LOG="$LLM_LOGS/$LLM_ENGINE.log"

llm_url() { printf 'http://%s:%s' "$LLM_HOST" "$LLM_PORT"; }

# The llama-server binary, wherever the installer left it. The tarball extracts
# into a tag-named directory (llama-b11146/), so the path is discovered rather
# than hardcoded — a new tag would otherwise silently break `llm on`.
llamacpp_bin() {
    local b
    b="$(find "$LLAMACPP_DIR" -maxdepth 3 -type f -name 'llama-server' 2>/dev/null | head -1)"
    printf '%s' "$b"
}

# The endpoint that means "this engine is up".
#
# Ollama answers /api/version; llama.cpp answers /health, and returns 503 while
# it is still loading weights. That difference is why curl is called with -f:
# without it a 503 counts as success and `llm on` would report ready before the
# model is in memory.
llm_health_path() {
    case "$LLM_ENGINE" in
        llamacpp) printf '%s' "/health" ;;
        *)        printf '%s' "/api/version" ;;
    esac
}

# The base URL to actually talk to.
#
# Normally this is the configured host. But a server can be bound to loopback
# while the config says otherwise — started by hand, or by a different tool.
# Reporting "OFF" for a server that is answering would be a lie, so fall back to
# 127.0.0.1 before giving up.
llm_base() {
    if curl -fsS -o /dev/null --max-time 2 "$(llm_url)$(llm_health_path)" 2>/dev/null; then
        printf '%s' "$(llm_url)"
    else
        printf 'http://127.0.0.1:%s' "$LLM_PORT"
    fi
}

# Is the server answering? Ask over HTTP rather than checking for a process:
# `ollama` is also the CLI name, so pgrep matches short-lived client runs too.
#
# /v1/models is the fallback because both engines implement it. That matters when
# the engine was switched without a restart, or a server was started by hand: the
# configured health path would miss it and `llm off` would refuse to do anything.
llm_serving() {
    curl -fsS -o /dev/null --max-time 3 "$(llm_url)$(llm_health_path)" 2>/dev/null && return 0
    curl -fsS -o /dev/null --max-time 3 "$(llm_url)/v1/models" 2>/dev/null && return 0
    curl -fsS -o /dev/null --max-time 3 "http://127.0.0.1:$LLM_PORT$(llm_health_path)" 2>/dev/null
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

# Which model is resident right now. Empty if none.
#
# Ollama reports this itself, and a model can be loaded or evicted independently
# of the server. llama.cpp has no such distinction — weights are loaded at start
# and held until the process dies — so if the server answers, the configured GGUF
# is what is in memory.
llm_loaded_model() {
    case "$LLM_ENGINE" in
        llamacpp)
            llm_serving || return 0
            llm_openai_model
            ;;
        *)
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
            ;;
    esac
}

# The model id as the OpenAI API sees it. Both engines implement /v1/models, so
# this is also the honest answer to "what would a client get".
llm_openai_model() {
    curl -fsS --max-time 5 "$(llm_base)/v1/models" 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for m in d.get("data", []):
    print(m.get("id") or "")
    break
' 2>/dev/null
}

# Where the resident model lives: "100% GPU", "41% GPU, 59% CPU", or empty.
#
# Ollama can be asked, and reports the bytes it placed in VRAM. llama.cpp cannot,
# and this build logs nothing about the split at default verbosity, so the answer
# is measured: the memory the GPU can address, against the size of the model
# file.
#
# Both pools count, and that is the whole trick. On this card the driver backs
# model allocations with GTT — system RAM the GPU addresses — as readily as with
# dedicated VRAM, and it moves between the two across loads. Measured here: the
# same model and settings landed as "vram 6188 / gtt 1282" one load and
# "vram 16 / gtt 7422" the next, both running at ~21 tok/s. Counting VRAM alone
# reports the second case as "nothing loaded", which is the misreading this
# figure exists to prevent.
#
# Caveat: any other process holding either pool inflates the total. On a box
# where this is the only GPU tenant that is not a concern, and it still beats
# deriving the answer from -ngl, which is a request rather than a result.
llm_processor() {
    case "$LLM_ENGINE" in
        llamacpp)
            local d vram gtt size used pct
            d="$(llm_drm_device_dir)" || return 0
            vram="$(awk '{printf "%d", $1/1000000}' "$d/mem_info_vram_used" 2>/dev/null)"
            gtt="$(awk '{printf "%d", $1/1000000}' "$d/mem_info_gtt_used" 2>/dev/null)"
            size="$(stat -c %s "$LLM_GGUF" 2>/dev/null)"
            [ -n "$vram" ] && [ -n "$size" ] && [ "$size" -gt 0 ] || return 0
            used=$(( ${vram:-0} + ${gtt:-0} ))
            pct=$(( 100 * used / (size / 1000000) ))
            [ "$pct" -gt 100 ] && pct=100
            if [ "$pct" -ge 95 ]; then
                printf '100%% GPU'
            elif [ "$pct" -ge 10 ]; then
                printf '%s%% GPU, %s%% CPU' "$pct" "$((100 - pct))"
            else
                printf 'CPU only (nothing loaded on the GPU)'
            fi
            ;;
        *)
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
            ;;
    esac
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
