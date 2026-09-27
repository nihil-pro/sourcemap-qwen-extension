#!/usr/bin/env bash
# PostToolUse hook (matcher: "^agent$"), acting only on sourcemap-scout calls.
# The scout only picks files (its answer is {"files": ["path", ...]}); this hook looks each one up with `deepgraph show` and
# appends each file's note (ctx.json) and dependents (graph.json) to the scout's tool result,
# via additionalContext. So the details the main agent relies on come straight from deepgraph, never retyped by a model.

# Why PostToolUse and not SubagentStop: a SubagentStop hook can't replace a subagent's answer, only "block", which makes the
# subagent run another turn with the hook's reason as its prompt — an extra LLM call, and the model retyping our data.
# PostToolUse's additionalContext is appended to the tool result verbatim (confirmed: the main agent receives
# "<scout answer>\n<additionalContext>").

# The scout's own text can't be removed (PostToolUse can only append), and models sometimes wrap their JSON in prose. So the
# appended block starts with a clean, numbered file list and says it's the one to rely on; only files `deepgraph show`
# confirmed make that list, so a path the scout invented isn't passed on as real.

# Foreground calls only: for a background call, tool_response is just the launch notice, so there's nothing to enrich.
# Anything unexpected (unparseable answer, deepgraph missing, unknown path) is logged and skipped; the scout's own answer
# still reaches the main agent unchanged.

set -uo pipefail

INPUT="$(cat)"

ROOT_DIR="${QWEN_PROJECT_DIR:-$(pwd)}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_SCRIPT="$SCRIPT_DIR/scripts/lib.sh"
[[ -f "$LIB_SCRIPT" ]] || exit 0
# shellcheck source=scripts/lib.sh
source "$LIB_SCRIPT"

[[ "$(jq -r '.tool_input.subagent_type // empty' <<<"$INPUT")" == "sourcemap-scout" ]] || exit 0
[[ "$(jq -r '.tool_input.run_in_background // false' <<<"$INPUT")" == "true" ]] && exit 0

OUT_DIR="$ROOT_DIR/$SOURCEMAP_REL_DIR"
[[ -d "$OUT_DIR" ]] || exit 0
init_error_log "$ROOT_DIR" || exit 0

answer="$(jq -r '.tool_response.returnDisplay.result // (.tool_response.llmContent // [] | map(.text // empty) | join("\n"))' <<<"$INPUT")"

# The model may wrap its JSON in a ```json fence or add a stray line around it: take the outermost {...}
json="$(printf '%s\n' "$answer" | awk '{a[NR]=$0} /{/ && !first {first=NR} /}/ {last=NR} END {for (i = first; first && i <= last; i++) print a[i]}')"
if [[ -z "$json" ]] || ! paths="$(jq -r '.files // [] | .[] | if type == "string" then . else .path // empty end' <<<"$json" 2>/dev/null)"; then
  log_error "could not parse the scout's answer: ${answer:0:300}"
  exit 0
fi

# Wrapped in the same clean header whether or not any file made it, so the main agent always gets an unambiguous result
emit() {
  jq -n --arg ctx "
$1" '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $ctx}}'
}
no_files="No files in the sourcemap match this task; search the codebase yourself."

if [[ -z "$paths" ]]; then
  emit "$no_files"
  exit 0
fi

if [[ ! -x "$DEEPGRAPH_BIN" ]]; then
  log_error "deepgraph is not available; the scout's files were passed on without details"
  exit 0
fi

nodes="[]"
while IFS= read -r path; do
  [[ -n "$path" ]] || continue
  if node="$("$DEEPGRAPH_BIN" show "$OUT_DIR" "$path" --compact 2>&1)"; then
    # The main agent only needs what the file does and what would be affected by changing it
    nodes="$(jq -c --argjson n "$node" '. + [$n | {path, ctx, dependents}]' <<<"$nodes")"
  else
    log_error "deepgraph show failed for the scout's pick \"$path\": $node"
  fi
done <<<"$paths"

if [[ "$nodes" == "[]" ]]; then
  emit "$no_files"
  exit 0
fi

list="$(jq -r 'to_entries[] | "\(.key + 1). \(.value.path)\n   ctx: \(if .value.ctx == "" then "(not annotated)" else .value.ctx end)\n   dependents: \(if (.value.dependents | length) == 0 then "none" else (.value.dependents | join(", ")) end)"' <<<"$nodes")"
emit "Relevant files:
$list"
