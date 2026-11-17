//! GENERATED FILE — do not edit. Regenerate with `zig build gen`.
//! Source: actions.zig manifest (spec §2.9 v0 name table).

const std = @import("std");

/// Comptime action names shared by view `.on` attrs and the
/// dispatch skeleton — `act.like` in `.on = .{ .click = act.like }`
/// is compile-checked; the wire stays strings.
pub const act = struct {
};

/// Dispatch skeleton: each whitelisted action calls the app's
/// `on_<name>` decl on the Deps type (`@TypeOf(s.deps)`), with
/// the same (arg, value, fields) payload the session contract
/// receives. Unknown actions → error.InvalidAction.
pub fn dispatch(
    s: anytype,
    action: []const u8,
    arg: ?[]const u8,
    value: ?[]const u8,
    fields: ?*const std.json.ObjectMap,
) !void {
    _ = s;
    _ = action;
    _ = arg;
    _ = value;
    _ = fields;
    return error.InvalidAction;
}
