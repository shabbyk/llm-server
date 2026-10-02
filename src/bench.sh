#!/usr/bin/env bash
# Measure the server against a realistic prompt.
#
#   ./bench.sh            # the default prompt, 3 runs
#   ./bench.sh 5          # 5 runs
#   ./bench.sh 3 800      # 3 runs, ~800 word prompt
#
# Measures through the HTTP API, so the numbers are what you actually get —
# not a synthetic kernel benchmark. That distinction mattered on the previous
# llama.cpp build, where `llama-bench` reported 36.4 tok/s for Q4_K_M against a
# real 21.3, because it spreads a fixed warmup cost over very few tokens.
#
# Decode (tokens out per second) is the number you feel. Prefill (prompt tokens
# per second) is what long agentic system prompts pay.

set -uo pipefail
# shellcheck disable=SC1091
# Resolve through symlinks first: the installer links this into ~/.local/bin,
# and BASH_SOURCE would otherwise name the link rather than the script.
LLM_SRC="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
. "$LLM_SRC/common.sh"

RUNS="${1:-3}"
WORDS="${2:-800}"

llm_serving || { echo "bench: the server is not answering on $(llm_url)" >&2
                 echo "       start it with: llm on" >&2; exit 1; }

# A prompt of roughly the requested length, so prefill is measured rather than
# warmup. The previous build's benchmark flattered small models for exactly the
# opposite reason.
PROMPT="$(python3 - "$WORDS" <<'PY'
import sys
words = int(sys.argv[1])
sentence = ("The quick brown fox jumps over the lazy dog near the riverbank "
            "while the afternoon light fades across the valley. ")
print((sentence * (words // 16 + 1)).split()[:words] and
      " ".join((sentence * (words // 16 + 1)).split()[:words]))
PY
)"
PROMPT="$PROMPT Reply with only the word: done"

echo "  model:  $LLM_MODEL"
echo "  url:    $(llm_url)"
echo "  prompt: ~$WORDS words"
echo

python3 - "$LLM_HOST" "$LLM_PORT" "$LLM_MODEL" "$RUNS" "$PROMPT" <<'PY'
import json, sys, time, urllib.request

host, port, model, runs, prompt = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), sys.argv[5]
url = f"http://{host}:{port}/api/generate"

pre, dec = [], []
for i in range(runs + 1):
    payload = {
        "model": model,
        "prompt": prompt,
        "stream": False,
        "options": {"num_predict": 32, "temperature": 0},
    }
    req = urllib.request.Request(url, data=json.dumps(payload).encode(),
                                 headers={"Content-Type": "application/json"})
    t0 = time.monotonic()
    with urllib.request.urlopen(req, timeout=900) as r:
        d = json.load(r)
    wall = time.monotonic() - t0

    if i == 0:
        # Discard the first run: it pays the model-load and cache-warm cost,
        # which is exactly what made the previous build's benchmark flatter the
        # numbers. Reporting it would overstate prefill by an order of magnitude.
        print(f"  warmup: prefill paid the load cost, discarded ({wall:.2f}s)")
        continue

    pc, pns = d.get("prompt_eval_count", 0), d.get("prompt_eval_duration", 0)
    ec, ens = d.get("eval_count", 0), d.get("eval_duration", 0)
    p = pc / (pns / 1e9) if pns else 0
    e = ec / (ens / 1e9) if ens else 0
    pre.append(p); dec.append(e)
    print(f"  run {i}: prefill {p:6.0f} tok/s   decode {e:5.1f} tok/s   "
          f"wall {wall:5.2f}s   ({pc} in / {ec} out)")

if pre and dec:
    print()
    print(f"  mean:   prefill {sum(pre)/len(pre):6.0f} tok/s   "
          f"decode {sum(dec)/len(dec):5.1f} tok/s")
PY

echo
echo "  processor: $(llm_processor)"
mem="$(llm_gpu_mem)"
[ -n "${mem:-}" ] && echo "  gpu mem:   ${mem}"
echo
echo "  Note: a GPU figure is only meaningful next to the processor line above."
echo "  A CPU load reports plausible numbers and looks like a slow model."
