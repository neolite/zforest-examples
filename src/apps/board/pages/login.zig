//! "/login" — account sign-in (ADR-0001 phase 2 + email auth). Static
//! route, no params, no prepare gate; the form posts the `login`
//! action. The identifier field is the account EMAIL (pre-email
//! accounts still resolve by name server-side).
const std = @import("std");
const forest = @import("forest");
const zmeta = @import("../zmeta.zig");
const components = @import("../shared/components.zig");

/// Route params — static route, empty struct (required by the contract).
pub const params = struct {};

pub fn view(a: std.mem.Allocator, s: anytype, p: params, env: *const zmeta.Env) forest.Node {
    _ = p;
    _ = env;
    const venv = s.deps.viewEnv();
    const fields = [_]forest.Node{
        components.authField(a, "email", "email", "email", "username"),
        components.authField(a, "password", "password", "пароль", "current-password"),
    };
    return components.authPage(a, venv, "Вход", "login", &fields, "Войти", .{ .label = "нет аккаунта? регистрация", .href = components.registerHref(a) });
}
