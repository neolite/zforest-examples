//! "/robots.txt" — raw endpoint, no content_type → server defaults
//! to text/plain. Allows everything, points crawlers at the sitemap.
const std = @import("std");
const zmeta = @import("../zmeta.zig");
const app = @import("../app.zig");

pub const params = struct {};

pub fn api(
    a: std.mem.Allocator,
    s: anytype,
    p: params,
    env: *const zmeta.Env,
) ![]const u8 {
    _ = s;
    _ = p;
    _ = env;
    return std.fmt.allocPrint(
        a,
        "User-agent: *\n" ++
            "Allow: /\n" ++
            "\n" ++
            "# All published content is indexable; drafts never load.\n" ++
            "Sitemap: {s}/sitemap.xml\n",
        .{app.site_url},
    ) catch @panic("OOM");
}
