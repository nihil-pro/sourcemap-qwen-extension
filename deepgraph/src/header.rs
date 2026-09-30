//! The generated `@sourcemap` block appended to the end of every source
//! file: the file's note (`ctx`) and its dependents, so an agent finds a
//! file by grepping for what it does and sees what depends on it when it
//! reads the file.
//!
//! The block is local-only: a git clean filter (`deepgraph clean`) strips
//! it whenever git reads a file, so it never reaches the index, a commit,
//! or `git diff`. Everything therefore rests on one guarantee, covered by
//! the tests below: `strip(apply(x, block)) == x`, byte for byte.
//!
//! It goes at the END of the file, never the top: the top is crowded with
//! position-sensitive things (shebangs, Python encoding lines, license
//! headers, docblocks with `@jest-environment`-style pragmas, JSDoc that
//! must sit right above its declaration), and appending leaves every
//! existing line number identical to what git has.
//!
//! Layout written by `apply`, reversed exactly by `strip`:
//! - file ends with a newline:   `<content>` EOL `<block lines, each + EOL>`
//!   (i.e. one blank separator line, then the block)
//! - file has no final newline:  `<content>` EOL EOL `<block lines joined by EOL>`
//!   (no EOL after the block: that's how `strip` knows to drop the newline
//!   it added to the content's last line)
//! - empty file:                 `<block lines joined by EOL>`
//! EOL is the file's own line ending (CRLF if its first line ends in one).

use std::borrow::Cow;

use crate::walk::Lang;

/// Most dependents listed in a block; the rest become "(+N more)", so a
/// util imported by hundreds of files doesn't carry a huge block.
const MAX_DEPENDENTS: usize = 10;

/// Most exported names listed on the `@ctx:` line.
const MAX_EXPORTS: usize = 20;

/// A block is short; anything longer than this after a start marker isn't
/// ours (or is damaged), and is left alone.
const MAX_BLOCK_LINES: usize = 20;

struct Style {
    /// Start line prefix, followed by the end of line or a space.
    start: &'static str,
    /// Prefix of every line between start and end.
    mid: &'static str,
    /// The exact end line.
    end: &'static str,
}

fn style(lang: Lang) -> Style {
    match lang {
        Lang::Python => Style { start: "# @sourcemap", mid: "# ", end: "# @end-sourcemap" },
        Lang::Markdown => Style { start: "<!-- @sourcemap", mid: "", end: "@end-sourcemap -->" },
        Lang::Java | Lang::JavaScript | Lang::TypeScript => {
            Style { start: "/* @sourcemap", mid: " * ", end: " * @end-sourcemap */" }
        }
    }
}

impl Style {
    fn is_start(&self, line: &str) -> bool {
        line.strip_prefix(self.start)
            .map(|rest| rest.is_empty() || rest.starts_with(' '))
            .unwrap_or(false)
    }

    fn is_mid(&self, line: &str) -> bool {
        if self.mid.is_empty() {
            // Markdown: an HTML comment, so any line that doesn't open or close one
            !line.contains("-->") && !line.contains("<!--")
        } else {
            line.starts_with(self.mid)
        }
    }

    /// Keeps a value from closing the comment early or spanning lines.
    fn sanitize(&self, s: &str) -> String {
        let one_line = s.split_whitespace().collect::<Vec<_>>().join(" ");
        match self.end {
            e if e.ends_with("*/") => one_line.replace("*/", "* /"),
            e if e.ends_with("-->") => one_line.replace("-->", "-- >"),
            _ => one_line,
        }
    }
}

/// What a block says about one file.
pub struct HeaderInfo<'a> {
    /// The note. Shown even when written for an older version of the
    /// file: an edit rarely changes *what* a file does, and a stale note
    /// is re-annotated soon anyway.
    pub ctx: Option<&'a str>,
    /// Exported names (a `"*"` wildcard marker is skipped). Appended to the
    /// `@ctx:` line, so a search by a class or function name finds the
    /// file too, not only a search by what the note says.
    pub exports: &'a [String],
    pub dependents: &'a [String],
}

/// `items` joined with ", ", at most `max` of them, then "(+N more)".
fn capped_list(items: &[&str], max: usize) -> String {
    let shown = items.iter().take(max).copied().collect::<Vec<_>>().join(", ");
    match items.len().saturating_sub(max) {
        0 => shown,
        more => format!("{shown} (+{more} more)"),
    }
}

/// The block's lines (without line endings), or `None` when there's
/// nothing worth saying (no note, no exports and no dependents).
pub fn render(lang: Lang, info: &HeaderInfo) -> Option<Vec<String>> {
    let exports: Vec<&str> = info.exports.iter().map(String::as_str).filter(|e| *e != "*").collect();
    if info.ctx.is_none() && exports.is_empty() && info.dependents.is_empty() {
        return None;
    }
    let st = style(lang);
    let mut lines = vec![format!("{} (generated; do not edit)", st.start)];
    // `@ctx:` and `@dependents:` are unique enough to grep for (a bare
    // `ctx:` is a common identifier, e.g. a canvas context), so
    // `@ctx:.*word` lists one description line per file.
    let mut ctx_line: Vec<String> = info.ctx.map(str::to_string).into_iter().collect();
    if !exports.is_empty() {
        ctx_line.push(format!("Exports: {}", capped_list(&exports, MAX_EXPORTS)));
    }
    if !ctx_line.is_empty() {
        lines.push(format!("{}@ctx: {}", st.mid, st.sanitize(&ctx_line.join(" "))));
    }
    let deps = if info.dependents.is_empty() {
        "none".to_string()
    } else {
        let deps: Vec<&str> = info.dependents.iter().map(String::as_str).collect();
        capped_list(&deps, MAX_DEPENDENTS)
    };
    lines.push(format!("{}@dependents: {}", st.mid, st.sanitize(&deps)));
    lines.push(st.end.to_string());
    Some(lines)
}

fn trim_eol(line: &str) -> &str {
    line.strip_suffix('\n').map(|l| l.strip_suffix('\r').unwrap_or(l)).unwrap_or(line)
}

fn is_blank_line(line: &str) -> bool {
    line == "\n" || line == "\r\n"
}

fn detect_eol(content: &str) -> &'static str {
    match content.find('\n') {
        Some(i) if i > 0 && content.as_bytes()[i - 1] == b'\r' => "\r\n",
        _ => "\n",
    }
}

/// Index of the end line of a block starting at `lines[i]`, if one does.
fn block_end(lines: &[&str], i: usize, st: &Style) -> Option<usize> {
    if !st.is_start(trim_eol(lines[i])) {
        return None;
    }
    for (j, line) in lines.iter().enumerate().skip(i + 1).take(MAX_BLOCK_LINES) {
        let line = trim_eol(line);
        if line == st.end {
            return Some(j);
        }
        if !st.is_mid(line) {
            return None;
        }
    }
    None
}

/// Removes every `@sourcemap` block (normally just the one at the end,
/// but also one the agent has since appended code after, or a duplicate),
/// together with the separator `apply` added before it. A start marker
/// without a well-formed block after it is left untouched.
pub fn strip(content: &str, lang: Lang) -> Cow<'_, str> {
    let st = style(lang);
    if !content.contains(st.start) {
        return Cow::Borrowed(content);
    }
    let lines: Vec<&str> = content.split_inclusive('\n').collect();
    let mut out = String::with_capacity(content.len());
    let mut changed = false;
    let mut i = 0;
    while i < lines.len() {
        if let Some(end) = block_end(&lines, i, &st) {
            // The separator line before the block was already copied to `out`
            if i > 0 && is_blank_line(lines[i - 1]) && out.ends_with(lines[i - 1]) {
                out.truncate(out.len() - lines[i - 1].len());
            }
            // A block that ends the file without a newline means the content had none either
            if end == lines.len() - 1 && !lines[end].ends_with('\n') {
                if out.ends_with("\r\n") {
                    out.truncate(out.len() - 2);
                } else if out.ends_with('\n') {
                    out.truncate(out.len() - 1);
                }
            }
            changed = true;
            i = end + 1;
            continue;
        }
        out.push_str(lines[i]);
        i += 1;
    }
    if changed {
        Cow::Owned(out)
    } else {
        Cow::Borrowed(content)
    }
}

/// `content` with any existing block replaced by `block` (or just removed, for `None`).
pub fn apply(content: &str, lang: Lang, block: Option<&[String]>) -> String {
    let base = strip(content, lang);
    let Some(block) = block else {
        return base.into_owned();
    };
    let eol = detect_eol(&base);
    let joined = block.join(eol);
    if base.is_empty() {
        joined
    } else if base.ends_with('\n') {
        format!("{base}{eol}{joined}{eol}")
    } else {
        format!("{base}{eol}{eol}{joined}")
    }
}

/// Content hash of a file, as stored in `graph.json` and in notes:
/// FNV-1a 64 over the content without its block, with CRLF read as LF.
/// Stable across Rust versions and machines (so a teammate's note for an
/// unchanged file is recognized as fresh), and blind to the block itself
/// (so rewriting a block never makes the file's note look stale).
pub fn content_hash(stripped: &str) -> String {
    let bytes = stripped.as_bytes();
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for (i, &b) in bytes.iter().enumerate() {
        if b == b'\r' && bytes.get(i + 1) == Some(&b'\n') {
            continue;
        }
        h ^= b as u64;
        h = h.wrapping_mul(0x0000_0100_0000_01b3);
    }
    format!("{h:016x}")
}

/// The hash earlier versions stored (std's `DefaultHasher` over the raw
/// bytes). Only used by `import-ctx` to tell which old notes are still
/// fresh; not stable across Rust versions, which is why it was replaced.
pub fn legacy_hash(bytes: &[u8]) -> String {
    use std::hash::{Hash, Hasher};
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    bytes.hash(&mut hasher);
    format!("{:016x}", hasher.finish())
}

#[cfg(test)]
mod tests {
    use super::*;

    const LANGS: [Lang; 5] = [Lang::Java, Lang::Python, Lang::JavaScript, Lang::TypeScript, Lang::Markdown];

    fn deps(n: usize) -> Vec<String> {
        (0..n).map(|i| format!("src/dep{i}.ts")).collect()
    }

    fn sample_contents() -> Vec<&'static str> {
        vec![
            "",
            "\n",
            "\n\n",
            "a",
            "a\n",
            "a\n\n",
            "a\n\n\n",
            "a\r\n",
            "a\r\nb",
            "a\r\n\r\n",
            "#!/usr/bin/env node\n",
            "#!/usr/bin/env node",
            "export const a = 1;\nexport const b = 2;\n",
            "\u{feff}export const a = 1;\n",
            "---\ntitle: x\n---\n# Doc\n",
            "# -*- coding: utf-8 -*-\n\"\"\"doc\"\"\"\n",
        ]
    }

    fn infos<'a>(d: &'a [String]) -> Vec<HeaderInfo<'a>> {
        vec![
            HeaderInfo { ctx: Some("Does a thing."), exports: &[], dependents: &[] },
            HeaderInfo { ctx: Some("Does */ --> a\nthing."), exports: d, dependents: d },
            HeaderInfo { ctx: None, exports: &[], dependents: d },
        ]
    }

    #[test]
    fn strip_undoes_apply_exactly() {
        let d = deps(12);
        for lang in LANGS {
            for content in sample_contents() {
                for info in infos(&d) {
                    let block = render(lang, &info).unwrap();
                    let applied = apply(content, lang, Some(&block));
                    assert_ne!(applied, content);
                    assert_eq!(strip(&applied, lang), content, "{lang:?} {content:?} -> {applied:?}");
                }
            }
        }
    }

    #[test]
    fn apply_is_idempotent_and_replaces() {
        let d = deps(3);
        for lang in LANGS {
            for content in sample_contents() {
                let infos = infos(&d);
                let first = render(lang, &infos[0]).unwrap();
                let second = render(lang, &infos[1]).unwrap();
                let once = apply(content, lang, Some(&first));
                assert_eq!(apply(&once, lang, Some(&first)), once);
                let replaced = apply(&once, lang, Some(&second));
                assert_eq!(replaced, apply(content, lang, Some(&second)));
                assert_eq!(apply(&replaced, lang, None), content);
            }
        }
    }

    #[test]
    fn block_is_at_the_end_with_file_eol() {
        let d = deps(1);
        let block = render(Lang::TypeScript, &HeaderInfo { ctx: Some("X."), exports: &[], dependents: &d }).unwrap();
        assert_eq!(
            apply("a\r\n", Lang::TypeScript, Some(&block)),
            "a\r\n\r\n/* @sourcemap (generated; do not edit)\r\n * @ctx: X.\r\n * @dependents: src/dep0.ts\r\n * @end-sourcemap */\r\n"
        );
    }

    #[test]
    fn strips_block_with_code_appended_after_it() {
        let block = render(Lang::JavaScript, &HeaderInfo { ctx: Some("X."), exports: &[], dependents: &[] }).unwrap();
        let applied = apply("a();\n", Lang::JavaScript, Some(&block));
        let edited = format!("{applied}b();\n");
        assert_eq!(strip(&edited, Lang::JavaScript), "a();\nb();\n");
    }

    #[test]
    fn leaves_damaged_or_foreign_markers_alone() {
        let damaged = "a\n\n/* @sourcemap (generated; do not edit)\n * ctx: X.\nconst b = 1;\n";
        assert_eq!(strip(damaged, Lang::JavaScript), damaged);
        let unterminated = "a\n\n/* @sourcemap (generated; do not edit)\n * ctx: X.\n";
        assert_eq!(strip(unterminated, Lang::JavaScript), unterminated);
        let other = "/* @sourcemapper */\n";
        assert_eq!(strip(other, Lang::JavaScript), other);
    }

    #[test]
    fn caps_dependents() {
        let d = deps(13);
        let block = render(Lang::Python, &HeaderInfo { ctx: None, exports: &[], dependents: &d }).unwrap();
        assert!(block[1].ends_with("src/dep9.ts (+3 more)"), "{}", block[1]);
        assert!(render(Lang::Python, &HeaderInfo { ctx: None, exports: &[], dependents: &[] }).is_none());
    }

    #[test]
    fn exports_end_the_ctx_line() {
        let exports = vec!["Timer".to_string(), "*".to_string(), "format".to_string()];
        let with_note = render(Lang::TypeScript, &HeaderInfo { ctx: Some("Tracks time."), exports: &exports, dependents: &[] }).unwrap();
        assert_eq!(with_note[1], " * @ctx: Tracks time. Exports: Timer, format");
        let without_note = render(Lang::TypeScript, &HeaderInfo { ctx: None, exports: &exports, dependents: &[] }).unwrap();
        assert_eq!(without_note[1], " * @ctx: Exports: Timer, format");
        let wildcard_only = vec!["*".to_string()];
        assert!(render(Lang::TypeScript, &HeaderInfo { ctx: None, exports: &wildcard_only, dependents: &[] }).is_none());
    }

    #[test]
    fn hash_ignores_crlf() {
        assert_eq!(content_hash("a\r\nb\r\n"), content_hash("a\nb\n"));
        assert_ne!(content_hash("a\nb\n"), content_hash("a\nb"));
    }
}
