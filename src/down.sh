#!/usr/bin/env bash
# Stop the server and tear down the tmux session.

set -uo pipefail
# shellcheck disable=SC1091
. "${LLM_DIR:-$HOME/llm}/common.sh"

"$LLM_DIR/stop.sh"

if tmux has-session -t "$LLM_SESSION" 2>/dev/null; then
    tmux kill-session -t "$LLM_SESSION"
    echo "tmux session '$LLM_SESSION' closed."
fi
