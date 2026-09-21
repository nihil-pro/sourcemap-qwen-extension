#!/usr/bin/env bash
#
# populate.sh — first-time background population of routes.yaml, launched
# by bootstrap.sh once the skeleton exists (generate.sh already ran
# synchronously before this is spawned).
#
# Mirrors refresh_dirty.sh's architecture exactly: the model is asked for
# {path, context, depends} data only, via --json-schema structured_output,
# over every node that still carries an empty ::meta block — it never
# touches routes.yaml directly. apply_updates.sh applies the result
# mechanically afterward, then add-dependents.sh recomputes the reverse
# "dependents" graph. This needs no write or shell-execution tools, and
# therefore no --approval-mode override: the model is free to spawn
# subagents (the "agent" tool) to parallelize reading a large tree, but
# nothing anywhere in that chain can ever edit a file or run a command —
# that's what the default (non-yolo) approval mode already guarantees,
# regardless of what the prompt says.
#
# This replaces an earlier version that asked the model to edit
# routes.yaml and run generate.sh/add-dependents.sh directly, which
# required `--approval-mode yolo` (full unattended auto-approve for an
# unsupervised background process) purely so those tool calls wouldn't be
# silently dropped. Structured-output-only avoids that risk entirely
# instead of accepting it.
#
# Known limitation: this asks for the WHOLE tree's data in a single
# structured_output call. Fine for small/medium projects (tested); a very
# large tree could exceed context/output limits before hitting a safety
# problem. Not solved here — batch this the way refresh_dirty.sh batches
# dirty files if it becomes an issue.
#
# Split out from bootstrap.sh specifically so the whole thing can be
# launched as a single `nohup ./populate.sh ... & disown` command,
# mirroring hook_sync_on_stop.sh's proven-working spawn of
# refresh_dirty.sh.
#
# CRITICAL #1: prompts are passed via --system-prompt/--prompt, never as
# a bare positional argument. Confirmed by direct testing: a positional
# prompt containing a "#" character anywhere (e.g. this task's own
# markdown headings) makes qwen's CLI parsing silently misread it and
# fail with "No input provided via stdin".
#
# CRITICAL #2: qwen's stdout is redirected to a FILE, never captured via
# `$(...)` command substitution. Confirmed by direct, repeated testing:
# capturing via command substitution (which reads through a pipe)
# silently truncates qwen's output at exactly 65536 bytes every time —
# a classic Node.js symptom, where an async stdout write to a pipe can
# get cut short if the process exits before the write flushes, while the
# same write to a regular file does not have this problem. The truncated
# JSON cuts off mid-stream, so the final "result" event (usually the
# last and largest thing written) is frequently missing or malformed,
# which is what was silently causing files_json to come back empty on
# every attempt despite the model completing successfully.
#
# Usage: ./populate.sh <root_dir>

set -uo pipefail

ROOT_DIR="${1:?root_dir required}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_SCRIPT="$SCRIPT_DIR/lib.sh"
[[ -f "$LIB_SCRIPT" ]] && source "$LIB_SCRIPT"

ROUTES_FILE="$ROOT_DIR/${DEFAULT_OUTPUT_FILE:-.qwen/sourcemap/routes.yaml}"
[[ -f "$ROUTES_FILE" ]] || exit 0

SYSTEM_PROMPT_FILE="$SCRIPT_DIR/bootstrap.system.md"
MESSAGE_FILE="$SCRIPT_DIR/bootstrap.md"
[[ -f "$SYSTEM_PROMPT_FILE" && -f "$MESSAGE_FILE" ]] || exit 0

LOCK_DIR="$(dirname "$ROUTES_FILE")/.refresh.lock"
mkdir "$LOCK_DIR" 2>/dev/null || exit 0
updates_tmp=""
raw_output_file=""
trap 'rm -f "$updates_tmp" "$raw_output_file"; rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT

system_prompt="$(cat "$SYSTEM_PROMPT_FILE")"
message="$(cat "$MESSAGE_FILE")"

schema='{"type":"object","properties":{"files":{"type":"array","items":{"type":"object","properties":{"path":{"type":"string"},"context":{"type":"string"},"depends":{"type":"array","items":{"type":"string"}}},"required":["path","context","depends"]}}},"required":["files"]}'

# No -m/model flag (uses the session's own configured default — this pass
# needs to reason about the whole project, not just narrow extraction)
# and no --max-tool-calls cap (may need to read most of the project and
# spawn several subagents per bootstrap.md's "Execution" section).
#
# Retried up to 3 attempts: observed directly that the model sometimes
# finishes a turn without ever calling structured_output (or emits a
# non-JSON final answer), especially on a small/fast model — the run
# still exits 0, "result" just isn't parseable JSON, so fromjson fails
# and files_json below comes back empty. Since bootstrap.sh only
# re-populates when routes.yaml is MISSING (not when it exists but is
# still blank), a single silent failure here would otherwise leave the
# map permanently empty with nothing to retry it later.
files_json=""
for attempt in 1 2 3; do
  raw_output_file="$(mktemp "${TMPDIR:-/tmp}/sourcemap_populate_raw.XXXXXX.json")"
  (cd "$ROOT_DIR" && qwen -e none \
      --system-prompt "$system_prompt" \
      --output-format json \
      --json-schema "$schema" \
      --prompt "$message" >"$raw_output_file" 2>/dev/null)
  qwen_exit=$?
  if [[ $qwen_exit -eq 0 ]]; then
    # --output-format json emits one JSON object per event in an array;
    # the final "result"-type event's own "result" field is the
    # structured_output answer, but re-encoded as a JSON STRING (not a
    # nested object) — hence the "fromjson". Confirmed directly against
    # real output; there is no "structured_result" key anywhere in the
    # stream despite the name being a plausible guess.
    files_json="$(jq -c '[.[] | select(.type=="result")] | last | .result | fromjson | .files // empty' "$raw_output_file" 2>/dev/null)"
  fi
  rm -f "$raw_output_file"
  [[ -n "$files_json" && "$files_json" != "null" ]] && break
  files_json=""
done
[[ -n "$files_json" ]] || exit 0

updates_tmp="$(mktemp "${TMPDIR:-/tmp}/sourcemap_populate.XXXXXX.json")"
jq -n --argjson files "$files_json" '{files: $files}' > "$updates_tmp"

APPLY_SCRIPT="$SCRIPT_DIR/apply_updates.sh"
if [[ -x "$APPLY_SCRIPT" ]]; then
  "$APPLY_SCRIPT" "$ROOT_DIR" "$updates_tmp" >/dev/null 2>&1 || true
fi

ADD_DEPENDENTS_SCRIPT="$SCRIPT_DIR/add-dependents.sh"
if [[ -x "$ADD_DEPENDENTS_SCRIPT" ]]; then
  "$ADD_DEPENDENTS_SCRIPT" "$ROOT_DIR" >/dev/null 2>&1 || true
fi
