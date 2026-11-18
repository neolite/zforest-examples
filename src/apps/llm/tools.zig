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
};

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
fn argStr(obj: ?std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const o = obj orelse return null;
    const v = o.get(name) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn argF64(obj: ?std.json.ObjectMap, name: []const u8) ?f64 {
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
/// model can react to them, matching real tool semantics).
pub fn exec(gpa: std.mem.Allocator, io: Io, def: *const ToolDef, args_json: []const u8) []const u8 {
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
    return execBuiltin(gpa, io, def.builtin_name orelse def.name, args_json);
}

fn execBuiltin(gpa: std.mem.Allocator, io: Io, name: []const u8, args_json: []const u8) []const u8 {
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
    return std.fmt.allocPrint(gpa, "error: unknown builtin tool '{s}'", .{name}) catch @panic("OOM");
}

fn dupeStr(gpa: std.mem.Allocator, s: []const u8) []const u8 {
    return state.dupe(gpa, s);
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
    const r1 = exec(gpa, std.testing.io, &mock, "{\"a\":1}");
    defer gpa.free(r1);
    try std.testing.expectEqualStrings("got {\"a\":1}", r1);

    var calc: ToolDef = .{ .name = "calculator", .exec = .builtin };
    const r2 = exec(gpa, std.testing.io, &calc, "{\"expr\":\"2+3*4\"}");
    defer gpa.free(r2);
    try std.testing.expectEqualStrings("14", r2);

    const r3 = exec(gpa, std.testing.io, &calc, "{\"expr\":\"1/0\"}");
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
