//! "/tag/:tag" — all posts carrying the tag (already-slugified at
//! content load, so the raw path segment compares directly).
//! Unknown/unused tag → prepare 404s. Head: "Метка: {tag} — ZBlog",
//! canonical /tag/{tag}, website OG.
const std = @import("std");
const forest = @import("forest");
const html = @import("zplug_html");
const seo = @import("zplug_seo");
const zmeta = @import("../../zmeta.zig");
const app = @import("../../app.zig");
const content_mod = @import("../../content.zig");
const views = @import("../../views.zig");

pub const params = struct { tag: []const u8 };

fn postsFor(a: std.mem.Allocator, tag: []const u8) []const content_mod.Post {
    return content_mod.postsTagged(a, app.content(), tag);
}

pub fn prepare(s: anytype, p: params, env: *const zmeta.Env) !void {
    _ = s;
    _ = env;
    if (!content_mod.hasTag(app.content(), p.tag)) return error.NotFound;
}

pub fn head(
    a: std.mem.Allocator,
    s: anytype,
    p: params,
    env: *const zmeta.Env,
) ?zmeta.HeadSpec {
    _ = s;
    _ = env;
    const path = app.tagPath(a, p.tag);
    const description = std.fmt.allocPrint(a, "Все статьи блога с меткой «{s}».", .{p.tag}) catch @panic("OOM");
    return app.headSpecFor(a, .{
        .title = app.pageTitle(a, std.fmt.allocPrint(a, "Метка: {s}", .{p.tag}) catch @panic("OOM")),
        .description = description,
        .path = path,
        .append = seo.jsonLdBlog(a, .{
            .name = std.fmt.allocPrint(a, "{s} — метка {s}", .{ app.site_name, p.tag }) catch @panic("OOM"),
            .url = app.absolute(a, path),
            .description = description,
        }),
    });
}

pub fn view(a: std.mem.Allocator, s: anytype, p: params, env: *const zmeta.Env) forest.Node {
    _ = s;
    _ = env;
    const posts = postsFor(a, p.tag);

    const h1 = std.fmt.allocPrint(a, "Метка: #{s}", .{p.tag}) catch @panic("OOM");
    const trail = [_]views.Crumb{
        .{ .label = "Блог", .href = "/" },
        .{ .label = h1, .href = null },
    };

    return html.elNodes(a, "div", &.{.{ .name = "class", .value = "tag-page" }}, &.{
        views.breadcrumb(a, &trail),
        forest.el(a, .h1, .{}, h1),
        views.postList(a, posts),
    });
}
