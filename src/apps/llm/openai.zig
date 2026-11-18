//! openai — OpenAI-compatible chat.completions client for zllm.
//!
//! Two halves:
//!   - `feedData`/`parseModels` — pure parsers (unit-tested without
//!     network): one SSE `data:` payload → Mailbox events; a GET
//!     /models body → id list.
//!   - `worker` — the detached thread: std.http.Client POST/GET →
//!     SSE line loop → Mailbox. It touches ONLY the Mailbox (own
//!     mutex) — never session/zefx state.
const std = @import("std");
const Io = std.Io;
const state = @import("state.zig");
const mcp = @import("mcp.zig");

// ── chunk JSON shape ─────────────────────────────────────────────

const Chunk = struct {
    choices: []const Choice = &.{},
    usage: ?UsageJ = null,
    /// Non-standard but seen in the wild: {"error":{...}} payloads.
    @"error": ?struct { message: ?[]const u8 = null } = null,
};

const Choice = struct {
    delta: ?Delta = null,
    finish_reason: ?[]const u8 = null,
};

const Delta = struct {
    content: ?[]const u8 = null,
    reasoning_content: ?[]const u8 = null,
    tool_calls: ?[]const ToolCallDelta = null,
};

const ToolCallDelta = struct {
    index: usize = 0,
    id: ?[]const u8 = null,
    function: ?struct {
        name: ?[]const u8 = null,
        arguments: ?[]const u8 = null,
    } = null,
};

const UsageJ = struct {
    prompt_tokens: ?u64 = null,
    completion_tokens: ?u64 = null,
    total_tokens: ?u64 = null,
};

/// Push the semantic events of one SSE `data:` payload. `[DONE]` →
/// `.done(null)`; malformed JSON → `.error` note (stream continues —
/// providers occasionally send keep-alive-ish junk). Called by the
/// worker AND directly by tests.
pub fn feedData(mb: *state.Mailbox, data: []const u8) void {
    const trimmed = std.mem.trim(u8, data, " \t\r\n");
    if (trimmed.len == 0) return;
    if (std.mem.eql(u8, trimmed, "[DONE]")) {
        mb.push(.{ .done = null });
        return;
    }
    var parsed = std.json.parseFromSlice(Chunk, mb.gpa, trimmed, .{ .ignore_unknown_fields = true }) catch {
        mb.push(.{ .err = state.dupe(mb.gpa, "unparseable SSE chunk") });
        return;
    };
    defer parsed.deinit();
    const chunk = parsed.value;

    if (chunk.@"error") |e| {
        const msg = e.message orelse "api error";
        mb.push(.{ .err = state.dupe(mb.gpa, msg) });
        return;
    }
    for (chunk.choices) |ch| {
        if (ch.delta) |d| {
            if (d.content) |c| {
                if (c.len != 0) mb.push(.{ .delta = state.dupe(mb.gpa, c) });
            }
            if (d.reasoning_content) |r| {
                if (r.len != 0) mb.push(.{ .reasoning = state.dupe(mb.gpa, r) });
            }
            if (d.tool_calls) |tcs| {
                for (tcs) |tc| {
                    const tf = tc.function;
                    mb.push(.{ .call_delta = .{
                        .index = @intCast(@min(tc.index, 255)),
                        .id = if (tc.id) |s| state.dupe(mb.gpa, s) else null,
                        .name = if (tf) |f| (if (f.name) |s| state.dupe(mb.gpa, s) else null) else null,
                        .args = if (tf) |f| (if (f.arguments) |s| state.dupe(mb.gpa, s) else null) else null,
                    } });
                }
            }
        }
        if (ch.finish_reason) |fr| {
            mb.push(.{ .done = state.dupe(mb.gpa, fr) });
        }
    }
    if (chunk.usage) |u| {
        mb.push(.{ .usage = .{
            .prompt = u.prompt_tokens orelse 0,
            .completion = u.completion_tokens orelse 0,
            .total = u.total_tokens orelse (u.prompt_tokens orelse 0) + (u.completion_tokens orelse 0),
        } });
    }
}

/// Parse a GET /models response body → owned id list (sorted for a
/// stable dropdown). Error union for the caller to surface.
pub fn parseModels(gpa: std.mem.Allocator, body: []const u8) ![][]const u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, body, .{}) catch return error.BadJson;
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.BadJson,
    };
    const data_v = obj.get("data") orelse return error.BadJson;
    const arr = switch (data_v) {
        .array => |a| a,
        else => return error.BadJson,
    };
    if (arr.items.len > 256) return error.TooMany;
    // Two passes: count valid ids, then fill an exact-size slice —
    // callers `free` the returned slice, so its len must match the
    // allocation (Allocator.free is size-class sensitive).
    var n: usize = 0;
    for (arr.items) |item| {
        const id_v = switch (item) {
            .object => |o| o.get("id") orelse continue,
            else => continue,
        };
        const id = switch (id_v) {
            .string => |s| s,
            else => continue,
        };
        if (id.len != 0 and id.len <= 200) n += 1;
    }
    const ids = try gpa.alloc([]const u8, n);
    var i: usize = 0;
    errdefer {
        for (ids[0..i]) |id| gpa.free(id);
        gpa.free(ids);
    }
    for (arr.items) |item| {
        const id_v = switch (item) {
            .object => |o| o.get("id") orelse continue,
            else => continue,
        };
        const id = switch (id_v) {
            .string => |s| s,
            else => continue,
        };
        if (id.len == 0 or id.len > 200) continue;
        ids[i] = state.dupe(gpa, id);
        i += 1;
    }
    std.mem.sort([]const u8, ids, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    return ids;
}

// ── worker thread ────────────────────────────────────────────────

fn pushErr(mb: *state.Mailbox, comptime fmt: []const u8, args: anytype) void {
    const s = std.fmt.allocPrint(mb.gpa, fmt, args) catch return;
    mb.push(.{ .err = s });
    mb.finished.store(true, .seq_cst);
}

fn pushRaw(mb: *state.Mailbox, s: []const u8) void {
    mb.push(.{ .raw = state.dupe(mb.gpa, s) });
}

/// SSE event accumulator: `data:` lines join with '\n' until a blank
/// line dispatches the payload.
const SseAcc = struct {
    gpa: std.mem.Allocator,
    buf: std.ArrayListUnmanaged(u8) = .empty,

    fn feed(self: *SseAcc, line: []const u8) void {
        var p = line["data:".len..];
        p = std.mem.trimStart(u8, p, " ");
        if (self.buf.items.len != 0) self.buf.append(self.gpa, '\n') catch @panic("OOM");
        self.buf.appendSlice(self.gpa, p) catch @panic("OOM");
    }
    /// Take the accumulated payload as an OWNED copy ("" when empty)
    /// and reset. Must dupe BEFORE clearing: clearRetainingCapacity
    /// memsets the buffer to undefined — returning items directly
    /// handed callers a slice into just-poisoned memory (observed as
    /// pure 0xAA SSE payloads).
    fn take(self: *SseAcc, gpa: std.mem.Allocator) []u8 {
        const s = gpa.dupe(u8, self.buf.items) catch @panic("OOM");
        self.buf.clearRetainingCapacity();
        return s;
    }
};

/// Dispatch one complete SSE payload: inspector raw + semantic parse.
fn dispatchPayload(mb: *state.Mailbox, payload: []const u8) void {
    if (payload.len == 0) return;
    pushRaw(mb, payload);
    feedData(mb, payload);
}

/// Worker entry — detached thread. Reads `mb.job` (mailbox-owned
/// snapshot) and pushes events; releases its ref on exit.
pub fn worker(mb: *state.Mailbox) void {
    defer mb.workerDone();
    const gpa = mb.gpa;
    const job = &mb.job;

    // MCP jobs have their own JSON-RPC transport — same Mailbox,
    // different wire protocol.
    if (job.kind == .mcp_check) {
        mcp.checkWorker(mb);
        return;
    }
    if (job.kind == .mcp_call) {
        mcp.callWorker(mb);
        return;
    }

    var client: std.http.Client = .{ .allocator = gpa, .io = mb.io };
    defer client.deinit();

    const uri = std.Uri.parse(job.url) catch {
        pushErr(mb, "bad endpoint url: {s}", .{job.url});
        return;
    };
    const is_models = job.kind == .models;
    const method: std.http.Method = if (is_models) .GET else .POST;

    var hdr_storage: [2]std.http.Header = undefined;
    var hdrs: []const std.http.Header = &.{};
    // `defer` is block-scoped: freeing inside the `if` would dangle
    // hdr_storage[0].value before sendHead serializes it (observed as
    // `authorization: UUU…` on the wire → 401 / connection reset).
    var auth_val: ?[]u8 = null;
    defer if (auth_val) |v| gpa.free(v);
    if (job.api_key.len != 0) {
        auth_val = std.fmt.allocPrint(gpa, "Bearer {s}", .{job.api_key}) catch {
            pushErr(mb, "oom", .{});
            return;
        };
        hdr_storage[0] = .{ .name = "authorization", .value = auth_val.? };
        hdr_storage[1] = .{ .name = "content-type", .value = "application/json" };
        hdrs = hdr_storage[0..2];
    } else if (!is_models) {
        hdr_storage[0] = .{ .name = "content-type", .value = "application/json" };
        hdrs = hdr_storage[0..1];
    }

    // Inspector "req" entry: method + url + pretty-printed body
    // (JSON.stringify(…, null, 2) style). The API key travels in the
    // Authorization header — never logged.
    const req_desc = if (is_models)
        std.fmt.allocPrint(gpa, "GET {s}", .{job.url}) catch ""
    else blk: {
        const pb = state.prettyJson(gpa, job.body);
        defer gpa.free(pb);
        break :blk std.fmt.allocPrint(gpa, "POST {s}\n\n{s}", .{ job.url, pb }) catch job.body;
    };
    mb.push(.{ .req = state.dupe(mb.gpa, req_desc) });

    var req = client.request(method, uri, .{
        .keep_alive = true,
        .extra_headers = hdrs,
    }) catch |e| {
        pushErr(mb, "connect failed: {s}", .{@errorName(e)});
        return;
    };
    defer req.deinit();
    // std.http does not decompress — ask for identity so SSE bodies
    // arrive as plaintext `data:` lines (gzip showed up as binary).
    req.headers.accept_encoding = .omit;

    if (is_models) {
        // GET has no payload — the head must be flushed explicitly or
        // the server sees an empty request and closes the connection.
        req.sendBodiless() catch |e| {
            pushErr(mb, "send failed: {s}", .{@errorName(e)});
            return;
        };
    } else {
        // @constCast: Request only writes the body to the socket.
        req.sendBodyComplete(@constCast(job.body)) catch |e| {
            pushErr(mb, "send failed: {s}", .{@errorName(e)});
            return;
        };
    }

    var rdbuf: [4096]u8 = undefined;
    var resp = req.receiveHead(&rdbuf) catch |e| {
        pushErr(mb, "response failed: {s}", .{@errorName(e)});
        return;
    };

    if (resp.head.status != .ok) {
        var tb: [2048]u8 = undefined;
        const rdr0 = resp.reader(&tb);
        const body = rdr0.allocRemaining(gpa, .limited(2048)) catch "";
        pushErr(mb, "HTTP {d}: {s}", .{ @backingInt(resp.head.status), body });
        return;
    }

    var tb: [8192]u8 = undefined;
    const rdr = resp.reader(&tb);

    if (is_models) {
        const body = rdr.allocRemaining(gpa, .limited(4 * 1024 * 1024)) catch {
            pushErr(mb, "models body read failed", .{});
            return;
        };
        defer gpa.free(body);
        const ids = parseModels(gpa, body) catch {
            pushErr(mb, "models parse failed", .{});
            return;
        };
        mb.push(.{ .models = ids });
        return;
    }

    // ── SSE line loop ──────────────────────────────────────────
    var acc: SseAcc = .{ .gpa = gpa };
    defer acc.buf.deinit(gpa);
    var saw_done = false;
    var rx_any = false;
    while (mb.alive.load(.seq_cst) and !mb.cancel.load(.seq_cst) and !saw_done) {
        const line = rdr.takeDelimiter('\n') catch |e| switch (e) {
            error.ReadFailed => {
                // With `connection: close` the peer may FIN right after
                // the terminal chunk — the chunked reader reports
                // ReadFailed instead of a clean EOF. Once bytes flowed
                // that is teardown, not a failure; before any data it
                // is a genuine read error.
                if (rx_any) {
                    pushRaw(mb, "stream closed early (ReadFailed) — keeping partial reply");
                    break;
                }
                pushErr(mb, "stream read failed", .{});
                return;
            },
            else => break,
        };
        const l0 = line orelse break; // EOF
        const l = std.mem.trimEnd(u8, l0, "\r");
        rx_any = true;
        // Zig 0.17.1's chunked body reader can return slices that
        // include unwritten (undefined) buffer tail on some streams —
        // observed as 0xAA runs. SSE is UTF-8 by spec; a line that
        // fails validation is reader corruption, not wire data.
        if (!std.unicode.utf8ValidateSlice(l)) {
            pushRaw(mb, "skipped corrupt SSE line (invalid utf-8)");
            continue;
        }
        if (l.len == 0) {
            const payload = acc.take(gpa);
            defer gpa.free(payload);
            if (payload.len != 0) {
                dispatchPayload(mb, payload);
                if (std.mem.eql(u8, std.mem.trim(u8, payload, " \t\r\n"), "[DONE]")) saw_done = true;
            }
            continue;
        }
        if (std.mem.startsWith(u8, l, "data:")) {
            acc.feed(l);
        }
        // event:/id:/retry:/comment lines are ignored.
    }
    // Trailing event without a final blank line.
    const payload = acc.take(gpa);
    defer gpa.free(payload);
    if (payload.len != 0) dispatchPayload(mb, payload);

    if (mb.cancel.load(.seq_cst)) {
        mb.push(.{ .err = state.dupe(gpa, "stopped by user") });
    } else if (!saw_done) {
        // EOF without [DONE] — some providers just close.
        mb.push(.{ .done = null });
    }
}

// ── tests ────────────────────────────────────────────────────────

fn testMailbox(gpa: std.mem.Allocator) *state.Mailbox {
    return state.Mailbox.create(gpa, std.testing.io, .{}, null);
}

test "feedData parses content deltas and usage" {
    const gpa = std.testing.allocator;
    const mb = testMailbox(gpa);
    // LIFO: deinit frees the mailbox contents, destroy frees the
    // struct itself — this order is required.
    defer mb.gpa.destroy(mb);
    defer mb.deinit();

    feedData(mb, "{\"choices\":[{\"delta\":{\"content\":\"Hel\"}}]}");
    feedData(mb, "{\"choices\":[{\"delta\":{\"content\":\"lo\"},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":3,\"completion_tokens\":2,\"total_tokens\":5}}");
    feedData(mb, "[DONE]");

    var out: std.ArrayListUnmanaged(state.Ev) = .empty;
    defer {
        for (out.items) |ev| state.freeEv(gpa, ev);
        out.deinit(gpa);
    }
    mb.drain(&out);
    // delta, delta, done(finish_reason), usage, done([DONE])
    try std.testing.expectEqual(@as(usize, 5), out.items.len);
    try std.testing.expectEqualStrings("Hel", out.items[0].delta);
    try std.testing.expectEqualStrings("lo", out.items[1].delta);
    try std.testing.expect(out.items[2] == .done);
    try std.testing.expectEqual(@as(u64, 5), out.items[3].usage.total);
    try std.testing.expect(out.items[4] == .done);
}

test "feedData accumulates tool_call fragments by index" {
    const gpa = std.testing.allocator;
    const mb = testMailbox(gpa);
    // LIFO: deinit frees the mailbox contents, destroy frees the
    // struct itself — this order is required.
    defer mb.gpa.destroy(mb);
    defer mb.deinit();

    feedData(mb, "{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_1\",\"function\":{\"name\":\"calc\",\"arguments\":\"{\\\"ex\"}}]}}]}");
    feedData(mb, "{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"pr\\\":\\\"1+1\\\"}\"}}]}}]}");

    var out: std.ArrayListUnmanaged(state.Ev) = .empty;
    defer {
        for (out.items) |ev| state.freeEv(gpa, ev);
        out.deinit(gpa);
    }
    mb.drain(&out);
    try std.testing.expectEqual(@as(usize, 2), out.items.len);
    const cd0 = out.items[0].call_delta;
    try std.testing.expectEqualStrings("call_1", cd0.id.?);
    try std.testing.expectEqualStrings("calc", cd0.name.?);
    try std.testing.expectEqualStrings("{\"ex", cd0.args.?);
    try std.testing.expectEqualStrings("pr\":\"1+1\"}", out.items[1].call_delta.args.?);
}

test "feedData handles reasoning_content and api errors" {
    const gpa = std.testing.allocator;
    const mb = testMailbox(gpa);
    // LIFO: deinit frees the mailbox contents, destroy frees the
    // struct itself — this order is required.
    defer mb.gpa.destroy(mb);
    defer mb.deinit();

    feedData(mb, "{\"choices\":[{\"delta\":{\"reasoning_content\":\"thinking…\"}}]}");
    feedData(mb, "{\"error\":{\"message\":\"rate limited\"}}");

    var out: std.ArrayListUnmanaged(state.Ev) = .empty;
    defer {
        for (out.items) |ev| state.freeEv(gpa, ev);
        out.deinit(gpa);
    }
    mb.drain(&out);
    try std.testing.expectEqualStrings("thinking…", out.items[0].reasoning);
    try std.testing.expectEqualStrings("rate limited", out.items[1].err);
}

test "parseModels extracts and sorts ids" {
    const gpa = std.testing.allocator;
    const ids = try parseModels(gpa, "{\"object\":\"list\",\"data\":[{\"id\":\"b-model\"},{\"id\":\"a-model\"},{\"id\":\"\"},{\"no_id\":1}]}");
    defer {
        for (ids) |id| gpa.free(id);
        gpa.free(ids);
    }
    try std.testing.expectEqual(@as(usize, 2), ids.len);
    try std.testing.expectEqualStrings("a-model", ids[0]);
    try std.testing.expectEqualStrings("b-model", ids[1]);
    try std.testing.expectError(error.BadJson, parseModels(gpa, "nope"));
}
