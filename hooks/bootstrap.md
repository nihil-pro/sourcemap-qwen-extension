## Setup
Check for `.qwen/sourcemap/routes.yaml`. If it doesn't exist, generate it by running: `bash ${CLAUDE_PLUGIN_ROOT}/hooks/generate.sh`

This file represents the project tree. Each node is either a file (has an extension) or a directory. Your task is to populate the `::meta` block for every node, following the rules below.

## Processing rules
- Traverse depth-first, processing files before directories.
- For each file:
  - Reconstruct its absolute path from its parent nodes, then read its contents
  - Focus on **what** the code does, not how it does it. Summarize this in `::meta context` — one sentence max, as few words as possible. Avoid characters that could break YAML
  - Check the imports block, if present. Only include imports of other project files in `::meta depends` — not libraries, built-ins, or generic utilities like `HttpClient`, loggers, or framework classes. This map exists to show how parts of the project's own code depend on each other, not what tools each file uses to do its job. If it's not project-authored code, it doesn't belong in `depends`
- Once every file in a directory has been processed, summarize their `::meta context` entries into that directory's own `::meta context`, again as briefly as possible
- Skip self-describing nodes (e.g. `package.json`, `gradle.properties`) — leave them unprocessed

## Execution
1. Before starting, draft a plan and split the work into batches
2. Spawn as many subagents as available, giving each precise, self-contained instructions so they can work independently on their batch
3. Once all batches are complete, do a final review pass. The file should stay brief — this is a design requirement, not a suggestion
4. Finally run the `bash ${CLAUDE_PLUGIN_ROOT}/hooks/add-dependents.sh`, so routes.yaml became a bidirectional dependencies graph.
