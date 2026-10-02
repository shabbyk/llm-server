#!/usr/bin/env bash
# Interactive installer for the local AI stack.
#
#   ./install.sh              # asks what you want, then installs it
#   ./install.sh --yes        # install everything, no questions
#   ./install.sh --llm-only
#   ./install.sh --tts-only
#   ./install.sh --webui-only
#   ./install.sh --force      # reinstall things that are already present
#
# Two independent pieces:
#
#   LLM   Ollama running qwen3.5:9b, exposed as an OpenAI-compatible API.
#         Installed user-locally: no sudo, and deliberately NO systemd unit, so
#         nothing starts on boot. Drive it with `llm on` / `llm off`.
#
#   TTS   The Rust wrapper in tts/ plus the KoboldCpp engine and Qwen3-TTS
#         weights, for text-to-speech with zero-shot voice cloning.
#         Drive it with `tts on` / `tts off`.
#
# Debian and Ubuntu are supported. Anything else is refused rather than
# half-attempted, because the package names and the Vulkan setup differ.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"

OLLAMA_VERSION="${OLLAMA_VERSION:-latest}"
LLM_DIR="${LLM_DIR:-$HOME/llm}"
TTS_DIR="${TTS_DIR:-$HOME/tts}"
WEBUI_DIR="${WEBUI_DIR:-$HOME/.openwebui}"
WEBUI_VENV="${WEBUI_VENV:-$HOME/.venvs/openwebui}"
BINDIR="${BINDIR:-$HOME/.local/bin}"

KOBOLDC_VER="${KOBOLDC_VER:-v1.122.1}"
# The nocuda build is 137 MB against 642 MB for the CUDA one, and it is the
# variant that actually ships the Vulkan backend used on AMD. Confirmed working
# on an RX 6600.
KOBOLDC_ASSET="koboldcpp-linux-x64-nocuda"
TTS_REPO="https://huggingface.co/koboldcpp/tts/resolve/main"
TTS_MODELS=(
    "Qwen3-TTS-12Hz-1.7B-Base-q8_0.gguf"
    "qwen3-tts-tokenizer-q8_0.gguf"
)

WANT_LLM="" ; WANT_TTS="" ; WANT_WEBUI="" ; ASSUME_YES=0 ; FORCE=0

# Share the config and helpers with the switch, so the installer and `llm`
# cannot drift apart on model name, port, or how the CLI is invoked.
# shellcheck disable=SC1091
. "$REPO_DIR/src/common.sh"

B=$'\033[1m'; N=$'\033[0m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'
step() { printf '\n%s==>%s %s\n' "$B" "$N" "$*"; }
info() { printf '    %s\n' "$*"; }
ok()   { printf '    %s%s%s %s\n' "$G" "$*" "$N" ""; }
warn() { printf '    %swarning:%s %s\n' "$Y" "$N" "$*"; }
die()  { printf '    %serror:%s %s\n' "$R" "$N" "$*" >&2; exit 1; }

ask_yn() { # prompt default(y/n)
    local prompt="$1" default="${2:-y}" reply
    if [ "$ASSUME_YES" -eq 1 ]; then
        printf '  %s [auto: yes]\n' "$prompt"
        return 0
    fi
    if [ "$default" = "y" ]; then
        printf '  %s [Y/n] ' "$prompt"
    else
        printf '  %s [y/N] ' "$prompt"
    fi
    read -r reply || reply=""
    reply="${reply:-$default}"
    case "$reply" in [Yy]*) return 0 ;; *) return 1 ;; esac
}

while [ $# -gt 0 ]; do
    case "$1" in
        --yes|-y)    ASSUME_YES=1 ;;
        --llm-only)  WANT_LLM=1; WANT_TTS=0 ;;
        --tts-only)  WANT_LLM=0; WANT_TTS=1 ;;
        --webui-only) WANT_LLM=0; WANT_TTS=0; WANT_WEBUI=1 ;;
        --force)     FORCE=1 ;;
        -h|--help)   sed -n '2,/^$/p' "$0" | sed -e 's/^#\{1,\} \{0,1\}//' -e '/^$/d'; exit 0 ;;
        *)           die "unknown option: $1 (try --help)" ;;
    esac
    shift
done

# ---------------------------------------------------------------- platform --
. /etc/os-release 2>/dev/null || die "cannot read /etc/os-release"
case "${ID:-} ${ID_LIKE:-}" in
    *debian*|*ubuntu*) ;;
    *) die "unsupported distribution '${ID:-unknown}'. This installer supports Debian and Ubuntu." ;;
esac
[ "$(uname -m)" = "x86_64" ] || die "unsupported architecture '$(uname -m)'; x86_64 only."

SUDO=""
if [ "$(id -u)" -ne 0 ]; then
    command -v sudo >/dev/null 2>&1 || die "sudo is required to install packages"
    SUDO="sudo"
fi

apt_install() {
    info "apt-get install $*"
    $SUDO apt-get update -qq
    DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y -qq --no-install-recommends "$@"
}

need_pkg() { # command package...
    local cmd="$1" pkg="$2"
    command -v "$cmd" >/dev/null 2>&1 && return 0
    apt_install "$pkg"
}

# The version string, without the noise.
#
# `ollama --version` writes "Warning: could not connect to a running Ollama
# instance" to STDOUT when no server is up — which is precisely the state we are
# in during installation. Taking `head -1` of that yields the warning instead of
# the version, so filter warnings out and accept that there may be nothing left.
#
# The `|| true` matters: under `set -o pipefail` a `grep` that matches nothing
# fails the whole pipeline, and `set -e` would then abort the installer on the
# ordinary "no server running" case.
ollama_version() {
    "$BINDIR/ollama" --version 2>/dev/null | grep -v '^Warning:' | head -1 || true
}

printf '%s\n' "  ${B}Local AI stack installer${N}"
printf '  %s\n' "$PRETTY_NAME"
printf '  repo: %s\n' "$REPO_DIR"

# ------------------------------------------------------------------- LLM ----
install_ollama() {
    step "Ollama (LLM runtime)"

    mkdir -p "$BINDIR" "$LLM_DIR/logs"

    if [ -x "$BINDIR/ollama" ] && [ "$FORCE" -ne 1 ]; then
        local v
        v="$(ollama_version)"
        ok "already installed: ${v:-ollama is present}"
        return 0
    fi

    need_pkg curl curl
    need_pkg tar tar
    need_pkg zstd zstd
    need_pkg python3 python3

    local url tag
    if [ "$OLLAMA_VERSION" = "latest" ]; then
        tag="$(curl -fsSL https://api.github.com/repos/ollama/ollama/releases/latest \
               | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"])')"
    else
        tag="$OLLAMA_VERSION"
    fi
    url="https://github.com/ollama/ollama/releases/download/${tag}/ollama-linux-amd64.tar.zst"

    info "downloading $tag (about 1.4 GB)"
    curl -fL --retry 3 --retry-delay 3 -o /tmp/ollama.tar.zst "$url"

    info "extracting to $HOME/.local"
    tar --zstd -xf /tmp/ollama.tar.zst -C "$HOME/.local"
    rm -f /tmp/ollama.tar.zst

    [ -x "$BINDIR/ollama" ] || die "expected $BINDIR/ollama after extraction"
    ok "installed ollama $tag"

    # Note carefully what is NOT done here: no systemd unit, no /etc, no root.
    info "no systemd unit created — nothing will start on boot"
}

start_ollama() {
    command -v pgrep >/dev/null 2>&1 || need_pkg pgrep procps
    if curl -sS -o /dev/null --max-time 2 "http://127.0.0.1:11434/api/version" 2>/dev/null; then
        return 0
    fi
    OLLAMA_HOST="127.0.0.1:11434" OLLAMA_KEEP_ALIVE=5m \
        setsid "$BINDIR/ollama" serve >>"$LLM_DIR/logs/ollama.log" 2>&1 </dev/null &
    disown 2>/dev/null || true
    local i
    for i in $(seq 1 30); do
        curl -sS -o /dev/null --max-time 2 "http://127.0.0.1:11434/api/version" 2>/dev/null && return 0
        sleep 1
    done
    return 1
}

pull_model() {
    local model="${LLM_MODEL:-qwen3.5:9b}"
    step "Model: $model"

    start_ollama || die "the Ollama server did not start; see $LLM_DIR/logs/ollama.log"

    # `ollama list` prints names with an explicit tag, so a model created from a
    # GGUF shows up as "myname:latest" while the request says "myname". Match
    # both forms, or every local model looks missing and gets re-pulled.
    if ollama_cli list 2>/dev/null | awk 'NR>1 {print $1}' \
        | grep -qxE "${model}(:latest)?$"; then
        ok "already pulled: $model"
        return 0
    fi

    info "pulling $model — this can be several GB"
    if ! ollama_cli pull "$model"; then
        die "could not pull '$model'. Check the tag at https://ollama.com/library"
    fi
    ok "pulled $model"
}

verify_llm() {
    step "Verifying the LLM"
    local model="${LLM_MODEL:-qwen3.5:9b}"

    # Load it and see where it actually landed. A silent CPU fallback is the
    # failure this check exists to catch: it looks like a slow model, not an
    # error, so it needs to be stated explicitly.
    curl -sS --max-time 600 "http://127.0.0.1:11434/api/generate" \
        -H 'Content-Type: application/json' \
        -d "{\"model\":\"$model\",\"prompt\":\"\",\"keep_alive\":\"5m\"}" -o /dev/null || true

    local proc
    proc="$(curl -sS --max-time 5 http://127.0.0.1:11434/api/ps 2>/dev/null | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
for m in d.get("models", []):
    s=m.get("size") or 0; v=m.get("size_vram") or 0
    if s: print("100% GPU" if round(100*v/s)>=99 else f"{round(100*v/s)}% GPU"); break
' 2>/dev/null)"

    if [ "$proc" = "100% GPU" ]; then
        ok "loaded 100% on the GPU"
    elif [ -n "$proc" ]; then
        warn "loaded $proc — not fully on the GPU. A CPU load still 'works', just slowly."
        warn "Check the Vulkan driver, and that you are in the 'render' group (id | grep render)."
    else
        warn "could not determine where the model loaded"
    fi
}

# ------------------------------------------------------------------- TTS ----
install_tts() {
    step "TTS engine and weights"
    mkdir -p "$TTS_DIR"/{bin,models,voices,logs,out}

    # --- the engine ---------------------------------------------------------
    if [ -x "$TTS_DIR/bin/koboldcpp" ] && [ "$FORCE" -ne 1 ]; then
        ok "already present: $TTS_DIR/bin/koboldcpp"
    else
        need_pkg curl curl
        local url="https://github.com/LostRuins/koboldcpp/releases/download/${KOBOLDC_VER}/${KOBOLDC_ASSET}"
        info "downloading KoboldCpp ${KOBOLDC_VER} (~137 MB, the Vulkan build)"
        curl -fL --retry 3 --retry-delay 3 -o "$TTS_DIR/bin/koboldcpp" "$url"
        chmod +x "$TTS_DIR/bin/koboldcpp"
        ok "installed $TTS_DIR/bin/koboldcpp"
    fi

    # --- the weights --------------------------------------------------------
    need_pkg curl curl
    local f dest
    for f in "${TTS_MODELS[@]}"; do
        dest="$TTS_DIR/models/$f"
        if [ -f "$dest" ] && [ "$FORCE" -ne 1 ]; then
            ok "already present: $f"
            continue
        fi
        info "downloading $f"
        curl -fL --retry 3 --retry-delay 3 -o "$dest" "$TTS_REPO/$f"
        ok "installed $f ($(du -h "$dest" | cut -f1))"
    done
}

build_tts() {
    step "Building the TTS wrapper"

    # Check the install location as well as PATH: ~/.cargo/bin is often absent
    # from a non-login shell, and re-running rustup just to find a cargo that is
    # already there wastes a minute and can upgrade the toolchain underneath you.
    if ! command -v cargo >/dev/null 2>&1 && [ ! -x "$HOME/.cargo/bin/cargo" ]; then
        info "installing Rust (user-local, no sudo)"
        need_pkg curl curl
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
            | sh -s -- -y --no-modify-path --profile minimal
        ok "installed rustup"
    fi
    # shellcheck disable=SC1091
    [ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"
    export PATH="$HOME/.cargo/bin:$PATH"

    # A C toolchain is required even though the program contains no C: Rust
    # compiles proc-macro crates and build scripts for the host, and linking
    # those needs cc plus glibc's dev files. Without it the build fails with
    # "linker `cc` not found", which is not an obvious message.
    command -v cc >/dev/null 2>&1 || {
        info "installing a C toolchain (needed to link Rust build scripts)"
        apt_install build-essential
    }

    info "cargo build --release"
    ( cd "$REPO_DIR/tts" && cargo build --release ) || die "the TTS build failed"

    [ -x "$REPO_DIR/tts/target/release/tts" ] || die "no binary after the build"
    ln -sfn "$REPO_DIR/tts/target/release/tts" "$BINDIR/tts"
    ok "linked $BINDIR/tts"
}

install_tts_config() {
    if [ ! -f "$TTS_DIR/config.env" ]; then
        # The example is written as KEY=VALUE comments, so copy it and let the
        # defaults stand. Editing is optional.
        sed -e 's/^#: /: /' "$REPO_DIR/tts/config.env.example" > "$TTS_DIR/config.env"
        ok "wrote $TTS_DIR/config.env"
    fi
}


# ----------------------------------------------------------------- chat UI --
install_chat_ui() {
    step "Chat UI (Open WebUI)"

    # Open WebUI requires Python <3.13 and Debian 13 ships 3.13, so a managed
    # interpreter is needed. uv fetches one without root.
    if ! command -v uv >/dev/null 2>&1 && [ ! -x "$BINDIR/uv" ]; then
        info "installing uv (to obtain Python 3.12; Open WebUI needs <3.13)"
        need_pkg curl curl
        curl -LsSf https://astral.sh/uv/install.sh | sh
    fi
    export PATH="$BINDIR:$PATH"
    command -v uv >/dev/null 2>&1 || die "uv is still not on PATH; check $BINDIR"

    if [ -x "$WEBUI_VENV/bin/open-webui" ] && [ "$FORCE" -ne 1 ]; then
        ok "already installed at $WEBUI_VENV"
        return 0
    fi

    info "creating a virtualenv (Python 3.12)"
    uv venv "$WEBUI_VENV" --python 3.12

    # CPU-only torch FIRST, and the ordering matters.
    #
    # torch arrives transitively through sentence-transformers (Open WebUI's
    # RAG embeddings). The default wheel bundles ~4.5 GB of NVIDIA CUDA
    # libraries -- nvidia-*, triton -- that cannot run on this machine's AMD
    # card. Installing the CPU build first means the resolver sees torch
    # already satisfied and never pulls them. Measured: 7.2 GB before, ~2.5 GB
    # after. The library is identical; only the GPU backends differ.
    info "installing CPU-only torch (avoids ~4.5 GB of unusable CUDA libraries)"
    uv pip install --python "$WEBUI_VENV/bin/python" torch \
        --index-url https://download.pytorch.org/whl/cpu

    info "installing open-webui (about 100 packages, a few minutes)"
    uv pip install --python "$WEBUI_VENV/bin/python" open-webui
    ok "installed Open WebUI"
}

# --------------------------------------------------------------- switch -----
install_switches() {
    step "Commands"
    mkdir -p "$BINDIR"

    # The previous design COPIED scripts into $LLM_DIR. The new one symlinks
    # from the repo, so those copies are stale and actively harmful: an old
    # ask.py in $LLM_DIR hardcodes the llama.cpp model name and would be used
    # in preference to the current one.
    local f
    for f in common.sh llm ask.sh ask.py bench.sh up.sh down.sh start.sh stop.sh status.sh llm-run; do
        if [ -f "$LLM_DIR/$f" ]; then
            rm -f "$LLM_DIR/$f"
            info "removed stale $LLM_DIR/$f"
        fi
    done
    [ -d "$LLM_DIR/llama" ] && \
        info "note: $LLM_DIR/llama holds the old llama.cpp build; remove it by hand if you no longer want it"

    chmod +x "$REPO_DIR/src/llm" "$REPO_DIR/src/ask.sh" "$REPO_DIR/src/bench.sh"
    ln -sfn "$REPO_DIR/src/llm" "$BINDIR/llm"
    ok "linked $BINDIR/llm"

    if [ -n "$WANT_WEBUI" ] && [ "$WANT_WEBUI" = 1 ]; then
        chmod +x "$REPO_DIR/src/webui"
        ln -sfn "$REPO_DIR/src/webui" "$BINDIR/webui"
        ok "linked $BINDIR/webui"
        mkdir -p "$WEBUI_DIR"
        if [ ! -f "$WEBUI_DIR/config.env" ]; then
            cp "$REPO_DIR/src/webui.env.example" "$WEBUI_DIR/config.env"
            ok "wrote $WEBUI_DIR/config.env"
        fi
    fi

    if ! grep -q '.local/bin' "$HOME/.bashrc" 2>/dev/null; then
        printf '\n# user-local binaries (llm / tts switches)\nexport PATH="$HOME/.local/bin:$PATH"\n' >> "$HOME/.bashrc"
        info "added ~/.local/bin to PATH in ~/.bashrc"
    fi
    case ":$PATH:" in
        *":$BINDIR:"*) : ;;
        *) warn "$BINDIR is not on your PATH yet. Run 'exec bash -l', or use the full path." ;;
    esac

    if [ -f "$LLM_DIR/config.env" ] && ! grep -q 'LLM_MODEL' "$LLM_DIR/config.env"; then
        # A config.env from the previous llama.cpp build pins LLM_PORT=8080 and
        # uses the old `:=` form. Sourcing it would silently override the new
        # defaults, so move it aside rather than delete it — it may hold local
        # choices worth keeping.
        mv "$LLM_DIR/config.env" "$LLM_DIR/config.env.pre-ollama"
        warn "moved the old llama.cpp config to $LLM_DIR/config.env.pre-ollama"
    fi

    if [ ! -f "$LLM_DIR/config.env" ] && [ -f "$REPO_DIR/config.env.example" ]; then
        cp "$REPO_DIR/config.env.example" "$LLM_DIR/config.env"
        ok "wrote $LLM_DIR/config.env"
    fi
}

# ------------------------------------------------------------------ main ----
[ -n "$WANT_LLM" ] || [ -n "$WANT_TTS" ] || {
    echo
    echo "  What would you like to install?"
    ask_yn "LLM — qwen3.5:9b on Ollama?" y && WANT_LLM=1 || WANT_LLM=0
    ask_yn "TTS — the voice-cloning server?" y && WANT_TTS=1 || WANT_TTS=0
    ask_yn "Chat UI — Open WebUI on top of the model?" y && WANT_WEBUI=1 || WANT_WEBUI=0
}

[ "$WANT_LLM" = 1 ] && { install_ollama; pull_model; verify_llm; }
[ "$WANT_TTS" = 1 ] && { install_tts; build_tts; install_tts_config; }
[ "$WANT_WEBUI" = 1 ] && install_chat_ui
install_switches

step "Done"
cat <<EOF

  Nothing is running and nothing will start on its own.

    llm on          start the LLM and load the model
    llm status      state, model, where it loaded, context
    ./src/ask.sh "hello"        one-shot prompt

    tts on          start the TTS server and web UI
    tts status      state, backend, voices
    tts say "hello" -o out.wav

    webui on        the chat interface, on top of Ollama
    webui status    state, plus whether Ollama and TTS are reachable

  Models live in $LLM_DIR (config) and $TTS_DIR (weights, voices, logs).
  Neither directory is in git.
EOF
