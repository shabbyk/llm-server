#!/usr/bin/env python3
"""Minimal client for the local Ollama server. Called by ask.sh.

Usage: ask.py <host> <port> <model> <thinking:true|false> <raw:true|false> <prompt>

Uses Ollama's native /api/chat rather than the OpenAI-compatible route, because
`think` is the documented switch for this and it lives in the native API. The
OpenAI route has a `reasoning_effort` parameter, but its behaviour for Qwen3.5
depends on the client implementation, while `think` is unambiguous.
"""

import json
import sys
import time
import urllib.error
import urllib.request

HOST, PORT, MODEL, THINKING, RAW, PROMPT = sys.argv[1:7]
THINKING = THINKING == "true"
RAW = RAW == "true"

payload = {
    "model": MODEL,
    "messages": [{"role": "user", "content": PROMPT}],
    # Qwen3.5 is a reasoning model: left alone it spends hundreds of tokens
    # thinking, and the useful answer can end up in the reasoning trace rather
    # than in "content". Off unless asked for.
    "think": THINKING,
    "stream": False,
}

req = urllib.request.Request(
    f"http://{HOST}:{PORT}/api/chat",
    data=json.dumps(payload).encode(),
    headers={"Content-Type": "application/json"},
)

started = time.monotonic()
try:
    with urllib.request.urlopen(req, timeout=900) as resp:
        body = json.load(resp)
except urllib.error.HTTPError as exc:
    sys.exit(f"HTTP {exc.code}: {exc.read().decode(errors='replace')[:500]}")
except urllib.error.URLError as exc:
    sys.exit(f"cannot reach {HOST}:{PORT} — is it up? Try: llm on  ({exc.reason})")

elapsed = time.monotonic() - started

if RAW:
    print(json.dumps(body, indent=2))
    sys.exit(0)

message = body.get("message") or {}
content = (message.get("content") or "").strip()
if not content:
    # Do not print an empty line and call it success: say what happened.
    thinking_text = (message.get("thinking") or "").strip()
    if thinking_text and not THINKING:
        content = "(empty content, but the model returned a reasoning trace — "\
                  "it may be thinking despite think=false)"
    else:
        content = "(no content in the response)"

print(content)

# Timings to stderr so piping stdout gives you just the answer.
eval_count = body.get("eval_count") or 0
eval_ns = body.get("eval_duration") or 0
prompt_count = body.get("prompt_eval_count") or 0
prompt_ns = body.get("prompt_eval_duration") or 0

parts = [f"wall {elapsed:.2f}s"]
if eval_count and eval_ns:
    parts.append(f"decode {eval_count / (eval_ns / 1e9):.1f} tok/s")
if prompt_count and prompt_ns:
    parts.append(f"prefill {prompt_count / (prompt_ns / 1e9):.0f} tok/s")
parts.append(f"{eval_count} out / {prompt_count} in")
print("  " + ", ".join(parts), file=sys.stderr)
