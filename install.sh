#!/usr/bin/env bash
# Interactive installer for the local AI stack.
#
#   ./install.sh              # asks what you want, then installs it
#   ./install.sh --yes        # install everything, no questions
#   ./install.sh --llm-only
#   ./install.sh --tts-only
#   ./install.sh --webui-only
#   ./install.sh --llamacpp-only
#   ./install.sh --rag-only
#   ./install.sh --force      # reinstall things that are already present
#   ./install.sh --uninstall  # remove the stack (forwards to uninstall.sh)
#
# Three independent pieces:
#
#   LLM   A local model, on one of two engines:
#
#           ollama     qwen3.5:9b by tag, managed with `llm pull` / `llm models`.
#           llamacpp   llama-server against a GGUF file. Also serves the bundled
#                      llama.ui chat page, and speaks MCP so it can use tools.
#
#         Either way it is installed user-locally: no sudo, no systemd unit, so
#         nothing starts on boot. Drive it with `llm on` / `llm off`.
#
#   TTS   The Rust wrapper in tts/ plus the KoboldCpp engine and Qwen3-TTS
#         weights, for text-to-speech with zero-shot voice cloning.
#         Drive it with `tts on` / `tts off`.
#
#   RAG   A small MCP server providing web search and document lookup, so a
#         model can answer questions about things it was not trained on.
#         Drive it with `rag on` / `rag off`. Only useful with llama.cpp, since
#         that is the engine which consumes MCP tools.
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
RAG_DIR="${RAG_DIR:-$HOME/rag}"
RAG_VENV="${RAG_VENV:-$HOME/.venvs/rag}"
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

WANT_LLM="" ; WANT_TTS="" ; WANT_WEBUI="" ; WANT_RAG="" ; ASSUME_YES=0 ; FORCE=0

# Which LLM engine(s) to install: ollama, llamacpp, or both. The switch then
# chooses between installed engines with LLM_ENGINE.
LLM_CHOICE=""

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

# Numbered menu. Sets CHOICE to the 1-based index selected.
#
# `--yes` takes the default rather than asking, so an unattended run still gets a
# coherent answer instead of an empty variable.
CHOICE=""
ask_choice() { # prompt default_index option...
    local prompt="$1" default="$2"; shift 2
    local opts=("$@") reply i

    if [ "$ASSUME_YES" -eq 1 ]; then
        printf '  %s [auto: %s]\n' "$prompt" "${opts[$((default - 1))]}"
        CHOICE="$default"
        return 0
    fi

    printf '  %s\n' "$prompt"
    for i in "${!opts[@]}"; do
        if [ "$((i + 1))" -eq "$default" ]; then
            printf '    %d) %s  (default)\n' "$((i + 1))" "${opts[$i]}"
        else
            printf '    %d) %s\n' "$((i + 1))" "${opts[$i]}"
        fi
    done
    printf '  choice [%d] ' "$default"
    read -r reply || reply=""
    reply="${reply:-$default}"

    case "$reply" in
        ''|*[!0-9]*)          CHOICE="$default" ;;
        *) if [ "$reply" -ge 1 ] && [ "$reply" -le "${#opts[@]}" ]; then
               CHOICE="$reply"
           else
               CHOICE="$default"
           fi ;;
    esac
}

# Uninstall lives in its own script, because deleting is a different kind of
# operation from installing and deserves to be read and reviewed on its own. This
# forwards to it so there is still just one entry point to remember.
if [ "${1:-}" = "--uninstall" ]; then
    shift
    exec "$REPO_DIR/uninstall.sh" "$@"
fi

while [ $# -gt 0 ]; do
    case "$1" in
        --yes|-y)    ASSUME_YES=1 ;;
        --llm-only)  WANT_LLM=1; WANT_TTS=0 ;;
        --tts-only)  WANT_LLM=0; WANT_TTS=1 ;;
        --webui-only) WANT_LLM=0; WANT_TTS=0; WANT_WEBUI=1 ;;
        --llamacpp-only) WANT_LLM=1; LLM_CHOICE=llamacpp
                         WANT_TTS=0; WANT_WEBUI=0; WANT_RAG=1 ;;
        --rag-only)  WANT_LLM=0; WANT_TTS=0; WANT_WEBUI=0; WANT_RAG=1 ;;
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

# --------------------------------------------------------------- llama.cpp ----
# The Vulkan loader is what the prebuilt binary links against. The drivers are
# usually already present (Debian ships Mesa), so this matters only on a minimal
# install — but a missing loader fails at run time with "cannot open shared
# object", which reads as a broken download rather than a missing package.
need_vulkan() {
    ldconfig -p 2>/dev/null | grep -q 'libvulkan\.so\.1' && return 0
    apt_install libvulkan1
}

# Where the tarball's tag-named directory landed, or empty.
llamacpp_bin_installed() {
    find "$LLAMACPP_DIR" -maxdepth 3 -type f -name 'llama-server' 2>/dev/null | head -1
}

install_llamacpp() {
    step "llama.cpp (LLM runtime and llama.ui)"

    mkdir -p "$LLAMACPP_DIR" "$LLM_DIR/logs"

    need_pkg curl curl
    need_pkg tar tar
    need_pkg python3 python3

    local bin; bin="$(llamacpp_bin_installed)"
    if [ -n "$bin" ] && [ -x "$bin" ] && [ "$FORCE" -ne 1 ]; then
        ok "already installed: $("$bin" --version 2>&1 | grep -E '^version:' | head -1)"
    else
        # The version tags carry no binaries; they live on the nightly tag, and
        # this one-line asset names it. Pinning a version here would rot.
        local tag
        tag="$(curl -fsSL \
               https://github.com/ggml-org/llama.cpp/releases/latest/download/nightly-tag.txt \
               | tr -d '[:space:]')"
        [ -n "$tag" ] || die "could not resolve the llama.cpp nightly tag"

        # The Vulkan build, not ROCm: the RX 6600 is gfx1032, which ROCm does not
        # support. It is also 30 MB against 234 MB for a tarball that would not
        # run here.
        local url="https://github.com/ggml-org/llama.cpp/releases/download/${tag}/llama-${tag}-bin-ubuntu-vulkan-x64.tar.gz"
        info "downloading llama.cpp $tag (Vulkan build, about 30 MB)"
        curl -fL --retry 3 --retry-delay 3 -o /tmp/llama-vulkan.tar.gz "$url"

        # Clear previous tag directories so two versions cannot both be found.
        # The models directory is untouched.
        rm -rf "$LLAMACPP_DIR"/llama-*
        tar -xzf /tmp/llama-vulkan.tar.gz -C "$LLAMACPP_DIR"
        rm -f /tmp/llama-vulkan.tar.gz

        bin="$(llamacpp_bin_installed)"
        [ -n "$bin" ] || die "no llama-server after extraction"
        ok "installed $tag"
    fi

    need_vulkan
    info "Vulkan loader present"
    info "the same process serves the llama.ui chat page — there is no second service"
}

# Fetch the GGUF. The repository is derived from the configured filename, so
# pointing LLM_GGUF at another quant works without touching this script.
pull_gguf() {
    local name; name="$(basename "$LLM_GGUF")"
    step "Model: $name"

    mkdir -p "$(dirname "$LLM_GGUF")"

    if [ -f "$LLM_GGUF" ]; then
        if [ "$FORCE" -ne 1 ]; then
            ok "already present ($(du -h "$LLM_GGUF" | cut -f1))"
            return 0
        fi
        rm -f "$LLM_GGUF"
    fi

    need_pkg curl curl

    local url="https://huggingface.co/unsloth/Qwen3.5-9B-GGUF/resolve/main/${name}"
    info "downloading $name — about 5.7 GB"
    # -C - resumes a partial file. A 5.7 GB download that dies at 90% should not
    # begin again from zero.
    curl -fL --retry 3 --retry-delay 5 -C - -o "$LLM_GGUF" "$url" \
        || die "could not download $url"
    ok "downloaded $name ($(du -h "$LLM_GGUF" | cut -f1))"
}

verify_llamacpp() {
    step "Verifying llama.cpp"

    local bin; bin="$(llamacpp_bin_installed)"
    [ -x "$bin" ] || die "llama-server is missing"

    # A 5.3 GB model on an 8 GB card. Starting a second copy while one is already
    # resident does not merely waste time: it evicts the running one and leaves
    # both unusable. Report what is already there instead.
    if pgrep -x llama-server >/dev/null 2>&1; then
        local mem; mem="$(llm_gpu_mem || true)"
        ok "a llama-server is already running${mem:+ ($mem)}"
        info "skipping the load test rather than starting a second copy of the model"
        return 0
    fi

    # A scratch port, deliberately not LLM_PORT. At this point the config may
    # still name the other engine's port, and verification must not collide with
    # it or with a server started by hand.
    local port=8199
    local log="$LLM_DIR/logs/llamacpp-verify.log"
    : > "$log"

    info "loading the model to confirm the GPU offload (this takes a moment)"
    "$bin" -m "$LLM_GGUF" -ngl "$LLM_NGL" -c "$LLM_CTX" \
        --host 127.0.0.1 --port "$port" >>"$log" 2>&1 &
    local pid=$!

    # The child must not survive this function, whatever happens inside it.
    #
    # This is not hypothetical: an earlier version let a failing command
    # substitution abort the installer under `set -e` before the cleanup line,
    # and the load-test server was left holding 6 GB of the card. A RETURN trap
    # runs on every exit path, including that one.
    # shellcheck disable=SC2064
    trap "kill $pid 2>/dev/null || true" RETURN INT TERM

    local ready=0 i
    for i in $(seq 1 240); do
        if curl -fsS -o /dev/null --max-time 2 "http://127.0.0.1:$port/health" 2>/dev/null; then
            ready=1; break
        fi
        kill -0 "$pid" 2>/dev/null || break
        sleep 1
    done

    # The VRAM the driver reports against the size of the model file. This is the
    # same measure `llm status` uses, and it is read rather than inferred from
    # -ngl, which is a request and not a result.
    local proc=""
    if [ "$ready" -eq 1 ]; then
        sleep 2                     # let the upload settle before measuring
        proc="$(LLM_ENGINE=llamacpp llm_processor || true)"
    fi

    kill "$pid" 2>/dev/null || true
    for i in $(seq 1 25); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.2
    done
    kill -9 "$pid" 2>/dev/null || true
    trap - RETURN INT TERM

    if [ "$ready" -ne 1 ]; then
        warn "the server did not come up; see $log"
    elif [ "$proc" = "100% GPU" ]; then
        ok "loaded 100% on the GPU"
    elif [ -n "$proc" ]; then
        warn "loaded $proc — not fully on the GPU"
        warn "lower LLM_CTX, or accept a slower model."
    else
        warn "the server came up but the GPU offload could not be measured; see $log"
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
# uv is used to obtain a Python the distribution does not ship. Debian 13 has
# 3.13 and Open WebUI needs <3.13, so a managed interpreter is required; it is
# also what builds the RAG virtualenv. Installed user-locally, no root.
ensure_uv() {
    if ! command -v uv >/dev/null 2>&1 && [ ! -x "$BINDIR/uv" ]; then
        info "installing uv (to obtain a managed Python interpreter)"
        need_pkg curl curl
        curl -LsSf https://astral.sh/uv/install.sh | sh
    fi
    export PATH="$BINDIR:$PATH"
    command -v uv >/dev/null 2>&1 || die "uv is still not on PATH; check $BINDIR"
}

install_chat_ui() {
    step "Chat UI (Open WebUI)"

    ensure_uv

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

# ---------------------------------------------------------------------- RAG --
install_rag() {
    step "Lightweight RAG (web search and document lookup)"

    mkdir -p "$RAG_DIR/logs" "$RAG_DIR/docs"

    ensure_uv

    if [ -x "$RAG_VENV/bin/python" ] && [ "$FORCE" -ne 1 ]; then
        ok "already installed at $RAG_VENV"
    else
        # Everything here except the MCP protocol itself is Python's standard
        # library, so this virtualenv is ~37 MB against Open WebUI's ~2.5 GB.
        # No torch, no embedding model, no vector database: ranking is BM25, which
        # is arithmetic. That is the whole point of calling it lightweight.
        info "creating a virtualenv (Python 3.12)"
        uv venv "$RAG_VENV" --python 3.12
        info "installing the MCP server package"
        uv pip install --python "$RAG_VENV/bin/python" mcp
        ok "installed the RAG service"
    fi

    if [ ! -f "$RAG_DIR/config.env" ]; then
        cp "$REPO_DIR/src/rag.env.example" "$RAG_DIR/config.env"
        ok "wrote $RAG_DIR/config.env"
    fi
}

# --------------------------------------------------------------- switch -----
# Set a ${VAR:=value} line in the model config, in place, or append it.
#
# Done in Python rather than sed because the values here are paths, and a path
# containing the sed delimiter would otherwise silently corrupt the file.
set_config_var() { # VAR VALUE
    local var="$1" value="$2" cfg="$LLM_DIR/config.env"
    mkdir -p "$LLM_DIR"
    [ -f "$cfg" ] || cp "$REPO_DIR/config.env.example" "$cfg"

    python3 - "$cfg" "$var" "$value" <<'PY'
import re, sys
path, var, value = sys.argv[1], sys.argv[2], sys.argv[3]
new = ': "${%s:=%s}"\n' % (var, value)
pat = re.compile(r'^\s*(#\s*)?(:\s+)?"\$\{%s:=' % re.escape(var))
out, done = [], False
for line in open(path):
    if pat.match(line):
        if not done:          # replace the first, drop any duplicates
            out.append(new)
            done = True
    else:
        out.append(line)
if not done:
    if out and not out[-1].endswith("\n"):
        out[-1] += "\n"
    out.append("\n" + new)
open(path, "w").writelines(out)
PY
}

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

    chmod +x "$REPO_DIR/src/llm" "$REPO_DIR/src/ask.sh" "$REPO_DIR/src/bench.sh"
    ln -sfn "$REPO_DIR/src/llm" "$BINDIR/llm"
    ok "linked $BINDIR/llm"

    if [ "$WANT_RAG" = 1 ]; then
        chmod +x "$REPO_DIR/src/rag"
        ln -sfn "$REPO_DIR/src/rag" "$BINDIR/rag"
        ok "linked $BINDIR/rag"
        mkdir -p "$RAG_DIR"
        if [ ! -f "$RAG_DIR/config.env" ]; then
            cp "$REPO_DIR/src/rag.env.example" "$RAG_DIR/config.env"
            ok "wrote $RAG_DIR/config.env"
        fi
    fi

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

    # The Ollama-only version pinned LLM_PORT=11434 here. Now that each engine has
    # its own default, that pin would put llama.cpp on Ollama's port and make
    # `llm status` misleading about which engine is running. Comment it out and
    # keep the original text, so nothing is lost if you want it back.
    if [ -f "$LLM_DIR/config.env" ] && \
       grep -qE '^[[:space:]]*:[[:space:]]*"\$\{LLM_PORT:=' "$LLM_DIR/config.env"; then
        cp "$LLM_DIR/config.env" "$LLM_DIR/config.env.pre-engines"
        sed -i -E \
            's|^([[:space:]]*):[[:space:]]*"\$\{LLM_PORT:=([0-9]+)\}"|# unpinned by the installer: each engine now has its own port default\n#\1: "${LLM_PORT:=\2}"|' \
            "$LLM_DIR/config.env"
        info "unpinned LLM_PORT (ollama and llama.cpp now get their own ports)"
        info "previous file kept at $LLM_DIR/config.env.pre-engines"
    fi

    if [ ! -f "$LLM_DIR/config.env" ] && [ -f "$REPO_DIR/config.env.example" ]; then
        cp "$REPO_DIR/config.env.example" "$LLM_DIR/config.env"
        ok "wrote $LLM_DIR/config.env"
    fi

    # Record the engine actually chosen. Without this, picking llama.cpp in the
    # menu would install it and still leave `llm on` starting Ollama — the switch
    # would report a healthy server that is not the one you asked for.
    if [ "$WANT_LLM" = 1 ] && [ -n "$LLM_CHOICE" ]; then
        local engine
        case "$LLM_CHOICE" in
            ollama)   engine=ollama ;;
            llamacpp) engine=llamacpp ;;
            both)     engine=llamacpp ;;   # the engine you just added becomes active
            *)        engine=ollama ;;
        esac
        set_config_var LLM_ENGINE "$engine"
        ok "LLM_ENGINE=$engine in $LLM_DIR/config.env"
    fi
}

# ------------------------------------------------------------------ main ----
if [ -z "$WANT_LLM$WANT_TTS$WANT_WEBUI$WANT_RAG" ]; then
    echo
    echo "  What would you like to install?"
    ask_choice "LLM engine?" 3 \
        "Ollama only     — model referenced by tag; reuse an existing install" \
        "llama.cpp only  — GGUF model, with the llama.ui chat page built in" \
        "Both            — install each; starts on llama.cpp (~12 GB of models)"
    case "$CHOICE" in
        1) LLM_CHOICE=ollama ;;
        2) LLM_CHOICE=llamacpp ;;
        *) LLM_CHOICE=both ;;
    esac
    WANT_LLM=1

    ask_yn "TTS — the voice-cloning server?" y && WANT_TTS=1 || WANT_TTS=0
    ask_yn "Chat UI — Open WebUI on top of the model?" y && WANT_WEBUI=1 || WANT_WEBUI=0

    # Only worth asking when llama.cpp is in play: it is the engine that consumes
    # MCP tools. Offering it against Ollama would install something the model
    # could not reach.
    if [ "$LLM_CHOICE" != "ollama" ]; then
        ask_yn "RAG — web search and document lookup for the model?" y \
            && WANT_RAG=1 || WANT_RAG=0
    fi
fi

# A flag-only run (--llm-only) never went through the menu, so pick the default.
[ -z "$LLM_CHOICE" ] && LLM_CHOICE=both

case "$LLM_CHOICE" in
    ollama)   ENGINES=ollama ;;
    llamacpp) ENGINES=llamacpp ;;
    both)     ENGINES="ollama llamacpp" ;;
    *)        die "unknown engine choice '$LLM_CHOICE'" ;;
esac

if [ "$WANT_LLM" = 1 ]; then
    # Install in a fixed order rather than the menu's, so the output reads the
    # same however you got here.
    case " $ENGINES " in
        *" ollama "*)
            install_ollama
            pull_model
            verify_llm
            ;;
    esac
    case " $ENGINES " in
        *" llamacpp "*)
            install_llamacpp
            pull_gguf
            verify_llamacpp
            ;;
    esac
fi

[ "$WANT_TTS" = 1 ] && { install_tts; build_tts; install_tts_config; }
[ "$WANT_WEBUI" = 1 ] && install_chat_ui
[ "$WANT_RAG" = 1 ] && install_rag
install_switches

step "Done"
cat <<EOF

  Nothing is running and nothing will start on its own.

    llm on          start the LLM and load the model
    llm status      state, engine, model, where it loaded, context
    llm ui          the chat UI address, when the engine has one
    ./src/ask.sh "hello"        one-shot prompt

    tts on          start the TTS server and web UI
    tts status      state, backend, voices
    tts say "hello" -o out.wav

    webui on        Open WebUI, on top of the model
    webui status    state, plus whether the model and TTS are reachable

  Models and config live in $LLM_DIR.
  TTS weights and voices live in $TTS_DIR.
  Neither directory is in git.

  To remove the whole stack later:

    ./uninstall.sh --dry-run    show what would go, change nothing
    ./uninstall.sh              remove the software, keep your models
    ./uninstall.sh --purge      remove the ~14 GB of downloads too
EOF

if [ "$WANT_RAG" = 1 ]; then
cat <<EOF

  RAG — retrieval for the model:

    rag on          attach it to the model, and restart the model
    rag off         detach it
    rag test        exercise search, fetch and ranking
    rag status      installed, attached, and what it can see

  llama.cpp spawns the retrieval server itself when a tool is called, so there is
  no service to run and nothing to keep alive. Drop files into
  $RAG_DIR/docs to make them searchable as well.
EOF
fi

if [ "$WANT_LLM" = 1 ] && [ "$LLM_CHOICE" = "both" ]; then
cat <<EOF

  Two engines are installed, and llama.cpp is the active one. To go back to
  Ollama, edit LLM_ENGINE in $LLM_DIR/config.env, or for one run:

    LLM_ENGINE=ollama llm on
EOF
fi
