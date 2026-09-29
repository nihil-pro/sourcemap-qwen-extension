#!/usr/bin/env bash
# UserPromptSubmit hook.
# Tells the agent, once per session, what the @sourcemap block at the end of each file is: that its ctx line makes files findable
# by grepping for what they do, that its dependents line shows what a change can break, and that it must never edit or copy one.
# Only when blocks are on for this project (see lib.sh's setup_git_filter). No LLM call, no subprocess beyond jq: near-instant.

# Once-per-session:
# the hint only needs to land in the model's context once
# Repeating it on every prompt within the same session is pure token cost with no added value, since it's already there
# Gated by a marker file per session_id, mkdir-based lock, opportunistic 7-day cleanup of stale markers

set -uo pipefail

INPUT="$(cat)"

ROOT_DIR="${QWEN_PROJECT_DIR:-$(pwd)}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_SCRIPT="$SCRIPT_DIR/scripts/lib.sh"
[[ -f "$LIB_SCRIPT" ]] || exit 0
# shellcheck source=scripts/lib.sh
source "$LIB_SCRIPT"

# No blocks until the first background annotate.sh run has set up the git filter and written them
headers_enabled "$ROOT_DIR" || exit 0
init_error_log "$ROOT_DIR" || exit 0

SESSION_ID="$(jq -r '.session_id // empty' <<<"$INPUT")"

SESSIONS_DIR="$STATE_DIR/hint-sessions"
mkdir -p "$SESSIONS_DIR"
find "$SESSIONS_DIR" -maxdepth 1 -name '*.done' -mtime +7 -delete 2>/dev/null || true

if [[ -n "$SESSION_ID" ]]; then
  STATE_FILE="$SESSIONS_DIR/$SESSION_ID.done"
  if [[ -f "$STATE_FILE" ]]; then
    exit 0
  fi
  # mkdir is atomic on both macOS and Linux, so it doubles as a cheap lock against a rare concurrent call for the same session
  LOCK_DIR="$STATE_FILE.lock"
  for _ in $(seq 1 50); do
    mkdir "$LOCK_DIR" 2>/dev/null && break
    sleep 0.02
  done
  touch "$STATE_FILE"
  rmdir "$LOCK_DIR" 2>/dev/null || true
fi

# Read verbatim; if it's missing, there's nothing to inject
CONTEXT_FILE="$SCRIPT_DIR/prompts/hint.md"
[[ -f "$CONTEXT_FILE" ]] || exit 0
context="$(cat "$CONTEXT_FILE")"

jq -n --arg ctx "$context" \
  '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $ctx}}'
