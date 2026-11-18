//! app — zllm session deps + actions. Per-session console state:
//! conversations (heap Msgs), endpoint Config, parsed tool defs,
//! fetched model list, bounded inspector log, and the active
//! Mailbox stream. All LLM traffic runs on a detached worker thread
//! that only touches the Mailbox; `syncPull` drains events into the
//! session model under srv.mutex (same pattern as board's
//! global_seq poll, minus render groups — state is per-session).
const std = @import("std");
const Io = std.Io;
const zefx = @import("zefx");
const forest = @import("forest");
const zmeta = @import("zmeta.zig");
const routes = @import("gen/routes.zig");
const actions = @import("gen/actions.zig");
const state = @import("state.zig");
const tools = @import("tools.zig");
const openai = @import("openai.zig");
const mcp = @import("mcp.zig");
const presets = @import("presets.zig");

/// Console stylesheet — inlined into <head> by pages/index.zig `head`
/// (same pattern as zblog's blog.css: tiny, render-blocking, cache-free).
pub const llm_css = @embedFile("llm.css");

const Ping = struct {};

/// Fallback API key from the environment (main.zig seeds it) —
/// session configs start with it so `ZLLM_API_KEY=… zllm` works
/// out of the box. Never rendered back into HTML.
var env_api_key: []const u8 = "";
var env_base_url: []const u8 = "";
var env_mcp_servers: []const u8 = "";

/// `ZLLM_API_ENDPOINT` (or .env) seeds every session's base_url.
pub fn setEnvEndpoint(url: []const u8) void {
    env_base_url = url;
}

/// `ZLLM_MCP_JSON` env or mcp.json seeds every session's MCP config.
pub fn setEnvMcpServers(json: []const u8) void {
    env_mcp_servers = json;
}

pub fn setEnvApiKey(key: []const u8) void {
    env_api_key = key;
}

/// Inspector log bound — oldest entries drop off.
const inspector_cap = 400;
/// Auto tool-loop bound — a runaway model can't spin forever.
const max_tool_turns = 8;
/// Pending user messages bound (send queue).
const send_queue_cap = 16;

pub const InspectorEntry = struct {
    /// Stable identity for the keyed inspector list (never reused,
    /// survives ring-cap eviction of older entries).
    seq: u64,
    kind: []const u8, // "req" | "sse" | "tool" | "sys" | "err" | "mcp"
    text: []const u8,
    /// Owning conversation pointer — the inspector filters by the
    /// active chat. 0 = global entry, shown under every chat.
    chat: usize = 0,
};

pub const EndpointState = enum { idle, busy, ok, err };
pub const EndpointStatus = struct {
    kind: EndpointState = .idle,
    text: []const u8 = "",
};

/// Tools discovered via MCP `tools/list` — kept per server so a
/// re-check replaces only that server's slice. `tools_json` is an
/// OpenAI `tools` array text ("[]" when the check failed).
pub const McpTool = struct {
    server: []const u8,
    tools_json: []const u8,
};

/// A background process started by `proc_start` — stdout+stderr are
/// merged into `out` (256KB cap), `pos` is the read cursor for
/// `proc_output`. Reaped via `child.wait` once both pipes hit EOF.
pub const Proc = struct {
    id: u32,
    cmd: []const u8,
    child: *std.process.Child,
    out: std.ArrayListUnmanaged(u8) = .empty,
    pos: usize = 0,
    eof: [2]bool = .{ false, false },
    done: bool = false,
    /// Exit code, or -1 when killed/signalled.
    code: i32 = 0,
};

pub const LlmDeps = struct {
    pub const page_title = "zllm";
    pub const page_class = "app app-llm";
    pub const page_lang = "en";
    pub const cookie_name = "zfxl";

    route: routes.Route = .{ .index = .{} },

    convs: std.ArrayListUnmanaged(*state.Conversation) = .empty,
    active: usize = 0,
    cfg: state.Config = .{},
    /// Parsed user tool defs (from cfg.tools_json) — kept in sync by
    /// the tools_json setter; the raw text stays in cfg for the form.
    tool_defs: []tools.ToolDef = &.{},
    /// /models fetch result (sorted ids).
    models: [][]const u8 = &.{},
    inspector: std.ArrayListUnmanaged(InspectorEntry) = .empty,
    /// Monotonic id source for InspectorEntry.seq.
    insp_seq: u64 = 0,
    /// Active worker stream (chat or models fetch).
    mailbox: ?*state.Mailbox = null,
    /// User messages sent mid-stream, FIFO.
    send_queue: std.ArrayListUnmanaged(*state.Msg) = .empty,
    /// Tool-loop counter for the current assistant turn.
    tool_turns: u32 = 0,
    /// True while cfg.api_key came from env (UI shows "env" tag).
    key_from_env: bool = false,
    /// Last endpoint operation result — the visible "did it connect"
    /// signal in the Endpoint card.
    endpoint: EndpointStatus = .{},
    /// MCP servers that passed `tools/list` (discovered tools).
    mcp_tools: std.ArrayListUnmanaged(McpTool) = .empty,
    /// Last MCP check/call outcome — the MCP card status line.
    mcp_status: EndpointStatus = .{},
    /// In-flight MCP worker (check or tools/call) — separate from
    /// `mailbox` so a chat stream and an MCP call can overlap.
    mcp_mb: ?*state.Mailbox = null,
    /// Code-mode background processes (proc_start/output/list/kill).
    procs: std.ArrayListUnmanaged(Proc) = .empty,
    proc_seq: u32 = 1,
    /// Cached repo-context block for code mode (keyed by workspace).
    repo_ctx: []const u8 = "",
    repo_ctx_ws: []const u8 = "",
    /// Session cookie token — stable id for file persistence.
    sess_token: []const u8 = "",
    persist_loaded: bool = false,
    last_persist_ms: i64 = 0,

    ping: *zefx.Event(Ping),

    pub fn init(s: *Session) LlmDeps {
        var d: LlmDeps = .{
            .convs = .empty,
            .active = 0,
            .cfg = .{},
            .tool_defs = &.{},
            .models = &.{},
            .inspector = .empty,
            .insp_seq = 0,
            .mailbox = null,
            .send_queue = .empty,
            .tool_turns = 0,
            .key_from_env = false,
            .mcp_tools = .empty,
            .mcp_status = .{},
            .mcp_mb = null,
            .procs = .empty,
            .proc_seq = 1,
            .repo_ctx = "",
            .repo_ctx_ws = "",
            .sess_token = "",
            .persist_loaded = false,
            .last_persist_ms = 0,
            .ping = s.app.createEvent(Ping),
        };
        // gpa-own every default so deinit can free uniformly.
        const g = s.gpa;
        inline for (@typeInfo(state.Config).@"struct".field_names) |fname| {
            const f = @field(d.cfg, fname);
            if (@TypeOf(f) == []const u8 and f.len != 0) {
                @field(d.cfg, fname) = state.dupe(g, f);
            }
        }
        if (env_api_key.len != 0) {
            d.cfg.api_key = state.dupe(g, env_api_key);
            d.key_from_env = true;
        }
        if (env_base_url.len != 0) {
            d.cfg.base_url = state.dupe(g, env_base_url);
        }
        if (env_mcp_servers.len != 0) {
            d.cfg.mcp_servers = state.dupe(g, env_mcp_servers);
        }
        d.convs.append(g, state.convNew(g, "Chat 1")) catch @panic("OOM");
        return d;
    }

    pub fn deinit(s: *Session) void {
        const g = s.gpa;
        if (s.deps.mailbox) |mb| mb.close();
        s.deps.mailbox = null;
        if (s.deps.mcp_mb) |mb| mb.close();
        s.deps.mcp_mb = null;
        for (s.deps.mcp_tools.items) |mt| {
            state.freeStr(g, mt.server);
            state.freeStr(g, mt.tools_json);
        }
        s.deps.mcp_tools.deinit(g);
        state.freeStr(g, s.deps.mcp_status.text);
        for (s.deps.convs.items) |c| state.convFree(g, c);
        s.deps.convs.deinit(g);
        inline for (@typeInfo(state.Config).@"struct".field_names) |fname| {
            const f = @field(s.deps.cfg, fname);
            if (@TypeOf(f) == []const u8) state.freeStr(g, f);
        }
        tools.freeDefs(g, s.deps.tool_defs);
        for (s.deps.models) |id| g.free(id);
        if (s.deps.models.len != 0) g.free(s.deps.models);
        state.freeStr(g, s.deps.endpoint.text);
        for (s.deps.inspector.items) |e| g.free(e.text);
        s.deps.inspector.deinit(g);
        // send_queue entries are *Msg owned by their Conversation —
        // convFree already released them; only the list itself frees.
        s.deps.send_queue.deinit(g);
        for (s.deps.procs.items) |*p| {
            p.child.kill(s.io); // idempotent — no-op after wait
            state.freeStr(g, p.cmd);
            p.out.deinit(g);
            g.destroy(p.child);
        }
        s.deps.procs.deinit(g);
        state.freeStr(g, s.deps.repo_ctx);
        state.freeStr(g, s.deps.repo_ctx_ws);
        persistSave(s); // flush final state before teardown (needs sess_token)
        state.freeStr(g, s.deps.sess_token);
    }

    pub fn wire(s: *Session) void {
        s.deps.ping.onReducer(s, &onPing);
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
    pub fn dispatch(
        s: *Session,
        action: []const u8,
        arg: ?[]const u8,
        value: ?[]const u8,
        fields: ?*const std.json.ObjectMap,
    ) !void {
        return actions.dispatch(s, action, arg, value, fields);
    }

    /// SSE-worker hook: drain mailbox events into the session model,
    /// then ping once if anything applied (one flush per poll tick).
    /// Two mailboxes drain independently: `mailbox` (chat/models) and
    /// `mcp_mb` (MCP check/call workers).
    pub fn syncPull(s: *Session) void {
        if (s.deps.mailbox) |mb| drainMailbox(s, mb, true);
        if (s.deps.mcp_mb) |mb| drainMailbox(s, mb, false);
    }
    // ── actions ──────────────────────────────────────────────────────

    /// `send` — composer submit.
    pub fn on_send(s: *Session, arg: ?[]const u8, value: ?[]const u8, fields: ?*const std.json.ObjectMap) !void {
        _ = arg;
        _ = value;
        const f = fields orelse return error.InvalidAction;
        const text = fieldStr(f, "message") orelse return error.InvalidAction;
        try doSend(s, text);
    }

    /// `stop` — cancel the active stream(s).
    pub fn on_stop(s: *Session, arg: ?[]const u8, value: ?[]const u8, fields: ?*const std.json.ObjectMap) !void {
        _ = arg;
        _ = value;
        _ = fields;
        if (s.deps.mailbox) |mb| {
            mb.cancel.store(true, .seq_cst);
            note(s, "sys", "stop requested");
        }
        if (s.deps.mcp_mb) |mb| mb.cancel.store(true, .seq_cst);
        s.deps.ping.emit(.{});
    }

    /// `new_chat` — fresh conversation appended and activated.
    pub fn on_new_chat(s: *Session, arg: ?[]const u8, value: ?[]const u8, fields: ?*const std.json.ObjectMap) !void {
        _ = arg;
        _ = value;
        _ = fields;
        const g = s.gpa;
        const n = s.deps.convs.items.len + 1;
        const title = std.fmt.allocPrint(g, "Chat {d}", .{n}) catch @panic("OOM");
        s.deps.convs.append(g, state.convNew(g, title)) catch @panic("OOM");
        g.free(title);
        s.deps.active = s.deps.convs.items.len - 1;
        s.deps.ping.emit(.{});
    }

    /// `select_chat` — arg = conversation index.
    pub fn on_select_chat(s: *Session, arg: ?[]const u8, value: ?[]const u8, fields: ?*const std.json.ObjectMap) !void {
        _ = value;
        _ = fields;
        const a = arg orelse return error.InvalidAction;
        const idx = std.fmt.parseInt(usize, a, 10) catch return error.InvalidAction;
        if (idx >= s.deps.convs.items.len) return error.InvalidAction;
        s.deps.active = idx;
        s.deps.ping.emit(.{});
    }

    /// `delete_chat` — arg = index (can't delete the last one).
    pub fn on_delete_chat(s: *Session, arg: ?[]const u8, value: ?[]const u8, fields: ?*const std.json.ObjectMap) !void {
        _ = value;
        _ = fields;
        const a = arg orelse return error.InvalidAction;
        const idx = std.fmt.parseInt(usize, a, 10) catch return error.InvalidAction;
        if (idx >= s.deps.convs.items.len) return error.InvalidAction;
        if (s.deps.convs.items.len <= 1) return error.LastChat;
        const c = s.deps.convs.orderedRemove(idx);
        // Purge queued sends pointing into the freed conv — comparing
        // owner pointers is safe (values only, never dereferenced).
        var w: usize = 0;
        for (s.deps.send_queue.items) |m| {
            if (m.owner != c) {
                s.deps.send_queue.items[w] = m;
                w += 1;
            }
        }
        s.deps.send_queue.shrinkRetainingCapacity(w);
        state.convFree(s.gpa, c);
        if (s.deps.active >= s.deps.convs.items.len) s.deps.active = s.deps.convs.items.len - 1;
        s.deps.ping.emit(.{});
    }

    /// `approve_tool` / `reject_tool` — arg = "{msg_index}:{call_index}".
    pub fn on_approve_tool(s: *Session, arg: ?[]const u8, value: ?[]const u8, fields: ?*const std.json.ObjectMap) !void {
        _ = value;
        _ = fields;
        const a = arg orelse return error.InvalidAction;
        try resolveCallByPos(s, a, true);
    }
    pub fn on_reject_tool(s: *Session, arg: ?[]const u8, value: ?[]const u8, fields: ?*const std.json.ObjectMap) !void {
        _ = value;
        _ = fields;
        const a = arg orelse return error.InvalidAction;
        try resolveCallByPos(s, a, false);
    }

    /// Config field setters — each `data-on-change` commits one field.
    pub fn on_cfg_base_url(s: *Session, arg: ?[]const u8, value: ?[]const u8, fields: ?*const std.json.ObjectMap) !void {
        _ = arg;
        _ = fields;
        const v = value orelse return error.InvalidAction;
        state.setStr(s.gpa, &s.deps.cfg.base_url, std.mem.trim(u8, v, " \t"));
        s.deps.ping.emit(.{});
    }
    pub fn on_cfg_api_key(s: *Session, arg: ?[]const u8, value: ?[]const u8, fields: ?*const std.json.ObjectMap) !void {
        _ = arg;
        _ = fields;
        const v = value orelse return error.InvalidAction;
        state.setStr(s.gpa, &s.deps.cfg.api_key, v);
        s.deps.key_from_env = false;
        s.deps.ping.emit(.{});
    }
    pub fn on_cfg_model(s: *Session, arg: ?[]const u8, value: ?[]const u8, fields: ?*const std.json.ObjectMap) !void {
        _ = arg;
        _ = fields;
        const v = value orelse return error.InvalidAction;
        state.setStr(s.gpa, &s.deps.cfg.model, std.mem.trim(u8, v, " \t"));
        s.deps.ping.emit(.{});
    }
    pub fn on_cfg_system(s: *Session, arg: ?[]const u8, value: ?[]const u8, fields: ?*const std.json.ObjectMap) !void {
        _ = arg;
        _ = fields;
        const v = value orelse return error.InvalidAction;
        state.setStr(s.gpa, &s.deps.cfg.system, v);
        s.deps.ping.emit(.{});
    }
    pub fn on_cfg_temperature(s: *Session, arg: ?[]const u8, value: ?[]const u8, fields: ?*const std.json.ObjectMap) !void {
        _ = arg;
        _ = fields;
        const v = value orelse return error.InvalidAction;
        s.deps.cfg.temperature = std.fmt.parseFloat(f64, std.mem.trim(u8, v, " \t")) catch return error.InvalidAction;
        s.deps.ping.emit(.{});
    }
    pub fn on_cfg_top_p(s: *Session, arg: ?[]const u8, value: ?[]const u8, fields: ?*const std.json.ObjectMap) !void {
        _ = arg;
        _ = fields;
        const v = value orelse return error.InvalidAction;
        s.deps.cfg.top_p = std.fmt.parseFloat(f64, std.mem.trim(u8, v, " \t")) catch return error.InvalidAction;
        s.deps.ping.emit(.{});
    }
    pub fn on_cfg_context_window(s: *Session, arg: ?[]const u8, value: ?[]const u8, fields: ?*const std.json.ObjectMap) !void {
        _ = arg;
        _ = fields;
        const v = value orelse return error.InvalidAction;
        s.deps.cfg.context_window = std.fmt.parseInt(u32, std.mem.trim(u8, v, " \t"), 10) catch return error.InvalidAction;
        s.deps.ping.emit(.{});
    }
    pub fn on_cfg_tool_mode(s: *Session, arg: ?[]const u8, value: ?[]const u8, fields: ?*const std.json.ObjectMap) !void {
        _ = arg;
        _ = fields;
        const v = value orelse return error.InvalidAction;
        s.deps.cfg.tool_mode = if (std.mem.eql(u8, v, "auto")) .auto else if (std.mem.eql(u8, v, "off")) .off else .manual;
        s.deps.ping.emit(.{});
    }
    /// `cfg_agent_mode` — chat ↔ code toggle. Entering code mode with
    /// an empty system prompt seeds the coding-agent preset.
    pub fn on_cfg_agent_mode(s: *Session, arg: ?[]const u8, value: ?[]const u8, fields: ?*const std.json.ObjectMap) !void {
        _ = arg;
        _ = fields;
        const v = value orelse return error.InvalidAction;
        const m: state.AgentMode = if (std.mem.eql(u8, v, "code")) .code else .chat;
        const was = s.deps.cfg.agent_mode;
        s.deps.cfg.agent_mode = m;
        if (m == .code and was != .code and s.deps.cfg.system.len == 0) {
            if (presets.findSysprompt("coding_agent")) |p| {
                state.setStr(s.gpa, &s.deps.cfg.system, p.text);
            }
        }
        noteFmt(s, "sys", "mode: {s}", .{@tagName(m)});
        s.deps.ping.emit(.{});
    }
    /// `cfg_workspace` — code-mode root for file/process tools.
    pub fn on_cfg_workspace(s: *Session, arg: ?[]const u8, value: ?[]const u8, fields: ?*const std.json.ObjectMap) !void {
        _ = arg;
        _ = fields;
        const v = value orelse return error.InvalidAction;
        state.setStr(s.gpa, &s.deps.cfg.workspace, std.mem.trim(u8, v, " \t"));
        s.deps.ping.emit(.{});
    }
    pub fn on_cfg_tools_json(s: *Session, arg: ?[]const u8, value: ?[]const u8, fields: ?*const std.json.ObjectMap) !void {
        _ = arg;
        _ = fields;
        const v = value orelse return error.InvalidAction;
        // Validate BEFORE committing — bad JSON keeps the old defs and
        // the raw text, with an inspector note explaining why.
        const defs = tools.parseDefs(s.gpa, v) catch |e| {
            noteFmt(s, "err", "tools_json rejected: {s}", .{@errorName(e)});
            s.deps.ping.emit(.{});
            return;
        };
        tools.freeDefs(s.gpa, s.deps.tool_defs);
        s.deps.tool_defs = defs;
        state.setStr(s.gpa, &s.deps.cfg.tools_json, v);
        noteFmt(s, "sys", "tools_json: {d} tool(s) loaded", .{defs.len});
        s.deps.ping.emit(.{});
    }

    /// `set_preset` — select `change` → value = preset id → fill
    /// base_url/model/context_window.
    pub fn on_set_preset(s: *Session, arg: ?[]const u8, value: ?[]const u8, fields: ?*const std.json.ObjectMap) !void {
        _ = arg;
        _ = fields;
        const a = value orelse return error.InvalidAction;
        const p = presets.find(std.mem.trim(u8, a, " \t")) orelse return error.InvalidAction;
        state.setStr(s.gpa, &s.deps.cfg.base_url, p.base_url);
        if (p.model.len != 0) state.setStr(s.gpa, &s.deps.cfg.model, p.model);
        s.deps.cfg.context_window = p.context_window;
        noteFmt(s, "sys", "preset: {s}", .{p.label});
        s.deps.ping.emit(.{});
    }

    /// `fetch_models` — GET {base}/models on a worker thread.
    pub fn on_fetch_models(s: *Session, arg: ?[]const u8, value: ?[]const u8, fields: ?*const std.json.ObjectMap) !void {
        _ = arg;
        _ = value;
        _ = fields;
        if (s.deps.cfg.base_url.len == 0) return error.ConfigRequired;
        if (s.deps.mailbox != null) return error.Busy;
        if (!spawnModels(s)) return error.SpawnFailed;
        endpointFmt(s, .busy, "GET /models…", .{});
        note(s, "sys", "fetching /models…");
        s.deps.ping.emit(.{});
    }

    /// `load_tools_example` — fill tools_json with the builtin example set.
    pub fn on_load_tools_example(s: *Session, arg: ?[]const u8, value: ?[]const u8, fields: ?*const std.json.ObjectMap) !void {
        _ = arg;
        _ = value;
        _ = fields;
        try on_cfg_tools_json(s, null, tools.example_tools_json, null);
    }

    /// `set_sysprompt` — select `change` → value = preset id → fill
    /// cfg.system. "custom" is a no-op (keeps hand-written text).
    pub fn on_set_sysprompt(s: *Session, arg: ?[]const u8, value: ?[]const u8, fields: ?*const std.json.ObjectMap) !void {
        _ = arg;
        _ = fields;
        const v = std.mem.trim(u8, value orelse return error.InvalidAction, " \t");
        if (std.mem.eql(u8, v, "custom")) return; // keep hand-written text
        const p = presets.findSysprompt(v) orelse return error.InvalidAction;
        state.setStr(s.gpa, &s.deps.cfg.system, p.text);
        noteFmt(s, "sys", "system prompt: {s}", .{p.label});
        s.deps.ping.emit(.{});
    }

    /// `cfg_mcp_servers` — textarea commit; validated BEFORE storing
    /// (same contract as tools_json). A config change invalidates
    /// previously discovered tools.
    pub fn on_cfg_mcp_servers(s: *Session, arg: ?[]const u8, value: ?[]const u8, fields: ?*const std.json.ObjectMap) !void {
        _ = arg;
        _ = fields;
        const v = value orelse return error.InvalidAction;
        const servers = mcp.parseConfig(s.gpa, v) catch |e| {
            noteFmt(s, "err", "mcp_servers rejected: {s}", .{@errorName(e)});
            s.deps.ping.emit(.{});
            return;
        };
        mcp.freeServers(s.gpa, servers);
        state.setStr(s.gpa, &s.deps.cfg.mcp_servers, v);
        // Stale discoveries no longer match the config — drop them.
        for (s.deps.mcp_tools.items) |mt| {
            state.freeStr(s.gpa, mt.server);
            state.freeStr(s.gpa, mt.tools_json);
        }
        s.deps.mcp_tools.clearRetainingCapacity();
        noteFmt(s, "sys", "mcp_servers: {d} server(s) configured", .{servers.len});
        s.deps.ping.emit(.{});
    }

    /// `mcp_check` — run initialize + tools/list against every
    /// configured server on the MCP worker mailbox.
    pub fn on_mcp_check(s: *Session, arg: ?[]const u8, value: ?[]const u8, fields: ?*const std.json.ObjectMap) !void {
        _ = arg;
        _ = value;
        _ = fields;
        if (std.mem.trim(u8, s.deps.cfg.mcp_servers, " \t\r\n").len == 0) return error.ConfigRequired;
        if (s.deps.mailbox != null or s.deps.mcp_mb != null) return error.Busy;
        const body = state.dupe(s.gpa, s.deps.cfg.mcp_servers);
        const mb = state.Mailbox.create(s.gpa, s.io, .{
            .kind = .mcp_check,
            .body = body,
        }, null);
        if (!spawnWorker(mb)) {
            s.gpa.free(body);
            mb.deinit();
            s.gpa.destroy(mb);
            return error.SpawnFailed;
        }
        s.deps.mcp_mb = mb;
        s.deps.mcp_status.kind = .busy;
        state.setStr(s.gpa, &s.deps.mcp_status.text, "checking servers…");
        note(s, "sys", "mcp: checking servers…");
        s.deps.ping.emit(.{});
    }

    /// `clear_key` — wipe the api key.
    pub fn on_clear_key(s: *Session, arg: ?[]const u8, value: ?[]const u8, fields: ?*const std.json.ObjectMap) !void {
        _ = arg;
        _ = value;
        _ = fields;
        state.setStr(s.gpa, &s.deps.cfg.api_key, "");
        s.deps.key_from_env = false;
        note(s, "sys", "api key cleared");
        s.deps.ping.emit(.{});
    }

    /// `clear_chat` — remove all messages from the active conversation.
    pub fn on_clear_chat(s: *Session, arg: ?[]const u8, value: ?[]const u8, fields: ?*const std.json.ObjectMap) !void {
        _ = arg;
        _ = value;
        _ = fields;
        const conv = curConv(s);
        for (conv.msgs.items) |m| state.msgFree(s.gpa, m);
        conv.msgs.clearRetainingCapacity();
        s.deps.ping.emit(.{});
    }

    /// The `<main>` body — generated dispatch to the active page's view.
    pub fn view(a: std.mem.Allocator, s: *Session, env: *const zmeta.Env) []const forest.Node {
        return routes.viewNodes(a, s, env);
    }

    /// Live-island routes — generated `routes.isLive` over the typed
    /// route; pages opt in with `pub const live = true`.
    pub fn pageLive(s: *Session) bool {
        return routes.isLive(s.deps.route);
    }

    /// Per-page <head> — generated dispatch to page `head` fns.
    pub fn headSpec(s: *Session, a: std.mem.Allocator, env: *const zmeta.Env) ?zmeta.HeadSpec {
        return routes.headSpec(s, a, env);
    }
};

const Skel = zmeta.Session(LlmDeps);
pub const Session = Skel;

// ── session-state helpers ────────────────────────────────────────

fn onPing(s: *Session, _: Ping) void {
    s.bumpSeq();
    persistSave(s); // throttled to 2s internally
}

pub fn curConv(s: *Session) *state.Conversation {
    return s.deps.convs.items[s.deps.active];
}

/// Append an inspector entry (bounded ring — oldest drops).
/// `chat` = conversation pointer or 0 for global.
fn noteIn(s: *Session, comptime kind: []const u8, text: []const u8, chat: usize) void {
    const g = s.gpa;
    if (s.deps.inspector.items.len >= inspector_cap) {
        const old = s.deps.inspector.orderedRemove(0);
        g.free(old.text);
    }
    s.deps.insp_seq += 1;
    s.deps.inspector.append(g, .{ .seq = s.deps.insp_seq, .kind = kind, .text = state.dupe(g, text), .chat = chat }) catch @panic("OOM");
}

fn note(s: *Session, comptime kind: []const u8, text: []const u8) void {
    noteIn(s, kind, text, @intFromPtr(curConv(s)));
}

fn noteOwnedIn(s: *Session, comptime kind: []const u8, text: []const u8, chat: usize) void {
    // text already gpa-owned — adopt it (inspector frees later).
    if (s.deps.inspector.items.len >= inspector_cap) {
        const old = s.deps.inspector.orderedRemove(0);
        s.gpa.free(old.text);
    }
    s.deps.insp_seq += 1;
    s.deps.inspector.append(s.gpa, .{ .seq = s.deps.insp_seq, .kind = kind, .text = text, .chat = chat }) catch {
        s.gpa.free(text);
    };
}

fn noteOwned(s: *Session, comptime kind: []const u8, text: []const u8) void {
    noteOwnedIn(s, kind, text, @intFromPtr(curConv(s)));
}

/// noteFmt — allocPrint then adopt (no double-alloc leak).
/// Endpoint-card status: last wire operation outcome (fetch/chat).
fn endpointFmt(s: *Session, kind: EndpointState, comptime fmt: []const u8, args: anytype) void {
    const t = std.fmt.allocPrint(s.gpa, fmt, args) catch return;
    defer s.gpa.free(t);
    s.deps.endpoint.kind = kind;
    state.setStr(s.gpa, &s.deps.endpoint.text, t);
}

fn noteFmtIn(s: *Session, comptime kind: []const u8, comptime fmt: []const u8, args: anytype, chat: usize) void {
    const t = std.fmt.allocPrint(s.gpa, fmt, args) catch return;
    noteOwnedIn(s, kind, t, chat);
}

fn noteFmt(s: *Session, comptime kind: []const u8, comptime fmt: []const u8, args: anytype) void {
    noteFmtIn(s, kind, fmt, args, @intFromPtr(curConv(s)));
}

/// Conversation pointer owning a message (for inspector chat tags).
fn convOfMsg(s: *Session, m: ?*state.Msg) usize {
    const mm = m orelse return 0;
    for (s.deps.convs.items) |c| {
        for (c.msgs.items) |x| {
            if (x == mm) return @intFromPtr(c);
        }
    }
    return 0;
}

/// Coalesce a payload onto the LAST inspector entry when kind+chat
/// match — SSE chunks would otherwise flood the ring (one entry per
/// delta) and evict the req/tool rows users actually look for.
fn noteAppend(s: *Session, comptime kind: []const u8, text: []const u8, chat: usize) bool {
    const list = &s.deps.inspector;
    if (list.items.len == 0) return false;
    const last = &list.items[list.items.len - 1];
    if (last.chat != chat or !std.mem.eql(u8, last.kind, kind)) return false;
    // Cap the merged blob — past this, start a fresh entry instead of
    // paying O(n²) realloc on every delta.
    if (last.text.len > 128 * 1024) return false;
    const g = s.gpa;
    const nt = std.fmt.allocPrint(g, "{s}\n{s}", .{ last.text, text }) catch return false;
    g.free(last.text);
    last.text = nt;
    return true;
}

fn fieldStr(f: *const std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const v = f.get(name) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

// ── stream lifecycle ─────────────────────────────────────────────

/// Drain one mailbox's pending events into session state. `is_chat`
/// selects the finalize path: chat/models mailboxes run finishStream
/// (tool loop + send queue); the MCP mailbox just closes out.
fn drainMailbox(s: *Session, mb: *state.Mailbox, is_chat: bool) void {
    var evs: std.ArrayListUnmanaged(state.Ev) = .empty;
    mb.drain(&evs);
    defer {
        for (evs.items) |ev| state.freeEv(s.gpa, ev);
        evs.deinit(s.gpa);
    }
    if (evs.items.len == 0) {
        if (mb.finished.load(.seq_cst)) finalizeMailbox(s, mb, is_chat);
        return;
    }
    var changed = false;
    for (evs.items) |ev| {
        changed = applyEv(s, mb, ev) or changed;
    }
    if (changed) s.deps.ping.emit(.{});
    if (mb.finished.load(.seq_cst)) finalizeMailbox(s, mb, is_chat);
}

fn finalizeMailbox(s: *Session, mb: *state.Mailbox, is_chat: bool) void {
    if (is_chat) {
        finishStream(s, mb);
    } else {
        s.deps.mcp_mb = null;
        mb.close();
    }
}

/// Build the tools payload for a request: user defs + discovered MCP
/// tools merged into one OpenAI `tools` array. "" when tools are off
/// or none defined. gpa-owned result — caller frees.
fn toolsPayload(s: *Session) []const u8 {
    if (s.deps.cfg.tool_mode == .off) return "";
    var aw: std.Io.Writer.Allocating = .init(s.gpa);
    const w = &aw.writer;
    w.writeByte('[') catch @panic("OOM");
    var n: usize = 0;
    // Splice the inner objects of each `[…]` array — both producers
    // (defsToToolsJson, mcp toolsToOpenAi) emit compact arrays, so
    // stripping the outer brackets and comma-joining is exact.
    const emitInner = struct {
        fn f(wr: anytype, json: []const u8, count: *usize) void {
            const t = std.mem.trim(u8, json, " \t\r\n");
            if (t.len == 0) return;
            const inner = if (t.len >= 2 and t[0] == '[' and t[t.len - 1] == ']')
                std.mem.trim(u8, t[1 .. t.len - 1], " \t\r\n")
            else
                t; // single object (builtinDef output)
            if (inner.len == 0) return;
            if (count.* != 0) wr.writeByte(',') catch @panic("OOM");
            wr.writeAll(inner) catch @panic("OOM");
            count.* += 1;
        }
    }.f;
    if (s.deps.tool_defs.len != 0) {
        const uj = tools.defsToToolsJson(s.gpa, s.deps.tool_defs);
        defer s.gpa.free(uj);
        emitInner(w, uj, &n);
    }
    // Code mode: auto-attach file/bash/proc builtins the user didn't
    // redefine in tools_json.
    if (s.deps.cfg.agent_mode == .code) {
        for (tools.code_tool_names) |name| {
            var dup = false;
            for (s.deps.tool_defs) |d| {
                if (std.mem.eql(u8, d.name, name)) {
                    dup = true;
                    break;
                }
            }
            if (dup) continue;
            const def = tools.builtinDef(s.gpa, name) orelse continue;
            emitInner(w, def, &n);
            s.gpa.free(def);
        }
    }
    for (s.deps.mcp_tools.items) |mt| {
        emitInner(w, mt.tools_json, &n);
    }
    w.writeByte(']') catch @panic("OOM");
    if (n == 0) {
        aw.deinit();
        return "";
    }
    return aw.toOwnedSlice() catch @panic("OOM");
}

/// Reaper context: the Group must be awaited before it can be freed,
/// but awaiting blocks — so a dedicated plain thread parks on the
/// group's futex (groupAwait needs no Io operations itself) and
/// releases the group once the worker task has fully completed.
const WorkerReaper = struct {
    group: *Io.Group,
    io: Io,
    gpa: std.mem.Allocator,
};

fn reapWorker(ctx: *WorkerReaper) void {
    ctx.group.await(ctx.io) catch {};
    ctx.gpa.destroy(ctx.group);
    ctx.gpa.destroy(ctx);
}

/// Spawn the LLM worker on the Io pool. A raw `std.Thread.spawn`
/// thread cannot use `std.Io` (socket ops need Io-managed context —
/// connections silently close), so the task goes through
/// `Group.concurrent`, exactly like zserver's connection tasks.
fn spawnWorker(mb: *state.Mailbox) bool {
    const g = mb.gpa;
    const group = g.create(Io.Group) catch return false;
    group.* = .init;
    const ctx = g.create(WorkerReaper) catch {
        g.destroy(group);
        return false;
    };
    ctx.* = .{ .group = group, .io = mb.io, .gpa = g };
    group.concurrent(mb.io, openai.worker, .{mb}) catch {
        g.destroy(ctx);
        g.destroy(group);
        return false;
    };
    const t = std.Thread.spawn(.{}, reapWorker, .{ctx}) catch {
        // No reaper → the 24-byte group leaks; the task itself still
        // self-cleans. Acceptable for this rare spawn failure.
        return true;
    };
    t.detach();
    return true;
}

/// Snapshot the active conversation's messages into a Job and spawn
/// the worker. `target` is the assistant Msg events apply to (null
/// for models fetch). Returns false when spawn fails.
fn spawnChat(s: *Session, target: ?*state.Msg) bool {
    const g = s.gpa;
    const conv = curConv(s);
    const tp = toolsPayload(s);
    defer if (tp.len != 0) g.free(tp);
    // Code mode: prepend the cached repo snapshot to the system text.
    var cfg_eff = s.deps.cfg;
    var sys_eff: ?[]const u8 = null;
    if (s.deps.cfg.agent_mode == .code) {
        if (repoContext(s)) |rc| {
            sys_eff = std.fmt.allocPrint(g, "{s}\n\n{s}", .{ rc, s.deps.cfg.system }) catch null;
            if (sys_eff) |se| cfg_eff.system = se;
        }
    }
    defer if (sys_eff) |se| g.free(se);
    // Compact from the front when the estimate nears the window.
    var comp = compactMsgs(s, conv, cfg_eff.system.len, tp.len);
    defer {
        if (comp.owned) |*l| l.deinit(g);
        if (comp.marker) |mk| state.msgFree(g, mk);
    }
    const body = state.buildRequest(g, &cfg_eff, comp.msgs, tp);
    const url = state.completionsUrl(g, s.deps.cfg.base_url);
    const key = state.dupe(g, s.deps.cfg.api_key);

    const mb = state.Mailbox.create(g, s.io, .{
        .kind = .chat,
        .url = url,
        .api_key = key,
        .body = body,
    }, target);
    if (!spawnWorker(mb)) {
        // Spawn failed — free job strings + mailbox.
        g.free(url);
        g.free(key);
        g.free(body);
        mb.deinit();
        g.destroy(mb);
        return false;
    }
    s.deps.mailbox = mb;
    return true;
}

fn spawnModels(s: *Session) bool {
    const g = s.gpa;
    const url = state.modelsUrl(g, s.deps.cfg.base_url);
    const key = state.dupe(g, s.deps.cfg.api_key);
    const mb = state.Mailbox.create(g, s.io, .{
        .kind = .models,
        .url = url,
        .api_key = key,
        .body = "",
    }, null);
    if (!spawnWorker(mb)) {
        g.free(url);
        g.free(key);
        mb.deinit();
        g.destroy(mb);
        return false;
    }
    s.deps.mailbox = mb;
    return true;
}

/// `send` — fields{message}: append user msg + streaming assistant
/// placeholder, then spawn (or queue when a stream is active).
fn doSend(s: *Session, text: []const u8) !void {
    const g = s.gpa;
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return error.EmptyMessage;
    if (trimmed.len > 32000) return error.MessageTooLong;
    if (s.deps.cfg.base_url.len == 0 or s.deps.cfg.model.len == 0) {
        return error.ConfigRequired;
    }
    const conv = curConv(s);
    const um = state.msgNew(g, .user);
    um.text.appendSlice(g, trimmed) catch @panic("OOM");
    state.convAppend(g, conv, um);

    if (s.deps.mailbox != null) {
        // Mid-stream: queue the user message; the stream's finish
        // handler picks it up.
        if (s.deps.send_queue.items.len >= send_queue_cap) return error.QueueFull;
        s.deps.send_queue.append(g, um) catch @panic("OOM");
        s.deps.ping.emit(.{});
        return;
    }
    startTurn(s);
}

/// Begin an assistant turn for a queued/sent user message: append the
/// streaming placeholder and spawn the worker.
fn startTurn(s: *Session) void {
    const g = s.gpa;
    const conv = curConv(s);
    const am = state.msgNew(g, .assistant);
    am.status = .streaming;
    state.convAppend(g, conv, am);
    s.deps.tool_turns = 0;
    if (!spawnChat(s, am)) {
        am.status = .failed;
        am.err = state.dupe(g, "failed to start stream worker");
    }
    s.deps.ping.emit(.{});
}

/// Mailbox finished (done/error pushed + worker exited): run the
/// tool-call loop or dequeue the next user message.
fn finishStream(s: *Session, mb: *state.Mailbox) void {
    // Read the target msg BEFORE close(): close() drops the session
    // ref and, with the worker already gone (finished ⇒ workerDone),
    // frees the mailbox — `mb` must not be touched afterwards.
    const am_opt = mb.msg;
    s.deps.mailbox = null;
    mb.close();
    const am = am_opt orelse {
        // models fetch — ids arrive as .models events (applyEv).
        return;
    };
    // am is session-owned; mailbox is gone but am persists.
    if (am.status == .streaming) {
        // Stream ended without done/error event — treat as stopped.
        am.status = .stopped;
    }
    if (am.status == .ok and am.calls.items.len != 0 and
        s.deps.cfg.tool_mode != .off and s.deps.tool_turns < max_tool_turns)
    {
        s.deps.tool_turns += 1;
        if (s.deps.cfg.tool_mode == .auto) {
            resolveAllCalls(s, am);
            maybeContinue(s, am);
            return;
        }
        // manual: calls stay .pending — approve/reject actions drive on.
        s.deps.ping.emit(.{});
        return;
    }
    // No continuation — dequeue next user message.
    if (s.deps.send_queue.items.len != 0) {
        // The queued user Msg is already in conv.msgs — startTurn
        // only appends the streaming assistant placeholder + spawns.
        _ = s.deps.send_queue.orderedRemove(0);
        startTurn(s);
        return;
    }
    s.deps.ping.emit(.{});
}

/// After tool resolution: if every call on `am` has a result, append
/// the tool messages and fire the follow-up request.
fn maybeContinue(s: *Session, am: *state.Msg) void {
    const g = s.gpa;
    for (am.calls.items) |c| {
        if (c.state == .pending or c.state == .running) return;
    }
    const conv = curConv(s);
    // Append one role=tool message per resolved call.
    for (am.calls.items) |*c| {
        const tm = state.msgNew(g, .tool);
        tm.call_id = state.dupe(g, c.id);
        tm.tool_name = state.dupe(g, c.name);
        const res = c.result orelse "(no result)";
        tm.text.appendSlice(g, res) catch @panic("OOM");
        state.convAppend(g, conv, tm);
    }
    // Follow-up assistant turn reuses the SAME mailbox lifecycle.
    const nam = state.msgNew(g, .assistant);
    nam.status = .streaming;
    state.convAppend(g, conv, nam);
    if (!spawnChat(s, nam)) {
        nam.status = .failed;
        nam.err = state.dupe(g, "failed to start stream worker");
    }
    s.deps.ping.emit(.{});
}

/// auto mode: execute every pending call on `am` inline.
fn resolveAllCalls(s: *Session, am: *state.Msg) void {
    for (am.calls.items) |*c| {
        if (c.state == .pending) resolveCall(s, am, c);
    }
}

/// Execute one tool call: find its ToolDef (user defs; builtin defs
/// are reachable via exec:"builtin" + builtin_name/name), run it,
/// store the result.
fn resolveCall(s: *Session, am: *state.Msg, c: *state.ToolCall) void {
    const g = s.gpa;
    c.state = .running;
    // Find def by wire name.
    var def: ?tools.ToolDef = null;
    for (s.deps.tool_defs) |d| {
        if (std.mem.eql(u8, d.name, c.name)) {
            def = d;
            break;
        }
    }
    if (def) |d| {
        const res = tools.exec(g, s.io, &d, c.args_json.items, s.deps.cfg.workspace);
        c.result = res;
        c.state = .done;
        noteFmtIn(s, "tool", "{s}({s}) → {s}", .{ c.name, c.args_json.items, res }, convOfMsg(s, am));
    } else if (tools.isProcTool(c.name)) {
        const res = procExec(s, c.name, c.args_json.items);
        c.result = res;
        c.state = .done;
        noteFmtIn(s, "tool", "{s}({s}) → {s}", .{ c.name, c.args_json.items, res }, convOfMsg(s, am));
    } else if (mcp.parseWireName(c.name)) |mt| {
        resolveCallMcp(s, am, c, mt.server, mt.tool);
    } else if (tools.builtinExists(c.name)) {
        // Code-mode tools are attached to the payload without living
        // in tool_defs — a bare builtin name resolves here.
        var d: tools.ToolDef = .{ .name = c.name, .exec = .builtin };
        const res = tools.exec(g, s.io, &d, c.args_json.items, s.deps.cfg.workspace);
        c.result = res;
        c.state = .done;
        noteFmtIn(s, "tool", "{s}({s}) → {s}", .{ c.name, c.args_json.items, res }, convOfMsg(s, am));
    } else {
        // Not a declared tool — answer like a real API would: error
        // result so the model can recover.
        c.result = std.fmt.allocPrint(g, "error: unknown tool '{s}'", .{c.name}) catch @panic("OOM");
        c.state = .failed;
        noteFmtIn(s, "tool", "{s}: unknown tool", .{c.name}, convOfMsg(s, am));
    }
}

// ── code-mode background processes ───────────────────────────────

/// Dispatch a proc_* tool call — all handlers are synchronous and
/// return gpa-owned result text.
fn procExec(s: *Session, name: []const u8, args_json: []const u8) []const u8 {
    const g = s.gpa;
    var parsed = std.json.parseFromSlice(std.json.Value, g, args_json, .{}) catch
        return state.dupe(g, "error: bad args json");
    defer parsed.deinit();
    const obj: ?std.json.ObjectMap = switch (parsed.value) {
        .object => |o| o,
        else => null,
    };
    if (std.mem.eql(u8, name, "proc_start")) return procStart(s, obj);
    if (std.mem.eql(u8, name, "proc_output")) return procOutput(s, obj);
    if (std.mem.eql(u8, name, "proc_list")) return procList(s);
    if (std.mem.eql(u8, name, "proc_kill")) return procKill(s, obj);
    return state.dupe(g, "error: unknown proc tool");
}

fn procFind(s: *Session, id: u32) ?*Proc {
    for (s.deps.procs.items) |*p| {
        if (p.id == id) return p;
    }
    return null;
}

/// Drain whatever pipe data is available right now (non-blocking),
/// then reap the child once BOTH pipes hit EOF.
fn procDrain(s: *Session, p: *Proc) void {
    if (p.done) return;
    const so = p.child.stdout orelse return;
    const se = p.child.stderr orelse return;
    const fds = [_]std.posix.fd_t{ so.handle, se.handle };
    var chunk: [8192]u8 = undefined;
    while (true) {
        var pfds = [_]std.posix.pollfd{
            .{ .fd = fds[0], .events = if (p.eof[0]) 0 else std.posix.POLL.IN, .revents = 0 },
            .{ .fd = fds[1], .events = if (p.eof[1]) 0 else std.posix.POLL.IN, .revents = 0 },
        };
        _ = std.posix.poll(&pfds, 0) catch return;
        var any = false;
        for (pfds, 0..) |pfd, i| {
            if (pfd.revents == 0) continue;
            any = true;
            const n = std.posix.read(fds[i], &chunk) catch {
                p.eof[i] = true;
                continue;
            };
            if (n == 0) {
                p.eof[i] = true;
                continue;
            }
            if (p.out.items.len < 256 * 1024) {
                const room = 256 * 1024 - p.out.items.len;
                p.out.appendSlice(s.gpa, chunk[0..@min(n, room)]) catch {};
            }
        }
        if (!any) break;
    }
    if (p.eof[0] and p.eof[1]) {
        if (p.child.wait(s.io)) |t| {
            p.code = switch (t) {
                .exited => |c| @intCast(c),
                else => -1,
            };
        } else |_| {
            p.code = -1;
        }
        p.done = true;
    }
}

fn procStart(s: *Session, obj: ?std.json.ObjectMap) []const u8 {
    const g = s.gpa;
    const cmd = tools.argStr(obj, "command") orelse return state.dupe(g, "error: missing 'command'");
    if (cmd.len == 0 or cmd.len > 4000) return state.dupe(g, "error: command empty or too long");
    const argv = [_][]const u8{ "sh", "-c", cmd };
    const em = tools.scrubbedEnv(g);
    defer if (em) |m| {
        m.deinit();
        g.destroy(m);
    };
    var child = std.process.spawn(s.io, .{
        .argv = &argv,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        .cwd = if (s.deps.cfg.workspace.len != 0) .{ .path = s.deps.cfg.workspace } else .inherit,
        .environ_map = em,
    }) catch return state.dupe(g, "error: spawn failed");
    const id = s.deps.proc_seq;
    s.deps.proc_seq +%= 1;
    const heap_child = g.create(std.process.Child) catch {
        child.kill(s.io);
        return state.dupe(g, "error: oom");
    };
    heap_child.* = child;
    const cmd_dup = state.dupe(g, cmd);
    s.deps.procs.append(g, .{
        .id = id,
        .cmd = cmd_dup,
        .child = heap_child,
    }) catch {
        state.freeStr(g, cmd_dup);
        heap_child.kill(s.io);
        g.destroy(heap_child);
        return state.dupe(g, "error: oom");
    };
    return std.fmt.allocPrint(g, "proc {d} started: {s}", .{ id, cmd }) catch @panic("OOM");
}

fn procOutput(s: *Session, obj: ?std.json.ObjectMap) []const u8 {
    const g = s.gpa;
    const id = tools.argF64(obj, "id") orelse return state.dupe(g, "error: missing 'id'");
    const p = procFind(s, @intFromFloat(id)) orelse
        return state.dupe(g, "error: no such proc");
    procDrain(s, p);
    const fresh = p.out.items[p.pos..];
    p.pos = p.out.items.len;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(g);
    // Tail-cap very large bursts so the tool result stays sane.
    const slice = if (fresh.len > 32 * 1024) fresh[fresh.len - 32 * 1024 ..] else fresh;
    if (slice.len != fresh.len) out.appendSlice(g, "[earlier output truncated]\n") catch @panic("OOM");
    out.appendSlice(g, slice) catch @panic("OOM");
    const status = if (p.done)
        std.fmt.allocPrint(g, "exited {d}", .{p.code}) catch @panic("OOM")
    else
        state.dupe(g, "running");
    defer g.free(status);
    out.print(g, "\n[proc {d}: {s}]", .{ p.id, status }) catch @panic("OOM");
    return out.toOwnedSlice(g) catch @panic("OOM");
}

fn procList(s: *Session) []const u8 {
    const g = s.gpa;
    if (s.deps.procs.items.len == 0) return state.dupe(g, "no background processes");
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(g);
    for (s.deps.procs.items) |*p| {
        procDrain(s, p);
        const st = if (p.done)
            std.fmt.allocPrint(g, "exited {d}", .{p.code}) catch @panic("OOM")
        else
            state.dupe(g, "running");
        defer g.free(st);
        const cmd = p.cmd[0..@min(p.cmd.len, 80)];
        out.print(g, "proc {d}: {s} — {s}\n", .{ p.id, st, cmd }) catch @panic("OOM");
    }
    return out.toOwnedSlice(g) catch @panic("OOM");
}

fn procKill(s: *Session, obj: ?std.json.ObjectMap) []const u8 {
    const g = s.gpa;
    const id = tools.argF64(obj, "id") orelse return state.dupe(g, "error: missing 'id'");
    const p = procFind(s, @intFromFloat(id)) orelse
        return state.dupe(g, "error: no such proc");
    if (p.done) {
        return std.fmt.allocPrint(g, "proc {d} already exited {d}", .{ p.id, p.code }) catch @panic("OOM");
    }
    p.child.kill(s.io);
    p.done = true;
    p.code = -1;
    p.eof = .{ true, true };
    return std.fmt.allocPrint(g, "proc {d} killed", .{p.id}) catch @panic("OOM");
}

// ── code-mode repo context ───────────────────────────────────────

/// Run `sh -c cmd` capturing stdout (stderr dropped), ~3s deadline.
/// Returns gpa-owned output or null. Used for git/ls probes only.
fn captureCmd(s: *Session, cmd: []const u8, timeout_ms: u64) ?[]const u8 {
    const g = s.gpa;
    const argv = [_][]const u8{ "sh", "-c", cmd };
    const em = tools.scrubbedEnv(g);
    defer if (em) |m| {
        m.deinit();
        g.destroy(m);
    };
    var child = std.process.spawn(s.io, .{
        .argv = &argv,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
        .cwd = if (s.deps.cfg.workspace.len != 0) .{ .path = s.deps.cfg.workspace } else .inherit,
        .environ_map = em,
    }) catch return null;
    defer child.kill(s.io);
    const so = child.stdout orelse return null;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(g);
    var chunk: [8192]u8 = undefined;
    const start = Io.Clock.real.now(s.io);
    var eof = false;
    while (!eof) {
        if (Io.Clock.real.now(s.io).toMilliseconds() - start.toMilliseconds() >= @as(i64, @intCast(timeout_ms))) break;
        var pfds = [_]std.posix.pollfd{.{ .fd = so.handle, .events = std.posix.POLL.IN, .revents = 0 }};
        _ = std.posix.poll(&pfds, 100) catch break;
        if (pfds[0].revents == 0) continue;
        const n = std.posix.read(so.handle, &chunk) catch {
            eof = true;
            continue;
        };
        if (n == 0) {
            eof = true;
            continue;
        }
        if (out.items.len < 16 * 1024) {
            const room = 16 * 1024 - out.items.len;
            out.appendSlice(g, chunk[0..@min(n, room)]) catch {};
        }
    }
    return out.toOwnedSlice(g) catch null;
}

/// Repo snapshot for code mode: branch, dirty status, recent log,
/// top-level listing — cached per workspace string.
fn repoContext(s: *Session) ?[]const u8 {
    const g = s.gpa;
    const ws = s.deps.cfg.workspace;
    if (std.mem.eql(u8, s.deps.repo_ctx_ws, ws)) {
        return if (s.deps.repo_ctx.len != 0) s.deps.repo_ctx else null;
    }
    state.freeStr(g, s.deps.repo_ctx);
    state.freeStr(g, s.deps.repo_ctx_ws);
    s.deps.repo_ctx_ws = state.dupe(g, ws);
    s.deps.repo_ctx = "";

    const probe = captureCmd(s, "git rev-parse --is-inside-work-tree 2>/dev/null", 1500);
    defer if (probe) |p| g.free(p);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(g);
    out.appendSlice(g, "Workspace root for this session. ") catch @panic("OOM");
    if (ws.len != 0) {
        out.print(g, "Root: {s}. ", .{ws}) catch @panic("OOM");
    } else {
        out.appendSlice(g, "Root: current directory. ") catch @panic("OOM");
    }
    const in_git = probe != null and std.mem.indexOf(u8, probe.?, "true") != null;
    if (in_git) {
        const branch = captureCmd(s, "git branch --show-current 2>/dev/null", 1500);
        defer if (branch) |b| g.free(b);
        const status = captureCmd(s, "git status --short 2>/dev/null | head -25", 2000);
        defer if (status) |st| g.free(st);
        const log = captureCmd(s, "git log --oneline -3 2>/dev/null", 1500);
        defer if (log) |l| g.free(l);
        out.appendSlice(g, "Git repo. ") catch @panic("OOM");
        if (branch) |b| {
            const bn = std.mem.trim(u8, b, " \t\r\n");
            if (bn.len != 0) out.print(g, "Branch: {s}. ", .{bn}) catch @panic("OOM");
        }
        if (status) |st| {
            const stt = std.mem.trim(u8, st, " \t\r\n");
            if (stt.len != 0) {
                out.appendSlice(g, "Working tree changes:\n```\n") catch @panic("OOM");
                out.appendSlice(g, stt) catch @panic("OOM");
                out.appendSlice(g, "\n```\n") catch @panic("OOM");
            }
        }
        if (log) |l| {
            const lt = std.mem.trim(u8, l, " \t\r\n");
            if (lt.len != 0) {
                out.appendSlice(g, "Recent commits:\n```\n") catch @panic("OOM");
                out.appendSlice(g, lt) catch @panic("OOM");
                out.appendSlice(g, "\n```\n") catch @panic("OOM");
            }
        }
    } else {
        out.appendSlice(g, "Not a git repository. ") catch @panic("OOM");
    }
    const listing = captureCmd(s, "ls -A 2>/dev/null | head -40", 1500);
    defer if (listing) |l| g.free(l);
    if (listing) |l| {
        const lt = std.mem.trim(u8, l, " \t\r\n");
        if (lt.len != 0) {
            out.appendSlice(g, "Top-level entries:\n```\n") catch @panic("OOM");
            out.appendSlice(g, lt) catch @panic("OOM");
            out.appendSlice(g, "\n```\n") catch @panic("OOM");
        }
    }
    if (out.items.len == 0) return null;
    s.deps.repo_ctx = out.toOwnedSlice(g) catch return null;
    return s.deps.repo_ctx;
}

// ── context compaction ───────────────────────────────────────────

/// Estimated tokens of the request payload (system + tools + msgs).
fn requestEstTokens(msgs: []const *state.Msg, tools_len: usize, sys_len: usize) u64 {
    return state.estTokens(msgs, sys_len + tools_len);
}

/// Build the message list for a request, compacting from the front
/// when the estimate exceeds 75% of the context window. Drop units
/// are whole turns: an assistant msg with tool_calls takes its
/// trailing tool msgs with it (the API rejects orphan tool msgs).
/// Returns gpa-owned slice of *Msg plus an optional marker Msg the
/// caller must keep alive — both freed by the caller's arena scope.
fn compactMsgs(s: *Session, conv: *state.Conversation, sys_len: usize, tools_len: usize) struct { msgs: []const *state.Msg, owned: ?std.ArrayListUnmanaged(*state.Msg), marker: ?*state.Msg } {
    const g = s.gpa;
    const budget = @as(u64, s.deps.cfg.context_window) * 3 / 4;
    const est = requestEstTokens(conv.msgs.items, tools_len, sys_len);
    if (est <= budget or conv.msgs.items.len <= 2) {
        return .{ .msgs = conv.msgs.items, .owned = null, .marker = null };
    }
    // Group into drop units.
    var units: std.ArrayListUnmanaged([]const *state.Msg) = .empty;
    defer units.deinit(g);
    var i: usize = 0;
    while (i < conv.msgs.items.len) {
        const start = i;
        i += 1;
        const m = conv.msgs.items[start];
        if (m.role == .assistant and m.calls.items.len != 0) {
            while (i < conv.msgs.items.len and conv.msgs.items[i].role == .tool) i += 1;
        }
        units.append(g, conv.msgs.items[start..i]) catch @panic("OOM");
    }
    // Never drop the last unit (current turn).
    var drop: usize = 0;
    var kept_est = est;
    while (drop + 1 < units.items.len) {
        var unit_est: u64 = 0;
        for (units.items[drop]) |m| unit_est += state.estTokens(&[_]*state.Msg{m}, 0);
        if (kept_est -| unit_est <= budget) break;
        kept_est -|= unit_est;
        drop += 1;
    }
    if (drop == 0) return .{ .msgs = conv.msgs.items, .owned = null, .marker = null };
    const dropped: usize = blk: {
        var n: usize = 0;
        for (units.items[0..drop]) |u| n += u.len;
        break :blk n;
    };
    const marker_text = std.fmt.allocPrint(g, "[…{d} earlier message(s) omitted to fit the context window]", .{dropped}) catch @panic("OOM");
    const marker = state.msgNew(g, .user);
    marker.text.appendSlice(g, marker_text) catch @panic("OOM");
    g.free(marker_text);
    var list: std.ArrayListUnmanaged(*state.Msg) = .empty;
    list.append(g, marker) catch @panic("OOM");
    for (units.items[drop..]) |u| {
        for (u) |m| list.append(g, m) catch @panic("OOM");
    }
    return .{ .msgs = list.items, .owned = list, .marker = marker };
}

// ── file persistence ─────────────────────────────────────────────

fn persistPath(s: *Session) ?[]const u8 {
    if (s.deps.sess_token.len == 0) return null;
    var ok = true;
    for (s.deps.sess_token) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') ok = false;
    }
    if (!ok) return null;
    return std.fmt.allocPrint(s.gpa, "zllm-data/{s}.json", .{s.deps.sess_token}) catch null;
}

const PMsg = struct {
    role: []const u8,
    text: []const u8 = "",
    reasoning: []const u8 = "",
    call_id: ?[]const u8 = null,
    tool_name: ?[]const u8 = null,
    status: []const u8 = "ok",
    calls: []PCall = &.{},
};
const PCall = struct {
    id: []const u8,
    name: []const u8,
    args_json: []const u8 = "",
    state: []const u8 = "pending",
    result: ?[]const u8 = null,
};
const PConv = struct { title: []const u8, msgs: []PMsg };
const PCfg = struct {
    base_url: []const u8 = "",
    model: []const u8 = "",
    system: []const u8 = "",
    temperature: f64 = 0.7,
    top_p: f64 = 1.0,
    context_window: u32 = 64000,
    tool_mode: []const u8 = "manual",
    agent_mode: []const u8 = "chat",
    workspace: []const u8 = "",
    tools_json: []const u8 = "",
    mcp_servers: []const u8 = "",
};
const PState = struct {
    convs: []PConv,
    active: u32,
    cfg: PCfg,
};

fn msgToP(g: std.mem.Allocator, m: *const state.Msg) PMsg {
    var calls: std.ArrayListUnmanaged(PCall) = .empty;
    for (m.calls.items) |c| {
        calls.append(g, .{
            .id = c.id,
            .name = c.name,
            .args_json = c.args_json.items,
            .state = @tagName(c.state),
            .result = c.result,
        }) catch @panic("OOM");
    }
    return .{
        .role = @tagName(m.role),
        .text = m.text.items,
        .reasoning = m.reasoning.items,
        .call_id = m.call_id,
        .tool_name = m.tool_name,
        .status = @tagName(m.status),
        .calls = calls.items,
    };
}

fn pToMsg(g: std.mem.Allocator, pm: PMsg) *state.Msg {
    const role: state.Role = if (std.mem.eql(u8, pm.role, "assistant")) .assistant else if (std.mem.eql(u8, pm.role, "tool")) .tool else .user;
    const m = state.msgNew(g, role);
    m.text.appendSlice(g, pm.text) catch @panic("OOM");
    m.reasoning.appendSlice(g, pm.reasoning) catch @panic("OOM");
    if (pm.call_id) |cid| m.call_id = state.dupe(g, cid);
    if (pm.tool_name) |tn| m.tool_name = state.dupe(g, tn);
    m.status = if (std.mem.eql(u8, pm.status, "failed")) .failed else if (std.mem.eql(u8, pm.status, "streaming")) .streaming else .ok;
    for (pm.calls) |pc| {
        const st: state.CallState = if (std.mem.eql(u8, pc.state, "done")) .done else if (std.mem.eql(u8, pc.state, "rejected")) .rejected else if (std.mem.eql(u8, pc.state, "failed")) .failed else .pending; // running → pending (stream is gone)
        m.calls.append(g, .{
            .id = state.dupe(g, pc.id),
            .name = state.dupe(g, pc.name),
            .state = st,
            .result = if (pc.result) |r| state.dupe(g, r) else null,
        }) catch @panic("OOM");
        const last = &m.calls.items[m.calls.items.len - 1];
        last.args_json.appendSlice(g, pc.args_json) catch @panic("OOM");
    }
    return m;
}

/// Serialize convs+msgs+cfg subset to zllm-data/<token>.json.
/// Throttled to once per 2s; deinit bypasses the throttle.
fn persistSave(s: *Session) void {
    const g = s.gpa;
    const path = persistPath(s) orelse return;
    defer g.free(path);
    const now = Io.Clock.real.now(s.io).toMilliseconds();
    if (now - s.deps.last_persist_ms < 2000) return;
    s.deps.last_persist_ms = now;

    var convs: std.ArrayListUnmanaged(PConv) = .empty;
    defer {
        for (convs.items) |c| {
            for (c.msgs) |m| g.free(m.calls);
            g.free(c.msgs);
        }
        g.free(convs.items);
    }
    for (s.deps.convs.items) |conv| {
        var msgs: std.ArrayListUnmanaged(PMsg) = .empty;
        for (conv.msgs.items) |m| msgs.append(g, msgToP(g, m)) catch @panic("OOM");
        convs.append(g, .{ .title = conv.title, .msgs = msgs.items }) catch @panic("OOM");
    }
    const ps: PState = .{
        .convs = convs.items,
        .active = @intCast(@min(s.deps.active, std.math.maxInt(u32))),
        .cfg = .{
            .base_url = s.deps.cfg.base_url,
            .model = s.deps.cfg.model,
            .system = s.deps.cfg.system,
            .temperature = s.deps.cfg.temperature,
            .top_p = s.deps.cfg.top_p,
            .context_window = s.deps.cfg.context_window,
            .tool_mode = @tagName(s.deps.cfg.tool_mode),
            .agent_mode = @tagName(s.deps.cfg.agent_mode),
            .workspace = s.deps.cfg.workspace,
            .tools_json = s.deps.cfg.tools_json,
            .mcp_servers = s.deps.cfg.mcp_servers,
        },
    };
    var aw: std.Io.Writer.Allocating = .init(g);
    std.json.Stringify.value(ps, .{}, &aw.writer) catch return;
    const data = aw.toOwnedSlice() catch return;
    defer g.free(data);
    const dir = std.fs.path.dirname(path) orelse "zllm-data";
    std.Io.Dir.cwd().createDirPath(s.io, dir) catch {};
    std.Io.Dir.cwd().writeFile(s.io, .{ .sub_path = path, .data = data }) catch {};
}

/// Load persisted state for this session's cookie token — replaces
/// the default "Chat 1" conv. Runs once, lazily, on first request.
fn persistLoad(s: *Session) void {
    const g = s.gpa;
    s.deps.persist_loaded = true;
    const path = persistPath(s) orelse return;
    defer g.free(path);
    const data = std.Io.Dir.cwd().readFileAlloc(s.io, path, g, .limited(8 * 1024 * 1024)) catch return;
    defer g.free(data);
    const ps = std.json.parseFromSlice(PState, g, data, .{}) catch return;
    defer ps.deinit();
    if (ps.value.convs.len == 0) return;
    // Free the default conv, rebuild from disk.
    for (s.deps.convs.items) |c| state.convFree(g, c);
    s.deps.convs.clearRetainingCapacity();
    for (ps.value.convs, 0..) |pc, ci| {
        const conv = state.convNew(g, pc.title);
        for (pc.msgs) |pm| {
            const m = pToMsg(g, pm);
            state.convAppend(g, conv, m);
        }
        s.deps.convs.append(g, conv) catch @panic("OOM");
        _ = ci;
    }
    s.deps.active = @min(@as(usize, ps.value.active), s.deps.convs.items.len - 1);
    const c = ps.value.cfg;
    state.setStr(g, &s.deps.cfg.base_url, c.base_url);
    state.setStr(g, &s.deps.cfg.model, c.model);
    state.setStr(g, &s.deps.cfg.system, c.system);
    s.deps.cfg.temperature = c.temperature;
    s.deps.cfg.top_p = c.top_p;
    s.deps.cfg.context_window = c.context_window;
    s.deps.cfg.tool_mode = if (std.mem.eql(u8, c.tool_mode, "auto")) .auto else if (std.mem.eql(u8, c.tool_mode, "off")) .off else .manual;
    s.deps.cfg.agent_mode = if (std.mem.eql(u8, c.agent_mode, "code")) .code else .chat;
    state.setStr(g, &s.deps.cfg.workspace, c.workspace);
    state.setStr(g, &s.deps.cfg.tools_json, c.tools_json);
    state.setStr(g, &s.deps.cfg.mcp_servers, c.mcp_servers);
    // Re-parse tool defs from restored tools_json.
    if (c.tools_json.len != 0) {
        const defs = tools.parseDefs(g, c.tools_json) catch &.{};
        tools.freeDefs(g, s.deps.tool_defs);
        s.deps.tool_defs = defs;
    }
}

/// `readCookies` hook — capture the session cookie token so state can
/// persist per-browser across restarts.
pub fn readCookies(s: *Session, cookie_hdr: ?[]const u8) void {
    const hdr = cookie_hdr orelse return;
    const prefix = LlmDeps.cookie_name ++ "=";
    var it = std.mem.splitScalar(u8, hdr, ';');
    while (it.next()) |part| {
        const p = std.mem.trim(u8, part, " \t");
        if (std.mem.startsWith(u8, p, prefix)) {
            const tok = p[prefix.len..];
            if (tok.len != 0 and tok.len <= 128) {
                state.setStr(s.gpa, &s.deps.sess_token, tok);
                if (!s.deps.persist_loaded) persistLoad(s);
            }
            return;
        }
    }
}

/// MCP tool call: async JSON-RPC tools/call on the MCP mailbox.
/// The call stays `.running` until the `.mcp_call` event lands —
/// maybeContinue fires the follow-up request once ALL calls resolve.
fn resolveCallMcp(s: *Session, am: *state.Msg, c: *state.ToolCall, server_name: []const u8, tool_name: []const u8) void {
    const g = s.gpa;
    c.state = .running;
    const fail = struct {
        fn f(sess: *Session, tc: *state.ToolCall, msg: []const u8) void {
            if (tc.result) |old| state.freeStr(sess.gpa, old);
            tc.result = state.dupe(sess.gpa, msg);
            tc.state = .failed;
        }
    }.f;
    // Locate conv/msg/call positions for result routing.
    var conv_i: ?usize = null;
    var msg_i: ?usize = null;
    for (s.deps.convs.items, 0..) |conv, i| {
        for (conv.msgs.items, 0..) |m, j| {
            if (m == am) {
                conv_i = i;
                msg_i = j;
                break;
            }
        }
        if (conv_i != null) break;
    }
    const ci = conv_i orelse {
        fail(s, c, "error: mcp call lost (conversation not found)");
        return;
    };
    const mi = msg_i.?;
    const ki: usize = @intCast(c - am.calls.items.ptr);
    if (ki >= am.calls.items.len) {
        fail(s, c, "error: mcp call lost (call slot invalid)");
        return;
    }
    if (s.deps.mcp_mb != null) {
        fail(s, c, "error: another mcp call is in flight");
        return;
    }
    const servers = mcp.parseConfig(g, s.deps.cfg.mcp_servers) catch {
        fail(s, c, "error: mcp config invalid");
        return;
    };
    defer mcp.freeServers(g, servers);
    var srv: ?mcp.Server = null;
    for (servers) |sv| {
        if (std.mem.eql(u8, sv.name, server_name)) {
            srv = sv;
            break;
        }
    }
    const sv = srv orelse {
        fail(s, c, "error: unknown mcp server");
        return;
    };
    // params = {"name":<tool>,"arguments":<args|{}>} — args must be a
    // JSON object; malformed model output degrades to {}.
    const args_raw = std.mem.trim(u8, c.args_json.items, " \t\r\n");
    var args_ok = false;
    if (args_raw.len != 0) {
        var ap = std.json.parseFromSlice(std.json.Value, g, args_raw, .{}) catch null;
        defer if (ap) |*p| p.deinit();
        args_ok = ap != null and ap.?.value == .object;
    }
    var aw: std.Io.Writer.Allocating = .init(g);
    const w = &aw.writer;
    w.writeAll("{\"name\":") catch @panic("OOM");
    state.jsonStrPub(w, tool_name) catch @panic("OOM");
    w.writeAll(",\"arguments\":") catch @panic("OOM");
    if (args_ok) {
        w.writeAll(args_raw) catch @panic("OOM");
    } else {
        w.writeAll("{}") catch @panic("OOM");
    }
    w.writeByte('}') catch @panic("OOM");
    const params = aw.toOwnedSlice() catch @panic("OOM");
    // stdio servers carry argv JSON + env object; http carries url +
    // headers JSON (both ride the same Job.extra slot).
    var argv_json: []const u8 = "";
    var hdrs: []const u8 = undefined;
    var url: []const u8 = "";
    if (sv.stdio) {
        var aw2: std.Io.Writer.Allocating = .init(g);
        const w2 = &aw2.writer;
        w2.writeByte('[') catch @panic("OOM");
        state.jsonStrPub(w2, sv.command) catch @panic("OOM");
        for (sv.args) |a| {
            w2.writeByte(',') catch @panic("OOM");
            state.jsonStrPub(w2, a) catch @panic("OOM");
        }
        w2.writeByte(']') catch @panic("OOM");
        argv_json = aw2.toOwnedSlice() catch @panic("OOM");
        hdrs = mcp.headersJsonFor(g, sv.env);
    } else {
        url = state.dupe(g, sv.url);
        hdrs = mcp.headersJsonFor(g, sv.headers);
    }
    const mb = state.Mailbox.create(g, s.io, .{
        .kind = .mcp_call,
        .url = url,
        .body = params,
        .extra = hdrs,
        .argv = argv_json,
        .pos_conv = @intCast(ci),
        .pos_msg = @intCast(mi),
        .pos_call = @intCast(ki),
    }, null);
    if (!spawnWorker(mb)) {
        // mb.deinit frees the job's owned url/body/extra.
        mb.deinit();
        g.destroy(mb);
        fail(s, c, "error: failed to start mcp worker");
        return;
    }
    s.deps.mcp_mb = mb;
    noteFmtIn(s, "mcp", "{s}/{s} → calling", .{ server_name, tool_name }, convOfMsg(s, am));
}

/// approve/reject by position — arg = "{msg_index}:{call_index}".
/// Positional args survive duplicate/placeholder call ids.
fn resolveCallByPos(s: *Session, arg: []const u8, approve: bool) !void {
    const g = s.gpa;
    const conv = curConv(s);
    var it = std.mem.splitScalar(u8, arg, ':');
    const mi = std.fmt.parseInt(usize, it.first(), 10) catch return error.InvalidAction;
    const ci = std.fmt.parseInt(usize, it.rest(), 10) catch return error.InvalidAction;
    if (mi >= conv.msgs.items.len) return error.InvalidAction;
    const am = conv.msgs.items[mi];
    if (am.role != .assistant or ci >= am.calls.items.len) return error.InvalidAction;
    const c = &am.calls.items[ci];
    if (c.state != .pending) return error.CallResolved;
    if (approve) {
        resolveCall(s, am, c);
    } else {
        c.state = .rejected;
        c.result = state.dupe(g, "tool call rejected by user");
        noteFmtIn(s, "tool", "{s}: rejected", .{c.name}, @intFromPtr(curConv(s)));
    }
    // All resolved? → continue the conversation.
    var pending = false;
    for (am.calls.items) |cc| {
        if (cc.state == .pending or cc.state == .running) pending = true;
    }
    if (!pending) maybeContinue(s, am);
    s.deps.ping.emit(.{});
}

// ── event application ────────────────────────────────────────────

/// Apply one mailbox event to session state. Returns true when the
/// view should re-render.
fn applyEv(s: *Session, mb: *state.Mailbox, ev: state.Ev) bool {
    const g = s.gpa;
    // MCP jobs relabel wire logs as "mcp" in the inspector.
    const is_mcp_job = mb.job.kind == .mcp_check or mb.job.kind == .mcp_call;
    // Session-level events first — they apply with or without a
    // target message (models fetch has msg == null).
    switch (ev) {
        .raw => |r| {
            if (is_mcp_job) {
                noteIn(s, "mcp", r, 0);
            } else {
                // Chat SSE payloads coalesce into one growing entry —
                // one row per delta would flood the inspector ring.
                const chat = convOfMsg(s, mb.msg);
                if (!noteAppend(s, "sse", r, chat)) noteIn(s, "sse", r, chat);
            }
            return true;
        },
        .req => |r| {
            if (is_mcp_job) {
                noteIn(s, "mcp", r, 0);
            } else {
                noteIn(s, "req", r, convOfMsg(s, mb.msg));
            }
            return true;
        },
        .mcp => |r| {
            // Upsert this server's discovered tools ("[]" on failure
            // clears stale entries).
            var found = false;
            for (s.deps.mcp_tools.items) |*mt| {
                if (std.mem.eql(u8, mt.server, r.server)) {
                    state.freeStr(g, mt.tools_json);
                    mt.tools_json = state.dupe(g, r.tools_json);
                    found = true;
                    break;
                }
            }
            if (!found) {
                s.deps.mcp_tools.append(g, .{
                    .server = state.dupe(g, r.server),
                    .tools_json = state.dupe(g, r.tools_json),
                }) catch @panic("OOM");
            }
            noteFmtIn(s, "mcp", "{s}: {s}", .{ r.server, r.detail }, 0);
            s.deps.mcp_status.kind = if (r.ok) .ok else .err;
            const t = std.fmt.allocPrint(g, "{s}: {s}", .{ r.server, r.detail }) catch return true;
            defer g.free(t);
            state.setStr(g, &s.deps.mcp_status.text, t);
            return true;
        },
        .mcp_call => |r| {
            if (r.conv >= s.deps.convs.items.len) return false;
            const conv = s.deps.convs.items[r.conv];
            if (r.msg >= conv.msgs.items.len) return false;
            const am = conv.msgs.items[r.msg];
            if (r.call >= am.calls.items.len) return false;
            const c = &am.calls.items[r.call];
            if (c.state != .running) return false; // resolved meanwhile
            if (c.result) |old| state.freeStr(g, old);
            c.result = state.dupe(g, r.text);
            c.state = if (r.ok) .done else .failed;
            noteFmtIn(s, "mcp", "{s} → {s}", .{ c.name, r.text }, @intFromPtr(conv));
            var pending = false;
            for (am.calls.items) |cc| {
                if (cc.state == .pending or cc.state == .running) pending = true;
            }
            if (!pending) maybeContinue(s, am);
            return true;
        },
        .models => |ids| {
            const copy = g.alloc([]const u8, ids.len) catch @panic("OOM");
            for (ids, copy) |id, *dst| dst.* = state.dupe(g, id);
            for (s.deps.models) |id| g.free(id);
            if (s.deps.models.len != 0) g.free(s.deps.models);
            s.deps.models = copy;
            endpointFmt(s, .ok, "{d} model(s) loaded", .{ids.len});
            // Empty model field → adopt the first fetched id so the
            // user never has to type a model name by hand.
            if (s.deps.cfg.model.len == 0 and s.deps.models.len != 0)
                state.setStr(g, &s.deps.cfg.model, s.deps.models[0]);
            noteFmt(s, "sys", "{d} model(s) loaded", .{ids.len});
            return true;
        },
        else => {},
    }
    const am = mb.msg orelse return false;
    switch (ev) {
        .delta => |d| {
            am.text.appendSlice(g, d) catch @panic("OOM");
            return true;
        },
        .reasoning => |d| {
            am.reasoning.appendSlice(g, d) catch @panic("OOM");
            return true;
        },
        .call_delta => |cd| {
            // Index-addressed accumulation: ensure slot exists.
            while (am.calls.items.len <= cd.index) {
                am.calls.append(g, .{ .id = "", .name = "" }) catch @panic("OOM");
            }
            const c = &am.calls.items[cd.index];
            if (cd.id) |id| {
                state.freeStr(g, c.id);
                c.id = state.dupe(g, id);
            }
            if (cd.name) |n| {
                state.freeStr(g, c.name);
                c.name = state.dupe(g, n);
            } else if (c.name.len == 0) {
                c.name = state.dupe(g, "?");
            }
            if (cd.args) |a| {
                c.args_json.appendSlice(g, a) catch @panic("OOM");
            }
            if (c.id.len == 0) c.id = state.dupe(g, "call_pending");
            return true;
        },
        .usage => |u| {
            am.usage = u;
            return true;
        },
        .done => {
            am.status = .ok;
            endpointFmt(s, .ok, "stream finished", .{});
            return true;
        },
        .err => |e| {
            am.status = .failed;
            if (am.err) |old| state.freeStr(g, old);
            am.err = state.dupe(g, e);
            endpointFmt(s, .err, "{s}", .{e});
            return true;
        },
        // .raw/.req/.models/.mcp/.mcp_call returned early above.
        .raw, .req, .models, .mcp, .mcp_call => unreachable,
    }
}

// ── tests ────────────────────────────────────────────────────────

test "smoke: session create/deinit + send validation" {
    const gpa = std.testing.allocator;
    const s = Session.create(gpa, std.testing.io);
    defer s.deinit();
    try std.testing.expectEqual(@as(usize, 1), s.deps.convs.items.len);
    try std.testing.expectEqualStrings("", s.deps.cfg.api_key);
    // send without config → ConfigRequired
    try std.testing.expectError(error.ConfigRequired, doSend(s, "hi"));
}

test "smoke: cfg setters + preset + tools_json roundtrip" {
    const gpa = std.testing.allocator;
    const s = Session.create(gpa, std.testing.io);
    defer s.deinit();
    try LlmDeps.on_set_preset(s, null, "deepseek", null);
    try std.testing.expectEqualStrings("https://api.deepseek.com/v1", s.deps.cfg.base_url);
    try std.testing.expectEqualStrings("deepseek-chat", s.deps.cfg.model);
    try LlmDeps.on_cfg_tools_json(s, null, tools.example_tools_json, null);
    try std.testing.expect(s.deps.tool_defs.len >= 3);
    // bad json keeps old defs
    const before = s.deps.tool_defs.len;
    try LlmDeps.on_cfg_tools_json(s, null, "not json", null);
    try std.testing.expectEqual(before, s.deps.tool_defs.len);
}

test "smoke: conversation management" {
    const gpa = std.testing.allocator;
    const s = Session.create(gpa, std.testing.io);
    defer s.deinit();
    try LlmDeps.on_new_chat(s, null, null, null);
    try std.testing.expectEqual(@as(usize, 2), s.deps.convs.items.len);
    try std.testing.expectEqual(@as(usize, 1), s.deps.active);
    try LlmDeps.on_select_chat(s, "0", null, null);
    try std.testing.expectEqual(@as(usize, 0), s.deps.active);
    try std.testing.expectError(error.LastChat, blk: {
        // delete down to one
        try LlmDeps.on_delete_chat(s, "1", null, null);
        break :blk LlmDeps.on_delete_chat(s, "0", null, null);
    });
}

test "smoke: inspector ring bounds" {
    const gpa = std.testing.allocator;
    const s = Session.create(gpa, std.testing.io);
    defer s.deinit();
    var i: usize = 0;
    while (i < inspector_cap + 20) : (i += 1) {
        note(s, "sys", "x");
    }
    try std.testing.expectEqual(@as(usize, inspector_cap), s.deps.inspector.items.len);
}

test "smoke: doSend appends user msg and queues while streaming" {
    const gpa = std.testing.allocator;
    const s = Session.create(gpa, std.testing.io);
    defer s.deinit();
    // fake config so doSend passes validation
    state.setStr(gpa, &s.deps.cfg.base_url, "http://localhost:1");
    state.setStr(gpa, &s.deps.cfg.model, "m");
    // fake an active mailbox so send queues instead of spawning
    const mb = state.Mailbox.create(gpa, s.io, .{}, null);
    s.deps.mailbox = mb;
    try doSend(s, "hello");
    try std.testing.expectEqual(@as(usize, 1), s.deps.send_queue.items.len);
    try std.testing.expectEqual(@as(usize, 1), curConv(s).msgs.items.len);
    // cleanup: simulate worker exit + session close (two refs).
    mb.workerDone();
    mb.close();
    s.deps.mailbox = null;
}

test "toolsPayload merges user defs and mcp tools" {
    const gpa = std.testing.allocator;
    const s = Session.create(gpa, std.testing.io);
    defer s.deinit();
    s.deps.cfg.tool_mode = .auto;
    // mcp discovery result shape
    s.deps.mcp_tools.append(gpa, .{
        .server = state.dupe(gpa, "mock"),
        .tools_json = state.dupe(gpa, "[{\"type\":\"function\",\"function\":{\"name\":\"mcp__mock__echo_mcp\"}}]"),
    }) catch @panic("OOM");
    const tp = toolsPayload(s);
    defer if (tp.len != 0) gpa.free(tp);
    try std.testing.expect(std.mem.indexOf(u8, tp, "mcp__mock__echo_mcp") != null);
    try std.testing.expect(std.mem.startsWith(u8, tp, "["));
    try std.testing.expect(std.mem.endsWith(u8, tp, "]"));
}
