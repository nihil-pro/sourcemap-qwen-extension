#!/usr/bin/env bash
#
# annotate.sh — background builder/annotator of the project's sourcemap. Spawned by bootstrap.sh on every session start,
# and by sync-stale.sh after a turn leaves files needing a note.
#
# 1. Makes sure deepgraph is built (build-deepgraph.sh; a no-op once it is).
# 2. Sets up the git clean filter (lib.sh's setup_git_filter); @sourcemap blocks are only written when that succeeded.
# 3. Runs `deepgraph build`, which regenerates the local graph.json (files, dependents, content hashes), tidies the committed
#    notes file (.qwen/sourcemap/notes.jsonl), and brings every file's @sourcemap block up to date.
#    Steps 1-3 always run; step 4 only with the "LLM annotation" setting on (see lib.sh's annotation_enabled).
# 4. Asks the model for a one-sentence note for every file without a current one (none, or written for other content),
#    and adds each to the notes file together with the hash it was written for.
#    The blocks aren't updated from here: this runs in the background, possibly while the agent is editing, so new notes
#    reach the blocks at the end of the agent's turn (sync-stale.sh) or at the next session start.
#
# The dependency graph is static analysis, so the model is asked for *content only*: {path, context}, via --json-schema
# structured_output. It never touches the notes file directly and needs no write or shell-execution tools, and therefore no
# --approval-mode override.
#
# Processes files in BATCHES of SOURCEMAP_POPULATE_BATCH_SIZE (default 10) rather than in one structured_output call.
# Confirmed directly: on anything beyond a small project, asking for everything at once degrades badly
# (the model either never calls structured_output at all, or the answer is too large/low-quality).
# Each batch is written back as soon as it's done, so an interrupted run loses at most one batch;
# whatever is left stays pending and is picked up by the next run.
#
# Two locks, in the project's state dir: .annotate.lock makes this script a per-project singleton (a run can take a long time
# on a large project); .write.lock guards every short read-modify-write of the notes file and the blocks, shared with
# sync-stale.sh's synchronous `deepgraph build`.
#
# Runs qwen with `-e none` — NOT --safe-mode. Hooks apply to *any* qwen invocation in this project, so something must stop
# this nested invocation from re-triggering our own SessionStart/UserPromptSubmit/Stop hooks (unbounded recursive process
# spawning otherwise). `-e none` disables this extension specifically (hooks *and* agents), which is both sufficient and
# narrower than --safe-mode: it leaves skills/MCP/QWEN.md intact.
#
# CRITICAL #1: prompts are passed via --system-prompt/--prompt, never as a bare positional argument. Confirmed by direct
# testing: a positional prompt containing a "#" character anywhere makes qwen's CLI parsing silently misread it and fail
# with "No input provided via stdin".
#
# CRITICAL #2: qwen's stdout is redirected to a FILE, never captured via `$(...)` command substitution. Confirmed by direct,
# repeated testing: capturing via command substitution (which reads through a pipe) silently truncates qwen's output at
# exactly 65536 bytes every time — a classic Node.js symptom, where an async stdout write to a pipe can get cut short if the
# process exits before the write flushes, while the same write to a regular file does not have this problem.
#
# Usage: ./annotate.sh <root_dir>

set -uo pipefail

ROOT_DIR="$(cd "${1:?root_dir required}" && pwd)" || exit 0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
init_error_log "$ROOT_DIR" || exit 0
load_settings "$ROOT_DIR"

ANNOTATE_LOCK="$STATE_DIR/.annotate.lock"
WRITE_LOCK="$STATE_DIR/.write.lock"

try_lock "$ANNOTATE_LOCK" || exit 0
raw_output_file=""
qwen_err_file=""
annotate_settings=""
cleanup() {
  rm -f "$raw_output_file" "$qwen_err_file" "$annotate_settings"
  [[ "$(cat "$WRITE_LOCK/pid" 2>/dev/null)" == "$$" ]] && release_lock "$WRITE_LOCK"
  release_lock "$ANNOTATE_LOCK"
}
trap cleanup EXIT

# build-deepgraph.sh logs its own failures
"$SCRIPT_DIR/build-deepgraph.sh" "$ROOT_DIR" || exit 0

# One-time migration from the ctx.json of 1.0.x, which kept everything in the folder the notes file now lives in: notes still
# current for their file are imported (not paid for again), then that version's generated files are removed, so they can't
# end up committed next to the notes.
OLD_DIR="$ROOT_DIR/.qwen/sourcemap"
if [[ -f "$OLD_DIR/ctx.json" && ! -f "$NOTES_FILE" ]]; then
  if out="$("$DEEPGRAPH_BIN" import-ctx "$ROOT_DIR" "$OLD_DIR/ctx.json" --notes "$NOTES_FILE" 2>&1)"; then
    rm -rf "$OLD_DIR"/{ctx.json,graph.json,vectors.json,deepgraph,error.log,.hint-sessions,.annotate.lock,.write.lock}
  else
    log_error "could not import notes from $OLD_DIR/ctx.json: $out"
  fi
fi

headers=()
setup_git_filter "$ROOT_DIR" && headers=(--headers)

wait_lock "$WRITE_LOCK" 600 || { log_error "timed out waiting for $WRITE_LOCK"; exit 0; }
deepgraph_build "$ROOT_DIR" ${headers[@]+"${headers[@]}"}
build_status=$?
pending="$(deepgraph_pending)"
release_lock "$WRITE_LOCK"
[[ $build_status -eq 0 && -n "$pending" ]] || exit 0
annotation_enabled || exit 0

# Passed via --system-prompt, which *replaces* qwen's default coding-agent system prompt (one that pushes toward exploring
# and editing the repo) and holds every instruction; the message itself is just the batch's file list.
SYSTEM_PROMPT_FILE="$SCRIPT_DIR/../prompts/annotate.md"
[[ -f "$SYSTEM_PROMPT_FILE" ]] || { log_error "missing prompt file: $SYSTEM_PROMPT_FILE"; exit 0; }

# The model gets exactly two tools, read_file and structured_output (confirmed via the run's tool list), so a background run
# can't write, run commands, spawn agents, use skills or MCP servers — or wander off grepping the repo:
# - --core-tools read_file: the only core tool (drops edit/write/shell/grep/glob/web...). --allowed-tools only auto-approves
#   (read_file needs no approval headless anyway); it restricts nothing on its own.
# - --exclude-tools: system built-ins that bypass --core-tools. This list matches the qwen version this was written against;
#   a built-in added by a later qwen version stays available until it's added here.
# - --allowed-mcp-server-names none: no configured MCP server matches, so none are started.
# structured_output isn't affected by either list: --json-schema adds it on its own.
QWEN_TOOL_ARGS=(
  --core-tools read_file
  --allowed-tools read_file
  --exclude-tools "agent,list_agents,send_message,task_stop,skill,tool_search,tool_call,get_goal,update_goal,report_findings,record_artifact,enter_worktree,exit_worktree"
  --allowed-mcp-server-names none
)

# Workaround for a qwen bug (0.24.6): the <available_skills> listing is sent even with the skill tool excluded, costing
# ~27% of every batch's input tokens (measured: 5689 -> 4154). Skills can only be disabled via settings (no CLI flag), so
# the annotator's qwen calls get their own system settings file, set through QWEN_CODE_SYSTEM_SETTINGS_PATH, that disables
# every skill level. It's a copy of the real system settings (if any) with the levels added, so an existing system file
# isn't hidden; one jq can't parse (e.g. with comments) is used unchanged instead, and logged. Drop this once qwen stops
# listing skills when the tool is absent.
SKILL_LEVELS='["bundled","user","project","extension"]'
system_settings="${QWEN_CODE_SYSTEM_SETTINGS_PATH:-}"
if [[ -z "$system_settings" ]]; then
  case "$(uname -s)" in
    Darwin) system_settings="/Library/Application Support/QwenCode/settings.json" ;;
    *) system_settings="/etc/qwen-code/settings.json" ;;
  esac
fi
annotate_settings="$(mktemp "${TMPDIR:-/tmp}/sourcemap_annotate_settings.XXXXXX")"
if [[ -f "$system_settings" ]]; then
  jq --argjson l "$SKILL_LEVELS" '.skills.disabledLevels = ((.skills.disabledLevels // []) + $l | unique)' \
    "$system_settings" > "$annotate_settings" 2>/dev/null \
    || { log_error "could not add skills.disabledLevels to $system_settings (not plain JSON?); skills stay listed in annotation requests"
         cp "$system_settings" "$annotate_settings"; }
else
  jq -n --argjson l "$SKILL_LEVELS" '{skills: {disabledLevels: $l}}' > "$annotate_settings"
fi

BATCH_SIZE="${SOURCEMAP_POPULATE_BATCH_SIZE:-10}"
system_prompt="$(cat "$SYSTEM_PROMPT_FILE")"
schema='{"type":"object","properties":{"files":{"type":"array","items":{"type":"object","properties":{"path":{"type":"string"},"context":{"type":"string"}},"required":["path","context"]}}},"required":["files"]}'

# Runs one batch. $1 = newline-separated "path<TAB>hash" lines. A failed batch (after retries) is simply skipped:
# its files stay pending and get retried by the next run.
run_batch() {
  local batch="$1"
  local path_list abs_list hashes message rel
  path_list="$(cut -f1 <<<"$batch")"
  # The model gets absolute paths: qwen's read_file only accepts absolute ones, and a model left to join
  # a relative path onto the project root itself sometimes gets it wrong. Answers are mapped back to the graph's relative paths.
  abs_list="$(while IFS= read -r rel; do printf '%s/%s\n' "$ROOT_DIR" "$rel"; done <<<"$path_list")"
  # The hash each file had when this batch was enumerated. A file edited while the model works on it
  # then keeps a mismatching ctx_hash, so it's re-annotated next time instead of silently keeping an outdated note.
  hashes="$(jq -Rn '[inputs | split("\t") | {(.[0]): .[1]}] | add' <<<"$batch")"
  message="$(printf 'Process exactly these FILES:\n%s' "$abs_list")"

  local files_json="" attempt
  local qwen_exit
  for attempt in 1 2 3; do
    raw_output_file="$(mktemp "${TMPDIR:-/tmp}/sourcemap_annotate_raw.XXXXXX")"
    qwen_err_file="$(mktemp "${TMPDIR:-/tmp}/sourcemap_annotate_err.XXXXXX")"
    (cd "$ROOT_DIR" && export QWEN_CODE_SYSTEM_SETTINGS_PATH="$annotate_settings" && run_qwen -e none "${QWEN_TOOL_ARGS[@]}" \
        --system-prompt "$system_prompt" \
        --output-format json \
        --json-schema "$schema" \
        --prompt "$message" >"$raw_output_file" 2>"$qwen_err_file")
    qwen_exit=$?
    if [[ $qwen_exit -eq 0 ]]; then
      # --output-format json emits one JSON object per event in an array; the final "result"-type event's own "result"
      # field is the structured_output answer, re-encoded as a JSON STRING (not a nested object) — hence the "fromjson".
      # A model that answered in plain text instead of calling structured_output is expected now and then, so a parse
      # failure is logged as a failed attempt rather than as jq's own error.
      files_json="$(jq -c '[.[] | select(.type=="result")] | last | .result | fromjson | .files // empty' "$raw_output_file" 2>/dev/null)"
      if [[ -z "$files_json" || "$files_json" == "null" ]]; then
        local detail
        detail="$(jq -c '[.[] | select(.type=="result")] | last | .result' "$raw_output_file" 2>/dev/null)" \
          || detail="(not JSON) $(head -c 500 "$raw_output_file")"
        log_error "attempt $attempt: no structured_output in qwen's result: ${detail:0:500}"
      fi
    else
      # qwen's stderr is only interesting when it failed
      log_error "attempt $attempt: qwen exited with $qwen_exit: $(tail -n 20 "$qwen_err_file")"
    fi
    rm -f "$raw_output_file" "$qwen_err_file"
    raw_output_file=""
    qwen_err_file=""
    [[ -n "$files_json" && "$files_json" != "null" ]] && break
    files_json=""
  done
  if [[ -z "$files_json" ]]; then
    log_error "batch skipped after 3 attempts, left pending: $(paste -sd ' ' - <<<"$path_list")"
    return 0
  fi

  wait_lock "$WRITE_LOCK" 600 || { log_error "timed out waiting for $WRITE_LOCK, batch not written"; return 0; }
  # Paths come back absolute (as given) and are made relative again; a relative or "./path" answer is accepted too.
  # Only paths from this batch are written (the model may invent one).
  # An empty context is never written as-is: a file without a note is re-queued, so a model with nothing to say about
  # a trivial file would otherwise get it re-queued forever. The prompt already asks for some description; this is the backstop.
  jq -c --arg root "$ROOT_DIR/" --argjson h "$hashes" '
    [.[] | .path |= (ltrimstr($root) | ltrimstr("./")) | select($h[.path] != null)
     | {path, hash: $h[.path], ctx: (if (.context // "") == "" then "(no description)" else .context end)}]
  ' <<<"$files_json" | "$DEEPGRAPH_BIN" set-notes --notes "$NOTES_FILE" \
    || log_error "failed to write batch into $NOTES_FILE: $(paste -sd ' ' - <<<"$path_list")"
  release_lock "$WRITE_LOCK"
}

batch=""
count=0
while IFS= read -r line; do
  [[ -n "$line" ]] || continue
  batch="$batch$line"$'\n'
  count=$(( count + 1 ))
  if [[ $count -ge $BATCH_SIZE ]]; then
    run_batch "${batch%$'\n'}"
    batch=""
    count=0
  fi
done <<<"$pending"
[[ -n "$batch" ]] && run_batch "${batch%$'\n'}"

exit 0
