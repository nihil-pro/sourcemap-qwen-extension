#!/usr/bin/env bash
# PostToolUse hook (matcher: "^(edit|replace|write_file)$").

# Records the edited/written file's path into this session's "dirty" list,
# so hook_sync_on_stop.sh can trigger a scoped ::meta refresh for exactly the files that actually changed this session.

# Fast and synchronous: no LLM call here, just a state-file append

# "replace" is a legacy alias for "edit" (confirmed in qwen-code source); matching both costs nothing and covers older callers.
# field name verified directly against real tool_use events for all three tools — edit/replace/write_file all use "file_path".

set -uo pipefail

INPUT="$(cat)"
SESSION_ID="$(jq -r '.session_id // empty' <<<"$INPUT")"
FILE_PATH="$(jq -r '.tool_input.file_path // empty' <<<"$INPUT")"

[[ -n "$SESSION_ID" && -n "$FILE_PATH" ]] || exit 0

ROOT_DIR="${QWEN_PROJECT_DIR:-$(pwd)}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_SCRIPT="$SCRIPT_DIR/lib.sh"
[[ -f "$LIB_SCRIPT" ]] && source "$LIB_SCRIPT"

# Only track paths inside the project root.
case "$FILE_PATH" in
  "$ROOT_DIR"/*) REL_PATH="${FILE_PATH#"$ROOT_DIR"/}" ;;
  *) exit 0 ;;
esac

# Skip anything under an ignored directory (node_modules, dist, .qwen,
# etc.) or a self-describing file — routes.yaml has no node for these
# anyway, so there'd be nothing to refresh.
if declare -F is_ignored >/dev/null 2>&1; then
  IFS='/' read -ra segs <<<"$REL_PATH"
  for seg in "${segs[@]}"; do
    is_ignored "$seg" && exit 0
  done
  is_self_describing "$(basename "$REL_PATH")" && exit 0
fi

DIRTY_DIR="$ROOT_DIR/${DEFAULT_OUTPUT_FILE:-.qwen/sourcemap/routes.yaml}"
DIRTY_DIR="$(dirname "$DIRTY_DIR")/.dirty-sessions"
mkdir -p "$DIRTY_DIR"
find "$DIRTY_DIR" -maxdepth 1 -name '*.json' -mtime +7 -delete 2>/dev/null || true

DIRTY_FILE="$DIRTY_DIR/$SESSION_ID.json"
[[ -f "$DIRTY_FILE" ]] || printf '{"files":[]}' > "$DIRTY_FILE"

# mkdir is atomic on both macOS and Linux, so it doubles as a cheap lock
# against a rare concurrent call for the same session.
LOCK_DIR="$DIRTY_FILE.lock"
for _ in $(seq 1 50); do
  mkdir "$LOCK_DIR" 2>/dev/null && break
  sleep 0.02
done
UPDATED="$(jq --arg p "$REL_PATH" '.files = ((.files // []) + [$p] | unique)' "$DIRTY_FILE")"
printf '%s' "$UPDATED" > "$DIRTY_FILE"
rmdir "$LOCK_DIR" 2>/dev/null || true

exit 0
