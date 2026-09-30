# deepgraph

A CLI that scans a Java/Python/JavaScript/TypeScript/Markdown codebase
and builds a bidirectional dependency graph — for each file, what it
imports (or, for `.md`, links to) and what imports/links to it — plus
short human- or LLM-written notes on what each file does, which it can
write into the files themselves as a comment block at the end, so any
tool that greps or reads the code sees them.

Static analysis only: nothing is executed, so it's safe to point at any
codebase.

## Quick start

```sh
cargo build --release
alias deepgraph=./target/release/deepgraph   # or copy it onto your PATH

N=./my-project/.qwen/sourcemap/notes.jsonl
deepgraph build ./my-project ./state --notes $N   # scan -> ./state/graph.json
deepgraph pending ./state --notes $N              # files needing a note
deepgraph show ./state src/lib/index.ts --notes $N  # look up one file
```

Two places hold data:

- **`<output-dir>/graph.json`** — the dependency graph. Fully rewritten
  every time you run `build`; just re-run it after the code changes.
  Disposable, so keep it out of the project (or gitignore it).
- **the notes file** (`--notes`, e.g. `<project>/.qwen/sourcemap/notes.jsonl`)
  — what each file does. Written by you or an LLM (see
  [Notes](#notes)), meant to be committed so a team writes each note once.

## `deepgraph build <dir> <output-dir>`

Scans `<dir>` and writes `<output-dir>/graph.json`. With `--notes`,
also tidies the notes file: drops notes of files that no longer exist
on disk, and resolves duplicate lines (see [Notes](#notes)). With
`--headers`, then updates every file's [`@sourcemap` block](#sourcemap-blocks).

Flags:

| Flag | Effect |
|---|---|
| `--notes <file>` | The notes file to tidy (and to take notes from, with `--headers`). |
| `--headers` | Also write/update each file's `@sourcemap` block. Only with the git clean filter set up (see below), or the blocks get committed. Prints the rewritten files' paths on stdout. |
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
      "hash": "e9ff2d870f7e925e",       // content hash (FNV-1a, without the @sourcemap block, CRLF read as LF)
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

Prints one file's node from `graph.json`, merged with its note (with
`--notes`) if it has one.

`<file>` can be the full relative path, or just a unique trailing
suffix of it:

```sh
deepgraph show ./state Button.tsx --notes $N
deepgraph show ./state components/Button.tsx --notes $N
```

If that suffix matches more than one file, `show` lists every match so
you can be more specific. `ctx_stale: true` means the note was written
for other content.

## Notes

The notes file is [JSON Lines](https://jsonlines.org/), one note per
line, sorted by path:

```jsonc
{"path":"src/lib/index.ts","hash":"e9ff2d870f7e925e","ctx":"Public barrel for the lib package."}
```

`hash` is the file's `hash` from `graph.json` when `ctx` was written: a
note is current while it matches, and stale once the file changes. The
hash is stable across machines and Rust versions, so a teammate's note
for an unchanged file counts as current.

- `deepgraph pending <output-dir> --notes <file>` prints
  `path<TAB>hash` for every file without a current note.
- `deepgraph set-notes --notes <file>` adds or replaces notes from a
  JSON array of `{"path","hash","ctx"}` on stdin. A cheap model is fine
  for writing them: what the file *does*, not how.
- `deepgraph import-ctx <dir> <ctx.json> --notes <file>` imports notes
  from the `ctx.json` of earlier versions, keeping those still current.

Writing the notes file also writes a `.gitattributes` next to it that
merges it with git's built-in `union` driver: two branches adding or
changing notes never conflict, both sides' lines are kept, and the
next `build --notes` keeps the note matching the file's current hash.

## `@sourcemap` blocks

`deepgraph headers <dir> <output-dir> --notes <file> [files...]` (or
`build --headers`) appends a comment block to the end of each file with
its note, its exported names (at most 20) and its dependents (at most 10):

```ts
/* @sourcemap (generated; do not edit)
 * @ctx: Session token storage and refresh. Exports: TokenStore, refreshToken
 * @dependents: src/main.ts, src/app.ts
 * @end-sourcemap */
```

Python uses `#` lines and Markdown an HTML comment. A file with neither
a note, exports nor dependents gets no block. A note written for other content
is still shown as is (an edit rarely changes what a file does) until
it's re-annotated. The labels are `@`-prefixed so they
can be grepped for without matching code: `@ctx:.*token` lists one
description line per file. Only files whose block changes are
rewritten, a file edited since the last `build` is skipped, and a file
changed while being written is left alone. The block is at the end so
nothing position-sensitive at the top of a file (shebangs, encoding
lines, license headers, docblocks) is disturbed, and every line keeps
its number.

The blocks are meant to stay out of git, via a clean filter that strips
them whenever git reads a file:

```sh
git config filter.sourcemap.clean 'deepgraph clean %f'
git config filter.sourcemap.smudge cat    # required below applies to checkout too
git config filter.sourcemap.required true
printf '*.%s filter=sourcemap\n' java py pyi js jsx mjs cjs ts mts cts tsx md markdown >> .git/info/attributes
```

`deepgraph clean <path>` copies stdin to stdout without the block
(`path` only picks the comment syntax); `strip(block + content)`
restores the content byte for byte, so git sees no change at all.
After writing blocks, re-`git add` the files whose only change is the
block: git trusts the file size recorded in its index, so `git status`
lists them as modified until then (their staged content doesn't change).

`deepgraph strip <dir>` removes every block under `<dir>`.

## `deepgraph search <output-dir> <query>`

Searches every file's path, exported names (from `graph.json`), and
note (with `--notes`, when it has one), so files are findable before
they're annotated, or without notes at all.

```sh
deepgraph search ./deepgraph "auth token refresh"
deepgraph search ./deepgraph "auth token refresh" --limit 5 --compact
```

This is fast fuzzy text matching: substrings score highest,
otherwise each query word is matched against its closest word in the
note, so typos and partial words still find things. No setup needed.

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
