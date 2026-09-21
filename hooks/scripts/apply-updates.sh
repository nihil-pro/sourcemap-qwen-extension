#!/usr/bin/env bash
#
# apply-updates.sh — mechanically rewrites specific nodes' "context" and
# "depends" in routes.yaml from a JSON updates file, leaving every other
# line — including any "dependents" block add-dependents.sh already
# wrote — untouched. The model that produces the updates (refresh-dirty.sh)
# never touches the YAML directly: it only returns content via
# --json-schema structured_output, and this script applies it using the
# same indentation-bounded parsing sync.sh already uses, so a model can't
# corrupt tree structure or unrelated nodes even if it tried.
#
# "depends" is rewritten in the same block-list style add-dependents.sh
# expects to parse ("depends:\n  - path", or "depends: []"), never as a
# flow array — matching whatever convention is already in the file so
# other tooling keeps working.
#
# A target path with no matching node in routes.yaml (e.g. deleted
# between being marked dirty and this running) is silently skipped —
# sync.sh already dropped it structurally, so there's nothing to patch.
#
# "depends" entries are resolved against the real paths already in the
# map, trying the extension-stripped form when an exact match fails —
# models reliably give import-specifier-style paths ("src/app/foo",
# no ".tsx") regardless of prompt wording, since that's just how JS/TS
# imports look; fighting that with more instructions is less robust than
# just resolving it here, the same reasoning as trusting the model for
# content only and never for YAML structure.
#
# Usage: ./apply-updates.sh <root_dir> <updates_json_file> [output_file]
#   updates_json_file: {"files":[{"path":"a/b.ts","context":"...","depends":["c/d.ts"]}]}
#   output_file: relative to root_dir (default: lib.sh's DEFAULT_OUTPUT_FILE)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

ROOT_DIR_ARG="${1:?root_dir required}"
UPDATES_JSON="${2:?updates json file required}"
OUTPUT_FILE="${3:-$DEFAULT_OUTPUT_FILE}"

ROOT_DIR="$(cd "$ROOT_DIR_ARG" && pwd)"
ROUTES_FILE="$ROOT_DIR/$OUTPUT_FILE"

[[ -f "$ROUTES_FILE" ]] || { echo "error: $ROUTES_FILE not found" >&2; exit 1; }
[[ -f "$UPDATES_JSON" ]] || { echo "error: $UPDATES_JSON not found" >&2; exit 1; }

unescape_yaml() {
  local s="$1"
  s="${s//\\\"/\"}"
  s="${s//\\\\/\\}"
  printf '%s' "$s"
}

old_lines=()
while IFS= read -r line || [[ -n "$line" ]]; do
  old_lines+=("$line")
done < "$ROUTES_FILE"
n=${#old_lines[@]}

# --- Pass 0: build a lookup of every known file path in the map, plus its
# extension-stripped form, for resolving "depends" entries below. Written
# to a temp file (path<TAB>noext) rather than a bash associative array,
# since this must stay bash-3.2-compatible (macOS's default bash).
LOOKUP_FILE="$(mktemp "${TMPDIR:-/tmp}/apply_updates_lookup.XXXXXX")"
trap 'rm -f "$LOOKUP_FILE"' EXIT
{
  lookup_stack=()
  for ((x = 0; x < n; x++)); do
    l="${old_lines[$x]}"
    if [[ "$l" =~ ^([[:space:]]*)\"([^\"]*)\":(.*)$ ]]; then
      sp="${BASH_REMATCH[1]}"
      ky="${BASH_REMATCH[2]}"
      [[ "$ky" == "::meta" ]] && continue
      d=$(( ${#sp} / 2 ))
      lookup_stack=("${lookup_stack[@]:0:$d}")
      lookup_stack[$d]="$(unescape_yaml "$ky")"
      # a file node's own key contains a "." in its last segment
      if [[ "$ky" == *.* ]]; then
        p="$(IFS=/; echo "${lookup_stack[*]}")"
        printf '%s\t%s\n' "$p" "${p%.*}"
      fi
    fi
  done
} > "$LOOKUP_FILE"

resolve_dep() {
  local item="$1"
  # already an exact, correct path
  if awk -F'\t' -v x="$item" '$1==x{f=1; exit} END{exit !f}' "$LOOKUP_FILE"; then
    printf '%s' "$item"
    return
  fi
  # item as given has no extension (the common case — that's just how
  # JS/TS import specifiers look): match it straight against the lookup's
  # extension-stripped column.
  local resolved
  resolved="$(awk -F'\t' -v x="$item" '$2==x{print $1; exit}' "$LOOKUP_FILE")"
  if [[ -n "$resolved" ]]; then
    printf '%s' "$resolved"
    return
  fi
  # item has a plausible-but-wrong extension (e.g. the model guessed
  # ".ts" for an actual ".tsx" file) — strip whatever it gave and retry.
  local item_noext="${item%.*}"
  if [[ "$item_noext" != "$item" ]]; then
    resolved="$(awk -F'\t' -v x="$item_noext" '$2==x{print $1; exit}' "$LOOKUP_FILE")"
    if [[ -n "$resolved" ]]; then
      printf '%s' "$resolved"
      return
    fi
  fi
  printf '%s' "$item"
}

stack=()
i=0
patched_count=0

{
  while [[ $i -lt $n ]]; do
    line="${old_lines[$i]}"
    if [[ "$line" =~ ^([[:space:]]*)\"([^\"]*)\":(.*)$ ]]; then
      spaces="${BASH_REMATCH[1]}"
      key="${BASH_REMATCH[2]}"
      depth=$(( ${#spaces} / 2 ))

      if [[ "$key" == "::meta" && $depth -eq ${#stack[@]} ]]; then
        block_indent=${#spaces}
        path="$(IFS=/; echo "${stack[*]}")"

        j=$(( i + 1 ))
        while [[ $j -lt $n ]]; do
          next="${old_lines[$j]}"
          if [[ -z "$next" ]]; then j=$(( j + 1 )); continue; fi
          [[ "$next" =~ ^([[:space:]]*) ]]
          next_spaces=${#BASH_REMATCH[1]}
          [[ $next_spaces -le $block_indent ]] && break
          j=$(( j + 1 ))
        done

        update="$(jq -c --arg p "$path" '.files[]? | select(.path == $p)' "$UPDATES_JSON")"
        if [[ -n "$update" ]]; then
          new_context="$(jq -r '.context // ""' <<<"$update")"
          # An empty context is never written back as-is: populate.sh's
          # enumerate_pending() uses `context: ""` as the sentinel for
          # "not yet processed" (see its header), so a model that
          # legitimately has nothing to say about a trivial file would
          # otherwise be indistinguishable from a node that was never
          # touched at all, and could get endlessly re-queued by a later
          # pass. The prompt already tells the model to always give some
          # description; this is the backstop for when it doesn't.
          [[ -z "$new_context" ]] && new_context="(no description)"

          # Collect the block's lines minus the old "context:" and
          # "depends:" (with its own "- item" lines) — anything left
          # (e.g. a "dependents" block add-dependents.sh wrote, or any
          # future field) is preserved verbatim, printed after our new
          # context/depends so field order stays context/depends/rest.
          has_depends_field=0
          preserved=()
          skip_depends_indent=-1
          for ((k = i + 1; k < j; k++)); do
            cur="${old_lines[$k]}"
            if [[ "$skip_depends_indent" -ge 0 ]]; then
              if [[ "$cur" =~ ^([[:space:]]*)-[[:space:]] && ${#BASH_REMATCH[1]} -gt $skip_depends_indent ]]; then
                continue
              fi
              skip_depends_indent=-1
            fi
            if [[ "$cur" =~ ^([[:space:]]*)context:(.*)$ ]]; then
              continue
            fi
            if [[ "$cur" =~ ^([[:space:]]*)depends:(.*)$ ]]; then
              has_depends_field=1
              skip_depends_indent=${#BASH_REMATCH[1]}
              continue
            fi
            preserved+=("$cur")
          done

          printf '%s\n' "$line"
          printf '%s  context: "%s"\n' "$spaces" "$(escape_yaml "$new_context")"

          if [[ "$has_depends_field" -eq 1 ]]; then
            deps_count="$(jq '(.depends // []) | length' <<<"$update")"
            if [[ "$deps_count" -eq 0 ]]; then
              printf '%s  depends: []\n' "$spaces"
            else
              printf '%s  depends:\n' "$spaces"
              while IFS= read -r dep; do
                printf '%s    - %s\n' "$spaces" "$(resolve_dep "$dep")"
              done < <(jq -r '.depends[]' <<<"$update")
            fi
          fi

          if [[ "${#preserved[@]}" -gt 0 ]]; then
            printf '%s\n' "${preserved[@]}"
          fi

          patched_count=$((patched_count + 1))
        else
          printf '%s\n' "${old_lines[@]:$i:$(( j - i ))}"
        fi
        i=$j
        continue
      elif [[ "$key" != "::meta" ]]; then
        stack=("${stack[@]:0:$depth}")
        stack[$depth]="$(unescape_yaml "$key")"
      fi
    fi
    printf '%s\n' "$line"
    i=$(( i + 1 ))
  done
} > "$ROUTES_FILE.tmp"

mv "$ROUTES_FILE.tmp" "$ROUTES_FILE"
echo "Patched $patched_count node(s) in $ROUTES_FILE"
