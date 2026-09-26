#!/usr/bin/env bash
# Install a local llama.cpp LLM server (Vulkan) plus an on/off switch.
#
#   ./install.sh                     # interactive: deps, binaries, both models
#   ./install.sh --skip-models       # just the plumbing, fetch models later
#   ./install.sh --models q6         # only the default model (7.5 GB)
#   ./install.sh --dir ~/.local/llm  # install somewhere else
#   ./install.sh --uninstall
#
# Nothing is started automatically and nothing is registered as a service. You
# get a switch: `llm on` / `llm off`.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"

# ---------------------------------------------------------------- defaults --
LLM_DIR="${LLM_DIR:-$HOME/llm}"
LLM_BUILD="${LLM_BUILD:-b11146}"       # llama.cpp release tag; "latest" works
LLM_REPO="${LLM_REPO:-unsloth/Qwen3.5-9B-GGUF}"
LLM_MODELS_WANTED="q6 q4"
SKIP_DEPS=0
SKIP_MODELS=0
ASSUME_YES=0
UNINSTALL=0

# ------------------------------------------------------------------ output --
if [ -t 1 ]; then
    B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; D=$'\033[2m'; N=$'\033[0m'
else
    B=""; G=""; Y=""; R=""; D=""; N=""
fi
step() { printf '%s==>%s %s\n' "$B" "$N" "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '%s    warning:%s %s\n' "$Y" "$N" "$*"; }
die()  { printf '%s    error:%s %s\n' "$R" "$N" "$*" >&2; exit 1; }
ok()   { printf '%s    ok%s %s\n' "$G" "$N" "$*"; }

usage() { sed -n '2,/^$/p' "$0" | sed -e 's/^#\{1,\} \{0,1\}//' -e '/^$/d'; }

# -------------------------------------------------------------------- args --
while [ $# -gt 0 ]; do
    case "$1" in
        --dir)          LLM_DIR="$2"; shift 2 ;;
        --build)        LLM_BUILD="$2"; shift 2 ;;
        --repo)         LLM_REPO="$2"; shift 2 ;;
        --models)       LLM_MODELS_WANTED="$2"; shift 2 ;;
        --skip-deps)    SKIP_DEPS=1; shift ;;
        --skip-models)  SKIP_MODELS=1; shift ;;
        -y|--yes)       ASSUME_YES=1; shift ;;
        --uninstall)    UNINSTALL=1; shift ;;
        -h|--help)      usage; exit 0 ;;
        *)              die "unknown option '$1' (try --help)" ;;
    esac
done

ARCH="$(uname -m)"
case "$ARCH" in
    x86_64|amd64)  ARCH_TAG="x64" ;;
    aarch64|arm64) ARCH_TAG="arm64" ;;
    *) die "unsupported architecture '$ARCH'. This installer ships prebuilt Vulkan binaries for x64 and arm64 only; building from source is a separate job." ;;
esac

# --------------------------------------------------------------- uninstall --
if [ "$UNINSTALL" -eq 1 ]; then
    step "Uninstalling"
    if pgrep -x llama-server >/dev/null 2>&1; then
        "$LLM_DIR/stop.sh" 2>/dev/null || kill $(pgrep -x llama-server) 2>/dev/null || true
    fi
    tmux kill-session -t llm 2>/dev/null && info "closed tmux session" || true
    rm -f "$HOME/.local/bin/llm"
    info "removed ~/.local/bin/llm"
    if [ -d "$LLM_DIR" ]; then
        printf '    %sDelete %s and all downloaded models (~13 GB)? [y/N] ' "$Y" "$LLM_DIR"
        read -r reply </dev/tty || reply=""
        if [ "${reply,,}" = y ]; then
            rm -rf "$LLM_DIR"
            info "deleted $LLM_DIR"
        else
            info "kept $LLM_DIR (delete it by hand to finish)"
        fi
    fi
    # Group membership is deliberately left alone: removing it is a system-wide
    # change that other software on the box may depend on.
    warn "group membership (video/render) left as-is; remove by hand with 'sudo gpasswd -d $USER render' if you are sure"
    step "Done."
    exit 0
fi

# ------------------------------------------------------------- preflight ---
step "Preflight"
if [ ! -r /etc/os-release ]; then
    die "cannot identify the OS (/etc/os-release missing)"
fi
# shellcheck disable=SC1091
. /etc/os-release
info "os         $PRETTY_NAME"
info "arch       $ARCH (using $ARCH_TAG builds)"
info "install to $LLM_DIR"

[ "$LLM_BUILD" = "latest" ] || [ -n "$LLM_BUILD" ] || die "LLM_BUILD must be a tag or 'latest'"
[ -w "$(dirname "$LLM_DIR")" ] || die "cannot write to $(dirname "$LLM_DIR") (set --dir, or fix permissions)"
ok "preflight passed"

# Ask before doing anything that needs sudo, rather than failing halfway in.
SUDO=""
if [ "$(id -u)" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then
        SUDO="sudo"
    else
        die "this install needs root for package installation and group membership, and sudo is not available. Re-run as root, or use --skip-deps and add the groups by hand."
    fi
fi

# ------------------------------------------------------------------ deps ---
if [ "$SKIP_DEPS" -eq 0 ]; then
    step "System packages"
    if [ -z "$SUDO" ]; then
        info "already root"
    elif [ "$ASSUME_YES" -eq 1 ]; then
        $SUDO -n true 2>/dev/null || die "need sudo but -n failed; re-run without --yes so you can authenticate"
    fi

    # libgomp1 is not optional and is easy to miss: without it llama-server dies
    # at startup with "libgomp.so.1 => not found" and no useful error.
    #
    # The Vulkan driver package name is Mesa-specific. On NVIDIA you need the
    # proprietary ICD instead, which this script does not attempt to install.
    PKGS="curl tmux python3 libgomp1 libvulkan1 vulkan-tools"
    if [ "$ID" = "ubuntu" ] || [ "$ID" = "debian" ]; then
        PKGS="$PKGS mesa-vulkan-drivers"
    elif [ "$ID" = "fedora" ]; then
        PKGS="$PKGS vulkan-loader vulkan-tools mesa-vulkan-drivers"
    elif [ "$ID" = "arch" ]; then
        PKGS="$PKGS vulkan-icd-loader vulkan-tools mesa-vulkan-drivers"
    else
        warn "unrecognised distro '$ID'; not adding a Vulkan driver package"
    fi

    info "installing: $PKGS"
    # shellcheck disable=SC2086
    $SUDO apt-get update -qq 2>/dev/null || $SUDO dnf -y -q install 2>/dev/null || \
        $SUDO pacman -Sy --noconfirm 2>/dev/null || warn "could not refresh package lists; continuing"
    # shellcheck disable=SC2086
    $SUDO apt-get install -y -qq $PKGS 2>/dev/null \
        || $SUDO dnf -y -q install $PKGS 2>/dev/null \
        || $SUDO pacman -S --noconfirm --needed $PKGS 2>/dev/null \
        || die "package installation failed. Install these by hand: $PKGS"
    ok "packages present"
else
    step "System packages"
    info "skipped (--skip-deps)"
fi

# ------------------------------------------------------------- GPU gate ----
step "GPU check"
if ! command -v vulkaninfo >/dev/null 2>&1; then
    warn "vulkaninfo not found; cannot verify the GPU. Continuing, but if the server reports no device, this is why."
else
    # A CPU fallback (llvmpipe/lavapipe) will happily appear here, so require a
    # real hardware device. Filter out the software rasterisers explicitly.
    VULKAN_OUT="$(vulkaninfo --summary 2>/dev/null || true)"
    HW="$(printf '%s\n' "$VULKAN_OUT" | grep -E 'deviceName|deviceType' \
          | grep -viE 'llvmpipe|lavapipe|swiftshader|software' || true)"
    if [ -z "$HW" ]; then
        warn "no hardware Vulkan device found. Drivers may be missing or you may lack access to /dev/dri."
        warn "the install will continue, but the server will not offload to the GPU."
    else
        printf '%s\n' "$VULKAN_OUT" | sed -n 's/^ *deviceName *= */    /p' | head -3
        ok "hardware Vulkan device present"
    fi
fi

if [ -e /dev/dri/renderD128 ] || ls /dev/dri/renderD* >/dev/null 2>&1; then
    GRP=""
    for g in render video; do
        if getent group "$g" >/dev/null 2>&1; then GRP="$g"; break; fi
    done
    if [ -z "$GRP" ]; then
        warn "no 'render' or 'video' group on this system; cannot check GPU access"
    elif id -nG | tr ' ' '\n' | grep -qx "$GRP"; then
        ok "already in group '$GRP'"
    else
        if [ "$SKIP_DEPS" -eq 0 ] && [ -n "$SUDO" ]; then
            $SUDO usermod -aG "$GRP" "$(id -un)" 2>/dev/null || warn "could not add you to '$GRP'"
            ok "added you to '$GRP' — takes effect at your next login"
        else
            warn "not in group '$GRP'. Run: sudo usermod -aG $GRP $(id -un)"
        fi
        warn "until you log out and back in, the llm-run shim bridges this by re-execing under 'newgrp'"
    fi
else
    warn "no /dev/dri/renderD* — this machine appears to have no GPU, or no display driver bound"
fi

# ------------------------------------------------------------- binaries ----
step "llama.cpp binaries ($LLM_BUILD, Vulkan)"

if [ "$LLM_BUILD" = "latest" ]; then
    LLM_BUILD="$(curl -fsSL --max-time 30 "https://api.github.com/repos/ggml-org/llama.cpp/releases/latest" 2>/dev/null \
                 | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"])' 2>/dev/null || true)"
    [ -n "$LLM_BUILD" ] || die "could not determine the latest llama.cpp release; pass --build <tag>"
    info "latest release is $LLM_BUILD"
fi

BIN_DIR="$LLM_DIR/llama"
TARBALL="llama-${LLM_BUILD}-bin-ubuntu-vulkan-${ARCH_TAG}.tar.gz"
URL="https://github.com/ggml-org/llama.cpp/releases/download/${LLM_BUILD}/${TARBALL}"

if [ -x "$BIN_DIR/llama-server" ]; then
    have="$("$BIN_DIR/llama-server" --version 2>/dev/null | head -1)"
    info "already installed: $have"
    if [ "${have##*build }" != "${LLM_BUILD#b}" ] && [ "${have##*build }" != "$LLM_BUILD" ]; then
        warn "that is a different build than $LLM_BUILD; delete $BIN_DIR to change it"
    fi
    ok "binaries present"
else
    info "downloading $TARBALL"
    tmp="$(mktemp -d)"
    # -C - makes this resumable if a previous attempt died partway.
    if curl -fL --retry 5 --retry-delay 3 -C - -o "$tmp/$TARBALL" "$URL"; then
        mkdir -p "$LLM_DIR"
        tar -xzf "$tmp/$TARBALL" -C "$tmp"
        found="$(find "$tmp" -maxdepth 2 -name llama-server -type f | head -1)"
        [ -n "$found" ] || die "tarball did not contain llama-server"
        rm -rf "$BIN_DIR"
        mv "$(dirname "$found")" "$BIN_DIR"
        rm -rf "$tmp"
        ok "installed to $BIN_DIR"
    else
        rm -rf "$tmp"
        die "download failed: $URL
  If the tag does not exist, pick another with --build <tag>, or use --build latest."
    fi
fi

# A missing shared library here is the single most common way this silently
# breaks, and the error only appears at runtime. Check now, while it is cheap.
if command -v ldd >/dev/null 2>&1; then
    missing="$(ldd "$BIN_DIR/llama-server" 2>/dev/null | grep -i 'not found' || true)"
    if [ -n "$missing" ]; then
        warn "llama-server has unresolved libraries:"
        printf '%s\n' "$missing" | sed 's/^/      /'
        warn "install the matching -dev/-runtime packages, then re-run. (libgomp.so.1 comes from libgomp1.)"
    else
        ok "all shared libraries resolve"
    fi
fi

# --------------------------------------------------------------- models ----
if [ "$SKIP_MODELS" -eq 0 ]; then
    step "Models ($LLM_REPO)"
    mkdir -p "$LLM_DIR/models"
    for preset in $LLM_MODELS_WANTED; do
        case "$preset" in
            q6) fname="Qwen3.5-9B-Q6_K.gguf" ;;
            q4) fname="Qwen3.5-9B-Q4_K_M.gguf" ;;
            *) die "unknown preset '$preset' (expected q6 or q4)" ;;
        esac
        dest="$LLM_DIR/models/$fname"
        if [ -f "$dest" ]; then
            ok "$(basename "$dest") already downloaded ($(du -h "$dest" | cut -f1))"
            continue
        fi
        url="https://huggingface.co/${LLM_REPO}/resolve/main/${fname}"
        info "downloading $fname (~$(curl -fsSLI --max-time 20 "$url" 2>/dev/null \
             | grep -i '^content-length' | tail -1 | tr -dc '0-9' | awk '{printf "%.1f GB", $1/1e9}') )"
        # -C - resumes; --retry rides out flaky links.
        curl -fL --retry 5 --retry-delay 3 -C - -o "$dest" "$url" \
            || die "download failed: $url"
        ok "$(basename "$dest") ($(du -h "$dest" | cut -f1))"
    done
else
    step "Models"
    info "skipped (--skip-models)"
fi

# -------------------------------------------------------------- install ----
step "Installing scripts"
mkdir -p "$LLM_DIR/logs"
for f in common.sh llm-run llm start.sh stop.sh status.sh up.sh down.sh ask.sh ask.py bench.sh; do
    install -m 0755 "$REPO_DIR/src/$f" "$LLM_DIR/$f"
done
# common.sh is sourced, not executed; but 0755 keeps it usable when someone
# runs it by accident without breaking anything.
ok "scripts installed to $LLM_DIR"

if [ -f "$REPO_DIR/config.env.example" ] && [ ! -f "$LLM_DIR/config.env" ]; then
    install -m 0644 "$REPO_DIR/config.env.example" "$LLM_DIR/config.env"
    info "wrote $LLM_DIR/config.env — edit it to change host, port, context"
fi

# ---------------------------------------------------------------- switch ---
step "Installing the 'llm' switch"
BINDIR="$HOME/.local/bin"
mkdir -p "$BINDIR"
ln -sfn "$LLM_DIR/llm" "$BINDIR/llm"
ok "linked $BINDIR/llm"

if ! grep -q '.local/bin' "$HOME/.bashrc" 2>/dev/null; then
    printf '\n# user-local binaries (llm on/off switch)\nexport PATH="$HOME/.local/bin:$PATH"\n' >> "$HOME/.bashrc"
    info "added ~/.local/bin to PATH in ~/.bashrc"
fi
case ":$PATH:" in
    *":$BINDIR:"*) : ;;
    *) warn "$BINDIR is not on your PATH yet. Either 'exec bash -l' or run ~/.local/bin/llm by full path." ;;
esac

# ---------------------------------------------------------------- verify ---
step "Verifying"
# The real check is whether a hardware device is visible from a process that
# can open the render node. --list-devices is the cheapest honest test.
if "$BIN_DIR/llama-server" --list-devices 2>/dev/null | grep -qiE 'Vulkan[0-9]'; then
    ok "llama-server sees a Vulkan device"
    "$BIN_DIR/llama-server" --list-devices 2>/dev/null | grep -E 'Vulkan[0-9]' | sed 's/^/      /'
elif "$LLM_DIR/llm-run" "$BIN_DIR/llama-server" --list-devices 2>/dev/null | grep -qiE 'Vulkan[0-9]'; then
    ok "llama-server sees a Vulkan device (via the render-group shim)"
else
    warn "llama-server does not see a Vulkan device right now."
    warn "If you were just added to the render group, log out and back in, then re-run."
    warn "Check 'ls -l /dev/dri/renderD*' and 'vulkaninfo --summary'."
fi

# --------------------------------------------------------------- summary ---
cat <<EOF

${B}Done.${N} Nothing is running and nothing will start on its own.

    ${B}llm on${N}          start the server (waits until it is ready to serve)
    ${B}llm off${N}         stop it and release the GPU
    ${B}llm${N}             status
    ${B}llm help${N}        everything else

    config       $LLM_DIR/config.env
    logs         $LLM_DIR/logs/
    models       $LLM_DIR/models/

Then:
    llm on
    llm on && ~/llm/ask.sh "say hello"

${D}The server has no API key and no authentication. It binds to a LAN address,
so anything that can route to this host can use it. Put it behind a tunnel, or
add a reverse proxy with auth, before it leaves a trusted network.${N}

EOF
