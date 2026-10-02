#!/usr/bin/env bash
# Remove the local AI stack that install.sh installed.
#
#   ./uninstall.sh                 # remove the software, keep your data
#   ./uninstall.sh --dry-run       # print what would go; change nothing
#   ./uninstall.sh --purge         # also remove models and weights (~14 GB)
#   ./uninstall.sh --purge-all     # ...and your voice clips, documents, chats
#   ./uninstall.sh --llm --rag     # only those components
#   ./uninstall.sh --yes           # no prompts
#   ./uninstall.sh --remove-toolchain
#   ./uninstall.sh --help
#
# The tiers are the whole design, so they are worth reading once.
#
#   DEFAULT removes software, which can be fetched again:
#     the runtimes (Ollama, llama.cpp), the Python virtualenvs, the TTS engine,
#     the `llm` / `tts` / `webui` / `rag` commands, and the PATH line the
#     installer added to ~/.bashrc. About 5 GB.
#
#   --purge also removes data, which is slow to fetch again:
#     the models and weights — around 14 GB of downloads — plus logs and config
#     files. Your own content is still left alone.
#
#   --purge-all also removes your content: voice clips, documents, and the chat
#     database. That is neither downloadable nor recoverable.
#
#   NEVER removed, whatever you pass:
#     system packages installed with apt (build-essential, libvulkan1) and the
#     Rust toolchain. Those are shared with the rest of the machine, and deleting
#     them because this stack is going away is how a cleanup turns into an
#     outage. They are listed at the end so you can decide yourself.
#
# The repository clone is left in place too — you are running this from it.

set -uo pipefail
# Deliberately not `set -e`: one path failing to delete should not abandon the
# rest of the removal half-done.

REPO_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

BINDIR="${BINDIR:-$HOME/.local/bin}"
LLM_DIR="${LLM_DIR:-$HOME/llm}"
TTS_DIR="${TTS_DIR:-$HOME/tts}"
WEBUI_DIR="${WEBUI_DIR:-$HOME/.openwebui}"
WEBUI_VENV="${WEBUI_VENV:-$HOME/.venvs/openwebui}"
RAG_DIR="${RAG_DIR:-$HOME/rag}"
RAG_VENV="${RAG_VENV:-$HOME/.venvs/rag}"

OLLAMA_BIN="$BINDIR/ollama"
OLLAMA_LIB="$HOME/.local/lib/ollama"

B=$'\033[1m'; N=$'\033[0m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'
step() { printf '\n%s==>%s %s\n' "$B" "$N" "$*"; }
info() { printf '    %s\n' "$*"; }
ok()   { printf '    %s%s%s\n' "$G" "$*" "$N"; }
warn() { printf '    %swarning:%s %s\n' "$Y" "$N" "$*"; }
die()  { printf '    %serror:%s %s\n' "$R" "$N" "$*" >&2; exit 1; }

ASSUME_YES=0 ; DRY_RUN=0 ; PURGE=0 ; PURGE_ALL=0 ; REMOVE_TOOLCHAIN=0
WANT_LLM="" ; WANT_TTS="" ; WANT_WEBUI="" ; WANT_RAG="" ; SELECTED=0

usage() { sed -n '2,/^$/p' "$0" | sed -e 's/^#\{1,\} \{0,1\}//' -e '/^$/d'; }

while [ $# -gt 0 ]; do
    case "$1" in
        -y|--yes)           ASSUME_YES=1 ;;
        --dry-run|-n)       DRY_RUN=1 ;;
        --purge)            PURGE=1 ;;
        --purge-all)        PURGE=1; PURGE_ALL=1 ;;
        --remove-toolchain) REMOVE_TOOLCHAIN=1 ;;
        --llm)              WANT_LLM=1;   SELECTED=1 ;;
        --tts)              WANT_TTS=1;   SELECTED=1 ;;
        --webui)            WANT_WEBUI=1; SELECTED=1 ;;
        --rag)              WANT_RAG=1;   SELECTED=1 ;;
        -h|--help)          usage; exit 0 ;;
        *)                  die "unknown option: $1 (try --help)" ;;
    esac
    shift
done

# Naming a component selects it; naming none means all of them.
if [ "$SELECTED" -eq 0 ]; then
    WANT_LLM=1; WANT_TTS=1; WANT_WEBUI=1; WANT_RAG=1
fi

# ---------------------------------------------------------------- helpers ----
# Human-readable size. Symlinks are reported as such rather than followed, or
# every link would appear to be as large as its target.
describe() {
    local p="$1"
    if [ -L "$p" ];     then printf 'symlink'
    elif [ -d "$p" ];   then du -sh "$p" 2>/dev/null | cut -f1
    elif [ -e "$p" ];   then du -h  "$p" 2>/dev/null | cut -f1
    else                     printf 'missing'
    fi
}

# Total bytes across paths. Symlinks are skipped so their targets are not
# counted twice.
total_bytes() {
    local p sum=0 b
    for p in "$@"; do
        [ -e "$p" ] || continue
        [ -L "$p" ] && continue
        b="$(du -sb "$p" 2>/dev/null | cut -f1)"
        sum=$(( sum + ${b:-0} ))
    done
    printf '%s' "$sum"
}

human() {
    awk -v b="${1:-0}" 'BEGIN{ split("B KB MB GB TB",u," "); i=1; while (b>=1024 && i<5){b/=1024;i++} printf "%.1f %s", b, u[i] }'
}

# Print what a removal would take. No side effects at all — this is what the plan
# uses, so the preview cannot accidentally be the execution.
show() {
    local p
    for p in "$@"; do
        [ -e "$p" ] || [ -L "$p" ] || continue
        printf '    %-48s %s\n' "${p/#$HOME/~}" "$(describe "$p")"
    done
}

# Actually remove. The size is captured *before* the delete, because afterwards
# there is nothing left to measure and every line would read "missing".
remove() {
    local p size
    for p in "$@"; do
        [ -e "$p" ] || [ -L "$p" ] || continue

        # Nothing outside the home directory is ever a target. Every path this
        # script builds is under $HOME, so a path that is not means a variable
        # went wrong — and a destructive script should fail closed on that rather
        # than discover it after deleting something shared.
        case "$p" in
            "$HOME"/*) ;;
            *) warn "refusing to remove $p — outside $HOME"; continue ;;
        esac

        size="$(describe "$p")"
        if rm -rf -- "$p" 2>/dev/null; then
            printf '    removed  %-48s %s\n' "${p/#$HOME/~}" "$size"
        else
            warn "could not remove $p"
        fi
    done
}

confirm() {
    [ "$ASSUME_YES" -eq 1 ] && return 0
    local reply
    printf '  %s [y/N] ' "$1"
    read -r reply || reply=""
    case "$reply" in [Yy]*) return 0 ;; *) return 1 ;; esac
}

# ------------------------------------------------------- build the plan ------
SOFTWARE=() ; DOWNLOAD=() ; LINK=()

[ "$WANT_LLM" = 1 ] && SOFTWARE+=(
    "$OLLAMA_BIN" "$OLLAMA_LIB" "$LLM_DIR/llamacpp"
)
[ "$WANT_TTS" = 1 ] && SOFTWARE+=(
    "$TTS_DIR/bin" "$REPO_DIR/tts/target"
)
[ "$WANT_WEBUI" = 1 ] && SOFTWARE+=( "$WEBUI_VENV" )
[ "$WANT_RAG" = 1 ]   && SOFTWARE+=( "$RAG_VENV" )

[ "$WANT_LLM" = 1 ]   && LINK+=( "$BINDIR/llm" )
[ "$WANT_TTS" = 1 ]   && LINK+=( "$BINDIR/tts" )
[ "$WANT_WEBUI" = 1 ] && LINK+=( "$BINDIR/webui" )
[ "$WANT_RAG" = 1 ]   && LINK+=( "$BINDIR/rag" )

if [ "$PURGE_ALL" -eq 1 ]; then
    # Whole directories, which subsumes every finer path and takes the content
    # with them.
    [ "$WANT_LLM" = 1 ]   && DOWNLOAD+=( "$LLM_DIR" "$HOME/.ollama" )
    [ "$WANT_TTS" = 1 ]   && DOWNLOAD+=( "$TTS_DIR" )
    [ "$WANT_WEBUI" = 1 ] && DOWNLOAD+=( "$WEBUI_DIR" )
    [ "$WANT_RAG" = 1 ]   && DOWNLOAD+=( "$RAG_DIR" )
elif [ "$PURGE" -eq 1 ]; then
    [ "$WANT_LLM" = 1 ] && DOWNLOAD+=(
        "$LLM_DIR/models" "$HOME/.ollama" "$LLM_DIR/logs" "$LLM_DIR/config.env"
    )
    [ "$WANT_TTS" = 1 ] && DOWNLOAD+=(
        "$TTS_DIR/models" "$TTS_DIR/logs" "$TTS_DIR/out" "$TTS_DIR/config.env"
    )
    [ "$WANT_WEBUI" = 1 ] && DOWNLOAD+=( "$WEBUI_DIR/config.env" )
    [ "$WANT_RAG" = 1 ]   && DOWNLOAD+=( "$RAG_DIR/config.env" "$RAG_DIR/logs" )

    # Config files the installer moved aside across versions. Globbed, so each
    # one is checked for existence rather than assumed.
    for bak in "$LLM_DIR"/config.env.*; do
        [ -e "$bak" ] && DOWNLOAD+=( "$bak" )
    done
fi

# --------------------------------------------------------------- the plan ----
printf '%s\n' "  ${B}Local AI stack uninstaller${N}"
printf '  repo: %s\n' "$REPO_DIR"
[ "$DRY_RUN" -eq 1 ] && printf '  %smode: dry run — nothing will be changed%s\n' "$Y" "$N"

step "Plan"

comps=""
[ "$WANT_LLM" = 1 ]   && comps="$comps llm"
[ "$WANT_TTS" = 1 ]   && comps="$comps tts"
[ "$WANT_WEBUI" = 1 ] && comps="$comps webui"
[ "$WANT_RAG" = 1 ]   && comps="$comps rag"
printf '  components: %s\n\n' "$comps"

printf '  %sSOFTWARE%s to remove — re-installable:        %s\n' "$B" "$N" "$(human "$(total_bytes "${SOFTWARE[@]}")")"
show "${SOFTWARE[@]}"

if [ "$PURGE" -eq 1 ]; then
    printf '\n  %sDATA%s to remove — re-downloadable:            %s\n' "$B" "$N" "$(human "$(total_bytes "${DOWNLOAD[@]}")")"
    if [ "$PURGE_ALL" -eq 1 ]; then
        printf '    %sincluding your voice clips, documents and chat history%s\n' "$R" "$N"
    fi
    show "${DOWNLOAD[@]}"
else
    printf '\n  %sDATA%s kept: models, weights, logs, configs\n' "$B" "$N"
fi

printf '\n  %sCOMMANDS%s to unlink:\n' "$B" "$N"
for p in "${LINK[@]}"; do
    [ -e "$p" ] || [ -L "$p" ] || { printf '    %-48s not present\n' "${p/#$HOME/~}"; continue; }
    printf '    %-48s -> %s\n' "${p/#$HOME/~}" "$(readlink "$p" 2>/dev/null || echo file)"
done

if [ "$PURGE_ALL" -eq 1 ]; then
    printf '\n  %sThis removes voice clips, documents and chat history.%s\n' "$R" "$N"
    printf '  None of it is downloadable again.\n'
fi

if [ "$DRY_RUN" -eq 1 ]; then
    printf '\n  %sdry run: stopping nothing, editing nothing, deleting nothing%s\n' "$Y" "$N"
    exit 0
fi

if ! confirm "Proceed?"; then
    echo "  cancelled — nothing was changed."
    exit 0
fi

# ---------------------------------------------------------------- act --------
# Stop the servers *before* deleting their binaries, or they keep running with
# their files unlinked until the next reboot.
step "Stopping services"
stopped=0
for sw in llm tts webui; do
    [ -x "$BINDIR/$sw" ] || continue
    if "$BINDIR/$sw" off >/dev/null 2>&1; then
        ok "$sw stopped"
        stopped=1
    else
        info "$sw: nothing to stop, or it refused"
    fi
done
[ "$stopped" -eq 0 ] && info "no running services found"
# RAG has no daemon — llama.cpp spawns it per tool call — so deleting the
# virtualenv is enough.

step "Removing software"
remove "${SOFTWARE[@]}"

if [ "$PURGE" -eq 1 ]; then
    step "Removing data"
    remove "${DOWNLOAD[@]}"
fi

step "Removing commands"
remove "${LINK[@]}"

# Revert the PATH line only when nothing needs it any more. If a component
# remains, its command still lives in ~/.local/bin.
if [ "$SELECTED" -eq 0 ]; then
    step "Restoring ~/.bashrc"
    if grep -q 'user-local binaries' "$HOME/.bashrc" 2>/dev/null; then
        cp "$HOME/.bashrc" "$HOME/.bashrc.bak-uninstall"
        python3 - "$HOME/.bashrc" <<'PY'
import re, sys
path = sys.argv[1]
out, pending = [], False
for line in open(path):
    # The comment has been worded differently across installer versions
    # ("llm on/off switch", "llm / tts switches"), so match it loosely and then
    # drop the export that followed it.
    if re.match(r'\s*#\s*user-local binaries', line):
        pending = True
        continue
    if pending and re.match(r'\s*export\s+PATH=.*\.local/bin', line):
        pending = False
        continue
    pending = False
    out.append(line)
open(path, "w").writelines(out)
PY
        ok "removed the PATH block (backup: ~/.bashrc.bak-uninstall)"
    else
        info "nothing to revert"
    fi
else
    step "Leaving ~/.bashrc alone"
    info "components remain, so their commands still need ~/.local/bin on PATH"
fi

if [ "$REMOVE_TOOLCHAIN" -eq 1 ]; then
    step "Removing the Rust toolchain"
    warn "this deletes ~/.cargo and ~/.rustup — any other Rust project here loses them"
    if confirm "Remove the Rust toolchain?"; then
        rm -rf -- "$HOME/.cargo" "$HOME/.rustup"
        ok "removed ~/.cargo and ~/.rustup"
    else
        info "kept"
    fi
fi

# ------------------------------------------------------------- leftovers -----
step "Left in place"
printf '  Shared with the rest of the machine, so not touched:\n'
for c in cc gcc make vulkaninfo uv rustup; do
    if command -v "$c" >/dev/null 2>&1; then printf '    %-12s %s\n' "$c" "$(command -v "$c")"; fi
done
printf '    %-12s apt packages:  sudo apt remove build-essential libvulkan1 vulkan-tools\n' ""
printf '    %-12s Rust toolchain: rustup self uninstall   (or --remove-toolchain)\n' ""

if [ "$PURGE" -ne 1 ]; then
    step "Data still on disk"
    found=0
    for p in "$LLM_DIR/models" "$HOME/.ollama" "$TTS_DIR/models"; do
        [ -e "$p" ] || continue
        printf '    %-48s %s\n' "${p/#$HOME/~}" "$(describe "$p")"
        found=1
    done
    if [ "$found" -eq 1 ]; then
        printf '  Remove it with: ./uninstall.sh --purge\n'
    else
        info "none found"
    fi
fi

if [ "$PURGE_ALL" -ne 1 ]; then
    found=0
    for p in "$TTS_DIR/voices" "$RAG_DIR/docs" "$WEBUI_DIR/data"; do
        [ -e "$p" ] || continue
        [ "$found" -eq 0 ] && { step "Your content, untouched"; found=1; }
        printf '    %-48s %s\n' "${p/#$HOME/~}" "$(describe "$p")"
    done
    [ "$found" -eq 1 ] && printf '  Remove it with: ./uninstall.sh --purge-all\n'
fi

step "Done"
if [ "$PURGE_ALL" -eq 1 ]; then
    echo "  Everything this installer created has been removed."
elif [ "$PURGE" -eq 1 ]; then
    echo "  Software and downloads are gone. Your content remains, along with"
    echo "  the repository clone."
else
    echo "  Software is gone. Models, weights and your content remain, so a"
    echo "  re-install will reuse them instead of downloading them again."
fi
cat <<EOF

    Re-install with:  ./install.sh
    Remove the clone: rm -rf $REPO_DIR
EOF
