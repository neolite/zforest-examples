//! "/post/:slug" — single post: h1 title, <time datetime> pub date,
//! author, tag links, TOC (from markdown heading ids), rendered
//! markdown body. SEO head: "{title} — ZBlog", meta description
//! (frontmatter → excerpt), canonical, OG article:* + BlogPosting
//! JSON-LD. Unknown slug → prepare 404s.
const std = @import("std");
const forest = @import("forest");
const seo = @import("zplug_seo");
const zmeta = @import("../../zmeta.zig");
const app = @import("../../app.zig");
const content_mod = @import("../../content.zig");
const views = @import("../../views.zig");

/// `[slug]` segment → `slug: []const u8` (slices the raw path — safe
/// because content slugs are slugified to [a-z0-9-] at load).
pub const params = struct { slug: []const u8 };

pub fn prepare(s: anytype, p: params, env: *const zmeta.Env) !void {
    _ = s;
    _ = env;
    if (app.findPost(p.slug) == null) return error.NotFound;
}

fn metaDescription(post: content_mod.Post) []const u8 {
    if (post.description.len > 0) return post.description;
    return post.excerpt;
}

pub fn head(
    a: std.mem.Allocator,
    s: anytype,
    p: params,
    env: *const zmeta.Env,
) ?zmeta.HeadSpec {
    _ = s;
    _ = env;
    const post = app.findPost(p.slug) orelse return null;
    const path = app.postPath(a, post.slug);
    const url = app.absolute(a, path);
    const description = metaDescription(post);
    const title = app.pageTitle(a, post.title);
    const author = if (post.author.len > 0) post.author else app.author_name;

    const article = seo.Article{
        .title = title,
        .url = url,
        .description = if (description.len > 0) description else null,
        .site_name = app.site_name,
        .locale = app.og_locale,
        .published_time = if (post.date.len > 0) post.date else null,
        .modified_time = if (post.date.len > 0) post.date else null,
        .section = if (post.tags.len > 0) post.tags[0] else null,
        .author_name = author,
    };

    const ld = seo.jsonLdArticle(a, .{
        .headline = post.title,
        .url = url,
        .date_published = if (post.date.len > 0) post.date else "1970-01-01",
        .date_modified = if (post.date.len > 0) post.date else null,
        .description = if (description.len > 0) description else null,
        .author_name = author,
        .site_name = app.site_name,
        .site_url = app.site_url,
        .keywords = post.tags,
    });

    return app.headSpecFor(a, .{
        .title = title,
        .description = description,
        .path = path,
        .article = article,
        .append = ld,
    });
}

pub fn view(a: std.mem.Allocator, s: anytype, p: params, env: *const zmeta.Env) forest.Node {
    _ = s;
    _ = env;
    const post = app.findPost(p.slug) orelse unreachable; // prepare 404'd
    return views.postPage(a, post);
}
