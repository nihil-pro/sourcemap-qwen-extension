# sourcemap
A qwen-code extension that maintains a bidirectional dependency graph of the project's files and provides a sourcemap-scout subagent that finds the files relevant to a given task. 
Each file it finds includes a list of its dependents, which helps the main agent make fewer mistakes: it never forgets to check whether changes to one file break others, and, most importantly, 
it spends its budget thinking about the task rather than about where the related files are and how to find them.

This extension is based mostly on static analysis, rather than on LLM judgment, that's why it Requires Rust. 
It comes with vendored [deepgraph](deepgraph/README.md) that will be built in the background on the first session start after install.

LLM annotation is an opt-in feature, that writes a one-sentence note per file in the background, using your qwen quota, and makes the search for relevant files even more accurate.

## Settings
Asked at install time, and may be changed later with `qwen extensions settings set sourcemap <setting>`:
- ONNX Runtime: Absolute path to a local `libonnxruntime` (dylib/so), for offline semantic search via local embedding model. If omitted, `deepgraph` defaults to fuzzy search only.
- Embedding model directory: Absolute path to a local embedding model directory with model.onnx, tokenizer.json etc. The [MiniLM-L12-V2](https://huggingface.co/sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2/tree/main) is recommended.
- LLM annotation: Project files collected by `deepgraph` will be annotated in background based on their contents. Defaults to true.
- Exclude patterns: While `deepgraph` already respects .gitignore, .agentignore and many others non-code related, such as `node_modules`, you can pass an additional comma-separated `gitignore-style` globs to leave out of the sourcemap
- OpenAI API logging: `true` passes `--openai-logging` to the extension's background qwen calls

## Search
Both fuzzy and semantic search match each file's path, exported names, and note (when it has one), so a file is findable even before it's annotated. 
Semantic search caches each file's embedding, and only re-embeds files whose path, exports or note changed. 
The scout agent runs semantic search when deepgraph was built with it and a model directory is set, and fuzzy search otherwise, including cases where semantic search fails.

## Letting the scout run without approval prompts
The scout calls deepgraph through `.qwen/sourcemap/deepgraph` with `run_shell_command`, which needs approval in the Ask Permissions and Auto-Edit modes. 
To auto-approve just that command, add to user or project`.qwen/settings.json`:
```json
{
  "permissions": {
    "allow": ["Bash(.qwen/sourcemap/deepgraph *)"]
  }
}
```

## Troubleshooting
Errors from every hook and background script go to project `.qwen/sourcemap/error.log`; deepgraph's full build output is in the extension's `bin/build.log`.
