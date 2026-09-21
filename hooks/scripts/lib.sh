#!/usr/bin/env bash
# shared config and helpers for generate.sh and sync.sh. Not meant to be run directly; source it from bash.

# Default output file, relative to the scanned root (the project root, not this extension's install location).

# routes.yaml is per-project generated data, so it lives at a fixed project-relative path,
# independent of where the sourcemap extension itself happens to be installed.
# This is the single source of truth for that path;
# every script/hook that needs it should read this constant rather than hardcoding it again.

# Anything under .qwen is already pruned wholesale by IGNORE_EXACT below,
# so with this default is_ignored's $OUTPUT_FILE check never actually fires;
# it only matters if a caller points output_file somewhere outside .qwen.
DEFAULT_OUTPUT_FILE=".qwen/sourcemap/routes.yaml"

# Directories to skip entirely: VCS/editor metadata, build output,
# dependency/vendor directories for Java, Python, JS/TS, Go and .NET, AI
# coding agent state/config directories, and this tool's own files.
IGNORE_EXACT=(
  # vcs / editor / os
  ".git" ".svn" ".hg" ".idea" ".vscode" ".vs" ".DS_Store"
  # AI coding agents
  ".claude" ".qwen" ".cursor" ".windsurf" ".continue" ".codeium" ".copilot"
  ".aider" ".cline" ".roo" ".cody" ".amazonq" ".devin" ".augment" ".trae"
  ".gigacode" ".gigaide"
  # JavaScript / TypeScript
  "node_modules" "bower_components" "jspm_packages"
  "dist" "build" "out" ".next" ".nuxt" ".output" ".turbo" ".parcel-cache" "coverage"
  # Python
  "venv" ".venv" "env" ".env" "__pycache__" ".tox" ".mypy_cache" ".pytest_cache" ".ruff_cache"
  # Java
  "target" ".gradle" ".mvn"
  # Go
  "vendor"
  # .NET
  "bin" "obj" "packages"
  # noisy generated output (this tool's own scripts live under .qwen/,
  # already covered by the ".qwen" entry above)
  "logs"
)

# Glob-style ignore patterns (matched against the bare entry name).
IGNORE_GLOB=(
  "*.egg-info"
)

# Directories that are pure structural/naming conventions rather than
# meaningful content locations, so they get no "::meta" block of their own
# (their children still do). Covers Java/Kotlin (Maven & Gradle layout),
# Go, .NET and common JS/TS and generic test-folder conventions.
NO_META_DIRS=(
  "src" "lib"
  "main" "java" "kotlin" "resources"
  "test" "tests" "__tests__" "spec"
  "cmd" "pkg" "internal"
  "Properties" "wwwroot"
  "public" "static"
)

# Self-describing config/manifest files: their name and format already say
# what they are, so they get no "::meta" block either.
NO_META_FILES_EXACT=(
  # JS/TS
  "package.json" "package-lock.json" "npm-shrinkwrap.json" "yarn.lock" "pnpm-lock.yaml"
  "tsconfig.json" "jsconfig.json"
  "eslint.config.js" "eslint.config.mjs" "eslint.config.cjs" "eslint.config.ts"
  "vite.config.js" "vite.config.ts" "webpack.config.js" "babel.config.js" "index.html"
  "browserslist"
  # Python
  "requirements.txt" "Pipfile" "Pipfile.lock" "pyproject.toml" "setup.py" "setup.cfg" "poetry.lock" "tox.ini"
  # Java
  "pom.xml" "build.gradle" "build.gradle.kts" "settings.gradle" "settings.gradle.kts" "gradle.properties"
  # Go
  "go.mod" "go.sum"
  # .NET
  "nuget.config" "packages.config" "global.json" "Directory.Build.props"
  # generic project metadata
  ".gitignore" ".gitattributes" ".editorconfig" ".dockerignore"
  "Dockerfile" "docker-compose.yml" "docker-compose.yaml" "Makefile" "LICENSE" "README.md"
  # repo-specific
  "map.yaml"
)

# Glob patterns, matched against the bare filename. The ".*rc" / ".*rc.*"
# pair catches the whole family of dotfile "rc" configs (.eslintrc,
# .prettierrc, .babelrc, .npmrc, .nvmrc, .browserslistrc, .yarnrc,
# .stylelintrc, .huskyrc, ...) without listing each one by hand.
NO_META_FILES_GLOB=(
  ".*rc" ".*rc.*"
  "tsconfig.*.json"
  "*.csproj" "*.sln" "*.fsproj" "*.vbproj"
)

# is_ignored also excludes $OUTPUT_FILE (the yaml this run is writing),
# expected to be set by the calling script before use.
is_ignored() {
  local name="$1"
  local pat
  for pat in "${IGNORE_EXACT[@]}"; do
    [[ "$name" == "$pat" ]] && return 0
  done
  for pat in "${IGNORE_GLOB[@]}"; do
    [[ "$name" == $pat ]] && return 0
  done
  if [[ -n "${OUTPUT_FILE:-}" ]]; then
    local output_base="${OUTPUT_FILE##*/}"
    [[ "$name" == "$output_base" || "$name" == "$output_base.tmp" ]] && return 0
  fi
  return 1
}

is_no_meta() {
  local name="$1"
  local pat
  for pat in "${NO_META_DIRS[@]}"; do
    [[ "$name" == "$pat" ]] && return 0
  done
  return 1
}

is_self_describing() {
  local name="$1"
  local pat
  for pat in "${NO_META_FILES_EXACT[@]}"; do
    [[ "$name" == "$pat" ]] && return 0
  done
  for pat in "${NO_META_FILES_GLOB[@]}"; do
    [[ "$name" == $pat ]] && return 0
  done
  return 1
}

escape_yaml() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "$s"
}

# Directories get context only — a directory doesn't "depend" on things the way a file does, it just groups them.
emit_meta_dir() {
  local indent="$1"
  printf '%s"::meta":\n' "$indent"
  printf '%s  context: ""\n' "$indent"
}

# Files get context plus depends (paths relative to the scanned root —
# see generate.sh's header for why plain paths, not YAML anchors/aliases).
emit_meta_file() {
  local indent="$1"
  printf '%s"::meta":\n' "$indent"
  printf '%s  context: ""\n' "$indent"
  printf '%s  depends: []\n' "$indent"
}
