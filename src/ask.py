#!/usr/bin/env python3
"""Minimal client for the local llama.cpp server. Called by ask.sh.

Usage: ask.py <host> <port> <thinking:true|false> <raw:true|false> <prompt>
"""

import json
import sys
import time
import urllib.error
import urllib.request

HOST, PORT, THINKING, RAW, PROMPT = sys.argv[1:6]
THINKING = THINKING == "true"
RAW = RAW == "true"

payload = {
    "model": "local",
    "messages": [{"role": "user", "content": PROMPT}],
    # Qwen3.5's chat template reads this; without it the model thinks by
    # default and can return an empty "content". This is the documented
    # mechanism (tools/server/README.md, "chat_template_kwargs").
    #
    # Note there is also a --reasoning-budget *server* flag, but it is not a
    # request field. Do not add "reasoning_budget" here.
    "chat_template_kwargs": {"enable_thinking": THINKING},
}

req = urllib.request.Request(
    f"http://{HOST}:{PORT}/v1/chat/completions",
    data=json.dumps(payload).encode(),
    headers={"Content-Type": "application/json"},
)

started = time.monotonic()
try:
    with urllib.request.urlopen(req, timeout=600) as resp:
        body = json.load(resp)
except urllib.error.HTTPError as exc:
    sys.exit(f"HTTP {exc.code}: {exc.read().decode(errors='replace')[:500]}")
except urllib.error.URLError as exc:
    sys.exit(
        f"cannot reach the server at {HOST}:{PORT} — {exc.reason}\n"
        f"is it running? (try: llm on)"
    )

elapsed = time.monotonic() - started

if RAW:
    print(json.dumps(body, indent=2))
    sys.exit()

msg = body["choices"][0]["message"]
text = msg.get("content") or ""
reasoning = msg.get("reasoning_content") or ""

if reasoning:
    print("--- reasoning ---")
    print(reasoning.rstrip())
    print("--- answer ---")
if not text.strip():
    print("(empty content — the model put everything in reasoning; try -t)")
print(text.rstrip())

usage = body.get("usage", {})
tokens = usage.get("completion_tokens")
rate = f"{tokens / elapsed:.1f}" if tokens else "?"
print(
    f"\n[{tokens if tokens else '?'} tok, {elapsed:.2f}s, {rate} tok/s]",
    file=sys.stderr,
)
