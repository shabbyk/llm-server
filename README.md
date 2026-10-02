# Local AI stack: Ollama LLM + voice-cloning TTS

Runs a quantised Qwen3.5-9B and a text-to-speech server with zero-shot voice
cloning, both on one consumer GPU, both behind an on/off switch.

No container, no service manager, nothing that starts on its own.

```sh
./install.sh          # asks what you want, then installs it

llm on                # start the model, wait until it can actually answer
llm off               # unload, and confirm the GPU memory was released
tts on                # start speech synthesis and its web UI
tts off
```

Two independent pieces. Installing one does not require the other:

| | Runtime | Serves | Switch |
|---|---|---|---|
| **LLM** | Ollama, user-local | OpenAI-compatible API on 11434 | `llm` |
| **TTS** | KoboldCpp + a Rust wrapper | web UI on 8081, OpenAI-shaped audio API | `tts` |

## Install

```sh
./install.sh              # interactive
./install.sh --yes        # everything, no questions
./install.sh --llm-only   # just the model server
./install.sh --tts-only   # just text to speech
```

It asks two questions —

```
  LLM — qwen3.5:9b on Ollama? [Y/n]
  TTS — the voice-cloning server? [Y/n]
```

— then does the rest: installs Ollama, pulls the model, installs a C and Rust
toolchain if needed, builds the TTS wrapper, and fetches the engine and weights.
Debian and Ubuntu are supported; anything else is refused rather than
half-attempted, because the package names and Vulkan setup differ.

Roughly 1.4 GB for the runtime, ~6 GB for the model, ~2.5 GB for the TTS
weights. The installer is idempotent — re-run it and existing pieces are
detected and skipped.

**Ollama is installed user-locally into `~/.local`.** No sudo, and deliberately
**no systemd unit**, so nothing starts on boot. That is the same rule the rest of
this repository follows: it is a switch, not a service.

## Hardware: RX 6600 (`gfx1032`), which ROCm does not support

The target card is a **Radeon RX 6600**. ROCm ships support for `gfx1030`,
`gfx1100`, `gfx1101` and `gfx1102` — **`gfx1032` is not among them**, so any
ROCm-based stack treats this GPU as unsupported and falls back to the CPU, or
needs `HSA_OVERRIDE_GFX_VERSION` to pretend to be a neighbouring target.

Everything here therefore goes through **Vulkan**, which has no card allowlist
and simply uses whatever the driver exposes. On this machine that is
`AMD Radeon RX 6600 (RADV NAVI23)` via Mesa, and both Ollama and KoboldCpp drive
it successfully.

Worth knowing: this box also exposes `llvmpipe`, a *software* Vulkan device. Get
the device selection wrong and you get CPU speed while everything reports as a
GPU. Ollama picks the discrete card correctly here, but check rather than assume
— `llm status` prints where the model actually loaded.

## The switch

```sh
llm on        # start the server, load the model, wait until resident
llm off       # unload, stop the server, report VRAM
llm status    # state, model, where it loaded, context, installed models
llm toggle    # flip
llm restart
llm models    # what is installed
llm pull X    # fetch another model
llm log       # follow the server log
```

`llm on` finishes by reporting **where the model landed**:

```
  processor: 100% GPU
  context:   32768
```

That line is the point. A CPU load still "works" — it just answers slowly, and
looks like a slow model rather than a broken GPU. If it does not say `100% GPU`,
something is wrong and the switch says so.

### Context length: the setting that bites

Ollama's own default is **4096**, and it does not warn — it silently truncates.
An agentic client's system prompt and tool definitions alone run ~6.6k tokens, so
at 4096 the model appears to ignore instructions and forget context. This
repository sets **32768** in `~/llm/config.env`.

```sh
# ~/llm/config.env
: "${LLM_CTX:=32768}"
```

### Thinking is off by default

Qwen3.5 is a reasoning model. Left alone it spends hundreds of tokens thinking,
and the useful answer can end up in the reasoning trace rather than in
`content` — which looks like an empty reply. Use the client, which disables it:

```sh
./src/ask.sh "why is the sky blue"     # thinking OFF (default)
./src/ask.sh -t "plan a refactor"      # thinking ON, slower
```

## Speed

Qwen3.5-9B Q4_K_M on an RX 6600, Vulkan, measured through the API:

| | Ollama | previous llama.cpp build |
|---|---|---|
| decode | **~23 tok/s** | 21.3 tok/s |
| prefill | ~200–2600 tok/s | 468–573 tok/s |
| default context | **4096** (overridden here) | 32768 |

Decode is the number you feel, and it is a wash — unsurprising, since Ollama
vendors the same ggml Vulkan backend. Prefill is what long agentic prompts pay,
and it varies enough run to run that a single number is not worth quoting;
`./src/bench.sh` measures it properly, discarding the first run that pays the
model-load cost.

Not benchmarked against the old build in a controlled way, so treat the
comparison as a signal rather than a result.

## Text to speech

```sh
tts on                                        # start, returns when ready
tts say "Hello there." -v me.wav -o out.wav
tts voices                                    # the advertised names
tts add ~/Downloads/me.wav                    # install a reference clip
tts off
```

The UI is on <http://localhost:8081/> once `tts on` returns. See
[tts/README.md](tts/README.md) for the full guide.

**One thing to know before tuning a reference clip:** clone quality is capped by
design. The upstream model takes a reference *transcript* as well as audio, and
KoboldCpp forwards only the audio, so it runs in `x_vector_only_mode`
permanently. It is good, not perfect, and no amount of clip tuning lifts that
ceiling.

## Security

Neither service has authentication.

- **LLM** binds `127.0.0.1` by default. To serve other machines set
  `LLM_HOST=0.0.0.0` in `~/llm/config.env` — and remember that anyone who can
  route here gets the model with no key.
- **TTS UI** binds `0.0.0.0` and can write files and restart its server. Set
  `TTS_WEBUI_HOST=127.0.0.1` in `~/tts/config.env` for tunnel-only.

Both defaults are chosen so the *unsafe* option is the one you have to ask for.

## Layout

```
install.sh              the installer
config.env.example      LLM settings, documented
src/common.sh           shared config and helpers
src/llm                 the LLM switch
src/ask.sh ask.py       one-shot prompt client (thinking off by default)
src/bench.sh            prefill/decode measurement
tts/                    the TTS wrapper: one Rust binary
```

Source lives here. Runtime state does not:

| | |
|---|---|
| `~/llm/` | `config.env`, logs |
| `~/.ollama/` | model blobs |
| `~/.local/{bin,lib}/ollama` | the Ollama runtime |
| `~/tts/` | engine, weights, voices, logs |

`~/llm/llama/` is the previous llama.cpp build. The installer does not remove it;
delete it by hand once you are satisfied with Ollama.

## Troubleshooting

**`llm on` says not fully on the GPU.** Check `vulkaninfo --summary` lists RADV,
and that you are in the `render` group: `id | grep render`. Log out and back in
after being added.

**The model answers but ignores instructions.** Check the context. Ollama
silently truncates at its default of 4096; this repository sets 32768, but a
`~/llm/config.env` from an older install may not.

**`ollama` commands warn "could not connect".** The CLI talks to `127.0.0.1:11434`
unless told otherwise. If you have set `LLM_HOST` elsewhere, that is expected —
use `llm status`, which resolves the right address.

**A stale `~/llm/config.env` overrides everything.** The installer moves one from
the llama.cpp era to `config.env.pre-ollama`, because it pins port 8080.

## Licence

The installer and wrapper scripts here are yours to license as you see fit.
Ollama is MIT. KoboldCpp is AGPL. Qwen3.5 and Qwen3-TTS weights are Apache-2.0.
Only clone voices you have permission to clone — voice-impersonation law is
separate from model licensing.
