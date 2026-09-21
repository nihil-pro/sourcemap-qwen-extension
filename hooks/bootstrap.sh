#!/usr/bin/env bash
# SessionStart hook
# Its ONLY synchronous work is a file existence check and spawning a background process,
# otherwise it could took for a wile in large codebase, and hook will fail with timeout

# Never overwrites an existing routes.yaml. That's what sync.sh and refresh-dirty.sh are for

# The background work is launched via `nohup ... & disown` to protect from SIGHUP an inline "(...)" subshell block as well
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
