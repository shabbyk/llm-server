#!/usr/bin/env bash
# Start the server inside a tmux session so it survives closing your terminal.
#
#   ./up.sh          # Q6_K on the configured port, session "llm"
#   ./up.sh q4       # Q4_K_M instead
#   ./up.sh q6 9090  # different port
#   ./down.sh        # stop the server and kill the session
#
# Prefer the `llm` switch, which wraps this and waits until the server is ready.

set -euo pipefail
# shellcheck disable=SC1091
. "${LLM_DIR:-$HOME/llm}/common.sh"

port="$LLM_PORT"

case "${1:-}" in
    "")        preset=q6 ;;
    q6|Q6)     preset=q6 ;;
    q4|Q4)     preset=q4 ;;
    *) echo "unknown preset '$1' (expected q6 or q4)" >&2; exit 2 ;;
esac
[ $# -gt 0 ] && shift
[ $# -gt 0 ] && port="$1"

if tmux has-session -t "$LLM_SESSION" 2>/dev/null; then
    # Only a live server justifies attaching. A session with no server in it is
    # a dead pane (server was killed by hand) — clear it and start fresh.
    if pgrep -x llama-server >/dev/null; then
        echo "llama-server is already running (pid $(pgrep -x llama-server | tr '\n' ' '))."
        echo "Attaching to tmux session '$LLM_SESSION' — Ctrl-b d to detach."
        echo "If you meant to restart it, stop it first."
        exec tmux attach -t "$LLM_SESSION"
    fi
    echo "stale tmux session '$LLM_SESSION' with no server in it — removing."
    tmux kill-session -t "$LLM_SESSION"
fi

if pgrep -x llama-server >/dev/null; then
    echo "llama-server is already running outside tmux (pid $(pgrep -x llama-server | tr '\n' ' '))." >&2
    echo "Stop it with ./stop.sh first." >&2
    exit 1
fi

# -d detaches immediately; the server then runs in the background, logging to
# $LLM_LOGS. Attach whenever you want to watch it load.
tmux new-session -d -s "$LLM_SESSION" "$LLM_DIR/start.sh $preset $port"
echo "started '$preset' on port $port in tmux session '$LLM_SESSION'"
echo "  attach   tmux attach -t $LLM_SESSION    (Ctrl-b d to detach)"
echo "  status   ~/llm/status.sh"
echo "  log      tail -f $LLM_LOGS/${preset}-p${port}.log"
echo "  stop     ~/llm/down.sh"
