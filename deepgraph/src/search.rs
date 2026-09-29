use std::path::Path;

use crate::model::{CtxStore, Graph};

pub struct SearchHit {
    pub path: String,
    pub ctx: String,
    pub score: f64,
}

/// One searchable file: its path, exported names, and note (if any),
/// joined into the text search matches against.
/// Including path and exports means a file is findable even before it
/// has a note (or when notes aren't written at all), and a note adds to
/// that rather than being the only signal.
pub struct SearchDoc {
    pub path: String,
    pub ctx: String,
    pub text: String,
}

/// Builds one `SearchDoc` per file in `<output>/graph.json`, merged with
/// its note from `<output>/ctx.json`. Falls back to `ctx.json` alone
/// (paths + notes) if there's no graph to read exports from.
pub fn load_search_docs(graph_path: &Path, ctx_store: &CtxStore) -> Vec<SearchDoc> {
    let graph: Option<Graph> = std::fs::read_to_string(graph_path)
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok());

    let note = |path: &str| ctx_store.get(path).map(|e| e.ctx.clone()).unwrap_or_default();

    match graph {
        Some(graph) => graph
            .nodes
            .iter()
            .map(|(path, node)| {
                let exports: Vec<&str> = node
                    .exports
                    .iter()
                    .map(String::as_str)
                    .filter(|e| *e != "*")
                    .collect();
                make_doc(path, &exports, note(path))
            })
            .collect(),
        None => ctx_store.keys().map(|path| make_doc(path, &[], note(path))).collect(),
    }
}

fn make_doc(path: &str, exports: &[&str], ctx: String) -> SearchDoc {
    let mut text = path.to_string();
    if !exports.is_empty() {
        text.push('\n');
        text.push_str(&exports.join(" "));
    }
    if !ctx.is_empty() {
        text.push('\n');
        text.push_str(&ctx);
    }
    SearchDoc { path: path.to_string(), ctx, text }
}

/// Lowercased words, also split at camelCase boundaries, so an export
/// like `NotificationDispatcher` or a path like `Snackbar.events.ts`
/// matches the query words "notification" or "snackbar".
fn tokenize(s: &str) -> Vec<String> {
    let mut tokens = Vec::new();
    for word in s.split(|c: char| !c.is_alphanumeric()).filter(|t| !t.is_empty()) {
        let mut current = String::new();
        let mut prev_lower = false;
        for c in word.chars() {
            if c.is_uppercase() && prev_lower && !current.is_empty() {
                tokens.push(current.to_lowercase());
                current.clear();
            }
            prev_lower = c.is_lowercase() || c.is_numeric();
            current.push(c);
        }
        if !current.is_empty() {
            tokens.push(current.to_lowercase());
        }
    }
    tokens
}

/// Simple, dependency-light fuzzy search over each file's path, exports
/// and note: exact substring matches rank highest, otherwise each query
/// word is scored against its best-matching word in the text
/// (Jaro-Winkler, so typos and partial words still find things) and
/// averaged.
pub fn fuzzy_search(docs: &[SearchDoc], query: &str, limit: usize) -> Vec<SearchHit> {
    let query_lower = query.to_lowercase();
    let query_tokens = tokenize(query);

    let mut hits: Vec<SearchHit> = docs
        .iter()
        .filter_map(|doc| {
            let text_lower = doc.text.to_lowercase();
            let mut score = 0.0;
            if text_lower.contains(&query_lower) {
                score += 2.0;
            }

            let text_tokens = tokenize(&doc.text);
            if !query_tokens.is_empty() && !text_tokens.is_empty() {
                let token_score: f64 = query_tokens
                    .iter()
                    .map(|qt| {
                        text_tokens
                            .iter()
                            .map(|tt| {
                                if tt == qt {
                                    1.0
                                } else {
                                    strsim::jaro_winkler(qt, tt)
                                }
                            })
                            .fold(0.0_f64, f64::max)
                    })
                    .sum();
                score += token_score / query_tokens.len() as f64;
            }

            if score > 0.3 {
                Some(SearchHit {
                    path: doc.path.clone(),
                    ctx: doc.ctx.clone(),
                    score,
                })
            } else {
                None
            }
        })
        .collect();

    hits.sort_by(|a, b| b.score.partial_cmp(&a.score).unwrap_or(std::cmp::Ordering::Equal));
    hits.truncate(limit);
    hits
}
