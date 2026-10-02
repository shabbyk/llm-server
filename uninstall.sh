#!/usr/bin/env bash
# Remove parts of the local AI stack, tool by tool.
#
#   ./uninstall.sh                          # everything, software only
#   ./uninstall.sh ollama --remove-model    # Ollama and its model blobs,
#                                           #   leaving llama.cpp untouched
#   ./uninstall.sh llamacpp                 # llama.cpp runtime only
#   ./uninstall.sh llamacpp --remove-model  #   ...and the 5 GB GGUF
#   ./uninstall.sh tts --remove-model       # TTS and its 2.6 GB of weights
#   ./uninstall.sh webui rag --purge        # those two, with their state
#   ./uninstall.sh all --purge-all          # everything, including your content
#   ./uninstall.sh --dry-run                # print the plan; change nothing
#   ./uninstall.sh --list                   # what is installed, and how big
#
#   Tools:  ollama  llamacpp  tts  webui  rag
#   Groups: llm (ollama + llamacpp), all
#
# Data flags apply to whichever tools you named, so the same script can remove a
# 28 MB runtime while leaving a 6 GB download in place:
#
#   (none)          software only. The runtime, which is one download to restore.
#   --remove-model  also the model or weights: the large, slow downloads.
#   --purge         also logs, config and other state.
#   --purge-all     also your content: voice clips, documents, chat history.
#                   None of that can be downloaded again.
#
# Nothing outside $HOME is ever removed, and apt packages and the Rust toolchain
# are only ever reported, never deleted — they are shared with the rest of the
# machine.

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

B=$'\033[1m'; N=$'\033[0m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'
step() { printf '\n%s==>%s %s\n' "$B" "$N" "$*"; }
info() { printf '    %s\n' "$*"; }
ok()   { printf '    %s%s%s\n' "$G" "$*" "$N"; }
warn() { printf '    %swarning:%s %s\n' "$Y" "$N" "$*"; }
die()  { printf '    %serror:%s %s\n' "$R" "$N" "$*" >&2; exit 1; }

# --------------------------------------------------------------- the tools ---
# Each tool declares four kinds of thing. Keeping them separate is what lets
# `--remove-model` mean the 6 GB of blobs and nothing else.
ALL_TOOLS=(ollama llamacpp tts webui rag)

tool_software() { # the runtime: always removed when the tool is selected
    case "$1" in
        ollama)   printf '%s\n' "$BINDIR/ollama" "$HOME/.local/lib/ollama" ;;
        llamacpp) printf '%s\n' "$LLM_DIR/llamacpp" ;;
        tts)      printf '%s\n' "$TTS_DIR/bin" "$REPO_DIR/tts/target" ;;
        webui)    printf '%s\n' "$WEBUI_VENV" ;;
        rag)      printf '%s\n' "$RAG_VENV" ;;
    esac
}

tool_model() { # the downloads: --remove-model
    case "$1" in
        ollama)   printf '%s\n' "$HOME/.ollama" ;;
        llamacpp) printf '%s\n' "$LLM_DIR/models" ;;
        tts)      printf '%s\n' "$TTS_DIR/models" ;;
    esac
}

tool_state() { # logs, config, pids: --purge
    case "$1" in
        ollama)
            printf '%s\n' "$LLM_DIR/logs/ollama.log" "$LLM_DIR/logs/ollama.pid" ;;
        llamacpp)
            printf '%s\n' "$LLM_DIR/logs/llamacpp.log" \
                          "$LLM_DIR/logs/llamacpp.pid" \
                          "$LLM_DIR/logs/llamacpp-verify.log" ;;
        tts)
            printf '%s\n' "$TTS_DIR/logs" "$TTS_DIR/out" "$TTS_DIR/config.env" ;;
        webui)
            printf '%s\n' "$WEBUI_DIR/config.env" "$WEBUI_DIR/webui.log" "$WEBUI_DIR/webui.pid" ;;
        rag)
            printf '%s\n' "$RAG_DIR/logs" "$RAG_DIR/config.env" ;;
    esac
}

tool_content() { # yours: only --purge-all
    case "$1" in
        tts)   printf '%s\n' "$TTS_DIR/voices" ;;
        rag)   printf '%s\n' "$RAG_DIR/docs" ;;
        webui) printf '%s\n' "$WEBUI_DIR/data" ;;
    esac
}

# The `llm` command and ~/llm/config.env are shared by both engines. Deleting the
# command because Ollama left would take away llama.cpp's only way to start, so
# shared things are only touched when both engines are going.
engine_both() { selected ollama && selected llamacpp; }

shared_links() {
    engine_both    && printf '%s\n' "$BINDIR/llm"
    selected tts   && printf '%s\n' "$BINDIR/tts"
    selected webui && printf '%s\n' "$BINDIR/webui"
    selected rag   && printf '%s\n' "$BINDIR/rag"
    return 0
}

shared_state() {
    engine_both && printf '%s\n' "$LLM_DIR/config.env" "$LLM_DIR/logs" \
                            "$LLM_DIR"/config.env.*
    return 0
}

# Only under --purge-all: the containing directory, once nothing in it is wanted.
shared_content() {
    engine_both && printf '%s\n' "$LLM_DIR"
    return 0
}

# ---------------------------------------------------------------- helpers ----
describe() {
    local p="$1"
    if [ -L "$p" ];     then printf 'symlink'
    elif [ -d "$p" ];   then du -sh "$p" 2>/dev/null | cut -f1
    elif [ -e "$p" ];   then du -h  "$p" 2>/dev/null | cut -f1
    else                     printf 'missing'
    fi
}

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

# Print what a removal would take. No side effects at all: this is what the plan
# uses, so the preview can never be the execution.
show() {
    local p
    for p in "$@"; do
        [ -n "$p" ] || continue
        [ -e "$p" ] || [ -L "$p" ] || continue
        printf '    %-46s %s\n' "${p/#$HOME/~}" "$(describe "$p")"
    done
}

remove() {
    local p size
    for p in "$@"; do
        [ -n "$p" ] || continue
        [ -e "$p" ] || [ -L "$p" ] || continue

        # Nothing outside the home directory is ever a target. Every path here is
        # built under $HOME, so one that is not means a variable went wrong — and
        # a destructive script should fail closed on that rather than find out
        # afterwards.
        case "$p" in
            "$HOME"/*) ;;
            *) warn "refusing to remove $p — outside \$HOME"; continue ;;
        esac

        size="$(describe "$p")"
        if rm -rf -- "$p" 2>/dev/null; then
            printf '    removed  %-46s %s\n' "${p/#$HOME/~}" "$size"
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

usage() { sed -n '2,/^$/p' "$0" | sed -e 's/^#\{1,\} \{0,1\}//' -e '/^$/d'; }

# Drop duplicates and empty entries. mapfile leaves an empty element behind when
# a function emits nothing, and those must not reach the plan.
dedup() {
    local out=() p q seen
    for p in "$@"; do
        [ -n "$p" ] || continue
        seen=0
        for q in "${out[@]:-}"; do [ "$q" = "$p" ] && { seen=1; break; }; done
        [ "$seen" -eq 0 ] && out+=( "$p" )
    done
    [ "${#out[@]}" -gt 0 ] && printf '%s\n' "${out[@]}"
    return 0
}

# -------------------------------------------------------------- arguments ----
ASSUME_YES=0 ; DRY_RUN=0 ; LIST_ONLY=0
REMOVE_MODEL=0 ; PURGE=0 ; PURGE_ALL=0 ; REMOVE_TOOLCHAIN=0
TOOLS=()

selected() {
    local t
    for t in "${TOOLS[@]}"; do [ "$t" = "$1" ] && return 0; done
    return 1
}

add_tool() {
    case "$1" in
        llm)      TOOLS+=(ollama llamacpp) ;;
        all)      TOOLS=("${ALL_TOOLS[@]}") ;;
        ollama|llamacpp|tts|webui|rag) TOOLS+=("$1") ;;
        *)
            echo "uninstall: unknown tool '$1'" >&2
            echo "  tools:  ${ALL_TOOLS[*]}" >&2
            echo "  groups: llm (ollama + llamacpp), all" >&2
            exit 2
            ;;
    esac
}

while [ $# -gt 0 ]; do
    case "$1" in
        -y|--yes)           ASSUME_YES=1 ;;
        --dry-run|-n)       DRY_RUN=1 ;;
        --list|list)        LIST_ONLY=1 ;;
        --remove-model)     REMOVE_MODEL=1 ;;
        --purge)            REMOVE_MODEL=1; PURGE=1 ;;
        --purge-all)        REMOVE_MODEL=1; PURGE=1; PURGE_ALL=1 ;;
        --remove-toolchain) REMOVE_TOOLCHAIN=1 ;;
        --llm)              add_tool llm ;;
        --tts)              add_tool tts ;;
        --webui)            add_tool webui ;;
        --rag)              add_tool rag ;;
        -h|--help)          usage; exit 0 ;;
        -*)                 die "unknown option: $1 (try --help)" ;;
        *)                  add_tool "$1" ;;
    esac
    shift
done

# Naming nothing means everything, which is what a bare `uninstall.sh` has always
# done.
[ "${#TOOLS[@]}" -eq 0 ] && TOOLS=("${ALL_TOOLS[@]}")

# --------------------------------------------------------------- --list ------
if [ "$LIST_ONLY" -eq 1 ]; then
    printf '%s\n' "  ${B}Installed tools${N}"
    for t in "${ALL_TOOLS[@]}"; do
        mapfile -t sw < <(tool_software "$t")
        present="-"
        for p in "${sw[@]:-}"; do [ -e "$p" ] && present="installed"; done
        mapfile -t md < <(tool_model "$t")
        mapfile -t st < <(tool_state "$t")
        mapfile -t ct < <(tool_content "$t")
        md_s=$(total_bytes "${md[@]:-}"); st_s=$(total_bytes "${st[@]:-}"); ct_s=$(total_bytes "${ct[@]:-}")
        printf '  %-9s %-10s model: %-9s state: %-9s content: %s\n' \
            "$t" "$present" \
            "$([ "$md_s" -gt 0 ] && human "$md_s" || echo '-')" \
            "$([ "$st_s" -gt 0 ] && human "$st_s" || echo '-')" \
            "$([ "$ct_s" -gt 0 ] && human "$ct_s" || echo '-')"
    done
    exit 0
fi

# ---------------------------------------------------------- build the plan ---
SOFTWARE=() ; MODEL=() ; STATE=() ; CONTENT=() ; LINKS=()

for t in "${TOOLS[@]}"; do
    mapfile -t _a < <(tool_software "$t"); SOFTWARE+=( "${_a[@]:-}" )
    mapfile -t _a < <(tool_model    "$t"); [ "$REMOVE_MODEL" -eq 1 ] && MODEL+=( "${_a[@]:-}" )
    mapfile -t _a < <(tool_state    "$t"); [ "$PURGE" -eq 1 ]        && STATE+=( "${_a[@]:-}" )
    mapfile -t _a < <(tool_content  "$t"); [ "$PURGE_ALL" -eq 1 ]    && CONTENT+=( "${_a[@]:-}" )
done

mapfile -t _a < <(shared_links); LINKS+=( "${_a[@]:-}" )
[ "$PURGE" -eq 1 ]     && { mapfile -t _a < <(shared_state);   STATE+=( "${_a[@]:-}" ); }
[ "$PURGE_ALL" -eq 1 ] && { mapfile -t _a < <(shared_content); CONTENT+=( "${_a[@]:-}" ); }

mapfile -t SOFTWARE < <(dedup "${SOFTWARE[@]:-}")
mapfile -t MODEL    < <(dedup "${MODEL[@]:-}")
mapfile -t STATE    < <(dedup "${STATE[@]:-}")
mapfile -t CONTENT  < <(dedup "${CONTENT[@]:-}")
mapfile -t LINKS    < <(dedup "${LINKS[@]:-}")

# --------------------------------------------------------------- the plan ----
printf '%s\n' "  ${B}Local AI stack uninstaller${N}"
printf '  repo: %s\n' "$REPO_DIR"
[ "$DRY_RUN" -eq 1 ] && printf '  %smode: dry run — nothing will be changed%s\n' "$Y" "$N"

step "Plan"
printf '  tools: %s\n\n' "${TOOLS[*]}"

printf '  %sSOFTWARE%s  re-installable:                %s\n' "$B" "$N" "$(human "$(total_bytes "${SOFTWARE[@]:-}")")"
show "${SOFTWARE[@]:-}"
[ "${#SOFTWARE[@]}" -eq 0 ] && printf '    (nothing)\n'

if [ "$REMOVE_MODEL" -eq 1 ]; then
    printf '\n  %sMODELS%s    re-downloadable:               %s\n' "$B" "$N" "$(human "$(total_bytes "${MODEL[@]:-}")")"
    show "${MODEL[@]:-}"
    [ "${#MODEL[@]}" -eq 0 ] && printf '    (these tools have no models)\n'
else
    printf '\n  %sMODELS%s    kept (add --remove-model to delete)\n' "$B" "$N"
fi

if [ "$PURGE" -eq 1 ]; then
    printf '\n  %sSTATE%s     logs, config, pids:\n' "$B" "$N"
    show "${STATE[@]:-}"
    [ "${#STATE[@]}" -eq 0 ] && printf '    (none)\n'
fi

if [ "$PURGE_ALL" -eq 1 ]; then
    printf '\n  %sCONTENT%s   not downloadable again:        %s\n' "$R" "$N" "$(human "$(total_bytes "${CONTENT[@]:-}")")"
    show "${CONTENT[@]:-}"
    [ "${#CONTENT[@]}" -eq 0 ] && printf '    (none)\n'
fi

printf '\n  %sCOMMANDS%s  to unlink:\n' "$B" "$N"
show "${LINKS[@]:-}"
[ "${#LINKS[@]}" -eq 0 ] && printf '    (none)\n'

if [ "$PURGE_ALL" -eq 1 ]; then
    printf '\n  %sThis removes voice clips, documents and chat history.%s\n' "$R" "$N"
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
# Stop the servers before deleting their binaries, or they keep running with
# their files unlinked until the next reboot.
step "Stopping services"
_any=0
if selected ollama || selected llamacpp; then
    if [ -x "$BINDIR/llm" ]; then
        if "$BINDIR/llm" off >/dev/null 2>&1; then ok "llm stopped"; _any=1
        else info "llm: nothing to stop"; fi
    fi
fi
if selected tts && [ -x "$BINDIR/tts" ]; then
    if "$BINDIR/tts" off >/dev/null 2>&1; then ok "tts stopped"; _any=1
    else info "tts: nothing to stop"; fi
fi
if selected webui && [ -x "$BINDIR/webui" ]; then
    if "$BINDIR/webui" off >/dev/null 2>&1; then ok "webui stopped"; _any=1
    else info "webui: nothing to stop"; fi
fi
# RAG has no daemon: llama.cpp spawns it per tool call, so deleting the venv is
# enough.
[ "$_any" -eq 0 ] && info "no running services found"

step "Removing software"
remove "${SOFTWARE[@]:-}"

if [ "$REMOVE_MODEL" -eq 1 ]; then
    step "Removing models and weights"
    remove "${MODEL[@]:-}"
fi

if [ "$PURGE" -eq 1 ]; then
    step "Removing state"
    remove "${STATE[@]:-}"
fi

if [ "$PURGE_ALL" -eq 1 ]; then
    step "Removing your content"
    remove "${CONTENT[@]:-}"
fi

step "Removing commands"
remove "${LINKS[@]:-}"

# Revert the PATH line only when no command needs it any more. Removing it while
# llama.cpp remains installed would take away the `llm` command that starts it.
if [ "${#TOOLS[@]}" -eq "${#ALL_TOOLS[@]}" ]; then
    step "Restoring ~/.bashrc"
    if grep -q 'user-local binaries' "$HOME/.bashrc" 2>/dev/null; then
        cp "$HOME/.bashrc" "$HOME/.bashrc.bak-uninstall"
        python3 - "$HOME/.bashrc" <<'PY'
import re, sys
path = sys.argv[1]
out, pending = [], False
for line in open(path):
    # The comment has been worded differently across installer versions ("llm
    # on/off switch", "llm / tts switches"), so match it loosely and drop the
    # export that followed it. A strict match would silently leave the line.
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
    info "tools remain, and their commands still need ~/.local/bin on PATH"
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
printf '  Shared with the rest of the machine, so never deleted:\n'
for c in cc gcc make vulkaninfo uv rustup; do
    command -v "$c" >/dev/null 2>&1 && printf '    %-12s %s\n' "$c" "$(command -v "$c")"
done
printf '    %-12s apt packages:   sudo apt remove build-essential libvulkan1 vulkan-tools\n' ""
printf '    %-12s Rust toolchain: rustup self uninstall   (or --remove-toolchain)\n' ""

if [ "$REMOVE_MODEL" -ne 1 ]; then
    step "Data still on disk"
    found=0
    for t in "${TOOLS[@]}"; do
        mapfile -t md < <(tool_model "$t")
        for p in "${md[@]:-}"; do
            [ -e "$p" ] || continue
            printf '    %-46s %s\n' "${p/#$HOME/~}" "$(describe "$p")"
            found=1
        done
    done
    if [ "$found" -eq 1 ]; then
        printf '  Remove it with: ./uninstall.sh %s --remove-model\n' "${TOOLS[*]}"
    else
        info "none found"
    fi
fi

if [ "$PURGE_ALL" -ne 1 ]; then
    found=0
    for t in "${TOOLS[@]}"; do
        mapfile -t ct < <(tool_content "$t")
        for p in "${ct[@]:-}"; do
            [ -e "$p" ] || continue
            [ "$found" -eq 0 ] && { step "Your content, untouched"; found=1; }
            printf '    %-46s %s\n' "${p/#$HOME/~}" "$(describe "$p")"
        done
    done
    [ "$found" -eq 1 ] && printf '  Remove it with: ./uninstall.sh %s --purge-all\n' "${TOOLS[*]}"
fi

step "Done"
echo "  Removed: ${TOOLS[*]}"
[ "$REMOVE_MODEL" -ne 1 ] && echo "  Models kept, so a re-install reuses them instead of downloading again."
printf '\n    Re-install with:  ./install.sh\n'
