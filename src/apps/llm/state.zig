//! state — zllm per-session domain state: conversations, messages,
//! endpoint config, the inspector log, and the thread→session
//! Mailbox that carries LLM stream events.
//!
//! Ownership: every string/list here is gpa-owned and freed by the
//! matching `free*` helper (deps.deinit walks the whole graph). The
//! Mailbox is the ONLY object shared with the worker thread — it owns
//! its event strings and the request snapshot; the worker never
//! touches session state (zefx stores are session-thread-only, all
//! mutation happens in `syncPull` under srv.mutex).
const std = @import("std");
const Io = std.Io;

// ── domain types ─────────────────────────────────────────────────

pub const Role = enum { user, assistant, tool };

pub const MsgStatus = enum { ok, streaming, failed, stopped };

/// Token counters reported by the API (`usage` chunk) — zeros when the
/// endpoint doesn't send them.
pub const Usage = struct {
    prompt: u64 = 0,
    completion: u64 = 0,
    total: u64 = 0,
};

pub const CallState = enum { pending, running, done, rejected, failed };

/// One function-call request inside an assistant message. `args_json`
/// accumulates streamed `arguments` fragments; `result` is the tool
/// message content once resolved (done/rejected/error).
pub const ToolCall = struct {
    /// API call id (`call_…`) — echoed back as `tool_call_id`.
    id: []const u8,
    name: []const u8,
    args_json: std.ArrayListUnmanaged(u8) = .empty,
    state: CallState = .pending,
    /// gpa-owned result text (tool output or error description).
    result: ?[]const u8 = null,
};

/// A chat message. `text` is the streamed/accumulated content;
/// `reasoning` holds `reasoning_content` deltas (DeepSeek reasoner
/// style — shown collapsed in the UI). `calls` is the assistant
/// message's tool_calls (empty for other roles). `call_id`/`tool_name`
/// link role=tool messages back to their call.
pub const Msg = struct {
    role: Role,
    /// Position in conv.msgs at append time — stable because msgs
    /// only append (clear_chat resets everything anyway). Used for
    /// positional tool-call action args "{ord}:{call_idx}".
    ord: usize = 0,
    /// Owning conversation — set by convAppend. Lets delete_chat
    /// purge queued sends that point into the freed conv.
    owner: ?*Conversation = null,
    text: std.ArrayListUnmanaged(u8) = .empty,
    reasoning: std.ArrayListUnmanaged(u8) = .empty,
    calls: std.ArrayListUnmanaged(ToolCall) = .empty,
    call_id: ?[]const u8 = null,
    tool_name: ?[]const u8 = null,
    status: MsgStatus = .ok,
    /// gpa-owned error description (status == .failed).
    err: ?[]const u8 = null,
    usage: ?Usage = null,
};

pub const ToolMode = enum { off, manual, auto };

/// Endpoint + generation config — every field gpa-owned (duped on
/// set, freed on replace/deinit).
pub const Config = struct {
    base_url: []const u8 = "",
    api_key: []const u8 = "",
    model: []const u8 = "",
    /// Prepended as a `system` message when non-empty.
    system: []const u8 = "",
    temperature: f64 = 0.7,
    top_p: f64 = 1.0,
    /// Context-window size for the fill meter (tokens).
    context_window: u32 = 64000,
    tool_mode: ToolMode = .manual,
    /// Raw JSON array of user tool defs (validated on set).
    tools_json: []const u8 = "",
    /// Raw JSON array of MCP server configs (validated on set).
    mcp_servers: []const u8 = "",
};

pub const Conversation = struct {
    title: []const u8,
    /// Heap-allocated Msg pointers — STABLE addresses: the Mailbox
    /// holds a `*Msg` across the stream's lifetime while the list
    /// itself may grow.
    msgs: std.ArrayListUnmanaged(*Msg) = .empty,
};

// ── mailbox: worker thread → session ─────────────────────────────

/// Events the worker pushes; every owned string is gpa-allocated and
/// freed by whoever consumes it (drain in syncPull, or mailbox.deinit
/// for leftovers).
pub const Ev = union(enum) {
    /// Assistant content delta.
    delta: []const u8,
    /// reasoning_content delta.
    reasoning: []const u8,
    /// Streamed tool_call fragment.
    call_delta: struct {
        index: u8,
        id: ?[]const u8 = null,
        name: ?[]const u8 = null,
        args: ?[]const u8 = null,
    },
    usage: Usage,
    /// finish_reason (null when absent).
    done: ?[]const u8,
    /// Terminal failure description.
    err: []const u8,
    /// Inspector-only raw payload (response SSE data line, note).
    raw: []const u8,
    /// Inspector-only outbound request descriptor (method+url+body).
    req: []const u8,
    /// Fetched /models id list — the session ADOPTS the slice.
    models: [][]const u8,
    /// MCP check result for one server (all strings owned).
    mcp: struct {
        server: []const u8,
        ok: bool,
        detail: []const u8,
        /// OpenAI tools array text ("[]" on failure).
        tools_json: []const u8,
    },
    /// MCP tools/call result routed back to a ToolCall by position.
    mcp_call: struct {
        conv: u32,
        msg: u32,
        call: u32,
        ok: bool,
        text: []const u8,
    },
};

pub const JobKind = enum { chat, models, mcp_check, mcp_call };

/// What the worker needs, snapshotted at dispatch time. Owned by the
/// Mailbox (freed in deinit) so the worker never reads session memory.
pub const Job = struct {
    kind: JobKind = .chat,
    /// Full URL (…/chat/completions or …/models).
    url: []const u8 = "",
    api_key: []const u8 = "",
    /// Request body (chat) — for mcp_check the servers config JSON,
    /// for mcp_call the tools/call `params` object.
    body: []const u8 = "",
    /// mcp_call only: JSON object of extra headers (http) or env vars
    /// (stdio).
    extra: []const u8 = "",
    /// mcp_call only, stdio transport: JSON array of the child argv
    /// ([command, arg…]). Empty → HTTP transport via `url`.
    argv: []const u8 = "",
    /// mcp_call only: conv/msg/call indices echoed into .mcp_call.
    pos_conv: u32 = 0,
    pos_msg: u32 = 0,
    pos_call: u32 = 0,
};

/// Shared worker↔session channel. refs = session(1) + worker(1);
/// `release` frees at zero. `alive`/`cancel` are the worker's escape
/// hatches: session deinit clears them so a dead session's stream
/// aborts at the next chunk instead of streaming into the void.
pub const Mailbox = struct {
    gpa: std.mem.Allocator,
    io: Io,
    mutex: Io.Mutex = .init,
    evs: std.ArrayListUnmanaged(Ev) = .empty,
    job: Job = .{},
    /// Target message for chat events — owned by the session; only
    /// valid while `alive` (the drain is the sole reader).
    msg: ?*Msg = null,
    alive: std.atomic.Value(bool) = .init(true),
    cancel: std.atomic.Value(bool) = .init(false),
    /// Terminal event pushed (done/error) — drain-side bookkeeping.
    finished: std.atomic.Value(bool) = .init(false),
    refs: std.atomic.Value(usize) = .init(2),

    pub fn create(gpa: std.mem.Allocator, io: Io, job: Job, msg: ?*Msg) *Mailbox {
        const mb = gpa.create(Mailbox) catch @panic("OOM");
        mb.* = .{ .gpa = gpa, .io = io, .job = job, .msg = msg };
        return mb;
    }

    /// Worker side: queue an event (strings already gpa-owned).
    pub fn push(self: *Mailbox, ev: Ev) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.evs.append(self.gpa, ev) catch {
            // OOM inside a worker can't propagate — drop the event.
            freeEv(self.gpa, ev);
        };
    }

    /// Session side (syncPull, under srv.mutex): take all pending
    /// events, leaving the list empty.
    pub fn drain(self: *Mailbox, out: *std.ArrayListUnmanaged(Ev)) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        out.* = self.evs;
        self.evs = .empty;
    }

    /// Session deinit: stop the worker and drop the session's ref.
    pub fn close(self: *Mailbox) void {
        self.alive.store(false, .seq_cst);
        self.cancel.store(true, .seq_cst);
        self.release();
    }

    /// Worker exit: drop the worker's ref (frees at zero).
    pub fn workerDone(self: *Mailbox) void {
        self.finished.store(true, .seq_cst);
        self.release();
    }

    fn release(self: *Mailbox) void {
        if (self.refs.fetchSub(1, .seq_cst) == 1) {
            self.deinit();
            self.gpa.destroy(self);
        }
    }

    pub fn deinit(self: *Mailbox) void {
        var evs = self.evs;
        defer evs.deinit(self.gpa);
        for (evs.items) |ev| freeEv(self.gpa, ev);
        evs.clearRetainingCapacity();
        if (self.job.url.len != 0) self.gpa.free(self.job.url);
        if (self.job.api_key.len != 0) self.gpa.free(self.job.api_key);
        if (self.job.body.len != 0) self.gpa.free(self.job.body);
        if (self.job.extra.len != 0) self.gpa.free(self.job.extra);
        if (self.job.argv.len != 0) self.gpa.free(self.job.argv);
        // `msg` is session-owned — never freed here.
    }
};

/// Free an event's owned payload — used by drain consumers and
/// mailbox.deinit for leftovers.
pub fn freeEv(gpa: std.mem.Allocator, ev: Ev) void {
    switch (ev) {
        .delta, .reasoning, .err, .raw, .req, .done => |s| {
            if (s) |x| gpa.free(x);
        },
        .call_delta => |cd| {
            if (cd.id) |s| gpa.free(s);
            if (cd.name) |s| gpa.free(s);
            if (cd.args) |s| gpa.free(s);
        },
        .usage => {},
        .models => |ids| {
            for (ids) |id| gpa.free(id);
            gpa.free(ids);
        },
        .mcp => |r| {
            gpa.free(r.server);
            gpa.free(r.detail);
            gpa.free(r.tools_json);
        },
        .mcp_call => |r| gpa.free(r.text),
    }
}

// ── alloc helpers ────────────────────────────────────────────────

pub fn dupe(gpa: std.mem.Allocator, s: []const u8) []const u8 {
    return gpa.dupe(u8, s) catch @panic("OOM");
}

/// Replace an owned string field: free old, dupe new.
pub fn setStr(gpa: std.mem.Allocator, slot: *[]const u8, s: []const u8) void {
    if (slot.*.len != 0) gpa.free(slot.*);
    slot.* = dupe(gpa, s);
}

pub fn freeStr(gpa: std.mem.Allocator, s: []const u8) void {
    if (s.len != 0) gpa.free(s);
}

// ── message helpers ──────────────────────────────────────────────

pub fn msgNew(gpa: std.mem.Allocator, role: Role) *Msg {
    const m = gpa.create(Msg) catch @panic("OOM");
    m.* = .{ .role = role };
    return m;
}

pub fn msgFree(gpa: std.mem.Allocator, m: *Msg) void {
    m.text.deinit(gpa);
    m.reasoning.deinit(gpa);
    for (m.calls.items) |*c| {
        c.args_json.deinit(gpa);
        freeStr(gpa, c.id);
        freeStr(gpa, c.name);
        if (c.result) |r| gpa.free(r);
    }
    m.calls.deinit(gpa);
    if (m.call_id) |s| gpa.free(s);
    if (m.tool_name) |s| gpa.free(s);
    if (m.err) |s| gpa.free(s);
    gpa.destroy(m);
}

/// Append with ord stamping — the ONLY way msgs enter a conversation
/// (keeps `ord` == list position for positional action args).
pub fn convAppend(gpa: std.mem.Allocator, conv: *Conversation, m: *Msg) void {
    m.ord = conv.msgs.items.len;
    m.owner = conv;
    conv.msgs.append(gpa, m) catch @panic("OOM");
}

pub fn convNew(gpa: std.mem.Allocator, title: []const u8) *Conversation {
    const c = gpa.create(Conversation) catch @panic("OOM");
    c.* = .{ .title = dupe(gpa, title) };
    return c;
}

pub fn convFree(gpa: std.mem.Allocator, c: *Conversation) void {
    freeStr(gpa, c.title);
    for (c.msgs.items) |m| msgFree(gpa, m);
    c.msgs.deinit(gpa);
    gpa.destroy(c);
}

// ── request building (pure — unit-testable) ──────────────────────

fn jsonStr(w: anytype, s: []const u8) !void {
    try jsonStrPub(w, s);
}

/// Public JSON string escaper — plugins/tools reuse it for wire JSON.
pub fn jsonStrPub(w: anytype, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    try w.print("\\u{x:0>4}", .{c});
                } else {
                    try w.writeByte(c);
                }
            },
        }
    }
    try w.writeByte('"');
}

/// `{base}/chat/completions` — base may or may not end in /v1; the
/// completions path is always appended to the trimmed base (OpenAI-
/// style bases already include /v1, e.g. api.openai.com/v1).
pub fn completionsUrl(gpa: std.mem.Allocator, base: []const u8) []const u8 {
    return std.fmt.allocPrint(gpa, "{s}/chat/completions", .{std.mem.trimEnd(u8, base, "/")}) catch @panic("OOM");
}

pub fn modelsUrl(gpa: std.mem.Allocator, base: []const u8) []const u8 {
    return std.fmt.allocPrint(gpa, "{s}/models", .{std.mem.trimEnd(u8, base, "/")}) catch @panic("OOM");
}

/// Serialize one chat message into the request `messages` array.
/// `system` is emitted separately by the caller.
fn writeMsgJson(w: anytype, m: *const Msg) !void {
    switch (m.role) {
        .user => {
            try w.writeAll("{\"role\":\"user\",\"content\":");
            try jsonStr(w, m.text.items);
            try w.writeByte('}');
        },
        .assistant => {
            try w.writeAll("{\"role\":\"assistant\",\"content\":");
            // content may be "" while tool_calls carry the payload.
            try jsonStr(w, m.text.items);
            if (m.calls.items.len != 0) {
                try w.writeAll(",\"tool_calls\":[");
                for (m.calls.items, 0..) |c, i| {
                    if (i != 0) try w.writeByte(',');
                    try w.writeAll("{\"id\":");
                    try jsonStr(w, c.id);
                    try w.writeAll(",\"type\":\"function\",\"function\":{\"name\":");
                    try jsonStr(w, c.name);
                    try w.writeAll(",\"arguments\":");
                    try jsonStr(w, c.args_json.items);
                    try w.writeAll("}}");
                }
                try w.writeByte(']');
            }
            try w.writeByte('}');
        },
        .tool => {
            try w.writeAll("{\"role\":\"tool\",\"tool_call_id\":");
            try jsonStr(w, m.call_id orelse "");
            try w.writeAll(",\"content\":");
            try jsonStr(w, if (m.text.items.len != 0) m.text.items else (m.err orelse ""));
            try w.writeByte('}');
        },
    }
}

/// Build the full chat.completions request body. `tools_json` is the
/// raw user tool-defs array — validated/spliced by the caller via
/// `toolsJson` (pass "" for none). Returns gpa-owned JSON.
pub fn buildRequest(
    gpa: std.mem.Allocator,
    cfg: *const Config,
    msgs: []const *Msg,
    tools_payload: []const u8,
) []const u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    const w = &aw.writer;
    w.writeAll("{\"model\":") catch @panic("OOM");
    jsonStr(w, cfg.model) catch @panic("OOM");
    w.writeAll(",\"stream\":true,\"stream_options\":{\"include_usage\":true}") catch @panic("OOM");
    w.print(",\"temperature\":{d},\"top_p\":{d}", .{ cfg.temperature, cfg.top_p }) catch @panic("OOM");
    w.writeAll(",\"messages\":[") catch @panic("OOM");
    var first = true;
    if (cfg.system.len != 0) {
        w.writeAll("{\"role\":\"system\",\"content\":") catch @panic("OOM");
        jsonStr(w, cfg.system) catch @panic("OOM");
        w.writeByte('}') catch @panic("OOM");
        first = false;
    }
    for (msgs) |m| {
        // Skip unresolved tool-call assistants mid-flight: their tool
        // messages aren't in the list yet — the API rejects orphan
        // tool_calls. Pending manual calls never reach the wire.
        if (m.role == .assistant and m.calls.items.len != 0) {
            var all_resolved = true;
            for (m.calls.items) |c| {
                if (c.state == .pending or c.state == .running) all_resolved = false;
            }
            if (!all_resolved) continue;
        }
        if (!first) w.writeByte(',') catch @panic("OOM");
        first = false;
        writeMsgJson(w, m) catch @panic("OOM");
    }
    w.writeByte(']') catch @panic("OOM");
    if (tools_payload.len != 0) {
        w.writeAll(",\"tools\":") catch @panic("OOM");
        w.writeAll(tools_payload) catch @panic("OOM");
    }
    w.writeByte('}') catch @panic("OOM");
    return aw.toOwnedSlice() catch @panic("OOM");
}

/// Rough token estimate for the context meter — chars/4 heuristic,
/// same order of magnitude as real tokenizers for latin+cyrillic mix.
pub fn estTokens(msgs: []const *Msg, system_len: usize) u64 {
    var n: u64 = system_len / 4;
    for (msgs) |m| {
        n += @intCast(m.text.items.len / 4);
        n += @intCast(m.reasoning.items.len / 4);
        for (m.calls.items) |c| n += @intCast(c.args_json.items.len / 4);
    }
    return n;
}

/// Context composition for the segmented meter — same chars/4
/// heuristic split by source: system prompt, tools payload, and
/// messages grouped by role.
pub const CtxParts = struct {
    system: u64 = 0,
    tools: u64 = 0,
    user: u64 = 0,
    assistant: u64 = 0,
    tool: u64 = 0,

    pub fn total(self: CtxParts) u64 {
        return self.system + self.tools + self.user + self.assistant + self.tool;
    }
};

pub fn estTokensParts(msgs: []const *Msg, system_len: usize, tools_len: usize) CtxParts {
    var p: CtxParts = .{ .system = system_len / 4, .tools = tools_len / 4 };
    for (msgs) |m| {
        var n = @as(u64, m.text.items.len / 4) + @as(u64, m.reasoning.items.len / 4);
        for (m.calls.items) |c| n += @intCast(c.args_json.items.len / 4);
        switch (m.role) {
            .user => p.user += n,
            .assistant => p.assistant += n,
            .tool => p.tool += n,
        }
    }
    return p;
}

// ── tests ────────────────────────────────────────────────────────

test "jsonStr escapes quotes, backslash, control chars, keeps utf8" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    jsonStr(&aw.writer, "a\"b\\c\nd\te") catch @panic("OOM");
    try std.testing.expectEqualStrings("\"a\\\"b\\\\c\\nd\\te\"", aw.written());
}

test "completionsUrl/modelsUrl trim trailing slashes" {
    const gpa = std.testing.allocator;
    const url1 = completionsUrl(gpa, "https://api.openai.com/v1/");
    defer gpa.free(url1);
    try std.testing.expectEqualStrings("https://api.openai.com/v1/chat/completions", url1);
    const url2 = modelsUrl(gpa, "http://localhost:11434/v1");
    defer gpa.free(url2);
    try std.testing.expectEqualStrings("http://localhost:11434/v1/models", url2);
}

test "buildRequest emits system+roles+tool_calls correctly" {
    const gpa = std.testing.allocator;
    var cfg = Config{ .model = "m", .system = "be nice" };
    const user = msgNew(gpa, .user);
    defer msgFree(gpa, user);
    user.text.appendSlice(gpa, "hi") catch @panic("OOM");

    const asst = msgNew(gpa, .assistant);
    defer msgFree(gpa, asst);
    asst.calls.append(gpa, .{
        .id = dupe(gpa, "call_1"),
        .name = dupe(gpa, "calc"),
        .state = .done,
    }) catch @panic("OOM");
    asst.calls.items[0].args_json.appendSlice(gpa, "{\"expr\":\"1+1\"}") catch @panic("OOM");
    asst.calls.items[0].result = dupe(gpa, "2");

    const tool = msgNew(gpa, .tool);
    defer msgFree(gpa, tool);
    tool.call_id = dupe(gpa, "call_1");
    tool.tool_name = dupe(gpa, "calc");
    tool.text.appendSlice(gpa, "2") catch @panic("OOM");

    const msgs = [_]*Msg{ user, asst, tool };
    const body = buildRequest(gpa, &cfg, &msgs, "[{\"type\":\"function\"}]");
    defer gpa.free(body);
    const s = body;
    try std.testing.expect(std.mem.indexOf(u8, s, "\"role\":\"system\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "be nice") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"role\":\"user\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"tool_calls\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "call_1") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"role\":\"tool\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"tools\":[{\"type\":\"function\"}]") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"stream\":true") != null);
    _ = &cfg;
}

test "buildRequest skips assistant with unresolved calls" {
    const gpa = std.testing.allocator;
    const cfg = Config{ .model = "m" };
    const asst = msgNew(gpa, .assistant);
    defer msgFree(gpa, asst);
    asst.calls.append(gpa, .{ .id = dupe(gpa, "c1"), .name = dupe(gpa, "t"), .state = .pending }) catch @panic("OOM");
    const msgs = [_]*Msg{asst};
    const body = buildRequest(gpa, &cfg, &msgs, "");
    defer gpa.free(body);
    try std.testing.expectEqualStrings("{\"model\":\"m\",\"stream\":true,\"stream_options\":{\"include_usage\":true},\"temperature\":0.7,\"top_p\":1,\"messages\":[]}", body);
}

test "estTokens approximates chars/4" {
    const gpa = std.testing.allocator;
    const m = msgNew(gpa, .user);
    defer msgFree(gpa, m);
    m.text.appendSlice(gpa, "aaaaaaaa") catch @panic("OOM"); // 8 chars → 2
    const msgs = [_]*Msg{m};
    try std.testing.expectEqual(@as(u64, 4), estTokens(&msgs, 8)); // +2 from system
}

// ── inspector JSON pretty-print ──────────────────────────────────

/// Lexical JSON indenter — JS `JSON.stringify(v, null, 2)` style.
/// No parse: strings/escapes are tracked so structural chars inside
/// string values never trigger reformatting, key order is preserved.
/// Non-JSON input (first non-ws char isn't '{' — chat payloads are
/// always objects; '[DONE]'-style sentinels pass through) returns an
/// unchanged dupe — callers always own the result.
pub fn prettyJson(gpa: std.mem.Allocator, s: []const u8) []u8 {
    var i: usize = 0;
    while (i < s.len and std.ascii.isWhitespace(s[i])) : (i += 1) {}
    if (i >= s.len or s[i] != '{') return gpa.dupe(u8, s) catch @panic("OOM");

    var out: std.ArrayListUnmanaged(u8) = .empty;
    var indent: usize = 0;
    var in_str = false;
    var esc = false;
    // Last significant byte emitted — detects empty `{}`/`[]` pairs.
    var last: u8 = 0;

    const nl = struct {
        fn emit(o: *std.ArrayListUnmanaged(u8), g: std.mem.Allocator, n: usize) void {
            o.append(g, '\n') catch @panic("OOM");
            var k: usize = 0;
            while (k < n * 2) : (k += 1) o.append(g, ' ') catch @panic("OOM");
        }
    }.emit;

    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (in_str) {
            out.append(gpa, c) catch @panic("OOM");
            last = c;
            if (esc) esc = false else if (c == '\\') esc = true else if (c == '"') in_str = false;
            continue;
        }
        switch (c) {
            ' ', '\t', '\r', '\n' => continue, // reformat whitespace
            '"' => {
                in_str = true;
                out.append(gpa, c) catch @panic("OOM");
                last = c;
            },
            '{', '[' => {
                out.append(gpa, c) catch @panic("OOM");
                last = c;
                // Empty pair? peek past whitespace — `}`/`]` stays inline.
                var j = i + 1;
                while (j < s.len and std.ascii.isWhitespace(s[j])) : (j += 1) {}
                if (j < s.len and s[j] != '}' and s[j] != ']') {
                    indent += 1;
                    nl(&out, gpa, indent);
                }
            },
            '}', ']' => {
                if (last == '{' or last == '[') {
                    // Empty pair — the opener took no indent, take none.
                } else {
                    indent -|= 1;
                    nl(&out, gpa, indent);
                }
                out.append(gpa, c) catch @panic("OOM");
                last = c;
            },
            ',' => {
                out.append(gpa, c) catch @panic("OOM");
                last = c;
                nl(&out, gpa, indent);
            },
            ':' => {
                out.append(gpa, ':') catch @panic("OOM");
                out.append(gpa, ' ') catch @panic("OOM");
                last = ' ';
            },
            else => {
                out.append(gpa, c) catch @panic("OOM");
                last = c;
            },
        }
    }
    // toOwnedSlice: the returned slice must BE the allocation —
    // out.items can be shorter than capacity and gpa.free would
    // reject it.
    return out.toOwnedSlice(gpa) catch @panic("OOM");
}

test "prettyJson indents like JSON.stringify(…, null, 2)" {
    const gpa = std.testing.allocator;
    const src = "{\"a\":1,\"b\":[true,\"x,y\"],\"c\":{},\"d\":\"}\"}";
    const p = prettyJson(gpa, src);
    defer gpa.free(p);
    try std.testing.expectEqualStrings(
        "{\n  \"a\": 1,\n  \"b\": [\n    true,\n    \"x,y\"\n  ],\n  \"c\": {},\n  \"d\": \"}\"\n}",
        p,
    );
}

test "prettyJson passes non-JSON through" {
    const gpa = std.testing.allocator;
    const p = prettyJson(gpa, "[DONE]");
    defer gpa.free(p);
    try std.testing.expectEqualStrings("[DONE]", p);
}
