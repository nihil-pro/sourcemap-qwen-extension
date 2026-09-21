#!/usr/bin/env bash
# adds a "dependents" list to every file's "::meta" in routes.yaml,
# so finalize the bidirectional dependencies graph

# Idempotent: "dependents" is recomputed from scratch on every run
# Files with nothing depending on them get "dependents: []"

# The yaml is processed line by line with plain awk, so it relies on the layout generate.sh/sync.sh emit:
# quoted tree keys, 2-space indentation, and "depends" as a "- path" list or "[]".
# CRLF files keep their line endings.
#
# Usage: ./add-dependents.sh [root_dir] [output_file]
#   root_dir     project root (default: ".")
#   output_file  path of the yaml file, relative to root_dir, read and rewritten in place (default: lib.sh's DEFAULT_OUTPUT_FILE)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

ROOT_DIR_ARG="${1:-.}"
OUTPUT_FILE="${2:-$DEFAULT_OUTPUT_FILE}"

ROOT_DIR="$(cd "$ROOT_DIR_ARG" && pwd)"
OUTPUT_PATH="$ROOT_DIR/$OUTPUT_FILE"

[[ -f "$OUTPUT_PATH" ]] || { echo "error: $OUTPUT_PATH not found" >&2; exit 1; }

trap 'rm -f "$OUTPUT_PATH.tmp"' EXIT

# The file is read twice: pass 1 (NR == FNR) inverts every "depends" edge,
# pass 2 copies the file and writes "dependents" right after each "depends".
awk '
function mkpath(level,   i, p) {
  p = ""
  for (i = 0; i < level; i++) p = p (i ? "/" : "") stack[i]
  return p
}

# Track the key stack from quoted tree keys, e.g.   "App.tsx":
function track(line,   ind, name) {
  match(line, /^ */)
  ind = RLENGTH / 2
  name = line
  sub(/^ *"/, "", name)
  sub(/":.*$/, "", name)
  if (name == "::meta") metalevel = ind
  else stack[ind] = name
}

function out(s) { printf "%s%s", s, eol }

function flush(   n, i, arr) {
  if (curpath in dep) {
    out(pad "dependents:")
    n = split(dep[curpath], arr, "\n")
    for (i = 1; i <= n; i++) out(pad "  - " arr[i])
  } else {
    out(pad "dependents: []")
  }
  indeps = 0
}

FNR == 1 { eol = ($0 ~ /\r$/) ? "\r\n" : "\n" }
{ sub(/\r$/, "") }

# ---- pass 1: collect edges ----
NR == FNR {
  if ($0 ~ /^ *"/) { track($0); cur = "" }
  else if ($0 ~ /^ *depends:/) {
    path = mkpath(metalevel)
    files[path] = 1
    cur = ($0 ~ /\[\]/) ? "" : "depends"
  }
  else if ($0 ~ /^ *- /) {
    if (cur == "depends") {
      item = $0
      sub(/^ *- */, "", item)
      sub(/ *$/, "", item)
      dep[item] = (item in dep) ? dep[item] "\n" path : path
      edges[++nedges] = path " -> " item
      targets[nedges] = item
    }
  }
  else cur = ""
  next
}

# ---- pass 2: rewrite ----
FNR == 1 {
  for (i = 1; i <= nedges; i++)
    if (!(targets[i] in files))
      print "warning: depends target not in map: " edges[i] | "cat 1>&2"
  close("cat 1>&2")
  delete stack
  metalevel = 0
}

skipping && $0 ~ /^ *- / { next }
{ skipping = 0 }
indeps && $0 !~ /^ *- / { flush() }

$0 ~ /^ *dependents:/ { skipping = 1; next }

{
  if ($0 ~ /^ *"/) track($0)
  else if ($0 ~ /^ *depends:/) {
    match($0, /^ */)
    pad = substr($0, 1, RLENGTH)
    curpath = mkpath(metalevel)
    out($0)
    if ($0 ~ /\[\]/) flush(); else indeps = 1
    next
  }
  out($0)
}

END { if (indeps) flush() }
' "$OUTPUT_PATH" "$OUTPUT_PATH" > "$OUTPUT_PATH.tmp"

mv "$OUTPUT_PATH.tmp" "$OUTPUT_PATH"
echo "Updated dependents in $OUTPUT_PATH"
