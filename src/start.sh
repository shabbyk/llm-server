#!/usr/bin/env bash
# Start the llama.cpp server. Runs in the foreground; use tmux to detach.
#
#   ./start.sh                 # Q6_K, configured port and context
#   ./start.sh q4              # Q4_K_M instead
#   ./start.sh q6 9090         # different port
#   ./start.sh q4 8192 16384   # port, then context
#
# Any setting from common.sh can be overridden in the environment instead, e.g.
#   LLM_CTX=32768 ./start.sh

set -euo pipefail
# shellcheck disable=SC1091
. "${LLM_DIR:-$HOME/llm}/common.sh"

preset=q6
port="$LLM_PORT"
ctx="$LLM_CTX"

case "${1:-}" in
    "")     ;;
    q6|Q6)  preset=q6 ;;
    q4|Q4)  preset=q4 ;;
    -h|--help)
        sed -n '2,/^$/p' "$0" | sed -e 's/^#\{1,\} \{0,1\}//' -e '/^$/d'
        exit 0 ;;
    *) echo "unknown preset '$1' (expected q6 or q4)" >&2; exit 2 ;;
esac
[ $# -gt 0 ] && shift
[ $# -gt 0 ] && port="$1" && shift
[ $# -gt 0 ] && ctx="$1" && shift
[ $# -gt 0 ] && { echo "too many arguments" >&2; exit 2; }

model="$(llm_model_path "$preset")"
if [ ! -f "$model" ]; then
    echo "missing model: $model" >&2
    echo "run install.sh, or see the download step in README" >&2
    exit 1
fi

# pgrep -x, never -f: this script's own command line contains the pattern, so
# -f would match it and report a phantom server.
if pgrep -x llama-server >/dev/null; then
    echo "llama-server is already running (pid $(pgrep -x llama-server | tr '\n' ' '))." >&2
    echo "Use ./stop.sh first." >&2
    exit 1
fi

mkdir -p "$LLM_LOGS"
log="$LLM_LOGS/${preset}-p${port}.log"

cat <<EOF
model      $(basename "$model")
preset     $preset   context $ctx   port $port
bind       http://$LLM_HOST:$port
offload    -ngl $LLM_NGL   threads $LLM_THREADS   flash-attn on   KV q8_0/q8_0
log        $log
EOF
echo

# Note: at the default verbosity llama.cpp does not print the device selection
# or the offload lines, so a quiet log here does NOT mean it fell back to the
# CPU. Add -lv 4 to see "offloaded N/N layers to GPU". To check for real, use
# ./status.sh and measure tok/s — see status.sh.
llm_with_render_group \
    "$LLM_BIN/llama-server" \
        --model "$model" \
        --host "$LLM_HOST" \
        --port "$port" \
        --gpu-layers "$LLM_NGL" \
        --ctx-size "$ctx" \
        --threads "$LLM_THREADS" \
        --flash-attn on \
        --cache-type-k q8_0 \
        --cache-type-v q8_0 \
        --jinja \
        --log-file "$log" \
        --log-timestamps
