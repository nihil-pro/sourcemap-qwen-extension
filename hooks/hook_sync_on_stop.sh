#!/usr/bin/env bash
# Stop hook.
# Keeps routes.yaml's structure in sync with the filesystem after each turn, by delegating to sync.sh

# In a git repo, only runs when `git status --porcelain` shows a change to a path sync.sh would actually notice;
# i.e. a path not pruned by lib.sh's own ignore rules, OR this session has files mark_dirty.sh recorded as edited.

# Without git (or outside a repo), always runs; sync.sh's own diff is what tells you whether anything structurally changed.

# Only surfaces a systemMessage to the user when something structural actually changed; a no-op sync stays silent.

# After structural sync, also checks that same dirty list, and if non-empty,
# spawns refresh_dirty.sh in the BACKGROUND to regenerate exactly those files' ::meta context/depends.

# Backgrounded, so a content refresh never delays this turn

set -euo pipefail

INPUT="$(cat)"
SESSION_ID="$(jq -r '.session_id // empty' <<<"$INPUT" 2>/dev/null || true)"

ROOT_DIR="${QWEN_PROJECT_DIR:-$(pwd)}"
cd "$ROOT_DIR" || exit 0

# sync.sh and lib.sh are siblings of this script — resolve relative to
# this file's own location, not $ROOT_DIR, so a future move of the whole
# sourcemap/ folder doesn't break this path again.
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYNC_SCRIPT="$HOOK_DIR/sync.sh"
LIB_SCRIPT="$HOOK_DIR/lib.sh"
REFRESH_SCRIPT="$HOOK_DIR/refresh_dirty.sh"

[[ -x "$SYNC_SCRIPT" ]] || exit 0
[[ -f "$LIB_SCRIPT" ]] || exit 0
OUTPUT_FILE="routes.yaml"
# shellcheck source=lib.sh
source "$LIB_SCRIPT"

DIRTY_FILE="$ROOT_DIR/$(dirname "$DEFAULT_OUTPUT_FILE")/.dirty-sessions/$SESSION_ID.json"
has_dirty=false
if [[ -n "$SESSION_ID" && -s "$DIRTY_FILE" ]]; then
  [[ "$(jq '(.files // []) | length' "$DIRTY_FILE" 2>/dev/null || echo 0)" -gt 0 ]] && has_dirty=true
fi

if [[ -d "$ROOT_DIR/.git" ]] && command -v git >/dev/null 2>&1; then
  # True if every path segment is checked against lib.sh's ignore rules —
  # a change three levels inside node_modules/ is exactly as irrelevant
  # to routes.yaml as node_modules/ itself, since the tree walk prunes
  # the whole subtree at the first ignored ancestor.
  path_is_ignored() {
    local path="$1"
    local seg
    local IFS='/'
    for seg in $path; do
      is_ignored "$seg" && return 0
    done
    return 1
  }

  relevant=false
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    # porcelain format: "XY path" ("XY old -> new" for a rename/copy).
    path="${line:3}"
    path="${path#*-> }"
    path="${path%\"}"
    path="${path#\"}"
    if ! path_is_ignored "$path"; then
      relevant=true
      break
    fi
  done < <(git -C "$ROOT_DIR" status --porcelain 2>/dev/null)

  [[ "$relevant" == true || "$has_dirty" == true ]] || exit 0
fi

# No output_file arg — let sync.sh apply its own default (lib.sh's
# DEFAULT_OUTPUT_FILE), so this hook never has to duplicate that path.
output="$("$SYNC_SCRIPT" "$ROOT_DIR" 2>&1)" || exit 0

if printf '%s' "$output" | grep -qE '^(Added|Removed)'; then
  jq -n --arg msg "$output" '{systemMessage: $msg}'
fi

if [[ "$has_dirty" == true && -x "$REFRESH_SCRIPT" ]]; then
  nohup "$REFRESH_SCRIPT" "$ROOT_DIR" "$SESSION_ID" >/dev/null 2>&1 &
  disown 2>/dev/null || true
fi
