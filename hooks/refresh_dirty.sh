#!/usr/bin/env bash
#
# refresh_dirty.sh — refreshes ::meta (context/depends) for files marked
# dirty by mark_dirty.sh this session, then recomputes the "dependents"
# graph. Spawned in the BACKGROUND (detached, non-blocking) by
# hook_sync_on_stop.sh once structural sync is done, so it never delays
# the user's turn — see that script for the launch side.
#
# Runs with `qwen -e none` — NOT --safe-mode. Hooks apply to *any* qwen
# invocation in this project (same risk documented in
# prompt_boundaries.sh's header), so something must stop this nested
# invocation from re-triggering our own SessionStart/UserPromptSubmit/Stop
# hooks — unbounded recursive process spawning otherwise. `-e none`
# disables this extension specifically (hooks *and* agents), which is
# both sufficient and narrower than --safe-mode: it leaves skills/MCP/
# QWEN.md intact, which --safe-mode would strip and which this pass can
# genuinely use. Verified directly (see prior investigation): a nested
# `-e none` invocation shows zero routes-* hook firings and no
# sourcemap-scout in its agent list.
#
# The model is asked for *content only*, via --json-schema
# structured_output, and never touches routes.yaml directly — that's
# applied mechanically by apply_updates.sh afterward. This is deliberate:
# a model can mis-format YAML in ways that are individually plausible but
# break the file; asking it only for {path, context, depends} and
# patching those exact fields ourselves means it structurally cannot
# corrupt the tree even if it wanted to.
#
# Guarded by a project-wide lock (not just per-session): multiple
# interactive sessions against the same project could each trigger a
# refresh, and without a lock two concurrent runs writing routes.yaml
# could race and silently lose one's update. A run that can't acquire the
# lock exits without clearing the session's dirty list, so those files
# stay queued and get picked up next time this session's Stop hook fires.
#
# CRITICAL: the message is passed via --prompt, never as a bare
# positional argument. Confirmed by direct testing: a positional prompt
# containing a "#" character anywhere makes qwen's CLI parsing silently
# misread it and fail with "No input provided via stdin" — and since
# $message embeds the full raw content of every dirty file, a "#"
# appearing ANYWHERE in ANY of them (Python/shell/Ruby comments, CSS hex
# colors, a markdown heading, ...) would have silently broken this. Our
# own test files happened not to contain one, which is why this passed
# earlier testing despite the bug being present the whole time.
#
# Usage: ./refresh_dirty.sh <root_dir> <session_id>

set -uo pipefail

ROOT_DIR="${1:?root_dir required}"
SESSION_ID="${2:?session_id required}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_SCRIPT="$SCRIPT_DIR/lib.sh"
[[ -f "$LIB_SCRIPT" ]] && source "$LIB_SCRIPT"

ROUTES_FILE="$ROOT_DIR/${DEFAULT_OUTPUT_FILE:-.qwen/sourcemap/routes.yaml}"
DIRTY_DIR="$(dirname "$ROUTES_FILE")/.dirty-sessions"
DIRTY_FILE="$DIRTY_DIR/$SESSION_ID.json"

[[ -f "$ROUTES_FILE" ]] || exit 0
[[ -f "$DIRTY_FILE" ]] || exit 0

MODEL="${SOURCEMAP_REFRESH_MODEL:-qwen/qwen3.8-27b}"
MAX_TOOL_CALLS="${SOURCEMAP_REFRESH_MAX_TOOL_CALLS:-10}"

LOCK_DIR="$(dirname "$ROUTES_FILE")/.refresh.lock"
mkdir "$LOCK_DIR" 2>/dev/null || exit 0
updates_tmp=""
trap 'rm -f "$updates_tmp"; rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT

# Snapshot and clear this session's dirty list up front, so edits made
# *during* this refresh (a quick follow-up turn) get queued for next
# time instead of racing this run.
paths_json="$(jq -c '.files // []' "$DIRTY_FILE" 2>/dev/null || echo '[]')"
rm -f "$DIRTY_FILE"

[[ "$(jq 'length' <<<"$paths_json" 2>/dev/null || echo 0)" -gt 0 ]] || exit 0

# The system prompt and the message template's static prefix live in
# sibling .md files — plain prompt content, no shell-escaping needed
# there (unlike the inline single-quoted string this replaced, which
# needed the '"'"' trick to embed a literal apostrophe). Read verbatim;
# if either is missing, there's nothing sane to send the model.
SYSTEM_PROMPT_FILE="$SCRIPT_DIR/refresh-dirty.system.md"
MESSAGE_TEMPLATE_FILE="$SCRIPT_DIR/refresh-dirty.message.md"
[[ -f "$SYSTEM_PROMPT_FILE" && -f "$MESSAGE_TEMPLATE_FILE" ]] || exit 0

# Build one combined message: the static template followed by the full
# current content of every dirty file that still exists (one may have
# been deleted since being marked dirty; skip it — sync.sh already
# dropped it from routes.yaml, nothing to do).
message="$(cat "$MESSAGE_TEMPLATE_FILE")"
sent_any=false
while IFS= read -r rel; do
  abs="$ROOT_DIR/$rel"
  [[ -f "$abs" ]] || continue
  content="$(cat "$abs" 2>/dev/null)"
  message="$message

=== File: $rel ===
$content"
  sent_any=true
done < <(jq -r '.[]' <<<"$paths_json")

[[ "$sent_any" == true ]] || exit 0

system_prompt="$(cat "$SYSTEM_PROMPT_FILE")"

schema='{"type":"object","properties":{"files":{"type":"array","items":{"type":"object","properties":{"path":{"type":"string"},"context":{"type":"string"},"depends":{"type":"array","items":{"type":"string"}}},"required":["path","context","depends"]}}},"required":["files"]}'

raw_output="$(
  cd "$ROOT_DIR" && qwen -e none -m "$MODEL" \
    --system-prompt "$system_prompt" \
    --output-format json \
    --max-tool-calls "$MAX_TOOL_CALLS" \
    --json-schema "$schema" \
    --prompt "$message" 2>/dev/null
)"
[[ $? -eq 0 ]] || exit 0

files_json="$(printf '%s' "$raw_output" | jq -c '.[-1].structured_result.files // empty' 2>/dev/null)"
[[ -n "$files_json" && "$files_json" != "null" ]] || exit 0

updates_tmp="$(mktemp "${TMPDIR:-/tmp}/sourcemap_updates.XXXXXX.json")"
jq -n --argjson files "$files_json" '{files: $files}' > "$updates_tmp"

APPLY_SCRIPT="$SCRIPT_DIR/apply_updates.sh"
if [[ -x "$APPLY_SCRIPT" ]]; then
  "$APPLY_SCRIPT" "$ROOT_DIR" "$updates_tmp" >/dev/null 2>&1 || true
fi

# depends may have changed for these files, which can change who else's
# "dependents" list should mention them — recomputed from scratch, cheap
# and idempotent (see add-dependents.sh's own header).
ADD_DEPENDENTS_SCRIPT="$SCRIPT_DIR/add-dependents.sh"
if [[ -x "$ADD_DEPENDENTS_SCRIPT" ]]; then
  "$ADD_DEPENDENTS_SCRIPT" "$ROOT_DIR" >/dev/null 2>&1 || true
fi
