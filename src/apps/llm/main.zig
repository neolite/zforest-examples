const std = @import("std");
const server = @import("zserver");
const llm = @import("app.zig");

/// Parse the optional `bind-ip` arg: a dotted IPv4 literal, or loopback
/// for anything unparsable (safe default for a demo server).
fn bindIp(arg: ?[]const u8) std.Io.net.Ip4Address {
    const s = arg orelse return .loopback(0);
    return std.Io.net.Ip4Address.parse(s, 0) catch .loopback(0);
}

const DotEnv = struct {
    api_key: ?[]u8 = null,
    endpoint: ?[]u8 = null,
};

/// Minimal dotenv: first `KEY=VALUE` wins, `#` comments and optional
/// double quotes handled. Real environment variables take precedence
/// — .env only fills gaps. Looked up relative to the cwd so both
/// `zig build run-llm` (repo root) and running inside src/apps/llm
/// work.
fn loadDotEnv(io: std.Io, gpa: std.mem.Allocator) DotEnv {
    var out: DotEnv = .{};
    const paths = [_][]const u8{ "src/apps/llm/.env", ".env" };
    for (paths) |path| {
        const data = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 * 1024)) catch continue;
        var it = std.mem.splitScalar(u8, data, '\n');
        while (it.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const k = std.mem.trim(u8, line[0..eq], " \t");
            var v = std.mem.trim(u8, line[eq + 1 ..], " \t\r");
            if (v.len >= 2 and v[0] == '"' and v[v.len - 1] == '"') v = v[1 .. v.len - 1];
            if (std.mem.eql(u8, k, "ZLLM_API_KEY") and out.api_key == null) {
                out.api_key = gpa.dupe(u8, v) catch null;
            } else if (std.mem.eql(u8, k, "ZLLM_API_ENDPOINT") and out.endpoint == null) {
                out.endpoint = gpa.dupe(u8, v) catch null;
            }
        }
        gpa.free(data);
        if (out.api_key != null and out.endpoint != null) break;
    }
    return out;
}

/// `zllm [port] [bind-ip]` — defaults 8090 / 127.0.0.1.
/// `ZLLM_API_KEY` / `ZLLM_API_ENDPOINT` (env or src/apps/llm/.env)
/// seed every session's api_key + base_url (key never rendered back).
pub fn main(init: std.process.Init) !void {
    const argv = init.minimal.args.vector;
    const port: u16 = if (argv.len < 2) 8090 else std.fmt.parseInt(u16, std.mem.span(argv[1]), 10) catch 8090;
    var bind = bindIp(if (argv.len < 3) null else std.mem.span(argv[2]));
    bind.port = port;

    const de = loadDotEnv(init.io, init.gpa);
    const api_key = init.environ_map.get("ZLLM_API_KEY") orelse de.api_key;
    if (api_key) |key| {
        if (key.len != 0) llm.setEnvApiKey(key);
    }
    const endpoint = init.environ_map.get("ZLLM_API_ENDPOINT") orelse de.endpoint;
    if (endpoint) |ep| {
        if (ep.len != 0) llm.setEnvEndpoint(ep);
    }
    // MCP servers: ZLLM_MCP_JSON env wins, else mcp.json next to the
    // app (.env-style lookup: src/apps/llm/mcp.json, then ./mcp.json).
    const mcp_json = init.environ_map.get("ZLLM_MCP_JSON") orelse blk: {
        const paths = [_][]const u8{ "src/apps/llm/mcp.json", "mcp.json" };
        for (paths) |path| {
            const data = std.Io.Dir.cwd().readFileAlloc(init.io, path, init.gpa, .limited(64 * 1024)) catch continue;
            break :blk data;
        }
        break :blk null;
    };
    if (mcp_json) |mj| {
        if (mj.len != 0) llm.setEnvMcpServers(mj);
    }

    try server.serve(init.gpa, init.io, bind, llm.Session);
}

test {
    _ = @import("app.zig");
    _ = @import("state.zig");
    _ = @import("tools.zig");
    _ = @import("openai.zig");
    _ = @import("mcp.zig");
    _ = @import("presets.zig");
}
