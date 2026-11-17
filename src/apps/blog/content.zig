//! content — markdown-file CMS for zblog. Posts live in
//! `content/posts/*.md`, static pages in `content/pages/*.md`, both
//! with a hand-rolled YAML-subset frontmatter (no yaml dep):
//!
//!   ---
//!   title: Заголовок
//!   date: 2026-11-17
//!   tags: zig, meta-framework, seo
//!   description: Краткое описание для meta/OG/RSS
//!   slug: custom-slug        (optional — default: filename)
//!   draft: false             (optional — drafts are skipped at load)
//!   ---
//!   # Markdown body…
//!
//! Frontmatter rules: the file must OPEN with a `---` line and close
//! with a second `---` line; `key: value` pairs only (unknown keys
//! ignored); `tags` is comma-separated and each tag is slugified
//! (lowercase + [a-z0-9-], Cyrillic transliterated — see
//! plugins/markdown.zig `slugify`). `date` is `YYYY-MM-DD` (validated
//! loosely — calendar correctness is the RSS layer's problem).
//! Everything after the closing fence is the markdown body.
//!
//! Slugs: filename (minus .md) or the `slug:` field, run through
//! `markdown.slugify` — output is always URL-safe `[a-z0-9-]`, which
//! is what makes `[slug]`/`[tag]` route params safe to slice raw.
const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const markdown = @import("zplug_markdown");

pub const Post = struct {
    /// URL slug — slugified, unique within the loaded set is NOT
    /// enforced (duplicate slugs → first match wins in findPost).
    slug: []const u8,
    title: []const u8,
    /// "YYYY-MM-DD" or "" when absent/invalid — sorts LAST desc.
    date: []const u8,
    /// Slugified tags (already URL-safe, lowercase).
    tags: []const []const u8,
    /// Frontmatter `description:` or "" — meta/OG/RSS fallback is
    /// `description orelse excerpt`.
    description: []const u8,
    /// Frontmatter `author:` or "" — shown in the post header +
    /// JSON-LD author.name (falls back to site author at render).
    author: []const u8 = "",
    /// Markdown body (after the frontmatter fence).
    body: []const u8,
    /// ~160-char plain-text excerpt of the body's first paragraph —
    /// used for meta description / RSS description fallbacks.
    excerpt: []const u8,
    /// Frontmatter `draft:` — `load` drops these; parsePost keeps the
    /// flag so tests can inspect it.
    draft: bool = false,
    /// Source filename, for debugging.
    file: []const u8,
};

pub const Page = struct {
    slug: []const u8,
    title: []const u8,
    description: []const u8,
    body: []const u8,
};

pub const Content = struct {
    posts: []const Post,
    pages: []const Page,
};

// ── frontmatter ──────────────────────────────────────────────────

pub const Frontmatter = struct {
    title: ?[]const u8 = null,
    date: ?[]const u8 = null,
    author: ?[]const u8 = null,
    tags: []const []const u8 = &.{},
    description: ?[]const u8 = null,
    slug: ?[]const u8 = null,
    draft: bool = false,
    /// Markdown source after the closing `---` fence (or the whole
    /// input when there is no frontmatter).
    body: []const u8,
};

fn isFenceLine(t: []const u8) bool {
    return std.mem.eql(u8, std.mem.trim(u8, t, " \t\r"), "---");
}

const Line = struct { lo: usize, hi: usize };

/// Split `src` into lines as (start,end) offsets INCLUDING the '\n'
/// in `hi` when present, so `body` slicing stays verbatim.
fn splitLines(a: std.mem.Allocator, src: []const u8) []const Line {
    var out: std.ArrayListUnmanaged(Line) = .empty;
    var off: usize = 0;
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |raw| {
        const hi = off + raw.len + @intFromBool(off + raw.len < src.len);
        out.append(a, .{ .lo = off, .hi = hi }) catch @panic("OOM");
        off = hi;
    }
    return out.toOwnedSlice(a) catch @panic("OOM");
}

fn lineSlice(src: []const u8, lo: usize, hi: usize) []const u8 {
    var s = src[lo..hi];
    if (s.len > 0 and s[s.len - 1] == '\n') s = s[0 .. s.len - 1];
    if (s.len > 0 and s[s.len - 1] == '\r') s = s[0 .. s.len - 1];
    return s;
}

/// Parse the `---`-fenced frontmatter subset. Never fails: malformed
/// input degrades to "no frontmatter" (whole src is the body) or
/// ignored keys — content files are trusted-ish but a typo shouldn't
/// 500 the blog.
pub fn parseFrontmatter(a: std.mem.Allocator, src: []const u8) Frontmatter {
    var fm: Frontmatter = .{ .body = src };
    const lines = splitLines(a, src);
    if (lines.len < 2) return fm;
    if (!isFenceLine(lineSlice(src, lines[0].lo, lines[0].hi))) return fm;

    // Find the closing fence.
    var close: ?usize = null;
    var i: usize = 1;
    while (i < lines.len) : (i += 1) {
        if (isFenceLine(lineSlice(src, lines[i].lo, lines[i].hi))) {
            close = i;
            break;
        }
    }
    const end = close orelse return fm; // unclosed fence → no frontmatter
    fm.body = src[lines[end].hi..];

    var tags: std.ArrayListUnmanaged([]const u8) = .empty;
    for (lines[1..end]) |ln| {
        const t = lineSlice(src, ln.lo, ln.hi);
        if (isBlankLine(t)) continue;
        const colon = std.mem.indexOfScalar(u8, t, ':') orelse continue;
        const key = std.mem.trim(u8, t[0..colon], " \t");
        const value = std.mem.trim(u8, t[colon + 1 ..], " \t");
        if (std.mem.eql(u8, key, "title")) {
            fm.title = value;
        } else if (std.mem.eql(u8, key, "date")) {
            fm.date = value;
        } else if (std.mem.eql(u8, key, "author")) {
            fm.author = value;
        } else if (std.mem.eql(u8, key, "description")) {
            fm.description = value;
        } else if (std.mem.eql(u8, key, "slug")) {
            fm.slug = value;
        } else if (std.mem.eql(u8, key, "draft")) {
            fm.draft = std.mem.eql(u8, value, "true") or
                std.mem.eql(u8, value, "yes") or
                std.mem.eql(u8, value, "1");
        } else if (std.mem.eql(u8, key, "tags")) {
            var it = std.mem.splitScalar(u8, value, ',');
            while (it.next()) |raw_tag| {
                const tag = markdown.slugify(a, std.mem.trim(u8, raw_tag, " \t"));
                if (std.mem.eql(u8, tag, "section")) continue; // slugify's empty-marker
                var dup = false;
                for (tags.items) |existing| {
                    if (std.mem.eql(u8, existing, tag)) dup = true;
                }
                if (!dup) tags.append(a, tag) catch @panic("OOM");
            }
        }
        // Unknown keys ignored.
    }
    fm.tags = tags.items;
    return fm;
}

fn isBlankLine(t: []const u8) bool {
    for (t) |c| if (c != ' ' and c != '\t' and c != '\r') return false;
    return true;
}

// ── excerpts ─────────────────────────────────────────────────────

const excerpt_max = 160;

/// ~160-char plain-text excerpt: first paragraph of the body,
/// inline markup stripped via `markdown.plainInline`, whitespace
/// collapsed, truncated at a word boundary on a UTF-8 char edge.
pub fn makeExcerpt(a: std.mem.Allocator, body: []const u8) []const u8 {
    // First paragraph = up to the first blank line.
    var end = body.len;
    var it = std.mem.splitScalar(u8, body, '\n');
    var off: usize = 0;
    var seen_content = false;
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) {
            if (seen_content) {
                end = off;
                break;
            }
        } else seen_content = true;
        off += raw.len + 1;
    }
    const para = std.mem.trim(u8, body[0..@min(end, body.len)], " \t\r\n");
    if (para.len == 0) return "";
    const plain = markdown.plainInline(a, para);

    // Collapse all whitespace runs to single spaces.
    var norm: std.ArrayListUnmanaged(u8) = .empty;
    var ws = false;
    for (plain) |c| {
        if (std.ascii.isWhitespace(c)) {
            ws = true;
        } else {
            if (ws and norm.items.len > 0) norm.append(a, ' ') catch @panic("OOM");
            ws = false;
            norm.append(a, c) catch @panic("OOM");
        }
    }
    var s = norm.items;
    if (s.len <= excerpt_max) return s;
    // Truncate at a UTF-8 boundary then back off to the last space.
    var cut: usize = excerpt_max;
    while (cut > 0 and (s[cut] & 0xC0) == 0x80) cut -= 1;
    s = s[0..cut];
    if (std.mem.lastIndexOfScalar(u8, s, ' ')) |sp| {
        if (sp > excerpt_max / 2) s = s[0..sp];
    }
    return s;
}

// ── parsing entries ──────────────────────────────────────────────

/// `YYYY-MM-DD` shape + range check (month 1–12, day 1–31 — full
/// calendar validation like Feb-30 is left to the RSS layer).
pub fn validDate(s: []const u8) bool {
    if (s.len != 10) return false;
    for (s, 0..) |c, i| {
        switch (i) {
            4, 7 => if (c != '-') return false,
            else => if (!std.ascii.isDigit(c)) return false,
        }
    }
    const m = std.fmt.parseInt(u32, s[5..7], 10) catch return false;
    const d = std.fmt.parseInt(u32, s[8..10], 10) catch return false;
    return m >= 1 and m <= 12 and d >= 1 and d <= 31;
}

/// `content/posts/<file>.md` source → Post. `file_name` is the bare
/// filename (used for the default slug + `file` debug field).
pub fn parsePost(a: std.mem.Allocator, file_name: []const u8, src: []const u8) Post {
    const fm = parseFrontmatter(a, src);
    const base = if (std.mem.endsWith(u8, file_name, ".md"))
        file_name[0 .. file_name.len - 3]
    else
        file_name;
    const slug_src = fm.slug orelse base;
    var slug = markdown.slugify(a, slug_src);
    if (std.mem.eql(u8, slug, "section") and slug_src.len == 0) slug = "post";
    const title = fm.title orelse base;
    const date = if (fm.date) |d| (if (validDate(d)) d else "") else "";
    return .{
        .slug = slug,
        .title = title,
        .date = date,
        .tags = fm.tags,
        .description = fm.description orelse "",
        .author = fm.author orelse "",
        .body = fm.body,
        .excerpt = makeExcerpt(a, fm.body),
        .draft = fm.draft,
        .file = file_name,
    };
}

/// `content/pages/<file>.md` source → Page (same frontmatter, no
/// date/tags/draft semantics — unknown keys still ignored).
pub fn parsePage(a: std.mem.Allocator, file_name: []const u8, src: []const u8) Page {
    const fm = parseFrontmatter(a, src);
    const base = if (std.mem.endsWith(u8, file_name, ".md"))
        file_name[0 .. file_name.len - 3]
    else
        file_name;
    return .{
        .slug = markdown.slugify(a, base),
        .title = fm.title orelse base,
        .description = fm.description orelse "",
        .body = fm.body,
    };
}

// ── loading ──────────────────────────────────────────────────────

fn loadDir(
    a: std.mem.Allocator,
    io: Io,
    dir_path: []const u8,
    comptime kind: enum { post, page },
    out: anytype,
) !void {
    var dir = Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return, // optional dir — empty is fine
        else => |e| return e,
    };
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const name = entry.name;
        if (!std.mem.endsWith(u8, name, ".md")) continue;
        if (name.len <= 3) continue; // ".md" alone
        const path = try std.fmt.allocPrint(a, "{s}/{s}", .{ dir_path, name });
        const src = try Dir.cwd().readFileAlloc(io, path, a, .limited(1 << 20));
        switch (kind) {
            .post => {
                const p = parsePost(a, name, src);
                if (p.slug.len == 0) continue;
                if (p.draft) continue; // drafts never reach Content
                try out.append(a, p);
            },
            .page => try out.append(a, parsePage(a, name, src)),
        }
    }
}

const PostCtx = struct {
    fn lt(_: void, x: Post, y: Post) bool {
        // Date descending; empty dates sort last; slug tiebreak.
        const xd = x.date.len != 0;
        const yd = y.date.len != 0;
        if (xd != yd) return xd;
        const ord = std.mem.order(u8, x.date, y.date);
        if (ord == .gt) return true;
        if (ord == .lt) return false;
        return std.mem.order(u8, x.slug, y.slug) == .lt;
    }
};

/// Scan `<dir>/posts/*.md` + `<dir>/pages/*.md`, parse, sort posts
/// by date desc. `dir` is app-relative ("src/apps/blog/content").
pub fn load(a: std.mem.Allocator, io: Io, dir_path: []const u8) !Content {
    var posts: std.ArrayListUnmanaged(Post) = .empty;
    var pages: std.ArrayListUnmanaged(Page) = .empty;
    const posts_dir = try std.fmt.allocPrint(a, "{s}/posts", .{dir_path});
    const pages_dir = try std.fmt.allocPrint(a, "{s}/pages", .{dir_path});
    try loadDir(a, io, posts_dir, .post, &posts);
    try loadDir(a, io, pages_dir, .page, &pages);
    std.mem.sort(Post, posts.items, {}, PostCtx.lt);
    return .{
        .posts = posts.items,
        .pages = pages.items,
    };
}

// ── queries ──────────────────────────────────────────────────────

pub fn findPost(c: *const Content, slug: []const u8) ?Post {
    for (c.posts) |p| {
        if (std.mem.eql(u8, p.slug, slug)) return p;
    }
    return null;
}

pub fn findPage(c: *const Content, slug: []const u8) ?Page {
    for (c.pages) |p| {
        if (std.mem.eql(u8, p.slug, slug)) return p;
    }
    return null;
}

/// Non-allocating membership check — for `prepare` gates that can't
/// take an allocator.
pub fn hasTag(c: *const Content, tag: []const u8) bool {
    for (c.posts) |p| {
        for (p.tags) |t| {
            if (std.mem.eql(u8, t, tag)) return true;
        }
    }
    return false;
}

/// Posts carrying `tag` (already-slugified tag string), date desc —
/// the loaded order is preserved.
pub fn postsTagged(a: std.mem.Allocator, c: *const Content, tag: []const u8) []const Post {
    var out: std.ArrayListUnmanaged(Post) = .empty;
    for (c.posts) |p| {
        for (p.tags) |t| {
            if (std.mem.eql(u8, t, tag)) {
                out.append(a, p) catch @panic("OOM");
                break;
            }
        }
    }
    return out.items;
}

/// Unicode-lite lowercase for search: ASCII lowercased, Cyrillic
/// uppercase (U+0410–U+042F, Ё) mapped down — everything else copied
/// verbatim. Two-byte UTF-8 sequences pass through unchanged.
fn lowerInto(a: std.mem.Allocator, s: []const u8) []const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        const b = s[i];
        if (b < 0x80) {
            out.append(a, std.ascii.toLower(b)) catch @panic("OOM");
            i += 1;
            continue;
        }
        if ((b == 0xD0 or b == 0xD1) and i + 1 < s.len) {
            const cp: u32 = (@as(u32, b & 0x1F) << 6) | @as(u32, s[i + 1] & 0x3F);
            if (cp >= 0x0410 and cp <= 0x042F) {
                const lo = cp + 0x20;
                out.append(a, @intCast(0xC0 | (lo >> 6))) catch @panic("OOM");
                out.append(a, @intCast(0x80 | (lo & 0x3F))) catch @panic("OOM");
                i += 2;
                continue;
            }
            if (cp == 0x0401) { // Ё → ё (U+0451)
                out.append(a, 0xD1) catch @panic("OOM");
                out.append(a, 0x91) catch @panic("OOM");
                i += 2;
                continue;
            }
        }
        out.append(a, b) catch @panic("OOM");
        i += 1;
    }
    return out.items;
}

/// Case-insensitive substring search over title + tags + excerpt +
/// description (superset of the spec's title+tags+excerpt — the
/// description usually IS the excerpt's sibling). Cyrillic-aware
/// lowercase on both sides.
pub fn searchPosts(a: std.mem.Allocator, c: *const Content, q_raw: []const u8) []const Post {
    const q = std.mem.trim(u8, q_raw, " \t");
    if (q.len == 0) return c.posts;
    const needle = lowerInto(a, q);
    var out: std.ArrayListUnmanaged(Post) = .empty;
    for (c.posts) |p| {
        var hay: std.ArrayListUnmanaged(u8) = .empty;
        hay.appendSlice(a, p.title) catch @panic("OOM");
        hay.append(a, ' ') catch @panic("OOM");
        for (p.tags) |t| {
            hay.appendSlice(a, t) catch @panic("OOM");
            hay.append(a, ' ') catch @panic("OOM");
        }
        hay.appendSlice(a, p.excerpt) catch @panic("OOM");
        hay.append(a, ' ') catch @panic("OOM");
        hay.appendSlice(a, p.description) catch @panic("OOM");
        const lowered = lowerInto(a, hay.items);
        if (std.mem.indexOf(u8, lowered, needle) != null) {
            out.append(a, p) catch @panic("OOM");
        }
    }
    return out.items;
}

// ── pagination ───────────────────────────────────────────────────

pub const page_size = 5;

pub const PageSlice = struct {
    items: []const Post,
    /// 1-based current page (clamped into [1, pages]).
    page: usize,
    /// Total pages (>= 1 even for an empty list).
    pages: usize,
};

/// Slice `posts` into `page_size`-sized pages. `page_req` is the raw
/// `?page=` value (1-based); out-of-range requests clamp — the
/// caller uses the returned `page` for canonicals/links so `?page=99`
/// renders the last page under its own canonical.
pub fn paginate(a: std.mem.Allocator, posts: []const Post, page_req: usize) PageSlice {
    const pages = @max(@as(usize, 1), (posts.len + page_size - 1) / page_size);
    const page = @min(@max(page_req, 1), pages);
    const start = (page - 1) * page_size;
    const end = @min(start + page_size, posts.len);
    _ = a;
    return .{
        .items = if (start < posts.len) posts[start..end] else &.{},
        .page = page,
        .pages = pages,
    };
}

// ─────────────────────────────────────────────
// tests
// ─────────────────────────────────────────────

fn parseOne(a: std.mem.Allocator, name: []const u8, src: []const u8) Post {
    return parsePost(a, name, src);
}

test "frontmatter: full and minimal parses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const full =
        \\---
        \\title: Заголовок
        \\date: 2026-11-17
        \\tags: zig, Meta-Framework, zig
        \\description: Описание поста
        \\slug: custom-slug
        \\draft: false
        \\---
        \\# Body here
        \\
    ;
    const fm = parseFrontmatter(a, full);
    try std.testing.expectEqualStrings("Заголовок", fm.title.?);
    try std.testing.expectEqualStrings("2026-11-17", fm.date.?);
    try std.testing.expectEqualStrings("Описание поста", fm.description.?);
    try std.testing.expectEqualStrings("custom-slug", fm.slug.?);
    try std.testing.expect(!fm.draft);
    try std.testing.expectEqual(@as(usize, 2), fm.tags.len); // "zig" deduped
    try std.testing.expectEqualStrings("zig", fm.tags[0]);
    try std.testing.expectEqualStrings("meta-framework", fm.tags[1]);
    try std.testing.expectEqualStrings("# Body here\n", fm.body);

    // No frontmatter at all → whole src is body.
    const plain = parseFrontmatter(a, "# just markdown\n");
    try std.testing.expect(plain.title == null);
    try std.testing.expectEqualStrings("# just markdown\n", plain.body);

    // Unclosed fence → treated as no frontmatter.
    const unclosed = parseFrontmatter(a, "---\ntitle: x\nbody");
    try std.testing.expect(unclosed.title == null);
}

test "frontmatter: draft flag variants" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try std.testing.expect(parseFrontmatter(a, "---\ndraft: true\n---\nx").draft);
    try std.testing.expect(parseFrontmatter(a, "---\ndraft: yes\n---\nx").draft);
    try std.testing.expect(parseFrontmatter(a, "---\ndraft: 1\n---\nx").draft);
    try std.testing.expect(!parseFrontmatter(a, "---\ndraft: false\n---\nx").draft);
    try std.testing.expect(!parseFrontmatter(a, "---\ndraft:\n---\nx").draft);
}

test "parsePost: slug/title/date defaults and excerpt" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const p = parseOne(a, "pervy-post.md", "---\ntitle: T\ndate: 2026-01-05\n---\n\nFirst **para** text.\n\nSecond para.\n");
    try std.testing.expectEqualStrings("pervy-post", p.slug);
    try std.testing.expectEqualStrings("T", p.title);
    try std.testing.expectEqualStrings("2026-01-05", p.date);
    try std.testing.expectEqualStrings("First para text.", p.excerpt);

    // No title → filename base; bad date → "".
    const p2 = parseOne(a, "drugoy.md", "---\ndate: 2026-13-99\n---\nbody\n");
    try std.testing.expectEqualStrings("drugoy", p2.title);
    try std.testing.expectEqualStrings("", p2.date);
    try std.testing.expect(!validDate("2026-13-99"));
    try std.testing.expect(validDate("2026-02-28"));

    // Cyrillic filename → transliterated slug.
    const p3 = parseOne(a, "pervyy-post.md", "---\ntitle: Привет\n---\ntext\n");
    try std.testing.expectEqualStrings("pervyy-post", p3.slug);
}

test "excerpt: truncates long first paragraph at word boundary" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var buf: [1024]u8 = undefined;
    const word = "оченьдлинноеслово";
    var w = std.Io.Writer.fixed(&buf);
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        w.writeAll(word) catch unreachable;
        w.writeByte(' ') catch unreachable;
    }
    const long = buf[0..w.end];
    const ex = makeExcerpt(a, long);
    try std.testing.expect(ex.len <= excerpt_max);
    try std.testing.expect(std.mem.endsWith(u8, ex, "оченьдлинноеслово") == false or ex.len < excerpt_max);
}

test "searchPosts: case-insensitive incl cyrillic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const posts = [_]Post{
        parseOne(a, "a.md", "---\ntitle: Zig и zmeta\ntags: zig, ssr\n---\nПро серверный рендеринг.\n"),
        parseOne(a, "b.md", "---\ntitle: Совсем другое\ntags: css\n---\nТекст про стили.\n"),
    };
    const c = Content{ .posts = &posts, .pages = &.{} };

    try std.testing.expectEqual(@as(usize, 1), searchPosts(a, &c, "ZIG").len);
    try std.testing.expectEqual(@as(usize, 1), searchPosts(a, &c, "и ZMETA").len); // cyrillic needle
    try std.testing.expectEqual(@as(usize, 1), searchPosts(a, &c, "РЕНДЕРИНГ").len); // cyrillic haystack upper query
    try std.testing.expectEqual(@as(usize, 0), searchPosts(a, &c, "nomatch").len);
    try std.testing.expectEqual(@as(usize, 2), searchPosts(a, &c, "").len);
    // Tag search.
    try std.testing.expectEqual(@as(usize, 1), searchPosts(a, &c, "ssr").len);
}

test "markdown plugin: slugify cyrillic headings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The exact strings from the sample posts — regression cover for
    // the transliteration table (plugin-module tests don't run under
    // `zig build test`, so this lives here where zplug_markdown is
    // already imported).
    try std.testing.expectEqualStrings("zachem", markdown.slugify(a, "зачем"));
    try std.testing.expectEqualStrings("abv", markdown.slugify(a, "абв"));
    try std.testing.expectEqualStrings("zachem-eschyo-odin-blog", markdown.slugify(a, "Зачем ещё один блог"));
    try std.testing.expectEqualStrings("arkhitektura-v-dvukh-slovakh", markdown.slugify(a, "Архитектура в двух словах"));
    try std.testing.expectEqualStrings("chto-dayot-zmeta", markdown.slugify(a, "Что даёт zmeta"));
    try std.testing.expectEqualStrings("proizvoditelnost", markdown.slugify(a, "Производительность"));
    try std.testing.expectEqualStrings("chto-dalshe", markdown.slugify(a, "Что дальше"));
    // plainInline must not mangle cyrillic either.
    try std.testing.expectEqualStrings("Зачем ещё один блог", markdown.plainInline(a, "Зачем ещё один блог"));
}

test "postsTagged + paginate bounds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var posts: std.ArrayListUnmanaged(Post) = .empty;
    for (0..12) |i| {
        const name = try std.fmt.allocPrint(a, "p{d}.md", .{i});
        posts.append(a, parseOne(a, name, try std.fmt.allocPrint(a, "---\ntitle: P{d}\ndate: 2026-01-{d:0>2}\ntags: t{d}\n---\nx\n", .{ i, i + 1, i % 2 }))) catch @panic("OOM");
    }
    std.mem.sort(Post, posts.items, {}, PostCtx.lt); // load() does this too
    const c = Content{ .posts = posts.items, .pages = &.{} };

    const tagged = postsTagged(a, &c, "t0");
    try std.testing.expectEqual(@as(usize, 6), tagged.len);

    const pg1 = paginate(a, c.posts, 1);
    try std.testing.expectEqual(@as(usize, 5), pg1.items.len);
    try std.testing.expectEqual(@as(usize, 1), pg1.page);
    try std.testing.expectEqual(@as(usize, 3), pg1.pages);
    const pg3 = paginate(a, c.posts, 3);
    try std.testing.expectEqual(@as(usize, 2), pg3.items.len);
    // Out-of-range clamps to last page.
    const pg99 = paginate(a, c.posts, 99);
    try std.testing.expectEqual(@as(usize, 3), pg99.page);
    try std.testing.expectEqual(@as(usize, 2), pg99.items.len);
    // Page 0 clamps to 1.
    try std.testing.expectEqual(@as(usize, 1), paginate(a, c.posts, 0).page);
    // Empty list → 1 page, 0 items.
    const empty = paginate(a, &.{}, 5);
    try std.testing.expectEqual(@as(usize, 1), empty.pages);
    try std.testing.expectEqual(@as(usize, 0), empty.items.len);

    // Sort check: dates descending.
    try std.testing.expectEqualStrings("2026-01-12", c.posts[0].date);
}
