//! "/about" — static page rendered from `content/pages/about.md`
//! through the same markdown pipeline as posts (no date/tags).
//! 404s when the content file is absent.
const std = @import("std");
const forest = @import("forest");
const html = @import("zplug_html");
const markdown = @import("zplug_markdown");
const zmeta = @import("../zmeta.zig");
const app = @import("../app.zig");
const views = @import("../views.zig");

pub const params = struct {};

pub fn prepare(s: anytype, p: params, env: *const zmeta.Env) !void {
    _ = s;
    _ = p;
    _ = env;
    if (app.findPage("about") == null) return error.NotFound;
}

pub fn head(
    a: std.mem.Allocator,
    s: anytype,
    p: params,
    env: *const zmeta.Env,
) ?zmeta.HeadSpec {
    _ = s;
    _ = p;
    _ = env;
    const page = app.findPage("about") orelse return null;
    const description = if (page.description.len > 0) page.description else app.site_description;
    return app.headSpecFor(a, .{
        .title = app.pageTitle(a, page.title),
        .description = description,
        .path = "/about",
    });
}

pub fn view(a: std.mem.Allocator, s: anytype, p: params, env: *const zmeta.Env) forest.Node {
    _ = s;
    _ = p;
    _ = env;
    const page = app.findPage("about") orelse unreachable; // prepare 404'd
    const body = markdown.renderBlocks(a, page.body);
    const trail = [_]views.Crumb{
        .{ .label = "Блог", .href = "/" },
        .{ .label = page.title, .href = null },
    };
    return html.elNodes(a, "div", &.{.{ .name = "class", .value = "page-about" }}, &.{
        views.breadcrumb(a, &trail),
        forest.el(a, .h1, .{}, page.title),
        forest.el(a, .div, .{ .class = "post-body" }, body),
    });
}
