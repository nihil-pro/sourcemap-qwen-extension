Read `.qwen/sourcemap/routes.yaml`. It represents the project tree. Every node carrying an empty `::meta` block needs to be filled in — files have `context` and `depends`, directories have `context` only. Nodes with no `::meta` block are self-describing or purely structural; skip them.

## Processing rules
- Process a directory's files before the directory itself.
- For each file: reconstruct its path from its position in the tree, read its content, then produce:
  - `context` — one sentence, as few words as possible, on **what** the code does, not how. Avoid characters that could break YAML (colons, quotes)
  - `depends` — other PROJECT-authored files it imports, as paths relative to the project root matching routes.yaml's own path format. Never libraries, built-ins, or generic framework/utility classes (`HttpClient`, loggers, etc.) — only this project's own code
- For each directory, once every child is processed: summarize their `context` entries into the directory's own one-sentence `context`. Directories have no `depends` — give an empty array
- Skip self-describing nodes (`package.json`, `gradle.properties`, anything with no `::meta` block)

## Execution
1. Draft a plan and split the tree into batches
2. Spawn as many subagents as available, each with precise, self-contained instructions to read and summarize its batch and report findings back to you as plain text. Subagents only read — they have no file-editing or shell tools, and neither do you
3. Once every batch reports back, do a final brief pass for consistency — the map should stay brief, that's a design requirement, not a suggestion
4. Call `structured_output` exactly once with one entry per node you processed (files and directories alike), then stop
