#!/usr/bin/env bash
#
# populate.sh — first-time background population of routes.yaml, launched
# by bootstrap.sh once a session starts and the file doesn't exist yet.
# Also runs generate.sh itself now (moved out of bootstrap.sh — see that
# script's header for why the SessionStart hook needs to stay
# near-instant and can't run it synchronously anymore).
#
# Processes the tree in BATCHES of SOURCEMAP_POPULATE_BATCH_SIZE nodes
# (default 10) — files first, then directories deepest-first — rather
# than asking for the whole project in one structured_output call.
# Confirmed directly: on anything beyond a small project, asking for
# everything at once degrades badly (the model either never calls
# structured_output at all, or the answer is too large/low-quality).
# Directories run after every batch of files because a directory's
# context is a rollup of its children's, read back from routes.yaml
# after earlier batches have already applied their content — sorting
# directories deepest-first (by path depth) and applying each batch
# before starting the next guarantees a directory is never summarized
# before all of its children have been.
#
# Mirrors refresh-dirty.sh's architecture: each batch call asks for
# {path, context, depends} only, via --json-schema structured_output,
# and never touches routes.yaml directly — apply-updates.sh applies the
# result mechanically after every batch, and add-dependents.sh
# recomputes the reverse "dependents" graph once at the very end. This
# needs no write or shell-execution tools, and therefore no
# --approval-mode override — full auto-approve was tried and rejected
# earlier specifically because it grants an unsupervised background
# process more than this task needs.
#
# CRITICAL #1: prompts are passed via --system-prompt/--prompt, never as
# a bare positional argument. Confirmed by direct testing: a positional
# prompt containing a "#" character anywhere makes qwen's CLI parsing
# silently misread it and fail with "No input provided via stdin".
#
# CRITICAL #2: qwen's stdout is redirected to a FILE, never captured via
# `$(...)` command substitution. Confirmed by direct, repeated testing:
# capturing via command substitution (which reads through a pipe)
# silently truncates qwen's output at exactly 65536 bytes every time —
# a classic Node.js symptom, where an async stdout write to a pipe can
# get cut short if the process exits before the write flushes, while the
# same write to a regular file does not have this problem.
#
# Usage: ./populate.sh <root_dir>

set -uo pipefail

ROOT_DIR="${1:?root_dir required}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_SCRIPT="$SCRIPT_DIR/lib.sh"
[[ -f "$LIB_SCRIPT" ]] && source "$LIB_SCRIPT"

ROUTES_FILE="$ROOT_DIR/${DEFAULT_OUTPUT_FILE:-.qwen/sourcemap/routes.yaml}"

# Lock acquired BEFORE generate.sh runs (not after): bootstrap.sh spawns
# this unconditionally whenever routes.yaml is missing, so two sessions
# starting close together could both spawn a populate.sh before either
# has created the file. Locking first means only one instance ever gets
# past this line; the other exits immediately instead of both running
# generate.sh redundantly.
LOCK_DIR="$(dirname "$ROUTES_FILE")/.refresh.lock"
mkdir "$LOCK_DIR" 2>/dev/null || exit 0
updates_tmp=""
raw_output_file=""
trap 'rm -f "$updates_tmp" "$raw_output_file"; rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT

GENERATE_SCRIPT="$SCRIPT_DIR/generate.sh"
if [[ ! -f "$ROUTES_FILE" ]]; then
  [[ -x "$GENERATE_SCRIPT" ]] || exit 0
  "$GENERATE_SCRIPT" "$ROOT_DIR" >/dev/null 2>&1 || exit 0
fi
[[ -f "$ROUTES_FILE" ]] || exit 0

RULES_FILE="$SCRIPT_DIR/../prompts/bootstrap.md"
SYSTEM_PROMPT_FILE="$SCRIPT_DIR/../prompts/bootstrap-system.md"
[[ -f "$RULES_FILE" && -f "$SYSTEM_PROMPT_FILE" ]] || exit 0

APPLY_SCRIPT="$SCRIPT_DIR/apply-updates.sh"
ADD_DEPENDENTS_SCRIPT="$SCRIPT_DIR/add-dependents.sh"
[[ -x "$APPLY_SCRIPT" ]] || exit 0

BATCH_SIZE="${SOURCEMAP_POPULATE_BATCH_SIZE:-10}"
system_prompt="$(cat "$SYSTEM_PROMPT_FILE")"
rules="$(cat "$RULES_FILE")"
schema='{"type":"object","properties":{"files":{"type":"array","items":{"type":"object","properties":{"path":{"type":"string"},"context":{"type":"string"},"depends":{"type":"array","items":{"type":"string"}}},"required":["path","context","depends"]}}},"required":["files"]}'

unescape_yaml() {
  local s="$1"
  s="${s//\\\"/\"}"
  s="${s//\\\\/\\}"
  printf '%s' "$s"
}

# Walks routes.yaml with the same indentation-tracked stack apply-updates.sh
# and add-dependents.sh already use for this exact layout (not
# centralized into a shared helper — this codebase already duplicates
# this snippet per-script rather than adding an extra process hop for
# it). Prints "file\t<depth>\t<path>" or "dir\t<depth>\t<path>" for every
# node whose ::meta block still has an empty context.
enumerate_pending() {
  local old_lines=() line
  while IFS= read -r line || [[ -n "$line" ]]; do
    old_lines+=("$line")
  done < "$ROUTES_FILE"
  local n=${#old_lines[@]}
  local stack=() i=0
  while [[ $i -lt $n ]]; do
    line="${old_lines[$i]}"
    if [[ "$line" =~ ^([[:space:]]*)\"([^\"]*)\":(.*)$ ]]; then
      local spaces="${BASH_REMATCH[1]}" key="${BASH_REMATCH[2]}"
      local depth=$(( ${#spaces} / 2 ))
      if [[ "$key" == "::meta" && $depth -eq ${#stack[@]} ]]; then
        local block_indent=${#spaces}
        local path parent_depth
        path="$(IFS=/; echo "${stack[*]}")"
        parent_depth=${#stack[@]}
        local j=$(( i + 1 )) is_empty=0 has_depends=0
        while [[ $j -lt $n ]]; do
          local next="${old_lines[$j]}"
          if [[ -z "$next" ]]; then j=$(( j + 1 )); continue; fi
          [[ "$next" =~ ^([[:space:]]*) ]]
          local next_spaces=${#BASH_REMATCH[1]}
          [[ $next_spaces -le $block_indent ]] && break
          [[ "$next" =~ ^[[:space:]]*context:\ \"\"[[:space:]]*$ ]] && is_empty=1
          [[ "$next" =~ ^[[:space:]]*depends: ]] && has_depends=1
          j=$(( j + 1 ))
        done
        if [[ $is_empty -eq 1 ]]; then
          if [[ $has_depends -eq 1 ]]; then
            printf 'file\t%d\t%s\n' "$parent_depth" "$path"
          else
            printf 'dir\t%d\t%s\n' "$parent_depth" "$path"
          fi
        fi
        i=$j
        continue
      elif [[ "$key" != "::meta" ]]; then
        stack=("${stack[@]:0:$depth}")
        stack[$depth]="$(unescape_yaml "$key")"
      fi
    fi
    i=$(( i + 1 ))
  done
}

# Runs one batch: $1 = "FILES" or "DIRECTORIES" (task label for the
# message), $2 = newline-separated list of paths. Applies the batch's
# results immediately on success; a failed batch (after retries) is
# simply skipped — its nodes stay empty and will be picked up by the
# next bootstrap.sh run (routes.yaml existing-but-partially-blank is
# fine; only a fully-missing file triggers another populate.sh pass, so
# a stuck batch would need a manual retry today — acceptable for a
# first-time bootstrap, not worth over-engineering further here).
run_batch() {
  local task_label="$1" path_list="$2"
  local message
  message="$(printf 'Process exactly these %s:\n%s\n\n%s' "$task_label" "$path_list" "$rules")"

  local files_json="" attempt
  for attempt in 1 2 3; do
    raw_output_file="$(mktemp "${TMPDIR:-/tmp}/sourcemap_populate_raw.XXXXXX.json")"
    (cd "$ROOT_DIR" && qwen -e none \
        --system-prompt "$system_prompt" \
        --output-format json \
        --json-schema "$schema" \
        --prompt "$message" >"$raw_output_file" 2>/dev/null)
    local qwen_exit=$?
    if [[ $qwen_exit -eq 0 ]]; then
      # --output-format json emits one JSON object per event in an
      # array; the final "result"-type event's own "result" field is the
      # structured_output answer, re-encoded as a JSON STRING (not a
      # nested object) — hence the "fromjson".
      files_json="$(jq -c '[.[] | select(.type=="result")] | last | .result | fromjson | .files // empty' "$raw_output_file" 2>/dev/null)"
    fi
    rm -f "$raw_output_file"
    raw_output_file=""
    [[ -n "$files_json" && "$files_json" != "null" ]] && break
    files_json=""
  done
  [[ -n "$files_json" ]] || return 0

  updates_tmp="$(mktemp "${TMPDIR:-/tmp}/sourcemap_populate.XXXXXX.json")"
  jq -n --argjson files "$files_json" '{files: $files}' > "$updates_tmp"
  "$APPLY_SCRIPT" "$ROOT_DIR" "$updates_tmp" >/dev/null 2>&1 || true
  rm -f "$updates_tmp"
  updates_tmp=""
}

batch_and_run() {
  local task_label="$1"
  local -a paths=()
  local line
  while IFS= read -r line; do
    [[ -n "$line" ]] && paths+=("$line")
  done

  local total=${#paths[@]}
  [[ $total -gt 0 ]] || return 0

  local start=0
  while [[ $start -lt $total ]]; do
    local end=$(( start + BATCH_SIZE ))
    [[ $end -gt $total ]] && end=$total
    local batch_list=""
    local k
    for (( k = start; k < end; k++ )); do
      batch_list="$batch_list${paths[$k]}"$'\n'
    done
    run_batch "$task_label" "$batch_list"
    start=$end
  done
}

# Files first (any order — no ordering dependency among them), then
# directories deepest-first (field 2 is depth; numeric-descending sort).
enumerate_pending | awk -F'\t' '$1=="file"{print $3}' | batch_and_run "FILES"
enumerate_pending | awk -F'\t' '$1=="dir"{print $2"\t"$3}' | sort -t $'\t' -k1,1nr | cut -f2 | batch_and_run "DIRECTORIES"

if [[ -x "$ADD_DEPENDENTS_SCRIPT" ]]; then
  "$ADD_DEPENDENTS_SCRIPT" "$ROOT_DIR" >/dev/null 2>&1 || true
fi
