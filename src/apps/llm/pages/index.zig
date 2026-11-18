//! "/" — the zllm console: chat sidebar + transcript + composer on
//! the left/center, endpoint+tools config rail on the right, and a
//! raw inspector strip at the bottom. Everything re-renders through
//! the normal forest diff on each mailbox drain (`Deps.syncPull` →
//! ping → bumpSeq → render).
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
            field(a, "System prompt", h.textarea(a)
                .attr("rows", "3")
                .value(s.deps.cfg.system)
                .child(s.deps.cfg.system)
                .on(.change, act.cfg_system).node()),
            h.div(a).class("grid2").children(.{
                field(a, "Temperature", h.input(a)
                    .type("number").attr("step", "0.1").attr("min", "0").attr("max", "2")
                    .value(f64Str(a, s.deps.cfg.temperature))
                    .on(.change, act.cfg_temperature).node()),
                field(a, "Top-p", h.input(a)
                    .type("number").attr("step", "0.05").attr("min", "0").attr("max", "1")
                    .value(f64Str(a, s.deps.cfg.top_p))
                    .on(.change, act.cfg_top_p).node()),
                field(a, "Context window", h.input(a)
                    .type("number").attr("step", "1024")
                    .value(u32Str(a, s.deps.cfg.context_window))
                    .on(.change, act.cfg_context_window).node()),
                field(a, "Tools", h.select(a)
                    .on(.change, act.cfg_tool_mode)
                    .child(.{
                        h.option(a).value("off").attr("selected", s.deps.cfg.tool_mode == .off).child("off").node(),
                        h.option(a).value("manual").attr("selected", s.deps.cfg.tool_mode == .manual).child("manual (approve)").node(),
                        h.option(a).value("auto").attr("selected", s.deps.cfg.tool_mode == .auto).child("auto").node(),
                    }).node()),
            }).node(),
        }).node(),
        h.section(a).class("card").children(.{
            h.h2(a).child("Tools (JSON)").node(),
            h.p(a).class("hint").child("OpenAI tools array. \"exec\":\"builtin\" runs a builtin (calculator, datetime_now, echo, word_count, uuid, random_number, http_status…); otherwise mock. \"builtin\":\"name\" aliases the wire name.").node(),
            h.textarea(a)
                .class("mono tools-json")
                .attr("rows", "10")
                .value(s.deps.cfg.tools_json)
                .child(s.deps.cfg.tools_json)
                .on(.change, act.cfg_tools_json).node(),
            h.button(a).class("btn ghost").on(.click, act.load_tools_example).child("insert example").node(),
        }).node(),
    }).node();
}

fn presetValue(s: *Session) []const u8 {
    for (presets.presets) |p| {
        if (std.mem.eql(u8, p.base_url, s.deps.cfg.base_url)) return p.id;
    }
    return "custom";
}

fn presetOptions(a: std.mem.Allocator, s: *Session) forest.Node {
    const cur = presetValue(s);
    var opts: std.ArrayListUnmanaged(forest.Node) = .empty;
    for (presets.presets) |p| {
        opts.append(a, h.option(a)
            .value(p.id)
            .attr("selected", std.mem.eql(u8, p.id, cur))
            .child(p.label)
            .node()) catch @panic("OOM");
    }
    return h.fragment(a, opts.items);
}

/// Endpoint health line — last wire operation outcome so the user
/// sees at a glance whether the provider was reached.
fn endpointStatus(a: std.mem.Allocator, s: *Session) forest.Node {
    const e = s.deps.endpoint;
    return switch (e.kind) {
        .idle => h.div(a).class("ep-status ep-idle")
            .child("no endpoint test yet — pick a preset, add a key, then “models” or send")
            .node(),
        .busy => h.div(a).class("ep-status ep-busy")
            .child(h.f(a, "… {s}", .{e.text})).node(),
        .ok => h.div(a).class("ep-status ep-ok")
            .child(h.f(a, "✓ {s}", .{e.text})).node(),
        .err => h.div(a).class("ep-status ep-err")
            .child(h.f(a, "✗ {s}", .{e.text})).node(),
    };
}

/// Model picker: a <select> over the fetched /models ids once they
/// exist, a plain text input before that (custom endpoints without
/// /models still work).
fn modelControl(a: std.mem.Allocator, s: *Session) forest.Node {
    const cur = s.deps.cfg.model;
    if (s.deps.models.len == 0) {
        return h.input(a)
            .class("mono")
            .placeholder("model id")
            .value(cur)
            .on(.change, act.cfg_model).node();
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
    return h.select(a).on(.change, act.cfg_model).child(h.fragment(a, opts.items)).node();
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
    var ib: [16]u8 = undefined;
    const arg = std.fmt.bufPrint(&ib, "{d}", .{i}) catch unreachable;
    const active = s.deps.active == i;
    return h.li(a)
        .id(h.f(a, "chat-{d}", .{i}))
        .class(if (active) "chat active" else "chat")
        .children(.{
            h.button(a)
                .class("chat-pick")
                .on(.click, act.select_chat)
                .arg(arg)
                .child(c.title)
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

fn ctxBar(a: std.mem.Allocator, s: *Session) forest.Node {
    const est = estCtx(s);
    const win = s.deps.cfg.context_window;
    const pct = if (win == 0) @as(u64, 0) else @min(@as(u64, 100), est * 100 / @max(win, 1));
    return h.div(a).class("ctxbar").children(.{
        h.div(a).class("ctxbar-top").children(.{
            h.span(a).class("ctxbar-label").child("context").node(),
            h.span(a).class("ctxbar-num").child(h.f(a, "~{d} est / {d} window ({d}%)", .{ est, win, pct })).node(),
        }).node(),
        h.div(a).class("ctxbar-track").children(.{
            h.div(a).class("ctxbar-fill").attr("style", h.f(a, "width:{d}%", .{pct})).node(),
        }).node(),
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

fn msgRow(a: std.mem.Allocator, m: *state.Msg) forest.Node {
    const role = roleLabel(m);
    var kids: std.ArrayListUnmanaged(forest.Node) = .empty;
    const g = a;

    kids.append(g, h.div(a).class("msg-head").children(.{
        h.span(a).class(h.f(a, "role role-{s}", .{@tagName(m.role)})).child(role).node(),
        if (m.status != .ok)
            h.span(a).class(h.f(a, "msg-status st-{s}", .{@tagName(m.status)})).child(statusLabel(m)).node()
        else
            h.span(a).node(),
    }).node()) catch @panic("OOM");

    if (m.reasoning.items.len != 0) {
        kids.append(g, h.details(a).class("reasoning").children(.{
            h.summary(a).child("reasoning").node(),
            h.pre(a).class("mono").child(m.reasoning.items).node(),
        }).node()) catch @panic("OOM");
    }

    if (m.text.items.len != 0 or m.status == .streaming) {
        kids.append(g, h.div(a).class("msg-text").child(m.text.items).node()) catch @panic("OOM");
    }
    if (m.status == .streaming) {
        kids.append(g, h.span(a).class("cursor").child("▍").node()) catch @panic("OOM");
    }
    if (m.status == .failed) {
        kids.append(g, h.div(a).class("msg-err").child(m.err orelse "unknown error").node()) catch @panic("OOM");
    }

    for (m.calls.items, 0..) |*c, ci| {
        kids.append(g, callCard(a, m, c, ci)) catch @panic("OOM");
    }

    if (m.role == .assistant) {
        if (m.usage) |u| {
            if (u.total != 0) {
                kids.append(g, h.div(a).class("msg-usage").child(
                    h.f(a, "tokens: {d} prompt + {d} completion = {d}", .{ u.prompt, u.completion, u.total }),
                ).node()) catch @panic("OOM");
            }
        }
    }

    return h.div(a)
        .class(h.f(a, "msg msg-{s}", .{@tagName(m.role)}))
        .id(h.f(a, "m{d}-{x}", .{ m.ord, @intFromPtr(m) }))
        .children(kids.items)
        .node();
}

fn callCard(a: std.mem.Allocator, m: *state.Msg, c: *state.ToolCall, ci: usize) forest.Node {
    var kids: std.ArrayListUnmanaged(forest.Node) = .empty;
    const g = a;

    kids.append(g, h.div(a).class("call-head").children(.{
        h.span(a).class("call-name mono").child(c.name).node(),
        h.span(a).class(h.f(a, "call-state cs-{s}", .{@tagName(c.state)})).child(callStateLabel(c)).node(),
    }).node()) catch @panic("OOM");

    if (c.args_json.items.len != 0) {
        kids.append(g, h.pre(a).class("mono call-args").child(c.args_json.items).node()) catch @panic("OOM");
    }

    if (c.state == .pending) {
        const pos = h.f(a, "{d}:{d}", .{ m.ord, ci });
        kids.append(g, h.div(a).class("call-actions").children(.{
            h.button(a).class("btn approve").on(.click, act.approve_tool).arg(pos).child("approve").node(),
            h.button(a).class("btn reject").on(.click, act.reject_tool).arg(pos).child("reject").node(),
        }).node()) catch @panic("OOM");
    }
    if (c.result) |r| {
        kids.append(g, h.pre(a).class("mono call-result").child(r).node()) catch @panic("OOM");
    }
    return h.div(a).class("tool-call").children(kids.items).node();
}

fn composer(a: std.mem.Allocator, s: *Session) forest.Node {
    const busy = s.deps.mailbox != null;
    return h.form(a)
        .class("composer")
        .on(.submit, act.send)
        .children(.{
            h.textarea(a)
                .name("message")
                .attr("rows", "2")
                .attr("autofocus", "")
                .placeholder(if (busy) "streaming… message queues until the turn ends" else "Message the model…")
                .node(),
            h.div(a).class("composer-btns").children(.{
                h.button(a).class("btn primary").type("submit").child("send").node(),
                h.button(a).class("btn danger").type("button").disabled(!busy).on(.click, act.stop).child("stop").node(),
            }).node(),
        })
        .node();
}

// ── right column: inspector ──────────────────────────────────────

fn inspCol(a: std.mem.Allocator, s: *Session) forest.Node {
    return h.div(a).class("llm-insp").children(.{
        h.h2(a).child("Inspector").node(),
        usageBox(a, s),
        h.div(a).class("insp-log").id("insp-log").children(inspRows(a, s)).node(),
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
            h.span(a).class("mono").child(h.f(a, "{d} + {d} tok", .{ prompt, completion })).node(),
        }).node(),
        h.div(a).class("usage-row").children(.{
            h.span(a).child("est. context").node(),
            h.span(a).class("mono").child(h.f(a, "~{d} tok", .{estCtx(s)})).node(),
        }).node(),
        h.div(a).class("usage-row").children(.{
            h.span(a).child("tools").node(),
            h.span(a).class("mono").child(h.f(a, "{d} def(s) · {s}", .{ s.deps.tool_defs.len, @tagName(s.deps.cfg.tool_mode) })).node(),
        }).node(),
    }).node();
}

fn inspRows(a: std.mem.Allocator, s: *Session) forest.Node {
    const items = s.deps.inspector.items;
    const start = if (items.len > 80) items.len - 80 else 0;
    var rows: std.ArrayListUnmanaged(forest.Node) = .empty;
    for (items[start..]) |e| {
        rows.append(a, h.div(a).class("insp-row").children(.{
            h.span(a).class(h.f(a, "insp-kind k-{s}", .{e.kind})).child(e.kind).node(),
            h.pre(a).class("mono insp-text").child(e.text).node(),
        }).node()) catch @panic("OOM");
    }
    return h.fragment(a, rows.items);
}
