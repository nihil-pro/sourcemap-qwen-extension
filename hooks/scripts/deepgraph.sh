#!/usr/bin/env bash
# Runs the extension's deepgraph for the sourcemap-scout agent (or a human), via the project-local launcher
# annotate.sh writes to .qwen/sourcemap/deepgraph — agent files get no ${extensionPath} substitution, so the scout
# can't reach bin/deepgraph directly, but it can always run a fixed project-relative path.

# `search` and `show` get this project's sourcemap directory filled in as their <output> argument, so callers write just
# `.qwen/sourcemap/deepgraph search "<query>"` or `.qwen/sourcemap/deepgraph show <path>`. Other subcommands pass through as-is.

# `search` picks the search mode itself, so callers (the scout) have one command and no fallback step to get wrong:
# semantic when the binary was built with it and a model directory is configured (with the install-time ONNX Runtime and
# model settings added), fuzzy otherwise. No model directory means fuzzy: deepgraph would otherwise try to download a
# model from Hugging Face, which can hang on an offline network. A semantic search that still fails (bad model path,
# broken runtime) is logged and the same query is rerun as fuzzy. A caller's own --semantic is ignored.
# A missing binary is logged, and reported on stderr.

# Usage: ./deepgraph.sh <root_dir> <deepgraph args...>

set -uo pipefail

ROOT_DIR="${1:?root_dir required}"
shift
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

if [[ ! -x "$DEEPGRAPH_BIN" ]]; then
  # stderr stays with the caller here (the scout must see the failure), so error.log is written explicitly
  msg="deepgraph is not available (not built yet, or its build failed)"
  printf '%s [%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(basename "$0")" "$msg" >> "$ROOT_DIR/$SOURCEMAP_REL_DIR/error.log" 2>/dev/null
  echo "$msg" >&2
  exit 1
fi

load_settings "$ROOT_DIR"

if [[ "${1:-}" == search ]]; then
  out_dir="$ROOT_DIR/$SOURCEMAP_REL_DIR"
  args=()
  for a in "${@:2}"; do [[ "$a" == --semantic ]] || args+=("$a"); done

  if [[ "$(cat "$DEEPGRAPH_STAMP" 2>/dev/null)" == *embeddings* && -n "$SOURCEMAP_MODEL_DIR" ]]; then
    semantic_args=(--semantic --model-dir "$SOURCEMAP_MODEL_DIR")
    [[ -n "$SOURCEMAP_ONNX_RUNTIME" ]] && semantic_args+=(--onnx-runtime "$SOURCEMAP_ONNX_RUNTIME")
    err_file="$(mktemp "${TMPDIR:-/tmp}/sourcemap_search_err.XXXXXX")"
    if out="$("$DEEPGRAPH_BIN" search "$out_dir" ${args[@]+"${args[@]}"} "${semantic_args[@]}" 2>"$err_file")"; then
      rm -f "$err_file"
      printf '%s\n' "$out"
      exit 0
    fi
    printf '%s [%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(basename "$0")" \
      "semantic search failed, fell back to fuzzy: $(tail -n 5 "$err_file")" >> "$out_dir/error.log" 2>/dev/null
    rm -f "$err_file"
  fi
  exec "$DEEPGRAPH_BIN" search "$out_dir" ${args[@]+"${args[@]}"}
fi

case "${1:-}" in
  show) args=("$1" "$ROOT_DIR/$SOURCEMAP_REL_DIR" "${@:2}") ;;
  *) args=("$@") ;;
esac

exec "$DEEPGRAPH_BIN" "${args[@]}"
