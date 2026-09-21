For each FILE listed below: reconstruct its path from the project root, read its content, then produce:
- `context` — one sentence, as few words as possible, on **what** the code does, not how. Avoid characters that could break YAML (colons, quotes). Never leave this empty, even for a trivial or near-empty file — give the shortest true description you can (e.g. "Empty barrel re-exporting the module's public API")
- `depends` — other PROJECT-authored files it imports, as paths relative to the project root. Never libraries, built-ins, or generic framework/utility classes (`HttpClient`, loggers, etc.) — only this project's own code

For each DIRECTORY listed below: read `.qwen/sourcemap/routes.yaml` to see its children's `context` values (already filled in by an earlier pass), then summarize them into the directory's own one-sentence `context`, as briefly as possible. Directories have no `depends` — give an empty array

Call `structured_output` exactly once with one entry per node listed below — never more, never fewer, and nothing outside this list. You have read-only tools and no file-editing or shell tools of any kind.