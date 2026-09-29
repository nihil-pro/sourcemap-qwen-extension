#!/usr/bin/env bash
# Builds the vendored deepgraph (<extension>/deepgraph) with cargo and installs the binary into $SOURCEMAP_HOME/bin.
# qwen-code has no postinstall hook, so this runs from annotate.sh, in the background of the first session after install.

# No-op when the binary is already there and was built from the current sources (see lib.sh's DEEPGRAPH_STAMP).
# Two sessions starting together both land here; the second waits for the first's build instead of starting its own.
# On failure, leaves DEEPGRAPH_BUILD_FAILED behind so bootstrap.sh can tell the user once, instead of failing silently forever.

# Usage: ./build-deepgraph.sh <root_dir>
#   root_dir  project root, only used to read workspace-scope settings

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

ROOT_DIR="$(project_root "${1:-$(pwd)}")"
init_error_log "$ROOT_DIR"
load_settings "$ROOT_DIR"
deepgraph_is_built && exit 0

mkdir -p "$DEEPGRAPH_BIN_DIR"
LOCK_DIR="$DEEPGRAPH_BIN_DIR/.build.lock"
# A release build from scratch takes a few minutes: wait up to 30 min
wait_lock "$LOCK_DIR" 1800 1 || { log_error "timed out waiting for another deepgraph build ($LOCK_DIR)"; exit 1; }
trap 'release_lock "$LOCK_DIR"' EXIT

# Another session may have finished the build while we waited
deepgraph_is_built && exit 0

fail() {
  # the marker is shown to the user by bootstrap.sh, so it gets just the first line; error.log gets everything
  printf '%s\n' "${1%%$'\n'*}" > "$DEEPGRAPH_BUILD_FAILED"
  log_error "$1"
  exit 1
}

# Hook processes don't source the user's shell profile, so rustup's default location may be missing from PATH
command -v cargo >/dev/null 2>&1 || PATH="$HOME/.cargo/bin:$PATH"
command -v cargo >/dev/null 2>&1 || fail "cargo not found (is Rust installed?)"

stamp="$(deepgraph_source_stamp)"
args=(build --release --locked --manifest-path "$DEEPGRAPH_SRC/Cargo.toml")

# The full cargo output goes to its own build log; error.log gets its tail, which is where cargo's error summary is
if ! cargo "${args[@]}" > "$DEEPGRAPH_BUILD_LOG" 2>&1; then
  fail "cargo build failed (full log: $DEEPGRAPH_BUILD_LOG):
$(tail -n 30 "$DEEPGRAPH_BUILD_LOG")"
fi

cp "$DEEPGRAPH_SRC/target/release/deepgraph" "$DEEPGRAPH_BIN.tmp" && mv "$DEEPGRAPH_BIN.tmp" "$DEEPGRAPH_BIN" \
  || fail "could not install $DEEPGRAPH_BIN"
printf '%s' "$stamp" > "$DEEPGRAPH_STAMP"
rm -f "$DEEPGRAPH_BUILD_FAILED"
