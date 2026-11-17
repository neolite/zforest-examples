//! html — raw-markup element helpers for tags `forest.Tag` doesn't
//! cover yet (`article`/`nav`/`header`/`time`/`aside`/`ol`/`del`/
//! `h4`-`h6`/…). `forest.el`'s tag set is the framework's element
//! whitelist; when a page needs semantic tags outside it, serialize
//! the element to an escaped string and ship it as a
//! `forest.Node.raw` — raw nodes emit verbatim in SSR and are skipped
//! by diff/snapshot, which is exactly right for static markup (blog
//! chrome, markdown headings h4-h6, ordered lists, strikethrough).
//!
//! Safety contract: every dynamic value MUST pass through
//! `text()`/`renderNodes()` (content) or the attr escaping inside
//! `el`/`elNodes` — never concatenate untrusted bytes into `inner`.
//! Tag and attribute NAMES are comptime literals at call sites, so
//! they can't be attacker-controlled.
const std = @import("std");
const forest = @import("forest");

/// One attribute for `el`/`elNodes`: `value == null` omits the
/// attribute entirely (like `forest.el`'s `?T` attr operands).
pub const Attr = struct {
    name: []const u8,
    value: ?[]const u8 = null,
};

/// Convenience: a class-only attr list entry.
pub fn classAttr(comptime c: []const u8) Attr {
    return .{ .name = "class", .value = c };
}

/// Escaped text → HTML string, for composing raw inner markup.
/// Equivalent to `forest.escapeHtml` but arena-panic on OOM like the
/// rest of the view layer.
pub fn text(a: std.mem.Allocator, s: []const u8) []const u8 {
    return forest.escapeHtml(a, s) catch @panic("OOM");
}

/// Serialize `kids` (forest nodes) to an HTML string in `a` — the
/// inner markup for `elNodes` callers that already hold nodes.
pub fn renderNodes(a: std.mem.Allocator, kids: []const forest.Node) []const u8 {
    var aw: std.Io.Writer.Allocating = .init(a);
    forest.writeHtml(a, kids, &aw.writer) catch @panic("OOM");
    return aw.toOwnedSlice() catch @panic("OOM");
}

/// `<tag attr="v">inner</tag>` as a `forest.Node.raw`. `inner` is
/// TRUSTED markup — pass `text()`/`renderNodes()` output or string
/// literals. `tag`/attr names are comptime literals at call sites.
pub fn el(
    a: std.mem.Allocator,
    comptime tag: []const u8,
    attrs: []const Attr,
    inner: []const u8,
) forest.Node {
    var aw: std.Io.Writer.Allocating = .init(a);
    const w = &aw.writer;
    w.writeByte('<') catch @panic("OOM");
    w.writeAll(tag) catch @panic("OOM");
    for (attrs) |at| {
        w.writeByte(' ') catch @panic("OOM");
        w.writeAll(at.name) catch @panic("OOM");
        if (at.value) |v| {
            w.writeAll("=\"") catch @panic("OOM");
            forest.escapeHtmlInto(w, v) catch @panic("OOM");
            w.writeByte('"') catch @panic("OOM");
        }
    }
    w.writeByte('>') catch @panic("OOM");
    w.writeAll(inner) catch @panic("OOM");
    w.writeAll("</") catch @panic("OOM");
    w.writeAll(tag) catch @panic("OOM");
    w.writeByte('>') catch @panic("OOM");
    return .{ .raw = aw.toOwnedSlice() catch @panic("OOM") };
}

/// `el` with forest.Node children — serialized via `writeHtml` first,
/// so callers mix real elements and nested raw nodes freely.
pub fn elNodes(
    a: std.mem.Allocator,
    comptime tag: []const u8,
    attrs: []const Attr,
    kids: []const forest.Node,
) forest.Node {
    return el(a, tag, attrs, renderNodes(a, kids));
}

/// Heading helper for the markdown plugin: `level` is 1-6 at runtime,
/// dispatched to comptime tag names. `inner` is trusted markup.
pub fn heading(
    a: std.mem.Allocator,
    level: u8,
    attrs: []const Attr,
    inner: []const u8,
) forest.Node {
    return switch (level) {
        1 => el(a, "h1", attrs, inner),
        2 => el(a, "h2", attrs, inner),
        3 => el(a, "h3", attrs, inner),
        4 => el(a, "h4", attrs, inner),
        5 => el(a, "h5", attrs, inner),
        6 => el(a, "h6", attrs, inner),
        else => unreachable,
    };
}

// ─────────────────────────────────────────────
// tests
// ─────────────────────────────────────────────

test "html.el escapes attrs and passes inner verbatim" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const n = el(a, "time", &.{
        .{ .name = "datetime", .value = "2026-11-17" },
        .{ .name = "data-x", .value = "a\"b<c" },
    }, "17 &lt;tag&gt;");
    var aw: std.Io.Writer.Allocating = .init(a);
    forest.writeHtml(a, &.{n}, &aw.writer) catch @panic("OOM");
    try std.testing.expectEqualStrings(
        "<time datetime=\"2026-11-17\" data-x=\"a&quot;b&lt;c\">17 &lt;tag&gt;</time>",
        aw.writer.buffered(),
    );
}

test "html.elNodes serializes forest children inside raw wrapper" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const kids = [_]forest.Node{
        forest.el(a, .p, .{ .class = "x" }, "hi"),
        forest.text(" & bye"),
    };
    const n = elNodes(a, "article", &.{.{ .name = "class", .value = "post" }}, &kids);
    var aw: std.Io.Writer.Allocating = .init(a);
    forest.writeHtml(a, &.{n}, &aw.writer) catch @panic("OOM");
    try std.testing.expectEqualStrings(
        "<article class=\"post\"><p class=\"x\">hi</p> &amp; bye</article>",
        aw.writer.buffered(),
    );
}

test "html.heading dispatches levels to tag names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var aw: std.Io.Writer.Allocating = .init(a);
    const nodes = [_]forest.Node{
        heading(a, 2, &.{.{ .name = "id", .value = "s" }}, "T"),
        heading(a, 6, &.{}, "deep"),
    };
    forest.writeHtml(a, &nodes, &aw.writer) catch @panic("OOM");
    try std.testing.expectEqualStrings("<h2 id=\"s\">T</h2><h6>deep</h6>", aw.writer.buffered());
}
