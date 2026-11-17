//! app — zblog session deps + site-wide SEO/head composition.
//! Read-only: no actions, no session state beyond the route.
//!
//! Content is loaded ONCE at startup by `main` into a private arena
//! (`initContent`) — `content()` unwraps it. Pages query it through
//! `findPost`/`postsTagged`/`searchPosts`/`paginate`.
const std = @import("std");
const Io = std.Io;
const zefx = @import("zefx");
const forest = @import("forest");
const zmeta = @import("zmeta.zig");
const routes = @import("gen/routes.zig");
const actions = @import("gen/actions.zig");
const content_mod = @import("content.zig");
const seo = @import("zplug_seo");

// ── site constants ───────────────────────────────────────────────

pub const site_name = "ZBlog";
pub const site_tagline = "Блог о zforest, zmeta и server-driven UI на Zig";
/// PLACEHOLDER — swap for the real domain before deploying; every
/// canonical/OG/RSS/sitemap/robots URL derives from this.
pub const site_url = "https://blog.example.com";
pub const site_description =
    "ZBlog — блог о zforest, zmeta и server-driven UI: SSR, SSE, " ++
    "markdown-файлы как CMS, SEO из коробки. На Zig.";
pub const author_name = "ZBlog";
pub const og_locale = "ru_RU";
/// `zig build run-blog` resolves this relative to the repo root.
pub const default_content_dir = "src/apps/blog/content";
/// Feed/sitemap keep every published post — RSS readers expect the
/// full archive; pagination applies to HTML only.
pub const rss_item_limit = 50;

const blog_css = @embedFile("blog.css");

// ── content store ────────────────────────────────────────────────

var content_arena: std.heap.ArenaAllocator = undefined;
var loaded: ?content_mod.Content = null;

/// Load `dir` once at startup. `dir` is repo-root-relative
/// (`src/apps/blog/content` by default; `main` argv[3] overrides).
pub fn initContent(io: Io, gpa: std.mem.Allocator, dir: []const u8) !void {
    content_arena = std.heap.ArenaAllocator.init(gpa);
    const a = content_arena.allocator();
    loaded = try content_mod.load(a, io, dir);
}

pub fn deinitContent() void {
    if (loaded != null) {
        content_arena.deinit();
        loaded = null;
    }
}

/// The loaded content — panics if `initContent` wasn't called (main
/// always calls it; tests assign `loaded` directly).
pub fn content() *const content_mod.Content {
    return &loaded.?;
}

/// Test hook: inject a Content built in the test's allocator.
pub fn setContentForTest(c: content_mod.Content) void {
    loaded = c;
}

pub fn findPost(slug: []const u8) ?content_mod.Post {
    return content_mod.findPost(content(), slug);
}

pub fn findPage(slug: []const u8) ?content_mod.Page {
    return content_mod.findPage(content(), slug);
}

// ── URL helpers ──────────────────────────────────────────────────

/// Percent-decode `%XX` (UTF-8 bytes pass through). `env.query` is
/// raw — values arrive still-encoded, so `?q=…` must be decoded
/// before matching against post text.
pub fn urlDecode(a: std.mem.Allocator, s: []const u8) []const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '%' and i + 2 < s.len) {
            const hi = std.fmt.charToDigit(s[i + 1], 16) catch {
                out.append(a, s[i]) catch @panic("OOM");
                i += 1;
                continue;
            };
            const lo = std.fmt.charToDigit(s[i + 2], 16) catch {
                out.append(a, s[i]) catch @panic("OOM");
                i += 1;
                continue;
            };
            out.append(a, @intCast(hi * 16 + lo)) catch @panic("OOM");
            i += 3;
            continue;
        }
        if (s[i] == '+') {
            out.append(a, ' ') catch @panic("OOM");
        } else {
            out.append(a, s[i]) catch @panic("OOM");
        }
        i += 1;
    }
    return out.items;
}

/// Percent-encode everything outside RFC 3986 unreserved
/// `[A-Za-z0-9-._~]` — UTF-8 bytes become %XX (uppercase hex).
pub fn urlEncode(a: std.mem.Allocator, s: []const u8) []const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    const hexd = "0123456789ABCDEF";
    for (s) |c| {
        const unreserved = std.ascii.isAlphanumeric(c) or
            c == '-' or c == '.' or c == '_' or c == '~';
        if (unreserved) {
            out.append(a, c) catch @panic("OOM");
        } else {
            out.append(a, '%') catch @panic("OOM");
            out.append(a, hexd[c >> 4]) catch @panic("OOM");
            out.append(a, hexd[c & 0xF]) catch @panic("OOM");
        }
    }
    return out.items;
}

/// `site_url ++ path` — the absolute URL for canonicals/OG/RSS/sitemap.
pub fn absolute(a: std.mem.Allocator, path: []const u8) []const u8 {
    return std.fmt.allocPrint(a, "{s}{s}", .{ site_url, path }) catch @panic("OOM");
}

/// Post permalink path (`/post/<slug>`) and absolute URL.
pub fn postPath(a: std.mem.Allocator, slug: []const u8) []const u8 {
    return std.fmt.allocPrint(a, "/post/{s}", .{slug}) catch @panic("OOM");
}

pub fn postUrl(a: std.mem.Allocator, slug: []const u8) []const u8 {
    return absolute(a, postPath(a, slug));
}

pub fn tagPath(a: std.mem.Allocator, tag: []const u8) []const u8 {
    return std.fmt.allocPrint(a, "/tag/{s}", .{tag}) catch @panic("OOM");
}

// ── head composition ─────────────────────────────────────────────

/// Options for `headSpecFor` — every page builds its <head> extra
/// from this one helper so style/meta/canonical/OG stay uniform.
pub const HeadOpts = struct {
    /// Full <title> text INCLUDING the " — ZBlog" suffix.
    title: []const u8,
    /// Meta description (frontmatter desc → excerpt fallback done by
    /// the caller). Empty → no description tag.
    description: []const u8 = "",
    /// Canonical PATH incl. query ("/post/x", "/?page=2") — turned
    /// into the absolute canonical + og:url.
    path: []const u8,
    /// Non-null → og:type "article" via `seo.ogArticle`; null →
    /// "website" via `seo.ogWebsite`.
    article: ?seo.Article = null,
    /// Raw markup appended LAST inside <head> (JSON-LD scripts,
    /// rel=next/prev links — caller-built via plugins/seo).
    append: ?[]const u8 = null,
};

/// `HeadSpec` for a page: title + `extra` = inline CSS + meta
/// description + canonical + OG (+article:*) + twitter card +
/// caller `append`. `lang` comes from `Deps.page_lang`.
pub fn headSpecFor(a: std.mem.Allocator, o: HeadOpts) zmeta.HeadSpec {
    const canonical = absolute(a, o.path);
    var aw: std.Io.Writer.Allocating = .init(a);
    const w = &aw.writer;

    // Inline CSS — render-blocking but tiny and cache-free; the
    // view stays lean (no per-element style attrs).
    w.writeAll("<style>") catch @panic("OOM");
    w.writeAll(blog_css) catch @panic("OOM");
    w.writeAll("</style>\n") catch @panic("OOM");

    if (o.description.len > 0) {
        w.writeAll(seo.metaName(a, "description", o.description)) catch @panic("OOM");
        w.writeAll(seo.metaName(a, "twitter:card", "summary")) catch @panic("OOM");
    } else {
        w.writeAll(seo.metaName(a, "twitter:card", "summary")) catch @panic("OOM");
    }
    w.writeAll(seo.linkCanonical(a, canonical)) catch @panic("OOM");

    if (o.article) |art| {
        w.writeAll(seo.ogArticle(a, art)) catch @panic("OOM");
    } else {
        w.writeAll(seo.ogWebsite(a, .{
            .title = o.title,
            .url = canonical,
            .description = if (o.description.len > 0) o.description else null,
            .site_name = site_name,
            .locale = og_locale,
        })) catch @panic("OOM");
    }
    if (o.append) |extra| w.writeAll(extra) catch @panic("OOM");

    return .{
        .title = o.title,
        .extra = aw.toOwnedSlice() catch @panic("OOM"),
        .lang = null, // Deps.page_lang supplies "ru"
    };
}

/// `<title>` convention: "{page} — ZBlog".
pub fn pageTitle(a: std.mem.Allocator, page: []const u8) []const u8 {
    return std.fmt.allocPrint(a, "{s} — {s}", .{ page, site_name }) catch @panic("OOM");
}

// ── deps ─────────────────────────────────────────────────────────

pub const BlogDeps = struct {
    pub const page_title = site_name;
    pub const page_class = "blog";
    pub const page_lang = "ru";
    pub const cookie_name = "zblg";

    route: routes.Route = .{ .index = .{} },

    pub fn init(s: *Session) BlogDeps {
        _ = s;
        return .{};
    }
    pub fn deinit(s: *Session) void {
        _ = s;
    }

    pub fn setRoute(s: *Session, path: []const u8) bool {
        return routes.setRoute(s, path);
    }
    pub fn validPath(path: []const u8) bool {
        return routes.validPath(path);
    }
    pub fn prepare(s: *Session, env: *const zmeta.Env) !void {
        try routes.prepare(s, env);
    }
    pub fn view(a: std.mem.Allocator, s: *Session, env: *const zmeta.Env) []const forest.Node {
        return routes.viewNodes(a, s, env);
    }
    pub fn pageLive(s: *Session) bool {
        _ = s;
        return false; // read-only blog — no live bindings
    }

    /// Raw endpoints (rss.xml/sitemap.xml/robots.txt): render into a
    /// fresh arena, write verbatim, report the route's content type.
    pub fn serveRaw(
        s: *Session,
        path: []const u8,
        writer: anytype,
    ) !bool {
        var arena = std.heap.ArenaAllocator.init(s.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const env = zmeta.Env{ .route = path, .query = s.query };
        const body = routes.raw(a, s, path, &env) catch return error.RawFailed;
        const b = body orelse return false;
        try writer.writeAll(b);
        return true;
    }

    pub fn endpointContentType(s: *Session, path: []const u8) ?[]const u8 {
        _ = s;
        return routes.contentType(path);
    }

    pub fn headSpec(s: *Session, a: std.mem.Allocator, env: *const zmeta.Env) ?zmeta.HeadSpec {
        return routes.headSpec(s, a, env);
    }

    pub fn dispatch(
        s: *Session,
        action: []const u8,
        arg: ?[]const u8,
        value: ?[]const u8,
        fields: ?*const std.json.ObjectMap,
    ) !void {
        return actions.dispatch(s, action, arg, value, fields);
    }
};

pub const Session = zmeta.Session(BlogDeps);
