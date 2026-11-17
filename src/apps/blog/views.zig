//! views — shared post/article/TOC markup for zblog pages. Kept
//! separate from app.zig so pages stay declarative.
//!
//! Tag reality check: forest.Tag lacks article/header/nav/time/ol/
//! del/h4–h6, so semantic wrappers go through plugins/html.zig's
//! trusted-raw helpers; everything else uses forest.el directly.
const std = @import("std");
const forest = @import("forest");
const html = @import("zplug_html");
const markdown = @import("zplug_markdown");
const content_mod = @import("content.zig");
const app = @import("app.zig");

// ── dates ────────────────────────────────────────────────────────

const month_names_ru = [_][]const u8{
    "января",
    "февраля",
    "марта",
    "апреля",
    "мая",
    "июня",
    "июля",
    "августа",
    "сентября",
    "октября",
    "ноября",
    "декабря",
};

/// "2026-11-17" → "17 ноября 2026" (Russian long date for <time>
/// display text). Invalid/empty input → "".
pub fn formatDateRu(a: std.mem.Allocator, iso: []const u8) []const u8 {
    if (!content_mod.validDate(iso)) return "";
    const y = std.fmt.parseInt(u32, iso[0..4], 10) catch return "";
    const m = std.fmt.parseInt(u32, iso[5..7], 10) catch return "";
    const d = std.fmt.parseInt(u32, iso[8..10], 10) catch return "";
    if (m < 1 or m > 12) return "";
    return std.fmt.allocPrint(a, "{d} {s} {d}", .{ d, month_names_ru[m - 1], y }) catch @panic("OOM");
}

/// `<time datetime="YYYY-MM-DD">17 ноября 2026</time>` or "" when
/// the post has no valid date.
fn timeEl(a: std.mem.Allocator, iso: []const u8) ?forest.Node {
    if (!content_mod.validDate(iso)) return null;
    const display = formatDateRu(a, iso);
    return html.el(
        a,
        "time",
        &.{.{ .name = "datetime", .value = iso }},
        html.text(a, display), // escaped display text as inner markup
    );
}

// ── post card (index/tag lists) ──────────────────────────────────

fn tagLinks(a: std.mem.Allocator, tags: []const []const u8) []const forest.Node {
    var out: std.ArrayListUnmanaged(forest.Node) = .empty;
    for (tags, 0..) |t, i| {
        if (i != 0) out.append(a, forest.text(" ")) catch @panic("OOM");
        const href = app.tagPath(a, t);
        const label = std.fmt.allocPrint(a, "#{s}", .{t}) catch @panic("OOM");
        out.append(a, forest.el(a, .a, .{ .href = href, .class = "tag" }, label)) catch @panic("OOM");
    }
    return out.items;
}

/// One `<article class="post">` card: h2 title link, meta line
/// (date + tags), excerpt.
pub fn postCard(a: std.mem.Allocator, p: content_mod.Post) forest.Node {
    const href = app.postPath(a, p.slug);

    var inner: std.ArrayListUnmanaged(forest.Node) = .empty;
    inner.append(a, forest.el(
        a,
        .h2,
        .{},
        forest.el(a, .a, .{ .href = href }, p.title),
    )) catch @panic("OOM");

    // Meta line: <time> + tag links inside <p class="meta">.
    var meta: std.ArrayListUnmanaged(forest.Node) = .empty;
    if (timeEl(a, p.date)) |te| meta.append(a, te) catch @panic("OOM");
    if (p.tags.len > 0) {
        if (meta.items.len > 0) meta.append(a, forest.text(" · ")) catch @panic("OOM");
        for (tagLinks(a, p.tags)) |n| meta.append(a, n) catch @panic("OOM");
    }
    if (meta.items.len > 0) {
        inner.append(a, html.elNodes(a, "p", &.{.{ .name = "class", .value = "meta" }}, meta.items)) catch @panic("OOM");
    }

    if (p.excerpt.len > 0) {
        inner.append(a, forest.el(a, .p, .{ .class = "excerpt" }, p.excerpt)) catch @panic("OOM");
    }

    return html.elNodes(a, "article", &.{.{ .name = "class", .value = "post" }}, inner.items);
}

/// `<div class="post-list">` wrapping `postCard`s.
pub fn postList(a: std.mem.Allocator, posts: []const content_mod.Post) forest.Node {
    var kids: std.ArrayListUnmanaged(forest.Node) = .empty;
    for (posts) |p| kids.append(a, postCard(a, p)) catch @panic("OOM");
    if (kids.items.len == 0) {
        return forest.el(a, .p, .{ .class = "empty" }, "Пока ничего не опубликовано.");
    }
    return html.elNodes(a, "div", &.{.{ .name = "class", .value = "post-list" }}, kids.items);
}

// ── breadcrumb ───────────────────────────────────────────────────

pub const Crumb = struct { label: []const u8, href: ?[]const u8 };

/// `<nav aria-label="breadcrumb"><ol><li><a>Блог</a></li><li>…</li></ol></nav>`
/// — the current page is the last <li> (no link).
pub fn breadcrumb(a: std.mem.Allocator, trail: []const Crumb) forest.Node {
    var lis: std.ArrayListUnmanaged(forest.Node) = .empty;
    for (trail) |item| {
        if (item.href) |href| {
            lis.append(a, forest.el(
                a,
                .li,
                .{},
                forest.el(a, .a, .{ .href = href }, item.label),
            )) catch @panic("OOM");
        } else {
            lis.append(a, forest.el(a, .li, .{ .class = "current" }, item.label)) catch @panic("OOM");
        }
    }
    const ol = html.elNodes(a, "ol", &.{}, lis.items);
    return html.elNodes(a, "nav", &.{.{ .name = "aria-label", .value = "breadcrumb" }}, &.{ol});
}

// ── TOC ──────────────────────────────────────────────────────────

/// `<nav class="toc"><details><summary>Содержание</summary><ul>…</ul></details></nav>`
/// driven by `markdown.headings` ids. Returns null for <2 headings —
/// a one-item TOC is noise.
pub fn tocNav(a: std.mem.Allocator, headings: []const markdown.Heading) ?forest.Node {
    if (headings.len < 2) return null;
    var lis: std.ArrayListUnmanaged(forest.Node) = .empty;
    for (headings) |h| {
        const anchor = std.fmt.allocPrint(a, "#{s}", .{h.id}) catch @panic("OOM");
        lis.append(a, forest.el(
            a,
            .li,
            .{ .class = std.fmt.allocPrint(a, "lv{d}", .{h.level}) catch @panic("OOM") },
            forest.el(a, .a, .{ .href = anchor }, h.text),
        )) catch @panic("OOM");
    }
    const ul = forest.el(a, .ul, .{}, lis.items);
    const details = forest.el(a, .details, .{}, .{
        forest.el(a, .summary, .{}, "Содержание"),
        ul,
    });
    return html.elNodes(a, "nav", &.{ .{ .name = "class", .value = "toc" }, .{ .name = "aria-label", .value = "Содержание" } }, &.{details});
}

// ── full post page ───────────────────────────────────────────────

/// The `/post/<slug>` article: breadcrumb, semantic <article> with
/// <header> (h1 + time + author), TOC nav, rendered markdown body,
/// <footer> tag list.
pub fn postPage(a: std.mem.Allocator, p: content_mod.Post) forest.Node {
    const headings = markdown.headings(a, p.body);
    const body_nodes = markdown.renderBlocks(a, p.body);

    // <header>: h1 + meta line (date · author).
    var meta: std.ArrayListUnmanaged(forest.Node) = .empty;
    var first = true;
    if (timeEl(a, p.date)) |te| {
        meta.append(a, te) catch @panic("OOM");
        first = false;
    }
    const author = if (p.author.len > 0) p.author else app.author_name;
    if (!first) meta.append(a, forest.text(" · ")) catch @panic("OOM");
    const author_label = std.fmt.allocPrint(a, "Автор: {s}", .{author}) catch @panic("OOM");
    meta.append(a, forest.text(author_label)) catch @panic("OOM");
    const header = html.elNodes(a, "header", &.{}, &.{
        forest.el(a, .h1, .{}, p.title),
        html.elNodes(a, "p", &.{.{ .name = "class", .value = "meta" }}, meta.items),
    });

    // Body: <div class="post-body"> around the markdown blocks.
    const body = forest.el(a, .div, .{ .class = "post-body" }, body_nodes);

    // <footer>: tag links back to /tag/<slug>.
    const footer: ?forest.Node = if (p.tags.len > 0)
        html.elNodes(a, "footer", &.{}, &.{
            html.elNodes(a, "p", &.{.{ .name = "class", .value = "tags" }}, tagLinks(a, p.tags)),
        })
    else
        null;

    var article_kids: std.ArrayListUnmanaged(forest.Node) = .empty;
    article_kids.append(a, header) catch @panic("OOM");
    if (tocNav(a, headings)) |toc| article_kids.append(a, toc) catch @panic("OOM");
    article_kids.append(a, body) catch @panic("OOM");
    if (footer) |f| article_kids.append(a, f) catch @panic("OOM");

    const article = html.elNodes(a, "article", &.{.{ .name = "class", .value = "post-full" }}, article_kids.items);

    // Breadcrumb trail: Блог → post title.
    const trail = [_]Crumb{
        .{ .label = "Блог", .href = "/" },
        .{ .label = p.title, .href = null },
    };
    return html.elNodes(a, "div", &.{.{ .name = "class", .value = "post-page" }}, &.{
        breadcrumb(a, &trail),
        article,
    });
}
