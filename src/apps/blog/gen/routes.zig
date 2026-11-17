//! GENERATED FILE — do not edit. Regenerate with `zig build gen`
//! (or `zig run src/zmeta/gen.zig -- <app-dir>`).
//! Source: pages/ files + actions.zig manifest.

const std = @import("std");
const forest = @import("forest");
const zmeta = @import("../zmeta.zig");
const index_page = @import("../pages/index.zig");
const about_page = @import("../pages/about.zig");
const post_page = @import("../pages/post/[slug].zig");
const tag_page = @import("../pages/tag/[tag].zig");
const robots_txt_raw = @import("../pages/robots.txt.zig");
const rss_xml_raw = @import("../pages/rss.xml.zig");
const sitemap_xml_raw = @import("../pages/sitemap.xml.zig");
const lay_root = @import("../pages/_layout.zig");

/// Typed route — one tag per page file. Dynamic `[name]`
/// segments carry the page's `params` struct as payload.
pub const Route = union(enum) {
    index: index_page.params,
    about: about_page.params,
    post: post_page.params,
    tag: tag_page.params,
};

/// Parse a request path into a typed Route. Static segments take
/// precedence over `[name]` dynamics at the same position;
/// `[...name]` catch-alls match any non-empty tail. Int params
/// parse as integers; `[]const u8` params slice the path —
/// callers storing the route must pass session-owned memory
/// (the skeleton's `setRoute` does). Returns null on any
/// mismatch — the caller maps that to 404.
pub fn parseRoute(path: []const u8) ?Route {
    if (std.mem.eql(u8, path, "/")) return Route{ .index = .{} };
    if (!std.mem.startsWith(u8, path, "/")) return null;
    var segs: [2][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, path[1..], '/');
    while (it.next()) |seg| {
        // Store only what fits — catch-all routes match tails
        // deeper than the deepest static route, so `n` keeps
        // counting past the buffer instead of bailing out.
        if (n < segs.len) segs[n] = seg;
        n += 1;
    }
    return result: {
        if (n == 1 and std.mem.eql(u8, segs[0], "about")) {
            break :result Route{ .about = .{} };
        }
        if (n == 2 and std.mem.eql(u8, segs[0], "post")) {
            const slug = segs[1];
            break :result Route{ .post = .{ .slug = slug } };
        }
        if (n == 2 and std.mem.eql(u8, segs[0], "tag")) {
            const tag = segs[1];
            break :result Route{ .tag = .{ .tag = tag } };
        }
        break :result null;
    };
}

/// Session glue: parse + store the typed route. Deps.setRoute
/// delegates here; returns false → 404.
pub fn setRoute(s: anytype, path: []const u8) bool {
    const r = parseRoute(path) orelse return false;
    s.deps.route = r;
    return true;
}

/// Pure route pre-check for the server's validPath hook —
/// accepts api paths too when the app has pages/api/.
pub fn validPath(path: []const u8) bool {
    return parseRoute(path) != null or rawPath(path);
}

/// Type-safe href: `href(a, .{ .item = .{ .id = 3 } })` allocates
/// the path in `a` (the render arena in views). Static routes
/// return comptime literals.
pub fn href(a: std.mem.Allocator, r: Route) []const u8 {
    return switch (r) {
        .index => "/",
        .about => "/about",
        .post => |p| std.fmt.allocPrint(a, "/post/{s}", .{p.slug}) catch @panic("OOM"),
        .tag => |p| std.fmt.allocPrint(a, "/tag/{s}", .{p.tag}) catch @panic("OOM"),
    };
}

fn preparePage(comptime Page: type, s: anytype, p: anytype, env: *const zmeta.Env) !void {
    if (@hasDecl(Page, "prepare")) try Page.prepare(s, p, env);
}

/// Route gate: Deps.prepare delegates here. Applicable
/// `_middleware.zig` files run outermost-first, then the
/// page's own `prepare`; any error → servePage 404s before
/// view work. Api endpoints (`pages/api/`) skip this
/// dispatch entirely.
pub fn prepare(s: anytype, env: *const zmeta.Env) !void {
    switch (s.deps.route) {
        .index => |p| try preparePage(index_page, s, p, env),
        .about => |p| try preparePage(about_page, s, p, env),
        .post => |p| try preparePage(post_page, s, p, env),
        .tag => |p| try preparePage(tag_page, s, p, env),
    }
}

/// View dispatch: Deps.view delegates here. Each page's
/// `view(a, s, params, env) forest.Node` becomes one node,
/// wrapped by every applicable `_layout.zig` (outermost
/// first — `pages/_layout.zig` wraps all pages).
pub fn viewNodes(a: std.mem.Allocator, s: anytype, env: *const zmeta.Env) []const forest.Node {
    const nodes = a.alloc(forest.Node, 1) catch @panic("OOM");
    nodes[0] = switch (s.deps.route) {
        .index => |p| lay_root.layout(a, s, env, index_page.view(a, s, p, env)),
        .about => |p| lay_root.layout(a, s, env, about_page.view(a, s, p, env)),
        .post => |p| lay_root.layout(a, s, env, post_page.view(a, s, p, env)),
        .tag => |p| lay_root.layout(a, s, env, tag_page.view(a, s, p, env)),
    };
    return nodes;
}

fn pageLive(comptime Page: type) bool {
    if (@hasDecl(Page, "live")) return Page.live;
    return false;
}

/// Whether the route's page opted into live bindings. The
/// session's `Deps.pageLive` forwards here.
pub fn isLive(r: Route) bool {
    return switch (r) {
        .index => pageLive(index_page),
        .about => pageLive(about_page),
        .post => pageLive(post_page),
        .tag => pageLive(tag_page),
    };
}

fn headFor(comptime Page: type, s: anytype, p: anytype, a: std.mem.Allocator, env: *const zmeta.Env) ?zmeta.HeadSpec {
    if (@hasDecl(Page, "head")) return Page.head(a, s, p, env);
    return null;
}

/// Per-page `<head>` overrides for the CURRENT route —
/// `Deps.headSpec` delegates here. The session calls it
/// after servePage resolved the route (the page's
/// `prepare` already ran); `a` is the session render
/// arena. Pages without `pub fn head` → null → the
/// server's page_title/page_lang defaults apply.
pub fn headSpec(s: anytype, a: std.mem.Allocator, env: *const zmeta.Env) ?zmeta.HeadSpec {
    return switch (s.deps.route) {
        .index => |p| headFor(index_page, s, p, a, env),
        .about => |p| headFor(about_page, s, p, a, env),
        .post => |p| headFor(post_page, s, p, a, env),
        .tag => |p| headFor(tag_page, s, p, a, env),
    };
}
/// Typed raw-endpoint route — one tag per dotted
/// `pages/**` file ("pages/rss.xml.zig" → "/rss.xml").
/// Handlers return a raw body (RSS/XML/text) through the
/// same `api(a, s, params, env)` shape as api endpoints;
/// the server skips the HTML shell and defaults the
/// content type to text/plain (see `contentType`).
pub const RawRoute = union(enum) {
    robots_txt: robots_txt_raw.params,
    rss_xml: rss_xml_raw.params,
    sitemap_xml: sitemap_xml_raw.params,
};

/// Parse a raw-endpoint path ("/rss.xml", "/blog/feed.atom")
/// — same segment rules and precedence as parseRoute.
/// Returns null on any mismatch → the caller falls
/// through to page handling (404 for unknown paths).
pub fn parseRaw(path: []const u8) ?RawRoute {
    if (!std.mem.startsWith(u8, path, "/")) return null;
    var segs: [1][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, path[1..], '/');
    while (it.next()) |seg| {
        if (n < segs.len) segs[n] = seg;
        n += 1;
    }
    return result: {
        if (n == 1 and std.mem.eql(u8, segs[0], "robots.txt")) {
            break :result RawRoute{ .robots_txt = .{} };
        }
        if (n == 1 and std.mem.eql(u8, segs[0], "rss.xml")) {
            break :result RawRoute{ .rss_xml = .{} };
        }
        if (n == 1 and std.mem.eql(u8, segs[0], "sitemap.xml")) {
            break :result RawRoute{ .sitemap_xml = .{} };
        }
        break :result null;
    };
}

/// Pure raw-route pre-check — pairs with `validPath`.
pub fn rawPath(path: []const u8) bool {
    return parseRaw(path) != null;
}

/// Raw-endpoint dispatch: returns the handler's body, or
/// null when `path` isn't a raw route. `a` is the caller's
/// arena; `env` carries route+query.
pub fn raw(a: std.mem.Allocator, s: anytype, path: []const u8, env: *const zmeta.Env) !?[]const u8 {
    const r = parseRaw(path) orelse return null;
    const body = switch (r) {
        .robots_txt => |p| try robots_txt_raw.api(a, s, p, env),
        .rss_xml => |p| try rss_xml_raw.api(a, s, p, env),
        .sitemap_xml => |p| try sitemap_xml_raw.api(a, s, p, env),
    };
    return body;
}

fn endpointCt(comptime P: type) ?[]const u8 {
    if (@hasDecl(P, "content_type")) return P.content_type;
    return null;
}

/// Content-type lookup for api/raw endpoint responses —
/// `Deps.endpointContentType` delegates here. Forwards each
/// file's `pub const content_type`; null → the server's
/// per-kind default.
pub fn contentType(path: []const u8) ?[]const u8 {
    if (parseRaw(path)) |r| return switch (r) {
        .robots_txt => endpointCt(robots_txt_raw),
        .rss_xml => endpointCt(rss_xml_raw),
        .sitemap_xml => endpointCt(sitemap_xml_raw),
    };
    return null;
}
