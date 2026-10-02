#!/usr/bin/env python3
"""Minimal client for the local LLM server. Called by ask.sh.

Usage: ask.py <host> <port> <model> <engine> <thinking:true|false> <raw:true|false> <prompt>

Two engines, two APIs, and the difference is not cosmetic:

  ollama     Uses the native /api/chat, because `think` is the documented switch
             for reasoning there. The OpenAI-compatible route also has a
             reasoning_effort parameter, but its behaviour for Qwen3.5 depends on
             the client implementation, while `think` is unambiguous.

  llamacpp   Uses the OpenAI-compatible /v1/chat/completions. There is no native
             reasoning switch; the equivalent is chat_template_kwargs, which is
             passed straight to the model's Jinja template. That template exposes
             `enable_thinking`, which is the same knob by another name.

Both are normalised to the same output, so callers cannot tell which ran.
"""

import json
import sys
import time
import urllib.error
import urllib.request

HOST, PORT, MODEL, ENGINE, THINKING, RAW, PROMPT = sys.argv[1:8]
THINKING = THINKING == "true"
RAW = RAW == "true"


def build_request() -> tuple[str, dict]:
    """The URL and payload for the selected engine."""
    if ENGINE == "llamacpp":
        return f"http://{HOST}:{PORT}/v1/chat/completions", {
            "model": MODEL,
            "messages": [{"role": "user", "content": PROMPT}],
            # Goes to the chat template, which turns it into the <think> block
            # (or its absence) that Qwen3.5 expects.
            "chat_template_kwargs": {"enable_thinking": THINKING},
            "stream": False,
            "temperature": 0.7,
        }
    return f"http://{HOST}:{PORT}/api/chat", {
        "model": MODEL,
        "messages": [{"role": "user", "content": PROMPT}],
        # Qwen3.5 is a reasoning model: left alone it spends hundreds of tokens
        # thinking, and the useful answer can end up in the reasoning trace rather
        # than in "content". Off unless asked for.
        "think": THINKING,
        "stream": False,
    }


def read_answer(body: dict) -> tuple[str, str]:
    """Return (content, thinking) from either engine's response shape."""
    if ENGINE == "llamacpp":
        # A reasoning model may put the trace in its own field, and older builds
        # reused `reasoning_content`; accept both spellings.
        choice = (body.get("choices") or [{}])[0]
        message = choice.get("message") or {}
        content = message.get("content") or ""
        thinking = message.get("reasoning_content") or message.get("reasoning") or ""
        return content.strip(), thinking.strip()
    message = body.get("message") or {}
    return (message.get("content") or "").strip(), (message.get("thinking") or "").strip()


def read_timings(body: dict) -> tuple[int, float, int, float]:
    """Return (out_tokens, decode_tok_s, in_tokens, prefill_tok_s).

    Normalised from Ollama's duration fields and llama.cpp's timings block. Zero
    means "not reported", and the caller then omits the figure rather than
    printing a fabricated one.
    """
    if ENGINE == "llamacpp":
        t = body.get("timings") or {}
        out_n = int(t.get("predicted_n") or 0)
        decode = float(t.get("predicted_per_second") or 0)
        in_n = int(t.get("prompt_n") or 0)
        prefill = float(t.get("prompt_per_second") or 0)
        # llama.cpp reports ms, not ns, and only sometimes the rate. Derive it.
        if not decode and t.get("predicted_ms"):
            decode = out_n / (float(t["predicted_ms"]) / 1000)
        if not prefill and t.get("prompt_ms"):
            prefill = in_n / (float(t["prompt_ms"]) / 1000)
        return out_n, decode, in_n, prefill

    out_n = int(body.get("eval_count") or 0)
    out_ns = int(body.get("eval_duration") or 0)
    in_n = int(body.get("prompt_eval_count") or 0)
    in_ns = int(body.get("prompt_eval_duration") or 0)
    return (
        out_n,
        out_n / (out_ns / 1e9) if out_ns else 0.0,
        in_n,
        in_n / (in_ns / 1e9) if in_ns else 0.0,
    )


url, payload = build_request()
req = urllib.request.Request(
    url,
    data=json.dumps(payload).encode(),
    headers={"Content-Type": "application/json"},
)

started = time.monotonic()
try:
    with urllib.request.urlopen(req, timeout=900) as resp:
        body = json.load(resp)
except urllib.error.HTTPError as exc:
    detail = exc.read().decode(errors="replace")[:500]
    sys.exit(f"HTTP {exc.code}: {detail}")
except urllib.error.URLError as exc:
    sys.exit(f"cannot reach {HOST}:{PORT} — is it up? Try: llm on  ({exc.reason})")

elapsed = time.monotonic() - started

if RAW:
    print(json.dumps(body, indent=2))
    sys.exit(0)

content, thinking_text = read_answer(body)
if not content:
    # Do not print an empty line and call it success: say what happened.
    if thinking_text and not THINKING:
        content = ("(empty content, but the model returned a reasoning trace — "
                   "it may be thinking despite thinking being off)")
    elif thinking_text:
        content = "(no content; the whole response is in the reasoning trace)"
    else:
        content = "(no content in the response)"

print(content)

# Timings to stderr so piping stdout gives you just the answer.
out_n, decode, in_n, prefill = read_timings(body)
parts = [f"wall {elapsed:.2f}s"]
if decode:
    parts.append(f"decode {decode:.1f} tok/s")
if prefill:
    parts.append(f"prefill {prefill:.0f} tok/s")
parts.append(f"{out_n} out / {in_n} in")
print("  " + ", ".join(parts), file=sys.stderr)
