//! Root `_layout.zig` — wraps EVERY page: semantic site chrome
//! (<header> brand+nav, <main>, <footer>) around the page node.
//! `header`/`footer`/`nav` aren't in forest.Tag → plugins/html.zig.
const std = @import("std");
const forest = @import("forest");
const html = @import("zplug_html");
const zmeta = @import("../zmeta.zig");
const app = @import("../app.zig");

pub fn layout(
    a: std.mem.Allocator,
    s: anytype,
    env: *const zmeta.Env,
    inner: forest.Node,
) forest.Node {
    _ = s;
    _ = env;

    const nav_link = struct {
        fn f(a2: std.mem.Allocator, href: []const u8, label: []const u8) forest.Node {
            return forest.el(a2, .a, .{ .href = href, .class = "nav-link" }, label);
        }
    }.f;

    const header = html.elNodes(a, "header", &.{.{ .name = "class", .value = "site-header" }}, &.{
        forest.el(a, .a, .{ .href = "/", .class = "brand" }, app.site_name),
        html.elNodes(a, "nav", &.{.{ .name = "aria-label", .value = "Основная навигация" }}, &.{
            nav_link(a, "/", "Блог"),
            nav_link(a, "/about", "О блоге"),
        }),
    });

    const main = forest.el(a, .main, .{ .id = "content", .class = "site-main" }, inner);

    const footer = forest.el(a, .footer, .{ .class = "site-footer" }, .{
        forest.el(a, .p, .{ .class = "copyright" }, app.site_tagline),
        forest.el(a, .p, .{ .class = "footer-links" }, .{
            forest.el(a, .a, .{ .href = "/rss.xml", .class = "nav-link" }, "RSS"),
            forest.el(a, .a, .{ .href = "/sitemap.xml", .class = "nav-link" }, "Sitemap"),
        }),
    });

    return html.elNodes(a, "div", &.{.{ .name = "class", .value = "site" }}, &.{ header, main, footer });
}
