//! Root `_layout.zig` — zllm is a full-bleed console: the page node
//! already carries the whole `.llm` grid, so the layout passes the
//! inner content through untouched (contract requires the fn).
const std = @import("std");
const forest = @import("forest");
const zmeta = @import("../zmeta.zig");

pub fn layout(
    a: std.mem.Allocator,
    s: anytype,
    env: *const zmeta.Env,
    inner: forest.Node,
) forest.Node {
    _ = a;
    _ = s;
    _ = env;
    return inner;
}
