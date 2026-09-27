use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

use clap::ValueEnum;
use fastembed::{
    EmbeddingModel, InitOptions, InitOptionsUserDefined, Pooling, TextEmbedding, TokenizerFiles,
    UserDefinedEmbeddingModel,
};

use serde::{Deserialize, Serialize};

use crate::search::{SearchDoc, SearchHit};

/// fastembed's `Pooling` doesn't implement `clap::ValueEnum`, and (more
/// importantly) a "bring your own" model gets no pooling strategy
/// unless we set one explicitly -- fastembed silently falls back to CLS
/// pooling otherwise, which produces poor sentence embeddings for
/// mean-pooling models (most sentence-transformers models, including
/// every MiniLM variant). Default to `mean` since that covers the
/// models this flag exists for.
#[derive(Clone, Copy, Debug, ValueEnum)]
pub enum PoolingArg {
    Mean,
    Cls,
}

impl From<PoolingArg> for Pooling {
    fn from(p: PoolingArg) -> Self {
        match p {
            PoolingArg::Mean => Pooling::Mean,
            PoolingArg::Cls => Pooling::Cls,
        }
    }
}

/// `ort` panics (rather than returning a `Result`) when it can't load
/// the ONNX Runtime library, e.g. `--onnx-runtime`/`ORT_DYLIB_PATH`
/// unset and no `libonnxruntime` on the default library search path --
/// as an uncaught panic that would otherwise print a raw backtrace and
/// exit with code 101 instead of a normal CLI error. Runs `f` with a
/// suppressed panic hook and converts any panic into a clean `Result`.
fn catch_panic<T>(f: impl FnOnce() -> anyhow::Result<T>) -> anyhow::Result<T> {
    let previous_hook = std::panic::take_hook();
    std::panic::set_hook(Box::new(|_| {}));
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(f));
    std::panic::set_hook(previous_hook);

    match result {
        Ok(inner) => inner,
        Err(payload) => {
            let msg = payload
                .downcast_ref::<String>()
                .cloned()
                .or_else(|| payload.downcast_ref::<&str>().map(|s| s.to_string()))
                .unwrap_or_else(|| "no panic message".to_string());
            anyhow::bail!(
                "the ONNX Runtime failed to load or run: {msg}\n\
                 hint: pass --onnx-runtime <path to libonnxruntime.so/.dylib/.dll>, or set \
                 the ORT_DYLIB_PATH environment variable, to point at a real ONNX Runtime \
                 library (only relevant to --features embeddings-local-runtime builds)."
            )
        }
    }
}

fn cosine_similarity(a: &[f32], b: &[f32]) -> f32 {
    let dot: f32 = a.iter().zip(b).map(|(x, y)| x * y).sum();
    let na: f32 = a.iter().map(|x| x * x).sum::<f32>().sqrt();
    let nb: f32 = b.iter().map(|x| x * x).sum::<f32>().sqrt();
    if na == 0.0 || nb == 0.0 {
        0.0
    } else {
        dot / (na * nb)
    }
}

fn read_required(dir: &Path, name: &str) -> anyhow::Result<Vec<u8>> {
    // HF ONNX exports commonly nest the model itself under `onnx/`, so
    // check both `<dir>/<name>` and `<dir>/onnx/<name>`.
    for candidate in [dir.join(name), dir.join("onnx").join(name)] {
        if candidate.is_file() {
            return Ok(std::fs::read(&candidate)?);
        }
    }
    anyhow::bail!(
        "expected {name:?} in {dir:?} (or its onnx/ subdirectory) -- \
         a local model directory needs model.onnx, tokenizer.json, config.json, \
         special_tokens_map.json, and tokenizer_config.json"
    )
}

/// Points `ort` at a local ONNX Runtime library file instead of the
/// prebuilt binary it would otherwise download at build time -- for
/// private networks that can't reach `ort`'s download source. Only
/// meaningful in builds compiled with `embeddings-local-runtime`
/// (which builds `ort` with `load-dynamic` instead of
/// `download-binaries`); must be called before any model is loaded.
#[cfg(feature = "embeddings-local-runtime")]
pub fn init_local_onnx_runtime(path: &Path) -> anyhow::Result<()> {
    if !path.is_file() {
        anyhow::bail!("ONNX Runtime library not found at {path:?}");
    }
    catch_panic(|| {
        ort::init_from(path.to_string_lossy().to_string())
            .commit()
            .map_err(|e| anyhow::anyhow!("failed to load ONNX Runtime from {path:?}: {e}"))?;
        Ok(())
    })
}

/// Loads an embedding model straight from local files -- no network, no
/// HuggingFace Hub -- for environments where that isn't reachable (as
/// it wasn't in the one this tool was built in: the default download
/// path connects but the model download itself gets cut off).
fn load_local_model(dir: &Path, pooling: PoolingArg) -> anyhow::Result<TextEmbedding> {
    let onnx_file = read_required(dir, "model.onnx")?;
    let tokenizer_files = TokenizerFiles {
        tokenizer_file: read_required(dir, "tokenizer.json")?,
        config_file: read_required(dir, "config.json")?,
        special_tokens_map_file: read_required(dir, "special_tokens_map.json")?,
        tokenizer_config_file: read_required(dir, "tokenizer_config.json")?,
    };
    let mut model = UserDefinedEmbeddingModel::new(onnx_file, tokenizer_files);
    model.pooling = Some(pooling.into());
    TextEmbedding::try_new_from_user_defined(model, InitOptionsUserDefined::new())
}

/// On-disk cache of each file's embedding (`<output>/vectors.json`), so a
/// query only embeds the query itself plus whatever files are new or
/// whose search text changed since the last search -- re-embedding every
/// file on every query costs seconds per thousand files, minutes on a
/// large codebase. Tied to one model: a cache written with a different
/// model or pooling strategy is discarded wholesale, since vectors from
/// different models aren't comparable.
#[derive(Serialize, Deserialize, Default)]
struct VectorCache {
    model: String,
    vectors: BTreeMap<String, CachedVector>,
}

#[derive(Serialize, Deserialize)]
struct CachedVector {
    /// `text_key` of the search text this vector was computed from.
    key: String,
    v: Vec<f32>,
}

/// FNV-1a, 64-bit. Deliberately not `std`'s `DefaultHasher` (what
/// `graph.json`'s `hash` uses): that's only guaranteed stable within one
/// build, so a toolchain upgrade would silently invalidate every cached
/// vector. This is stable forever.
fn text_key(text: &str) -> String {
    let mut h: u64 = 0xcbf29ce484222325;
    for b in text.as_bytes() {
        h ^= u64::from(*b);
        h = h.wrapping_mul(0x100000001b3);
    }
    format!("{h:016x}")
}

fn model_id(model_dir: &Option<PathBuf>, pooling: PoolingArg) -> String {
    match model_dir {
        Some(dir) => {
            let dir = dir.canonicalize().unwrap_or_else(|_| dir.clone());
            format!("dir:{}:{pooling:?}", dir.display())
        }
        None => "AllMiniLML6V2".to_string(),
    }
}

fn load_cache(path: &Path, model: &str) -> VectorCache {
    std::fs::read_to_string(path)
        .ok()
        .and_then(|s| serde_json::from_str::<VectorCache>(&s).ok())
        .filter(|c| c.model == model)
        .unwrap_or_else(|| VectorCache { model: model.to_string(), vectors: BTreeMap::new() })
}

/// Written to a temp file and renamed into place, so two searches
/// running at once can't leave a half-written cache behind (the loser's
/// write is simply replaced; either version is complete and valid).
fn save_cache(path: &Path, cache: &VectorCache) -> anyhow::Result<()> {
    let tmp = path.with_extension(format!("json.tmp{}", std::process::id()));
    std::fs::write(&tmp, serde_json::to_string(cache)?)?;
    std::fs::rename(&tmp, path)?;
    Ok(())
}

pub fn semantic_search(
    docs: &[SearchDoc],
    query: &str,
    limit: usize,
    model_dir: Option<PathBuf>,
    pooling: PoolingArg,
    cache_path: &Path,
) -> anyhow::Result<Vec<SearchHit>> {
    catch_panic(|| {
        let model_name = model_id(&model_dir, pooling);
        let mut cache = load_cache(cache_path, &model_name);

        let keys: Vec<String> = docs.iter().map(|d| text_key(&d.text)).collect();
        let stale: Vec<usize> = (0..docs.len())
            .filter(|&i| cache.vectors.get(&docs[i].path).map_or(true, |c| c.key != keys[i]))
            .collect();

        let model = match &model_dir {
            Some(dir) => load_local_model(dir, pooling)?,
            None => TextEmbedding::try_new(InitOptions::new(EmbeddingModel::AllMiniLML6V2))?,
        };

        let mut texts: Vec<String> = stale.iter().map(|&i| docs[i].text.clone()).collect();
        texts.push(query.to_string());
        let mut embeddings = model.embed(texts, None)?;
        let query_embedding = embeddings.pop().expect("query embedding present");

        for (&i, v) in stale.iter().zip(embeddings) {
            cache.vectors.insert(docs[i].path.clone(), CachedVector { key: keys[i].clone(), v });
        }
        // Drop files that are gone, so the cache never outgrows the project.
        let removed = cache.vectors.len() > docs.len();
        if removed {
            let live: BTreeSet<&str> = docs.iter().map(|d| d.path.as_str()).collect();
            cache.vectors.retain(|p, _| live.contains(p.as_str()));
        }
        if !stale.is_empty() || removed {
            save_cache(cache_path, &cache)?;
        }

        let mut hits: Vec<SearchHit> = docs
            .iter()
            .map(|doc| SearchHit {
                path: doc.path.clone(),
                ctx: doc.ctx.clone(),
                score: cosine_similarity(&query_embedding, &cache.vectors[&doc.path].v) as f64,
            })
            .collect();

        hits.sort_by(|a, b| b.score.partial_cmp(&a.score).unwrap_or(std::cmp::Ordering::Equal));
        hits.truncate(limit);
        Ok(hits)
    })
}
