# Qwen3-TTS server

Apache-2.0 text-to-speech with zero-shot voice cloning from a few seconds of
reference audio. Running on **Vulkan** (RX 6600), not ROCm — the card is not
ROCm-supported, but Mesa's RADV driver handles it fine.

The TTS engine is [KoboldCpp](https://github.com/LostRuins/koboldcpp) 1.122.1
(AGPL), which is not built from this repository. This repository is the wrapper
around it: one Rust binary that supervises the engine, fronts it with HTTP, and
provides a small web UI with the one thing a bare TTS server lacks — a way to
upload a reference clip.

## Layout: source here, data in `~/tts`

| | |
|---|---|
| **Source** (this repo) | the Rust binary, committed |
| **Runtime** (`~/tts`, `TTS_DIR`) | models, the koboldcpp binary, voices, logs, output — never committed |
| **Config** (`~/tts/config.env`) | optional, plain `KEY=VALUE` |

Point `TTS_DIR` elsewhere to move the whole runtime tree at once. `voices/` holds
your own recordings, which is why it is gitignored.

## Quick start

```bash
cargo build --release          # see "Building" below if this fails
./target/release/tts on        # start; returns when ready
./target/release/tts status    # state, model, backend, ports, voices
./target/release/tts say "Hello there." -v ref_synthetic.wav -o out.wav
./target/release/tts off       # stop, and confirm the GPU was released
```

The web UI is on <http://localhost:8081/> once `tts on` has returned. `tts on`
prints the LAN address too.

## Commands

```
tts on                  start (detached); returns when ready
tts off                 stop; waits for the port and the process to actually go
tts restart             off, then on
tts toggle              on if off, off if on
tts status              state, model, backend, ports, voice list
tts serve [--attach]    foreground; --attach fronts an already-running TTS server
tts say "text" [-v VOICE] [-o FILE]      text to WAV (reads stdin if no text)
tts voices              the advertised voice names
tts add FILE            install a reference clip as a voice, then restart
tts log                 follow the wrapper's log
tts watch               follow KoboldCpp's log live
```

`on` and `off` are the canonical verbs, deliberately matching `llm`. The
aliases `up`/`start` and `down`/`stop` are accepted, so both spellings work:

```
llm on  /  tts on        the same word for the same idea
llm off /  tts off
```

`say` and `voices` talk straight to the TTS server, so they work even with no
daemon running. `add` and `restart` need the daemon, because only it may restart
the engine.

## How the lifecycle works

Two decisions in here are worth knowing, because they replace things that used to
break:

**Detaching.** `tts on` forks twice and calls `setsid()`, so the daemon is
reparented to init and detached from your terminal. Closing the shell does not
stop it. This replaces tmux.

**Liveness is decided by the kernel.** The daemon holds
`flock(LOCK_EX|LOCK_NB)` on `~/tts/logs/tts.lock` for its whole life. "Is it
running?" means "can I take the lock?" — so a stale pidfile can never make
`status` lie in either direction.

**The engine cannot be orphaned.** The child is spawned with
`PR_SET_PDEATHSIG` set, so if the wrapper dies for any reason the kernel kills
the engine too. Without it, a crash would leave a process holding port 5001 that
nothing could stop; that is the one failure mode this design most needed to
avoid.

**`fork()` happens before the async runtime is built.** The runtime is
multithreaded and fork is only sound in a single-threaded process, so `up`
daemonises and only then builds the runtime, and `restart`/`toggle` drop the
runtime before forking. Do not casually reorder this.

## HTTP API

| Method | Path | Notes |
|---|---|---|
| `GET` | `/` | the UI |
| `GET` | `/api/health` | `tts_up`, `backend`, `restarting`, voice dir, accepted formats |
| `GET` | `/api/voices` | each voice with `cloned` / `builtin` / `stale` and duration |
| `GET` | `/v1/audio/voices` | KoboldCpp's native list, passed through unchanged |
| `POST` | `/api/speak` | multipart `text`, `voice` → `audio/wav` |
| `POST` | `/api/voices/upload` | multipart `file`; restarts and blocks until live |
| `POST` | `/v1/audio/speech` | JSON `{"input","voice"}` → `audio/wav` |

```bash
curl -X POST http://localhost:8081/v1/audio/speech \
  -H "Content-Type: application/json" \
  -d '{"input":"Hello from Qwen3 TTS.","voice":"ref_synthetic.wav"}' \
  -o out.wav
```

`response_format` is accepted and ignored: the model emits PCM WAV and that is
what comes back. `GET /v1/audio/voices` is a change from the shell version, which
had no such route.

`tts say` and the OpenAI endpoint validate the voice name first. An unadvertised
name is **not** an error upstream — KoboldCpp silently substitutes an unrelated
default speaker — so it is refused with the real list instead.

## Voice cloning

Reference samples live in `~/tts/voices/`. Any `.wav` or `.mp3` there becomes a
voice name, but only after a restart, because KoboldCpp builds its voice bank
once at startup:

```python
# koboldcpp.py:13223
if args.ttsdir and os.path.isdir(args.ttsdir):
    for filename in os.listdir(args.ttsdir):     # scanned once, never again
```

There is no reload endpoint, so `tts add` and the upload form restart the server
and block until it answers again — about 5 s. `/api/health` reports
`restarting: true` meanwhile so the page can disable Generate rather than show a
connection error it cannot explain.

```bash
tts add ~/Downloads/me.wav
tts say "This is a sample." -v me.wav -o sample.wav
```

> **Use the filename *with* its extension.** The advertised name of
> `ref_synthetic.wav` is `ref_synthetic.wav`. Passing `ref_synthetic` does not
> error — it falls back to an unrelated default voice, which looks like cloning
> "worked" but is not a clone. `tts voices` prints the real names, and both the
> CLI and the API reject anything else.

**One consequence of the build-once design:** deleting a clip does not remove the
voice. KoboldCpp keeps the audio in memory, so a deleted file keeps generating
until the next restart. `/api/voices` badges those **stale** rather than
mislabelling them as built-in.

**Legal note:** the licence permits commercial use of the *software*. Cloning a
real person's voice without their consent is still not legal in most
jurisdictions. Voice-impersonation law is separate from model licensing.

## Why the clone quality is capped

This is a permanent property of the setup, not a tuning problem.

The upstream Qwen3-TTS API takes **two** inputs: `ref_audio` *and* `ref_text`,
the transcript of the reference. KoboldCpp supplies only the audio:

```python
# koboldcpp.py:13225  -- ttsdir scan, audio files only
if filename.lower().endswith((".mp3", ".wav")):
    voicebank[filename] = base64.b64encode(f.read()).decode("utf-8")

# koboldcpp.py:3361  -- one field forwarded, no transcript alongside it
reference_audio = voicebank.get(voicestr, "")
inputs.reference_audio = reference_audio.encode("UTF-8")
```

`ref_text` appears nowhere in KoboldCpp. Its own docs describe that fallback:
*"If you set `x_vector_only_mode=True`, only the speaker embedding is used so
`ref_text` is not required, but cloning quality may be reduced."* KoboldCpp is
unconditionally in that mode, so the reduced-quality caveat is the permanent
operating condition here.

What actually helps, in order:

1. **One speaker in the clip.** Two voices get averaged into one embedding.
2. **No music, echo, or background noise.** Noise becomes part of the identity.
3. **3–10 s of natural connected speech with varied pitch.** A monotone clip
   yields a monotone clone; much beyond ~10 s adds little.
4. **Consistent mic distance and gain** across clips you add later.

Lifting the ceiling means leaving KoboldCpp for the upstream `transformers` path
(`create_voice_clone_prompt(ref_audio=..., ref_text=...)`), which needs PyTorch.

### On the clone-check tools

The three scripts that used to sit here (`f0.py`, `spectrum.py`,
`check_voice.py`) have been removed. None of them graded a clone, and presenting
them as verification was misleading:

- `check_voice.py` ignored its file argument and re-synthesised fixed lines.
- `f0.py` ranked the true clone **worse** (14.8%) than the built-in `kobo`
  (5.5%) and a known-bad fallback (9.7%).
- `spectrum.py` did not separate them either (0.9994 vs 0.9991).

They only ever caught a catastrophic fallback to the wrong voice, which the
name validation now prevents outright. Judge clones by ear.

## Performance

Ryzen 5 5600X + RX 6600, KoboldCpp 1.122.1, Q8_0. `RTF` = wall-clock / audio
duration; below 1.0 is faster than realtime. Generation streams, so perceived
latency is better than RTF suggests.

**1.7B Base (deployed):**

| Backend | RTF | Speed |
|---|---|---|
| CPU (6 threads) | 1.777 | 0.56x realtime |
| **Vulkan (RX 6600)** | **0.818** | **1.22x realtime** |

Four Vulkan runs gave 0.976 / 0.769 / 0.762 / 0.766. The GPU advantage is ~2.2x.
Earlier measurements of 0.537 (Vulkan) and 0.484 (0.6B Vulkan) predate a reboot
that cleared a wedged device and read too favourably; treat them as historical.

**Why the 1.7B is nearly free:** 2.8x the parameters costs only ~11% more
wallclock on the GPU, because the code Predictor is ~71% of runtime, identical
across model sizes, and strictly serial. The GPU absorbs the larger Talker; the
CPU does not (35% more). On this machine, take the 1.7B.

## Two flag traps

Both silently produce CPU numbers that look perfectly plausible:

1. **`--ttsgpu` alone does nothing.** It only *permits* GPU use. Without
   `--usevulkan 0` the backend never initialises and you get a CPU run wearing a
   GPU label. The wrapper passes both, and reads the backend back from the
   engine's own output rather than trusting the flags — `tts status` shows what
   actually came up.
2. **`--noblas` and `--usevulkan` are mutually exclusive.** KoboldCpp rejects the
   combination with exit code 2, so the wrapper never passes `--noblas`.
   (Measured impact on its own: 0.3%, i.e. irrelevant.)

## Configuration

`~/tts/config.env`, plain `KEY=VALUE`. Precedence: built-in defaults < this file
< environment. See `config.env.example` for the full list; the common ones:

```
TTS_PORT=5001            # the engine
TTS_WEBUI_PORT=8081      # this wrapper
TTS_BACKEND=gpu          # or cpu
TTS_MODEL=auto           # auto | 1.7b | 0.6b
TTS_THREADS=6
```

## Building

Most people should not do this by hand — `./install.sh` at the repository root
installs the toolchain, builds this, and fetches the engine and weights. The
notes below are for doing it yourself or debugging that.

Requires a Rust toolchain and a C toolchain. If `cargo build` fails with
``linker `cc` not found``, the C toolchain is missing:

```bash
sudo apt-get install -y build-essential
rustup target list --installed        # not needed; the host target is correct
cargo build --release
```

The C toolchain is needed even though the program itself has no C in it: Rust
compiles proc-macro crates (serde, clap) and build scripts for the host, and
linking those needs `cc` plus glibc's dev files.

## Files

```
tts/
  Cargo.toml, Cargo.lock
  src/main.rs          CLI dispatch, lifecycle, status
  src/daemon.rs        fork/setsid, flock liveness, pidfile, readiness pipe
  src/supervisor.rs    owns the engine: spawn, log, readiness, restart
  src/server.rs        router + shared state
  src/api.rs           HTTP handlers
  src/voices.rs        voice listing, stale detection, upload sanitisation
  src/client.rs        calls to the engine
  src/config.rs        config.env parsing and defaults
  src/cli.rs           command definitions
  src/commands.rs      say, add, log, watch
  src/sys.rs           /proc and libc helpers
  assets/index.html    the UI, embedded into the binary

~/tts/                 (runtime, gitignored)
  bin/koboldcpp        KoboldCpp 1.122.1 Linux Vulkan build (AGPL)
  models/              GGUFs
  voices/              reference samples
  out/                 generated audio
  logs/server.log      engine output
  logs/tts.log         wrapper output
```

## Security

The UI has **no authentication**. Anyone who can reach port 8081 can synthesise
speech, write files into `~/tts/voices/`, and restart the engine. That is a step
up from read-only inference — fine on a trusted LAN, do not expose it to the
internet. Set `TTS_WEBUI_HOST=127.0.0.1` to reach it only through an SSH tunnel.
