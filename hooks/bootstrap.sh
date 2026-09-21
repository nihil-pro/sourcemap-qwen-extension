#!/usr/bin/env bash
#
# bootstrap.sh — SessionStart hook. Ensures routes.yaml exists at session
# start; if it's missing (e.g. a fresh clone, or this tooling was just
# added to the project), runs generate.sh to create the skeleton, then
# launches populate.sh in the BACKGROUND to actually populate it —
# reusing bootstrap.md's instructions verbatim (the same population task
# the old manual /sourcemap command ran; that command and its commands/
# dir are gone now that this is fully automatic).
# Never overwrites an existing file — that's what sync.sh (Stop hook)
# and refresh_dirty.sh (for individually edited files) are for.
#
# The background work lives in its own script (populate.sh), launched
# via `nohup ... & disown` — the exact pattern hook_sync_on_stop.sh
# already uses successfully for refresh_dirty.sh. `nohup` only protects
# a single external command from SIGHUP, not an inline "(...)" subshell
# block; an earlier version that backgrounded a subshell directly here
# was observed getting killed right after this hook's own synchronous
# portion returned. See populate.sh's header for the rest (model choice,
# no tool-call cap, the shared lock, and why `-e none`).

set -uo pipefail

cat >/dev/null  # drain stdin; SessionStart's input isn't needed here

ROOT_DIR="${QWEN_PROJECT_DIR:-$(pwd)}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_SCRIPT="$SCRIPT_DIR/lib.sh"
GENERATE_SCRIPT="$SCRIPT_DIR/generate.sh"
POPULATE_SCRIPT="$SCRIPT_DIR/populate.sh"

[[ -f "$LIB_SCRIPT" ]] && source "$LIB_SCRIPT"
[[ -x "$GENERATE_SCRIPT" ]] || exit 0

ROUTES_FILE="$ROOT_DIR/${DEFAULT_OUTPUT_FILE:-.qwen/sourcemap/routes.yaml}"
[[ -f "$ROUTES_FILE" ]] && exit 0

"$GENERATE_SCRIPT" "$ROOT_DIR" >/dev/null 2>&1 || exit 0

[[ -x "$POPULATE_SCRIPT" ]] || exit 0

nohup "$POPULATE_SCRIPT" "$ROOT_DIR" >/dev/null 2>&1 &
disown 2>/dev/null || true
