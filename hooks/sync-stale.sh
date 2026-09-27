#!/usr/bin/env bash
# Stop hook.
# Keeps graph.json/ctx.json in sync with the filesystem after each turn by re-running `deepgraph build`,
# which is fast enough to do synchronously (static analysis only, no LLM).

# In a git repo, only runs when `git status --porcelain` shows any change;
# without git (or outside a repo), always runs.

# Only surfaces a systemMessage to the user when files were added or removed; a no-op sync stays silent.

# Then, if any file's note is missing or stale (its content hash moved since the note was written),
# spawns annotate.sh in the BACKGROUND to (re)write exactly those notes, so a content refresh never delays this turn.
# Staleness comes from deepgraph's content hashes, so it covers every change, not just the ones made through the agent's own edit tools.

# Does nothing until bootstrap.sh's background run has built deepgraph and the first graph.

set -uo pipefail

cat >/dev/null  # drain stdin; Stop's input isn't needed here

ROOT_DIR="${QWEN_PROJECT_DIR:-$(pwd)}"
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_SCRIPT="$HOOK_DIR/scripts/lib.sh"
ANNOTATE_SCRIPT="$HOOK_DIR/scripts/annotate.sh"

[[ -f "$LIB_SCRIPT" ]] || exit 0
# shellcheck source=scripts/lib.sh
source "$LIB_SCRIPT"

OUT_DIR="$ROOT_DIR/$SOURCEMAP_REL_DIR"
[[ -x "$DEEPGRAPH_BIN" && -f "$OUT_DIR/graph.json" && -f "$OUT_DIR/ctx.json" ]] || exit 0
init_error_log "$ROOT_DIR" || exit 0

if [[ -d "$ROOT_DIR/.git" ]] && command -v git >/dev/null 2>&1; then
  [[ -n "$(git -C "$ROOT_DIR" status --porcelain 2>/dev/null)" ]] || exit 0
fi

load_settings "$ROOT_DIR"

# annotate.sh only holds this lock for a single ctx.json write; if it can't be had within ~1s, skip this turn's sync
# rather than risk the hook timeout; the next Stop (or session start) catches up.
WRITE_LOCK="$OUT_DIR/.write.lock"
wait_lock "$WRITE_LOCK" 20 || exit 0
trap 'release_lock "$WRITE_LOCK"' EXIT

before="$(jq -r 'keys[]' "$OUT_DIR/ctx.json")"
# deepgraph_build logs its own failures
deepgraph_build "$ROOT_DIR" || exit 0
after="$(jq -r 'keys[]' "$OUT_DIR/ctx.json")"
pending="$(enumerate_pending "$OUT_DIR")"

release_lock "$WRITE_LOCK"
trap - EXIT

added="$(comm -13 <(printf '%s\n' "$before" | sort) <(printf '%s\n' "$after" | sort) | sed '/^$/d')"
removed="$(comm -23 <(printf '%s\n' "$before" | sort) <(printf '%s\n' "$after" | sort) | sed '/^$/d')"

output=""
[[ -n "$added" ]] && output="Added to sourcemap:"$'\n'"$(sed 's/^/  + /' <<<"$added")"
[[ -n "$removed" ]] && output="${output:+$output$'\n'}Removed from sourcemap:"$'\n'"$(sed 's/^/  - /' <<<"$removed")"
[[ -n "$output" ]] && jq -n --arg msg "$output" '{systemMessage: $msg}'

if [[ -n "$pending" && -x "$ANNOTATE_SCRIPT" ]] && annotation_enabled; then
  nohup "$ANNOTATE_SCRIPT" "$ROOT_DIR" >/dev/null &
  disown 2>/dev/null || true
fi

exit 0
