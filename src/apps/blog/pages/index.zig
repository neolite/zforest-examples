//! "/" — blog index: `?q=` search (title+tags+excerpt+description,
//! Cyrillic-aware case-insensitive), `?page=N` pagination
//! (`content.page_size` per page), semantic <article> cards, and the
//! SEO head: unique title, self-canonical (page 1 canonicalizes to
//! "/", `?page=1` drops), Blog + ItemList JSON-LD, rel=next/prev.
const std = @import("std");
const forest = @import("forest");
const html = @import("zplug_html");
const seo = @import("zplug_seo");
const zmeta = @import("../zmeta.zig");
const app = @import("../app.zig");
const content_mod = @import("../content.zig");
const views = @import("../views.zig");

pub const params = struct {};

const Query = struct {
    /// Decoded `?q=` ("" = no search).
    q: []const u8,
    /// Raw `?page=` request (1-based; paginate() clamps).
    page: usize,
};

fn parseQuery(a: std.mem.Allocator, env: *const zmeta.Env) Query {
    const q_raw = zmeta.queryParam(env.query, "q") orelse "";
    const q = app.urlDecode(a, q_raw);
    const page_raw = zmeta.queryParam(env.query, "page") orelse "";
    const page = std.fmt.parseInt(usize, page_raw, 10) catch 1;
    return .{ .q = std.mem.trim(u8, q, " \t"), .page = page };
}

fn filteredPosts(a: std.mem.Allocator, query: Query) []const content_mod.Post {
    const c = app.content();
    if (query.q.len == 0) return c.posts;
    return content_mod.searchPosts(a, c, query.q);
}

/// Canonical PATH for the current view: "/" for unfiltered page 1,
/// "/?page=N" / "/?q=…" / "/?q=…&page=N" otherwise — `page=1` never
/// appears (page 1 IS the canonical root).
fn canonicalPath(a: std.mem.Allocator, query: Query, page: usize) []const u8 {
    if (query.q.len == 0 and page <= 1) return "/";
    var aw: std.Io.Writer.Allocating = .init(a);
    const w = &aw.writer;
    w.writeAll("/?") catch @panic("OOM");
    var first = true;
    if (query.q.len > 0) {
        w.writeAll("q=") catch @panic("OOM");
        w.writeAll(app.urlEncode(a, query.q)) catch @panic("OOM");
        first = false;
    }
    if (page > 1) {
        if (!first) w.writeByte('&') catch @panic("OOM");
        w.print("page={d}", .{page}) catch @panic("OOM");
    }
    return aw.toOwnedSlice() catch @panic("OOM");
}

/// `/?…` href preserving the active query for pagination links.
fn pageHref(a: std.mem.Allocator, query: Query, page: usize) []const u8 {
    return canonicalPath(a, query, page);
}

fn headTitle(a: std.mem.Allocator, query: Query, page: usize, pages: usize) []const u8 {
    if (query.q.len > 0) {
        return std.fmt.allocPrint(a, "Поиск: {s} — {s}", .{ query.q, app.site_name }) catch @panic("OOM");
    }
    if (page > 1) {
        return std.fmt.allocPrint(a, "Страница {d} из {d} — {s}", .{ page, pages, app.site_name }) catch @panic("OOM");
    }
    return app.pageTitle(a, "Блог о Zig и server-driven UI");
}

/// Blog + ItemList JSON-LD for the visible page of posts.
fn indexJsonLd(a: std.mem.Allocator, slice: content_mod.PageSlice) []const u8 {
    var parts: std.ArrayListUnmanaged([]const u8) = .empty;

    parts.append(a, seo.jsonLdBlog(a, .{
        .name = app.site_name,
        .url = app.absolute(a, "/"),
        .description = app.site_description,
    })) catch @panic("OOM");

    var elems: std.ArrayListUnmanaged(seo.J) = .empty;
    for (slice.items, 0..) |p, i| {
        elems.append(a, .{ .object = &.{
            .{ .name = "@type", .value = .{ .str = "ListItem" } },
            .{ .name = "position", .value = .{ .integer = @intCast(i + 1) } },
            .{ .name = "url", .value = .{ .str = app.postUrl(a, p.slug) } },
            .{ .name = "name", .value = .{ .str = p.title } },
        } }) catch @panic("OOM");
    }
    parts.append(a, seo.jsonLd(a, .{ .object = &.{
        .{ .name = "@context", .value = .{ .str = "https://schema.org" } },
        .{ .name = "@type", .value = .{ .str = "ItemList" } },
        .{ .name = "name", .value = .{ .str = app.site_name } },
        .{ .name = "itemListElement", .value = .{ .array = elems.items } },
    } })) catch @panic("OOM");

    return std.mem.concat(a, u8, parts.items) catch @panic("OOM");
}

/// rel=next/prev link tags for paginated views (search excluded —
/// canonical already carries ?q, but pagination of results is rare;
/// emit anyway for consistency).
fn pageLinks(a: std.mem.Allocator, query: Query, slice: content_mod.PageSlice) []const u8 {
    var aw: std.Io.Writer.Allocating = .init(a);
    const w = &aw.writer;
    if (slice.page > 1) {
        w.writeAll(seo.linkTag(a, "prev", app.absolute(a, pageHref(a, query, slice.page - 1)))) catch @panic("OOM");
    }
    if (slice.page < slice.pages) {
        w.writeAll(seo.linkTag(a, "next", app.absolute(a, pageHref(a, query, slice.page + 1)))) catch @panic("OOM");
    }
    return aw.toOwnedSlice() catch @panic("OOM");
}

pub fn head(
    a: std.mem.Allocator,
    s: anytype,
    p: params,
    env: *const zmeta.Env,
) ?zmeta.HeadSpec {
    _ = s;
    _ = p;
    const query = parseQuery(a, env);
    const filtered = filteredPosts(a, query);
    const slice = content_mod.paginate(a, filtered, query.page);
    const canon = canonicalPath(a, query, slice.page);
    const title = headTitle(a, query, slice.page, slice.pages);

    // JSON-LD + rel links appended after the standard head block.
    var aw: std.Io.Writer.Allocating = .init(a);
    const w = &aw.writer;
    w.writeAll(indexJsonLd(a, slice)) catch @panic("OOM");
    w.writeAll(pageLinks(a, query, slice)) catch @panic("OOM");

    return app.headSpecFor(a, .{
        .title = title,
        .description = if (query.q.len > 0)
            std.fmt.allocPrint(a, "Результаты поиска «{s}» в {s}", .{ query.q, app.site_name }) catch @panic("OOM")
        else
            app.site_description,
        .path = canon,
        .append = aw.toOwnedSlice() catch @panic("OOM"),
    });
}

pub fn view(a: std.mem.Allocator, s: anytype, p: params, env: *const zmeta.Env) forest.Node {
    _ = s;
    _ = p;
    const query = parseQuery(a, env);
    const filtered = filteredPosts(a, query);
    const slice = content_mod.paginate(a, filtered, query.page);

    var kids: std.ArrayListUnmanaged(forest.Node) = .empty;

    // h1: exactly one per page — site section or the active search.
    if (query.q.len > 0) {
        const h1 = std.fmt.allocPrint(a, "Поиск: «{s}»", .{query.q}) catch @panic("OOM");
        kids.append(a, forest.el(a, .h1, .{}, h1)) catch @panic("OOM");
    } else {
        kids.append(a, forest.el(a, .h1, .{}, "Блог")) catch @panic("OOM");
    }

    // Search form — GET / so it works without JS; `q` carries over.
    // forest escapes the .value attr; the input shows the decoded query.
    // html.elNodes because `aria-label` needs a hyphen forest's
    // struct-attr syntax can't express.
    kids.append(a, html.elNodes(a, "form", &.{
        .{ .name = "action", .value = "/" },
        .{ .name = "method", .value = "get" },
        .{ .name = "class", .value = "search-form" },
        .{ .name = "role", .value = "search" },
        .{ .name = "aria-label", .value = "Поиск по статьям" },
    }, &.{
        forest.el(a, .input, .{
            .type = "search",
            .name = "q",
            .value = query.q,
            .placeholder = "Поиск по статьям…",
        }, .{}),
        forest.el(a, .button, .{ .type = "submit" }, "Найти"),
    })) catch @panic("OOM");

    // Post cards (or an explicit empty state).
    if (slice.items.len == 0) {
        if (query.q.len > 0) {
            const msg = std.fmt.allocPrint(a, "По запросу «{s}» ничего не найдено.", .{query.q}) catch @panic("OOM");
            kids.append(a, forest.el(a, .p, .{ .class = "empty" }, msg)) catch @panic("OOM");
        } else {
            kids.append(a, forest.el(a, .p, .{ .class = "empty" }, "Пока ничего не опубликовано.")) catch @panic("OOM");
        }
    } else {
        kids.append(a, views.postList(a, slice.items)) catch @panic("OOM");
    }

    // Pagination nav — only when there's more than one page.
    if (slice.pages > 1) {
        var links: std.ArrayListUnmanaged(forest.Node) = .empty;
        if (slice.page > 1) {
            const href = pageHref(a, query, slice.page - 1);
            links.append(a, forest.el(a, .a, .{ .href = href, .rel = "prev" }, "← Назад")) catch @panic("OOM");
        }
        const pos = std.fmt.allocPrint(a, "Страница {d} из {d}", .{ slice.page, slice.pages }) catch @panic("OOM");
        links.append(a, forest.el(a, .span, .{ .class = "page-pos" }, pos)) catch @panic("OOM");
        if (slice.page < slice.pages) {
            const href = pageHref(a, query, slice.page + 1);
            links.append(a, forest.el(a, .a, .{ .href = href, .rel = "next" }, "Вперёд →")) catch @panic("OOM");
        }
        kids.append(a, html.elNodes(a, "nav", &.{ .{ .name = "class", .value = "pagination" }, .{ .name = "aria-label", .value = "Страницы" } }, links.items)) catch @panic("OOM");
    }

    return html.elNodes(a, "div", &.{.{ .name = "class", .value = "index-page" }}, kids.items);
}
