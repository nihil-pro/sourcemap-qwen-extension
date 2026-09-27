mod facts;
mod graph;
mod lang;
mod model;
mod search;
#[cfg(feature = "embeddings-core")]
mod search_semantic;
mod time_fmt;
mod tsutil;
mod walk;

use std::path::{Path, PathBuf};

use clap::{Parser as ClapParser, Subcommand};
use globset::{Glob, GlobSet, GlobSetBuilder};
use serde::Serialize;

use model::{CtxEntry, CtxStore, Graph, Node};

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
    /// Also syncs `<output>/ctx.json`'s file list to match: adds an
    /// empty note for new files, drops entries for files that are gone,
    /// and never touches an existing note's `ctx`/`ctx_hash`.
    Build {
        /// Directory to scan.
        dir: PathBuf,

        /// Output directory. `build` writes `graph.json` and `ctx.json`
        /// here (created if it doesn't exist).
        output: PathBuf,

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

    /// Print one file's node from `<output>/graph.json`, merged with its
    /// note from `<output>/ctx.json` if one exists. `file` can be the
    /// full relative path or just a unique trailing suffix of it (e.g.
    /// `Button.tsx` or `components/Button.tsx`).
    Show {
        /// The same output directory given to `build`.
        output: PathBuf,

        /// Full relative path, or a unique trailing suffix of it.
        file: String,

        /// Emit compact JSON instead of pretty-printed.
        #[arg(long)]
        compact: bool,
    },

    /// Search every file's path, exported names, and `ctx.json` note (if
    /// it has one) for `query`. Default is a fast fuzzy text match
    /// (substrings and typo-tolerant word matching); pass `--semantic`
    /// (only available in builds compiled with the `embeddings` or
    /// `embeddings-local-runtime` feature) for meaning-based search
    /// instead of keyword matching. Semantic search caches each file's
    /// embedding in `<output>/vectors.json`, so only new or changed
    /// files are embedded again.
    Search {
        /// The same output directory given to `build`.
        output: PathBuf,

        /// What to search for.
        query: String,

        /// Max results to print.
        #[arg(long, default_value_t = 10)]
        limit: usize,

        /// Emit compact JSON instead of pretty-printed.
        #[arg(long)]
        compact: bool,

        /// Use embedding-based semantic search instead of fuzzy text
        /// matching. Requires a binary built with `--features embeddings`
        /// or `--features embeddings-local-runtime`.
        #[cfg(feature = "embeddings-core")]
        #[arg(long)]
        semantic: bool,

        /// Load the embedding model straight from this local directory
        /// instead of downloading it from Hugging Face Hub -- for
        /// offline use, or when that isn't reachable. Needs
        /// `model.onnx` (or `onnx/model.onnx`), `tokenizer.json`,
        /// `config.json`, `special_tokens_map.json`, and
        /// `tokenizer_config.json` (an all-MiniLM-L6-v2 ONNX export,
        /// e.g. Xenova/all-MiniLM-L6-v2 on Hugging Face, downloaded
        /// ahead of time). Only used with `--semantic`; without this,
        /// the model is downloaded once and cached (see
        /// `FASTEMBED_CACHE_DIR`).
        #[cfg(feature = "embeddings-core")]
        #[arg(long)]
        model_dir: Option<PathBuf>,

        /// Pooling strategy for turning `--model-dir`'s token embeddings
        /// into one sentence embedding. `mean` is correct for the large
        /// majority of sentence-transformers models (every MiniLM
        /// variant, E5, paraphrase-*); a handful of others (BGE, mxbai)
        /// need `cls` instead -- check the model card if results seem
        /// off. Only used with `--model-dir`; ignored for the default
        /// downloaded model, which already knows its own strategy.
        #[cfg(feature = "embeddings-core")]
        #[arg(long, value_enum, default_value = "mean")]
        pooling: search_semantic::PoolingArg,

        /// Load the ONNX Runtime engine itself from this local library
        /// file (`libonnxruntime.so`/`.dylib`/`.dll`) instead of the
        /// prebuilt binary `ort` would otherwise download -- for
        /// private networks that can't reach `ort`'s download source.
        /// Only available in builds compiled with
        /// `--features embeddings-local-runtime` (which also disables
        /// that download at build time). `ORT_DYLIB_PATH` works too, as
        /// a fallback, if you'd rather set it once in the environment.
        #[cfg(feature = "embeddings-local-runtime")]
        #[arg(long)]
        onnx_runtime: Option<PathBuf>,
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

/// `<output>` is a directory: `build` writes `graph.json` (and, once
/// annotated, `ctx.json`) inside it.
fn output_paths(dir: &Path) -> (PathBuf, PathBuf) {
    (dir.join("graph.json"), dir.join("ctx.json"))
}

fn build_excludes(patterns: &[String]) -> anyhow::Result<GlobSet> {
    let mut builder = GlobSetBuilder::new();
    for p in patterns {
        builder.add(Glob::new(p).map_err(|e| anyhow::anyhow!("invalid --exclude pattern {p:?}: {e}"))?);
    }
    Ok(builder.build()?)
}

fn run_build(
    dir: PathBuf,
    output: PathBuf,
    compact: bool,
    with_external: bool,
    with_barrels: bool,
    excludes: &[String],
) -> anyhow::Result<()> {
    let root = dir
        .canonicalize()
        .map_err(|e| anyhow::anyhow!("cannot access directory {:?}: {e}", dir))?;

    let exclude_set = build_excludes(excludes)?;
    let files = walk::collect_source_files(&root, &exclude_set)?;
    eprintln!("deepgraph: scanning {} source file(s) under {}", files.len(), root.display());

    let opts = graph::GraphOptions {
        include_external: with_external,
        include_barrels: with_barrels,
    };
    let graph = graph::build_graph(&root, &files, &opts)?;

    let (graph_path, ctx_path) = output_paths(&output);
    std::fs::create_dir_all(&output)?;

    let graph_json = if compact {
        serde_json::to_string(&graph)?
    } else {
        serde_json::to_string_pretty(&graph)?
    };
    std::fs::write(&graph_path, graph_json)?;

    let existing_ctx = load_ctx_store(&ctx_path);
    let (ctx_store, added, removed) = reconcile_ctx_store(existing_ctx, &graph);
    let ctx_json = if compact {
        serde_json::to_string(&ctx_store)?
    } else {
        serde_json::to_string_pretty(&ctx_store)?
    };
    std::fs::write(&ctx_path, ctx_json)?;

    let needing_annotation = ctx_store.values().filter(|e| e.ctx.is_empty()).count();
    eprintln!("deepgraph: wrote {} node(s) to {}", graph.nodes.len(), graph_path.display());
    eprintln!(
        "deepgraph: {} -- {added} new, {removed} removed, {needing_annotation} of {} need a note",
        ctx_path.display(),
        ctx_store.len()
    );

    Ok(())
}

/// Keeps `ctx.json`'s key set in sync with the current `graph.json`,
/// without ever touching an existing note's `ctx`/`ctx_hash`: files new
/// to the graph get an empty stub (a to-do marker for whoever/whatever
/// annotates), and files no longer in the graph are dropped.
fn reconcile_ctx_store(existing: CtxStore, graph: &Graph) -> (CtxStore, usize, usize) {
    let removed = existing.keys().filter(|k| !graph.nodes.contains_key(*k)).count();
    let mut added = 0;
    let mut reconciled = CtxStore::new();
    for path in graph.nodes.keys() {
        match existing.get(path) {
            Some(entry) => {
                reconciled.insert(path.clone(), entry.clone());
            }
            None => {
                reconciled.insert(
                    path.clone(),
                    CtxEntry { ctx: String::new(), ctx_hash: String::new() },
                );
                added += 1;
            }
        }
    }
    (reconciled, added, removed)
}

fn run_show(output: PathBuf, file: String, compact: bool) -> anyhow::Result<()> {
    let (graph_path, ctx_path) = output_paths(&output);

    let graph_json = std::fs::read_to_string(&graph_path)
        .map_err(|e| anyhow::anyhow!("cannot read {:?}: {e}", graph_path))?;
    let graph: Graph = serde_json::from_str(&graph_json)?;

    let ctx_store: CtxStore = std::fs::read_to_string(&ctx_path)
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default();

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
        0 => anyhow::bail!("no file in {:?} matches {:?}", graph_path, file),
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
        // An empty ctx (an unfilled stub `build` seeded) is never
        // "stale" -- there's no note yet to be out of date.
        Some(entry) => (entry.ctx.clone(), !entry.ctx.is_empty() && entry.ctx_hash != node.hash),
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

fn load_ctx_store(ctx_path: &Path) -> CtxStore {
    std::fs::read_to_string(ctx_path)
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default()
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

#[allow(unused_variables)]
fn run_search(
    output: PathBuf,
    query: String,
    limit: usize,
    compact: bool,
    #[cfg(feature = "embeddings-core")] semantic: bool,
    #[cfg(feature = "embeddings-core")] model_dir: Option<PathBuf>,
    #[cfg(feature = "embeddings-core")] pooling: search_semantic::PoolingArg,
    #[cfg(feature = "embeddings-local-runtime")] onnx_runtime: Option<PathBuf>,
) -> anyhow::Result<()> {
    let (graph_path, ctx_path) = output_paths(&output);
    let ctx_store = load_ctx_store(&ctx_path);
    let docs = search::load_search_docs(&graph_path, &ctx_store);
    if docs.is_empty() {
        eprintln!(
            "deepgraph: {:?} has no files yet -- run `deepgraph build` first",
            output
        );
    }

    #[cfg(feature = "embeddings-core")]
    if semantic {
        #[cfg(feature = "embeddings-local-runtime")]
        if let Some(path) = onnx_runtime {
            search_semantic::init_local_onnx_runtime(&path)?;
        }
        let hits = search_semantic::semantic_search(
            &docs,
            &query,
            limit,
            model_dir,
            pooling,
            &output.join("vectors.json"),
        )?;
        return print_search_hits(hits, compact);
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
            compact,
            with_external,
            with_barrels,
            excludes,
        } => run_build(dir, output, compact, with_external, with_barrels, &excludes),
        Command::Show { output, file, compact } => run_show(output, file, compact),
        Command::Search {
            output,
            query,
            limit,
            compact,
            #[cfg(feature = "embeddings-core")]
            semantic,
            #[cfg(feature = "embeddings-core")]
            model_dir,
            #[cfg(feature = "embeddings-core")]
            pooling,
            #[cfg(feature = "embeddings-local-runtime")]
            onnx_runtime,
        } => run_search(
            output,
            query,
            limit,
            compact,
            #[cfg(feature = "embeddings-core")]
            semantic,
            #[cfg(feature = "embeddings-core")]
            model_dir,
            #[cfg(feature = "embeddings-core")]
            pooling,
            #[cfg(feature = "embeddings-local-runtime")]
            onnx_runtime,
        ),
    }
}
