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
# Works against either engine, picking the API each one actually implements.
# Every run gets a unique prompt prefix, so prompt caching cannot make prefill
# look faster than it is.
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
echo "  engine: $LLM_ENGINE"
echo "  url:    $(llm_url)"
echo "  prompt: ~$WORDS words"
echo

python3 - "$LLM_HOST" "$LLM_PORT" "$LLM_MODEL" "$LLM_ENGINE" "$RUNS" "$PROMPT" <<'PY'
import json, sys, time, urllib.request

host, port, model, engine, runs, prompt = (
    sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], int(sys.argv[5]), sys.argv[6])

# Each engine has its own API, and its own idea of what timing looks like.
if engine == "llamacpp":
    url = f"http://{host}:{port}/completion"

    def payload(seed):
        return {"prompt": seed + prompt, "n_predict": 32, "temperature": 0,
                "stream": False,
                # Otherwise runs 2..n reuse the cached prefix and prefill collapses
                # to near zero, which flatters the engine instead of measuring it.
                "cache_prompt": False}

    def timings(d):
        t = d.get("timings") or {}
        in_n = int(t.get("prompt_n") or 0)
        out_n = int(t.get("predicted_n") or 0)
        p = float(t.get("prompt_per_second") or 0)
        e = float(t.get("predicted_per_second") or 0)
        if not p and t.get("prompt_ms"):
            p = in_n / (float(t["prompt_ms"]) / 1000)
        if not e and t.get("predicted_ms"):
            e = out_n / (float(t["predicted_ms"]) / 1000)
        return in_n, out_n, p, e
else:
    url = f"http://{host}:{port}/api/generate"

    def payload(seed):
        return {"model": model, "prompt": seed + prompt, "stream": False,
                "options": {"num_predict": 32, "temperature": 0}}

    def timings(d):
        in_n = int(d.get("prompt_eval_count") or 0)
        in_ns = int(d.get("prompt_eval_duration") or 0)
        out_n = int(d.get("eval_count") or 0)
        out_ns = int(d.get("eval_duration") or 0)
        return (in_n, out_n,
                in_n / (in_ns / 1e9) if in_ns else 0.0,
                out_n / (out_ns / 1e9) if out_ns else 0.0)

pre, dec = [], []
for i in range(runs + 1):
    # A unique prefix per run, so prompt caching cannot hide the prefill cost.
    # The nonce goes at the front: caching is by prefix, so a suffix change would
    # still let the shared beginning be skipped.
    seed = f"[run {i}, nonce {time.time_ns()}]\n"
    req = urllib.request.Request(url, data=json.dumps(payload(seed)).encode(),
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

    in_n, out_n, p, e = timings(d)
    pre.append(p); dec.append(e)
    print(f"  run {i}: prefill {p:6.0f} tok/s   decode {e:5.1f} tok/s   "
          f"wall {wall:5.2f}s   ({in_n} in / {out_n} out)")

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
