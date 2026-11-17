//! "/rss.xml" — raw endpoint: dotted final segment → api handler
//! shape, `content_type` decl → application/rss+xml. Full archive
//! (up to app.rss_item_limit newest posts) with rendered HTML in
//! content:encoded. No HTML shell.
const std = @import("std");
const markdown = @import("zplug_markdown");
const rss = @import("zplug_rss");
const html = @import("zplug_html");
const zmeta = @import("../zmeta.zig");
const app = @import("../app.zig");
const content_mod = @import("../content.zig");

pub const params = struct {};

/// Response content type — forwarded by generated `routes.contentType`.
pub const content_type = "application/rss+xml; charset=utf-8";

fn itemHtml(a: std.mem.Allocator, post: content_mod.Post) []const u8 {
    return html.renderNodes(a, markdown.renderBlocks(a, post.body));
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

    const n = @min(c.posts.len, app.rss_item_limit);
    var items: std.ArrayListUnmanaged(rss.Item) = .empty;
    for (c.posts[0..n]) |post| {
        const desc = if (post.description.len > 0) post.description else post.excerpt;
        items.append(a, .{
            .title = post.title,
            .link = app.postUrl(a, post.slug),
            .pub_date = rss.pubDate(a, post.date),
            .description = if (desc.len > 0) desc else null,
            .categories = post.tags,
            .content_encoded = itemHtml(a, post),
        }) catch @panic("OOM");
    }

    // lastBuildDate = newest post's date (posts are date-desc sorted;
    // undated posts yield "" → element omitted).
    const newest = if (c.posts.len > 0) c.posts[0].date else "";

    return rss.render(a, .{
        .title = app.site_name,
        .link = app.site_url,
        .description = app.site_tagline,
        .language = "ru",
        .last_build_date = rss.pubDate(a, newest) orelse "",
        .atom_link = app.absolute(a, "/rss.xml"),
    }, items.items);
}
