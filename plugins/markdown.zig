//! markdown — a conservative subset renderer producing `forest`
//! nodes, extracted from `src/apps/board/shared/markdown.zig` and
//! extended for long-form blog content. Deliberately NOT CommonMark:
//! the grammar is small enough to audit for XSS, and anything
//! unrecognized stays literal text.
//!
//! Supported (document mode — `renderBlocks`, used by zblog):
//!   blocks   ATX headings `#`..`######` — rendered through
//!            plugins/html.zig as `<hN id="slug">` (slug from
//!            `slugify`, deduplicated per document: `x`, `x-2`, …)
//!            paragraphs — wrapped in `<p>`
//!            `-`/`*`/`+` and `1.`/`1)` lists, nested by indent
//!            `>` quote runs — one level, inline content only
//!            ``` fenced code — `<pre><code class="language-x">`
//!            GFM pipe tables — `<table><thead><tbody>`
//!            `---`/`***`/`___` thematic breaks — `<hr>`
//!   inline   `code` — literal content, no inner parsing
//!            **bold** / *italic* / _italic_ — `<strong>`/`<em>`
//!            ~~strike~~ — `<del>` (raw node; forest.Tag has no del)
//!            [text](url) — `<a>`; http/https PLUS root-relative
//!            "/path" and "#anchor" (board's original http/https-only
//!            rule is a subset — javascript:/data:/relative-without-
//!            slash still fail and stay literal)
//!            ![alt](src) — `<img>`; alt REQUIRED (empty alt → literal)
//!
//! `render` is the board-compatible mode: same blocks minus `<p>`
//! wrappers, blank-line gaps re-emitted as text (the board `.ptext`
//! container is `white-space: pre-wrap`), so board could adopt this
//! file later without view changes. It is NOT migrated yet — board
//! still uses its own copy.
//!
//! Unsupported (stays literal): setext headings, indented code
//! blocks, raw HTML, link titles/images-in-links, reference links,
//! autolinks, nested blockquotes, lazy list continuation (a
//! non-indented line ends the list), `|` inside table cells.
//!
//! Safety: every literal byte goes through forest text/element nodes
//! or plugins/html.zig's escaped raw serializer (`writeHtml` escapes
//! text, attrs ride the normal attr path after scheme checks);
//! `forest.raw` is never called with untrusted bytes, so user input
//! cannot inject markup.
//!
//! Heading ids are deduplicated PER render/headings() CALL — a page
//! embedding several documents should treat ids as document-local
//! (fine for zblog: one post body per page).
const std = @import("std");
const forest = @import("forest");
// html.zig is a named build module (zplug_html) — a file may belong
// to exactly one Zig module, so plugin-internal imports go through
// the build graph, not relative paths.
const html = @import("zplug_html");

/// Recursion cap for markup nested inside emphasis/link text.
const max_depth = 8;

const Line = struct { lo: usize, hi: usize };

/// `src` split into '\n'-separated spans ([lo,hi) into `src`; a
/// trailing '\r' stays inside the span — the HTML parser normalizes it).
fn linesOf(a: std.mem.Allocator, src: []const u8) []const Line {
    var out: std.ArrayListUnmanaged(Line) = .empty;
    var off: usize = 0;
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |raw| {
        out.append(a, .{ .lo = off, .hi = off + raw.len }) catch @panic("OOM");
        off += raw.len + 1;
    }
    return out.toOwnedSlice(a) catch @panic("OOM");
}

/// Line content for classification: the span minus one trailing '\r'.
fn lineText(src: []const u8, ln: Line) []const u8 {
    var s = src[ln.lo..ln.hi];
    if (s.len > 0 and s[s.len - 1] == '\r') s = s[0 .. s.len - 1];
    return s;
}

fn isBlank(t: []const u8) bool {
    for (t) |c| if (c != ' ' and c != '\t') return false;
    return true;
}

fn trim(t: []const u8) []const u8 {
    return std.mem.trim(u8, t, " \t");
}

/// Leading-space width: space = 1, tab advances to the next multiple
/// of 4 (CommonMark-ish tab stops, simplified).
fn indentOf(t: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < t.len) {
        if (t[i] == ' ') {
            n += 1;
            i += 1;
        } else if (t[i] == '\t') {
            n += 4 - (n % 4);
            i += 1;
        } else break;
    }
    return n;
}

fn skipIndent(t: []const u8) []const u8 {
    var i: usize = 0;
    while (i < t.len and (t[i] == ' ' or t[i] == '\t')) i += 1;
    return t[i..];
}

// ── block classification ─────────────────────────────────────────

const HeadingMark = struct { level: u8, text: []const u8 };

/// ATX heading: up to 3 leading spaces, 1-6 '#', then space/EOL.
/// `text` is the raw heading content (closing #'s NOT stripped here —
/// `headingText` does that).
fn headingMark(t: []const u8) ?HeadingMark {
    const s = skipIndent(t);
    if (indentOf(t) > 3) return null;
    var level: usize = 0;
    while (level < s.len and s[level] == '#' and level < 7) level += 1;
    if (level == 0 or level > 6) return null;
    if (level < s.len and s[level] != ' ' and s[level] != '\t') return null;
    var body = trim(s[level..]);
    // Optional closing sequence: " ##" at end.
    if (body.len > 0 and body[body.len - 1] == '#') {
        var k = body.len;
        while (k > 0 and body[k - 1] == '#') k -= 1;
        if (k == 0 or body[k - 1] == ' ' or body[k - 1] == '\t') {
            body = trim(body[0..k]);
        }
    }
    return .{ .level = @intCast(level), .text = body };
}

/// Fenced code opening: up to 3 spaces + ``` + optional info string.
/// Returns the info string (may be "").
fn fenceOpen(t: []const u8) ?[]const u8 {
    const s = skipIndent(t);
    if (indentOf(t) > 3) return null;
    if (s.len < 3 or s[0] != '`' or s[1] != '`' or s[2] != '`') return null;
    return trim(s[3..]);
}

/// Fenced code closing: up to 3 spaces + ``` + only trailing spaces.
fn fenceClose(t: []const u8) bool {
    const s = skipIndent(t);
    if (indentOf(t) > 3) return false;
    if (s.len < 3 or s[0] != '`' or s[1] != '`' or s[2] != '`') return false;
    for (s[3..]) |c| if (c != ' ' and c != '\t') return false;
    return true;
}

fn isQuote(t: []const u8) bool {
    return t.len > 0 and t[0] == '>';
}

/// Thematic break: a run of >=3 of the same `-`/`*`/`_` allowing
/// spaces/tabs between (CommonMark rule, simplified).
fn isHr(t: []const u8) bool {
    const s = trim(t);
    if (s.len < 3) return false;
    const c = s[0];
    if (c != '-' and c != '*' and c != '_') return false;
    var n: usize = 0;
    for (s) |ch| {
        if (ch == c) {
            n += 1;
        } else if (ch != ' ' and ch != '\t') return false;
    }
    return n >= 3;
}

const ListMark = struct {
    indent: usize,
    ordered: bool,
    /// Content after the marker + following whitespace.
    content: []const u8,
};

/// List item marker: `-`/`*`/`+` or `N.`/`N)` followed by whitespace.
/// Content must be non-empty (a bare "-" stays literal).
fn listMark(t: []const u8) ?ListMark {
    const indent = indentOf(t);
    const s = t[indent..];
    if (s.len == 0) return null;
    if (s[0] == '-' or s[0] == '*' or s[0] == '+') {
        if (s.len > 1 and (s[1] == ' ' or s[1] == '\t')) {
            const content = trim(s[1..]);
            if (content.len > 0) return .{ .indent = indent, .ordered = false, .content = content };
        }
        return null;
    }
    // Ordered: 1-9 digits then '.' or ')' then whitespace.
    var k: usize = 0;
    while (k < s.len and k < 9 and std.ascii.isDigit(s[k])) k += 1;
    if (k == 0 or k >= s.len or (s[k] != '.' and s[k] != ')')) return null;
    if (k + 1 >= s.len or (s[k + 1] != ' ' and s[k + 1] != '\t')) return null;
    const content = trim(s[k + 1 ..]);
    if (content.len == 0) return null;
    return .{ .indent = indent, .ordered = true, .content = content };
}

/// GFM table delimiter row: only `|`, `-`, `:`, space/tab and at
/// least one `-` and one `|` (a bare `---` under text is a <hr>,
/// not a one-column table).
fn isTableDelim(t: []const u8) bool {
    const s = trim(t);
    if (s.len == 0) return false;
    var saw_dash = false;
    var saw_pipe = false;
    for (s) |c| {
        switch (c) {
            '-' => saw_dash = true,
            '|' => saw_pipe = true,
            ':', ' ', '\t' => {},
            else => return false,
        }
    }
    return saw_dash and saw_pipe;
}

/// Split a pipe-table row into trimmed cells: outer pipes optional,
/// one trailing empty cell (from a trailing `|`) dropped. No escape
/// handling — `\|` and pipes inside code spans still split (documented
/// subset limitation).
fn splitRow(a: std.mem.Allocator, t: []const u8) []const []const u8 {
    var s = trim(t);
    if (s.len > 0 and s[0] == '|') s = s[1..];
    if (s.len > 0 and s[s.len - 1] == '|') s = s[0 .. s.len - 1];
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, s, '|');
    while (it.next()) |cell| {
        out.append(a, trim(cell)) catch @panic("OOM");
    }
    return out.toOwnedSlice(a) catch @panic("OOM");
}

const BlockKind = enum { para, heading, quote, fence, list, table, hr };

const Block = struct {
    kind: BlockKind,
    /// First/last line indices ([first, last)) into the lines array.
    first: usize,
    last: usize,
};

/// True when a table can start at line `i`: current line contains
/// `|` and the NEXT line is a delimiter row.
fn tableStart(lines: []const Line, src: []const u8, i: usize) bool {
    if (i + 1 >= lines.len) return false;
    const t = lineText(src, lines[i]);
    if (std.mem.indexOfScalar(u8, t, '|') == null) return false;
    return isTableDelim(lineText(src, lines[i + 1]));
}

/// True when a new block of any kind starts at line `i` — used to
/// terminate a paragraph run.
fn interruptsPara(lines: []const Line, src: []const u8, i: usize) bool {
    const t = lineText(src, lines[i]);
    if (isBlank(t)) return true;
    if (headingMark(t) != null) return true;
    if (fenceOpen(t) != null) return true;
    if (isHr(t)) return true;
    if (isQuote(t)) return true;
    if (listMark(t) != null) return true;
    if (tableStart(lines, src, i)) return true;
    return false;
}

/// Split `src` into blocks. The scan is shared by `render`,
/// `renderBlocks` and `headings` so all three agree on structure
/// (and therefore on heading-id assignment order).
fn scanBlocks(a: std.mem.Allocator, src: []const u8) []const Block {
    const lines = linesOf(a, src);
    var out: std.ArrayListUnmanaged(Block) = .empty;
    var i: usize = 0;
    while (i < lines.len) {
        const t = lineText(src, lines[i]);
        if (isBlank(t)) {
            i += 1;
            continue;
        }
        const first = i;
        var kind: BlockKind = .para;
        var j: usize = i + 1;
        if (headingMark(t) != null) {
            kind = .heading;
        } else if (fenceOpen(t) != null) {
            kind = .fence;
            while (j < lines.len and !fenceClose(lineText(src, lines[j]))) j += 1;
            if (j < lines.len) j += 1; // consume closing fence
        } else if (isHr(t)) {
            kind = .hr;
        } else if (tableStart(lines, src, i)) {
            kind = .table;
            j = i + 2; // header + delimiter
            while (j < lines.len) {
                const bt = lineText(src, lines[j]);
                if (isBlank(bt) or std.mem.indexOfScalar(u8, bt, '|') == null) break;
                j += 1;
            }
        } else if (isQuote(t)) {
            kind = .quote;
            while (j < lines.len and isQuote(lineText(src, lines[j]))) j += 1;
        } else if (listMark(t) != null) {
            kind = .list;
            // Run of marker lines plus indented continuations; a
            // blank or unindented non-marker line ends the list
            // (no lazy continuation in this subset).
            while (j < lines.len) {
                const lt = lineText(src, lines[j]);
                if (isBlank(lt)) break;
                if (listMark(lt) != null) {
                    j += 1;
                } else if (indentOf(lt) > 0) {
                    j += 1;
                } else break;
            }
        } else {
            kind = .para;
            while (j < lines.len and !interruptsPara(lines, src, j)) j += 1;
        }
        out.append(a, .{ .kind = kind, .first = first, .last = j }) catch @panic("OOM");
        i = j;
    }
    return out.toOwnedSlice(a) catch @panic("OOM");
}

// ── inline parsing ───────────────────────────────────────────────

fn pushText(a: std.mem.Allocator, out: *std.ArrayListUnmanaged(forest.Node), s: []const u8) void {
    if (s.len == 0) return;
    out.append(a, .{ .text = s }) catch @panic("OOM");
}

/// Emphasis content must be non-empty with non-whitespace edges —
/// rejects "* *", "** **" and friends.
fn emphOk(inner: []const u8) bool {
    return inner.len > 0 and
        !std.ascii.isWhitespace(inner[0]) and
        !std.ascii.isWhitespace(inner[inner.len - 1]);
}

const Span = struct { tag: forest.Tag, inner: []const u8, next: usize };
const LinkSpan = struct { inner: []const u8, url: []const u8, next: usize };
const ImgSpan = struct { alt: []const u8, url: []const u8, next: usize };
const StrikeSpan = struct { inner: []const u8, next: usize };

/// Index after the closing '`' of a code span starting at src[i], or
/// null. Empty `` spans stay literal.
fn codeSpanEnd(src: []const u8, i: usize) ?usize {
    const rel = std.mem.indexOfScalar(u8, src[i + 1 ..], '`') orelse return null;
    const close = i + 1 + rel;
    if (close == i + 1) return null;
    return close + 1;
}

/// '*'/'**' emphasis starting at src[i]. Single '*' matches intraword
/// (CommonMark-style); the closer is the next '*' — including one that
/// begins a '**' pair, which just leaves a literal '*' behind.
fn starSpan(src: []const u8, i: usize) ?Span {
    if (i + 1 < src.len and src[i + 1] == '*') {
        const rel = std.mem.indexOf(u8, src[i + 2 ..], "**") orelse return null;
        const close = i + 2 + rel;
        const inner = src[i + 2 .. close];
        if (!emphOk(inner)) return null;
        return .{ .tag = .strong, .inner = inner, .next = close + 2 };
    }
    const rel = std.mem.indexOfScalar(u8, src[i + 1 ..], '*') orelse return null;
    const close = i + 1 + rel;
    const inner = src[i + 1 .. close];
    if (!emphOk(inner)) return null;
    return .{ .tag = .em, .inner = inner, .next = close + 1 };
}

/// '_' emphasis starting at src[i]. Refuses to open after an
/// alphanumeric and only accepts closers not followed by one — so
/// snake_case identifiers never italicize.
fn underSpan(src: []const u8, i: usize) ?Span {
    if (i > 0 and std.ascii.isAlphanumeric(src[i - 1])) return null;
    var j = i + 1;
    while (j < src.len) {
        const rel = std.mem.indexOfScalar(u8, src[j..], '_') orelse return null;
        const close = j + rel;
        const after_ok = close + 1 >= src.len or !std.ascii.isAlphanumeric(src[close + 1]);
        if (after_ok) {
            const inner = src[i + 1 .. close];
            if (emphOk(inner)) return .{ .tag = .em, .inner = inner, .next = close + 1 };
        }
        j = close + 1;
    }
    return null;
}

/// '~~' strikethrough starting at src[i] → `<del>` (raw node —
/// forest.Tag has no del). Same edge rules as emphasis.
fn strikeSpan(src: []const u8, i: usize) ?StrikeSpan {
    if (i + 1 >= src.len or src[i + 1] != '~') return null;
    const rel = std.mem.indexOf(u8, src[i + 2 ..], "~~") orelse return null;
    const close = i + 2 + rel;
    const inner = src[i + 2 .. close];
    if (!emphOk(inner)) return null;
    return .{ .inner = inner, .next = close + 2 };
}

fn hasScheme(u: []const u8, comptime s: []const u8) bool {
    return u.len > s.len and std.ascii.eqlIgnoreCase(u[0..s.len], s);
}

/// Link/image URL policy: http/https absolute, root-relative "/x"
/// (but NOT protocol-relative "//x"), or "#fragment". Everything
/// else — javascript:, data:, relative-without-slash, empty — fails
/// and the markup stays literal. No whitespace/control bytes.
fn validUrl(u: []const u8) bool {
    var ok = false;
    if (hasScheme(u, "https://") or hasScheme(u, "http://")) {
        ok = u.len > (if (hasScheme(u, "https://")) "https://".len else "http://".len);
    } else if (u.len > 1 and u[0] == '/' and u[1] != '/') {
        ok = true;
    } else if (u.len > 1 and u[0] == '#') {
        ok = true;
    }
    if (!ok) return false;
    for (u) |c| if (c <= 0x20 or c == 0x7f) return false;
    return true;
}

/// `[text](url)` starting at src[i]: first ']' then '(' … ')'. The url
/// is validated but NOT unescaped — it rides the attr path verbatim.
fn linkSpan(src: []const u8, i: usize) ?LinkSpan {
    const r1 = std.mem.indexOfScalar(u8, src[i + 1 ..], ']') orelse return null;
    const rb = i + 1 + r1;
    if (rb + 1 >= src.len or src[rb + 1] != '(') return null;
    const r2 = std.mem.indexOfScalar(u8, src[rb + 2 ..], ')') orelse return null;
    const rp = rb + 2 + r2;
    const text = src[i + 1 .. rb];
    const url = src[rb + 2 .. rp];
    if (text.len == 0 or !validUrl(url)) return null;
    return .{ .inner = text, .url = url, .next = rp + 1 };
}

/// `![alt](src)` starting at src[i] ('!' followed by '['). Alt text is
/// REQUIRED — `![](x)` stays literal (decorative images should be
/// written as plain `![]()`… no: as literal text or omitted entirely).
fn imgSpan(src: []const u8, i: usize) ?ImgSpan {
    if (i + 1 >= src.len or src[i + 1] != '[') return null;
    const r1 = std.mem.indexOfScalar(u8, src[i + 2 ..], ']') orelse return null;
    const rb = i + 2 + r1;
    if (rb + 1 >= src.len or src[rb + 1] != '(') return null;
    const r2 = std.mem.indexOfScalar(u8, src[rb + 2 ..], ')') orelse return null;
    const rp = rb + 2 + r2;
    const alt = src[i + 2 .. rb];
    const url = src[rb + 2 .. rp];
    if (alt.len == 0 or !validUrl(url)) return null;
    return .{ .alt = alt, .url = url, .next = rp + 1 };
}

fn emphNode(a: std.mem.Allocator, tag: forest.Tag, inner: []const u8, depth: usize) forest.Node {
    var kids: std.ArrayListUnmanaged(forest.Node) = .empty;
    inlineInto(a, inner, &kids, depth + 1);
    return switch (tag) {
        .strong => forest.el(a, .strong, .{}, kids.items),
        .em => forest.el(a, .em, .{}, kids.items),
        else => unreachable,
    };
}

/// `~~inner~~` → `<del>` raw node (forest.Tag has no del).
fn delNode(a: std.mem.Allocator, inner: []const u8, depth: usize) forest.Node {
    var kids: std.ArrayListUnmanaged(forest.Node) = .empty;
    inlineInto(a, inner, &kids, depth + 1);
    return html.el(a, "del", &.{}, html.renderNodes(a, kids.items));
}

fn linkNode(a: std.mem.Allocator, inner: []const u8, url: []const u8, depth: usize) forest.Node {
    var kids: std.ArrayListUnmanaged(forest.Node) = .empty;
    inlineInto(a, inner, &kids, depth + 1);
    return forest.el(a, .a, .{
        .href = url,
        .target = "_blank",
        .rel = "noopener noreferrer",
    }, kids.items);
}

/// Scan `src` for inline markup, appending nodes to `out`. Literal
/// runs (including failed markers) flush as text nodes between hits.
fn inlineInto(
    a: std.mem.Allocator,
    src: []const u8,
    out: *std.ArrayListUnmanaged(forest.Node),
    depth: usize,
) void {
    if (depth >= max_depth) {
        pushText(a, out, src);
        return;
    }
    var i: usize = 0;
    var run: usize = 0;
    while (i < src.len) {
        var next: ?usize = null;
        var node: ?forest.Node = null;
        switch (src[i]) {
            '`' => {
                if (codeSpanEnd(src, i)) |end| {
                    next = end;
                    node = forest.el(a, .code, .{}, src[i + 1 .. end - 1]);
                }
            },
            '*' => {
                if (starSpan(src, i)) |s| {
                    next = s.next;
                    node = emphNode(a, s.tag, s.inner, depth);
                }
            },
            '_' => {
                if (underSpan(src, i)) |s| {
                    next = s.next;
                    node = emphNode(a, s.tag, s.inner, depth);
                }
            },
            '~' => {
                if (strikeSpan(src, i)) |s| {
                    next = s.next;
                    node = delNode(a, s.inner, depth);
                }
            },
            '[' => {
                if (linkSpan(src, i)) |s| {
                    next = s.next;
                    node = linkNode(a, s.inner, s.url, depth);
                }
            },
            '!' => {
                if (imgSpan(src, i)) |s| {
                    next = s.next;
                    node = forest.el(a, .img, .{ .src = s.url, .alt = s.alt }, .{});
                }
            },
            else => {},
        }
        if (node) |n| {
            pushText(a, out, src[run..i]);
            out.append(a, n) catch @panic("OOM");
            i = next.?;
            run = i;
        } else i += 1;
    }
    pushText(a, out, src[run..src.len]);
}

// ── plain-text extraction (slugs + TOC labels) ───────────────────

/// Append the plain text of inline `src` to `out` — markup syntax
/// removed, link/image destinations dropped, code/emphasis content
/// kept. Mirrors `inlineInto`'s span rules so it agrees on what
/// counts as markup.
fn plainInto(
    a: std.mem.Allocator,
    src: []const u8,
    out: *std.ArrayListUnmanaged(u8),
    depth: usize,
) void {
    if (depth >= max_depth) {
        out.appendSlice(a, src) catch @panic("OOM");
        return;
    }
    var i: usize = 0;
    while (i < src.len) {
        switch (src[i]) {
            '`' => {
                if (codeSpanEnd(src, i)) |end| {
                    out.appendSlice(a, src[i + 1 .. end - 1]) catch @panic("OOM");
                    i = end;
                    continue;
                }
            },
            '*' => {
                if (starSpan(src, i)) |s| {
                    plainInto(a, s.inner, out, depth + 1);
                    i = s.next;
                    continue;
                }
            },
            '_' => {
                if (underSpan(src, i)) |s| {
                    plainInto(a, s.inner, out, depth + 1);
                    i = s.next;
                    continue;
                }
            },
            '~' => {
                if (strikeSpan(src, i)) |s| {
                    plainInto(a, s.inner, out, depth + 1);
                    i = s.next;
                    continue;
                }
            },
            '[' => {
                if (linkSpan(src, i)) |s| {
                    plainInto(a, s.inner, out, depth + 1);
                    i = s.next;
                    continue;
                }
            },
            '!' => {
                if (imgSpan(src, i)) |s| {
                    out.appendSlice(a, s.alt) catch @panic("OOM");
                    i = s.next;
                    continue;
                }
            },
            else => {},
        }
        out.append(a, src[i]) catch @panic("OOM");
        i += 1;
    }
}

/// Plain text of an inline span — used for heading slugs and TOC
/// labels. Whitespace is preserved; callers trim/collapse.
pub fn plainInline(a: std.mem.Allocator, src: []const u8) []const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    plainInto(a, src, &out, 0);
    return std.mem.trim(u8, out.items, " \t");
}

// ── slugs ────────────────────────────────────────────────────────

/// Cyrillic → latin transliteration for `slugify`: lowercase
/// а-я (U+0430–U+044F — NOTE: ё is U+0451, NOT in this range, so the
/// table has exactly 32 entries) plus the switch extras below.
/// Multi-char outputs ("zh", "sch", "yu"…) are ASCII so they pass
/// the slug charset unchanged.
const cyr_table = [_][]const u8{
    "a", // а U+0430
    "b", // б
    "v", // в
    "g", // г
    "d", // д
    "e", // е
    "zh", // ж U+0436
    "z", // з
    "i", // и
    "y", // й
    "k", // к
    "l", // л
    "m", // м
    "n", // н
    "o", // о
    "p", // п
    "r", // р
    "s", // с
    "t", // т
    "u", // у
    "f", // ф
    "kh", // х
    "ts", // ц
    "ch", // ч
    "sh", // ш
    "sch", // щ
    "", // ъ
    "y", // ы
    "", // ь
    "e", // э
    "yu", // ю
    "ya", // я U+044F
};

fn pushSlugChar(out: *std.ArrayListUnmanaged(u8), a: std.mem.Allocator, pending: *bool, c: u8) void {
    if (pending.*) {
        if (out.items.len != 0) out.append(a, '-') catch @panic("OOM");
        pending.* = false;
    }
    out.append(a, c) catch @panic("OOM");
}

/// UTF-8 sequence length for a lead byte (1 for ASCII/invalid).
fn utf8Len(b: u8) usize {
    return switch (b) {
        0x00...0x7F => 1,
        0xC0...0xDF => 2,
        0xE0...0xEF => 3,
        0xF0...0xF7 => 4,
        else => 1,
    };
}

/// Cyrillic codepoint → transliteration, or null. Accepts both
/// cases (uppercase mapped down first).
fn cyrillicTranslit(cp: u32) ?[]const u8 {
    var c = cp;
    if (c >= 0x0410 and c <= 0x042F) c += 0x20; // А-Я → а-я
    if (c == 0x0401) c = 0x0451; // Ё → ё
    if (c >= 0x0430 and c <= 0x044F) return cyr_table[c - 0x0430];
    return switch (c) {
        0x0451 => "yo", // ё
        0x0456 => "i", // і
        0x0457 => "yi", // ї
        0x0454 => "ye", // є
        0x0491 => "g", // ґ
        else => null,
    };
}

/// Lowercase + transliterate + keep `[a-z0-9]` runs joined by `-`.
/// Cyrillic maps through `cyrillicTranslit`; every other non-ASCII
/// codepoint is dropped (it still separates words via a dash).
/// Empty result → "section". Over-long slugs truncate at a dash
/// boundary (~80 chars).
pub fn slugify(a: std.mem.Allocator, text: []const u8) []const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var pending = false;
    var i: usize = 0;
    while (i < text.len) {
        const b = text[i];
        if (b < 0x80) {
            const c = std.ascii.toLower(b);
            if ((c >= 'a' and c <= 'z') or (c >= '0' and c <= '9')) {
                pushSlugChar(&out, a, &pending, c);
            } else {
                pending = true;
            }
            i += 1;
            continue;
        }
        const len = utf8Len(b);
        if (len == 2 and i + 1 < text.len and (b == 0xD0 or b == 0xD1)) {
            const cp: u32 = (@as(u32, b & 0x1F) << 6) | @as(u32, text[i + 1] & 0x3F);
            if (cyrillicTranslit(cp)) |tr| {
                for (tr) |c| pushSlugChar(&out, a, &pending, c);
            } else {
                pending = true;
            }
        } else {
            // Other multi-byte sequences: dropped, but still act as
            // a word separator.
            pending = true;
        }
        i += @max(len, 1);
        if (i > text.len) i = text.len;
    }
    var s = out.items;
    if (s.len == 0) return "section";
    const max_len = 80;
    if (s.len > max_len) {
        var cut: usize = max_len;
        while (cut > 0 and s[cut] != '-') cut -= 1;
        if (cut < 20) cut = max_len; // no good boundary — hard cut
        s = s[0..cut];
        while (s.len > 0 and s[s.len - 1] == '-') s = s[0 .. s.len - 1];
    }
    return s;
}

/// Per-document heading-id dedup: `slug`, `slug-2`, `slug-3`, …
const Slugger = struct {
    a: std.mem.Allocator,
    seen: std.StringHashMapUnmanaged(void) = .empty,

    fn init(a: std.mem.Allocator) Slugger {
        return .{ .a = a };
    }

    fn next(self: *Slugger, base_in: []const u8) []const u8 {
        var candidate = base_in;
        var n: u32 = 2;
        while (self.seen.contains(candidate)) {
            candidate = std.fmt.allocPrint(self.a, "{s}-{d}", .{ base_in, n }) catch @panic("OOM");
            n += 1;
        }
        self.seen.put(self.a, candidate, {}) catch @panic("OOM");
        return candidate;
    }
};

// ── lists ────────────────────────────────────────────────────────

const LNode = struct {
    ordered: bool,
    items: std.ArrayListUnmanaged(LItem) = .empty,
};

const LItem = struct {
    /// Inline markdown source for the item text (marker content +
    /// indented continuation lines joined with spaces).
    text: []const u8,
    /// Nested lists belonging to this item.
    kids: std.ArrayListUnmanaged(*LNode) = .empty,
};

const FlatItem = struct {
    indent: usize,
    ordered: bool,
    text: []const u8,
};

/// Parse the flat marker/continuation lines of a list block into
/// `(indent, ordered, text)` items. Continuation lines append to the
/// current item's text with a single space join.
fn flatItems(a: std.mem.Allocator, src: []const u8, lines: []const Line, first: usize, last: usize) []const FlatItem {
    var out: std.ArrayListUnmanaged(FlatItem) = .empty;
    var cur_indent: usize = 0;
    var cur_ordered = false;
    var cur_parts: std.ArrayListUnmanaged(u8) = .empty;
    var have = false;

    const flush = struct {
        fn f(
            a2: std.mem.Allocator,
            out2: *std.ArrayListUnmanaged(FlatItem),
            parts: *std.ArrayListUnmanaged(u8),
            indent: usize,
            ordered: bool,
            have2: bool,
        ) void {
            if (!have2) return;
            // Dupe: the trimmed slice aliases `parts.items`, and
            // clearRetainingCapacity() below poisons that buffer —
            // the item text must own its bytes.
            const text = a2.dupe(u8, std.mem.trim(u8, parts.items, " \t")) catch @panic("OOM");
            out2.append(a2, .{ .indent = indent, .ordered = ordered, .text = text }) catch @panic("OOM");
            parts.clearRetainingCapacity();
        }
    }.f;

    for (lines[first..last]) |ln| {
        const t = lineText(src, ln);
        if (listMark(t)) |m| {
            flush(a, &out, &cur_parts, cur_indent, cur_ordered, have);
            cur_indent = m.indent;
            cur_ordered = m.ordered;
            cur_parts.appendSlice(a, m.content) catch @panic("OOM");
            have = true;
        } else {
            // Continuation: indented non-marker line (guaranteed by
            // the block scanner; blanks end the block).
            cur_parts.append(a, ' ') catch @panic("OOM");
            cur_parts.appendSlice(a, trim(t)) catch @panic("OOM");
        }
    }
    flush(a, &out, &cur_parts, cur_indent, cur_ordered, have);
    return out.toOwnedSlice(a) catch @panic("OOM");
}

/// Build the nested list tree from flat items: equal indent =
/// sibling, greater indent = child of the previous item, smaller =
/// dedent to the matching open level. Same-indent items of a
/// different list type (`-` then `1.`) close the level and start a
/// sibling list — matching CommonMark's list-type splitting.
fn listTree(a: std.mem.Allocator, flats: []const FlatItem) []const *LNode {
    const Frame = struct { indent: usize, list: *LNode };
    var tops: std.ArrayListUnmanaged(*LNode) = .empty;
    var stack: std.ArrayListUnmanaged(Frame) = .empty;
    var top: ?*LNode = null;

    for (flats) |f| {
        while (stack.items.len > 0) {
            const fr = stack.items[stack.items.len - 1];
            if (fr.indent > f.indent or (fr.indent == f.indent and fr.list.ordered != f.ordered)) {
                _ = stack.pop();
            } else break;
        }
        if (stack.items.len == 0) {
            // Top level: reuse the current top list when the type
            // matches, otherwise start a sibling top-level list.
            if (top) |tl| {
                if (tl.ordered != f.ordered) {
                    const nl = a.create(LNode) catch @panic("OOM");
                    nl.* = .{ .ordered = f.ordered };
                    tops.append(a, nl) catch @panic("OOM");
                    top = nl;
                }
            } else {
                const nl = a.create(LNode) catch @panic("OOM");
                nl.* = .{ .ordered = f.ordered };
                tops.append(a, nl) catch @panic("OOM");
                top = nl;
            }
            const l = top.?;
            l.items.append(a, .{ .text = f.text }) catch @panic("OOM");
            stack.append(a, .{ .indent = f.indent, .list = l }) catch @panic("OOM");
        } else {
            const fr = stack.items[stack.items.len - 1];
            if (fr.indent == f.indent) {
                // Same level, same type — the pop loop already
                // ejected type mismatches.
                fr.list.items.append(a, .{ .text = f.text }) catch @panic("OOM");
            } else {
                // fr.indent < f.indent — nest under the previous item.
                const child = a.create(LNode) catch @panic("OOM");
                child.* = .{ .ordered = f.ordered };
                const items_slice = fr.list.items.items;
                const last_item = &items_slice[items_slice.len - 1];
                last_item.kids.append(a, child) catch @panic("OOM");
                child.items.append(a, .{ .text = f.text }) catch @panic("OOM");
                stack.append(a, .{ .indent = f.indent, .list = child }) catch @panic("OOM");
            }
        }
    }
    return tops.toOwnedSlice(a) catch @panic("OOM");
}

/// Emit one list node: `<ul>` is a forest element, `<ol>` goes
/// through plugins/html.zig (forest.Tag has no ol). Items are
/// `<li>` elements whose children are inline nodes plus nested
/// lists.
fn emitListNode(a: std.mem.Allocator, node: *const LNode) forest.Node {
    var lis: std.ArrayListUnmanaged(forest.Node) = .empty;
    for (node.items.items) |*it| {
        var kids: std.ArrayListUnmanaged(forest.Node) = .empty;
        inlineInto(a, it.text, &kids, 0);
        for (it.kids.items) |child| {
            kids.append(a, emitListNode(a, child)) catch @panic("OOM");
        }
        lis.append(a, forest.el(a, .li, .{}, kids.items)) catch @panic("OOM");
    }
    if (node.ordered) return html.elNodes(a, "ol", &.{}, lis.items);
    return forest.el(a, .ul, .{}, lis.items);
}

// ── tables ───────────────────────────────────────────────────────

const Align = enum { none, left, right, center };

fn alignOf(cell: []const u8) Align {
    const s = trim(cell);
    const left = s.len > 0 and s[0] == ':';
    const right = s.len > 0 and s[s.len - 1] == ':';
    if (left and right and s.len > 1) return .center;
    if (right) return .right;
    if (left) return .left;
    return .none;
}

fn alignAttr(al: Align) ?[]const u8 {
    return switch (al) {
        .none => null,
        .left => "left",
        .right => "right",
        .center => "center",
    };
}

/// Emit a GFM pipe table: header row → `<thead><tr><th>`, delimiter
/// row supplies `align` attrs, body rows → `<tbody><tr><td>`.
/// Rows are padded/truncated to the header's column count.
fn emitTable(
    a: std.mem.Allocator,
    src: []const u8,
    lines: []const Line,
    first: usize,
    last: usize,
) forest.Node {
    const header = splitRow(a, lineText(src, lines[first]));
    const delim = splitRow(a, lineText(src, lines[first + 1]));
    const ncols = header.len;

    var head_kids: std.ArrayListUnmanaged(forest.Node) = .empty;
    for (header, 0..) |cell, ci| {
        const al = if (ci < delim.len) alignOf(delim[ci]) else .none;
        var th_kids: std.ArrayListUnmanaged(forest.Node) = .empty;
        inlineInto(a, cell, &th_kids, 0);
        head_kids.append(a, forest.el(a, .th, .{ .@"align" = alignAttr(al) }, th_kids.items)) catch @panic("OOM");
    }
    const head_tr = forest.el(a, .tr, .{}, head_kids.items);
    const thead = forest.el(a, .thead, .{}, head_tr);

    var body_rows: std.ArrayListUnmanaged(forest.Node) = .empty;
    for (lines[first + 2 .. last]) |ln| {
        const cells = splitRow(a, lineText(src, ln));
        var td_kids: std.ArrayListUnmanaged(forest.Node) = .empty;
        for (0..ncols) |ci| {
            const cell: []const u8 = if (ci < cells.len) cells[ci] else "";
            const al = if (ci < delim.len) alignOf(delim[ci]) else .none;
            var cell_kids: std.ArrayListUnmanaged(forest.Node) = .empty;
            inlineInto(a, cell, &cell_kids, 0);
            td_kids.append(a, forest.el(a, .td, .{ .@"align" = alignAttr(al) }, cell_kids.items)) catch @panic("OOM");
        }
        body_rows.append(a, forest.el(a, .tr, .{}, td_kids.items)) catch @panic("OOM");
    }
    const tbody = forest.el(a, .tbody, .{}, body_rows.items);
    return forest.el(a, .table, .{}, forest.fragment(a, .{ thead, tbody }));
}

// ── block emission ───────────────────────────────────────────────

/// Slug + id attrs for a heading: plain text → slugify → Slugger
/// dedup. Shared shape between render and headings().
fn headingId(slugger: *Slugger, a: std.mem.Allocator, text: []const u8) struct { display: []const u8, id: []const u8 } {
    const plain = plainInline(a, text);
    const display = std.mem.trim(u8, plain, " \t");
    const id = slugger.next(slugify(a, display));
    return .{ .display = display, .id = id };
}

fn emitHeading(
    a: std.mem.Allocator,
    src: []const u8,
    lines: []const Line,
    blk: Block,
    slugger: *Slugger,
) forest.Node {
    const t = lineText(src, lines[blk.first]);
    const mark = headingMark(t).?; // classifier guaranteed
    const hid = headingId(slugger, a, mark.text);
    var kids: std.ArrayListUnmanaged(forest.Node) = .empty;
    inlineInto(a, mark.text, &kids, 0);
    return html.heading(a, mark.level, &.{
        .{ .name = "id", .value = hid.id },
    }, html.renderNodes(a, kids.items));
}

fn emitQuote(
    a: std.mem.Allocator,
    src: []const u8,
    lines: []const Line,
    blk: Block,
) forest.Node {
    // Join the '>'-stripped lines with '\n' (one level only — '>>'
    // leaves a literal '>' in the text).
    var qb: std.ArrayListUnmanaged(u8) = .empty;
    for (lines[blk.first..blk.last], 0..) |ln, n| {
        var qt = lineText(src, ln);
        qt = qt[1..]; // '>'
        if (qt.len > 0 and qt[0] == ' ') qt = qt[1..];
        if (n != 0) qb.append(a, '\n') catch @panic("OOM");
        qb.appendSlice(a, qt) catch @panic("OOM");
    }
    var qkids: std.ArrayListUnmanaged(forest.Node) = .empty;
    inlineInto(a, qb.items, &qkids, 0);
    return forest.el(a, .blockquote, .{}, qkids.items);
}

/// Sanitize a fence info string into a `language-x` class suffix:
/// `[a-zA-Z0-9_+#.-]` only, max 32 chars. Empty → no class.
fn fenceLang(info: []const u8) ?[]const u8 {
    const word = std.mem.sliceTo(info, ' ');
    if (word.len == 0 or word.len > 32) return null;
    for (word) |c| {
        const ok = std.ascii.isAlphanumeric(c) or c == '_' or c == '+' or c == '#' or c == '.' or c == '-';
        if (!ok) return null;
    }
    return word;
}

fn emitFence(
    a: std.mem.Allocator,
    src: []const u8,
    lines: []const Line,
    blk: Block,
) forest.Node {
    const open = lineText(src, lines[blk.first]);
    const info = fenceOpen(open).?; // classifier guaranteed
    // Content lines: everything between the fences. When the closing
    // fence was consumed it is the last line of the block.
    var content_last = blk.last;
    if (blk.last > blk.first + 1 and fenceClose(lineText(src, lines[blk.last - 1]))) {
        content_last = blk.last - 1;
    }
    var content: []const u8 = "";
    if (blk.first + 1 < content_last) {
        content = src[lines[blk.first + 1].lo..lines[content_last - 1].hi];
    }
    // CommonMark drops the content's final newline.
    if (content.len > 0 and content[content.len - 1] == '\n') {
        content = content[0 .. content.len - 1];
        if (content.len > 0 and content[content.len - 1] == '\r')
            content = content[0 .. content.len - 1];
    }
    const lang = fenceLang(info);
    const class: ?[]const u8 = if (lang) |l| std.fmt.allocPrint(a, "language-{s}", .{l}) catch @panic("OOM") else null;
    return forest.el(a, .pre, .{}, forest.el(a, .code, .{ .class = class }, content));
}

fn emitList(
    a: std.mem.Allocator,
    src: []const u8,
    lines: []const Line,
    blk: Block,
) []const forest.Node {
    const flats = flatItems(a, src, lines, blk.first, blk.last);
    const tops = listTree(a, flats);
    var out: std.ArrayListUnmanaged(forest.Node) = .empty;
    for (tops) |tl| out.append(a, emitListNode(a, tl)) catch @panic("OOM");
    return out.items;
}

/// Render one block into `out` (doc mode wraps paragraphs in `<p>`;
/// legacy mode inlines them and re-emits inter-block gaps as text —
/// handled by the caller via prev_end).
fn emitBlock(
    a: std.mem.Allocator,
    src: []const u8,
    lines: []const Line,
    blk: Block,
    slugger: *Slugger,
    doc: bool,
    out: *std.ArrayListUnmanaged(forest.Node),
) void {
    switch (blk.kind) {
        .heading => out.append(a, emitHeading(a, src, lines, blk, slugger)) catch @panic("OOM"),
        .hr => out.append(a, forest.el(a, .hr, .{}, .{})) catch @panic("OOM"),
        .quote => out.append(a, emitQuote(a, src, lines, blk)) catch @panic("OOM"),
        .fence => out.append(a, emitFence(a, src, lines, blk)) catch @panic("OOM"),
        .table => out.append(a, emitTable(a, src, lines, blk.first, blk.last)) catch @panic("OOM"),
        .list => {
            for (emitList(a, src, lines, blk)) |n| out.append(a, n) catch @panic("OOM");
        },
        .para => {
            const blo = lines[blk.first].lo;
            const bend = lines[blk.last - 1].hi;
            var kids: std.ArrayListUnmanaged(forest.Node) = .empty;
            inlineInto(a, src[blo..bend], &kids, 0);
            if (doc) {
                out.append(a, forest.el(a, .p, .{}, kids.items)) catch @panic("OOM");
            } else {
                for (kids.items) |n| out.append(a, n) catch @panic("OOM");
            }
        },
    }
}

fn renderMode(a: std.mem.Allocator, src: []const u8, doc: bool) []const forest.Node {
    const lines = linesOf(a, src);
    const blocks = scanBlocks(a, src);
    var out: std.ArrayListUnmanaged(forest.Node) = .empty;
    var slugger = Slugger.init(a);
    var prev_end: usize = 0;
    var emitted = false;
    for (blocks) |blk| {
        const blo = lines[blk.first].lo;
        if (doc) {
            // Doc mode: a blank text node between top-level blocks
            // keeps the emitted HTML readable; it renders as
            // insignificant whitespace.
            if (emitted) out.append(a, .{ .text = "\n\n" }) catch @panic("OOM");
        } else {
            // Legacy mode: blank-line gaps between blocks re-emit
            // verbatim as text (pre-wrap renders them like source
            // newlines).
            if (emitted and prev_end < blo)
                out.append(a, .{ .text = src[prev_end..blo] }) catch @panic("OOM");
        }
        emitBlock(a, src, lines, blk, &slugger, doc, &out);
        prev_end = lines[blk.last - 1].hi;
        emitted = true;
    }
    return out.toOwnedSlice(a) catch @panic("OOM");
}

/// Board-compatible render: no `<p>` wrappers, blank-line gaps kept
/// as text — for containers styled `white-space: pre-wrap`.
pub fn render(a: std.mem.Allocator, src: []const u8) []const forest.Node {
    return renderMode(a, src, false);
}

/// Document render for long-form pages: paragraphs wrapped in `<p>`,
/// inter-block whitespace dropped. Headings carry slug `id`s (see
/// `headings` for the same ids as data).
pub fn renderBlocks(a: std.mem.Allocator, src: []const u8) []const forest.Node {
    return renderMode(a, src, true);
}

/// TOC data: every ATX heading in document order with its rendered
/// `id` (same slugify+dedup the renderer uses — call this INSTEAD of
/// re-deriving ids from the HTML).
pub const Heading = struct {
    level: u8,
    /// Plain-text label (inline markup stripped).
    text: []const u8,
    /// DOM id the renderer emits (`slug`, `slug-2`, …).
    id: []const u8,
};

pub fn headings(a: std.mem.Allocator, src: []const u8) []const Heading {
    const lines = linesOf(a, src);
    const blocks = scanBlocks(a, src);
    var out: std.ArrayListUnmanaged(Heading) = .empty;
    var slugger = Slugger.init(a);
    for (blocks) |blk| {
        if (blk.kind != .heading) continue;
        const mark = headingMark(lineText(src, lines[blk.first])).?;
        const hid = headingId(&slugger, a, mark.text);
        out.append(a, .{
            .level = mark.level,
            .text = hid.display,
            .id = hid.id,
        }) catch @panic("OOM");
    }
    return out.toOwnedSlice(a) catch @panic("OOM");
}

// ─────────────────────────────────────────────
// tests
// ─────────────────────────────────────────────

fn renderStr(alloc: std.mem.Allocator, src: []const u8) []const u8 {
    const nodes = render(alloc, src);
    var aw: std.Io.Writer.Allocating = .init(alloc);
    forest.writeHtml(alloc, nodes, &aw.writer) catch @panic("OOM");
    return aw.toOwnedSlice() catch @panic("OOM");
}

fn renderDocStr(alloc: std.mem.Allocator, src: []const u8) []const u8 {
    const nodes = renderBlocks(alloc, src);
    var aw: std.Io.Writer.Allocating = .init(alloc);
    forest.writeHtml(alloc, nodes, &aw.writer) catch @panic("OOM");
    return aw.toOwnedSlice() catch @panic("OOM");
}

test "markdown: plain text passes through unchanged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    try std.testing.expectEqualStrings("hello world", renderStr(alloc, "hello world"));
    try std.testing.expectEqualStrings("a\nb", renderStr(alloc, "a\nb"));
    try std.testing.expectEqualStrings("", renderStr(alloc, ""));
    try std.testing.expectEqualStrings("", renderStr(alloc, "\n\n"));
    // A mid-line `*` is literal (line-initial `* ` IS a bullet —
    // covered in the list test).
    try std.testing.expectEqualStrings("a * b", renderStr(alloc, "a * b"));
    try std.testing.expectEqualStrings("2 * 3 * 4", renderStr(alloc, "2 * 3 * 4"));
    try std.testing.expectEqualStrings("``", renderStr(alloc, "``"));
    try std.testing.expectEqualStrings("`unclosed", renderStr(alloc, "`unclosed"));
    try std.testing.expectEqualStrings("[x](notaurl)", renderStr(alloc, "[x](notaurl)"));
}

test "markdown: bold and italic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    try std.testing.expectEqualStrings("<strong>b</strong>", renderStr(alloc, "**b**"));
    try std.testing.expectEqualStrings("<em>i</em>", renderStr(alloc, "*i*"));
    try std.testing.expectEqualStrings("<em>i</em>", renderStr(alloc, "_i_"));
    try std.testing.expectEqualStrings("a <strong>b</strong> c", renderStr(alloc, "a **b** c"));
    try std.testing.expectEqualStrings("<strong>a <em>b</em> c</strong>", renderStr(alloc, "**a *b* c**"));
    try std.testing.expectEqualStrings("snake_case_name", renderStr(alloc, "snake_case_name"));
    try std.testing.expectEqualStrings("a<em>b</em>c", renderStr(alloc, "a*b*c"));
}

test "markdown: strikethrough renders del" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    try std.testing.expectEqualStrings("<del>s</del>", renderStr(alloc, "~~s~~"));
    try std.testing.expectEqualStrings("a <del>b</del> c", renderStr(alloc, "a ~~b~~ c"));
    try std.testing.expectEqualStrings("~one~", renderStr(alloc, "~one~")); // single ~ literal
    try std.testing.expectEqualStrings("~~ x ~~", renderStr(alloc, "~~ x ~~")); // ws edges → literal
}

test "markdown: links allow http/https, root-relative and anchors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    try std.testing.expectEqualStrings(
        "<a href=\"https://ziglang.org\" target=\"_blank\" rel=\"noopener noreferrer\">z</a>",
        renderStr(alloc, "[z](https://ziglang.org)"),
    );
    try std.testing.expectEqualStrings(
        "<a href=\"/tag/zig\" target=\"_blank\" rel=\"noopener noreferrer\">t</a>",
        renderStr(alloc, "[t](/tag/zig)"),
    );
    try std.testing.expectEqualStrings(
        "<a href=\"#sec\" target=\"_blank\" rel=\"noopener noreferrer\">a</a>",
        renderStr(alloc, "[a](#sec)"),
    );
    // Still rejected: js/data/protocol-relative/bare-relative.
    try std.testing.expectEqualStrings("[x](javascript:alert(1))", renderStr(alloc, "[x](javascript:alert(1))"));
    try std.testing.expectEqualStrings("[x](//evil.com)", renderStr(alloc, "[x](//evil.com)"));
    try std.testing.expectEqualStrings("[x](rel/path)", renderStr(alloc, "[x](rel/path)"));
    try std.testing.expectEqualStrings("[x](ftp://a)", renderStr(alloc, "[x](ftp://a)"));
}

test "markdown: images require alt and emit img" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    try std.testing.expectEqualStrings(
        "<img src=\"/i.png\" alt=\"a cat\">",
        renderStr(alloc, "![a cat](/i.png)"),
    );
    try std.testing.expectEqualStrings(
        "<img src=\"https://x/y.png\" alt=\"x\">",
        renderStr(alloc, "![x](https://x/y.png)"),
    );
    // Empty alt stays literal.
    try std.testing.expectEqualStrings("![](https://x/y.png)", renderStr(alloc, "![](https://x/y.png)"));
    // Bad scheme stays literal.
    try std.testing.expectEqualStrings("![x](javascript:1)", renderStr(alloc, "![x](javascript:1)"));
}

test "markdown: user html stays escaped" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    try std.testing.expectEqualStrings(
        "&lt;script&gt;alert(1)&lt;/script&gt;",
        renderStr(alloc, "<script>alert(1)</script>"),
    );
    try std.testing.expectEqualStrings(
        "<a href=\"https://a&quot;b\" target=\"_blank\" rel=\"noopener noreferrer\">x</a>",
        renderStr(alloc, "[x](https://a\"b)"),
    );
}

test "markdown: headings get slug ids, dedup per document" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    try std.testing.expectEqualStrings(
        "<h2 id=\"hello-world\">Hello World</h2>",
        renderDocStr(alloc, "## Hello World"),
    );
    try std.testing.expectEqualStrings(
        "<h1 id=\"zig-in-2026\">Zig in 2026</h1>",
        renderDocStr(alloc, "# Zig in 2026"),
    );
    // Inline markup stripped from slug; closing hashes ignored.
    try std.testing.expectEqualStrings(
        "<h3 id=\"deep-dive\">deep <em>dive</em></h3>",
        renderDocStr(alloc, "### deep *dive* ##"),
    );
    // Dedup within one render.
    try std.testing.expectEqualStrings(
        "<h2 id=\"same\">Same</h2>\n\n<h2 id=\"same-2\">Same</h2>",
        renderDocStr(alloc, "## Same\n\n## Same"),
    );
    // cyrillic heading → transliterated slug.
    try std.testing.expectEqualStrings(
        "<h2 id=\"privet-mir\">Привет, мир!</h2>",
        renderDocStr(alloc, "## Привет, мир!"),
    );
}

test "markdown: headings() agrees with rendered ids" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const src = "# T\n\ntext\n\n## T\n\n### deep *x*\n";
    const hs = headings(alloc, src);
    try std.testing.expectEqual(@as(usize, 3), hs.len);
    try std.testing.expectEqual(@as(u8, 1), hs[0].level);
    try std.testing.expectEqualStrings("t", hs[0].id);
    try std.testing.expectEqualStrings("t-2", hs[1].id);
    try std.testing.expectEqualStrings("deep-x", hs[2].id);
    try std.testing.expectEqualStrings("deep x", hs[2].text);

    // Rendered HTML contains the same ids in order.
    const html_str = renderDocStr(alloc, src);
    try std.testing.expect(std.mem.indexOf(u8, html_str, "id=\"t\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html_str, "id=\"t-2\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html_str, "id=\"deep-x\"") != null);
}

test "markdown: doc mode wraps paragraphs, drops gap text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    try std.testing.expectEqualStrings("<p>a</p>\n\n<p>b</p>", renderDocStr(alloc, "a\n\nb"));
    // Legacy mode: no <p>, gap preserved as text.
    try std.testing.expectEqualStrings("a\n\nb", renderStr(alloc, "a\n\nb"));
    // Single newlines inside a paragraph collapse in doc mode HTML.
    try std.testing.expectEqualStrings("<p>a\nb</p>", renderDocStr(alloc, "a\nb"));
}

test "markdown: unordered and ordered lists, nested" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    try std.testing.expectEqualStrings(
        "<ul><li>a</li><li>b</li></ul>",
        renderDocStr(alloc, "- a\n- b"),
    );
    try std.testing.expectEqualStrings(
        "<ol><li>a</li><li>b</li></ol>",
        renderDocStr(alloc, "1. a\n2. b"),
    );
    // `*` is a bullet marker too (line-initial `* `).
    try std.testing.expectEqualStrings(
        "<ul><li>x</li></ul>",
        renderDocStr(alloc, "* x"),
    );
    // Nesting by indent.
    try std.testing.expectEqualStrings(
        "<ul><li>a<ul><li>x</li><li>y</li></ul></li><li>b</li></ul>",
        renderDocStr(alloc, "- a\n  - x\n  - y\n- b"),
    );
    // Ordered nested in unordered.
    try std.testing.expectEqualStrings(
        "<ul><li>a<ol><li>x</li></ol></li></ul>",
        renderDocStr(alloc, "- a\n  1. x"),
    );
    // Mixed types at same indent split into sibling lists.
    try std.testing.expectEqualStrings(
        "<ul><li>a</li></ul><ol><li>b</li></ol>",
        renderDocStr(alloc, "- a\n1. b"),
    );
    // Continuation lines join the item text.
    try std.testing.expectEqualStrings(
        "<ul><li>a b c</li></ul>",
        renderDocStr(alloc, "- a\n  b\n  c"),
    );
    // Inline markup inside items.
    try std.testing.expectEqualStrings(
        "<ul><li><strong>x</strong></li></ul>",
        renderDocStr(alloc, "- **x**"),
    );
    // List ends at blank + unindented text.
    try std.testing.expectEqualStrings(
        "<ul><li>a</li></ul>\n\n<p>after</p>",
        renderDocStr(alloc, "- a\n\nafter"),
    );
}

test "markdown: fenced code with language class" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    try std.testing.expectEqualStrings(
        "<pre><code class=\"language-zig\">fn main() {}</code></pre>",
        renderDocStr(alloc, "```zig\nfn main() {}\n```"),
    );
    // No info → no class.
    try std.testing.expectEqualStrings(
        "<pre><code>x</code></pre>",
        renderDocStr(alloc, "```\nx\n```"),
    );
    // Content escaped.
    try std.testing.expectEqualStrings(
        "<pre><code class=\"language-html\">&lt;b&gt;</code></pre>",
        renderDocStr(alloc, "```html\n<b>\n```"),
    );
    // Unterminated fence runs to EOF.
    try std.testing.expectEqualStrings(
        "<pre><code>code</code></pre>",
        renderDocStr(alloc, "```\ncode"),
    );
}

test "markdown: pipe tables" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    try std.testing.expectEqualStrings(
        "<table><thead><tr><th>a</th><th align=\"right\">b</th></tr></thead><tbody><tr><td>1</td><td align=\"right\">2</td></tr></tbody></table>",
        renderDocStr(alloc, "| a | b |\n| --- | ---: |\n| 1 | 2 |"),
    );
    // No outer pipes needed.
    try std.testing.expectEqualStrings(
        "<table><thead><tr><th>a</th><th>b</th></tr></thead><tbody><tr><td>1</td><td>2</td></tr></tbody></table>",
        renderDocStr(alloc, "a | b\n- | -\n1 | 2"),
    );
    // Inline markup in cells.
    try std.testing.expectEqualStrings(
        "<table><thead><tr><th><strong>a</strong></th></tr></thead><tbody><tr><td>x</td></tr></tbody></table>",
        renderDocStr(alloc, "| **a** |\n| --- |\n| x |"),
    );
    // Short rows pad to header width.
    try std.testing.expectEqualStrings(
        "<table><thead><tr><th>a</th><th>b</th></tr></thead><tbody><tr><td>1</td><td></td></tr></tbody></table>",
        renderDocStr(alloc, "| a | b |\n| --- | --- |\n| 1 |"),
    );
}

test "markdown: hr and blockquote" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    try std.testing.expectEqualStrings("<hr>", renderDocStr(alloc, "---"));
    try std.testing.expectEqualStrings("<hr>", renderDocStr(alloc, "* * *"));
    try std.testing.expectEqualStrings(
        "<blockquote>a\nb</blockquote>",
        renderDocStr(alloc, "> a\n> b"),
    );
    try std.testing.expectEqualStrings(
        "<blockquote><strong>x</strong></blockquote>",
        renderDocStr(alloc, "> **x**"),
    );
}

test "markdown: slugify transliterates and filters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    try std.testing.expectEqualStrings("hello-world", slugify(alloc, "Hello World"));
    try std.testing.expectEqualStrings("privet-mir", slugify(alloc, "Привет, мир"));
    try std.testing.expectEqualStrings("zig-i-rust", slugify(alloc, "Zig и Rust")); // и→i
    try std.testing.expectEqualStrings("schyotka", slugify(alloc, "Щётка")); // щ→sch ё→yo
    try std.testing.expectEqualStrings("section", slugify(alloc, "!!!"));
    try std.testing.expectEqualStrings("a-b-c", slugify(alloc, "a - b - c"));
    try std.testing.expectEqualStrings("no-leading", slugify(alloc, "--no--leading--"));
}
