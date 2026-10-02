# Local AI stack: local LLM + voice-cloning TTS + retrieval

Runs a quantised Qwen3.5-9B and a text-to-speech server with zero-shot voice
cloning, both on one consumer GPU, both behind an on/off switch. Optionally adds
a small retrieval service so the model can search the web and read your files.

No container, no service manager, nothing that starts on its own.

```sh
./install.sh          # asks what you want, then installs it

llm on                # start the model, wait until it can actually answer
llm off               # unload, and confirm the GPU memory was released
tts on                # start speech synthesis and its web UI
tts off
rag on                # retrieval for the model: web search, your documents
rag off
```

Independent pieces. Installing one does not require another:

| | Runtime | Serves | Switch |
|---|---|---|---|
| **LLM** | Ollama *or* llama.cpp, user-local | OpenAI-compatible API on 11434 / 8090 | `llm` |
| **TTS** | KoboldCpp + a Rust wrapper | web UI on 8081, OpenAI-shaped audio API | `tts` |
| **RAG** | a small Python MCP server | spawned by the model over stdio | `rag` |
| **Chat UI** | Open WebUI *or* the built-in llama.ui | chat interface on 8080 / 8090 | `webui` |

Two engines are supported, and `llm` drives either one. The difference matters:

| | Ollama | llama.cpp |
|---|---|---|
| Model | referenced by tag | a GGUF file on disk |
| Chat page | none — use Open WebUI | **llama.ui**, built into the server |
| Tools / MCP | no | **yes** — this is what the RAG service plugs into |
| Footprint | one 1.4 GB runtime, plus Ollama's own copy of ggml | the binary, plus your GGUF |

Both run on the same Vulkan backend, because Ollama vendors the same ggml code.
Pick `both` at install time and switch with `LLM_ENGINE`; nothing is destroyed
either way.

## Install

```sh
./install.sh              # interactive
./install.sh --yes        # everything, no questions
./install.sh --llm-only   # just the model server
./install.sh --tts-only   # just text to speech
./install.sh --llamacpp-only   # llama.cpp + llama.ui + RAG
./install.sh --rag-only   # just retrieval
```

It asks which engine you want —

```
  LLM engine?
    1) Ollama only     — model referenced by tag; reuse an existing install
    2) llama.cpp only  — GGUF model, with the llama.ui chat page built in
    3) Both            — install each; switch with LLM_ENGINE (~12 GB of models)  (default)

  TTS — the voice-cloning server? [Y/n]
  Chat UI — Open WebUI on top of the model? [Y/n]
  RAG — web search and document lookup for the model? [Y/n]
```

— then does the rest: installs the runtime, fetches the model, installs a C and
Rust toolchain if needed, builds the TTS wrapper, and sets up the retrieval
service. The RAG question is only asked when llama.cpp is in play, since that is
the engine which consumes MCP tools. Debian and Ubuntu are supported; anything
else is refused rather than half-attempted, because the package names and Vulkan
setup differ.

Roughly 1.4 GB for the Ollama runtime (or **30 MB** for llama.cpp), ~5.7 GB for
the model, ~2.5 GB for the TTS weights, and **37 MB** for the RAG service. The
installer is idempotent — re-run it and existing pieces are detected and skipped.

**Everything is installed user-locally under `~`.** No sudo for the runtimes, and
deliberately **no systemd unit**, so nothing starts on boot. That is the rule the
rest of this repository follows: it is a switch, not a service.

## llama.cpp and llama.ui

The prebuilt Vulkan tarball is about **30 MB** — no compiler, no Vulkan SDK, no
`build-essential`. The installer resolves the current nightly tag and extracts it
under `~/llm/llamacpp/`:

```
llama-b11146-bin-ubuntu-vulkan-x64.tar.gz    30.6 MB
```

The version tags carry no binaries; they are attached to the nightly tag, so the
installer reads `nightly-tag.txt` rather than pinning a version that would rot.

**llama.ui is the same process.** `llama-server` serves its chat page on the same
port as the API, so there is no second service to start:

```sh
llm on
llm ui            # http://127.0.0.1:8090/
```

Tools are attached with `rag on` rather than by hand — it writes the config and
restarts the model:

```sh
rag on
llm ui            # the tools now appear in the chat page
```

Under the hood it sets `LLM_MCP` in `~/llm/config.env`. One detail there is worth
knowing, because getting it wrong fails *silently*: llama.cpp only accepts MCP
servers over **stdio**, so the entry needs a `command` to spawn, not a `url`.
An entry with a `url` is skipped with a single warning in the log and the model
quietly has no tools.

One thing llama.ui does **not** have: speech output. The read-aloud feature in
[Speech output](#speech-output) is Open WebUI's, and it works by calling the TTS
server. If reading answers aloud matters more than the built-in page, use Open
WebUI — it works with either engine.

## RAG: web search and your documents

A small tool server that gives the model web search and access to a folder of your
documents. It is not a daemon: **llama.cpp spawns it**, speaks to it over stdio,
and stops it again, which is the only transport llama.cpp supports.

```sh
rag on            # attach it to the model, and restart the model
rag off           # detach it
rag status        # installed, attached, what it can see
rag test          # exercise search, fetch and ranking, no client needed
rag docs          # the folder it indexes
```

Because llama.cpp owns the process, "on" means *attached to the model*, not
*running a service*. With it off the model simply has no tools — which is the
safer default, and why it is a deliberate switch rather than automatic.

Four tools:

| Tool | What it does |
|---|---|
| `research` | search, read the top pages, and return the best-matching passages in **one call** |
| `web_search` | just the results — titles, URLs, snippets |
| `fetch_page` | read one URL as text |
| `search_docs` | search `~/rag/docs/` |

llama.cpp registers them as `rag_research`, `rag_web_search`, `rag_fetch_page` and
`rag_search_docs` — the server name is a prefix — and you can see them at
`http://127.0.0.1:8090/tools`.

`research` exists because a 9B model is not reliable at long tool-calling chains.
Asking it to search, then read, then read again invites it to stop halfway; giving
it one call that does the whole loop and returns citable passages plays to its
strengths.

**How it stays light.** Search is DuckDuckGo's HTML endpoint, so there is **no API
key and no second service**. Ranking is **BM25** — about thirty lines of
arithmetic — so there are no embeddings, no torch, and no vector database. The
virtualenv is **37 MB**, against Open WebUI's 2.5 GB.

The trade is that BM25 matches words rather than meaning: ask for "how do I stop
a process" and a page saying "terminate a job" will rank poorly. For a local 9B on
an 8 GB card that is the right trade, because embeddings would mean a second model
competing for the same VRAM.

**Only llama.cpp can use it.** Ollama does not speak MCP, so `rag on` refuses
rather than attaching something inert, and tells you to switch engines.

**What it can reach.** The model chooses the queries, and it can be talked into
choosing them by a page it has already read. Two things limit that: loopback and
link-local addresses are refused outright — that is where local API keys and
cloud metadata live — and only `http`/`https` are fetched. `--tools` and MCP both
also force `--cors-origins localhost` on the server, so only pages served from
this machine can reach the API.

## Hardware: RX 6600 (`gfx1032`), which ROCm does not support

The target card is a **Radeon RX 6600**. ROCm ships support for `gfx1030`,
`gfx1100`, `gfx1101` and `gfx1102` — **`gfx1032` is not among them**, so any
ROCm-based stack treats this GPU as unsupported and falls back to the CPU, or
needs `HSA_OVERRIDE_GFX_VERSION` to pretend to be a neighbouring target.

Everything here therefore goes through **Vulkan**, which has no card allowlist
and simply uses whatever the driver exposes. On this machine that is
`AMD Radeon RX 6600 (RADV NAVI23)` via Mesa, and Ollama, llama.cpp and KoboldCpp
all drive it successfully. That is also why the installer fetches llama.cpp's
**Vulkan** tarball rather than the ROCm one: the ROCm build is 234 MB and would
not run on `gfx1032` anyway.

Worth knowing: this box also exposes `llvmpipe`, a *software* Vulkan device. Get
the device selection wrong and you get CPU speed while everything reports as a
GPU. Ollama picks the discrete card correctly here, but check rather than assume
— `llm status` prints where the model actually loaded. For llama.cpp it reads the
offload back out of the server's own log line (`offloaded N/N layers to GPU`),
because there is no runtime query for the split.

## The switch

```sh
llm on        # start the server, load the model, wait until resident
llm off       # unload, stop the server, report VRAM
llm status    # state, engine, model, where it loaded, context, installed models
llm toggle    # flip
llm restart
llm models    # what is installed (Ollama tags, or GGUF files)
llm ui        # the chat page address, when the engine has one
llm pull X    # fetch another model (Ollama only)
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

The two engines spell this differently, and `ask.py` translates: Ollama takes
`think: false` on its native API, while llama.cpp is started with `--reasoning
off`, which reaches the model's own Jinja template. The server uses that switch
too, so the built-in llama.ui page behaves the same way.

(`--chat-template-kwargs '{"enable_thinking":false}'` also works and is what
older documentation shows, but this build warns on startup that it is
deprecated.)

## Speed

Qwen3.5-9B Q4_K_M, Vulkan, 32768 context, measured through the API with
`./src/bench.sh`:

| | Ollama | llama.cpp |
|---|---|---|
| decode | 36.9 tok/s | 21.3 tok/s |
| prefill | 520 tok/s | 234 tok/s |

Decode is the number you feel; prefill is what a long agentic system prompt pays.

Every figure comes from a fresh prompt. The benchmark prepends a unique nonce to
each run so prompt caching cannot make prefill look better than it is, and it
discards the first run that pays the model-load cost. Both matter: without them a
warm cache reports prefill an order of magnitude too high, which is how `llama-bench`
once reported 36.4 tok/s for a model that actually decoded at 21.3.

Treat these as relative, not absolute. They move with the driver, with what else
is holding the GPU, and with where the driver chooses to place the model.

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

## Chat UI

```sh
llm on                # the model must be up first
webui on              # then the interface
webui status          # state, and whether Ollama and TTS are reachable
webui off
```

Then open <http://localhost:8080/>. **The first account to sign up becomes
admin** — Open WebUI has its own login and does not ship with one.

**Open WebUI or llama.ui?** They are different tools for different days.

| | Open WebUI | llama.ui |
|---|---|---|
| Install | ~2.5 GB venv, 104 packages | nothing — ships with llama.cpp |
| Read-aloud | **yes**, via the TTS server | no |
| Memory, notes, code execution | yes, built in | no |
| Web search | yes, needs a backend | via the RAG service |
| Weight | heavier, and generates titles and tags in the background | bare, one process |

If you want answers read aloud in a cloned voice, that is Open WebUI — it is the
only one of the two that can call the TTS server. If you want the fastest,
smallest thing that can still reach the web through the RAG service, that is
llama.ui.

`webui on` reports whether the things it needs are running, because a chat UI
with no model behind it just shows an empty model list and looks broken:

```
  starting Open WebUI on 0.0.0.0:8080 ready
  url:    http://192.168.0.101:8080/
  ollama: reachable at http://127.0.0.1:11434
  tts:    not running (optional; 'tts on' enables speech output)
```

### It costs 2.5 GB, not 7.2

`open-webui` has 104 dependencies, and the bulk is not Open WebUI. `torch`
arrives transitively through `sentence-transformers` (for RAG embeddings), and
the default wheel bundles ~4.5 GB of NVIDIA CUDA libraries — `nvidia-*` and
`triton` — which cannot run on this machine's AMD card.

The installer installs the **CPU-only torch** first, so the resolver sees it
satisfied and never pulls them:

| | |
|---|---|
| venv before | 7.2 GB |
| **venv now** | **2.5 GB** |
| `nvidia-*`, `triton` | absent |
| torch | `2.14.1+cpu`, `CUDA available: False` |

The library is identical; only the GPU backends differ, and they were never
usable here. Your chat model still runs entirely on the GPU through Ollama —
the CPU work is just document embedding, on a model of tens of megabytes.

### Speech output

`webui on` wires it to the TTS server automatically, so answered text can be
read aloud in a cloned voice. Set `AUDIO_TTS_VOICE` in
`~/.openwebui/config.env` to any name from `tts voices`. This works because the
TTS server speaks OpenAI's audio API directly — no adapter.

### Web search is off, and needs a backend

Open WebUI **does not include web search**. It calls out to something you supply,
so enabling it means running a second service or handing over an API key. It is
left off until you choose.

**The variable names matter.** Older documentation — including an earlier version
of this file — uses `ENABLE_RAG_WEB_SEARCH` and `RAG_WEB_SEARCH_ENGINE`. This
version ignores both: setting them looks correct and does nothing at all. The
names below are the ones that work.

```sh
# ~/.openwebui/config.env
ENABLE_WEB_SEARCH=true
WEB_SEARCH_ENGINE=duckduckgo     # no account, no key
```

DuckDuckGo is the best starting point because it asks nothing of you. About thirty
other backends ship in this build — `brave`, `searxng`, `google_pse`, `tavily`,
`exa`, `mojeek` and more — each with its own settings. Then `webui restart`.
Everything in that file is exported to the server, so any Open WebUI setting can
go there.

If you are on llama.cpp you do not need this at all: the [RAG
service](#rag-web-search-and-your-documents) gives that engine web access
directly, with no key and no second service.

## Security

Neither the model nor the chat UI has authentication.

- **LLM** binds `127.0.0.1` by default. To serve other machines set
  `LLM_HOST=0.0.0.0` in `~/llm/config.env` — and remember that anyone who can
  route here gets the model with no key.
- **TTS UI** binds `0.0.0.0` and can write files and restart its server. Set
  `TTS_WEBUI_HOST=127.0.0.1` in `~/tts/config.env` for tunnel-only.
- **Chat UI** binds `0.0.0.0` and has its own login — the first sign-up becomes
  admin, so sign up before exposing the port. Set `WEBUI_HOST=127.0.0.1` in
  `~/.openwebui/config.env` for tunnel-only.

**The retrieval service is the one that reaches outward**, so it is worth being
precise about. It runs with the same privileges as the model server, because
llama.cpp spawns it as a child process. What limits it:

- `http` and `https` only; no `file://` or other schemes.
- Loopback and link-local addresses are refused, which is where local service
  APIs and cloud metadata endpoints live.
- It reads a fixed document folder and the open web. It cannot be pointed at
  arbitrary paths on disk.
- Enabling MCP (or `--tools`) makes llama-server default `--cors-origins` to
  `localhost`, so only pages served from this machine can reach the API.

The defaults are chosen so the *unsafe* option is the one you have to ask for.

## Layout

```
install.sh              the installer
uninstall.sh            the remover: software, data, or everything
config.env.example      LLM settings, documented
src/common.sh           shared config and helpers, engine-aware
src/llm                 the LLM switch (either engine)
src/ask.sh ask.py       one-shot prompt client (thinking off by default)
src/bench.sh            prefill/decode measurement, cache-defeating
src/rag                 the retrieval switch: attach / detach
src/rag_server.py       the retrieval service (MCP, stdio)
src/rag.env.example     its settings
src/webui               the chat UI switch
src/webui.env.example   its settings, including the search opt-in
tts/                    the TTS wrapper: one Rust binary
```

Source lives here. Runtime state does not:

| | |
|---|---|
| `~/llm/` | `config.env`, logs |
| `~/llm/models/` | llama.cpp GGUF files |
| `~/llm/llamacpp/` | the llama.cpp build |
| `~/.ollama/` | Ollama model blobs |
| `~/.local/{bin,lib}/ollama` | the Ollama runtime |
| `~/rag/` | `config.env`, logs, and `docs/` |
| `~/.venvs/rag/` | the retrieval Python environment (37 MB) |
| `~/tts/` | engine, weights, voices, logs |
| `~/.openwebui/` | the chat UI's database, uploads, settings |
| `~/.venvs/openwebui/` | its Python environment |

Both engines may be installed at once. They are separate programs on separate
ports, so only one runs at a time and switching is just `llm restart`.

## Uninstall

Per tool, because the tools have very different replacement costs:

```sh
./uninstall.sh --list                   # what is installed, and how big
./uninstall.sh ollama --remove-model    # Ollama and its blobs; llama.cpp stays
./uninstall.sh llamacpp --remove-model  # llama.cpp and its GGUF
./uninstall.sh tts --remove-model       # TTS and its weights
./uninstall.sh webui rag --purge        # those two, with their state
./uninstall.sh all --purge-all          # everything, including your content
./uninstall.sh --dry-run                # print the plan; change nothing
```

```
  Tools:  ollama  llamacpp  tts  webui  rag
  Groups: llm (ollama + llamacpp), all
```

Four levels of data, applied to whichever tools you named:

| Flag | Removes | Cost to restore |
|---|---|---|
| *(none)* | the runtime — ~5 GB in total | one download |
| `--remove-model` | the model or weights | an afternoon: **6.1 GB** Ollama, 5.3 GB llama.cpp, 2.5 GB TTS |
| `--purge` | logs, config, pids | a few preferences |
| `--purge-all` | voice clips, documents, chat history | **nothing — it is gone** |

That separation is the whole point. The two LLM engines are a good example: they
share a switch but not a download, so

```sh
./uninstall.sh ollama --remove-model    # frees 8.3 GB; llama.cpp untouched
./uninstall.sh llamacpp                 # frees 83 MB; Ollama's 6 GB untouched
```

Shared things are treated as shared. The `llm` command and `~/llm/config.env`
serve both engines, so they are only removed when *both* are going — deleting the
command because Ollama left would take away llama.cpp's only way to start.

`--dry-run` prints the real plan: it is built from the same lists the removal
uses, so the preview cannot drift from what would actually happen.

Three things it never removes:

- **apt packages** (`build-essential`, `libvulkan1`) — shared with the rest of
  the machine. It prints the exact `apt remove` line for you to decide.
- **The Rust toolchain** — another project here may depend on it. Opt in with
  `--remove-toolchain`.
- **The repository clone** — you are running the script from it.

Nothing outside `$HOME` is ever a target, so a path built from a bad variable
fails closed rather than deleting something shared.

## Troubleshooting

**The model has no tools, and the log says "no servers found in JSON".** The MCP
entry needs a `command` to spawn, not a `url`. llama.cpp's MCP support is
stdio-only: it runs the program itself and talks over the pipes. An entry written
with a `url` looks entirely plausible, is skipped with one warning line, and
leaves the model silently tool-less. `rag on` writes the correct form; check
`rag status`.

**`rag on` says the engine does not consume MCP tools.** Ollama does not speak
MCP — only llama.cpp does. Set `LLM_ENGINE=llamacpp` in `~/llm/config.env`, or for
one run `LLM_ENGINE=llamacpp llm on`.

**`llm on` says not fully on the GPU.** Check `vulkaninfo --summary` lists RADV,
and that you are in the `render` group: `id | grep render`. Log out and back in
after being added.

On llama.cpp the figure is **measured**, not reported: it compares the memory the
GPU can address — VRAM *and* GTT — against the size of the model file. Both pools
count because this card's driver backs model allocations with either, and moves
between them across loads; measuring VRAM alone reports a perfectly healthy
GTT-resident model as "nothing loaded". The cost is that any other process using
the card inflates the figure.

**The model answers but ignores instructions.** Check the context. Ollama's own
default is 4096 and it truncates silently; this repository sets 32768, but a
`~/llm/config.env` from an older install may not.

**`ollama` commands warn "could not connect".** The CLI talks to `127.0.0.1:11434`
unless told otherwise. If you have set `LLM_HOST` elsewhere that is expected —
use `llm status`, which resolves the right address.

**`llm status` shows an unexpected port.** A config written before both engines
existed pins `LLM_PORT`, which then applies to whichever engine is active. The
installer comments that line out and keeps a copy at `config.env.pre-engines`.
Each engine now has its own default: Ollama 11434, llama.cpp 8090.

## Licence

The installer and wrapper scripts here are yours to license as you see fit.
Ollama is MIT. KoboldCpp is AGPL. Qwen3.5 and Qwen3-TTS weights are Apache-2.0.
Only clone voices you have permission to clone — voice-impersonation law is
separate from model licensing.
