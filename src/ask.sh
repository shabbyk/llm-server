#!/usr/bin/env bash
# Ask the running server a question.
#
#   ./ask.sh "why is the sky blue"      # direct answer, thinking OFF (default)
#   ./ask.sh -t "plan a refactor"       # thinking ON (slower, burns tokens)
#   ./ask.sh -j "..."                   # dump the raw JSON response
#   ./ask.sh -m qwen3.5:27b "..."       # use a different model for this call
#
# Thinking is disabled by default because Qwen3.5 has it on by default: it will
# spend hundreds of tokens reasoning, and the answer can land in the reasoning
# trace rather than in "content". Pass -t when you actually want that.

set -euo pipefail
# shellcheck disable=SC1091
# Resolve through symlinks first: the installer links this into ~/.local/bin,
# and BASH_SOURCE would otherwise name the link rather than the script.
LLM_SRC="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
. "$LLM_SRC/common.sh"

thinking=false
raw=false
model="$LLM_MODEL"

while [ $# -gt 0 ]; do
    case "$1" in
        -t|--thinking) thinking=true; shift ;;
        -j|--json)     raw=true; shift ;;
        -m|--model)    model="$2"; shift 2 ;;
        -h|--help)     sed -n '2,/^$/p' "$0" | sed -e 's/^#\{1,\} \{0,1\}//' -e '/^$/d'; exit 0 ;;
        -*)            echo "unknown flag: $1" >&2; exit 2 ;;
        *)             break ;;
    esac
done

if [ $# -eq 0 ]; then
    echo "usage: ./ask.sh [-t] [-j] [-m model] \"your prompt\"" >&2
    exit 2
fi

# Pure HTTP client: it needs nothing from the GPU. The render group is the
# *server's* requirement, not the caller's.
exec python3 "$LLM_SRC/ask.py" "$LLM_HOST" "$LLM_PORT" "$model" "$thinking" "$raw" "$1"
