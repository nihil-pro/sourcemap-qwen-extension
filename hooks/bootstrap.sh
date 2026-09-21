#!/usr/bin/env bash
#
# bootstrap.sh — SessionStart hook. Its ONLY synchronous work is a file
# existence check and spawning a background process; it does not run
# generate.sh itself (that moved into populate.sh — see that script's
# header). This is deliberate: some qwen-code versions appear to
# interpret a hook's configured timeout in a different unit than others
# (observed directly: a hook that legitimately takes low-single-digit
# seconds gets killed as if the timeout were read in milliseconds), so
# this hook must return almost instantly regardless of how long
# generating/populating routes.yaml actually takes — all of that now
# happens after this hook has already exited.
#
# Never overwrites an existing routes.yaml — that's what sync.sh (Stop
# hook) and refresh-dirty.sh (for individually edited files) are for.
#
# The background work is launched via `nohup ... & disown` — the exact
# pattern sync-stale.sh already uses successfully for
# refresh-dirty.sh. `nohup` only protects a single external command from
# SIGHUP, not an inline "(...)" subshell block; an earlier version that
# backgrounded a subshell directly here was observed getting killed right
# after this hook's own synchronous portion returned.

set -uo pipefail

cat >/dev/null  # drain stdin; SessionStart's input isn't needed here

ROOT_DIR="${QWEN_PROJECT_DIR:-$(pwd)}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_SCRIPT="$SCRIPT_DIR/scripts/lib.sh"
POPULATE_SCRIPT="$SCRIPT_DIR/scripts/populate.sh"

[[ -f "$LIB_SCRIPT" ]] && source "$LIB_SCRIPT"

ROUTES_FILE="$ROOT_DIR/${DEFAULT_OUTPUT_FILE:-.qwen/sourcemap/routes.yaml}"
[[ -f "$ROUTES_FILE" ]] && exit 0

[[ -x "$POPULATE_SCRIPT" ]] || exit 0

nohup "$POPULATE_SCRIPT" "$ROOT_DIR" >/dev/null 2>&1 &
disown 2>/dev/null || true
