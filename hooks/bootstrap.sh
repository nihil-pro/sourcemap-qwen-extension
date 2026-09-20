#!/usr/bin/env bash
# SessionStart hook.
# Ensures routes.yaml exists at session start;
# if it's missing, runs generate.sh to create the skeleton,
# then spawns a BACKGROUND `qwen -e none` session to actually populate it.

# Never overwrites an existing file — that's what sync.sh (Stop hook) and refresh_dirty.sh (for individually edited files) are for.

# `-e none` (means run without extensions) is to avoiding recursion.

# Reuses refresh_dirty.sh's own lock file:
# a full populate pass and a scoped refresh both edit routes.yaml directly,
# so *any* two of them running concurrently, risk the same lost-update corruption;
# one shared lock covers every combination.

# Unlike refresh_dirty.sh, this gets no --max-tool-calls cap:
# it may need to read/edit most of the project and spawn several subagents,
# so a small fixed budget would just make it fail.

set -uo pipefail

cat >/dev/null  # drain stdin; SessionStart's input isn't needed here

ROOT_DIR="${QWEN_PROJECT_DIR:-$(pwd)}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_SCRIPT="$SCRIPT_DIR/lib.sh"
GENERATE_SCRIPT="$SCRIPT_DIR/generate.sh"

[[ -f "$LIB_SCRIPT" ]] && source "$LIB_SCRIPT"
[[ -x "$GENERATE_SCRIPT" ]] || exit 0

ROUTES_FILE="$ROOT_DIR/${DEFAULT_OUTPUT_FILE:-.qwen/sourcemap/routes.yaml}"
[[ -f "$ROUTES_FILE" ]] && exit 0

"$GENERATE_SCRIPT" "$ROOT_DIR" >/dev/null 2>&1 || exit 0

POPULATE_PROMPT_FILE="$SCRIPT_DIR/bootstrap.md"
[[ -f "$POPULATE_PROMPT_FILE" ]] || exit 0

EXT_ROOT="$(dirname "$SCRIPT_DIR")"
# ${CLAUDE_PLUGIN_ROOT} is normally substituted when the extension loads
# its own slash commands — that machinery doesn't run here, since we're
# just cat-ing the file and passing it as a raw message, so do it
# ourselves.
prompt="$(cat "$POPULATE_PROMPT_FILE")"
prompt="${prompt//\$\{CLAUDE_PLUGIN_ROOT\}/$EXT_ROOT}"

LOCK_DIR="$(dirname "$ROUTES_FILE")/.refresh.lock"

(
  mkdir "$LOCK_DIR" 2>/dev/null || exit 0
  trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT
  cd "$ROOT_DIR" && qwen --openai-logging -e none "$prompt" >/dev/null 2>&1
) &
disown 2>/dev/null || true
