#!/usr/bin/env bash
# UserPromptSubmit hook.
# Injects a short, static reminder that a "sourcemap-scout" subagent exists and can scope relevant files via routes.yaml,
# leaving the decision of *whether* to spawn it — and the actual file-relevance reasoning — to the orchestrating model itself.

# This deliberately does NO LLM call and NO classification of its own.
# A headless qwen subprocess doing the classification directly,
# which turned out to be slow (~25-70s+ per prompt) and needed a much larger model to reliably follow a "don't explore, just classify" instruction.
# This hook sidesteps all of that:
# it's near-instant (no subprocess, no API call),
# the orchestrating model decides per-prompt whether scoping is even worth it,
# and if it does spawn the scout, that subagent has real tool access rather than being limited to whatever text we could paste inline.

# Once-per-session:
# the hint only needs to land in the model's context once.
# Repeating it on every prompt within the same session is pure token cost with no added value, since it's already there.
# Gated by a marker file per session_id, mkdir-based lock, opportunistic 7-day cleanup of stale markers.

set -uo pipefail

INPUT="$(cat)"
SESSION_ID="$(jq -r '.session_id // empty' <<<"$INPUT")"

ROOT_DIR="${QWEN_PROJECT_DIR:-$(pwd)}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_SCRIPT="$SCRIPT_DIR/lib.sh"
[[ -f "$LIB_SCRIPT" ]] && source "$LIB_SCRIPT"
ROUTES_FILE="$ROOT_DIR/${DEFAULT_OUTPUT_FILE:-.qwen/sourcemap/routes.yaml}"

[[ -f "$ROUTES_FILE" ]] || exit 0

# Session-scoped state lives under the project's sourcemap data dir
# (already .qwen-prefixed, so it's automatically excluded from routes.yaml
# itself — see lib.sh's IGNORE_EXACT).
STATE_DIR="$ROOT_DIR/.qwen/sourcemap/.hint-sessions"
mkdir -p "$STATE_DIR"
find "$STATE_DIR" -maxdepth 1 -name '*.done' -mtime +7 -delete 2>/dev/null || true

if [[ -n "$SESSION_ID" ]]; then
  STATE_FILE="$STATE_DIR/$SESSION_ID.done"
  if [[ -f "$STATE_FILE" ]]; then
    exit 0
  fi
  # mkdir is atomic on both macOS and Linux, so it doubles as a cheap
  # lock against a rare concurrent call for the same session.
  LOCK_DIR="$STATE_FILE.lock"
  for _ in $(seq 1 50); do
    mkdir "$LOCK_DIR" 2>/dev/null && break
    sleep 0.02
  done
  touch "$STATE_FILE"
  rmdir "$LOCK_DIR" 2>/dev/null || true
fi

# The injected hint text lives in scout-hint.md, a sibling of this
# script — plain prompt content, no shell-escaping needed there. Read
# verbatim; if it's missing, there's nothing to inject.
CONTEXT_FILE="$SCRIPT_DIR/scout-hint.md"
[[ -f "$CONTEXT_FILE" ]] || exit 0
context="$(cat "$CONTEXT_FILE")"

jq -n --arg ctx "$context" \
  '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $ctx}}'
