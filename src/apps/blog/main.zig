//! zblog executable entry point: `zblog [port] [bind-ip] [content-dir]`.
//! The app itself lives alongside this file under `src/apps/blog/`
//! (pages/, app.zig, content.zig, actions.zig manifest, generated
//! gen/, content/ markdown files) — only framework code stays at the
//! `src/` root of THIS repo; the framework lives in ../zforest.
//!
//! `content-dir` (argv[3]) overrides the markdown root — default
//! `src/apps/blog/content`, resolved relative to the CWD (run from
//! the repo root: `zig build run-blog`).
const std = @import("std");
const server = @import("zserver");
const app = @import("app.zig");

/// Parse the optional `bind-ip` arg: a dotted IPv4 literal, or loopback
/// for anything unparsable (safe default for a demo server).
fn bindIp(arg: ?[]const u8) std.Io.net.Ip4Address {
    const s = arg orelse return .loopback(0);
    return std.Io.net.Ip4Address.parse(s, 0) catch .loopback(0);
}

pub fn main(init: std.process.Init) !void {
    const argv = init.minimal.args.vector;
    const port: u16 = if (argv.len < 2) 8085 else std.fmt.parseInt(u16, std.mem.span(argv[1]), 10) catch 8085;
    var bind = bindIp(if (argv.len < 3) null else std.mem.span(argv[2]));
    bind.port = port;
    const content_dir = if (argv.len > 3) std.mem.span(argv[3]) else app.default_content_dir;

    // Content loads once, up front — a missing dir is NOT fatal
    // (empty blog still serves index/rss/sitemap/robots).
    try app.initContent(init.io, init.gpa, content_dir);
    errdefer app.deinitContent();

    std.debug.print("zblog: {d} posts, {d} pages from {s}\n", .{
        app.content().posts.len,
        app.content().pages.len,
        content_dir,
    });

    try server.serve(init.gpa, init.io, bind, app.Session);
}

test {
    // Pull app + generated modules into the test binary so their
    // colocated test blocks are discovered by `zig build test`.
    _ = @import("app.zig");
    _ = @import("content.zig");
    _ = @import("views.zig");
    _ = @import("gen/routes.zig");
    _ = @import("gen/actions.zig");
}
