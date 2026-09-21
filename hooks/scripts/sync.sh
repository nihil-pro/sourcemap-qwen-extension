#!/usr/bin/env bash
# Regenerates routes.yaml from the current filesystem while preserving the existing "::meta" for every file or directory whose path is unchanged,
# so hand- or LLM-filled metadata isn't lost on every rerun.
# A path that's new gets fresh empty meta; a path that no longer exists is simply dropped.
# Both are reported on stdout so a hook (or a human) can see what changed structurally.

# Note:
# if a path is reused between a different file and directory across runs,
# the old meta is still carried over onto the new node, since matching is by path only. Re-tag it manually if that happens.

# Usage: ./sync.sh [root_dir] [output_file]
#   root_dir     directory to scan (default: ".")
#   output_file  path for the yaml file, relative to root_dir, read and
#                rewritten in place (default: lib.sh's DEFAULT_OUTPUT_FILE)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

ROOT_DIR_ARG="${1:-.}"
OUTPUT_FILE="${2:-$DEFAULT_OUTPUT_FILE}"

ROOT_DIR="$(cd "$ROOT_DIR_ARG" && pwd)"
OUTPUT_PATH="$ROOT_DIR/$OUTPUT_FILE"
mkdir -p "$(dirname "$OUTPUT_PATH")"

# Old "::meta" blocks are stashed as tiny files under this dir, one per
# path, so a lookup is a plain file check (works on bash 3.2 — no
# associative arrays) and "what's left over" after the walk = removed
# paths. A node at path "a/b" is stored at "$OLD_META_DIR/a/b.node-meta",
# which can never collide with a child stored at "$OLD_META_DIR/a/b/*",
# since the child's directory name ("b") differs from the meta file name
# ("b.node-meta").
OLD_META_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sync_routes.XXXXXX")"
trap 'rm -rf "$OLD_META_DIR"' EXIT

ADDED_LOG="$OLD_META_DIR/.added.log"
: > "$ADDED_LOG"

# Reverses escape_yaml (backslash and double-quote escaping) so a key
# captured from the old file matches a real filename again.
unescape_yaml() {
  local s="$1"
  s="${s//\\\"/\"}"
  s="${s//\\\\/\\}"
  printf '%s' "$s"
}

# --- Phase 1: parse the existing output file, if any, into OLD_META_DIR.
# Walks the file once, tracking the current key stack by indentation (2
# spaces per level, matching what this tool always emits) so each
# "::meta" block can be attributed to its full path and captured verbatim
# — including any content a human or LLM has since added to it, however
# it's shaped, since capture is purely indentation-bounded.
if [[ -f "$OUTPUT_PATH" ]]; then
  old_lines=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    old_lines+=("$line")
  done < "$OUTPUT_PATH"

  stack=()
  i=0
  n=${#old_lines[@]}
  while [[ $i -lt $n ]]; do
    line="${old_lines[$i]}"
    if [[ "$line" =~ ^([[:space:]]*)\"([^\"]*)\":(.*)$ ]]; then
      spaces="${BASH_REMATCH[1]}"
      key="${BASH_REMATCH[2]}"
      depth=$(( ${#spaces} / 2 ))

      if [[ "$key" == "::meta" && $depth -eq ${#stack[@]} ]]; then
        block_indent=${#spaces}
        path="$(IFS=/; echo "${stack[*]}")"
        store_path="$OLD_META_DIR/$path.node-meta"
        mkdir -p "$(dirname "$store_path")"
        j=$(( i + 1 ))
        while [[ $j -lt $n ]]; do
          next="${old_lines[$j]}"
          if [[ -z "$next" ]]; then
            j=$(( j + 1 )); continue
          fi
          [[ "$next" =~ ^([[:space:]]*) ]]
          next_spaces=${#BASH_REMATCH[1]}
          [[ $next_spaces -le $block_indent ]] && break
          j=$(( j + 1 ))
        done
        { printf '%s\n' "${old_lines[@]:$i:$(( j - i ))}"; } > "$store_path"
        i=$j
        continue
      elif [[ "$key" != "::meta" ]]; then
        stack=("${stack[@]:0:$depth}")
        stack[$depth]="$(unescape_yaml "$key")"
      fi
    fi
    i=$(( i + 1 ))
  done
fi

# Emits meta for a node at $2 (relpath), reusing the old block verbatim if
# one was captured for that exact path (its indentation is already
# correct, since indentation is purely a function of path depth), or a
# fresh empty block otherwise ($3: "dir" or "file", picking context-only
# vs. context+depends). A reused block is deleted from OLD_META_DIR so
# leftovers at the end are exactly the removed paths.
emit_meta_for() {
  local indent="$1"
  local relpath="$2"
  local kind="$3"
  local store_path="$OLD_META_DIR/$relpath.node-meta"
  if [[ -f "$store_path" ]]; then
    cat "$store_path"
    rm -f "$store_path"
  else
    if [[ "$kind" == "dir" ]]; then
      emit_meta_dir "$indent"
    else
      emit_meta_file "$indent"
    fi
    printf '%s\n' "$relpath" >> "$ADDED_LOG"
  fi
}

# Same shape as generate.sh's emit_node, but threads the relpath
# (from ROOT_DIR, "/"-joined) through so emit_meta_for can look it up.
emit_node() {
  local entry="$1"
  local indent="$2"
  local relpath="$3"
  local name
  name="$(basename "$entry")"

  if [[ -f "$entry" ]]; then
    printf '%s"%s":\n' "$indent" "$(escape_yaml "$name")"
    is_self_describing "$name" || emit_meta_for "$indent  " "$relpath" "file"
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
    emit_meta_for "$indent  " "$relpath" "dir"
  fi

  if [[ "${#entries[@]}" -gt 0 ]]; then
    for child in "${entries[@]}"; do
      local child_name2 child_relpath
      child_name2="$(basename "$child")"
      if [[ -z "$relpath" ]]; then
        child_relpath="$child_name2"
      else
        child_relpath="$relpath/$child_name2"
      fi
      emit_node "$child" "$indent  " "$child_relpath"
    done
  fi
}

# --- Phase 2: walk the current filesystem and write the new file.
{
  entries=()
  while IFS= read -r -d '' entry; do
    name="$(basename "$entry")"
    is_ignored "$name" && continue
    entries+=("$entry")
  done < <(find "$ROOT_DIR" -mindepth 1 -maxdepth 1 -print0 | sort -z)

  if [[ "${#entries[@]}" -gt 0 ]]; then
    for entry in "${entries[@]}"; do
      name="$(basename "$entry")"
      emit_node "$entry" "" "$name"
    done
  fi
} > "$OUTPUT_PATH.tmp"
mv "$OUTPUT_PATH.tmp" "$OUTPUT_PATH"

# --- Report what changed structurally.
removed=()
while IFS= read -r -d '' f; do
  removed+=("$f")
done < <(find "$OLD_META_DIR" -name '*.node-meta' -print0 2>/dev/null)

echo "Synced $OUTPUT_PATH"

if [[ -s "$ADDED_LOG" ]]; then
  echo "Added meta for new path(s):"
  sed 's/^/  + /' "$ADDED_LOG"
fi

if [[ "${#removed[@]}" -gt 0 ]]; then
  echo "Removed path(s) no longer present:"
  for f in "${removed[@]}"; do
    rel="${f#"$OLD_META_DIR"/}"
    rel="${rel%.node-meta}"
    echo "  - $rel"
  done
fi
