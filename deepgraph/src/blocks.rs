//! Writing `@sourcemap` blocks (see `header`) into the files on disk.
//!
//! These are the project's own source files, possibly open in an editor
//! or being edited by an agent, so every write is defensive:
//! - a file whose content no longer matches the graph (edited since the
//!   last `build`) is skipped; the next build picks it up;
//! - the new content goes to a temp file next to the original, and only
//!   replaces it if the original is still byte-identical to what was read,
//!   so a concurrent save is never overwritten (except in the tiny window
//!   between that check and the rename);
//! - the rename keeps the file's permissions (e.g. an executable script);
//! - a file that isn't valid UTF-8 is never touched.

use std::path::Path;

use crate::header::{self, HeaderInfo};
use crate::model::Graph;
use crate::notes::Notes;
use crate::walk::{self, Lang};

#[derive(Default)]
pub struct Stats {
    /// Paths (relative to the root) of the files that were rewritten.
    pub written: Vec<String>,
    pub skipped: usize,
}

/// Replaces `path`'s content with `new`, if it still is `old`.
/// Returns false (and changes nothing) if it isn't anymore.
fn replace_if_unchanged(path: &Path, old: &str, new: &str) -> anyhow::Result<bool> {
    let dir = path.parent().unwrap_or(Path::new("."));
    let name = path.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
    let tmp = dir.join(format!(".{name}.sourcemap-tmp"));
    std::fs::write(&tmp, new)?;
    let result = (|| {
        std::fs::set_permissions(&tmp, std::fs::metadata(path)?.permissions())?;
        if std::fs::read(path)? != old.as_bytes() {
            return Ok(false);
        }
        std::fs::rename(&tmp, path)?;
        Ok(true)
    })();
    if !matches!(result, Ok(true)) {
        let _ = std::fs::remove_file(&tmp);
    }
    result
}

/// Brings the block of every file in `graph` (or only `only`'s files) up
/// to date with its node's dependents and its note. Files whose block is
/// already right aren't touched.
pub fn write_headers(root: &Path, graph: &Graph, notes: &Notes, only: Option<&[String]>) -> Stats {
    let mut stats = Stats::default();
    let selected: Box<dyn Iterator<Item = (&String, &crate::model::Node)>> = match only {
        Some(paths) => Box::new(paths.iter().filter_map(|p| graph.nodes.get_key_value(p))),
        None => Box::new(graph.nodes.iter()),
    };
    for (path, node) in selected {
        let abs = root.join(path);
        let Some(lang) = walk::detect_lang(&abs) else { continue };
        let Ok(content) = std::fs::read_to_string(&abs) else {
            stats.skipped += 1;
            continue;
        };
        if header::content_hash(&header::strip(&content, lang)) != node.hash {
            stats.skipped += 1;
            continue;
        }
        let note = notes.get(path);
        let info = HeaderInfo {
            ctx: note.map(|n| n.ctx.as_str()),
            dependents: &node.dependents,
        };
        let block = header::render(lang, &info);
        let new = header::apply(&content, lang, block.as_deref());
        if new == content {
            continue;
        }
        match replace_if_unchanged(&abs, &content, &new) {
            Ok(true) => stats.written.push(path.clone()),
            Ok(false) => stats.skipped += 1,
            Err(e) => {
                eprintln!("deepgraph: could not write the block into {}: {e}", abs.display());
                stats.skipped += 1;
            }
        }
    }
    stats
}

/// Removes every block from every supported file under `root`,
/// regardless of `--exclude` patterns that may have changed since.
pub fn strip_tree(root: &Path) -> anyhow::Result<Stats> {
    let mut stats = Stats::default();
    let files = walk::collect_source_files(root, &globset::GlobSet::empty())?;
    for f in files {
        let Ok(content) = std::fs::read_to_string(&f.abs_path) else { continue };
        let stripped = header::strip(&content, f.lang);
        if stripped == content {
            continue;
        }
        match replace_if_unchanged(&f.abs_path, &content, &stripped) {
            Ok(true) => stats.written.push(f.rel_path),
            Ok(false) => stats.skipped += 1,
            Err(e) => {
                eprintln!("deepgraph: could not strip {}: {e}", f.abs_path.display());
                stats.skipped += 1;
            }
        }
    }
    Ok(stats)
}

/// The git clean filter: `input` (a file's content as git reads it from
/// the working tree) without its block. `path` only picks the comment
/// syntax; content in an unsupported language, or that isn't UTF-8,
/// passes through unchanged.
pub fn clean(path: &Path, input: Vec<u8>) -> Vec<u8> {
    let Some(lang): Option<Lang> = walk::detect_lang(path) else { return input };
    match String::from_utf8(input) {
        Ok(text) => match header::strip(&text, lang) {
            std::borrow::Cow::Borrowed(_) => text.into_bytes(),
            std::borrow::Cow::Owned(stripped) => stripped.into_bytes(),
        },
        Err(e) => e.into_bytes(),
    }
}
