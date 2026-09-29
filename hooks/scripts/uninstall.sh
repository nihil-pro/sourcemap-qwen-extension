#!/usr/bin/env bash
# Removes everything the extension put into a project's working copy: the @sourcemap block from every file, and the git clean
# filter (.git/info/attributes section and .git/config entries). qwen-code has no uninstall hook, so run it yourself, before
# uninstalling the extension, in every project it was used in: with the filter left configured and its binary gone, git refuses
# to add files (by design, so a block can never be committed silently).
# Keeps the committed notes (.qwen/sourcemap/) and the local state dir; delete those by hand if you don't want them.

# Usage: ./uninstall.sh [root_dir]   (default: the current directory)

set -uo pipefail

ROOT_DIR="$(cd "${1:-.}" && pwd)" || exit 1
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
project_paths "$ROOT_DIR"

if [[ ! -x "$DEEPGRAPH_BIN" ]]; then
  echo "deepgraph isn't built ($DEEPGRAPH_BIN), so the blocks can't be stripped; keeping the git filter" >&2
  exit 1
fi
stripped="$("$DEEPGRAPH_BIN" strip "$ROOT_DIR")" || exit 1
remove_git_filter "$ROOT_DIR"
# The index still records each file's size with its block, so git would report them all as modified until refreshed
[[ -z "$stripped" ]] || refresh_git_index "$ROOT_DIR" "$stripped"
echo "sourcemap: blocks and git filter removed from $ROOT_DIR. Local state left in $STATE_DIR."
