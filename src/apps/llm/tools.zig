//! tools — zllm tool layer: builtin safe executors, user tool-def
//! validation, and translation of `tools_json` into the OpenAI
//! `tools` array spliced into chat requests.
//!
//! Safety contract: builtin execs are pure functions over their JSON
//! args — NO arbitrary code evaluation, NO network, NO filesystem.
//! `calculator` parses a tiny arithmetic grammar itself (never
//! eval()). User `exec:"mock"` tools return a canned `result`
//! template (`{args}` → raw arguments JSON).
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const state = @import("state.zig");

// ── builtin catalog ──────────────────────────────────────────────

/// One builtin tool: OpenAI `function` object JSON (name/description/
/// parameters) + the exec dispatch key. Users enable them by name in
/// tools_json with `"exec":"builtin"`.
pub const Builtin = struct {
    name: []const u8,
    description: []const u8,
    /// JSON schema for `parameters`.
    parameters_json: []const u8,
};

pub const builtins = [_]Builtin{
    .{
        .name = "calculator",
        .description = "Evaluate an arithmetic expression (+ - * / % ^ parentheses, decimals). Returns a number.",
        .parameters_json =
        \\{"type":"object","properties":{"expr":{"type":"string","description":"Arithmetic expression, e.g. \"2*(3+4)\""}},"required":["expr"]}
        ,
    },
    .{
        .name = "datetime_now",
        .description = "Current UTC date/time (ISO-8601) and unix timestamp.",
        .parameters_json =
        \\{"type":"object","properties":{}}
        ,
    },
    .{
        .name = "echo",
        .description = "Echo the input text back unchanged.",
        .parameters_json =
        \\{"type":"object","properties":{"text":{"type":"string"}},"required":["text"]}
        ,
    },
    .{
        .name = "word_count",
        .description = "Count words/characters/bytes of a text.",
        .parameters_json =
        \\{"type":"object","properties":{"text":{"type":"string"}},"required":["text"]}
        ,
    },
    .{
        .name = "uuid4",
        .description = "Generate a random UUIDv4.",
        .parameters_json =
        \\{"type":"object","properties":{}}
        ,
    },
    .{
        .name = "http_status",
        .description = "Mock HTTP status lookup — returns a canned status line for a code (educational placeholder, no real network).",
        .parameters_json =
        \\{"type":"object","properties":{"code":{"type":"integer"}},"required":["code"]}
        ,
    },
    .{
        .name = "bash",
        .description = "Run a shell command via sh -c; stdout+stderr merged (64KB cap). UNSANDBOXED local execution — runs synchronously, keep commands short; timeout_ms optional (default 20000, max 120000).",
        .parameters_json =
        \\{"type":"object","properties":{"command":{"type":"string","description":"Shell command line"},"timeout_ms":{"type":"integer","description":"Max run time in ms"}},"required":["command"]}
        ,
    },
    // ── code-mode tools (auto-attached when agent_mode == .code) ──
    .{
        .name = "read_file",
        .description = "Read a text file from the workspace. Returns numbered lines; use start_line/max_lines for large files.",
        .parameters_json =
        \\{"type":"object","properties":{"path":{"type":"string","description":"Path relative to workspace root"},"start_line":{"type":"integer","description":"1-based first line, default 1"},"max_lines":{"type":"integer","description":"Max lines, default 400"}},"required":["path"]}
        ,
    },
    .{
        .name = "write_file",
        .description = "Write a whole file (creates parent dirs). Overwrites existing content — use edit_file for surgical changes.",
        .parameters_json =
        \\{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"]}
        ,
    },
    .{
        .name = "edit_file",
        .description = "Replace an exact string in a file. old_string must match uniquely unless replace_all is true.",
        .parameters_json =
        \\{"type":"object","properties":{"path":{"type":"string"},"old_string":{"type":"string"},"new_string":{"type":"string"},"replace_all":{"type":"boolean"}},"required":["path","old_string","new_string"]}
        ,
    },
    .{
        .name = "list_dir",
        .description = "List directory entries (dirs marked with /). Defaults to workspace root.",
        .parameters_json =
        \\{"type":"object","properties":{"path":{"type":"string","description":"Subdir relative to workspace, default root"}}}
        ,
    },
    .{
        .name = "grep_files",
        .description = "Recursive substring search over text files. Returns path:line: text matches (max 100). Skips binary and >512KB files.",
        .parameters_json =
        \\{"type":"object","properties":{"pattern":{"type":"string"},"path":{"type":"string","description":"Subdir to search, default workspace root"},"ignore_case":{"type":"boolean"}},"required":["pattern"]}
        ,
    },
    // ── background process tools (session-backed, code mode) ──
    .{
        .name = "proc_start",
        .description = "Start a BACKGROUND shell command (sh -c) in the workspace. Returns a proc id — read output with proc_output, stop with proc_kill. Use for dev servers, watchers, long test runs.",
        .parameters_json =
        \\{"type":"object","properties":{"command":{"type":"string"}},"required":["command"]}
        ,
    },
    .{
        .name = "proc_output",
        .description = "Read NEW output (merged stdout+stderr) from a background process plus its status.",
        .parameters_json =
        \\{"type":"object","properties":{"id":{"type":"integer","description":"Proc id from proc_start"}},"required":["id"]}
        ,
    },
    .{
        .name = "proc_list",
        .description = "List background processes with status and command line.",
        .parameters_json =
        \\{"type":"object","properties":{}}
        ,
    },
    .{
        .name = "proc_kill",
        .description = "Kill a background process by id.",
        .parameters_json =
        \\{"type":"object","properties":{"id":{"type":"integer"}},"required":["id"]}
        ,
    },
};

/// Builtin names auto-attached to requests in code mode (agent_mode
/// == .code). Order = payload order.
pub const code_tool_names = [_][]const u8{
    "bash",       "read_file",   "write_file", "edit_file", "list_dir", "grep_files",
    "proc_start", "proc_output", "proc_list",  "proc_kill",
};

/// True when `name` is a session-backed proc_* tool — app.zig routes
/// these to the process table instead of tools.exec.
pub fn isProcTool(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "proc_");
}

/// True when `name` exists in the builtin catalog.
pub fn builtinExists(name: []const u8) bool {
    for (builtins) |b| {
        if (std.mem.eql(u8, b.name, name)) return true;
    }
    return false;
}

pub fn builtinDef(gpa: std.mem.Allocator, name: []const u8) ?[]const u8 {
    for (builtins) |b| {
        if (std.mem.eql(u8, b.name, name)) {
            var aw: std.Io.Writer.Allocating = .init(gpa);
            const w = &aw.writer;
            w.writeAll("{\"type\":\"function\",\"function\":{\"name\":") catch @panic("OOM");
            state.jsonStrPub(w, b.name) catch @panic("OOM");
            w.writeAll(",\"description\":") catch @panic("OOM");
            state.jsonStrPub(w, b.description) catch @panic("OOM");
            w.writeAll(",\"parameters\":") catch @panic("OOM");
            w.writeAll(b.parameters_json) catch @panic("OOM");
            w.writeAll("}}") catch @panic("OOM");
            return aw.toOwnedSlice() catch @panic("OOM");
        }
    }
    return null;
}

// ── user tool defs ───────────────────────────────────────────────

pub const ExecKind = enum { builtin, mock };

/// One user-declared tool, parsed from `tools_json`.
pub const ToolDef = struct {
    name: []const u8,
    description: []const u8 = "",
    /// Re-serialized parameters schema JSON ("" → emit default object).
    parameters_json: []const u8 = "",
    exec: ExecKind = .mock,
    /// `"builtin":"other_name"` — route exec to a differently-named
    /// builtin while the wire name stays `name`.
    builtin_name: ?[]const u8 = null,
    /// mock: result template, `{args}` → raw arguments JSON.
    result_template: []const u8 = "",
};

/// Example tools_json shipped behind the "insert example" button.
pub const example_tools_json =
    \\[
    \\  {"name":"calculator","description":"Evaluate arithmetic expressions","parameters":{"type":"object","properties":{"expr":{"type":"string"}},"required":["expr"]},"exec":"builtin"},
    \\  {"name":"get_time","description":"Current UTC time","parameters":{"type":"object","properties":{}},"exec":"builtin","builtin":"datetime_now"},
    \\  {"name":"echo","description":"Echo text back","parameters":{"type":"object","properties":{"text":{"type":"string"}},"required":["text"]},"exec":"builtin"},
    \\  {"name":"get_weather","description":"Mock weather for a city","parameters":{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]},"exec":"mock","result":"{\"city\":\"{args}\",\"temp_c\":21,\"sky\":\"clear\"}"}
    \\]
;

/// Validate + parse tools_json into ToolDefs. Every string is duped
/// into `gpa`; caller frees via `freeDefs`. Returns error on malformed
/// JSON or missing/invalid fields.
pub fn parseDefs(gpa: std.mem.Allocator, json: []const u8) ![]ToolDef {
    if (std.mem.trim(u8, json, " \t\r\n").len == 0) return &.{};
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, json, .{}) catch return error.BadJson;
    defer parsed.deinit();
    const arr = switch (parsed.value) {
        .array => |a| a,
        else => return error.NotArray,
    };
    if (arr.items.len > 32) return error.TooMany;
    const defs = try gpa.alloc(ToolDef, arr.items.len);
    var n: usize = 0;
    errdefer {
        for (defs[0..n]) |d| freeDef(gpa, d);
        gpa.free(defs);
    }
    for (arr.items) |item| {
        defs[n] = try parseDef(gpa, item);
        n += 1;
    }
    return defs[0..n];
}

fn parseDef(gpa: std.mem.Allocator, v: std.json.Value) !ToolDef {
    const obj = switch (v) {
        .object => |o| o,
        else => return error.BadDef,
    };
    const name_v = obj.get("name") orelse return error.BadDef;
    const name = switch (name_v) {
        .string => |s| s,
        else => return error.BadDef,
    };
    if (name.len == 0 or name.len > 64) return error.BadDef;
    for (name) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-')) return error.BadDef;
    }
    var d: ToolDef = .{ .name = state.dupe(gpa, name) };
    errdefer freeDef(gpa, d);

    if (obj.get("description")) |dv| {
        d.description = switch (dv) {
            .string => |s| state.dupe(gpa, s),
            else => return error.BadDef,
        };
    }
    if (obj.get("parameters")) |pv| {
        switch (pv) {
            .object => {},
            else => return error.BadDef,
        }
        var sw: std.Io.Writer.Allocating = .init(gpa);
        defer sw.deinit();
        std.json.Stringify.value(pv, .{}, &sw.writer) catch return error.BadDef;
        d.parameters_json = sw.toOwnedSlice() catch return error.BadDef;
    }
    if (obj.get("exec")) |ev| {
        d.exec = switch (ev) {
            .string => |s| if (std.mem.eql(u8, s, "builtin")) .builtin else .mock,
            else => return error.BadDef,
        };
    }
    if (obj.get("builtin")) |bv| {
        d.builtin_name = switch (bv) {
            .string => |s| state.dupe(gpa, s),
            else => return error.BadDef,
        };
    }
    if (obj.get("result")) |rv| {
        d.result_template = switch (rv) {
            .string => |s| state.dupe(gpa, s),
            else => return error.BadDef,
        };
    }
    return d;
}

pub fn freeDef(gpa: std.mem.Allocator, d: ToolDef) void {
    state.freeStr(gpa, d.name);
    state.freeStr(gpa, d.description);
    state.freeStr(gpa, d.parameters_json);
    if (d.builtin_name) |s| gpa.free(s);
    state.freeStr(gpa, d.result_template);
}

pub fn freeDefs(gpa: std.mem.Allocator, defs: []ToolDef) void {
    for (defs) |d| freeDef(gpa, d);
    gpa.free(defs);
}

/// Serialize defs into the OpenAI `tools` array JSON. `builtin:` defs
/// (from tools.builtinDefsJSON) are pre-serialized function objects —
/// this fn only handles user ToolDefs.
pub fn defsToToolsJson(gpa: std.mem.Allocator, defs: []const ToolDef) []const u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    const w = &aw.writer;
    w.writeByte('[') catch @panic("OOM");
    for (defs, 0..) |d, i| {
        if (i != 0) w.writeByte(',') catch @panic("OOM");
        w.writeAll("{\"type\":\"function\",\"function\":{\"name\":") catch @panic("OOM");
        state.jsonStrPub(w, d.name) catch @panic("OOM");
        if (d.description.len != 0) {
            w.writeAll(",\"description\":") catch @panic("OOM");
            state.jsonStrPub(w, d.description) catch @panic("OOM");
        }
        w.writeAll(",\"parameters\":") catch @panic("OOM");
        if (d.parameters_json.len != 0) {
            w.writeAll(d.parameters_json) catch @panic("OOM");
        } else {
            w.writeAll("{\"type\":\"object\",\"properties\":{}}") catch @panic("OOM");
        }
        w.writeAll("}}") catch @panic("OOM");
    }
    w.writeByte(']') catch @panic("OOM");
    return aw.toOwnedSlice() catch @panic("OOM");
}

// ── execution ────────────────────────────────────────────────────

/// Extract a string field from a parsed args object (null when
/// absent/non-string). Slices stay valid while the caller's
/// `Parsed(Value)` lives — execBuiltin parses args_json ONCE and
/// keeps it alive for the whole dispatch.
pub fn argStr(obj: ?std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const o = obj orelse return null;
    const v = o.get(name) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

pub fn argF64(obj: ?std.json.ObjectMap, name: []const u8) ?f64 {
    const o = obj orelse return null;
    const v = o.get(name) orelse return null;
    return switch (v) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => null,
    };
}

// ── safe arithmetic evaluator ────────────────────────────────────
// Recursive descent over + - * / % ^ parens, unary minus, decimals.
// NO eval, NO identifiers — the grammar admits digits/operators only.

const ExprParser = struct {
    s: []const u8,
    i: usize = 0,

    fn ws(self: *ExprParser) void {
        while (self.i < self.s.len and std.ascii.isWhitespace(self.s[self.i])) self.i += 1;
    }
    fn peek(self: *ExprParser) ?u8 {
        self.ws();
        return if (self.i < self.s.len) self.s[self.i] else null;
    }
    fn eat(self: *ExprParser, c: u8) bool {
        self.ws();
        if (self.i < self.s.len and self.s[self.i] == c) {
            self.i += 1;
            return true;
        }
        return false;
    }
    fn num(self: *ExprParser) ?f64 {
        self.ws();
        const start = self.i;
        while (self.i < self.s.len and (std.ascii.isDigit(self.s[self.i]) or self.s[self.i] == '.')) self.i += 1;
        if (self.i == start) return null;
        return std.fmt.parseFloat(f64, self.s[start..self.i]) catch null;
    }
    fn expr(self: *ExprParser) ?f64 {
        return self.addSub();
    }
    fn addSub(self: *ExprParser) ?f64 {
        var v = self.mulDiv() orelse return null;
        while (true) {
            self.ws();
            if (self.i >= self.s.len) return v;
            const c = self.s[self.i];
            if (c == '+') {
                self.i += 1;
                v = v + (self.mulDiv() orelse return null);
            } else if (c == '-') {
                self.i += 1;
                v = v - (self.mulDiv() orelse return null);
            } else return v;
        }
    }
    fn mulDiv(self: *ExprParser) ?f64 {
        var v = self.power() orelse return null;
        while (true) {
            self.ws();
            if (self.i >= self.s.len) return v;
            const c = self.s[self.i];
            if (c == '*') {
                self.i += 1;
                v = v * (self.power() orelse return null);
            } else if (c == '/') {
                self.i += 1;
                const d = self.power() orelse return null;
                if (d == 0) return null;
                v = v / d;
            } else if (c == '%') {
                self.i += 1;
                const d = self.power() orelse return null;
                if (d == 0) return null;
                v = @mod(v, d);
            } else return v;
        }
    }
    fn power(self: *ExprParser) ?f64 {
        var v = self.unary() orelse return null;
        self.ws();
        if (self.i < self.s.len and self.s[self.i] == '^') {
            self.i += 1;
            const e = self.power() orelse return null; // right assoc
            v = std.math.pow(f64, v, e);
        }
        return v;
    }
    fn unary(self: *ExprParser) ?f64 {
        self.ws();
        if (self.i < self.s.len and self.s[self.i] == '-') {
            self.i += 1;
            return -(self.unary() orelse return null);
        }
        if (self.i < self.s.len and self.s[self.i] == '+') {
            self.i += 1;
            return self.unary();
        }
        return self.atom();
    }
    fn atom(self: *ExprParser) ?f64 {
        self.ws();
        if (self.i >= self.s.len) return null;
        if (self.s[self.i] == '(') {
            self.i += 1;
            const v = self.expr() orelse return null;
            if (!self.eat(')')) return null;
            return v;
        }
        return self.num();
    }
};

pub fn evalExpr(expr: []const u8) ?f64 {
    if (expr.len == 0 or expr.len > 512) return null;
    var p = ExprParser{ .s = expr };
    const v = p.expr() orelse return null;
    p.ws();
    if (p.i != p.s.len) return null; // trailing garbage
    return v;
}

/// Format an f64 compactly for tool results.
fn fmtNum(gpa: std.mem.Allocator, v: f64) []const u8 {
    if (@abs(v - @round(v)) < 1e-9 and @abs(v) < 1e15) {
        return std.fmt.allocPrint(gpa, "{d}", .{@as(i64, @intFromFloat(@round(v)))}) catch @panic("OOM");
    }
    return std.fmt.allocPrint(gpa, "{d:.6}", .{v}) catch @panic("OOM");
}

/// Execute a resolved tool call. Returns gpa-owned result text (never
/// an error union — failures become descriptive result strings so the
/// model can react to them, matching real tool semantics). `workspace`
/// is the code-mode root confining file/process tools ("" → cwd).
pub fn exec(gpa: std.mem.Allocator, io: Io, def: *const ToolDef, args_json: []const u8, workspace: []const u8) []const u8 {
    if (def.exec == .mock) {
        // {args} → raw arguments JSON substitution.
        var out: std.ArrayListUnmanaged(u8) = .empty;
        const t = def.result_template;
        var i: usize = 0;
        while (i < t.len) {
            if (std.mem.startsWith(u8, t[i..], "{args}")) {
                out.appendSlice(gpa, if (args_json.len != 0) args_json else "{}") catch @panic("OOM");
                i += 6;
            } else {
                out.append(gpa, t[i]) catch @panic("OOM");
                i += 1;
            }
        }
        return out.toOwnedSlice(gpa) catch @panic("OOM");
    }
    // builtin — `builtin_name` aliases the wire name to a builtin.
    return execBuiltin(gpa, io, def.builtin_name orelse def.name, args_json, workspace);
}

fn execBuiltin(gpa: std.mem.Allocator, io: Io, name: []const u8, args_json: []const u8, workspace: []const u8) []const u8 {
    // Parse args ONCE — argStr/argF64 return slices into this tree,
    // valid until the deferred deinit at function exit.
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, args_json, .{}) catch null;
    defer if (parsed) |*p| p.deinit();
    const obj: ?std.json.ObjectMap = if (parsed) |*p| switch (p.value) {
        .object => |o| o,
        else => null,
    } else null;
    if (std.mem.eql(u8, name, "calculator")) {
        const expr = argStr(obj, "expr") orelse return dupeStr(gpa, "error: missing 'expr' arg");
        const v = evalExpr(expr) orelse return dupeStr(gpa, "error: invalid expression");
        return fmtNum(gpa, v);
    }
    if (std.mem.eql(u8, name, "datetime_now")) {
        const ts = Io.Clock.real.now(io);
        const secs = ts.toSeconds();
        var buf: [64]u8 = undefined;
        // UTC via epoch math — civil-from-days algorithm.
        const days = @divFloor(secs, 86400);
        const rem = @mod(secs, 86400);
        const ymd = civilFromDays(days);
        const y = ymd[0];
        const mo = ymd[1];
        const d = ymd[2];
        const hh = @divTrunc(rem, 3600);
        const mm = @divTrunc(@mod(rem, 3600), 60);
        const ss = @mod(rem, 60);
        const n = std.fmt.bufPrint(&buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z (unix {d})", .{ y, mo, d, hh, mm, ss, secs }) catch unreachable;
        return dupeStr(gpa, n);
    }
    if (std.mem.eql(u8, name, "echo")) {
        return state.dupe(gpa, argStr(obj, "text") orelse "");
    }
    if (std.mem.eql(u8, name, "word_count")) {
        const t = argStr(obj, "text") orelse "";
        var words: usize = 0;
        var in_word = false;
        for (t) |c| {
            if (std.ascii.isWhitespace(c)) {
                in_word = false;
            } else if (!in_word) {
                in_word = true;
                words += 1;
            }
        }
        return std.fmt.allocPrint(gpa, "{d} words, {d} chars, {d} bytes", .{ words, t.len, t.len }) catch @panic("OOM");
    }
    if (std.mem.eql(u8, name, "uuid4")) {
        var rb: [16]u8 = undefined;
        io.random(&rb);
        rb[6] = (rb[6] & 0x0f) | 0x40;
        rb[8] = (rb[8] & 0x3f) | 0x80;
        return std.fmt.allocPrint(gpa, "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{
            rb[0], rb[1], rb[2],  rb[3],  rb[4],  rb[5],  rb[6],  rb[7],
            rb[8], rb[9], rb[10], rb[11], rb[12], rb[13], rb[14], rb[15],
        }) catch @panic("OOM");
    }
    if (std.mem.eql(u8, name, "http_status")) {
        const code = argF64(obj, "code") orelse return dupeStr(gpa, "error: missing 'code'");
        const reason: []const u8 = switch (@as(i64, @intFromFloat(code))) {
            200 => "OK",
            201 => "Created",
            204 => "No Content",
            301 => "Moved Permanently",
            302 => "Found",
            304 => "Not Modified",
            400 => "Bad Request",
            401 => "Unauthorized",
            403 => "Forbidden",
            404 => "Not Found",
            405 => "Method Not Allowed",
            409 => "Conflict",
            418 => "I'm a teapot",
            429 => "Too Many Requests",
            500 => "Internal Server Error",
            502 => "Bad Gateway",
            503 => "Service Unavailable",
            504 => "Gateway Timeout",
            else => "?",
        };
        return std.fmt.allocPrint(gpa, "HTTP {d} {s}", .{ @as(i64, @intFromFloat(code)), reason }) catch @panic("OOM");
    }
    if (std.mem.eql(u8, name, "bash")) return execBash(gpa, io, obj, workspace);
    if (std.mem.eql(u8, name, "read_file")) return execReadFile(gpa, io, obj, workspace);
    if (std.mem.eql(u8, name, "write_file")) return execWriteFile(gpa, io, obj, workspace);
    if (std.mem.eql(u8, name, "edit_file")) return execEditFile(gpa, io, obj, workspace);
    if (std.mem.eql(u8, name, "list_dir")) return execListDir(gpa, io, obj, workspace);
    if (std.mem.eql(u8, name, "grep_files")) return execGrep(gpa, io, obj, workspace);
    if (isProcTool(name)) return dupeStr(gpa, "error: process tools need an active code-mode session");
    return std.fmt.allocPrint(gpa, "error: unknown builtin tool '{s}'", .{name}) catch @panic("OOM");
}

/// `bash` builtin: spawn `sh -c <command>` with piped stdout+stderr,
/// drain both with a poll deadline, kill on timeout. Synchronous —
/// the caller (session drain) blocks for the command's duration.
fn execBash(gpa: std.mem.Allocator, io: Io, obj: ?std.json.ObjectMap, workspace: []const u8) []const u8 {
    const cmd = argStr(obj, "command") orelse return dupeStr(gpa, "error: missing 'command' arg");
    if (cmd.len == 0 or cmd.len > 4000) return dupeStr(gpa, "error: command empty or too long");
    var timeout_ms: u64 = 20000;
    if (argF64(obj, "timeout_ms")) |t| {
        if (t > 0 and t <= 120000) timeout_ms = @intFromFloat(t);
    }
    const argv = [_][]const u8{ "sh", "-c", cmd };
    const em = scrubbedEnv(gpa);
    defer if (em) |m| {
        m.deinit();
        gpa.destroy(m);
    };
    var child = std.process.spawn(io, .{
        .argv = &argv,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        .cwd = if (workspace.len != 0) .{ .path = workspace } else .inherit,
        .environ_map = em,
    }) catch return dupeStr(gpa, "error: spawn failed");
    defer child.kill(io); // idempotent — reaps if still running

    const so = child.stdout orelse return dupeStr(gpa, "error: no stdout pipe");
    const se = child.stderr orelse return dupeStr(gpa, "error: no stderr pipe");
    const fds_in = [_]std.posix.fd_t{ so.handle, se.handle };
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);
    const CAP: usize = 64 * 1024;
    var eof = [_]bool{ false, false };
    var timed_out = false;
    const start_ts = Io.Clock.real.now(io);
    var chunk: [8192]u8 = undefined;
    while (!eof[0] or !eof[1]) {
        if (Io.Clock.real.now(io).toMilliseconds() - start_ts.toMilliseconds() >= @as(i64, @intCast(timeout_ms))) {
            timed_out = true;
            break;
        }
        var pfds = [_]std.posix.pollfd{
            .{ .fd = fds_in[0], .events = if (eof[0]) 0 else std.posix.POLL.IN, .revents = 0 },
            .{ .fd = fds_in[1], .events = if (eof[1]) 0 else std.posix.POLL.IN, .revents = 0 },
        };
        _ = std.posix.poll(&pfds, 100) catch break;
        for (pfds, 0..) |pfd, i| {
            if (pfd.revents == 0) continue;
            if (pfd.revents & (std.posix.POLL.ERR | std.posix.POLL.NVAL) != 0) {
                eof[i] = true;
                continue;
            }
            const n = std.posix.read(fds_in[i], &chunk) catch {
                eof[i] = true;
                continue;
            };
            if (n == 0) {
                eof[i] = true;
                continue;
            }
            if (out.items.len < CAP) {
                const room = CAP - out.items.len;
                out.appendSlice(gpa, chunk[0..@min(n, room)]) catch @panic("OOM");
            }
        }
    }
    const term = if (timed_out) blk: {
        child.kill(io);
        break :blk null;
    } else child.wait(io) catch null;

    var result: std.ArrayListUnmanaged(u8) = .empty;
    defer result.deinit(gpa);
    result.appendSlice(gpa, out.items) catch @panic("OOM");
    if (timed_out) {
        result.appendSlice(gpa, "\n[timeout — process killed]") catch @panic("OOM");
    } else if (term) |t| {
        switch (t) {
            .exited => |code| result.print(gpa, "\n[exit {d}]", .{code}) catch @panic("OOM"),
            .signal => |sig| result.print(gpa, "\n[killed by signal {t}]", .{sig}) catch @panic("OOM"),
            else => {},
        }
    }
    if (result.items.len == 0) result.appendSlice(gpa, "(no output)") catch @panic("OOM");
    return result.toOwnedSlice(gpa) catch @panic("OOM");
}

/// Child environment with secrets stripped: vars whose NAME contains
/// KEY/TOKEN/SECRET/PASSWORD/CREDENTIAL/AUTH (case-insensitive) are
/// dropped unless allowlisted — keeps PATH/HOME/toolchain vars so
/// builds still work. Caller owns the map (deinit + destroy).
pub fn scrubbedEnv(gpa: std.mem.Allocator) ?*std.process.Environ.Map {
    const map = gpa.create(std.process.Environ.Map) catch return null;
    map.* = .init(gpa);
    switch (builtin.os.tag) {
        .windows, .wasi, .emscripten, .freestanding, .other => return map,
        else => {},
    }
    const deny = [_][]const u8{ "KEY", "TOKEN", "SECRET", "PASSWORD", "CREDENTIAL", "AUTH" };
    const allow = [_][]const u8{
        "PATH",           "HOME",                    "LANG",    "LC_ALL", "LC_CTYPE",  "TMPDIR",  "TEMP",          "TMP",
        "SHELL",          "USER",                    "LOGNAME", "TERM",   "COLORTERM", "SDKROOT", "DEVELOPER_DIR", "COMMAND_MODE",
        "MallocNanoZone", "__CF_USER_TEXT_ENCODING",
        "XPC_", "SSH_AUTH_SOCK", // agent socket is a path, not a secret
    };
    var i: usize = 0;
    while (std.c.environ[i]) |entry| : (i += 1) {
        const s = std.mem.span(entry);
        const eq = std.mem.indexOfScalar(u8, s, '=') orelse continue;
        const name = s[0..eq];
        if (name.len == 0) continue;
        var keep = false;
        for (allow) |a| {
            if (std.mem.startsWith(u8, name, a)) {
                keep = true;
                break;
            }
        }
        if (!keep) {
            var up_buf: [128]u8 = undefined;
            keep = name.len > up_buf.len; // unreasonably long names pass through
            if (!keep) {
                const up = std.ascii.upperString(&up_buf, name);
                keep = true;
                for (deny) |d| {
                    if (std.mem.indexOf(u8, up, d) != null) {
                        keep = false;
                        break;
                    }
                }
            }
        }
        if (keep) map.put(name, s[eq + 1 ..]) catch {};
    }
    return map;
}

fn dupeStr(gpa: std.mem.Allocator, s: []const u8) []const u8 {
    return state.dupe(gpa, s);
}

fn errResult(gpa: std.mem.Allocator, comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(gpa, "error: " ++ fmt, args) catch @panic("OOM");
}

pub fn argBool(obj: ?std.json.ObjectMap, name: []const u8) bool {
    const o = obj orelse return false;
    const v = o.get(name) orelse return false;
    return switch (v) {
        .bool => |b| b,
        else => false,
    };
}

// ── code-mode file tools ─────────────────────────────────────────

/// Resolve a tool `path` arg to an absolute normalized path confined
/// to `workspace` (process cwd when workspace is ""). Empty `path`
/// yields the workspace root itself. Returns a gpa-owned slice, or
/// null on escape/invalid input — `..` is collapsed by
/// `fs.path.resolveAlloc` BEFORE the prefix check, so traversal
/// outside the root is rejected.
fn resolveToolPath(gpa: std.mem.Allocator, io: Io, workspace: []const u8, path: []const u8) ?[]u8 {
    if (path.len > 4096) return null;
    if (std.mem.indexOfScalar(u8, path, 0) != null) return null;
    const cwd = std.process.currentPathAlloc(io, gpa) catch return null;
    defer gpa.free(cwd);
    const root = if (workspace.len != 0)
        (std.fs.path.resolveAlloc(gpa, &.{ cwd, workspace }) catch return null)
    else
        (gpa.dupe(u8, cwd) catch return null);
    defer gpa.free(root);
    if (path.len == 0) return gpa.dupe(u8, root) catch null;
    const target = std.fs.path.resolveAlloc(gpa, &.{ root, path }) catch return null;
    var prefix_buf: [4200]u8 = undefined;
    const prefix = if (root.len > 0 and root[root.len - 1] == '/')
        root
    else
        std.fmt.bufPrint(&prefix_buf, "{s}/", .{root}) catch {
            gpa.free(target);
            return null;
        };
    const inside = std.mem.eql(u8, target, root) or std.mem.startsWith(u8, target, prefix);
    if (!inside) {
        gpa.free(target);
        return null;
    }
    return target;
}

fn execReadFile(gpa: std.mem.Allocator, io: Io, obj: ?std.json.ObjectMap, workspace: []const u8) []const u8 {
    const path = argStr(obj, "path") orelse return errResult(gpa, "missing 'path' arg", .{});
    const abs = resolveToolPath(gpa, io, workspace, path) orelse
        return errResult(gpa, "invalid path or escapes workspace: '{s}'", .{path});
    defer gpa.free(abs);
    const data = std.Io.Dir.cwd().readFileAlloc(io, abs, gpa, .limited(2 * 1024 * 1024)) catch |e|
        return errResult(gpa, "read failed: {s}", .{@errorName(e)});
    defer gpa.free(data);
    const probe = data[0..@min(data.len, 8192)];
    if (std.mem.indexOfScalar(u8, probe, 0) != null) return dupeStr(gpa, "error: binary file");

    var start: usize = 1;
    if (argF64(obj, "start_line")) |v| {
        if (v >= 1 and v <= 1_000_000) start = @intFromFloat(v);
    }
    var max_lines: usize = 400;
    if (argF64(obj, "max_lines")) |v| {
        if (v >= 1 and v <= 5000) max_lines = @intFromFloat(v);
    }
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);
    var line_no: usize = 0;
    var shown: usize = 0;
    var truncated = false;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw| {
        line_no += 1;
        if (line_no < start) continue;
        if (shown >= max_lines) {
            truncated = true;
            break;
        }
        const line = std.mem.trimEnd(u8, raw, "\r");
        out.print(gpa, "{d}: {s}\n", .{ line_no, line }) catch @panic("OOM");
        shown += 1;
    }
    if (truncated) out.appendSlice(gpa, "[truncated — use start_line/max_lines]\n") catch @panic("OOM");
    if (shown == 0) return errResult(gpa, "no lines in range (file has {d})", .{line_no});
    return out.toOwnedSlice(gpa) catch @panic("OOM");
}

fn execWriteFile(gpa: std.mem.Allocator, io: Io, obj: ?std.json.ObjectMap, workspace: []const u8) []const u8 {
    const path = argStr(obj, "path") orelse return errResult(gpa, "missing 'path' arg", .{});
    const content = argStr(obj, "content") orelse return errResult(gpa, "missing 'content' arg", .{});
    if (content.len > 512 * 1024) return dupeStr(gpa, "error: content exceeds 512KB");
    const abs = resolveToolPath(gpa, io, workspace, path) orelse
        return errResult(gpa, "invalid path or escapes workspace: '{s}'", .{path});
    defer gpa.free(abs);
    if (std.fs.path.dirname(abs)) |dir| {
        std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    }
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = abs, .data = content }) catch |e|
        return errResult(gpa, "write failed: {s}", .{@errorName(e)});
    return std.fmt.allocPrint(gpa, "wrote {d} bytes to {s}", .{ content.len, path }) catch @panic("OOM");
}

fn execEditFile(gpa: std.mem.Allocator, io: Io, obj: ?std.json.ObjectMap, workspace: []const u8) []const u8 {
    const path = argStr(obj, "path") orelse return errResult(gpa, "missing 'path' arg", .{});
    const old = argStr(obj, "old_string") orelse return errResult(gpa, "missing 'old_string' arg", .{});
    const new = argStr(obj, "new_string") orelse return errResult(gpa, "missing 'new_string' arg", .{});
    if (old.len == 0) return dupeStr(gpa, "error: old_string is empty");
    const abs = resolveToolPath(gpa, io, workspace, path) orelse
        return errResult(gpa, "invalid path or escapes workspace: '{s}'", .{path});
    defer gpa.free(abs);
    const data = std.Io.Dir.cwd().readFileAlloc(io, abs, gpa, .limited(2 * 1024 * 1024)) catch |e|
        return errResult(gpa, "read failed: {s}", .{@errorName(e)});
    defer gpa.free(data);

    var count: usize = 0;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, data, pos, old)) |idx| {
        count += 1;
        pos = idx + old.len;
    }
    if (count == 0) return errResult(gpa, "old_string not found in {s}", .{path});
    const all = argBool(obj, "replace_all");
    if (count > 1 and !all) {
        return std.fmt.allocPrint(gpa, "error: old_string occurs {d} times in {s} — add more context or set replace_all", .{ count, path }) catch @panic("OOM");
    }
    // Build replaced content.
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);
    var cur: usize = 0;
    var replaced: usize = 0;
    while (std.mem.indexOfPos(u8, data, cur, old)) |idx| {
        out.appendSlice(gpa, data[cur..idx]) catch @panic("OOM");
        out.appendSlice(gpa, new) catch @panic("OOM");
        cur = idx + old.len;
        replaced += 1;
        if (!all) break;
    }
    out.appendSlice(gpa, data[cur..]) catch @panic("OOM");
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = abs, .data = out.items }) catch |e|
        return errResult(gpa, "write failed: {s}", .{@errorName(e)});
    return std.fmt.allocPrint(gpa, "edited {s}: replaced {d} occurrence(s)", .{ path, replaced }) catch @panic("OOM");
}

fn execListDir(gpa: std.mem.Allocator, io: Io, obj: ?std.json.ObjectMap, workspace: []const u8) []const u8 {
    const path = argStr(obj, "path") orelse "";
    const abs = resolveToolPath(gpa, io, workspace, path) orelse
        return errResult(gpa, "invalid path or escapes workspace: '{s}'", .{path});
    defer gpa.free(abs);
    var dir = std.Io.Dir.cwd().openDir(io, abs, .{ .iterate = true }) catch |e|
        return errResult(gpa, "open dir failed: {s}", .{@errorName(e)});
    defer dir.close(io);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);
    var it = dir.iterate();
    var n: usize = 0;
    var truncated = false;
    while (it.next(io) catch null) |entry| {
        if (n >= 500) {
            truncated = true;
            break;
        }
        const suffix: []const u8 = if (entry.kind == .directory) "/" else "";
        out.print(gpa, "{s}{s}\n", .{ entry.name, suffix }) catch @panic("OOM");
        n += 1;
    }
    if (truncated) out.appendSlice(gpa, "[truncated at 500 entries]\n") catch @panic("OOM");
    if (n == 0) return dupeStr(gpa, "(empty directory)");
    return out.toOwnedSlice(gpa) catch @panic("OOM");
}

const skip_dirs = [_][]const u8{ ".git", "node_modules", ".zig-cache", "zig-out", ".next", "dist" };

fn execGrep(gpa: std.mem.Allocator, io: Io, obj: ?std.json.ObjectMap, workspace: []const u8) []const u8 {
    const pattern = argStr(obj, "pattern") orelse return errResult(gpa, "missing 'pattern' arg", .{});
    if (pattern.len == 0 or pattern.len > 200) return dupeStr(gpa, "error: pattern empty or too long");
    const path = argStr(obj, "path") orelse "";
    const abs = resolveToolPath(gpa, io, workspace, path) orelse
        return errResult(gpa, "invalid path or escapes workspace: '{s}'", .{path});
    defer gpa.free(abs);
    var dir = std.Io.Dir.cwd().openDir(io, abs, .{ .iterate = true }) catch |e|
        return errResult(gpa, "open dir failed: {s}", .{@errorName(e)});
    defer dir.close(io);
    var walker = dir.walk(gpa) catch return errResult(gpa, "walk failed", .{});
    defer walker.deinit();

    const ignore_case = argBool(obj, "ignore_case");
    var needle_buf: [201]u8 = undefined;
    const needle = if (ignore_case) blk: {
        if (pattern.len > needle_buf.len) return dupeStr(gpa, "error: pattern too long");
        const n = std.ascii.lowerString(&needle_buf, pattern);
        break :blk n;
    } else pattern;
    var hay_buf: [201]u8 = undefined;

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);
    var matches: usize = 0;
    var scanned: usize = 0;
    var truncated = false;
    while (walker.next(io) catch null) |entry| {
        if (matches >= 100 or scanned >= 3000) {
            truncated = true;
            break;
        }
        if (entry.kind == .directory) {
            for (skip_dirs) |sd| {
                if (std.mem.eql(u8, entry.basename, sd)) {
                    walker.leave(io);
                    break;
                }
            }
            continue;
        }
        if (entry.kind != .file) continue;
        scanned += 1;
        const fdata = entry.dir.readFileAlloc(io, entry.basename, gpa, .limited(512 * 1024 + 1)) catch continue;
        defer gpa.free(fdata);
        if (fdata.len > 512 * 1024) continue;
        if (std.mem.indexOfScalar(u8, fdata[0..@min(fdata.len, 8192)], 0) != null) continue;
        var line_no: usize = 0;
        var lines = std.mem.splitScalar(u8, fdata, '\n');
        while (lines.next()) |raw| {
            line_no += 1;
            const line = std.mem.trimEnd(u8, raw, "\r");
            const hay = if (ignore_case and line.len <= hay_buf.len) blk: {
                break :blk std.ascii.lowerString(&hay_buf, line);
            } else line;
            const hit = if (ignore_case)
                (hay.len >= needle.len and std.mem.indexOf(u8, hay, needle) != null)
            else
                std.mem.indexOf(u8, line, pattern) != null;
            if (!hit) continue;
            const short = line[0..@min(line.len, 200)];
            out.print(gpa, "{s}:{d}: {s}\n", .{ entry.path, line_no, short }) catch @panic("OOM");
            matches += 1;
            if (matches >= 100) break;
        }
    }
    if (truncated) out.appendSlice(gpa, "[truncated — narrow the search path/pattern]\n") catch @panic("OOM");
    if (matches == 0) return dupeStr(gpa, "no matches");
    return out.toOwnedSlice(gpa) catch @panic("OOM");
}

// Howard Hinnant's civil-from-days — proleptic Gregorian, UTC.
fn civilFromDays(z: i64) struct { i64, u32, u32 } {
    const zz = z + 719468;
    const era = @divFloor(zz, 146097);
    const doe = zz - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    return .{ if (m <= 2) y + 1 else y, @intCast(m), @intCast(d) };
}

// ── tests ────────────────────────────────────────────────────────

test "evalExpr arithmetic grammar" {
    try std.testing.expectEqual(@as(?f64, 7), evalExpr("1+2*3"));
    try std.testing.expectEqual(@as(?f64, 10), evalExpr("(1+2)*3+1"));
    try std.testing.expectEqual(@as(?f64, 8), evalExpr("2^3"));
    try std.testing.expectEqual(@as(?f64, -1.5), evalExpr("-3/2"));
    try std.testing.expectEqual(@as(?f64, 1), evalExpr("5%2"));
    try std.testing.expect(evalExpr("1+") == null);
    try std.testing.expect(evalExpr("abc") == null);
    try std.testing.expect(evalExpr("1/0") == null);
    try std.testing.expect(evalExpr("2*(3+4") == null);
    try std.testing.expect(evalExpr("") == null);
    try std.testing.expect(evalExpr("1 2") == null);
}

test "parseDefs validates shape and dupes strings" {
    const gpa = std.testing.allocator;
    const defs = try parseDefs(gpa,
        \\[ {"name":"t1","description":"d","parameters":{"type":"object"},"exec":"mock","result":"ok {args}"} ]
    );
    defer freeDefs(gpa, defs);
    try std.testing.expectEqual(@as(usize, 1), defs.len);
    try std.testing.expectEqualStrings("t1", defs[0].name);
    try std.testing.expectEqual(ExecKind.mock, defs[0].exec);
    try std.testing.expectEqualStrings("ok {args}", defs[0].result_template);

    try std.testing.expectError(error.BadJson, parseDefs(gpa, "not json"));
    try std.testing.expectError(error.NotArray, parseDefs(gpa, "{}"));
    try std.testing.expectError(error.BadDef, parseDefs(gpa, "[{\"description\":\"x\"}]"));
    try std.testing.expectError(error.BadDef, parseDefs(gpa, "[{\"name\":\"bad name!\"}]"));
}

test "defsToToolsJson emits OpenAI tools array" {
    const gpa = std.testing.allocator;
    const defs = [_]ToolDef{.{
        .name = "t",
        .description = "d",
        .parameters_json = "{\"type\":\"object\"}",
    }};
    const j = defsToToolsJson(gpa, &defs);
    defer gpa.free(j);
    try std.testing.expect(std.mem.indexOf(u8, j, "\"type\":\"function\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, j, "\"name\":\"t\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, j, "\"parameters\":{\"type\":\"object\"}") != null);
}

test "exec mock substitutes {args}, builtin calculator works" {
    const gpa = std.testing.allocator;
    var mock: ToolDef = .{ .name = "m", .exec = .mock, .result_template = "got {args}" };
    const r1 = exec(gpa, std.testing.io, &mock, "{\"a\":1}", "");
    defer gpa.free(r1);
    try std.testing.expectEqualStrings("got {\"a\":1}", r1);

    var calc: ToolDef = .{ .name = "calculator", .exec = .builtin };
    const r2 = exec(gpa, std.testing.io, &calc, "{\"expr\":\"2+3*4\"}", "");
    defer gpa.free(r2);
    try std.testing.expectEqualStrings("14", r2);

    const r3 = exec(gpa, std.testing.io, &calc, "{\"expr\":\"1/0\"}", "");
    defer gpa.free(r3);
    try std.testing.expect(std.mem.startsWith(u8, r3, "error:"));
}

test "builtinDef emits function object for known names" {
    const gpa = std.testing.allocator;
    const j = builtinDef(gpa, "calculator").?;
    defer gpa.free(j);
    try std.testing.expect(std.mem.indexOf(u8, j, "\"name\":\"calculator\"") != null);
    try std.testing.expect(builtinDef(gpa, "nope") == null);
}

test "exec bash runs a command and captures output" {
    const gpa = std.testing.allocator;
    var d: ToolDef = .{ .name = "bash", .exec = .builtin };
    const r = exec(gpa, std.testing.io, &d, "{\"command\":\"echo hi && echo err >&2; exit 3\",\"timeout_ms\":5000}", "");
    defer gpa.free(r);
    try std.testing.expect(std.mem.indexOf(u8, r, "hi") != null);
    try std.testing.expect(std.mem.indexOf(u8, r, "err") != null);
    try std.testing.expect(std.mem.indexOf(u8, r, "exit 3") != null);
    // timeout kills long commands
    const r2 = exec(gpa, std.testing.io, &d, "{\"command\":\"sleep 30\",\"timeout_ms\":300}", "");
    defer gpa.free(r2);
    try std.testing.expect(std.mem.indexOf(u8, r2, "timeout") != null);
}

test "code file tools: write/read/edit/list/grep + workspace escape rejection" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const ws = ".zig-cache/zllm-tooltest";
    std.Io.Dir.cwd().createDirPath(io, ws) catch unreachable;
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = ws ++ "/a.txt", .data = "alpha\nbeta\n" }) catch unreachable;

    var d: ToolDef = .{ .name = "write_file", .exec = .builtin };
    const w = exec(gpa, io, &d, "{\"path\":\"sub/b.txt\",\"content\":\"x\\ny\\n\"}", ws);
    defer gpa.free(w);
    try std.testing.expect(std.mem.indexOf(u8, w, "wrote") != null);

    d.name = "read_file";
    const r = exec(gpa, io, &d, "{\"path\":\"a.txt\"}", ws);
    defer gpa.free(r);
    try std.testing.expect(std.mem.indexOf(u8, r, "1: alpha") != null);
    try std.testing.expect(std.mem.indexOf(u8, r, "2: beta") != null);

    d.name = "edit_file";
    const e = exec(gpa, io, &d, "{\"path\":\"a.txt\",\"old_string\":\"beta\",\"new_string\":\"gamma\"}", ws);
    defer gpa.free(e);
    try std.testing.expect(std.mem.indexOf(u8, e, "replaced 1") != null);

    d.name = "list_dir";
    const l = exec(gpa, io, &d, "{}", ws);
    defer gpa.free(l);
    try std.testing.expect(std.mem.indexOf(u8, l, "a.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, l, "sub/") != null);

    d.name = "grep_files";
    const g = exec(gpa, io, &d, "{\"pattern\":\"gamma\"}", ws);
    defer gpa.free(g);
    try std.testing.expect(std.mem.indexOf(u8, g, "a.txt:2: gamma") != null);

    // escape attempts must be rejected
    d.name = "read_file";
    const esc = exec(gpa, io, &d, "{\"path\":\"../build.zig\"}", ws);
    defer gpa.free(esc);
    try std.testing.expect(std.mem.indexOf(u8, esc, "escapes workspace") != null);
    const esc2 = exec(gpa, io, &d, "{\"path\":\"/etc/passwd\"}", ws);
    defer gpa.free(esc2);
    try std.testing.expect(std.mem.indexOf(u8, esc2, "escapes workspace") != null);
}
