# Local LLM server (llama.cpp + Vulkan) with an on/off switch

Runs Qwen3.5-9B locally on a single consumer GPU and serves it as an
OpenAI-compatible API. No container, no service manager, no daemon that starts
itself. You get a switch:

```sh
llm on      # start, and wait until it can actually serve
llm off     # stop, and confirm the GPU was released
llm         # status
```

Deliberately **not** Ollama: its ROCm build omits `gfx1032` (RX 6600), and it has
no Vulkan runner. llama.cpp ships a Vulkan backend that covers AMD, Intel and
Apple Silicon with the same binary.

Verified on Ubuntu 26.04 with a Ryzen 5 5600X and an RX 6600 (8 GB), Mesa 26.0.8,
Vulkan 1.4.335, llama.cpp build b11146.

## Requirements

- Linux, x86-64 or arm64
- A GPU with a working Vulkan driver (AMD/Intel via Mesa, or NVIDIA with the
  proprietary ICD installed separately)
- ~13 GB of disk for both quantisations
- `sudo` available for package installation and group membership

## Quick start

```sh
git clone <this-repo> llm-server
cd llm-server
./install.sh
```

Then:

```sh
llm on
llm on && ~/llm/ask.sh "say hello"
```

`install.sh` is idempotent — re-run it to add the other model or change the
pinned llama.cpp build.

```
--dir PATH        install somewhere other than ~/llm
--build TAG       llama.cpp release tag, or "latest" (default: b11146)
--models q6|q4    fetch only one quantisation (~7.5 GB / ~5.7 GB)
--skip-models     set up the plumbing, fetch models later
--skip-deps       don't touch system packages
--uninstall       remove the switch, scripts, and (with confirmation) the models
```

## The switch

| command | effect |
| --- | --- |
| `llm on [q6\|q4] [port]` | start, block until `/health` returns 200 |
| `llm off` | stop, then report VRAM **and** GTT after release |
| `llm toggle [q6\|q4]` | off if running, on if not |
| `llm restart [q6\|q4]` | off, then on |
| `llm status` | process, GPU memory, RAM, health |
| `llm log` | tail the current log |
| `llm watch` | attach to the tmux session (Ctrl-b d to detach) |
| `llm help` | everything else |

`llm on` waits for readiness rather than returning as soon as the process
exists. The model takes several seconds to load and `/health` answers 200
before that finishes, so the wait polls `/health` and treats the tmux session as
the liveness signal — judging by `pgrep -x llama-server` fails, because the
start chain (`bash → start.sh → llm-run → newgrp → llama-server`) has no process
by that name for the first ~100 ms, and the check gives up in under 100 ms.

Nothing starts automatically. After a reboot it stays off until you say so.
There is no systemd unit, no crontab entry, and no `.profile` hook.

## Measured performance

RX 6600, Ryzen 5 5600X, 12 threads, ctx 16384, KV cache `q8_0`/`q8_0`,
`-ngl 99`, flash-attn on, llama.cpp b11146:

| model | size | prefill | decode |
| --- | --- | --- | --- |
| Qwen3.5-9B Q6_K | 7.46 GB | 388 t/s | **19.0 tok/s** |
| Qwen3.5-9B Q4_K_M | 5.68 GB | 468–573 t/s | **21.3 tok/s** |

These are server-measured over ~310-token replies (`ask.sh` prints tok/s on
stderr). Taken at ctx 16384; decode is unaffected by context length, since the
KV cache is allocated once and does not sit in the decode path. Numbers scale
roughly with memory bandwidth, so expect proportionally
different figures on other cards.

**Do not quote `llama-bench` decode numbers.** It amortises a fixed warmup cost
over however many tokens you request, which flatters the smaller quant most:

| model | `-n 128` | `-n 512` | live server (~310 tok) |
| --- | --- | --- | --- |
| Q4_K_M | 36.4 | 28.5 | 21.3 |
| Q6_K | 19.0 | — | 19.0 |

The Q4_K_M reading of 36.4 tok/s implies ~203 GB/s of effective bandwidth
against the card's 224 GB/s peak — not achievable for RDNA2 in practice, and
that arithmetic is what exposed the problem. The Q6_K numbers happened to agree
at `-n 128`, which hid the issue. `bench.sh` is kept for prefill and for
`--list-devices`; use the live server for anything you plan to quote.

## Configuration

`~/llm/config.env`, plain shell. Precedence is **defaults < config.env <
environment**, so `LLM_PORT=9090 llm on` overrides the file.

Every assignment in that file uses `${VAR:=default}` rather than `VAR=default`,
which is what makes the environment win. If you add a setting, use the same
form — a bare assignment silently makes the file unbeatable.

| setting | default | notes |
| --- | --- | --- |
| `LLM_HOST` | detected LAN address | `127.0.0.1` for tunnel-only |
| `LLM_PORT` | 8080 | |
| `LLM_CTX` | 32768 | see below |
| `LLM_THREADS` | `nproc` | more than physical cores rarely helps |
| `LLM_NGL` | 99 | offload everything |
| `LLM_RENDER_GROUP_NAME` | render | group owning `/dev/dri/renderD*` |
| `LLM_SESSION` | llm | tmux session name |

### Context length

KV cache costs roughly **17 MiB per 1024 tokens** at `q8_0` for this model, and
it does not slow decode — it only adds prefill time on very long prompts. Load
was verified at 16384 (272 MiB), 24576 (408 MiB) and 32768 (544 MiB). The model's
`n_ctx_train` is 262144.

Exceeding capacity is an out-of-memory error at startup, not a slowdown. Pick
against the smaller of VRAM and the GTT aperture (see below), not VRAM alone.

The default is 32768 because agentic clients need it. OpenCode's system prompt
and tool definitions measure **6619 tokens**, sent on every request before you
type anything, so a 16384 window leaves almost nothing for the conversation.
32768 is the ceiling on an 8 GB card, not a preference — it needs 8002 MiB
against an 8069 MiB GTT aperture. If it will not load, use 24576; if you are
only calling from scripts and not an agent, 16384 is fine.

## GPU memory: why the counters lie

On amdgpu the model buffer can be backed by either VRAM or GTT (an aperture over
system RAM), **and it migrates between the two while the process runs**. One
server here read 7.13 GB of VRAM at startup, 6.92 GB mid-generation, and 0.02 GB
later — same uninterrupted pid, same 19 tok/s throughout.

So `mem_info_vram_used` is neither a residency nor a capacity signal. Both
`status.sh` and `llm off` report VRAM and GTT side by side, and neither is
treated as proof of anything.

The only trustworthy check is throughput:

- **~19 tok/s** — the GPU is doing the work
- **~4.5 tok/s** — it silently fell back to the CPU

Performance is unaffected by where the buffer lives (18.6 tok/s while in VRAM vs
19.0 while in GTT). The GTT aperture (8.07 GB here) is the tighter ceiling, so
it is the number to size against.

Also note: at the default verbosity llama.cpp b11146 prints neither the device
selection nor the offload lines, so a quiet log does **not** mean CPU fallback.
Add `-lv 4` to `start.sh` to see `offloaded 33/33 layers to GPU`.

## Troubleshooting

**`libgomp.so.1 => not found`.** Install `libgomp1`. Not optional, and the
error is bare enough to be easy to miss. `install.sh` includes it and checks
with `ldd` after unpacking.

**Vulkan reports no device, or the server runs at ~4.5 tok/s.** Almost always
group membership. `/dev/dri/renderD128` is `root:render 0660`, and
`usermod -aG` only affects *new* login sessions — a shell opened before the
change still gets `EACCES`. `llm-run` bridges that window by re-execing under
`newgrp`, which is setgid-root and therefore the only way a non-root user can
pick up a supplementary group without a fresh login. (`setpriv --init-groups`
cannot: `setgroups(2)` needs `CAP_SETGID`.) It self-disables once a login has
picked the group up naturally. Check with `llm status`, which measures
throughput rather than trusting a counter.

**Nothing at all is in the log about the GPU.** Expected — see above, use `-lv 4`.

**`common_fit_params: ... n_gpu_layers already set by user to 99, abort` and
`cannot meet free memory target of 1024 MiB`.** Both benign.

**`/health` returns 200 but requests fail.** The server answers `/health`
before the model finishes loading. `llm on` handles this by polling, but a raw
`curl` immediately after starting may catch it mid-load.

**Web UI returns 415 on `/`.** Only `curl` without `Accept-Encoding`. Use
`curl --compressed`.

**`llm on` hangs.** Check `llm log`. A port clash is the usual cause —
`status.sh` prints the full argv, which includes the port.

**The server vanished and `tmux ls` says "no server running".** The process is
not wedged, it exited cleanly — the log ends with `cleaning up before exit...`
and nothing before it. That is what a `SIGTERM` looks like, and the usual source
is the tmux *server* dying rather than the session being killed, which takes
`llama-server` down with it. There is nothing to restart it by design, so re-run
`llm on`. If it keeps happening, the box is likely reclaiming a session
(`loginctl terminate-user`, an idle-logout policy); check
`loginctl list-sessions` and `journalctl -u user@$UID.service`.

**A first request after `llm on` takes ~18 s, the second takes under 1 s.**
Expected. The weights are cold and amdgpu is still migrating the model buffer
into place. Prefill on the second request runs at ~200 tok/s.

**`llm on` ignores `LLM_CTX` set in the calling shell.** The tmux server is
long-lived, and a new session inherits the *server's* environment, not yours.
Set it in `config.env`.

## Security

There is no API key and no authentication, and the server binds to a LAN
address. Anything that can route to the host can use it and read the models.
That is a reasonable trade on a trusted home network and a bad one anywhere
else. `llm status` prints a CORS warning on startup for the same reason.

Before it leaves a trusted network, either set `LLM_HOST=127.0.0.1` and tunnel,
or put a reverse proxy with authentication in front of it.

## Layout

```
install.sh              one-shot installer
config.env.example      every setting, documented
src/common.sh           config, host detection, DRM helpers
src/llm-run             render-group shim (self-disabling)
src/llm                 the switch
src/up.sh down.sh       tmux lifecycle
src/start.sh stop.sh    process lifecycle
src/status.sh           state + GPU memory
src/ask.sh ask.py       HTTP client (thinking off by default)
src/bench.sh            llama-bench wrapper
```

Models land in `~/llm/models/`, logs in `~/llm/logs/`, binaries in
`~/llm/llama/`. None of those are in git.

## Why thinking is off by default

Qwen3.5 has thinking on by default. Left alone it will spend 300+ tokens
reasoning and often return an empty `content` while the real answer sits in
`reasoning_content` — which reads as a broken server. `ask.sh` passes
`chat_template_kwargs: {enable_thinking: false}`; `ask.sh -t` opts in.

There is also a `--reasoning-budget` *server* flag. It is not a request field —
do not send `reasoning_budget` in the JSON.

## OpenCode

The server speaks plain OpenAI chat completions, so any client works. OpenCode
is the one worth documenting, because two of its settings have to agree with the
server's or sessions break in confusing ways.

Config lives in `~/.config/opencode/opencode.json`. This is verified working
against OpenCode v2:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "providers": {
    "llamacpp": {
      "package": "@opencode/ai/providers/openai-compatible",
      "name": "llama.cpp (local)",
      "settings": {
        "baseURL": "http://192.168.1.50:8080/v1"
      },
      "body": {
        "chat_template_kwargs": {
          "enable_thinking": false
        }
      },
      "models": {
        "qwen3.5-9b-q6": {
          "name": "Qwen3.5 9B Q6_K",
          "modelID": "~/llm/models/Qwen3.5-9B-Q6_K.gguf",
          "limit": {
            "context": 32768,
            "output": 4096
          }
        }
      }
    }
  }
}
```

Then restart the config reader — OpenCode loads this from a background service,
so an edit often appears to do nothing until you do:

```sh
opencode service restart
```

Select it as `llamacpp/qwen3.5-9b-q6`, i.e. provider ID and model key.

Replace three things: the IP, the `modelID` path, and the model key. See
[Getting the model id](#getting-the-model-id) — the path above is a placeholder
with a `~` in it, and **`~` is not expanded inside a JSON value**, so copy the
literal path from your own `/v1/models` rather than typing that string.

### The two limits, and why they must match `LLM_CTX`

| setting | where | what it does |
| --- | --- | --- |
| `LLM_CTX` | `config.env`, passed as `--ctx-size` | **Allocates the KV cache.** 544 MiB at 32768. llama.cpp enforces it. |
| `limit.context` | `opencode.json` | **A belief, not an allocation.** OpenCode's arithmetic for when to compact. |
| `limit.output` | `opencode.json` | The slice of the window held back for the reply. |

`limit.context` does not grow the server. If the client believes in a larger
window than the server allocated, requests get rejected or truncated partway
through a reply, which looks like the model going silent. If the client believes
in a smaller one, it compacts early and wastes capacity you already paid for.
Keep all three equal.

OpenCode reserves `output` before sending, so the room left for input is:

```
usable input  =  context  −  output
```

The catch is that OpenCode's own system prompt and tool definitions measure
**6619 tokens**, sent on every request before you type anything. That is a fixed
tax, and it is why the two configurations behave so differently:

| context | output | input budget | minus 6619 | result |
| --- | --- | --- | --- | --- |
| 16384 | 8192 | 8192 | **1573** | compacts almost immediately |
| 32768 | 4096 | 28672 | **22053** | usable |

So **if a session compacts the moment it starts, `output` is the knob, not
`context`.** Reserving 8192 on a 16384 window leaves less input room than
OpenCode's own prompt occupies. A 9B at 19 tok/s needs 215 s to emit 4096
tokens, so a large output reserve is headroom you pay for on every request and
can never use. If replies get cut off mid-edit instead, drop `output` to 3072.

### Getting the model id

`GET /v1/models` is the authoritative answer:

```sh
curl -s http://192.168.1.50:8080/v1/models | jq -r '.data[].id'
```

It returns an absolute path, for example:

```
/home/you/llm/models/Qwen3.5-9B-Q6_K.gguf
```

because llama.cpp b11146 has no `--alias` flag, so the id is derived from the
file path. That is expected, not a misconfiguration. Copy it verbatim — no `~`,
because nothing expands it inside JSON.

**This server does not validate the `model` field.** Any string is accepted —
`totally-made-up-name` works — so a mismatch will not produce an error, unlike on
stricter OpenAI-compatible servers. That makes the id optional polish: set
`modelID` (v2) or the model key (v1) to the value above if you want the client's
picker to line up with `/v1/models`, but a short friendly key like
`qwen3.5-9b-q6` is easier to type and works identically.

### OpenCode v1

v1 uses a different shape — `provider` singular, `npm`, `options` — and has
**no provider-level `body` field**, so thinking cannot be turned off from config:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "llamacpp": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "llama.cpp (local)",
      "options": {
        "baseURL": "http://192.168.1.50:8080/v1"
      },
      "models": {
        "qwen3.5-9b-q6": {
          "name": "Qwen3.5 9B Q6_K",
          "limit": { "context": 32768, "output": 4096 }
        }
      }
    }
  }
}
```

The model key is sent straight through as `model` — there is no `modelID` in v1.
Expect thinking to be on, which costs about 13.7 s instead of 0.4 s for a short
answer, plus reasoning text that lands in `reasoning_content` rather than
`content`. Upgrading to v2 is the fix; there is no v1 workaround.

### Token costs, measured

Counted with the model's own tokenizer, not estimated:

| | |
| --- | --- |
| 4096 tokens of English | ~3,450 words (~7 double-spaced pages) |
| 4096 tokens of shell | ~300 lines |
| OpenCode system prompt + tools | 6,619 |
| a typical ~900-token source file | ~900 |

Code runs about 60% denser in tokens than the same word count of prose, so
output budgets get consumed faster than they look.

## License

MIT — see [LICENSE](LICENSE).
