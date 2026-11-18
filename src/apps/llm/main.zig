const std = @import("std");
const server = @import("zserver");
const llm = @import("app.zig");

/// Parse the optional `bind-ip` arg: a dotted IPv4 literal, or loopback
/// for anything unparsable (safe default for a demo server).
fn bindIp(arg: ?[]const u8) std.Io.net.Ip4Address {
    const s = arg orelse return .loopback(0);
    return std.Io.net.Ip4Address.parse(s, 0) catch .loopback(0);
}

/// `zllm [port] [bind-ip]` — defaults 8090 / 127.0.0.1.
/// `ZLLM_API_KEY` seeds every session's api_key (never rendered back).
pub fn main(init: std.process.Init) !void {
    const argv = init.minimal.args.vector;
    const port: u16 = if (argv.len < 2) 8090 else std.fmt.parseInt(u16, std.mem.span(argv[1]), 10) catch 8090;
    var bind = bindIp(if (argv.len < 3) null else std.mem.span(argv[2]));
    bind.port = port;

    if (init.environ_map.get("ZLLM_API_KEY")) |key| {
        if (key.len != 0) llm.setEnvApiKey(key);
    }

    try server.serve(init.gpa, init.io, bind, llm.Session);
}

test {
    _ = @import("app.zig");
    _ = @import("state.zig");
    _ = @import("tools.zig");
    _ = @import("openai.zig");
    _ = @import("presets.zig");
}
