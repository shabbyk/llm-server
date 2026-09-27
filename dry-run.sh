#!/usr/bin/env bash
# dry-run.sh — check whether this machine can run the server, before committing to it.
#
# Safe by default. With no flags it only reads things: no installs, no downloads,
# no changes to your system. Pass --install or --model to go further.
#
#   ./dry-run.sh              read-only checks
#   ./dry-run.sh --install    also install into a throwaway dir, no models
#   ./dry-run.sh --model      also fetch one quant and start/stop the server
#   ./dry-run.sh --clean      remove everything --install/--model created
#
# Add --skip-deps if you cannot sudo (or are not at a terminal to type a
# password into), having installed the packages yourself.
#
# Exists because the interesting questions (is your glibc new enough, do you
# have the GPU firmware, can you reach the render node) are all answerable
# without a 7 GB download. Run this first, then install for real.

set -u

SELF_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"

DRY_DIR="${DRY_DIR:-$HOME/llm-dryrun}"
PORT="${PORT:-8095}"
CTX="${CTX:-4096}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-900}"
BUILD="${BUILD:-b11146}"
QUANT="${QUANT:-q4}"

DO_INSTALL=0
DO_MODEL=0
DO_CLEAN=0
ASSUME_YES=0
SKIP_DEPS=0

while [ $# -gt 0 ]; do
    case "$1" in
        --install)  DO_INSTALL=1; shift ;;
        --model)    DO_INSTALL=1; DO_MODEL=1; shift ;;
        --clean)    DO_CLEAN=1; shift ;;
        --skip-deps) SKIP_DEPS=1; shift ;;
        --port)     PORT="$2"; shift 2 ;;
        --ctx)      CTX="$2"; shift 2 ;;
        --timeout)  HEALTH_TIMEOUT="$2"; shift 2 ;;
        --dir)      DRY_DIR="$2"; shift 2 ;;
        --quant)    QUANT="$2"; shift 2 ;;
        --build)    BUILD="$2"; shift 2 ;;
        -y|--yes)   ASSUME_YES=1; shift ;;
        -h|--help)  sed -n '2,/^$/p' "$0" | sed -e 's/^#\{1,\} \{0,1\}//' -e '/^$/d'; exit 0 ;;
        *) printf 'unknown option: %s (try --help)\n' "$1" >&2; exit 2 ;;
    esac
done

# ------------------------------------------------------------------ output --

if [ -t 1 ]; then
    G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; D=$'\033[90m'; B=$'\033[1m'; N=$'\033[0m'
else
    G=''; R=''; Y=''; D=''; B=''; N=''
fi

PASS=0; FAIL=0; WARN=0
ok()   { PASS=$((PASS+1)); printf '  %sPASS%s  %s\n' "$G" "$N" "$*"; }
bad()  { FAIL=$((FAIL+1)); printf '  %sFAIL%s  %s\n' "$R" "$N" "$*"; }
warn() { WARN=$((WARN+1)); printf '  %sWARN%s  %s\n' "$Y" "$N" "$*"; }
note() { printf '        %s%s%s\n' "$D" "$*" "$N"; }
skip() { printf '  %sSKIP%s  %s\n' "$D" "$N" "$*"; }
head_() { printf '\n%s%s%s\n' "$B" "$*" "$N"; }

# is $1 >= $2 ?
ver_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" = "$2" ]; }

# ------------------------------------------------------------------- clean --

if [ "$DO_CLEAN" -eq 1 ]; then
    printf 'removing dry-run artefacts\n'
    STATE="$HOME/.llm-dryrun.state"
    if [ -L "$HOME/.local/bin/llm" ]; then
        printf '  %s\n' "$HOME/.local/bin/llm -> $(readlink "$HOME/.local/bin/llm")"
        rm -f "$HOME/.local/bin/llm"
        printf '  removed the symlink\n'
    fi
    if [ -f "$STATE" ]; then
        PREV="$(cat "$STATE")"
        if [ -n "$PREV" ] && [ -e "$PREV" ]; then
            mkdir -p "$HOME/.local/bin"
            ln -sfn "$PREV" "$HOME/.local/bin/llm"
            printf '  put the old symlink back -> %s\n' "$PREV"
        fi
        rm -f "$STATE"
    fi
    if [ -d "$DRY_DIR" ]; then
        printf '  %s (%s)\n' "$DRY_DIR" "$(du -sh "$DRY_DIR" 2>/dev/null | cut -f1)"
        rm -rf "$DRY_DIR"
        printf '  removed\n'
    fi
    printf 'done. ~/.bashrc may still have a PATH line from install.sh; harmless.\n'
    exit 0
fi

printf '%sdry run%s  %s\n' "$B" "$N" "$(date -u '+%Y-%m-%d %H:%M:%SZ')"
printf 'nothing is installed or downloaded unless you pass --install or --model\n'

# ----------------------------------------------------------------- platform --

head_ "Platform"

if [ -r /etc/os-release ]; then
    . /etc/os-release
    printf '  distro   %s (ID=%s)\n' "${PRETTY_NAME:-unknown}" "${ID:-unknown}"
    case "${ID:-}" in
        debian) ok "Debian, install.sh will take the debian package branch" ;;
        ubuntu) ok "Ubuntu, install.sh will take the ubuntu package branch" ;;
        fedora|arch) ok "${ID}, install.sh knows this distro" ;;
        *) warn "${ID:-unknown} is not a distro install.sh has a package list for" ;;
    esac
else
    bad "cannot read /etc/os-release"
fi

GLIBC="$(ldd --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+$' || true)"
if [ -z "$GLIBC" ]; then
    bad "could not determine the glibc version"
else
    printf '  glibc    %s   (llama.cpp binary needs 2.34)\n' "$GLIBC"
    if ver_ge "$GLIBC" 2.34; then
        ok "glibc $GLIBC is new enough for the prebuilt binary"
    else
        bad "glibc $GLIBC is too old. Need 2.34. Debian 11 will not work; use 12 or 13."
    fi
fi

printf '  kernel   %s\n' "$(uname -r)"
case "$(uname -m)" in
    x86_64|amd64)   ok "x86_64, will fetch the x64 build" ;;
    aarch64|arm64) ok "aarch64, will fetch the arm64 build" ;;
    *) bad "$(uname -m) has no prebuilt Vulkan binary" ;;
esac

# ---------------------------------------------------------------- resources --

head_ "Resources"

AVAIL_MB="$(awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} END{printf "%d %d", t/1024, a/1024}' /proc/meminfo 2>/dev/null)"
set -- $AVAIL_MB
if [ -n "${1:-}" ]; then
    printf '  ram      %s MiB total, %s MiB available\n' "${1:-?}" "${2:-?}"
    if [ "${1:-0}" -ge 12000 ]; then
        ok "enough RAM to load a 9B quant"
    else
        warn "${1} MiB total. Q4_K_M is 5.7 GB and Q6_K is 7.5 GB, so a full load needs more than that."
    fi
else
    warn "could not read /proc/meminfo"
fi

NEED_MB=2000
[ "$DO_MODEL" -eq 1 ] && NEED_MB=8000
FREE_MB="$(df -Pm "$HOME" 2>/dev/null | awk 'NR==2{print $4}')"
if [ -n "${FREE_MB:-}" ]; then
    printf '  disk     %s MiB free in %s\n' "$FREE_MB" "$HOME"
    if [ "$FREE_MB" -ge "$NEED_MB" ]; then
        ok "enough free space ($NEED_MB MiB needed for this run)"
    else
        bad "need $NEED_MB MiB free in \$HOME, have $FREE_MB"
    fi
else
    warn "could not read free space for \$HOME"
fi

# ---------------------------------------------------------------------- gpu --
# All informational. A machine without a GPU can still install and start the
# server on the CPU, it will just be slow. None of this fails the run.

head_ "GPU (informational, will not fail the run)"

GPU_FOUND=0
if command -v lspci >/dev/null 2>&1; then
    GPU_LINE="$(lspci 2>/dev/null | grep -iE 'vga|3d controller|display' | head -3)"
    if [ -n "$GPU_LINE" ]; then
        GPU_FOUND=1
        printf '%s\n' "$GPU_LINE" | sed 's/^/  /'
    else
        printf '  lspci found no display or 3d controller\n'
    fi
else
    skip "lspci not installed (install.sh does not add it; pciutils if you want it)"
fi

VENDOR="unknown"
# Scan every card, not just card0. card0 is often a virtual device with no
# device/vendor at all, and the real GPU is card1.
for v in /sys/class/drm/card*/device/vendor; do
    [ -r "$v" ] || continue
    case "$(cat "$v" 2>/dev/null)" in
        0x1002) VENDOR="amd" ;;
        0x8086) VENDOR="intel" ;;
        0x10de) VENDOR="nvidia" ;;
    esac
    [ "$VENDOR" != "unknown" ] && break
done
printf '  vendor   %s\n' "$VENDOR"

if [ -d /dev/dri ]; then
    ls -l /dev/dri/ 2>/dev/null | tail -n +2 | sed 's/^/  /'
    RENDER_NODE="$(ls /dev/dri/renderD* 2>/dev/null | head -1)"
    if [ -n "$RENDER_NODE" ]; then
        if [ -r "$RENDER_NODE" ] && [ -w "$RENDER_NODE" ]; then
            ok "can read and write $RENDER_NODE"
        else
            bad "no access to $RENDER_NODE. Add yourself to the group that owns it"
            note "ls -l $RENDER_NODE   then: sudo usermod -aG <group> \$USER"
            note "and log out and back in. An already-open shell keeps the old groups."
        fi
    else
        warn "/dev/dri exists but has no renderD* node"
    fi
else
    skip "no /dev/dri, so no GPU acceleration. The server will run on the CPU."
fi

if [ "$VENDOR" = "amd" ]; then
    printf '  amdgpu blobs (Navi 2 / RX 6000 needs gc_11_0_3):\n'
    BLOBS="$(ls /lib/firmware/amdgpu/gc_11_0_3* 2>/dev/null | wc -l)"
    if [ "$BLOBS" -ge 7 ]; then
        ok "$BLOBS gc_11_0_3 blobs present"
    elif [ "$BLOBS" -gt 0 ]; then
        warn "only $BLOBS of 7 gc_11_0_3 blobs present, firmware is incomplete"
    else
        warn "no gc_11_0_3 blobs. On Debian that means non-free-firmware is not enabled."
        note "bookworm ships a firmware-amd-graphics too old for these; use backports or trixie"
    fi
fi

if [ "$VENDOR" = "nvidia" ]; then
    warn "NVIDIA needs the proprietary Vulkan ICD, which install.sh does not install"
fi

if command -v vulkaninfo >/dev/null 2>&1; then
    printf '  vulkaninfo:\n'
    VULKAN_OUT="$(vulkaninfo --summary 2>/dev/null || true)"
    if [ -z "$VULKAN_OUT" ]; then
        printf '    reported nothing\n'
        warn "vulkaninfo produced no output at all"
    else
        printf '%s\n' "$VULKAN_OUT" | grep -E 'deviceName|driverName|apiVersion' | sed 's/^/    /'
        # A software rasteriser listed next to a real GPU is normal and
        # harmless. It is only a problem when it is the only device there is.
        HW_DEV="$(printf '%s\n' "$VULKAN_OUT" | grep -E 'deviceName' \
                  | grep -viE 'llvmpipe|lavapipe|swiftshader|software' || true)"
        SW_DEV="$(printf '%s\n' "$VULKAN_OUT" | grep -E 'deviceName' \
                  | grep -iE 'llvmpipe|lavapipe|swiftshader|software' || true)"
        if [ -n "$HW_DEV" ]; then
            [ -n "$SW_DEV" ] && note "a software device is listed too, which is normal"
        elif [ -n "$SW_DEV" ]; then
            warn "only a software Vulkan device (llvmpipe/lavapipe). That is not GPU acceleration."
        else
            warn "vulkaninfo listed no devices"
        fi
    fi
else
    skip "vulkaninfo not installed yet, install.sh adds it"
fi

# -------------------------------------------------------------- packaging ---

head_ "Packages"

MISSING=""
for c in curl tmux python3; do
    command -v "$c" >/dev/null 2>&1 || MISSING="$MISSING $c"
done
if [ -n "$MISSING" ]; then
    note "install.sh will add:$MISSING"
    ok "no missing prerequisites that install.sh cannot handle"
else
    ok "curl, tmux and python3 all present"
fi

if [ -r /proc/version ] && grep -qi microsoft /proc/version 2>/dev/null; then
    warn "looks like WSL. /dev/dri and the render group behave differently there."
fi

if [ "${ID:-}" = "debian" ]; then
    if grep -rqs 'non-free' /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null; then
        ok "non-free is enabled in sources"
    else
        warn "non-free is not enabled. Needed for firmware-amd-graphics on an AMD card."
        note "add it, then: sudo apt update"
    fi
fi

if [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1; then
    if sudo -n true 2>/dev/null; then
        note "sudo works without a password"
    else
        note "sudo needs a password. --install will pause for it, which is fine"
        note "in an interactive shell. Over a non-interactive session, or if you"
        note "cannot sudo at all, add --skip-deps and install the packages yourself:"
        note "  sudo apt-get install -y curl tmux python3 libgomp1 libvulkan1 vulkan-tools mesa-vulkan-drivers"
    fi
fi

# ----------------------------------------------------------------- install --

if [ "$DO_INSTALL" -eq 0 ]; then
    head_ "Install"
    skip "not requested. Re-run with --install to actually install."
else
    head_ "Install (into $DRY_DIR)"

    if [ -L "$HOME/.local/bin/llm" ]; then
        PREV_TARGET="$(readlink "$HOME/.local/bin/llm")"
        if [ -f "$HOME/.llm-dryrun.state" ]; then
            note "symlink already repointed by an earlier run; keeping the original saved target"
        else
            warn "$HOME/.local/bin/llm already points at $PREV_TARGET"
            note "install.sh will repoint it at the dry-run dir."
            printf '%s' "$PREV_TARGET" > "$HOME/.llm-dryrun.state"
            note "saved, so --clean puts it back"
        fi
    fi

    ARGS=(--dir "$DRY_DIR" --build "$BUILD" --skip-models)
    [ "$DO_MODEL" -eq 1 ] && ARGS+=(--models "$QUANT")
    [ "$SKIP_DEPS" -eq 1 ] && ARGS+=(--skip-deps)
    [ "$ASSUME_YES" -eq 1 ] && ARGS+=(-y)

    printf '  ./install.sh %s\n\n' "${ARGS[*]}"
    if "$SELF_DIR/install.sh" "${ARGS[@]}"; then
        ok "install.sh completed"
    else
        bad "install.sh failed, see the output above"
    fi

    SRV="$DRY_DIR/llama/llama-server"
    if [ -x "$SRV" ]; then
        # llama-server logs a startup line before anything else, so grep for the
        # version rather than taking the first line. A too-old glibc shows up
        # here as a symbol lookup error instead of a version.
        VER_OUT="$("$SRV" --version 2>&1 || true)"
        VER="$(printf '%s\n' "$VER_OUT" | grep -m1 '^version:' || true)"
        if [ -n "$VER" ]; then
            ok "binary runs: $VER"
            printf '%s\n' "$VER_OUT" | grep -m1 'build ' | sed 's/^/        /'
        else
            bad "binary is present but will not execute. On Debian this is nearly always glibc."
            printf '%s\n' "$VER_OUT" | head -3 | sed 's/^/          /'
            note "check what it needs: objdump -T $SRV | grep -o 'GLIBC_[0-9.]*' | sort -uV | tail -3"
        fi
        if ldd "$SRV" 2>/dev/null | grep -q 'not found'; then
            bad "shared libraries missing:"
            ldd "$SRV" 2>/dev/null | grep 'not found' | sed 's/^/          /'
        else
            ok "all shared libraries resolve"
        fi
    else
        bad "no llama-server at $SRV"
    fi

    for s in llm up.sh start.sh stop.sh status.sh ask.sh common.sh llm-run; do
        [ -e "$DRY_DIR/$s" ] || bad "missing $DRY_DIR/$s"
    done
    [ -x "$DRY_DIR/llm" ] && ok "switch and scripts in place"
    [ -L "$HOME/.local/bin/llm" ] && ok "~/.local/bin/llm -> $(readlink "$HOME/.local/bin/llm")"
fi

# ------------------------------------------------------------- smoke test ---

if [ "$DO_MODEL" -eq 1 ]; then
    head_ "Start and stop"

    if [ ! -x "$DRY_DIR/llm" ]; then
        bad "nothing to start, install step did not produce a switch"
    else
        printf '  port %s, ctx %s, waiting up to %ss for the model to load\n' "$PORT" "$CTX" "$HEALTH_TIMEOUT"
        note "on CPU this is slow. That is fine, we only care that it starts."

        "$DRY_DIR/llm" on "$QUANT" "$PORT" >/dev/null 2>&1 &
        ON_PID=$!

        READY=0
        WAITED=0
        while [ "$WAITED" -lt "$HEALTH_TIMEOUT" ]; do
            if curl -fsS --max-time 5 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
                READY=1
                break
            fi
            kill -0 "$ON_PID" 2>/dev/null || break
            sleep 5
            WAITED=$((WAITED+5))
        done

        if [ "$READY" -eq 1 ]; then
            ok "healthy after ~${WAITED}s"
        else
            bad "never became healthy within ${HEALTH_TIMEOUT}s"
            note "log: tail -30 $DRY_DIR/logs/*p${PORT}.log"
        fi

        if [ "$READY" -eq 1 ]; then
            "$DRY_DIR/llm" status 2>&1 | sed 's/^/    /'
            printf '\n  sending a 4-token request:\n'
            T0=$(date +%s)
            RESP="$(curl -fsS --max-time 300 "http://127.0.0.1:$PORT/v1/chat/completions" \
                -H 'Content-Type: application/json' \
                -d "{\"model\":\"x\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with only the word: ok\"}],\"max_tokens\":4,\"chat_template_kwargs\":{\"enable_thinking\":false}}" \
                2>&1)"
            T1=$(date +%s)
            if printf '%s' "$RESP" | grep -q '"choices"'; then
                CONTENT="$(printf '%s' "$RESP" | sed -n 's/.*"content"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
                ok "got a reply in $((T1-T0))s: ${CONTENT:-<empty>}"
                note "no GPU here, so seconds per token is not comparable to a real card"
            else
                bad "request failed"
                note "$RESP"
            fi
        fi

        printf '\n  stopping\n'
        "$DRY_DIR/llm" off >/dev/null 2>&1
        wait "$ON_PID" 2>/dev/null
        sleep 2
        if pgrep -x llama-server >/dev/null 2>&1; then
            bad "llama-server is still running after llm off"
        else
            ok "stopped cleanly, port free"
        fi
    fi
fi

# ----------------------------------------------------------------- summary --

printf '\n%s%s%s\n' "$B" "----------------------------------------" "$N"
printf '  %spassed %s   %sfailed %s   %swarned %s%s\n' \
    "$G" "$PASS" "$R" "$FAIL" "$Y" "$WARN" "$N"

if [ "$DO_INSTALL" -eq 1 ] || [ "$DO_MODEL" -eq 1 ]; then
    printf '\n  installed into %s\n' "$DRY_DIR"
    printf '  undo with:  ./dry-run.sh --clean\n'
fi

if [ "$FAIL" -gt 0 ]; then
    printf '\n  %s%d check(s) failed.%s Not ready.\n' "$R" "$FAIL" "$N"
    exit 1
fi
printf '\n  %sNo blocking problems.%s\n' "$G" "$N"
exit 0
