//! mcp — MCP (Model Context Protocol) client for zllm, Streamable
//! HTTP transport only (JSON-RPC 2.0 over POST; responses may be
//! `application/json` or `text/event-stream`).
//!
//! Config lives in the `cfg.mcp_servers` field — a JSON array:
//!   [{"name":"fs","url":"http://127.0.0.1:8080/mcp",
//!     "headers":{"Authorization":"Bearer …"}}]
//!
//! Two worker jobs (state.JobKind):
//!   - `mcp_check` — body = the servers config JSON. Per server:
//!     initialize → notifications/initialized → tools/list, then one
//!     `.mcp` event carrying the tools re-serialized as an OpenAI
//!     `tools` array (namespaced `mcp__<server>__<tool>`).
//!   - `mcp_call` — url = server endpoint, body = tools/call `params`
//!     object, extra = headers JSON object, pos_* = call position.
//!     Same handshake, then tools/call → `.mcp_call` event.
//!
//! Every JSON-RPC exchange is logged to the inspector via `.req`
//! (outbound) and `.raw` (inbound) — applyEv relabels them "mcp"
//! for these job kinds.
const std = @import("std");
const Io = std.Io;
const state = @import("state.zig");

/// Protocol revision we offer; servers may negotiate another.
const PROTOCOL_VERSION = "2025-03-26";
const MAX_SERVERS = 8;
const MAX_BODY = 4 * 1024 * 1024;

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const Server = struct {
    name: []const u8,
    url: []const u8,
    headers: []Header = &.{},
};

pub fn freeServers(gpa: std.mem.Allocator, servers: []Server) void {
    for (servers) |s| {
        gpa.free(s.name);
        gpa.free(s.url);
        for (s.headers) |h| {
            gpa.free(h.name);
            gpa.free(h.value);
        }
        gpa.free(s.headers);
    }
    gpa.free(servers);
}

fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 32) return false;
    // "__" is the mcp__<server>__<tool> separator — forbid it inside
    // names so wire names stay unambiguous.
    if (std.mem.indexOf(u8, name, "__") != null) return false;
    for (name) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-')) return false;
    }
    return true;
}

fn parseHeaders(gpa: std.mem.Allocator, v: std.json.Value) ![]Header {
    const obj = switch (v) {
        .object => |o| o,
        else => return error.BadHeaders,
    };
    if (obj.count() > 8) return error.TooMany;
    const hs = try gpa.alloc(Header, obj.count());
    var n: usize = 0;
    errdefer {
        for (hs[0..n]) |h| {
            gpa.free(h.name);
            gpa.free(h.value);
        }
        gpa.free(hs);
    }
    var it = obj.iterator();
    while (it.next()) |e| {
        const k = e.key_ptr.*;
        const val = switch (e.value_ptr.*) {
            .string => |s| s,
            else => return error.BadHeaders,
        };
        if (k.len == 0 or k.len > 64 or val.len > 512) return error.BadHeaders;
        hs[n] = .{ .name = state.dupe(gpa, k), .value = state.dupe(gpa, val) };
        n += 1;
    }
    return hs;
}

/// Parse + validate the servers config JSON. All strings duped into
/// `gpa`; caller frees via `freeServers`.
pub fn parseConfig(gpa: std.mem.Allocator, json: []const u8) ![]Server {
    if (std.mem.trim(u8, json, " \t\r\n").len == 0) return &.{};
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, json, .{}) catch return error.BadJson;
    defer parsed.deinit();
    const arr = switch (parsed.value) {
        .array => |a| a,
        else => return error.NotArray,
    };
    if (arr.items.len > MAX_SERVERS) return error.TooMany;
    const servers = try gpa.alloc(Server, arr.items.len);
    var n: usize = 0;
    errdefer {
        for (servers[0..n]) |s| {
            gpa.free(s.name);
            gpa.free(s.url);
            for (s.headers) |h| {
                gpa.free(h.name);
                gpa.free(h.value);
            }
            gpa.free(s.headers);
        }
        gpa.free(servers);
    }
    for (arr.items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => return error.BadServer,
        };
        const name_v = obj.get("name") orelse return error.BadServer;
        const name = switch (name_v) {
            .string => |s| s,
            else => return error.BadServer,
        };
        if (!validName(name)) return error.BadName;
        const url_v = obj.get("url") orelse return error.BadServer;
        const url = switch (url_v) {
            .string => |s| s,
            else => return error.BadServer,
        };
        if (url.len == 0 or url.len > 512) return error.BadServer;
        const u = std.Uri.parse(url) catch return error.BadUrl;
        if (!std.mem.eql(u8, u.scheme, "http") and !std.mem.eql(u8, u.scheme, "https")) return error.BadUrl;
        var headers: []Header = &.{};
        if (obj.get("headers")) |hv| headers = try parseHeaders(gpa, hv);
        servers[n] = .{
            .name = state.dupe(gpa, name),
            .url = state.dupe(gpa, url),
            .headers = headers,
        };
        n += 1;
    }
    return servers[0..n];
}

// ── wire names ───────────────────────────────────────────────────

/// `mcp__<server>__<tool>` → {server, tool}; null when not MCP.
pub fn parseWireName(name: []const u8) ?struct { server: []const u8, tool: []const u8 } {
    if (!std.mem.startsWith(u8, name, "mcp__")) return null;
    const rest = name["mcp__".len..];
    const sep = std.mem.indexOf(u8, rest, "__") orelse return null;
    const server = rest[0..sep];
    const tool = rest[sep + 2 ..];
    if (server.len == 0 or tool.len == 0) return null;
    return .{ .server = server, .tool = tool };
}

/// Serialize an MCP `tools/list` result into an OpenAI `tools` array
/// with namespaced names. Returns "[]" when the server has no tools.
fn toolsToOpenAi(gpa: std.mem.Allocator, tools_v: std.json.Value, server: []const u8) []const u8 {
    const items = switch (tools_v) {
        .array => |a| a.items,
        else => return state.dupe(gpa, "[]"),
    };
    var aw: std.Io.Writer.Allocating = .init(gpa);
    const w = &aw.writer;
    w.writeByte('[') catch @panic("OOM");
    var emitted: usize = 0;
    for (items) |t| {
        const obj = switch (t) {
            .object => |o| o,
            else => continue,
        };
        const name_v = obj.get("name") orelse continue;
        const tname = switch (name_v) {
            .string => |s| s,
            else => continue,
        };
        if (tname.len == 0 or tname.len > 128) continue;
        const wire = std.fmt.allocPrint(gpa, "mcp__{s}__{s}", .{ server, tname }) catch continue;
        defer gpa.free(wire);
        if (emitted != 0) w.writeByte(',') catch @panic("OOM");
        emitted += 1;
        w.writeAll("{\"type\":\"function\",\"function\":{\"name\":") catch @panic("OOM");
        state.jsonStrPub(w, wire) catch @panic("OOM");
        if (obj.get("description")) |dv| {
            if (dv == .string) {
                w.writeAll(",\"description\":") catch @panic("OOM");
                state.jsonStrPub(w, dv.string) catch @panic("OOM");
            }
        }
        w.writeAll(",\"parameters\":") catch @panic("OOM");
        if (obj.get("inputSchema")) |sv| {
            std.json.Stringify.value(sv, .{}, w) catch @panic("OOM");
        } else {
            w.writeAll("{\"type\":\"object\",\"properties\":{}}") catch @panic("OOM");
        }
        w.writeAll("}}") catch @panic("OOM");
    }
    w.writeByte(']') catch @panic("OOM");
    return aw.toOwnedSlice() catch @panic("OOM");
}

/// Extract human-readable text from a tools/call `result` value:
/// content[].text joined, structuredContent as JSON fallback.
fn callResultText(gpa: std.mem.Allocator, result: std.json.Value) []const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var is_err = false;
    if (result == .object) {
        const obj = result.object;
        if (obj.get("isError")) |v| {
            is_err = v == .bool and v.bool;
        }
        if (obj.get("content")) |cv| {
            if (cv == .array) {
                for (cv.array.items) |item| {
                    if (item != .object) continue;
                    const it = item.object;
                    const t = it.get("type") orelse continue;
                    if (t != .string or !std.mem.eql(u8, t.string, "text")) continue;
                    if (it.get("text")) |tv| {
                        if (tv == .string and tv.string.len != 0) {
                            if (out.items.len != 0) out.append(gpa, '\n') catch @panic("OOM");
                            out.appendSlice(gpa, tv.string) catch @panic("OOM");
                        }
                    }
                }
            }
        }
        if (out.items.len == 0) {
            if (obj.get("structuredContent")) |sc| {
                var aw: std.Io.Writer.Allocating = .init(gpa);
                defer aw.deinit();
                std.json.Stringify.value(sc, .{ .whitespace = .indent_2 }, &aw.writer) catch {};
                if (aw.written().len != 0) {
                    out.appendSlice(gpa, aw.written()) catch @panic("OOM");
                }
            }
        }
    }
    if (out.items.len == 0) {
        var aw: std.Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        std.json.Stringify.value(result, .{ .whitespace = .indent_2 }, &aw.writer) catch {};
        if (aw.written().len != 0) out.appendSlice(gpa, aw.written()) catch @panic("OOM");
    }
    if (out.items.len == 0) out.appendSlice(gpa, "(empty result)") catch @panic("OOM");
    const text = out.toOwnedSlice(gpa) catch @panic("OOM");
    if (is_err) {
        const prefixed = std.fmt.allocPrint(gpa, "error: {s}", .{text}) catch @panic("OOM");
        gpa.free(text);
        return prefixed;
    }
    return text;
}

// ── connection ───────────────────────────────────────────────────

const Conn = struct {
    gpa: std.mem.Allocator,
    io: Io,
    client: std.http.Client,
    url: []const u8,
    /// Custom headers from server config ("" → none).
    headers_json: []const u8 = "",
    /// Negotiated session id + protocol version ("" until initialize).
    session_id: []u8 = &.{},
    proto_ver: []u8 = &.{},
    alive: *std.atomic.Value(bool),
    cancel: *std.atomic.Value(bool),

    fn deinit(self: *Conn) void {
        self.client.deinit();
        if (self.session_id.len != 0) self.gpa.free(self.session_id);
        if (self.proto_ver.len != 0) self.gpa.free(self.proto_ver);
    }

    fn init(gpa: std.mem.Allocator, io: Io, url: []const u8, headers_json: []const u8, alive: *std.atomic.Value(bool), cancel: *std.atomic.Value(bool)) Conn {
        return .{
            .gpa = gpa,
            .io = io,
            .client = .{ .allocator = gpa, .io = io },
            .url = url,
            .headers_json = headers_json,
            .alive = alive,
            .cancel = cancel,
        };
    }

    fn cancelled(self: *const Conn) bool {
        return !self.alive.load(.seq_cst) or self.cancel.load(.seq_cst);
    }
};

const RpcError = error{ Http, Rpc, BadJson, NoResponse, Cancelled };

/// POST one JSON-RPC envelope; returns the parsed response VALUE
/// (the whole envelope — caller reads .result/.error). Pushes `.req`
/// and `.raw` inspector events. Empty-body responses (notifications,
/// 202) return error.NoResponse — callers that expect them use
/// `postRaw` instead.
fn rpc(c: *Conn, mb: *state.Mailbox, body: []const u8) !std.json.Parsed(std.json.Value) {
    const text = try postRaw(c, mb, body);
    defer c.gpa.free(text);
    if (text.len == 0) return error.NoResponse;
    return std.json.parseFromSlice(std.json.Value, c.gpa, text, .{}) catch return error.BadJson;
}

/// POST a body that may legitimately get an empty response
/// (notifications/initialized → 202). Returns response text or "".
fn postRaw(c: *Conn, mb: *state.Mailbox, body: []const u8) ![]u8 {
    const uri = std.Uri.parse(c.url) catch return error.Http;
    var client_headers: std.ArrayListUnmanaged(std.http.Header) = .empty;
    defer client_headers.deinit(c.gpa);
    try client_headers.append(c.gpa, .{ .name = "content-type", .value = "application/json" });
    try client_headers.append(c.gpa, .{ .name = "accept", .value = "application/json, text/event-stream" });
    // Custom headers from config.
    if (c.headers_json.len != 0 and std.mem.trim(u8, c.headers_json, " \t").len != 0) {
        var hp = std.json.parseFromSlice(std.json.Value, c.gpa, c.headers_json, .{}) catch return error.Http;
        defer hp.deinit();
        if (hp.value == .object) {
            var it = hp.value.object.iterator();
            while (it.next()) |e| {
                const k = e.key_ptr.*;
                const v = switch (e.value_ptr.*) {
                    .string => |s| s,
                    else => continue,
                };
                try client_headers.append(c.gpa, .{ .name = k, .value = v });
            }
        }
    }
    if (c.session_id.len != 0) {
        try client_headers.append(c.gpa, .{ .name = "mcp-session-id", .value = c.session_id });
    }
    if (c.proto_ver.len != 0) {
        try client_headers.append(c.gpa, .{ .name = "mcp-protocol-version", .value = c.proto_ver });
    }

    // Inspector: outbound JSON-RPC (pretty like chat requests).
    const pb = state.prettyJson(c.gpa, body);
    defer c.gpa.free(pb);
    const desc = std.fmt.allocPrint(c.gpa, "MCP POST {s}\n\n{s}", .{ c.url, pb }) catch return error.Http;
    mb.push(.{ .req = desc });

    var req = c.client.request(.POST, uri, .{
        .keep_alive = true,
        .extra_headers = client_headers.items,
    }) catch return error.Http;
    defer req.deinit();
    req.headers.accept_encoding = .omit;
    req.sendBodyComplete(@constCast(body)) catch return error.Http;

    var rdbuf: [4096]u8 = undefined;
    var resp = req.receiveHead(&rdbuf) catch return error.Http;

    // Session id arrives on the initialize response — scan the raw
    // head bytes (Head only pre-parses a few well-known fields).
    if (headValue(resp.head.bytes, "mcp-session-id")) |v| {
        if (c.session_id.len != 0) c.gpa.free(c.session_id);
        c.session_id = c.gpa.dupe(u8, v) catch @panic("OOM");
    }

    // Capture head strings BEFORE resp.reader(): the reader recycles
    // the head buffer and invalidateStrings() poisons the slices
    // (observed as 0xAA reads → segfault). Dupe — even the dupe must
    // happen pre-reader.
    const ct = c.gpa.dupe(u8, resp.head.content_type orelse "") catch return error.Http;
    defer c.gpa.free(ct);
    const status = resp.head.status;

    var tb: [8192]u8 = undefined;
    const rdr = resp.reader(&tb);
    if (status != .ok and status != .accepted) {
        const snippet = rdr.allocRemaining(c.gpa, .limited(1024)) catch "";
        defer if (snippet.len != 0) c.gpa.free(snippet);
        const note = std.fmt.allocPrint(c.gpa, "HTTP {d}: {s}", .{ @backingInt(status), snippet }) catch null;
        if (note) |nn| mb.push(.{ .raw = nn });
        return error.Http;
    }
    const is_sse = std.mem.indexOf(u8, ct, "text/event-stream") != null;
    const raw = rdr.allocRemaining(c.gpa, .limited(MAX_BODY)) catch return error.Http;
    defer c.gpa.free(raw);

    if (!is_sse) {
        // application/json (or empty 202) — return as-is.
        mb.push(.{ .raw = state.dupe(c.gpa, if (raw.len != 0) raw else "(empty)") });
        return c.gpa.dupe(u8, raw);
    }
    // SSE: collect `data:` event payloads; pick the first that looks
    // like a JSON-RPC response (has "result" or "error"), else the
    // last non-empty payload.
    var payloads: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (payloads.items) |p| c.gpa.free(p);
        payloads.deinit(c.gpa);
    }
    var cur: std.ArrayListUnmanaged(u8) = .empty;
    defer cur.deinit(c.gpa);
    var it = std.mem.splitScalar(u8, raw, '\n');
    while (it.next()) |line0| {
        const line = std.mem.trimEnd(u8, line0, "\r");
        if (line.len == 0) {
            if (cur.items.len != 0) {
                const p = c.gpa.dupe(u8, cur.items) catch @panic("OOM");
                payloads.append(c.gpa, p) catch @panic("OOM");
                cur.clearRetainingCapacity();
            }
            continue;
        }
        if (std.mem.startsWith(u8, line, "data:")) {
            var d = line["data:".len..];
            d = std.mem.trimStart(u8, d, " ");
            if (cur.items.len != 0) cur.append(c.gpa, '\n') catch @panic("OOM");
            cur.appendSlice(c.gpa, d) catch @panic("OOM");
        }
    }
    if (cur.items.len != 0) {
        const p = c.gpa.dupe(u8, cur.items) catch @panic("OOM");
        payloads.append(c.gpa, p) catch @panic("OOM");
    }
    var fallback: ?[]const u8 = null;
    for (payloads.items) |p| {
        const t = std.mem.trim(u8, p, " \t\r\n");
        if (t.len == 0) continue;
        fallback = t;
        if (std.mem.indexOf(u8, t, "\"result\"") != null or std.mem.indexOf(u8, t, "\"error\"") != null) {
            mb.push(.{ .raw = state.dupe(c.gpa, t) });
            return c.gpa.dupe(u8, t);
        }
    }
    if (fallback) |f| {
        mb.push(.{ .raw = state.dupe(c.gpa, f) });
        return c.gpa.dupe(u8, f);
    }
    mb.push(.{ .raw = state.dupe(c.gpa, "(empty SSE stream)") });
    return c.gpa.dupe(u8, "");
}

/// Case-insensitive header lookup in a raw HTTP head block
/// ("Name: value\r\n…\r\n"). Returns the trimmed value slice.
fn headValue(head: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitSequence(u8, head, "\r\n");
    _ = it.next(); // status line
    while (it.next()) |line| {
        if (line.len == 0) return null;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const k = std.mem.trim(u8, line[0..colon], " \t");
        if (std.ascii.eqlIgnoreCase(k, name)) {
            return std.mem.trim(u8, line[colon + 1 ..], " \t");
        }
    }
    return null;
}

fn envelope(gpa: std.mem.Allocator, id: u32, method: []const u8, params: []const u8) []const u8 {
    return std.fmt.allocPrint(gpa, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"{s}\",\"params\":{s}}}", .{ id, method, if (params.len != 0) params else "null" }) catch @panic("OOM");
}

fn notification(gpa: std.mem.Allocator, method: []const u8) []const u8 {
    return std.fmt.allocPrint(gpa, "{{\"jsonrpc\":\"2.0\",\"method\":\"{s}\"}}", .{method}) catch @panic("OOM");
}

const INIT_PARAMS =
    \\{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"zllm","version":"0.1.0"}}
;

/// initialize → notifications/initialized. Fills session_id/proto_ver.
fn handshake(c: *Conn, mb: *state.Mailbox) !void {
    const body = envelope(c.gpa, 1, "initialize", INIT_PARAMS);
    defer c.gpa.free(body);
    var env = try rpc(c, mb, body);
    defer env.deinit();
    if (c.cancelled()) return error.Cancelled;
    const result = switch (env.value) {
        .object => |o| o.get("result") orelse return error.Rpc,
        else => return error.Rpc,
    };
    if (result == .object) {
        if (result.object.get("protocolVersion")) |pv| {
            // Dupe — env.deinit() frees the parse arena.
            if (pv == .string and pv.string.len != 0 and pv.string.len <= 64) {
                c.proto_ver = c.gpa.dupe(u8, pv.string) catch @panic("OOM");
            }
        }
    }
    const note = notification(c.gpa, "notifications/initialized");
    defer c.gpa.free(note);
    _ = try postRaw(c, mb, note);
}

// ── workers ──────────────────────────────────────────────────────

fn pushCheck(mb: *state.Mailbox, server: []const u8, ok: bool, detail: []const u8, tools_json: []const u8) void {
    mb.push(.{ .mcp = .{
        .server = state.dupe(mb.gpa, server),
        .ok = ok,
        .detail = state.dupe(mb.gpa, detail),
        .tools_json = state.dupe(mb.gpa, tools_json),
    } });
}

fn checkOne(mb: *state.Mailbox, srv: Server) void {
    const gpa = mb.gpa;
    var conn = Conn.init(gpa, mb.io, srv.url, "", &mb.alive, &mb.cancel);
    defer conn.deinit();
    errdefer {
        // Errors are reported by the caller via pushCheck.
    }
    handshake(&conn, mb) catch |e| {
        const msg = switch (e) {
            error.Http => "HTTP error",
            error.Rpc => "initialize failed (JSON-RPC error)",
            error.BadJson => "bad JSON response",
            error.NoResponse => "empty response",
            error.Cancelled => "cancelled",
            error.OutOfMemory => "out of memory",
        };
        pushCheck(mb, srv.name, false, msg, "[]");
        return;
    };
    const body = envelope(gpa, 2, "tools/list", "{}");
    defer gpa.free(body);
    var env = rpc(&conn, mb, body) catch |e| {
        const msg = switch (e) {
            error.Http => "HTTP error",
            error.BadJson => "tools/list failed",
            error.NoResponse => "empty response",
            error.OutOfMemory => "out of memory",
        };
        pushCheck(mb, srv.name, false, msg, "[]");
        return;
    };
    defer env.deinit();
    if (env.value == .object) {
        if (env.value.object.get("error")) |ev| {
            var msg_buf: [256]u8 = undefined;
            var msg: []const u8 = "tools/list error";
            if (ev == .object) {
                if (ev.object.get("message")) |mv| {
                    if (mv == .string) msg = mv.string;
                }
            }
            const d = std.fmt.bufPrint(&msg_buf, "{s}", .{msg}) catch msg;
            pushCheck(mb, srv.name, false, d, "[]");
            return;
        }
    }
    const result = switch (env.value) {
        .object => |o| o.get("result") orelse {
            pushCheck(mb, srv.name, false, "no result in tools/list", "[]");
            return;
        },
        else => {
            pushCheck(mb, srv.name, false, "bad tools/list response", "[]");
            return;
        },
    };
    // `result` is {"tools": [...]} — toolsToOpenAi wants the array.
    const tools_v = if (result == .object) result.object.get("tools") orelse result else result;
    const tools_json = toolsToOpenAi(gpa, tools_v, srv.name);
    // Accurate tool count from the tools array length.
    var n: usize = 0;
    if (result == .object) {
        if (result.object.get("tools")) |tv| {
            if (tv == .array) n = tv.array.items.len;
        }
    }
    var dbuf: [128]u8 = undefined;
    const detail = std.fmt.bufPrint(&dbuf, "ok — {d} tool(s), protocol {s}", .{ n, if (conn.proto_ver.len != 0) conn.proto_ver else "?" }) catch "ok";
    pushCheck(mb, srv.name, true, detail, tools_json);
    gpa.free(tools_json);
}

/// `mcp_check` job: body = servers config JSON.
pub fn checkWorker(mb: *state.Mailbox) void {
    const gpa = mb.gpa;
    const servers = parseConfig(gpa, mb.job.body) catch |e| {
        const msg = switch (e) {
            error.BadJson => "invalid JSON",
            error.NotArray => "config must be a JSON array",
            error.TooMany => "too many servers (max 8)",
            error.BadServer, error.BadName, error.BadUrl, error.BadHeaders => "invalid server entry",
            error.OutOfMemory => "out of memory",
        };
        pushCheck(mb, "config", false, msg, "[]");
        return;
    };
    defer freeServers(gpa, servers);
    if (servers.len == 0) {
        pushCheck(mb, "config", false, "no servers configured", "[]");
        return;
    }
    for (servers) |srv| {
        if (!mb.alive.load(.seq_cst) or mb.cancel.load(.seq_cst)) break;
        checkOne(mb, srv);
    }
}

pub fn headersJsonFor(gpa: std.mem.Allocator, headers: []const Header) []const u8 {
    if (headers.len == 0) return state.dupe(gpa, "{}");
    var aw: std.Io.Writer.Allocating = .init(gpa);
    const w = &aw.writer;
    w.writeByte('{') catch @panic("OOM");
    for (headers, 0..) |h, i| {
        if (i != 0) w.writeByte(',') catch @panic("OOM");
        state.jsonStrPub(w, h.name) catch @panic("OOM");
        w.writeByte(':') catch @panic("OOM");
        state.jsonStrPub(w, h.value) catch @panic("OOM");
    }
    w.writeByte('}') catch @panic("OOM");
    return aw.toOwnedSlice() catch @panic("OOM");
}

/// `mcp_call` job: url = endpoint, body = tools/call params object,
/// extra = headers JSON, pos_* = call position.
pub fn callWorker(mb: *state.Mailbox) void {
    const gpa = mb.gpa;
    const job = &mb.job;
    var conn = Conn.init(gpa, mb.io, job.url, job.extra, &mb.alive, &mb.cancel);
    defer conn.deinit();

    const fail = struct {
        fn push(m: *state.Mailbox, text: []const u8) void {
            m.push(.{ .mcp_call = .{
                .conv = m.job.pos_conv,
                .msg = m.job.pos_msg,
                .call = m.job.pos_call,
                .ok = false,
                .text = state.dupe(m.gpa, text),
            } });
        }
    }.push;

    handshake(&conn, mb) catch |e| {
        const msg = switch (e) {
            error.Http => "mcp: HTTP error during initialize",
            error.Rpc => "mcp: initialize failed",
            error.BadJson => "mcp: bad JSON response",
            error.NoResponse => "mcp: empty response",
            error.Cancelled => "stopped by user",
            error.OutOfMemory => "out of memory",
        };
        fail(mb, msg);
        return;
    };
    const body = envelope(gpa, 2, "tools/call", job.body);
    defer gpa.free(body);
    var env = rpc(&conn, mb, body) catch |e| {
        const msg = switch (e) {
            error.Http => "mcp: HTTP error",
            error.BadJson => "mcp: tools/call failed",
            error.NoResponse => "mcp: empty response",
            error.OutOfMemory => "out of memory",
        };
        fail(mb, msg);
        return;
    };
    defer env.deinit();
    if (env.value == .object) {
        if (env.value.object.get("error")) |ev| {
            var msg_buf: [512]u8 = undefined;
            var msg: []const u8 = "mcp: tools/call error";
            if (ev == .object) {
                if (ev.object.get("message")) |mv| {
                    if (mv == .string and mv.string.len <= msg_buf.len) msg = mv.string;
                }
            }
            const d = std.fmt.bufPrint(&msg_buf, "{s}", .{msg}) catch msg;
            fail(mb, d);
            return;
        }
    }
    const result = switch (env.value) {
        .object => |o| o.get("result") orelse {
            fail(mb, "mcp: no result in tools/call response");
            return;
        },
        else => {
            fail(mb, "mcp: bad tools/call response");
            return;
        },
    };
    const text = callResultText(gpa, result);
    mb.push(.{ .mcp_call = .{
        .conv = job.pos_conv,
        .msg = job.pos_msg,
        .call = job.pos_call,
        .ok = true,
        .text = text,
    } });
}

// ── tests ────────────────────────────────────────────────────────

test "parseConfig validates servers" {
    const gpa = std.testing.allocator;
    const servers = try parseConfig(gpa, "[{\"name\":\"fs\",\"url\":\"http://127.0.0.1:8080/mcp\",\"headers\":{\"Authorization\":\"Bearer x\"}}]");
    defer freeServers(gpa, servers);
    try std.testing.expectEqual(@as(usize, 1), servers.len);
    try std.testing.expectEqualStrings("fs", servers[0].name);
    try std.testing.expectEqualStrings("http://127.0.0.1:8080/mcp", servers[0].url);
    try std.testing.expectEqual(@as(usize, 1), servers[0].headers.len);
    try std.testing.expectEqualStrings("Authorization", servers[0].headers[0].name);

    try std.testing.expectError(error.BadJson, parseConfig(gpa, "nope"));
    try std.testing.expectError(error.NotArray, parseConfig(gpa, "{}"));
    try std.testing.expectError(error.BadName, parseConfig(gpa, "[{\"name\":\"a__b\",\"url\":\"http://x\"}]"));
    try std.testing.expectError(error.BadUrl, parseConfig(gpa, "[{\"name\":\"a\",\"url\":\"ftp://x\"}]"));
    try std.testing.expectEqual(@as(usize, 0), (try parseConfig(gpa, "[]")).len);
}

test "parseWireName splits namespaced tools" {
    const r = parseWireName("mcp__fs__read_file").?;
    try std.testing.expectEqualStrings("fs", r.server);
    try std.testing.expectEqualStrings("read_file", r.tool);
    // tool names may contain "__" — split at the FIRST separator.
    const r2 = parseWireName("mcp__fs__a__b").?;
    try std.testing.expectEqualStrings("a__b", r2.tool);
    try std.testing.expect(parseWireName("calculator") == null);
    try std.testing.expect(parseWireName("mcp__onlyserver") == null);
}

test "toolsToOpenAi unwraps tools array and namespaces names" {
    const gpa = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa,
        \\[{"name":"echo","description":"Echo text","inputSchema":{"type":"object","properties":{"text":{"type":"string"}}}}]
    , .{});
    defer parsed.deinit();
    const out = toolsToOpenAi(gpa, parsed.value, "mock");
    defer gpa.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "mcp__mock__echo") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"type\":\"function\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"parameters\"") != null);
    // Non-array input yields an empty tools payload.
    const obj = try std.json.parseFromSlice(std.json.Value, gpa, "{\"tools\":[]}", .{});
    defer obj.deinit();
    const empty = toolsToOpenAi(gpa, obj.value, "mock");
    defer gpa.free(empty);
    try std.testing.expectEqualStrings("[]", empty);
}
