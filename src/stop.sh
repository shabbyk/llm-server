#!/usr/bin/env bash
# Stop the running llama-server: SIGTERM, then SIGKILL if it ignores us.
#
# The wait matters. SIGTERM makes llama-server release its GPU allocations, but
# it is not instantaneous, and benchmarking or immediately restarting in that
# window measures a machine that is still giving memory back.

set -uo pipefail
# shellcheck disable=SC1091
. "${LLM_DIR:-$HOME/llm}/common.sh"

# -x, never -f: this script's own argv is "stop.sh" so it cannot self-match, but
# -f would still match the grep in status.sh and any editor you run from here.
pids="$(pgrep -x llama-server || true)"
if [ -z "$pids" ]; then
    echo "llama-server is not running."
    exit 0
fi

echo "stopping llama-server: $(echo "$pids" | tr '\n' ' ')"
kill $pids

for _ in $(seq 1 20); do
    pgrep -x llama-server >/dev/null || { echo "stopped."; exit 0; }
    sleep 0.5
done

echo "did not exit in 10s, sending SIGKILL"
kill -9 $pids 2>/dev/null
sleep 1
pgrep -x llama-server >/dev/null && { echo "still running: $(pgrep -x llama-server | tr '\n' ' ')" >&2; exit 1; }
echo "killed."
