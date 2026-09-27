# Local LLM server (llama.cpp + Vulkan) with an on/off switch

Runs Qwen3.5-9B on one consumer GPU and serves it as an OpenAI-compatible API.
No container, no service manager, nothing that starts on its own.

```sh
llm on      # start, and wait until it can actually serve
llm off     # stop, and confirm the GPU was released
llm         # status
```

Not Ollama on purpose. Its ROCm build leaves out `gfx1032`, which is the RX 6600,
and it has no Vulkan runner. llama.cpp ships one Vulkan backend that covers AMD,
Intel and Apple Silicon with the same binary.

Tested on Ubuntu 26.04, Ryzen 5 5600X, RX 6600 (8 GB), Mesa 26.0.8,
Vulkan 1.4.335, llama.cpp b11146. Debian 13 and 12 work too, with one extra step
— see [Debian](#debian).

## Requirements

- Linux, x86-64 or arm64
- A GPU with a working Vulkan driver
- ~13 GB of disk for both quantisations
- `sudo` available for packages and group membership

## Debian

Works, with two things to sort out first.

**Use Debian 13 (trixie) or 12 (bookworm).** Debian 11 is too old. There is no
Debian build of llama.cpp, so this downloads the Ubuntu one, and that binary
needs glibc 2.34 — bookworm has 2.36, bullseye only has 2.31, and it will not
run.

**Turn on `non-free-firmware` before installing.** On Debian the GPU firmware
lives there rather than inside `linux-firmware` as it does on Ubuntu, and without
it an RX 6000-series card can fail to start properly. Substitute your own suite
for `trixie` below — do not paste a different suite onto your system:

```sh
echo "deb http://deb.debian.org/debian trixie main contrib non-free non-free-firmware" \
  | sudo tee /etc/apt/sources.list.d/non-free.list
sudo apt update
```

`install.sh` installs `firmware-amd-graphics` for you and warns if it could not.

Check the blobs landed, because this is the one thing that quietly goes wrong:

```sh
ls /lib/firmware/amdgpu/gc_11_0_3*
```

Seven files should be listed. If nothing comes back, the card is on the wrong
firmware, and the check above is how you know. Bookworm is reported to ship a
`firmware-amd-graphics` too old to carry these, so on bookworm expect to need
`bookworm-backports`. Trixie carries a current one and should be fine as-is.

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

`install.sh` is safe to re-run. Use it to add the other model, or to move to a
newer llama.cpp build.

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
| `llm on [q6\|q4] [port]` | start, block until it can actually answer |
| `llm off` | stop, then report VRAM **and** GTT after release |
| `llm toggle [q6\|q4]` | off if running, on if not |
| `llm restart [q6\|q4]` | off, then on |
| `llm status` | process, GPU memory, RAM, speed |
| `llm log` | tail the current log |
| `llm watch` | attach to the tmux session (Ctrl-b d to detach) |
| `llm help` | everything else |

`llm on` waits until the model can really serve. That takes a few seconds, and
the health check reports ready too early, so `llm on` polls for the real thing
instead of trusting it.

Nothing starts on its own. After a reboot it stays off until you run `llm on`.
No systemd unit, no crontab entry, no `.profile` hook.

## Speed

RX 6600, Ryzen 5 5600X, llama.cpp b11146:

| model | size | prefill | decode |
| --- | --- | --- | --- |
| Qwen3.5-9B Q6_K | 7.46 GB | 388 t/s | **19.0 tok/s** |
| Qwen3.5-9B Q4_K_M | 5.68 GB | 468–573 t/s | **21.3 tok/s** |

Prefill is reading your prompt, decode is writing the answer. Decode is the
number you actually feel, and it mostly follows memory bandwidth.

Measured on the running server, not with `llama-bench`. `llama-bench` flatters
the smaller quant badly. It reported 36.4 tok/s for Q4_K_M against a real 21.3,
because it spreads a fixed warmup cost over very few tokens. `ask.sh` prints the
honest figure on stderr.

## Configuration

`~/llm/config.env`, plain shell. Precedence is **defaults < config.env <
environment**, so `LLM_PORT=9090 llm on` beats the file.

Use the `${VAR:=default}` form in that file, not `VAR=default`. A bare
assignment makes the file unbeatable and quietly turns that order upside down.

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

Bigger context costs memory, roughly 17 MiB per 1024 tokens. It does not slow
answers down.

32768 is the default because agent clients need it. OpenCode sends about 6600
tokens of its own instructions and tool definitions before you type anything, so
a 16384 window leaves almost nothing for the actual conversation.

32768 is the ceiling on an 8 GB card, not a preference. If it will not load, use
24576. If you are only calling from scripts, 16384 is fine. Going over the limit
fails at startup instead of running slow.

Set `LLM_CTX` in `config.env`, not in your shell. The long-lived tmux server
passes its own environment to new sessions, so a value you export is ignored.

## GPU memory counters lie

On AMD cards the model can sit in VRAM or spill into system RAM through an
aperture the driver calls GTT, and it moves between the two while it runs. The
same server read 7.13 GB of VRAM at startup and 0.02 GB a moment later. Same
process, same speed.

So the VRAM number tells you nothing useful. `llm status` prints VRAM and GTT
side by side and treats neither as proof of anything.

The one check that works is speed:

- **~19 tok/s** — the GPU is doing the work
- **~4.5 tok/s** — it fell back to the CPU

A quiet log means nothing either. llama.cpp b11146 prints no GPU lines at the
default log level. Add `-lv 4` to `start.sh` if you want to see them.

## Troubleshooting

**`libgomp.so.1 => not found`.** Install `libgomp1`. The error is bare and easy
to walk past. `install.sh` installs it and checks with `ldd` afterwards.

**No Vulkan device, or ~4.5 tok/s.** Group membership. `/dev/dri/renderD128`
belongs to the `render` group, and `usermod -aG` only affects new logins, so a
shell you already have open still gets `EACCES`. Log out and back in. `llm status`
measures speed, so it gives you the truth either way.

**The card is missing entirely on Debian.** Usually firmware. `ls
/lib/firmware/amdgpu/gc_11_0_3*` should list seven files. Empty means the card is
on the wrong blobs — see [Debian](#debian).

**`common_fit_params: ... n_gpu_layers already set by user to 99, abort`** and
**`cannot meet free memory target`**. Both harmless.

**`/health` returns 200 but requests fail.** It answers before the model has
loaded. `llm on` waits properly, a raw `curl` straight after starting may not.

**Web UI returns 415.** That's `curl` without `Accept-Encoding`. Use
`curl --compressed`.

**`llm on` hangs.** Usually a port clash. `llm log`, and `llm status` prints the
full command line including the port.

**The first request takes ~18 s and the second takes under 1 s.** Normal. The
model is cold and the driver is still moving it into place.

**Server gone, and `tmux ls` says "no server running".** It exited cleanly, it
did not crash. The tmux server died and took the session with it. Run `llm on`
again. If it keeps happening, something on the box is reclaiming sessions. Check
`loginctl list-sessions`.

## Security

No API key, no authentication, and it binds to a LAN address. Anything that can
reach the host can use it and read the models. Reasonable on a home network, a
bad idea anywhere else. `llm status` prints a CORS warning for the same reason.

To keep it off the network entirely, set `LLM_HOST=127.0.0.1` and tunnel.
Otherwise put a proxy with auth in front of it.

## Layout

```
install.sh              one-shot installer
dry-run.sh              check a machine before installing (see below)
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

Models in `~/llm/models/`, logs in `~/llm/logs/`, binaries in `~/llm/llama/`.
None of that is in git.

## Checking a machine first

`dry-run.sh` answers whether a box can run this, without installing anything.
With no flags it only reads, so it is safe to run anywhere:

```sh
git clone https://github.com/shabbyk/llm-server.git
cd llm-server
./dry-run.sh
```

It reports your glibc against the 2.34 the prebuilt binary needs, whether the
architecture has a build, free RAM and disk, whether you can reach the render
node, and — on an AMD card — whether the `gc_11_0_3` firmware blobs are there.
It exits non-zero if something will actually stop you.

Go further only once that looks clean:

```sh
./dry-run.sh --install     # install into ~/llm-dryrun, no models
./dry-run.sh --model       # also fetch one quant, then start and stop it
./dry-run.sh --clean       # remove everything the above created
```

`--install` repoints `~/.local/bin/llm` at the throwaway directory. It saves
where that symlink used to point and `--clean` puts it back, so it is safe on a
machine that already has this installed. If you cannot sudo, add `--skip-deps`
and install the packages yourself.

## Thinking is off by default

Qwen3.5 thinks by default. Left alone it burns 300+ tokens reasoning and often
puts the real answer in `reasoning_content` while `content` looks empty, which
reads as a broken server. `ask.sh` turns it off. `ask.sh -t` turns it back on.

There is a `--reasoning-budget` flag on the server, but it is not a request
field. Do not put `reasoning_budget` in the JSON.

## OpenCode

The server speaks plain OpenAI chat completions, so anything that talks to
OpenAI will work. OpenCode is worth spelling out, because two of its settings
have to agree with the server's or sessions break in ways that are hard to read.

Config goes in `~/.config/opencode/opencode.json`. This works on v2:

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
          "modelID": "PASTE-THE-PATH-FROM-v1-models",
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

Then:

```sh
opencode service restart
```

Pick the model as `llamacpp/qwen3.5-9b-q6`.

Two things to know. OpenCode reads this config from a background service, so an
edit often appears to do nothing until you restart it. And replace the IP and the
`modelID` above with your own.

### The two limits

`limit.context` tells OpenCode how big the window is. It does not make the
server bigger. Set it larger than what the server actually gave itself and
requests get cut off partway through a reply, which looks like the model going
quiet. Set it smaller and OpenCode tidies up before it needs to. Keep it equal
to `LLM_CTX`.

`limit.output` is how much of the window OpenCode holds back for the reply. So
the room left for you is:

```
usable input  =  context  −  output
```

Remember that ~6600 token overhead from earlier. It comes off the top every
single request:

| context | output | left for you | result |
| --- | --- | --- | --- |
| 16384 | 8192 | ~1600 | compacts straight away |
| 32768 | 4096 | ~22000 | usable |

**If a session compacts the moment it starts, turn `output` down, not `context`
up.** Reserving 8192 out of 16384 leaves less input room than OpenCode's own
prompt already needs. A 9B at 19 tok/s takes 215 s to write 4096 tokens, so a
large reserve is space you pay for on every request and can never actually use.

If replies get cut off mid-edit instead, drop `output` to 3072.

### Getting the model id

```sh
curl -s http://192.168.1.50:8080/v1/models | jq -r '.data[].id'
```

You get an absolute path, something like
`/home/you/llm/models/Qwen3.5-9B-Q6_K.gguf`. That is normal, not a
misconfiguration. Copy it as it is, with no `~`, because nothing expands that
inside JSON.

The server does not check this field. Any string is accepted, so a short name
like `qwen3.5-9b-q6` works just as well and is easier to type. Match the real
path only if you want OpenCode's model picker to line up with `/v1/models`.

### OpenCode v1

Different shape, and no way to turn thinking off from config:

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

Thinking stays on. That is about 13.7 s instead of 0.4 s for a short answer,
and the answer lands in `reasoning_content` instead of `content`. Upgrade to v2,
there is no workaround.

## License

MIT — see [LICENSE](LICENSE).
