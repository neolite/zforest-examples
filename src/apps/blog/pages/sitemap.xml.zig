//! "/sitemap.xml" — raw endpoint → application/xml. urlset of every
//! indexable URL: /, /about, each /post/<slug> (lastmod = post date),
//! each /tag/<tag> in use. Slugs are [a-z0-9-] so locs are safe, but
//! values are XML-escaped anyway.
const std = @import("std");
const zmeta = @import("../zmeta.zig");
const app = @import("../app.zig");
const content_mod = @import("../content.zig");

pub const params = struct {};

pub const content_type = "application/xml; charset=utf-8";

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

fn urlEntry(
    w: anytype,
    loc: []const u8,
    lastmod: []const u8,
) void {
    w.writeAll("  <url>\n    <loc>") catch @panic("OOM");
    xescInto(w, loc);
    w.writeAll("</loc>\n") catch @panic("OOM");
    if (content_mod.validDate(lastmod)) {
        w.writeAll("    <lastmod>") catch @panic("OOM");
        w.writeAll(lastmod) catch @panic("OOM");
        w.writeAll("</lastmod>\n") catch @panic("OOM");
    }
    w.writeAll("  </url>\n") catch @panic("OOM");
}

pub fn api(
    a: std.mem.Allocator,
    s: anytype,
    p: params,
    env: *const zmeta.Env,
) ![]const u8 {
    _ = s;
    _ = p;
    _ = env;
    const c = app.content();

    var aw: std.Io.Writer.Allocating = .init(a);
    const w = &aw.writer;
    w.writeAll("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n") catch @panic("OOM");
    w.writeAll("<urlset xmlns=\"http://www.sitemaps.org/schemas/sitemap/0.9\">\n") catch @panic("OOM");

    // Static routes.
    urlEntry(w, app.absolute(a, "/"), newestDate(c));
    if (app.findPage("about") != null) {
        urlEntry(w, app.absolute(a, "/about"), "");
    }

    // Posts — lastmod is the publication date.
    for (c.posts) |post| {
        urlEntry(w, app.postUrl(a, post.slug), post.date);
    }

    // Tags in use (dedup via the already-slugified post tags).
    var seen = std.StringHashMapUnmanaged(void){};
    for (c.posts) |post| {
        for (post.tags) |t| {
            if (seen.contains(t)) continue;
            seen.put(a, t, {}) catch @panic("OOM");
            urlEntry(w, app.absolute(a, app.tagPath(a, t)), "");
        }
    }

    w.writeAll("</urlset>\n") catch @panic("OOM");
    return aw.toOwnedSlice() catch @panic("OOM");
}

/// Newest valid post date for the index lastmod (posts are sorted
/// date-desc; the first dated post wins).
fn newestDate(c: *const content_mod.Content) []const u8 {
    for (c.posts) |p| {
        if (content_mod.validDate(p.date)) return p.date;
    }
    return "";
}
