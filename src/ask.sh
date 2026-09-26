#!/usr/bin/env bash
# Ask the running server a question.
#
#   ./ask.sh "why is the sky blue"      # direct answer, thinking OFF (default)
#   ./ask.sh -t "plan a refactor"       # thinking ON (slower, burns tokens)
#   ./ask.sh -j "..."                   # dump the raw JSON response
#   ./ask.sh -m 9090 "..."              # temporarily use a different port
#
# Thinking is disabled by default because Qwen3.5 has it on by default: it will
# spend 300+ tokens reasoning and often leave "content" empty while the reply
# lives in "reasoning_content". Pass -t when you actually want that.

set -euo pipefail
# shellcheck disable=SC1091
. "${LLM_DIR:-$HOME/llm}/common.sh"

thinking=false
raw=false
port="$LLM_PORT"

while [ $# -gt 0 ]; do
    case "$1" in
        -t|--thinking) thinking=true; shift ;;
        -j|--json)    raw=true; shift ;;
        -m|--port)    port="$2"; shift 2 ;;
        -h|--help)    sed -n '2,/^$/p' "$0" | sed -e 's/^#\{1,\} \{0,1\}//' -e '/^$/d'; exit 0 ;;
        -*)           echo "unknown flag: $1" >&2; exit 2 ;;
        *)            break ;;
    esac
done

if [ $# -eq 0 ]; then
    echo "usage: ./ask.sh [-t] [-j] [-m port] \"your prompt\"" >&2
    exit 2
fi

# No render-group shim here on purpose: this is a pure HTTP client. The render
# group is the *server's* requirement, not the caller's.
exec python3 "$LLM_DIR/ask.py" "$LLM_HOST" "$port" "$thinking" "$raw" "$1"
