//! rss — RSS 2.0 channel/item XML builder for blog feeds. All text
//! is XML-escaped; `content:encoded` payloads go inside CDATA with
//! the `]]>` split-guard. Absolute URLs are the caller's job — pass
//! `site_url`-derived links.
//!
//! Usage:
//!   const xml = rss.render(a, .{
//!       .title = "ZBlog", .link = site_url, .description = "…",
//!       .language = "ru", .last_build_date = rss.pubDate(a, newest) orelse "",
//!       .atom_link = site_url ++ "/rss.xml",
//!   }, items);
const std = @import("std");

pub const Channel = struct {
    title: []const u8,
    /// Absolute site URL (channel <link>).
    link: []const u8,
    description: []const u8,
    /// RSS language code — "ru" for the Russian blog.
    language: []const u8 = "ru",
    /// RFC-822 timestamp for <lastBuildDate> — `pubDate` output.
    /// Empty string omits the element.
    last_build_date: []const u8 = "",
    /// Absolute feed URL for <atom:link rel="self"> — empty omits.
    atom_link: []const u8 = "",
};

pub const Item = struct {
    title: []const u8,
    /// Absolute permalink — also the default <guid>.
    link: []const u8,
    /// Override <guid>; defaults to `link` with isPermaLink="true".
    guid: ?[]const u8 = null,
    /// RFC-822 <pubDate> — `pubDate` output. Null omits the element.
    pub_date: ?[]const u8 = null,
    /// <description> — plain text or escaped HTML, XML-escaped here.
    description: ?[]const u8 = null,
    /// One <category> per entry.
    categories: []const []const u8 = &.{},
    /// Full rendered HTML for <content:encoded> — TRUSTED markup
    /// (markdown.renderBlocks + writeHtml output), wrapped in CDATA.
    content_encoded: ?[]const u8 = null,
};

// ── XML escaping ─────────────────────────────────────────────────

fn xescInto(w: anytype, s: []const u8) void {
    for (s) |c| {
        switch (c) {
            '&' => w.writeAll("&amp;") catch @panic("OOM"),
            '<' => w.writeAll("&lt;") catch @panic("OOM"),
            '>' => w.writeAll("&gt;") catch @panic("OOM"),
            '"' => w.writeAll("&quot;") catch @panic("OOM"),
            else => w.writeByte(c) catch @panic("OOM"),
        }
    }
}

fn xesc(a: std.mem.Allocator, s: []const u8) []const u8 {
    var aw: std.Io.Writer.Allocating = .init(a);
    xescInto(&aw.writer, s);
    return aw.toOwnedSlice() catch @panic("OOM");
}

fn elem(w: anytype, comptime name: []const u8, text: []const u8) void {
    w.writeByte('<') catch @panic("OOM");
    w.writeAll(name) catch @panic("OOM");
    w.writeByte('>') catch @panic("OOM");
    xescInto(w, text);
    w.writeAll("</") catch @panic("OOM");
    w.writeAll(name) catch @panic("OOM");
    w.writeByte('>') catch @panic("OOM");
    w.writeByte('\n') catch @panic("OOM");
}

// ── RFC-822 dates ────────────────────────────────────────────────

const rfc_months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
const rfc_days = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };

/// Days since 1970-01-01 (Howard Hinnant's days_from_civil).
fn daysFromCivil(y: i64, m: u32, d: u32) i64 {
    const yy: i64 = if (m <= 2) y - 1 else y;
    const era = @divFloor(yy, 400);
    const yoe = yy - era * 400;
    const mp: i64 = @mod(@as(i64, m) + 9, 12);
    const doy = @divTrunc(153 * mp + 2, 5) + @as(i64, d) - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

/// `"YYYY-MM-DD"` → RFC-822 `"Wed, 17 Nov 2026 00:00:00 GMT"`, or
/// null when the input isn't a valid ISO date. Time is always
/// midnight UTC — posts are date-granular.
pub fn pubDate(a: std.mem.Allocator, iso: []const u8) ?[]const u8 {
    if (iso.len != 10 or iso[4] != '-' or iso[7] != '-') return null;
    const y = std.fmt.parseInt(i64, iso[0..4], 10) catch return null;
    const m = std.fmt.parseInt(u32, iso[5..7], 10) catch return null;
    const d = std.fmt.parseInt(u32, iso[8..10], 10) catch return null;
    if (m < 1 or m > 12 or d < 1 or d > 31) return null;
    const days = daysFromCivil(y, m, d);
    const wd = @mod(days + 4, 7); // 1970-01-01 was Thursday; 0=Sunday
    var buf: [48]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{s}, {d:0>2} {s} {d:0>4} 00:00:00 GMT", .{
        rfc_days[@intCast(wd)], d, rfc_months[m - 1], @as(u64, @intCast(y)),
    }) catch unreachable;
    return a.dupe(u8, s) catch @panic("OOM");
}

// ── document ─────────────────────────────────────────────────────

/// Full RSS 2.0 document: xml decl + rss root (with xmlns:content
/// and xmlns:atom for the self link + encoded bodies) + channel +
/// items.
pub fn render(a: std.mem.Allocator, ch: Channel, items: []const Item) []const u8 {
    var aw: std.Io.Writer.Allocating = .init(a);
    const w = &aw.writer;

    w.writeAll("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n") catch @panic("OOM");
    w.writeAll("<rss version=\"2.0\" xmlns:content=\"http://purl.org/rss/1.0/modules/content/\" xmlns:atom=\"http://www.w3.org/2005/Atom\">\n") catch @panic("OOM");
    w.writeAll("<channel>\n") catch @panic("OOM");
    elem(w, "title", ch.title);
    elem(w, "link", ch.link);
    elem(w, "description", ch.description);
    elem(w, "language", ch.language);
    if (ch.last_build_date.len > 0) elem(w, "lastBuildDate", ch.last_build_date);
    if (ch.atom_link.len > 0) {
        w.writeAll("<atom:link href=\"") catch @panic("OOM");
        xescInto(w, ch.atom_link);
        w.writeAll("\" rel=\"self\" type=\"application/rss+xml\"/>\n") catch @panic("OOM");
    }
    for (items) |it| {
        w.writeAll("<item>\n") catch @panic("OOM");
        elem(w, "title", it.title);
        elem(w, "link", it.link);
        const guid = it.guid orelse it.link;
        w.writeAll("<guid isPermaLink=\"true\">") catch @panic("OOM");
        xescInto(w, guid);
        w.writeAll("</guid>\n") catch @panic("OOM");
        if (it.pub_date) |pd| elem(w, "pubDate", pd);
        if (it.description) |d| elem(w, "description", d);
        for (it.categories) |c| elem(w, "category", c);
        if (it.content_encoded) |html_body| {
            w.writeAll("<content:encoded><![CDATA[") catch @panic("OOM");
            // Guard: a literal "]]>" inside content would close the
            // CDATA early — split it across two sections.
            var rest = html_body;
            while (std.mem.indexOf(u8, rest, "]]>")) |idx| {
                w.writeAll(rest[0..idx]) catch @panic("OOM");
                w.writeAll("]]]]><![CDATA[>") catch @panic("OOM");
                rest = rest[idx + 3 ..];
            }
            w.writeAll(rest) catch @panic("OOM");
            w.writeAll("]]></content:encoded>\n") catch @panic("OOM");
        }
        w.writeAll("</item>\n") catch @panic("OOM");
    }
    w.writeAll("</channel>\n</rss>\n") catch @panic("OOM");
    return aw.toOwnedSlice() catch @panic("OOM");
}

// ─────────────────────────────────────────────
// tests
// ─────────────────────────────────────────────

test "rss: pubDate converts ISO dates" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // 2026-11-17 is a Tuesday.
    try std.testing.expectEqualStrings("Tue, 17 Nov 2026 00:00:00 GMT", pubDate(a, "2026-11-17").?);
    // 2026-01-01 is a Thursday.
    try std.testing.expectEqualStrings("Thu, 01 Jan 2026 00:00:00 GMT", pubDate(a, "2026-01-01").?);
    try std.testing.expect(pubDate(a, "not-a-date") == null);
    try std.testing.expect(pubDate(a, "2026-13-01") == null);
    try std.testing.expect(pubDate(a, "2026-11-17T00:00:00Z") == null);
}

test "rss: render escapes text and emits items" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const xml = render(a, .{
        .title = "Z & B",
        .link = "https://blog.example.com",
        .description = "desc <b>",
        .language = "ru",
        .last_build_date = "Tue, 17 Nov 2026 00:00:00 GMT",
        .atom_link = "https://blog.example.com/rss.xml",
    }, &.{
        .{
            .title = "Post <one>",
            .link = "https://blog.example.com/post/x",
            .pub_date = pubDate(a, "2026-11-17"),
            .description = "d & d",
            .categories = &.{ "zig", "seo" },
            .content_encoded = "<h2 id=\"a\">Hi</h2><p>x]]>y</p>",
        },
    });
    // Channel-level escaping + required namespaces.
    try std.testing.expect(std.mem.indexOf(u8, xml, "<title>Z &amp; B</title>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "xmlns:content=\"http://purl.org/rss/1.0/modules/content/\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<atom:link href=\"https://blog.example.com/rss.xml\" rel=\"self\" type=\"application/rss+xml\"/>") != null);
    // Item fields.
    try std.testing.expect(std.mem.indexOf(u8, xml, "<title>Post &lt;one&gt;</title>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<guid isPermaLink=\"true\">https://blog.example.com/post/x</guid>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<pubDate>Tue, 17 Nov 2026 00:00:00 GMT</pubDate>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<category>zig</category>") != null);
    // CDATA content + the ]]> split-guard.
    try std.testing.expect(std.mem.indexOf(u8, xml, "<content:encoded><![CDATA[<h2 id=\"a\">Hi</h2><p>x]]]]><![CDATA[>y</p>]]></content:encoded>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<language>ru</language>") != null);
}
