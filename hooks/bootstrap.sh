#!/usr/bin/env bash
# SessionStart hook
# Its ONLY synchronous work is spawning annotate.sh in the background,
# otherwise building deepgraph (first session after install) or annotating a large codebase would take a while, and the hook would fail with timeout

# annotate.sh is spawned on every session start, not only when the sourcemap is missing:
# it builds deepgraph if needed, catches up with whatever changed since the last session, and retries files a previous run left without a note.
# When there's nothing to do it exits after a single `deepgraph build`; a run already in progress makes it exit immediately.

# The background work is launched via `nohup ... & disown` to protect from SIGHUP an inline "(...)" subshell block as well
set -uo pipefail

cat >/dev/null  # drain stdin; SessionStart's input isn't needed here

ROOT_DIR="${QWEN_PROJECT_DIR:-$(pwd)}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_SCRIPT="$SCRIPT_DIR/scripts/lib.sh"
ANNOTATE_SCRIPT="$SCRIPT_DIR/scripts/annotate.sh"

[[ -f "$LIB_SCRIPT" && -x "$ANNOTATE_SCRIPT" ]] || exit 0
# shellcheck source=scripts/lib.sh
source "$LIB_SCRIPT"
ROOT_DIR="$(project_root "$ROOT_DIR")"
init_error_log "$ROOT_DIR" || exit 0

# A failed deepgraph build would otherwise leave the sourcemap silently missing; tell the user (it's retried below regardless)
if [[ -f "$DEEPGRAPH_BUILD_FAILED" ]]; then
  jq -n --arg msg "sourcemap: building deepgraph failed: $(cat "$DEEPGRAPH_BUILD_FAILED"). Retrying in the background." \
    '{systemMessage: $msg}'
fi

# stderr is left pointing at error.log (see init_error_log), so anything the background run prints before setting up its own log still lands there
nohup "$ANNOTATE_SCRIPT" "$ROOT_DIR" >/dev/null &
disown 2>/dev/null || true
