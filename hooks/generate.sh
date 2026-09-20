#!/usr/bin/env bash
# Walks a directory tree and emit a YAML representation of its dirs/files.
# Skips build output and vendored/third-party package directories for Java, Python, JavaScript/TypeScript, Go and .NET.
# Shared ignore/no-meta rules live in lib.sh.

# Each file/directory name (extension included for files) becomes a YAML key,
# holding an "::meta" block plus, for directories, one nested key per child.
# There is no separate "type" or "children" wrapper; nesting itself expresses the tree.

# The "::meta" key uses a "::" prefix so it can't collide with a real file/dir name.

# Pure structural directories and self-describing config/manifest files get no "::meta" block,
# since they carry no meaningful context/depends of their own.

# "::meta" has just three fields:
# "context" – free text about what it does, not how
# "depends" – an array of files only (plain path strings relative to the scanned root)
# "dependents" – an array of files only (plain path strings relative to the scanned root)
# all are left empty here for a later LLM-driven pass to fill in and keep in sync with the code.

# This always writes a fresh map. To regenerate the tree while preserving existing meta for unchanged paths, use sync.sh instead.

# Usage: ./generate.sh [root_dir] [output_file]
#   root_dir     directory to scan (default: ".")
#   output_file  path for the yaml file, relative to root_dir
#                (default: lib.sh's DEFAULT_OUTPUT_FILE)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

ROOT_DIR_ARG="${1:-.}"
OUTPUT_FILE="${2:-$DEFAULT_OUTPUT_FILE}"

ROOT_DIR="$(cd "$ROOT_DIR_ARG" && pwd)"
OUTPUT_PATH="$ROOT_DIR/$OUTPUT_FILE"
mkdir -p "$(dirname "$OUTPUT_PATH")"

# Emits one entry (file or directory) as a YAML mapping key at $2 indent,
# recursing into directories. Directories listed in NO_META_DIRS (pure
# naming conventions, e.g. "src", "cmd") get no "::meta" block of their own.
emit_node() {
  local entry="$1"
  local indent="$2"
  local name
  name="$(basename "$entry")"

  if [[ -f "$entry" ]]; then
    printf '%s"%s":\n' "$indent" "$(escape_yaml "$name")"
    is_self_describing "$name" || emit_meta_file "$indent  "
    return
  fi

  local -a entries=()
  local child child_name
  while IFS= read -r -d '' child; do
    child_name="$(basename "$child")"
    is_ignored "$child_name" && continue
    entries+=("$child")
  done < <(find "$entry" -mindepth 1 -maxdepth 1 -print0 | sort -z)

  local skip_meta=false
  is_no_meta "$name" && skip_meta=true

  if [[ "$skip_meta" == true && "${#entries[@]}" -eq 0 ]]; then
    printf '%s"%s": {}\n' "$indent" "$(escape_yaml "$name")"
    return
  fi

  printf '%s"%s":\n' "$indent" "$(escape_yaml "$name")"

  if [[ "$skip_meta" == false ]]; then
    emit_meta_dir "$indent  "
  fi

  if [[ "${#entries[@]}" -gt 0 ]]; then
    for child in "${entries[@]}"; do
      emit_node "$child" "$indent  "
    done
  fi
}

{
  entries=()
  while IFS= read -r -d '' entry; do
    name="$(basename "$entry")"
    is_ignored "$name" && continue
    entries+=("$entry")
  done < <(find "$ROOT_DIR" -mindepth 1 -maxdepth 1 -print0 | sort -z)

  if [[ "${#entries[@]}" -gt 0 ]]; then
    for entry in "${entries[@]}"; do
      emit_node "$entry" ""
    done
  fi
} > "$OUTPUT_PATH"

echo "Generated $OUTPUT_PATH"
