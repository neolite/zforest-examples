//! seo — helpers for `zmeta.HeadSpec.extra`: the RAW HTML a page
//! injects before `</head>` (meta description, Open Graph/Twitter
//! cards, canonical links, JSON-LD). Everything here allocates in the
//! caller's arena and returns `[]const u8` for concatenation into
//! `HeadSpec.extra`.
//!
//! Safety: meta/link attribute values are HTML-escaped; JSON-LD
//! strings get JSON escaping with `<`/`>`/`&` → \uXXXX so a payload
//! can never break out of the <script> element. HeadSpec.extra is
//! emitted verbatim — these helpers are the escaping boundary.
const std = @import("std");
const forest = @import("forest");

// ── meta / link tags ─────────────────────────────────────────────

/// `<meta name="{name}" content="{content}">` — content HTML-escaped.
pub fn metaName(a: std.mem.Allocator, name: []const u8, content: []const u8) []const u8 {
    return tag(a, "meta", &.{
        .{ .name = "name", .value = name },
        .{ .name = "content", .value = content },
    });
}

/// `<meta property="{prop}" content="{content}">` — Open Graph and
/// `article:*` tags ride the `property` attribute.
pub fn metaProperty(a: std.mem.Allocator, prop: []const u8, content: []const u8) []const u8 {
    return tag(a, "meta", &.{
        .{ .name = "property", .value = prop },
        .{ .name = "content", .value = content },
    });
}

/// `<meta http-equiv="..." content="...">`.
pub fn metaHttpEquiv(a: std.mem.Allocator, equiv: []const u8, content: []const u8) []const u8 {
    return tag(a, "meta", &.{
        .{ .name = "http-equiv", .value = equiv },
        .{ .name = "content", .value = content },
    });
}

/// `<link rel="{rel}" href="{href}">` — canonical, next, prev,
/// alternate. `href` HTML-escaped (absolute URLs are expected).
pub fn linkTag(a: std.mem.Allocator, rel: []const u8, href: []const u8) []const u8 {
    return tag(a, "link", &.{
        .{ .name = "rel", .value = rel },
        .{ .name = "href", .value = href },
    });
}

/// `<link rel="canonical" href="{url}">`.
pub fn linkCanonical(a: std.mem.Allocator, url: []const u8) []const u8 {
    return linkTag(a, "canonical", url);
}

const TagAttr = struct { name: []const u8, value: ?[]const u8 = null };

/// Void-element serializer shared by the tag helpers above —
/// `<name attr="v" …>` with attr values HTML-escaped. Private: tag
/// and attr names are comptime literals at every call site.
fn tag(a: std.mem.Allocator, comptime name: []const u8, attrs: []const TagAttr) []const u8 {
    var aw: std.Io.Writer.Allocating = .init(a);
    const w = &aw.writer;
    w.writeByte('<') catch @panic("OOM");
    w.writeAll(name) catch @panic("OOM");
    for (attrs) |at| {
        w.writeByte(' ') catch @panic("OOM");
        w.writeAll(at.name) catch @panic("OOM");
        if (at.value) |v| {
            w.writeAll("=\"") catch @panic("OOM");
            forest.escapeHtmlInto(w, v) catch @panic("OOM");
            w.writeByte('"') catch @panic("OOM");
        }
    }
    w.writeAll("/>") catch @panic("OOM");
    w.writeByte('\n') catch @panic("OOM");
    return aw.toOwnedSlice() catch @panic("OOM");
}

// ── JSON ─────────────────────────────────────────────────────────

/// Minimal JSON value for hand-built structured data (JSON-LD).
/// Strings are emitted with script-safe escaping; there is no float
/// variant — dates/times belong in strings anyway.
pub const J = union(enum) {
    null,
    boolean: bool,
    integer: i64,
    str: []const u8,
    array: []const J,
    object: []const Field,
};

pub const Field = struct { name: []const u8, value: J };

/// Serialize `v` to JSON in `a`. String escaping: `"` `\` control
/// chars → \uXXXX, plus `<`/`>`/`&` → \u003c/\u003e/\u0026 so the
/// output is safe inside an inline <script>.
pub fn json(a: std.mem.Allocator, v: J) []const u8 {
    var aw: std.Io.Writer.Allocating = .init(a);
    writeJson(&aw.writer, v);
    return aw.toOwnedSlice() catch @panic("OOM");
}

fn writeJson(w: anytype, v: J) void {
    switch (v) {
        .null => w.writeAll("null") catch @panic("OOM"),
        .boolean => |b| w.writeAll(if (b) "true" else "false") catch @panic("OOM"),
        .integer => |i| {
            var buf: [24]u8 = undefined;
            w.writeAll(std.fmt.bufPrint(&buf, "{d}", .{i}) catch unreachable) catch @panic("OOM");
        },
        .str => |s| writeJsonString(w, s),
        .array => |items| {
            w.writeByte('[') catch @panic("OOM");
            for (items, 0..) |item, i| {
                if (i != 0) w.writeByte(',') catch @panic("OOM");
                writeJson(w, item);
            }
            w.writeByte(']') catch @panic("OOM");
        },
        .object => |fields| {
            w.writeByte('{') catch @panic("OOM");
            for (fields, 0..) |f, i| {
                if (i != 0) w.writeByte(',') catch @panic("OOM");
                writeJsonString(w, f.name);
                w.writeByte(':') catch @panic("OOM");
                writeJson(w, f.value);
            }
            w.writeByte('}') catch @panic("OOM");
        },
    }
}

fn writeJsonString(w: anytype, s: []const u8) void {
    w.writeByte('"') catch @panic("OOM");
    for (s) |c| {
        switch (c) {
            '"' => w.writeAll("\\\"") catch @panic("OOM"),
            '\\' => w.writeAll("\\\\") catch @panic("OOM"),
            '\n' => w.writeAll("\\n") catch @panic("OOM"),
            '\r' => w.writeAll("\\r") catch @panic("OOM"),
            '\t' => w.writeAll("\\t") catch @panic("OOM"),
            0x08 => w.writeAll("\\b") catch @panic("OOM"),
            0x0C => w.writeAll("\\f") catch @panic("OOM"),
            '<' => w.writeAll("\\u003c") catch @panic("OOM"),
            '>' => w.writeAll("\\u003e") catch @panic("OOM"),
            '&' => w.writeAll("\\u0026") catch @panic("OOM"),
            else => {
                if (c < 0x20) {
                    var buf: [6]u8 = undefined;
                    const hex = std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{c}) catch unreachable;
                    w.writeAll(hex) catch @panic("OOM");
                } else {
                    w.writeByte(c) catch @panic("OOM");
                }
            },
        }
    }
    w.writeByte('"') catch @panic("OOM");
}

/// `<script type="application/ld+json">{json}</script>` for a `J`
/// value — the structured-data block search engines read.
pub fn jsonLd(a: std.mem.Allocator, v: J) []const u8 {
    const body = json(a, v);
    return std.fmt.allocPrint(
        a,
        "<script type=\"application/ld+json\">{s}</script>\n",
        .{body},
    ) catch @panic("OOM");
}

// ── Open Graph / article conveniences ────────────────────────────

/// Inputs for `ogArticle` — every field maps to one meta tag;
/// optional fields are skipped when null.
pub const Article = struct {
    title: []const u8,
    url: []const u8, // absolute canonical URL
    description: ?[]const u8 = null,
    site_name: ?[]const u8 = null,
    locale: ?[]const u8 = "ru_RU",
    image: ?[]const u8 = null,
    published_time: ?[]const u8 = null, // ISO 8601 date/datetime
    modified_time: ?[]const u8 = null,
    /// `article:section` — typically the primary tag.
    section: ?[]const u8 = null,
    author_name: ?[]const u8 = null,
    author_url: ?[]const u8 = null,
};

/// Concatenated Open Graph + `article:*` meta tags for a post.
/// `og:type` is always "article" here (use `ogWebsite` for non-post
/// pages).
pub fn ogArticle(a: std.mem.Allocator, o: Article) []const u8 {
    var aw: std.Io.Writer.Allocating = .init(a);
    const w = &aw.writer;
    const put = struct {
        fn f(w2: anytype, a2: std.mem.Allocator, prop: []const u8, val: ?[]const u8) void {
            if (val) |v| {
                w2.writeAll(metaProperty(a2, prop, v)) catch @panic("OOM");
            }
        }
    }.f;

    w.writeAll(metaProperty(a, "og:type", "article")) catch @panic("OOM");
    w.writeAll(metaProperty(a, "og:title", o.title)) catch @panic("OOM");
    put(w, a, "og:description", o.description);
    w.writeAll(metaProperty(a, "og:url", o.url)) catch @panic("OOM");
    put(w, a, "og:site_name", o.site_name);
    put(w, a, "og:locale", o.locale);
    put(w, a, "og:image", o.image);
    put(w, a, "article:published_time", o.published_time);
    put(w, a, "article:modified_time", o.modified_time);
    put(w, a, "article:section", o.section);
    // article:author is a profile URL — a bare name doesn't belong
    // here (JSON-LD carries the name).
    put(w, a, "article:author", o.author_url);
    return aw.toOwnedSlice() catch @panic("OOM");
}

/// Open Graph block for non-article pages (index/tag/about):
/// `og:type` "website" + title/description/url/site_name/locale/image.
pub fn ogWebsite(a: std.mem.Allocator, o: struct {
    title: []const u8,
    url: []const u8,
    description: ?[]const u8 = null,
    site_name: ?[]const u8 = null,
    locale: ?[]const u8 = "ru_RU",
    image: ?[]const u8 = null,
}) []const u8 {
    var aw: std.Io.Writer.Allocating = .init(a);
    const w = &aw.writer;
    w.writeAll(metaProperty(a, "og:type", "website")) catch @panic("OOM");
    w.writeAll(metaProperty(a, "og:title", o.title)) catch @panic("OOM");
    if (o.description) |d| w.writeAll(metaProperty(a, "og:description", d)) catch @panic("OOM");
    w.writeAll(metaProperty(a, "og:url", o.url)) catch @panic("OOM");
    if (o.site_name) |sn| w.writeAll(metaProperty(a, "og:site_name", sn)) catch @panic("OOM");
    if (o.locale) |l| w.writeAll(metaProperty(a, "og:locale", l)) catch @panic("OOM");
    if (o.image) |img| w.writeAll(metaProperty(a, "og:image", img)) catch @panic("OOM");
    return aw.toOwnedSlice() catch @panic("OOM");
}

/// Inputs for `jsonLdArticle` — BlogPosting schema.org markup.
pub const ArticleLd = struct {
    headline: []const u8,
    url: []const u8,
    date_published: []const u8, // ISO 8601
    date_modified: ?[]const u8 = null,
    description: ?[]const u8 = null,
    image: ?[]const u8 = null,
    author_name: []const u8 = "ZBlog",
    author_url: ?[]const u8 = null,
    site_name: ?[]const u8 = null,
    site_url: ?[]const u8 = null,
    /// Tag slugs — emitted as `keywords` (comma-joined) and
    /// `articleSection`.
    keywords: []const []const u8 = &.{},
};

/// `<script type="application/ld+json">` BlogPosting for a post:
/// headline/description/dates/author/mainEntityOfPage/keywords.
pub fn jsonLdArticle(a: std.mem.Allocator, o: ArticleLd) []const u8 {
    var fields: std.ArrayListUnmanaged(Field) = .empty;
    fields.append(a, .{ .name = "@context", .value = .{ .str = "https://schema.org" } }) catch @panic("OOM");
    fields.append(a, .{ .name = "@type", .value = .{ .str = "BlogPosting" } }) catch @panic("OOM");
    fields.append(a, .{ .name = "headline", .value = .{ .str = o.headline } }) catch @panic("OOM");
    if (o.description) |d| fields.append(a, .{ .name = "description", .value = .{ .str = d } }) catch @panic("OOM");
    fields.append(a, .{ .name = "datePublished", .value = .{ .str = o.date_published } }) catch @panic("OOM");
    if (o.date_modified) |m| fields.append(a, .{ .name = "dateModified", .value = .{ .str = m } }) catch @panic("OOM");
    if (o.image) |img| fields.append(a, .{ .name = "image", .value = .{ .str = img } }) catch @panic("OOM");
    // mainEntityOfPage: the canonical URL as a WebPage reference.
    fields.append(a, .{ .name = "mainEntityOfPage", .value = .{ .object = &.{
        .{ .name = "@type", .value = .{ .str = "WebPage" } },
        .{ .name = "@id", .value = .{ .str = o.url } },
    } } }) catch @panic("OOM");
    // author: Person with name (+ url when known).
    var author_fields: std.ArrayListUnmanaged(Field) = .empty;
    author_fields.append(a, .{ .name = "@type", .value = .{ .str = "Person" } }) catch @panic("OOM");
    author_fields.append(a, .{ .name = "name", .value = .{ .str = o.author_name } }) catch @panic("OOM");
    if (o.author_url) |au| author_fields.append(a, .{ .name = "url", .value = .{ .str = au } }) catch @panic("OOM");
    fields.append(a, .{ .name = "author", .value = .{ .object = author_fields.items } }) catch @panic("OOM");
    if (o.site_name) |sn| {
        var publisher_fields: std.ArrayListUnmanaged(Field) = .empty;
        publisher_fields.append(a, .{ .name = "@type", .value = .{ .str = "Organization" } }) catch @panic("OOM");
        publisher_fields.append(a, .{ .name = "name", .value = .{ .str = sn } }) catch @panic("OOM");
        if (o.site_url) |su| publisher_fields.append(a, .{ .name = "url", .value = .{ .str = su } }) catch @panic("OOM");
        fields.append(a, .{ .name = "publisher", .value = .{ .object = publisher_fields.items } }) catch @panic("OOM");
    }
    if (o.keywords.len > 0) {
        const kw = std.mem.join(a, ", ", o.keywords) catch @panic("OOM");
        fields.append(a, .{ .name = "keywords", .value = .{ .str = kw } }) catch @panic("OOM");
    }
    return jsonLd(a, .{ .object = fields.items });
}

/// JSON-LD `Blog` for the index page: name/url/description (+
/// optional `blogPost` ItemList is left to callers via `jsonLd`).
pub fn jsonLdBlog(a: std.mem.Allocator, o: struct {
    name: []const u8,
    url: []const u8,
    description: ?[]const u8 = null,
}) []const u8 {
    var fields: std.ArrayListUnmanaged(Field) = .empty;
    fields.append(a, .{ .name = "@context", .value = .{ .str = "https://schema.org" } }) catch @panic("OOM");
    fields.append(a, .{ .name = "@type", .value = .{ .str = "Blog" } }) catch @panic("OOM");
    fields.append(a, .{ .name = "name", .value = .{ .str = o.name } }) catch @panic("OOM");
    fields.append(a, .{ .name = "url", .value = .{ .str = o.url } }) catch @panic("OOM");
    if (o.description) |d| fields.append(a, .{ .name = "description", .value = .{ .str = d } }) catch @panic("OOM");
    return jsonLd(a, .{ .object = fields.items });
}

// ─────────────────────────────────────────────
// tests
// ─────────────────────────────────────────────

test "seo: metaName/metaProperty escape content" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try std.testing.expectEqualStrings(
        "<meta name=\"description\" content=\"a &quot;b&quot; &lt;c&gt;\"/>\n",
        metaName(a, "description", "a \"b\" <c>"),
    );
    try std.testing.expectEqualStrings(
        "<meta property=\"og:title\" content=\"t\"/>\n",
        metaProperty(a, "og:title", "t"),
    );
    try std.testing.expectEqualStrings(
        "<link rel=\"canonical\" href=\"https://x/\"/>\n",
        linkCanonical(a, "https://x/"),
    );
}

test "seo: json escapes strings script-safely" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const v: J = .{ .object = &.{
        .{ .name = "t", .value = .{ .str = "a\"b\\c\nd</script>&" } },
        .{ .name = "n", .value = .{ .integer = -42 } },
        .{ .name = "b", .value = .{ .boolean = true } },
        .{ .name = "z", .value = .{ .null = {} } },
        .{ .name = "arr", .value = .{ .array = &.{ .{ .str = "x" }, .{ .integer = 1 } } } },
    } };
    try std.testing.expectEqualStrings(
        "{\"t\":\"a\\\"b\\\\c\\nd\\u003c/script\\u003e\\u0026\",\"n\":-42,\"b\":true,\"z\":null,\"arr\":[\"x\",1]}",
        json(a, v),
    );
}

test "seo: jsonLd wraps script tag" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const out = jsonLd(a, .{ .str = "x" });
    try std.testing.expectEqualStrings(
        "<script type=\"application/ld+json\">\"x\"</script>\n",
        out,
    );
}

test "seo: jsonLdArticle emits BlogPosting fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const out = jsonLdArticle(a, .{
        .headline = "Заголовок \"кавычки\"",
        .url = "https://blog.example.com/post/x",
        .date_published = "2026-11-17",
        .date_modified = "2026-11-18",
        .description = "desc & more",
        .author_name = "ZBlog",
        .site_name = "ZBlog",
        .site_url = "https://blog.example.com",
        .keywords = &.{ "zig", "seo" },
    });
    // Spot-check the load-bearing fields.
    try std.testing.expect(std.mem.indexOf(u8, out, "\"@type\":\"BlogPosting\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"headline\":\"Заголовок \\\"кавычки\\\"\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"datePublished\":\"2026-11-17\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"mainEntityOfPage\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"keywords\":\"zig, seo\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"publisher\"") != null);
    // & in description is JSON-escaped.
    try std.testing.expect(std.mem.indexOf(u8, out, "desc \\u0026 more") != null);
}

test "seo: ogArticle emits article tags" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const out = ogArticle(a, .{
        .title = "T",
        .url = "https://x/p",
        .published_time = "2026-11-17",
        .section = "zig",
        .author_name = "ZBlog",
    });
    try std.testing.expect(std.mem.indexOf(u8, out, "property=\"og:type\" content=\"article\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "property=\"article:published_time\" content=\"2026-11-17\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "property=\"article:section\" content=\"zig\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "property=\"og:locale\" content=\"ru_RU\"") != null);
}
