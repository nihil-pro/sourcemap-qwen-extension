//! The committed notes file (e.g. `<project>/.qwen/sourcemap/notes.jsonl`): one
//! `{"path","hash","ctx"}` object per line, sorted by path. Notes cost an
//! LLM call each, so they're shared through git, unlike everything else
//! deepgraph writes (graph, blocks), which is cheap to regenerate locally.
//!
//! One line per file keeps merges line-based, and the file's own
//! `.gitattributes` (written next to it) merges it with git's built-in
//! `union` driver: both sides' lines are kept, never a conflict. The
//! resulting duplicates are resolved on load, in favor of the note whose
//! hash matches the file's current content.

use std::collections::BTreeMap;
use std::io::Write;
use std::path::Path;

use serde::{Deserialize, Serialize};

use crate::model::{CtxEntry, CtxStore};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Note {
    pub path: String,
    /// The file's content hash when `ctx` was written (see `header::content_hash`).
    pub hash: String,
    pub ctx: String,
}

pub type Notes = BTreeMap<String, Note>;

const GITATTRIBUTES: &str = "notes.jsonl merge=union\n";

/// Every parseable line of the file (none if it's missing). Unparseable
/// lines, e.g. conflict markers from a merge that didn't use the union
/// driver, are skipped.
pub fn load(path: &Path) -> Vec<Note> {
    let Ok(text) = std::fs::read_to_string(path) else {
        return Vec::new();
    };
    text.lines()
        .filter(|l| !l.trim().is_empty())
        .filter_map(|l| serde_json::from_str::<Note>(l).ok())
        .filter(|n| !n.path.is_empty() && !n.ctx.is_empty())
        .collect()
}

/// One note per path. Among duplicates, the one whose hash matches the
/// file's current hash (per `current`) wins; otherwise the last one.
pub fn resolve(notes: Vec<Note>, current: impl Fn(&str) -> Option<String>) -> Notes {
    let mut out = Notes::new();
    for note in notes {
        let keep_existing = out
            .get(&note.path)
            .map(|existing: &Note| {
                let cur = current(&note.path);
                cur.as_deref() == Some(existing.hash.as_str()) && cur.as_deref() != Some(note.hash.as_str())
            })
            .unwrap_or(false);
        if !keep_existing {
            out.insert(note.path.clone(), note);
        }
    }
    out
}

fn serialize(notes: &Notes) -> String {
    let mut s = String::new();
    for note in notes.values() {
        s.push_str(&serde_json::to_string(note).expect("a note always serializes"));
        s.push('\n');
    }
    s
}

/// Writes `notes` if that changes the file (so an unchanged set never
/// touches it), atomically. Also writes the union-merge `.gitattributes`
/// next to it if missing. Doesn't create a file for an empty set.
/// Returns whether the file was written.
pub fn save(path: &Path, notes: &Notes) -> anyhow::Result<bool> {
    let text = serialize(notes);
    match std::fs::read_to_string(path) {
        Ok(existing) if existing == text => return Ok(false),
        Err(_) if notes.is_empty() => return Ok(false),
        _ => {}
    }
    let dir = path.parent().unwrap_or(Path::new("."));
    std::fs::create_dir_all(dir)?;
    let attrs = dir.join(".gitattributes");
    if !attrs.exists() {
        std::fs::write(&attrs, GITATTRIBUTES)?;
    }
    let tmp = path.with_extension("jsonl.tmp");
    {
        let mut f = std::fs::File::create(&tmp)?;
        f.write_all(text.as_bytes())?;
        f.sync_all()?;
    }
    std::fs::rename(&tmp, path)?;
    Ok(true)
}

/// The shape `show`/`search` read notes in.
pub fn to_ctx_store(notes: &Notes) -> CtxStore {
    notes
        .values()
        .map(|n| (n.path.clone(), CtxEntry { ctx: n.ctx.clone(), ctx_hash: n.hash.clone() }))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn note(path: &str, hash: &str, ctx: &str) -> Note {
        Note { path: path.into(), hash: hash.into(), ctx: ctx.into() }
    }

    #[test]
    fn duplicates_prefer_the_current_hash() {
        let current = |p: &str| (p == "a").then(|| "h2".to_string());
        let r = resolve(vec![note("a", "h2", "new"), note("a", "h1", "old")], current);
        assert_eq!(r["a"].ctx, "new");
        let r = resolve(vec![note("a", "h1", "old"), note("a", "h2", "new")], current);
        assert_eq!(r["a"].ctx, "new");
        let r = resolve(vec![note("b", "x", "first"), note("b", "y", "second")], current);
        assert_eq!(r["b"].ctx, "second");
    }
}
