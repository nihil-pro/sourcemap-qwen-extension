// Force linking against tree-sitter-md's compiled grammar: nothing
// below references its Rust API (see the `extern "C"` block), so
// without this the linker never pulls in its native library and the
// symbols below are undefined at link time.
extern crate tree_sitter_md as _;

use std::collections::{HashMap, HashSet};
use std::path::Path;

use tree_sitter::{Language, Node, Parser, Tree};

use crate::facts::{DepRef, Dependency, FileFacts, ImportWant};
use crate::tsutil::{first_child_of_kind, is_under_node_modules, node_text};

// Markdown is parsed with two separate grammars: a block grammar (this
// crate's typed Rust API needs a newer `tree-sitter` than the rest of
// this project pins) and an inline grammar for link/emphasis/etc.
// content within it. Rather than pull in a second `tree-sitter`
// version just for this, link straight against the same compiled C
// symbols the crate's own bindings use -- the same trick older
// tree-sitter-* binding crates use themselves (a `Language` is
// ABI-compatible with the raw pointer these functions return).
extern "C" {
    fn tree_sitter_markdown() -> Language;
    fn tree_sitter_markdown_inline() -> Language;
}

pub fn block_language() -> Language {
    unsafe { tree_sitter_markdown() }
}

pub fn inline_language() -> Language {
    unsafe { tree_sitter_markdown_inline() }
}

/// Markdown has no imports/exports, just links -- so the only thing
/// tracked is: does this file link to another `.md` file. `inline_parser`
/// is reused across calls (parsing the block tree's opaque `inline`
/// spans is a second, separate parse per span, by design of this
/// grammar).
pub fn analyze(
    block_tree: &Tree,
    src: &[u8],
    root: &Path,
    importer_dir: &Path,
    inline_parser: &mut Parser,
) -> FileFacts {
    let mut facts = FileFacts::default();

    let mut ref_defs: HashMap<String, String> = HashMap::new();
    let mut inline_spans: Vec<(usize, usize)> = Vec::new();
    collect_block(block_tree.root_node(), src, &mut ref_defs, &mut inline_spans);

    let mut raw_destinations: Vec<String> = Vec::new();
    for (start, end) in inline_spans {
        if start >= end {
            continue;
        }
        let text = &src[start..end];
        if text.iter().all(u8::is_ascii_whitespace) {
            continue;
        }
        let Some(tree) = inline_parser.parse(text, None) else {
            continue;
        };
        collect_inline_links(tree.root_node(), text, &ref_defs, &mut raw_destinations);
    }

    let mut seen = HashSet::new();
    for raw in raw_destinations {
        if !seen.insert(raw.clone()) {
            continue;
        }
        if let Some(target) = resolve_md_link(root, importer_dir, &raw) {
            facts.dependencies.push(Dependency { target, want: ImportWant::All });
        }
    }

    facts
}

fn normalize_label(raw: &str) -> String {
    raw.trim_start_matches('[').trim_end_matches(']').trim().to_lowercase()
}

fn collect_block(
    node: Node,
    src: &[u8],
    ref_defs: &mut HashMap<String, String>,
    inline_spans: &mut Vec<(usize, usize)>,
) {
    match node.kind() {
        "link_reference_definition" => {
            let label = first_child_of_kind(node, "link_label").map(|n| normalize_label(node_text(n, src)));
            let dest = first_child_of_kind(node, "link_destination").map(|n| node_text(n, src).to_string());
            if let (Some(label), Some(dest)) = (label, dest) {
                ref_defs.entry(label).or_insert(dest);
            }
        }
        "inline" | "pipe_table_cell" => {
            inline_spans.push((node.start_byte(), node.end_byte()));
            return; // inline content is re-parsed separately; don't descend here
        }
        _ => {}
    }
    let mut cursor = node.walk();
    for child in node.children(&mut cursor) {
        collect_block(child, src, ref_defs, inline_spans);
    }
}

fn collect_inline_links(node: Node, src: &[u8], ref_defs: &HashMap<String, String>, out: &mut Vec<String>) {
    match node.kind() {
        "inline_link" => {
            if let Some(dest) = first_child_of_kind(node, "link_destination") {
                out.push(node_text(dest, src).to_string());
            }
        }
        "full_reference_link" => {
            if let Some(label) = first_child_of_kind(node, "link_label") {
                let key = normalize_label(node_text(label, src));
                if let Some(dest) = ref_defs.get(&key) {
                    out.push(dest.clone());
                }
            }
        }
        "shortcut_link" | "collapsed_reference_link" => {
            if let Some(text_node) = first_child_of_kind(node, "link_text") {
                let key = node_text(text_node, src).trim().to_lowercase();
                if let Some(dest) = ref_defs.get(&key) {
                    out.push(dest.clone());
                }
            }
        }
        _ => {}
    }
    let mut cursor = node.walk();
    for child in node.children(&mut cursor) {
        collect_inline_links(child, src, ref_defs, out);
    }
}

/// Resolves a raw link destination to an internal `.md` file, or `None`
/// for anything else: external URLs, anchors-only links, links to
/// non-`.md` files, or links that don't resolve to a real file.
fn resolve_md_link(root: &Path, importer_dir: &Path, raw: &str) -> Option<DepRef> {
    let mut spec = raw.trim();
    if spec.len() >= 2 && spec.starts_with('<') && spec.ends_with('>') {
        spec = &spec[1..spec.len() - 1];
    }
    if spec.is_empty() || spec.starts_with('#') || spec.contains("://") || spec.starts_with("mailto:") {
        return None;
    }
    let spec = spec.split(['#', '?']).next().unwrap_or("");
    if !spec.to_ascii_lowercase().ends_with(".md") {
        return None;
    }

    let candidate = if let Some(rest) = spec.strip_prefix('/') {
        root.join(rest)
    } else {
        importer_dir.join(spec)
    };
    let canon = candidate.canonicalize().ok()?;
    if is_under_node_modules(&canon) {
        return None;
    }
    let rel = canon.strip_prefix(root).ok()?;
    Some(DepRef::Internal(rel.to_string_lossy().replace('\\', "/")))
}
