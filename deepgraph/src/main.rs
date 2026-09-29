mod blocks;
mod facts;
mod graph;
mod header;
mod lang;
mod model;
mod notes;
mod search;
mod time_fmt;
mod tsutil;
mod walk;

use std::io::{Read, Write};
use std::path::{Path, PathBuf};

use clap::{Parser as ClapParser, Subcommand};
use globset::{Glob, GlobSet, GlobSetBuilder};
use serde::Serialize;

use model::{CtxStore, Graph, Node};

/// Build a bidirectional import/export dependency graph for a Java,
/// Python, JavaScript, TypeScript, or Markdown codebase.
#[derive(ClapParser, Debug)]
#[command(name = "deepgraph", version, about)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand, Debug)]
enum Command {
    /// Scan a directory and write `<output>/graph.json` -- a pure
    /// function of the source tree, always safe to regenerate wholesale.
    /// With `--notes`, also tidies the notes file: drops notes of files
    /// that no longer exist and resolves duplicate lines (left by a union
    /// merge). With `--headers`, then brings every file's `@sourcemap`
    /// block up to date (see `headers`).
    Build {
        /// Directory to scan.
        dir: PathBuf,

        /// Output directory for `graph.json` (created if it doesn't exist).
        output: PathBuf,

        /// The notes file (JSON Lines, e.g. `<dir>/.qwen/sourcemap/notes.jsonl`).
        #[arg(long)]
        notes: Option<PathBuf>,

        /// Also write/update each file's `@sourcemap` block. Only safe
        /// with the git clean filter installed (see `clean`), or the
        /// blocks end up in commits.
        #[arg(long)]
        headers: bool,

        /// Emit compact JSON instead of pretty-printed.
        #[arg(long)]
        compact: bool,

        /// Keep `external_dependencies` (npm/stdlib/JDK packages etc.)
        /// on every node. Off by default.
        #[arg(long)]
        with_external: bool,

        /// Keep barrel files (pure re-export files, e.g. an `index.ts`
        /// that only does `export * from './x'`) as nodes, along with
        /// `is_barrel`/`effective_dependencies`/`effective_dependents`.
        /// Off by default: barrels are dropped and every remaining
        /// node's `dependencies`/`dependents` skip straight through to
        /// the real files that used to sit behind them.
        #[arg(long)]
        with_barrels: bool,

        /// Exclude files/directories matching this gitignore-style glob
        /// (relative to `dir`), e.g. `--exclude '**/*.test.ts'` or
        /// `--exclude 'legacy/**'`. Repeatable.
        #[arg(long = "exclude")]
        excludes: Vec<String>,
    },

    /// Print `path<TAB>hash` for every file in `<output>/graph.json` that
    /// has no note, or whose note was written for other content.
    Pending {
        /// The same output directory given to `build`.
        output: PathBuf,

        /// The notes file.
        #[arg(long)]
        notes: PathBuf,
    },

    /// Add or replace notes from a JSON array of `{"path","hash","ctx"}`
    /// on stdin (`hash`: the file's hash from `graph.json` that `ctx` was
    /// written for). Entries with an empty path or ctx are ignored.
    SetNotes {
        /// The notes file (created, with its `.gitattributes`, if missing).
        #[arg(long)]
        notes: PathBuf,
    },

    /// Bring the `@sourcemap` block at the end of each file up to date
    /// with its note and dependents (from `<output>/graph.json`). Only
    /// touches files whose block changes, and skips files edited since
    /// the last `build`.
    Headers {
        /// The scanned directory.
        dir: PathBuf,

        /// The same output directory given to `build`.
        output: PathBuf,

        /// The notes file.
        #[arg(long)]
        notes: PathBuf,

        /// Only these files (paths as in `graph.json`); all when omitted.
        files: Vec<String>,
    },

    /// Git clean filter: copy stdin to stdout without its `@sourcemap`
    /// block. Configure as `git config filter.<name>.clean 'deepgraph clean %f'`.
    Clean {
        /// The file's path (only its extension is used).
        path: PathBuf,
    },

    /// Remove the `@sourcemap` block from every supported file under `dir`.
    Strip {
        dir: PathBuf,
    },

    /// Import notes from an older `ctx.json` (`{path: {ctx, ctx_hash}}`),
    /// keeping only those still fresh for the file's current content.
    /// Existing notes win.
    ImportCtx {
        /// The directory `ctx.json`'s paths are relative to.
        dir: PathBuf,

        /// The old `ctx.json`.
        ctx_json: PathBuf,

        /// The notes file.
        #[arg(long)]
        notes: PathBuf,
    },

    /// Print one file's node from `<output>/graph.json`, merged with its
    /// note if one exists. `file` can be the full relative path or just a
    /// unique trailing suffix of it (e.g. `Button.tsx` or
    /// `components/Button.tsx`).
    Show {
        /// The same output directory given to `build`.
        output: PathBuf,

        /// Full relative path, or a unique trailing suffix of it.
        file: String,

        /// The notes file.
        #[arg(long)]
        notes: Option<PathBuf>,

        /// Emit compact JSON instead of pretty-printed.
        #[arg(long)]
        compact: bool,
    },

    /// Search every file's path, exported names, and note (if it has
    /// one) for `query`: a fast fuzzy text match (substrings and
    /// typo-tolerant word matching).
    Search {
        /// The same output directory given to `build`.
        output: PathBuf,

        /// What to search for.
        query: String,

        /// The notes file.
        #[arg(long)]
        notes: Option<PathBuf>,

        /// Max results to print.
        #[arg(long, default_value_t = 10)]
        limit: usize,

        /// Emit compact JSON instead of pretty-printed.
        #[arg(long)]
        compact: bool,
    },
}

#[derive(Serialize)]
struct ShowOutput<'a> {
    path: &'a str,
    #[serde(flatten)]
    node: &'a Node,
    ctx: String,
    ctx_stale: bool,
}

fn graph_path(output: &Path) -> PathBuf {
    output.join("graph.json")
}

fn load_graph(output: &Path) -> anyhow::Result<Graph> {
    let path = graph_path(output);
    let json = std::fs::read_to_string(&path).map_err(|e| anyhow::anyhow!("cannot read {:?}: {e}", path))?;
    Ok(serde_json::from_str(&json)?)
}

/// The notes file, one note per path (duplicates resolved against the graph's current hashes).
fn load_notes(path: &Path, graph: &Graph) -> notes::Notes {
    notes::resolve(notes::load(path), |p| graph.nodes.get(p).map(|n| n.hash.clone()))
}

fn canonical_root(dir: &Path) -> anyhow::Result<PathBuf> {
    dir.canonicalize().map_err(|e| anyhow::anyhow!("cannot access directory {:?}: {e}", dir))
}

fn build_excludes(patterns: &[String]) -> anyhow::Result<GlobSet> {
    let mut builder = GlobSetBuilder::new();
    for p in patterns {
        builder.add(Glob::new(p).map_err(|e| anyhow::anyhow!("invalid --exclude pattern {p:?}: {e}"))?);
    }
    Ok(builder.build()?)
}

#[allow(clippy::too_many_arguments)]
fn run_build(
    dir: PathBuf,
    output: PathBuf,
    notes_path: Option<PathBuf>,
    headers: bool,
    compact: bool,
    with_external: bool,
    with_barrels: bool,
    excludes: &[String],
) -> anyhow::Result<()> {
    let root = canonical_root(&dir)?;

    let exclude_set = build_excludes(excludes)?;
    let files = walk::collect_source_files(&root, &exclude_set)?;
    eprintln!("deepgraph: scanning {} source file(s) under {}", files.len(), root.display());

    let opts = graph::GraphOptions {
        include_external: with_external,
        include_barrels: with_barrels,
    };
    let graph = graph::build_graph(&root, &files, &opts)?;

    std::fs::create_dir_all(&output)?;
    let graph_json = if compact {
        serde_json::to_string(&graph)?
    } else {
        serde_json::to_string_pretty(&graph)?
    };
    let path = graph_path(&output);
    let tmp = path.with_extension("json.tmp");
    std::fs::write(&tmp, graph_json)?;
    std::fs::rename(&tmp, &path)?;
    eprintln!("deepgraph: wrote {} node(s) to {}", graph.nodes.len(), path.display());

    let Some(notes_path) = notes_path else {
        return Ok(());
    };
    // Notes are only dropped once their file is gone from disk, not merely
    // out of the graph: a file this machine excludes may still be one a
    // teammate annotated.
    let mut notes = load_notes(&notes_path, &graph);
    notes.retain(|p, _| root.join(p).is_file());
    notes::save(&notes_path, &notes)?;
    let fresh = graph.nodes.iter().filter(|(p, n)| notes.get(*p).is_some_and(|x| x.hash == n.hash)).count();
    eprintln!("deepgraph: {} -- {fresh} of {} file(s) have a current note", notes_path.display(), graph.nodes.len());

    if headers {
        report_blocks(&blocks::write_headers(&root, &graph, &notes, None), "updated in")?;
    }
    Ok(())
}

/// Prints each rewritten file's path on stdout (callers refresh git's
/// index for them: a size change alone makes `git status` report a file
/// as modified, even when the clean filter makes its content identical),
/// and a summary on stderr.
fn report_blocks(stats: &blocks::Stats, verb: &str) -> anyhow::Result<()> {
    let mut out = std::io::stdout().lock();
    for path in &stats.written {
        writeln!(out, "{path}")?;
    }
    eprintln!("deepgraph: blocks {verb} {} file(s), {} skipped (changed since the build)", stats.written.len(), stats.skipped);
    Ok(())
}

fn run_pending(output: PathBuf, notes_path: PathBuf) -> anyhow::Result<()> {
    let graph = load_graph(&output)?;
    let notes = load_notes(&notes_path, &graph);
    let mut out = std::io::stdout().lock();
    for (path, node) in &graph.nodes {
        if notes.get(path).map(|n| n.hash != node.hash).unwrap_or(true) {
            writeln!(out, "{path}\t{}", node.hash)?;
        }
    }
    Ok(())
}

fn run_set_notes(notes_path: PathBuf) -> anyhow::Result<()> {
    let mut input = String::new();
    std::io::stdin().read_to_string(&mut input)?;
    let updates: Vec<notes::Note> = serde_json::from_str(&input)?;
    let mut all: Vec<notes::Note> = notes::load(&notes_path);
    all.extend(updates.into_iter().filter(|n| !n.path.is_empty() && !n.ctx.is_empty()));
    // Later lines win among duplicates, so the updates replace older notes
    let merged = notes::resolve(all, |_| None);
    notes::save(&notes_path, &merged)?;
    Ok(())
}

fn run_headers(dir: PathBuf, output: PathBuf, notes_path: PathBuf, files: Vec<String>) -> anyhow::Result<()> {
    let root = canonical_root(&dir)?;
    let graph = load_graph(&output)?;
    let notes = load_notes(&notes_path, &graph);
    let only = (!files.is_empty()).then_some(files.as_slice());
    report_blocks(&blocks::write_headers(&root, &graph, &notes, only), "updated in")
}

fn run_clean(path: PathBuf) -> anyhow::Result<()> {
    let mut input = Vec::new();
    std::io::stdin().read_to_end(&mut input)?;
    let mut out = std::io::stdout().lock();
    out.write_all(&blocks::clean(&path, input))?;
    out.flush()?;
    Ok(())
}

fn run_strip(dir: PathBuf) -> anyhow::Result<()> {
    let root = canonical_root(&dir)?;
    report_blocks(&blocks::strip_tree(&root)?, "removed from")
}

fn run_import_ctx(dir: PathBuf, ctx_json: PathBuf, notes_path: PathBuf) -> anyhow::Result<()> {
    let root = canonical_root(&dir)?;
    let json = std::fs::read_to_string(&ctx_json).map_err(|e| anyhow::anyhow!("cannot read {:?}: {e}", ctx_json))?;
    let old: CtxStore = serde_json::from_str(&json)?;
    let mut notes = notes::resolve(notes::load(&notes_path), |_| None);
    let mut imported = 0;
    for (path, entry) in old {
        if entry.ctx.is_empty() || notes.contains_key(&path) {
            continue;
        }
        let abs = root.join(&path);
        let (Some(lang), Ok(content)) = (walk::detect_lang(&abs), std::fs::read_to_string(&abs)) else {
            continue;
        };
        let stripped = header::strip(&content, lang);
        // Old notes were keyed to the old hash of the raw content: only a
        // note still matching it describes the file as it is now
        if header::legacy_hash(stripped.as_bytes()) != entry.ctx_hash {
            continue;
        }
        let hash = header::content_hash(&stripped);
        notes.insert(path.clone(), notes::Note { path, hash, ctx: entry.ctx });
        imported += 1;
    }
    notes::save(&notes_path, &notes)?;
    eprintln!("deepgraph: imported {imported} current note(s) into {}", notes_path.display());
    Ok(())
}

fn run_show(output: PathBuf, file: String, notes_path: Option<PathBuf>, compact: bool) -> anyhow::Result<()> {
    let graph = load_graph(&output)?;
    let ctx_store = notes_path.map(|p| notes::to_ctx_store(&load_notes(&p, &graph))).unwrap_or_default();

    let query_parts: Vec<&str> = file.trim_matches('/').split('/').collect();
    let matches: Vec<&String> = graph
        .nodes
        .keys()
        .filter(|k| {
            if k.as_str() == file {
                return true;
            }
            let key_parts: Vec<&str> = k.split('/').collect();
            key_parts.len() >= query_parts.len()
                && key_parts[key_parts.len() - query_parts.len()..] == query_parts[..]
        })
        .collect();

    let path = match matches.len() {
        0 => anyhow::bail!("no file in {:?} matches {:?}", graph_path(&output), file),
        1 => matches[0].clone(),
        _ => {
            let exact = graph.nodes.keys().find(|k| k.as_str() == file);
            if let Some(p) = exact {
                p.clone()
            } else {
                let mut list = matches.iter().map(|s| s.as_str()).collect::<Vec<_>>();
                list.sort();
                anyhow::bail!(
                    "{:?} matches {} files, be more specific:\n  {}",
                    file,
                    list.len(),
                    list.join("\n  ")
                );
            }
        }
    };

    let node = &graph.nodes[&path];
    let (ctx, ctx_stale) = match ctx_store.get(&path) {
        Some(entry) => (entry.ctx.clone(), entry.ctx_hash != node.hash),
        None => (String::new(), false),
    };

    let out = ShowOutput {
        path: &path,
        node,
        ctx,
        ctx_stale,
    };

    let json = if compact {
        serde_json::to_string(&out)?
    } else {
        serde_json::to_string_pretty(&out)?
    };
    println!("{json}");

    Ok(())
}

#[derive(Serialize)]
struct SearchHitOutput {
    path: String,
    score: f64,
    ctx: String,
}

fn print_search_hits(hits: Vec<search::SearchHit>, compact: bool) -> anyhow::Result<()> {
    let out: Vec<SearchHitOutput> = hits
        .into_iter()
        .map(|h| SearchHitOutput { path: h.path, score: h.score, ctx: h.ctx })
        .collect();
    let json = if compact {
        serde_json::to_string(&out)?
    } else {
        serde_json::to_string_pretty(&out)?
    };
    println!("{json}");
    Ok(())
}

fn run_search(
    output: PathBuf,
    query: String,
    notes_path: Option<PathBuf>,
    limit: usize,
    compact: bool,
) -> anyhow::Result<()> {
    let ctx_store = match (&notes_path, load_graph(&output)) {
        (Some(p), Ok(graph)) => notes::to_ctx_store(&load_notes(p, &graph)),
        (Some(p), Err(_)) => notes::to_ctx_store(&notes::resolve(notes::load(p), |_| None)),
        (None, _) => CtxStore::new(),
    };
    let docs = search::load_search_docs(&graph_path(&output), &ctx_store);
    if docs.is_empty() {
        eprintln!(
            "deepgraph: {:?} has no files yet -- run `deepgraph build` first",
            output
        );
    }

    let hits = search::fuzzy_search(&docs, &query, limit);
    print_search_hits(hits, compact)
}

fn main() -> anyhow::Result<()> {
    let cli = Cli::parse();
    match cli.command {
        Command::Build {
            dir,
            output,
            notes,
            headers,
            compact,
            with_external,
            with_barrels,
            excludes,
        } => run_build(dir, output, notes, headers, compact, with_external, with_barrels, &excludes),
        Command::Pending { output, notes } => run_pending(output, notes),
        Command::SetNotes { notes } => run_set_notes(notes),
        Command::Headers { dir, output, notes, files } => run_headers(dir, output, notes, files),
        Command::Clean { path } => run_clean(path),
        Command::Strip { dir } => run_strip(dir),
        Command::ImportCtx { dir, ctx_json, notes } => run_import_ctx(dir, ctx_json, notes),
        Command::Show { output, file, notes, compact } => run_show(output, file, notes, compact),
        Command::Search { output, query, notes, limit, compact } => run_search(output, query, notes, limit, compact),
    }
}
