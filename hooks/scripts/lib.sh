#!/usr/bin/env bash
# Shared config and helpers for the hooks and scripts. Not meant to be run directly; source it from bash.
# Must stay bash-3.2-compatible (macOS's default bash): no associative arrays, no mapfile,
# and every possibly-empty array expanded as ${arr[@]+"${arr[@]}"} under `set -u`.

# Per-project generated data, relative to the project root (not this extension's install location).
# deepgraph writes graph.json (structure, fully regenerated each build) and ctx.json (LLM notes, preserved across builds) here.
# This is the single source of truth for that path.
SOURCEMAP_REL_DIR=".qwen/sourcemap"

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXT_DIR="$(cd "$_LIB_DIR/../.." && pwd)"

# deepgraph's source is vendored into the extension and built on first use (qwen-code has no postinstall hook).
# bin/ is recreated from scratch whenever qwen reinstalls/updates the extension, which is what triggers a rebuild of a new version.
DEEPGRAPH_SRC="$EXT_DIR/deepgraph"
EXT_BIN_DIR="$EXT_DIR/bin"
DEEPGRAPH_BIN="$EXT_BIN_DIR/deepgraph"
# Holds the cargo feature set the binary was built with, so changing the ONNX Runtime setting triggers a rebuild
DEEPGRAPH_STAMP="$EXT_BIN_DIR/.build-stamp"
DEEPGRAPH_BUILD_LOG="$EXT_BIN_DIR/build.log"
DEEPGRAPH_BUILD_FAILED="$EXT_BIN_DIR/.build-failed"

# Sends the calling script's stderr to the project's error.log, so every failure — explicit log_error calls and whatever a
# command prints to stderr — ends up in one place instead of /dev/null (hooks' and background runs' output is never seen).
# Call right after sourcing this file; child scripts inherit the redirect. Trims the log to its last 1000 lines past ~1MB.
# Usage: init_error_log <root_dir>
init_error_log() {
  local dir="$1/$SOURCEMAP_REL_DIR"
  SOURCEMAP_ERROR_LOG="$dir/error.log"
  mkdir -p "$dir" || return 1
  if [[ -f "$SOURCEMAP_ERROR_LOG" && $(wc -c < "$SOURCEMAP_ERROR_LOG") -gt 1048576 ]]; then
    tail -n 1000 "$SOURCEMAP_ERROR_LOG" > "$SOURCEMAP_ERROR_LOG.tmp" && mv "$SOURCEMAP_ERROR_LOG.tmp" "$SOURCEMAP_ERROR_LOG"
  fi
  exec 2>>"$SOURCEMAP_ERROR_LOG"
}

# Usage: log_error <message...>
log_error() {
  printf '%s [%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(basename "$0")" "$*" >&2
}

# Reads one key from a dotenv file the way qwen-code writes it: KEY=value, or KEY="value" when the value has a space
_read_env_key() {
  local file="$1" key="$2" line val
  [[ -f "$file" ]] || return 1
  line="$(grep -E "^[[:space:]]*$key=" "$file" 2>/dev/null | tail -n 1)" || return 1
  [[ -n "$line" ]] || return 1
  val="${line#*=}"
  if [[ "$val" == \"*\" || "$val" == \'*\' ]]; then
    val="${val:1:${#val}-2}"
  fi
  printf '%s' "$val"
}

# Loads the settings asked for at install time (see qwen-extension.json's "settings").
# qwen-code passes those only to MCP servers, never to hook processes, so they're read straight from where it stores them:
# the user-scope file inside the extension dir, overridden by the workspace-scope .env in the project root.
# A variable already set in the environment wins over both.
# Usage: load_settings <root_dir>
load_settings() {
  local root="$1" key val
  for key in SOURCEMAP_ONNX_RUNTIME SOURCEMAP_MODEL_DIR SOURCEMAP_EXCLUDE SOURCEMAP_OPENAI_LOGGING SOURCEMAP_ANNOTATE; do
    [[ -n "${!key:-}" ]] && continue
    val="$(_read_env_key "$root/.env" "$key")" || val="$(_read_env_key "$EXT_DIR/.env" "$key")" || val=""
    # prompts store whatever was typed, so expand a leading "~" for the two path settings
    [[ ( "$key" == SOURCEMAP_ONNX_RUNTIME || "$key" == SOURCEMAP_MODEL_DIR ) && "$val" == "~"* ]] && val="$HOME${val:1}"
    printf -v "$key" '%s' "$val"
    export "${key?}"
  done
}

# Usage: is_true <value>  — true/yes/1/on, case-insensitive (settings are free-text answers to an install prompt)
is_true() {
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    true|yes|1|on) return 0 ;;
    *) return 1 ;;
  esac
}

# LLM notes are on unless SOURCEMAP_ANNOTATE is set to something other than true/yes/1/on.
# Off means no qwen calls at all: search then matches file paths and exported names only.
annotation_enabled() {
  [[ -z "${SOURCEMAP_ANNOTATE:-}" ]] || is_true "$SOURCEMAP_ANNOTATE"
}

# Every direct qwen call from the extension's scripts goes through this, so the logging setting applies to all of them.
# With SOURCEMAP_OPENAI_LOGGING on, adds --openai-logging (qwen then logs each API request/response, to its default log dir).
# stdin is always /dev/null: qwen reads stdin as extra prompt input, so inside a `while read` loop it would swallow the
# loop's remaining input (confirmed: annotate.sh stopped after its first batch, with no error, until this was added).
# Usage: run_qwen <qwen args...>
run_qwen() {
  local -a extra=()
  is_true "${SOURCEMAP_OPENAI_LOGGING:-}" && extra+=(--openai-logging)
  qwen ${extra[@]+"${extra[@]}"} "$@" </dev/null
}

# Semantic search needs a local ONNX Runtime; without one, deepgraph is built with its default features (fuzzy search only)
deepgraph_features() {
  if [[ -n "${SOURCEMAP_ONNX_RUNTIME:-}" ]]; then
    printf 'embeddings-local-runtime'
  fi
}

deepgraph_is_built() {
  [[ -x "$DEEPGRAPH_BIN" && -f "$DEEPGRAPH_STAMP" ]] || return 1
  [[ "$(cat "$DEEPGRAPH_STAMP")" == "$(deepgraph_features)" ]]
}

# Regenerates graph.json and syncs ctx.json's file list (never touching existing notes).
# Callers must hold the write lock: ctx.json is also rewritten by annotate.sh, and deepgraph doesn't write it atomically.
# Usage: deepgraph_build <root_dir>
deepgraph_build() {
  local root="$1" pat
  local -a args=(build "$root" "$root/$SOURCEMAP_REL_DIR")
  local -a patterns=()
  IFS=',' read -ra patterns <<<"${SOURCEMAP_EXCLUDE:-}"
  for pat in ${patterns[@]+"${patterns[@]}"}; do
    # trim surrounding whitespace, since "a, b" is how people naturally type a comma-separated list
    pat="${pat#"${pat%%[![:space:]]*}"}"
    pat="${pat%"${pat##*[![:space:]]}"}"
    [[ -n "$pat" ]] && args+=(--exclude "$pat")
  done
  # deepgraph reports progress on stderr too, so its output is only logged when the build actually fails
  local out
  if ! out="$("$DEEPGRAPH_BIN" "${args[@]}" 2>&1 >/dev/null)"; then
    log_error "deepgraph build failed: $out"
    return 1
  fi
}

# Prints "path<TAB>hash" for every file whose note is missing (empty ctx) or stale (ctx_hash no longer matches the file's content hash)
# Usage: enumerate_pending <sourcemap_dir>
enumerate_pending() {
  local dir="$1"
  jq -r --slurpfile g "$dir/graph.json" '
    ($g[0].nodes) as $n
    | to_entries[]
    | select($n[.key] != null)
    | select(.value.ctx == "" or .value.ctx_hash != $n[.key].hash)
    | "\(.key)\t\($n[.key].hash)"
  ' "$dir/ctx.json"
}

# mkdir is atomic on both macOS and Linux, so it doubles as a cheap lock.
# The holder's pid is recorded inside, so a lock left behind by a killed process is reclaimed rather than blocking forever.
try_lock() {
  local dir="$1" pid
  if mkdir "$dir" 2>/dev/null; then
    echo "$$" > "$dir/pid"
    return 0
  fi
  pid="$(cat "$dir/pid" 2>/dev/null)"
  if [[ -n "$pid" ]] && ! kill -0 "$pid" 2>/dev/null; then
    rm -rf "$dir"
    if mkdir "$dir" 2>/dev/null; then
      echo "$$" > "$dir/pid"
      return 0
    fi
  fi
  return 1
}

# Usage: wait_lock <dir> <tries> [sleep_seconds]
wait_lock() {
  local dir="$1" tries="$2" delay="${3:-0.05}" i
  for (( i = 0; i < tries; i++ )); do
    try_lock "$dir" && return 0
    sleep "$delay"
  done
  return 1
}

release_lock() {
  rm -rf "$1"
}
