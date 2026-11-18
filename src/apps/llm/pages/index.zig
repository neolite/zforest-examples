//! "/" — the zllm console: chat sidebar + transcript + composer on
//! the left/center, endpoint+tools config rail on the right, and a
//! raw inspector strip at the bottom. Everything re-renders through
//! the normal forest diff on each mailbox drain (`Deps.syncPull` →
//! ping → bumpSeq → render).
//!
//! Live-update contract (forest diff semantics): `.child(str)` nodes
//! are STATIC — diffNode never revisits them. Anything that changes
//! after mount must be a bound leaf: `.id`/`.lid` + `.text(v)` for
//! text content, or an attr (`.class`/`.value`/`.attr`) on a bound
//! element. Structural add/remove goes through `eachOf` keyed lists
//! or `when`/`variant` branches — plain `.nodes` children can't
//! create elements client-side.
const std = @import("std");
const forest = @import("forest");
const zmeta = @import("../zmeta.zig");
const h = zmeta.h;
const app = @import("../app.zig");
const state = @import("../state.zig");
const presets = @import("../presets.zig");
const actions = @import("../gen/actions.zig");
const act = actions.act;

const Session = app.Session;

/// Route params — static route, empty struct (required by the contract).
pub const params = struct {};

/// Per-page <head>: title + inline llm.css (same trick as zblog —
/// tiny render-blocking style, no extra request).
pub fn head(
    a: std.mem.Allocator,
    s: anytype,
    p: params,
    env: *const zmeta.Env,
) ?zmeta.HeadSpec {
    _ = s;
    _ = p;
    _ = env;
    var aw: std.Io.Writer.Allocating = .init(a);
    const w = &aw.writer;
    w.writeAll("<style>") catch @panic("OOM");
    w.writeAll(app.llm_css) catch @panic("OOM");
    w.writeAll("</style>\n") catch @panic("OOM");
    // API key lives in the browser's localStorage (never rendered into
    // HTML): on load it is written into the password field and a
    // synthetic change replays it through the normal cfg_api_key
    // action; every later change persists back. Capturing listener so
    // it works regardless of client.js delegation order.
    w.writeAll("<script>(function(){var K='zllm_api_key',I='api-key-input';" ++
        "document.addEventListener('change',function(e){" ++
        "if(e.target&&e.target.id===I){try{localStorage.setItem(K,e.target.value)}catch(x){}}},true);" ++
        "window.addEventListener('DOMContentLoaded',function(){try{var k=localStorage.getItem(K);" ++
        "if(k){var i=document.getElementById(I);if(i){i.value=k;" ++
        "i.dispatchEvent(new Event('change',{bubbles:true}));}}}catch(e){}});})();</script>\n") catch @panic("OOM");
    return .{
        .title = "zllm — LLM endpoint playground",
        .extra = aw.toOwnedSlice() catch @panic("OOM"),
        .lang = null,
    };
}

// ── small formatting helpers ─────────────────────────────────────

fn roleLabel(m: *const state.Msg) []const u8 {
    return switch (m.role) {
        .user => "you",
        .assistant => "assistant",
        .tool => "tool",
    };
}

fn statusLabel(m: *const state.Msg) []const u8 {
    return switch (m.status) {
        .ok => "done",
        .streaming => "streaming…",
        .failed => "error",
        .stopped => "stopped",
    };
}

fn callStateLabel(c: *const state.ToolCall) []const u8 {
    return switch (c.state) {
        .pending => "awaiting approval",
        .running => "running…",
        .done => "done",
        .rejected => "rejected",
        .failed => "failed",
    };
}

/// Context estimate: state.estTokens over messages + system prompt +
/// the tools_json payload itself (it rides in every request).
fn estCtx(s: *Session) u64 {
    const conv = app.curConv(s);
    return state.estTokens(conv.msgs.items, s.deps.cfg.system.len + s.deps.cfg.tools_json.len);
}

fn f64Str(a: std.mem.Allocator, v: f64) []const u8 {
    return std.fmt.allocPrint(a, "{d:.2}", .{v}) catch @panic("OOM");
}

fn u32Str(a: std.mem.Allocator, v: u32) []const u8 {
    return std.fmt.allocPrint(a, "{d}", .{v}) catch @panic("OOM");
}

// ── view ─────────────────────────────────────────────────────────

pub fn view(a: std.mem.Allocator, s: anytype, p: params, env: *const zmeta.Env) forest.Node {
    _ = p;
    _ = env;
    return h.div(a)
        .class("llm")
        .children(.{
            sideBar(a, s),
            centerCol(a, s),
            inspCol(a, s),
        })
        .node();
}

// ── left column: chats + endpoint + tools config ─────────────────

fn sideBar(a: std.mem.Allocator, s: *Session) forest.Node {
    return h.div(a).class("llm-side").children(.{
        h.section(a).class("card").children(.{
            h.h2(a).child("Chats").node(),
            h.button(a).class("btn ghost").on(.click, act.new_chat).child("+ new chat").node(),
            h.ul(a).class("chat-list").id("chat-list").child(h.eachOf(a, s.deps.convs.items, s, chatRow)).node(),
        }).node(),
        h.section(a).class("card").children(.{
            h.h2(a).child("Endpoint").node(),
            endpointStatus(a, s),
            field(a, "Preset", h.select(a)
                .on(.change, act.set_preset)
                .child(presetOptions(a, s))
                .node()),
            h.p(a).class("hint").child("preset fills base URL, model & context window — you still need an API key").node(),
            field(a, "Base URL", h.input(a)
                .id("cfg-base")
                .class("mono")
                .placeholder("https://api.openai.com/v1")
                .value(s.deps.cfg.base_url)
                .on(.change, act.cfg_base_url).node()),
            field(a, "API key", h.div(a).class("keyrow").children(.{
                h.input(a)
                    .id("api-key-input")
                    .class("mono")
                    .type("password")
                    .placeholder(if (s.deps.key_from_env) "from env (ZLLM_API_KEY)" else "sk-…")
                    .value("")
                    .on(.change, act.cfg_api_key).node(),
                h.button(a).class("btn mini").on(.click, act.fetch_models).child("models").node(),
                h.button(a).class("btn mini").on(.click, act.clear_key).child("clear").node(),
            }).node()),
            field(a, "Model", modelControl(a, s)),
            field(a, "System prompt", h.div(a).children(.{
                h.select(a)
                    .on(.change, act.set_sysprompt)
                    .child(syspromptOptions(a, s))
                    .node(),
                h.textarea(a)
                    .id("cfg-system")
                    .attr("rows", "3")
                    .value(s.deps.cfg.system)
                    .child(s.deps.cfg.system)
                    .on(.change, act.cfg_system).node(),
            }).node()),
            h.div(a).class("grid2").children(.{
                field(a, "Temperature", h.input(a)
                    .id("cfg-temp")
                    .type("number").attr("step", "0.1").attr("min", "0").attr("max", "2")
                    .value(f64Str(a, s.deps.cfg.temperature))
                    .on(.change, act.cfg_temperature).node()),
                field(a, "Top-p", h.input(a)
                    .id("cfg-topp")
                    .type("number").attr("step", "0.05").attr("min", "0").attr("max", "1")
                    .value(f64Str(a, s.deps.cfg.top_p))
                    .on(.change, act.cfg_top_p).node()),
                field(a, "Context window", h.input(a)
                    .id("cfg-ctxwin")
                    .type("number").attr("step", "1024")
                    .value(u32Str(a, s.deps.cfg.context_window))
                    .on(.change, act.cfg_context_window).node()),
                field(a, "Tools", h.select(a)
                    .on(.change, act.cfg_tool_mode)
                    .child(.{
                        h.option(a).id("tm-off").value("off").attr("selected", s.deps.cfg.tool_mode == .off).child("off").node(),
                        h.option(a).id("tm-manual").value("manual").attr("selected", s.deps.cfg.tool_mode == .manual).child("manual (approve)").node(),
                        h.option(a).id("tm-auto").value("auto").attr("selected", s.deps.cfg.tool_mode == .auto).child("auto").node(),
                    }).node()),
            }).node(),
        }).node(),
        h.section(a).class("card").children(.{
            h.h2(a).child("Tools (JSON)").node(),
            h.p(a).class("hint").child("OpenAI tools array. \"exec\":\"builtin\" runs a builtin (calculator, datetime_now, echo, word_count, uuid, random_number, http_status…); otherwise mock. \"builtin\":\"name\" aliases the wire name.").node(),
            h.textarea(a)
                .id("cfg-tools")
                .class("mono tools-json")
                .attr("rows", "10")
                .value(s.deps.cfg.tools_json)
                .child(s.deps.cfg.tools_json)
                .on(.change, act.cfg_tools_json).node(),
            h.button(a).class("btn ghost").on(.click, act.load_tools_example).child("insert example").node(),
        }).node(),
        h.section(a).class("card").children(.{
            h.h2(a).child("MCP servers").node(),
            h.p(a).class("hint").child("JSON array — HTTP: {name,url,headers?}; stdio: {name,command,args?,env?} (e.g. npx chrome-devtools-mcp). “check” runs initialize + tools/list; tools join requests as mcp__<server>__<tool>.").node(),
            h.textarea(a)
                .id("cfg-mcp")
                .class("mono")
                .attr("rows", "4")
                .value(s.deps.cfg.mcp_servers)
                .child(s.deps.cfg.mcp_servers)
                .on(.change, act.cfg_mcp_servers).node(),
            h.div(a).class("mcp-bar").children(.{
                h.button(a).class("btn ghost").on(.click, act.mcp_check).child("check connection").node(),
                mcpStatus(a, s),
            }).node(),
        }).node(),
    }).node();
}

fn presetValue(s: *Session) []const u8 {
    for (presets.presets) |p| {
        if (std.mem.eql(u8, p.base_url, s.deps.cfg.base_url)) return p.id;
    }
    return "custom";
}

/// System-prompt preset picker: matches cfg.system against the known
/// preset texts — a hand-written prompt selects "custom…".
fn syspromptValue(s: *Session) []const u8 {
    for (presets.sysprompts) |p| {
        if (std.mem.eql(u8, p.text, s.deps.cfg.system)) return p.id;
    }
    return "custom";
}

fn syspromptOptions(a: std.mem.Allocator, s: *Session) forest.Node {
    const cur = syspromptValue(s);
    var opts: std.ArrayListUnmanaged(forest.Node) = .empty;
    if (std.mem.eql(u8, cur, "custom")) {
        opts.append(a, h.option(a)
            .id("sp-custom")
            .value("custom")
            .attr("selected", true)
            .child("custom (current text)")
            .node()) catch @panic("OOM");
    }
    for (presets.sysprompts) |p| {
        opts.append(a, h.option(a)
            .id(h.f(a, "sp-{s}", .{p.id}))
            .value(p.id)
            .attr("selected", std.mem.eql(u8, p.id, cur))
            .child(p.label)
            .node()) catch @panic("OOM");
    }
    return h.fragment(a, opts.items);
}

fn presetOptions(a: std.mem.Allocator, s: *Session) forest.Node {
    const cur = presetValue(s);
    var opts: std.ArrayListUnmanaged(forest.Node) = .empty;
    for (presets.presets) |p| {
        opts.append(a, h.option(a)
            .id(h.f(a, "preset-{s}", .{p.id}))
            .value(p.id)
            .attr("selected", std.mem.eql(u8, p.id, cur))
            .child(p.label)
            .node()) catch @panic("OOM");
    }
    return h.fragment(a, opts.items);
}

/// Endpoint health line — last wire operation outcome so the user
/// sees at a glance whether the provider was reached. One bound
/// element: class + text both diff live.
fn endpointStatus(a: std.mem.Allocator, s: *Session) forest.Node {
    const e = s.deps.endpoint;
    const kind: []const u8 = switch (e.kind) {
        .idle => "idle",
        .busy => "busy",
        .ok => "ok",
        .err => "err",
    };
    const text: []const u8 = switch (e.kind) {
        .idle => "no endpoint test yet — pick a preset, add a key, then “models” or send",
        .busy => h.f(a, "… {s}", .{e.text}),
        .ok => h.f(a, "✓ {s}", .{e.text}),
        .err => h.f(a, "✗ {s}", .{e.text}),
    };
    return h.div(a)
        .id("ep-status")
        .class(h.f(a, "ep-status ep-{s}", .{kind}))
        .text(text)
        .node();
}

/// MCP health line — mirrors endpointStatus for the MCP card.
fn mcpStatus(a: std.mem.Allocator, s: *Session) forest.Node {
    const e = s.deps.mcp_status;
    const kind: []const u8 = switch (e.kind) {
        .idle => "idle",
        .busy => "busy",
        .ok => "ok",
        .err => "err",
    };
    const text: []const u8 = switch (e.kind) {
        .idle => "not checked yet",
        .busy => h.f(a, "… {s}", .{e.text}),
        .ok => h.f(a, "✓ {s}", .{e.text}),
        .err => h.f(a, "✗ {s}", .{e.text}),
    };
    const ntools = mcpToolCount(s);
    const tools_note: []const u8 = if (ntools != 0)
        h.f(a, " · {d} mcp tool(s) loaded", .{ntools})
    else
        "";
    return h.div(a)
        .id("mcp-status")
        .class(h.f(a, "ep-status ep-{s}", .{kind}))
        .text(h.f(a, "{s}{s}", .{ text, tools_note }))
        .node();
}

fn mcpToolCount(s: *Session) usize {
    var n: usize = 0;
    for (s.deps.mcp_tools.items) |mt| {
        // tools_json is "[…]" — count top-level objects cheaply by
        // counting '"name"' keys at function level is fragile; the
        // array was built by us so count occurrences of
        // `"type":"function"`.
        // splitSequence yields k+1 segments for k occurrences — the
        // first is the preamble, so skip it before counting.
        var it = std.mem.splitSequence(u8, mt.tools_json, "\"type\":\"function\"");
        _ = it.next();
        while (it.next()) |_| n += 1;
    }
    return n;
}

/// Model picker: `variant` swaps between a text input (no /models
/// yet) and a <select> over fetched ids. The select branch key carries
/// the model list shape + current model, so any change re-ships the
/// whole branch markup with correct `selected` attrs — option-level
/// diffs can't reach inside a swapped branch anyway.
fn modelControl(a: std.mem.Allocator, s: *Session) forest.Node {
    const cur = s.deps.cfg.model;
    if (s.deps.models.len == 0) {
        return forest.variant(a, .{ .id = "model-ctl" }, "input", h.input(a)
            .id("cfg-model-in")
            .class("mono")
            .placeholder("model id")
            .value(cur)
            .on(.change, act.cfg_model).node());
    }
    const g = a;
    var opts: std.ArrayListUnmanaged(forest.Node) = .empty;
    var listed = false;
    if (cur.len != 0) {
        for (s.deps.models) |id| {
            if (std.mem.eql(u8, id, cur)) {
                listed = true;
                break;
            }
        }
    }
    if (cur.len == 0) {
        opts.append(g, h.option(a).value("").attr("selected", true).child("— pick a model —").node()) catch @panic("OOM");
    } else if (!listed) {
        opts.append(g, h.option(a).value(cur).attr("selected", true).child(h.f(a, "{s} (current)", .{cur})).node()) catch @panic("OOM");
    }
    for (s.deps.models) |id| {
        opts.append(g, h.option(a)
            .value(id)
            .attr("selected", std.mem.eql(u8, id, cur))
            .child(id)
            .node()) catch @panic("OOM");
    }
    const n = s.deps.models.len;
    const first = s.deps.models[0];
    const last = s.deps.models[n - 1];
    const key = h.f(a, "sel:{d}:{s}:{s}:{s}", .{ n, first, last, cur });
    return forest.variant(a, .{ .id = "model-ctl" }, key, h.select(a).on(.change, act.cfg_model).child(h.fragment(a, opts.items)).node());
}

fn field(a: std.mem.Allocator, label: []const u8, control: forest.Node) forest.Node {
    return h.label(a).class("fld").children(.{
        h.span(a).class("fld-label").child(label).node(),
        control,
    }).node();
}

fn chatRow(a: std.mem.Allocator, s: *Session, c: *state.Conversation) ?forest.Node {
    var i: usize = 0;
    while (i < s.deps.convs.items.len) : (i += 1) {
        if (s.deps.convs.items[i] == c) break;
    }
    // h.f arena-allocates — a stack bufPrint slice would dangle once
    // chatRow returns (forest stores the borrowed pointer).
    const arg = h.f(a, "{d}", .{i});
    const active = s.deps.active == i;
    return h.li(a)
        .id(h.f(a, "chat-{d}", .{i}))
        .class(if (active) "chat active" else "chat")
        .children(.{
            h.button(a)
                .lid("pick")
                .class("chat-pick")
                .on(.click, act.select_chat)
                .arg(arg)
                .text(c.title)
                .node(),
            h.button(a)
                .class("chat-del")
                .on(.click, act.delete_chat)
                .arg(arg)
                .child("×")
                .node(),
        })
        .node();
}

// ── center column: context meter + transcript + composer ─────────

fn centerCol(a: std.mem.Allocator, s: *Session) forest.Node {
    return h.div(a).class("llm-center").children(.{
        ctxBar(a, s),
        transcript(a, s),
        composer(a, s),
    }).node();
}

/// Context meter: stacked SVG segments (one per source — system,
/// tools, user/assistant/tool messages). `style` isn't in client.js's
/// attr whitelist, so widths ride on SVG `x`/`width` attrs — integer
/// permille of a 1000-wide viewBox. Denominator is min(total, window):
/// under the window the stack fills the bar showing composition; over
/// it the stack overflows past 1000 and clips at full.
fn ctxBar(a: std.mem.Allocator, s: *Session) forest.Node {
    const conv = app.curConv(s);
    const parts = state.estTokensParts(conv.msgs.items, s.deps.cfg.system.len, s.deps.cfg.tools_json.len);
    const total = parts.total();
    const win = s.deps.cfg.context_window;
    const den = @min(total, @as(u64, win));
    const pct = if (win == 0) @as(u64, 0) else @min(@as(u64, 100), total * 100 / @max(win, 1));

    const Seg = struct { name: []const u8, label: []const u8, n: u64 };
    const segs = [_]Seg{
        .{ .name = "sys", .label = "system", .n = parts.system },
        .{ .name = "tools", .label = "tools", .n = parts.tools },
        .{ .name = "user", .label = "you", .n = parts.user },
        .{ .name = "ai", .label = "assistant", .n = parts.assistant },
        .{ .name = "tool", .label = "tool", .n = parts.tool },
    };

    var rects: std.ArrayListUnmanaged(forest.Node) = .empty;
    var legend: std.ArrayListUnmanaged(forest.Node) = .empty;
    var x: u64 = 0;
    for (segs) |sg| {
        const w = if (den == 0) @as(u64, 0) else sg.n * 1000 / den;
        const x0 = x;
        x += w;
        rects.append(a, h.rect(a)
            .id(h.f(a, "ctx-seg-{s}", .{sg.name}))
            .class(h.f(a, "ctx-seg ctx-{s}", .{sg.name}))
            .attr("x", h.f(a, "{d}", .{x0}))
            .attr("width", h.f(a, "{d}", .{w}))
            .attr("height", "10")
            .attr("y", "0")
            .attr("title", h.f(a, "{s}: ~{d} est tok", .{ sg.label, sg.n }))
            .node()) catch @panic("OOM");
        legend.append(a, h.span(a).class("ctx-lg").children(.{
            h.span(a).class(h.f(a, "ctx-dot ctx-{s}", .{sg.name})).node(),
            h.span(a)
                .id(h.f(a, "ctx-lg-{s}", .{sg.name}))
                .text(h.f(a, "{s} {d}", .{ sg.label, sg.n }))
                .node(),
        }).node()) catch @panic("OOM");
    }

    return h.div(a).class("ctxbar").children(.{
        h.div(a).class("ctxbar-top").children(.{
            h.span(a).class("ctxbar-label").child("context").node(),
            h.span(a)
                .id("ctxbar-num")
                .class("ctxbar-num")
                .text(h.f(a, "~{d} est / {d} window ({d}%)", .{ total, win, pct }))
                .node(),
        }).node(),
        h.svg(a)
            .class("ctxbar-svg")
            .attr("viewBox", "0 0 1000 10")
            .attr("preserveAspectRatio", "none")
            .children(rects.items)
            .node(),
        h.div(a).class("ctx-legend").children(legend.items).node(),
    }).node();
}

fn transcript(a: std.mem.Allocator, s: *Session) forest.Node {
    const conv = app.curConv(s);
    return h.div(a).class("transcript").id("transcript").children(.{
        h.eachOf(a, conv.msgs.items, s, msgRowOrNull),
    }).node();
}

fn msgRowOrNull(a: std.mem.Allocator, s: *Session, m: *state.Msg) ?forest.Node {
    _ = s;
    return msgRow(a, m);
}

/// Per-call index counter for the keyed `calls` list — eachOf hands
/// the render fn no index, so ctx carries a mutable cursor.
const CallIdx = struct {
    ord: usize,
    i: usize = 0,
};

fn msgRow(a: std.mem.Allocator, m: *state.Msg) forest.Node {
    const role = roleLabel(m);
    const g = a;

    var kids: std.ArrayListUnmanaged(forest.Node) = .empty;

    // Head: role label is fixed per message (static); the status chip
    // changes streaming → ok/failed → bound class + text, always mounted.
    kids.append(g, h.div(a).class("msg-head").children(.{
        h.span(a).class(h.f(a, "role role-{s}", .{@tagName(m.role)})).child(role).node(),
        h.span(a)
            .lid("status")
            .class(h.f(a, "msg-status st-{s}", .{@tagName(m.status)}))
            .text(if (m.status == .ok) "" else statusLabel(m))
            .node(),
    }).node()) catch @panic("OOM");

    // Reasoning streams into <details> — `when` mounts the branch on
    // first delta and the bound <pre> keeps diffing its text after.
    // Emitted unconditionally so the anchor markers stay stable.
    kids.append(g, forest.when(a, .{ .lid = "reasoning" }, m.reasoning.items.len != 0, h.details(a).class("reasoning").children(.{
        h.summary(a).child("reasoning").node(),
        h.pre(a)
            .class("mono")
            .lid("rtext")
            .text(@as([]const u8, m.reasoning.items))
            .node(),
    }).node())) catch @panic("OOM");

    // Body text: always mounted, bound — grows token by token.
    kids.append(g, h.div(a)
        .lid("text")
        .class(if (m.text.items.len == 0 and m.status != .streaming) "msg-text hidden" else "msg-text")
        .text(@as([]const u8, m.text.items))
        .node()) catch @panic("OOM");

    // Streaming caret — bound text, empty when idle.
    kids.append(g, h.span(a)
        .lid("cursor")
        .class("cursor")
        .text(if (m.status == .streaming) "▍" else "")
        .node()) catch @panic("OOM");

    // Error line — hidden unless failed.
    kids.append(g, h.div(a)
        .lid("err")
        .class(if (m.status == .failed) "msg-err" else "msg-err hidden")
        .text(m.err orelse "")
        .node()) catch @panic("OOM");

    // Tool calls: keyed list inside a bound wrapper — call rows are
    // created/removed by the keyed diff, their leaves diff in place.
    var cidx = CallIdx{ .ord = m.ord };
    kids.append(g, h.div(a)
        .lid("calls")
        .class("calls")
        .child(h.eachOf(a, m.calls.items, &cidx, callRow))
        .node()) catch @panic("OOM");

    // Token usage line — hidden until the provider reports usage.
    const usage_str: []const u8 = if (m.usage) |u| blk: {
        if (u.total == 0) break :blk "";
        break :blk h.f(a, "tokens: {d} prompt + {d} completion = {d}", .{ u.prompt, u.completion, u.total });
    } else "";
    kids.append(g, h.div(a)
        .lid("usage")
        .class(if (usage_str.len == 0) "msg-usage hidden" else "msg-usage")
        .text(usage_str)
        .node()) catch @panic("OOM");

    return h.div(a)
        .class(h.f(a, "msg msg-{s}", .{@tagName(m.role)}))
        .id(h.f(a, "m{d}-{x}", .{ m.ord, @intFromPtr(m) }))
        .children(kids.items)
        .node();
}

fn callRow(a: std.mem.Allocator, ctx: *CallIdx, c: state.ToolCall) ?forest.Node {
    const i = ctx.i;
    ctx.i += 1;
    const pos = h.f(a, "{d}:{d}", .{ ctx.ord, i });
    const pending = c.state == .pending;
    const has_args = c.args_json.items.len != 0;
    const has_result = c.result != null and c.result.?.len != 0;
    return h.div(a)
        .class("tool-call")
        .id(h.f(a, "call-{d}-{d}", .{ ctx.ord, i }))
        .children(.{
            h.div(a).class("call-head").children(.{
                h.span(a)
                    .lid("name")
                    .class("call-name mono")
                    .text(@as([]const u8, c.name))
                    .node(),
                h.span(a)
                    .lid("state")
                    .class(h.f(a, "call-state cs-{s}", .{@tagName(c.state)}))
                    .text(callStateLabel(&c))
                    .node(),
            }).node(),
            h.pre(a)
                .lid("args")
                .class(if (has_args) "mono call-args" else "mono call-args hidden")
                .text(@as([]const u8, c.args_json.items))
                .node(),
            h.div(a)
                .lid("actions")
                .class(if (pending) "call-actions" else "call-actions hidden")
                .children(.{
                    h.button(a).class("btn approve").on(.click, act.approve_tool).arg(pos).child("approve").node(),
                    h.button(a).class("btn reject").on(.click, act.reject_tool).arg(pos).child("reject").node(),
                }).node(),
            h.pre(a)
                .lid("result")
                .class(if (has_result) "mono call-result" else "mono call-result hidden")
                .text(c.result orelse "")
                .node(),
        })
        .node();
}

fn composer(a: std.mem.Allocator, s: *Session) forest.Node {
    const busy = s.deps.mailbox != null;
    return h.form(a)
        .class("composer")
        .on(.submit, act.send)
        .children(.{
            h.textarea(a)
                .id("composer-msg")
                .name("message")
                .attr("rows", "2")
                .attr("autofocus", "")
                .attr("placeholder", if (busy) "streaming… message queues until the turn ends" else "Message the model…")
                .node(),
            h.div(a).class("composer-btns").children(.{
                h.button(a).class("btn primary").type("submit").child("send").node(),
                h.button(a)
                    .id("composer-stop")
                    .class("btn danger")
                    .type("button")
                    .disabled(!busy)
                    .on(.click, act.stop)
                    .child("stop")
                    .node(),
            }).node(),
        })
        .node();
}

// ── right column: inspector ──────────────────────────────────────

fn inspCol(a: std.mem.Allocator, s: *Session) forest.Node {
    return h.div(a).class("llm-insp").children(.{
        h.h2(a).child("Inspector").node(),
        usageBox(a, s),
        h.div(a).class("insp-log").id("insp-log").children(.{
            inspRows(a, s),
        }).node(),
    }).node();
}

fn usageBox(a: std.mem.Allocator, s: *Session) forest.Node {
    const conv = app.curConv(s);
    var prompt: u64 = 0;
    var completion: u64 = 0;
    for (conv.msgs.items) |m| {
        if (m.usage) |u| {
            if (u.total != 0) {
                prompt = u.prompt;
                completion = u.completion;
            }
        }
    }
    return h.div(a).class("usage").children(.{
        h.div(a).class("usage-row").children(.{
            h.span(a).child("last reply").node(),
            h.span(a)
                .id("usage-tok")
                .class("mono")
                .text(h.f(a, "{d} + {d} tok", .{ prompt, completion }))
                .node(),
        }).node(),
        h.div(a).class("usage-row").children(.{
            h.span(a).child("est. context").node(),
            h.span(a)
                .id("usage-ctx")
                .class("mono")
                .text(h.f(a, "~{d} tok", .{estCtx(s)}))
                .node(),
        }).node(),
        h.div(a).class("usage-row").children(.{
            h.span(a).child("tools").node(),
            h.span(a)
                .id("usage-tools")
                .class("mono")
                .text(h.f(a, "{d} def(s) · {s}", .{ s.deps.tool_defs.len, @tagName(s.deps.cfg.tool_mode) }))
                .node(),
        }).node(),
    }).node();
}

/// Keyed inspector rows — `seq` on each entry gives a stable id, so
/// appends create one row and ring-cap eviction removes the oldest.
/// Rows are immutable once appended → plain static children; the
/// `<details>` wrapper gives collapse-for-free (DOM holds open state,
/// no patches involved). SSE chunks arrive one-per-delta and flood the
/// log, so they mount collapsed; req/err/sys/tool stay expanded.
fn inspRows(a: std.mem.Allocator, s: *Session) forest.Children {
    const items = s.deps.inspector.items;
    // Per-chat inspector: entries tagged with a conversation show only
    // under that chat; chat == 0 entries are global (config, presets,
    // models, mcp checks) and visible everywhere.
    const cur = @intFromPtr(app.curConv(s));
    var filt: std.ArrayListUnmanaged(app.InspectorEntry) = .empty;
    for (items) |e| {
        if (e.chat == 0 or e.chat == cur) filt.append(a, e) catch @panic("OOM");
    }
    const start = if (filt.items.len > 80) filt.items.len - 80 else 0;
    return h.eachOf(a, filt.items[start..], s, inspRow);
}

fn inspRow(a: std.mem.Allocator, s: *Session, e: app.InspectorEntry) ?forest.Node {
    _ = s;
    const line = std.mem.sliceTo(e.text, '\n');
    const preview = line[0..@min(line.len, 90)];
    return h.details(a)
        .class("insp-row")
        .id(h.f(a, "insp-{d}", .{e.seq}))
        .attr("open", !std.mem.eql(u8, e.kind, "sse"))
        .children(.{
            h.summary(a).class("insp-sum").children(.{
                h.span(a)
                    .class(h.f(a, "insp-kind k-{s}", .{e.kind}))
                    .child(e.kind)
                    .node(),
                h.span(a).class("insp-prev mono").child(preview).node(),
            }).node(),
            h.pre(a).class("mono insp-text").child(e.text).node(),
        })
        .node();
}
