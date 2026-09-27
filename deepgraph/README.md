# deepgraph

A CLI that scans a Java/Python/JavaScript/TypeScript/Markdown codebase
and builds a bidirectional dependency graph — for each file, what it
imports (or, for `.md`, links to) and what imports/links to it — plus a
place to attach short human- or LLM-written notes on what each file
does, and a way to search those notes.

Static analysis only: nothing is executed, so it's safe to point at any
codebase.

## Quick start

```sh
cargo build --release
alias deepgraph=./target/release/deepgraph   # or copy it onto your PATH

deepgraph build ./my-project ./deepgraph      # scan -> ./deepgraph/graph.json
deepgraph show ./deepgraph src/lib/index.ts   # look up one file
deepgraph search ./deepgraph "session token refresh"  # search your notes
```

Everything lives under `<output-dir>` (here, `./deepgraph`) — a directory
`build` creates, holding two files:

- **`graph.json`** — the dependency graph. Fully rewritten every time
  you run `build`; just re-run it after the code changes.
- **`ctx.json`** — your notes on what files do. `build` seeds this with
  an empty entry per file (see [Annotating files](#annotating-files))
  but never writes the notes themselves — you (or an LLM) do.

## `deepgraph build <dir> <output-dir>`

Scans `<dir>` and writes `<output-dir>/graph.json`. Also keeps
`<output-dir>/ctx.json`'s set of files in sync with the scan: files new
to the graph get an empty note (a to-do marker), files no longer in the
graph have their entry removed, and every existing note is left exactly
as it was — `build` never reads or writes the `ctx`/`ctx_hash` of an
entry that already exists.

Flags:

| Flag | Effect |
|---|---|
| `--compact` | Compact JSON instead of pretty-printed. |
| `--with-external` | Also list each file's external dependencies (npm/stdlib/JDK packages). Off by default. |
| `--with-barrels` | Keep barrel files (e.g. an `index.ts` that just re-exports other files) as their own nodes. Off by default — see [below](#barrel-files). |
| `--exclude <glob>` | Skip files/directories matching this gitignore-style glob, relative to `<dir>`. Repeatable: `--exclude '**/*.test.ts' --exclude 'legacy/**'`. |

By default (no `--with-*` flags), you get the graph of "files with real
code and how they actually connect" — third-party packages and pure
re-export files are left out, and edges skip straight through the
latter. Pass both flags for the full picture.

### What gets scanned

Extensions: `.java`, `.py`/`.pyi`, `.js`/`.jsx`/`.mjs`/`.cjs`,
`.ts`/`.mts`/`.cts`/`.tsx`, `.md`/`.markdown`.

Markdown is handled differently from the code languages: there's no
import/export concept, so a `.md` file's only "dependency" is a link to
another `.md` file (`[text](./other.md)`, reference-style
`[text][ref]`/`[ref]`, or `[ref]: ./other.md`). Links with a `#anchor`
resolve to the target file with the anchor dropped; external URLs,
images, and links to anything other than a `.md` file are ignored
entirely (not even listed as external).

`.gitignore` is respected, and these directories are always skipped:
`node_modules`, `dist`, `build`, `out`, `target`, `.next`, `.nuxt`,
`__pycache__`, `.venv`, `venv`, `env`, `.mypy_cache`, `.pytest_cache`,
`.tox`, `coverage`, `vendor`, `.idea`, `.vscode`, `.gradle`,
`.settings`, `.git`. Add more with `--exclude`.

### `graph.json`

```jsonc
{
  "root": "/abs/path/to/scanned/dir",
  "generated_at": "2026-09-23T17:41:57Z",
  "nodes": {
    "src/lib/impl.ts": {
      "hash": "e9ff2d870f7e925e",       // content hash, for change detection
      "exports": ["helper", "Thing"],  // best-effort list of exported names
      "dependencies": ["src/util.ts"], // files this one imports
      "dependents": ["src/main.ts"]    // files that import this one
    }
  }
}
```

All paths are relative to `root`. An edge means "this file imports
something from that file" — it's file-level, not "this exact name is
guaranteed to exist there."

With `--with-barrels`, three more fields appear per node:
`is_barrel` (true if the file only re-exports other files), and
`effective_dependencies`/`effective_dependents` (the same edges, but
walked through any barrels to the real files behind them — this is
what `dependencies`/`dependents` already are by default, once barrels
are removed). With `--with-external`, `external_dependencies` lists
whatever didn't resolve to a file in the scan (npm packages, stdlib,
JDK classes, etc).

#### Barrel files

A "barrel" is a file that exists only to re-export other files, e.g. a
JS/TS `index.ts` doing `export * from './foo'; export * from './baz'`,
or a Python `__init__.py` doing `from .impl import Thing`. By default
these don't appear as nodes at all: if `b.ts` does
`import { foo } from './a'` where `a/index.ts` is a barrel re-exporting
`foo` from `a/foo.ts`, `b.ts`'s `dependencies` shows `a/foo.ts`
directly — no `index.ts` in the output. This is resolved per imported
name for JS/TS, so two files importing different names through the
same barrel each depend only on their own real source file, not on
everything the barrel re-exports.

## `deepgraph show <output-dir> <file>`

Prints one file's node from `graph.json`, merged with its note from
`ctx.json` if it has one — without loading the whole graph.

`<file>` can be the full relative path, or just a unique trailing
suffix of it:

```sh
deepgraph show ./deepgraph Button.tsx
deepgraph show ./deepgraph components/Button.tsx
```

If that suffix matches more than one file, `show` lists every match so
you can be more specific.

## Annotating files

`ctx.json` is a flat map of path → note. After `build`, every file has
an entry, empty until annotated:

```jsonc
{
  "src/lib/index.ts": {
    "ctx": "",
    "ctx_hash": ""
  }
}
```

Fill in `ctx` by hand, or point an LLM at each file (a cheap model is
fine — the notes are meant to be short: what the file *does*, not how)
and have it write `ctx` plus `ctx_hash` set to that file's current
`hash` from `graph.json`:

```jsonc
{
  "src/lib/index.ts": {
    "ctx": "Public barrel for the lib package.",
    "ctx_hash": "e9ff2d870f7e925e"
  }
}
```

An empty-`ctx` entry is a to-do marker (search still finds the file by
path and exports); you can find every file still needing a note with
`jq -r 'to_entries[] | select(.value.ctx == "") | .key' ctx.json`.

`deepgraph show` reports `ctx_stale: true` whenever a file's `hash` no
longer matches its `ctx_hash`, meaning the note might be out of date;
update `ctx` and `ctx_hash` together to clear it. Since staleness is
computed when you read it (not stored), annotating or re-annotating a
file is just one write to `ctx.json`, nothing else to keep in sync.

## `deepgraph search <output-dir> <query>`

Searches every file's path, exported names (from `graph.json`), and
note (from `ctx.json`, when it has one), so files are findable before
they're annotated, or without notes at all.

```sh
deepgraph search ./deepgraph "auth token refresh"
deepgraph search ./deepgraph "auth token refresh" --limit 5 --compact
```

By default this is fast fuzzy text matching: substrings score highest,
otherwise each query word is matched against its closest word in the
note, so typos and partial words still find things. No setup needed.

### Semantic search

Fuzzy search is keyword matching — it won't connect "auth token
refresh" to a note that says "renews the user's session" if they don't
share words. For that, add `--semantic`, which compares meaning instead
of keywords using a local embedding model. It needs a build with one of
two extra Cargo features (regular `cargo build --release` doesn't
include this, since it adds a fair amount of weight):

```sh
cargo build --release --features embeddings
deepgraph search ./deepgraph "auth token refresh" --semantic
```

The first `--semantic` run downloads a small model
(`all-MiniLM-L6-v2`) and caches it. If you're on a network that can't
reach Hugging Face Hub or GitHub (where the embedding runtime itself
comes from), see [Offline / private-network setup](#offline--private-network-setup)
below — there's a fully offline path.

`--limit` and `--compact` work the same as with fuzzy search.

Each file's embedding is cached in `<output-dir>/vectors.json`, keyed by
a hash of its search text: a query only embeds the query itself plus
files that are new or whose path, exports or note changed, and files
that are gone are dropped from the cache. The cache belongs to one
model -- a different `--model-dir` or `--pooling` discards it.

#### Offline / private-network setup

Two independent things normally come over the network here — the
embedding *engine* and the *model* — and each has its own offline
option:

```sh
# Build with the private-network feature instead of `embeddings`:
cargo build --release --features embeddings-local-runtime

# Then point both pieces at local files:
deepgraph search ./deepgraph "auth token refresh" --semantic \
  --onnx-runtime /path/to/libonnxruntime.so \
  --model-dir /path/to/model-directory
```

- **`--onnx-runtime <path>`** — a `libonnxruntime.so`/`.dylib`/`.dll`
  you already have (only works with the `embeddings-local-runtime`
  build above). `ORT_DYLIB_PATH` works too, if you'd rather set it once
  in the environment instead of passing the flag every time.
- **`--model-dir <path>`** — a directory with the model's files instead
  of downloading them: `model.onnx` (or `onnx/model.onnx`),
  `tokenizer.json`, `config.json`, `special_tokens_map.json`, and
  `tokenizer_config.json`. Works with *either* build. Get these from a
  model's Hugging Face page ahead of time, e.g.
  [Xenova/all-MiniLM-L6-v2](https://huggingface.co/Xenova/all-MiniLM-L6-v2)
  (English) or
  [sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2](https://huggingface.co/sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2)
  (multilingual notes). If the repo uses Git LFS, plain `git clone`
  leaves small pointer files, not the real weights — install `git-lfs`
  and run `git lfs pull` in the cloned directory first (tell-tale sign:
  `model.onnx` is a few hundred bytes instead of hundreds of
  megabytes).
- **`--pooling <mean|cls>`** (default `mean`) — only matters with
  `--model-dir`. Getting this wrong doesn't error, it just quietly
  produces bad search results. `mean` is correct for the models linked
  above and the overwhelming majority of similar models (every MiniLM
  variant, E5, `paraphrase-*`); pass `--pooling cls` only if a model's
  card specifically says it needs CLS pooling (e.g. BGE, mxbai-embed).

## Known limitations

- **JS/TS**: bare-specifier imports (`import x from 'a'`) resolve
  against workspace `package.json` files (monorepo packages) and
  `tsconfig.json`/`jsconfig.json` path aliases; anything else (`react`,
  `lodash`, etc.) is treated as external. `node_modules` is never
  resolved into or treated as internal, even indirectly through a path
  alias. Relative imports written with an emitted `.js` extension
  (common under `moduleResolution: bundler`/`nodenext`) correctly find
  the `.ts` source.
- **Python**: the scanned directory is assumed to be your project's
  import root (i.e. on `sys.path`) — point `deepgraph build` at `src/`,
  not its parent, if that's where imports actually resolve from.
  Stdlib and third-party imports are always external. Unlike JS/TS,
  re-exports through `__init__.py` aren't resolved per-name yet: two
  files importing different names re-exported by the same
  `__init__.py` will each show as depending on everything it
  re-exports, not just the name each one actually uses.
- **Java**: only types declared inside the scanned directory resolve
  internally; JDK/library imports (`java.util.List`, etc.) are always
  external. Nested/inner classes aren't indexed individually, only
  top-level types.
- **Markdown**: percent-encoded link destinations (`%20` for a space,
  etc.) aren't decoded before resolving against the filesystem, so a
  link to a path containing one won't resolve. Reference-style link
  labels are matched case-insensitively per CommonMark, but internal
  whitespace isn't normalized.
