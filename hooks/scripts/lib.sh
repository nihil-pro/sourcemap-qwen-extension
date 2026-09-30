#!/usr/bin/env bash
# Shared config and helpers for the hooks and scripts. Not meant to be run directly; source it from bash.
# Must stay bash-3.2-compatible (macOS's default bash): no associative arrays, no mapfile,
# and every possibly-empty array expanded as ${arr[@]+"${arr[@]}"} under `set -u`.

# Everything the extension generates lives outside the project and outside the extension's install dir (which qwen
# replaces on every extension update), except the notes file, which is committed so notes are paid for only once per team.
# SOURCEMAP_HOME can be overridden (tests do).
SOURCEMAP_HOME="${SOURCEMAP_HOME:-$HOME/.qwen/sourcemap}"

# Notes (one LLM-written sentence per file) are shared through git: this file is meant to be committed.
NOTES_REL=".qwen/sourcemap/notes.jsonl"

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXT_DIR="$(cd "$_LIB_DIR/../.." && pwd)"

# deepgraph's source is vendored into the extension and built on first use (qwen-code has no postinstall hook).
# The binary is installed at a stable path, not inside the extension, because the git clean filter configured in each project
# (see setup_git_filter) runs it on every `git add`/`git status`: a path that disappears on an extension update would break git.
DEEPGRAPH_SRC="$EXT_DIR/deepgraph"
DEEPGRAPH_BIN_DIR="$SOURCEMAP_HOME/bin"
DEEPGRAPH_BIN="$DEEPGRAPH_BIN_DIR/deepgraph"
# Checksum of the sources the binary was built from, so an extension update (or a local edit) triggers a rebuild
DEEPGRAPH_STAMP="$DEEPGRAPH_BIN_DIR/.build-stamp"
DEEPGRAPH_BUILD_LOG="$SOURCEMAP_HOME/build.log"
DEEPGRAPH_BUILD_FAILED="$SOURCEMAP_HOME/.build-failed"

# The file types deepgraph writes @sourcemap blocks into (walk.rs's detect_lang), for the git attributes
SOURCEMAP_EXTS="java py pyi js jsx mjs cjs ts mts cts tsx md markdown"

# The sourcemap covers a whole git repository, whichever of its subdirectories qwen was started in: a session in a
# subdirectory treated as its own project would keep a second set of notes (paying for them again) and rewrite the same
# files' blocks with paths relative to itself, fighting a session started at the repository root. Outside git, it's the
# directory itself.
# Usage: ROOT_DIR="$(project_root <dir>)"
project_root() {
  git -C "$1" rev-parse --show-toplevel 2>/dev/null || (cd "$1" && pwd)
}

# Sets STATE_DIR (this project's local, disposable data: graph.json, error.log, locks) and NOTES_FILE.
# The state dir is named after the project's directory plus a checksum of its full path, so two projects never share one.
# Usage: project_paths <root_dir>
project_paths() {
  local root="$1"
  STATE_DIR="$SOURCEMAP_HOME/projects/$(basename "$root")-$(printf '%s' "$root" | cksum | cut -d' ' -f1)"
  NOTES_FILE="$root/$NOTES_REL"
}

# Sends the calling script's stderr to the project's error.log, so every failure — explicit log_error calls and whatever a
# command prints to stderr — ends up in one place instead of /dev/null (hooks' and background runs' output is never seen).
# Call right after sourcing this file; child scripts inherit the redirect. Trims the log to its last 1000 lines past ~1MB.
# Also sets the project_paths variables.
# Usage: init_error_log <root_dir>
init_error_log() {
  project_paths "$1"
  SOURCEMAP_ERROR_LOG="$STATE_DIR/error.log"
  mkdir -p "$STATE_DIR" || return 1
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
# the user-scope file inside the extension dir, overridden by the workspace-scope .env in the directory qwen was started in
# (which may be a subdirectory of the project root, see project_root), or else in the project root.
# A variable already set in the environment wins over both.
# Usage: load_settings <root_dir>
load_settings() {
  local root="$1" key val
  for key in SOURCEMAP_EXCLUDE SOURCEMAP_OPENAI_LOGGING SOURCEMAP_ANNOTATE; do
    [[ -n "${!key:-}" ]] && continue
    val="$(_read_env_key "${QWEN_PROJECT_DIR:-$root}/.env" "$key")" || val="$(_read_env_key "$root/.env" "$key")" \
      || val="$(_read_env_key "$EXT_DIR/.env" "$key")" || val=""
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
# Off means no qwen calls at all: blocks then carry dependents only.
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

# Checksum of everything the binary is built from
deepgraph_source_stamp() {
  (cd "$DEEPGRAPH_SRC" && LC_ALL=C find Cargo.toml Cargo.lock src -type f | LC_ALL=C sort | xargs cat) | cksum | cut -d' ' -f1
}

deepgraph_is_built() {
  [[ -x "$DEEPGRAPH_BIN" && -f "$DEEPGRAPH_STAMP" ]] || return 1
  [[ "$(cat "$DEEPGRAPH_STAMP")" == "$(deepgraph_source_stamp)" ]]
}

# Regenerates graph.json, tidies the notes file (drops notes of deleted files, resolves duplicates a union merge left), and
# with --headers brings every file's @sourcemap block up to date.
# Callers must hold the write lock: the notes file is also rewritten by annotate.sh.
# Usage: deepgraph_build <root_dir> [--headers]
deepgraph_build() {
  local root="$1" pat
  shift
  local -a args=(build "$root" "$STATE_DIR" --notes "$NOTES_FILE" "$@")
  local -a patterns=()
  IFS=',' read -ra patterns <<<"${SOURCEMAP_EXCLUDE:-}"
  for pat in ${patterns[@]+"${patterns[@]}"}; do
    # trim surrounding whitespace, since "a, b" is how people naturally type a comma-separated list
    pat="${pat#"${pat%%[![:space:]]*}"}"
    pat="${pat%"${pat##*[![:space:]]}"}"
    [[ -n "$pat" ]] && args+=(--exclude "$pat")
  done
  # deepgraph reports progress on stderr too, so its stderr is only logged when the build actually fails.
  # stdout lists the files whose block was rewritten.
  local err_file written
  err_file="$(mktemp "${TMPDIR:-/tmp}/sourcemap_build_err.XXXXXX")"
  if ! written="$("$DEEPGRAPH_BIN" "${args[@]}" 2>"$err_file")"; then
    log_error "deepgraph build failed: $(cat "$err_file")"
    rm -f "$err_file"
    return 1
  fi
  rm -f "$err_file"
  [[ -z "$written" ]] || refresh_git_index "$root" "$written"
}

# After blocks were rewritten: a file whose size changed is reported as modified by `git status` without git even running the
# clean filter (it trusts the size recorded in the index), so every block write would show up as a change. `git add` of a file
# whose filtered content equals the index re-records its size without changing what's staged; only such files get it, never a
# file with real unstaged changes, and never an untracked one.
# Usage: refresh_git_index <root_dir> <newline-separated paths relative to root>
refresh_git_index() {
  local root="$1" written="$2" tracked changed unchanged
  git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  local -a git=(git --literal-pathspecs -c core.quotePath=false -C "$root")
  tracked="$(printf '%s\n' "$written" | tr '\n' '\0' | xargs -0 "${git[@]}" ls-files -- | sort)"
  [[ -n "$tracked" ]] || return 0
  changed="$(printf '%s\n' "$tracked" | tr '\n' '\0' | xargs -0 "${git[@]}" diff --relative --name-only -- | sort)"
  unchanged="$(comm -23 <(printf '%s\n' "$tracked") <(printf '%s\n' "$changed") | sed '/^$/d')"
  [[ -n "$unchanged" ]] || return 0
  printf '%s\n' "$unchanged" | tr '\n' '\0' | xargs -0 "${git[@]}" add -- \
    || log_error "could not refresh git's index after writing blocks (is another git command running?)"
}

# Prints "path<TAB>hash" for every file whose note is missing or was written for other content
deepgraph_pending() {
  "$DEEPGRAPH_BIN" pending "$STATE_DIR" --notes "$NOTES_FILE"
}

# --- git clean filter -------------------------------------------------------------------------------------------------
# The @sourcemap blocks exist only in the working tree: a clean filter strips them whenever git reads a file, so they never
# reach the index, commits or `git diff`, and a block-only change shows as no change at all. Configured locally only
# (.git/info/attributes and .git/config), so nothing is committed and teammates are unaffected.
# `required = true` makes git fail loudly rather than commit a block if the filter ever can't run. It applies to both
# directions, so a smudge command is needed too, even though checkout has nothing to add: with only `clean` configured, git
# treats the missing smudge as a failed required filter, and checkout, pull, stash and branch switches fail. `cat` passes
# the content through; the blocks come back at the end of the next turn.

_git_common_dir() {
  local root="$1" dir
  dir="$(git -C "$root" rev-parse --git-common-dir 2>/dev/null)" || return 1
  (cd "$root" && cd "$dir" && pwd)
}

# Blocks are written only when this succeeds, i.e. in a git work tree where the filter is set up and proven to work.
# Refuses when another attribute already routes one of our file types through a filter (e.g. Git LFS): a path takes a single
# filter, and ours (in info/attributes, which has the highest precedence) would silently replace it.
# Usage: setup_git_filter <root_dir>
setup_git_filter() {
  local root="$1" common attrs ext conflicts section current wanted expected
  command -v git >/dev/null 2>&1 || return 1
  git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
  common="$(_git_common_dir "$root")" || return 1
  attrs="$common/info/attributes"

  local ext_re
  ext_re="$(printf '%s' "$SOURCEMAP_EXTS" | tr ' ' '|')"
  conflicts="$(
    {
      git -C "$root" ls-files -z --full-name -- ':(top)*.gitattributes' 2>/dev/null \
        | (cd "$(git -C "$root" rev-parse --show-toplevel)" && xargs -0 cat 2>/dev/null)
      [[ -f "$attrs" ]] && sed '/^# >>> sourcemap/,/^# <<< sourcemap/d' "$attrs"
    } | grep -E '(^|[[:space:]])filter=' | grep -v 'filter=sourcemap' \
      | awk '{print $1}' | grep -E "(\.($ext_re)|\*)\$" | sort -u
  )"
  if [[ -n "$conflicts" ]]; then
    log_error "blocks disabled: other git filters apply to supported file types ($(paste -sd ' ' - <<<"$conflicts"))"
    return 1
  fi

  section="# >>> sourcemap (generated: strips the local @sourcemap blocks before git reads a file)"$'\n'
  for ext in $SOURCEMAP_EXTS; do section+="*.$ext filter=sourcemap"$'\n'; done
  section+="# <<< sourcemap"
  current="$(cat "$attrs" 2>/dev/null)"
  wanted="$(sed '/^# >>> sourcemap/,/^# <<< sourcemap/d' <<<"$current")"
  wanted="${wanted:+$wanted$'\n'}$section"
  if [[ "$current" != "$wanted" ]]; then
    mkdir -p "$common/info" && printf '%s\n' "$wanted" > "$attrs.tmp" && mv "$attrs.tmp" "$attrs" \
      || { log_error "could not write $attrs"; return 1; }
  fi

  expected="'$DEEPGRAPH_BIN' clean %f"
  if [[ "$(git -C "$root" config --local --get filter.sourcemap.clean)" != "$expected" ]]; then
    git -C "$root" config --local filter.sourcemap.clean "$expected" || return 1
  fi
  if [[ "$(git -C "$root" config --local --get filter.sourcemap.smudge)" != "cat" ]]; then
    git -C "$root" config --local filter.sourcemap.smudge cat || return 1
  fi
  if [[ "$(git -C "$root" config --local --get filter.sourcemap.required)" != "true" ]]; then
    git -C "$root" config --local filter.sourcemap.required true || return 1
  fi

  # Proof, through git itself, that a file with a block hashes exactly like the same file without one
  local with without
  with="$(printf 'x\n\n/* @sourcemap (generated; do not edit)\n * @dependents: none\n * @end-sourcemap */\n' \
    | git -C "$root" hash-object --stdin --path=sourcemap-probe.ts 2>&1)"
  without="$(printf 'x\n' | git -C "$root" hash-object --stdin --no-filters)"
  if [[ "$with" != "$without" ]]; then
    log_error "blocks disabled: the git clean filter isn't working ($with)"
    return 1
  fi
}

# Cheap check (for the hooks) that blocks are on for this project: setup_git_filter configured the filter
headers_enabled() {
  [[ "$(git -C "$1" config --local --get filter.sourcemap.clean 2>/dev/null)" == "'$DEEPGRAPH_BIN' clean %f" ]]
}

# Undoes setup_git_filter
# Usage: remove_git_filter <root_dir>
remove_git_filter() {
  local root="$1" common attrs rest
  common="$(_git_common_dir "$root")" || return 0
  attrs="$common/info/attributes"
  if [[ -f "$attrs" ]]; then
    rest="$(sed '/^# >>> sourcemap/,/^# <<< sourcemap/d' "$attrs")"
    if [[ -n "$rest" ]]; then printf '%s\n' "$rest" > "$attrs"; else rm -f "$attrs"; fi
  fi
  git -C "$root" config --local --remove-section filter.sourcemap 2>/dev/null || true
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
