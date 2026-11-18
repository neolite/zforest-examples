//! GENERATED FILE — do not edit. Regenerate with `zig build gen`.
//! Source: actions.zig manifest (spec §2.9 v0 name table).

const std = @import("std");

/// Comptime action names shared by view `.on` attrs and the
/// dispatch skeleton — `act.like` in `.on = .{ .click = act.like }`
/// is compile-checked; the wire stays strings.
pub const act = struct {
    pub const send = "send";
    pub const stop = "stop";
    pub const new_chat = "new_chat";
    pub const select_chat = "select_chat";
    pub const delete_chat = "delete_chat";
    pub const approve_tool = "approve_tool";
    pub const reject_tool = "reject_tool";
    pub const cfg_base_url = "cfg_base_url";
    pub const cfg_api_key = "cfg_api_key";
    pub const cfg_model = "cfg_model";
    pub const cfg_system = "cfg_system";
    pub const cfg_temperature = "cfg_temperature";
    pub const cfg_top_p = "cfg_top_p";
    pub const cfg_context_window = "cfg_context_window";
    pub const cfg_tool_mode = "cfg_tool_mode";
    pub const cfg_agent_mode = "cfg_agent_mode";
    pub const cfg_workspace = "cfg_workspace";
    pub const cfg_tools_json = "cfg_tools_json";
    pub const set_preset = "set_preset";
    pub const fetch_models = "fetch_models";
    pub const load_tools_example = "load_tools_example";
    pub const set_sysprompt = "set_sysprompt";
    pub const cfg_mcp_servers = "cfg_mcp_servers";
    pub const mcp_check = "mcp_check";
    pub const clear_key = "clear_key";
    pub const clear_chat = "clear_chat";
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
    const D = @TypeOf(s.deps);
    if (std.mem.eql(u8, action, act.send)) return D.on_send(s, arg, value, fields);
    if (std.mem.eql(u8, action, act.stop)) return D.on_stop(s, arg, value, fields);
    if (std.mem.eql(u8, action, act.new_chat)) return D.on_new_chat(s, arg, value, fields);
    if (std.mem.eql(u8, action, act.select_chat)) return D.on_select_chat(s, arg, value, fields);
    if (std.mem.eql(u8, action, act.delete_chat)) return D.on_delete_chat(s, arg, value, fields);
    if (std.mem.eql(u8, action, act.approve_tool)) return D.on_approve_tool(s, arg, value, fields);
    if (std.mem.eql(u8, action, act.reject_tool)) return D.on_reject_tool(s, arg, value, fields);
    if (std.mem.eql(u8, action, act.cfg_base_url)) return D.on_cfg_base_url(s, arg, value, fields);
    if (std.mem.eql(u8, action, act.cfg_api_key)) return D.on_cfg_api_key(s, arg, value, fields);
    if (std.mem.eql(u8, action, act.cfg_model)) return D.on_cfg_model(s, arg, value, fields);
    if (std.mem.eql(u8, action, act.cfg_system)) return D.on_cfg_system(s, arg, value, fields);
    if (std.mem.eql(u8, action, act.cfg_temperature)) return D.on_cfg_temperature(s, arg, value, fields);
    if (std.mem.eql(u8, action, act.cfg_top_p)) return D.on_cfg_top_p(s, arg, value, fields);
    if (std.mem.eql(u8, action, act.cfg_context_window)) return D.on_cfg_context_window(s, arg, value, fields);
    if (std.mem.eql(u8, action, act.cfg_tool_mode)) return D.on_cfg_tool_mode(s, arg, value, fields);
    if (std.mem.eql(u8, action, act.cfg_agent_mode)) return D.on_cfg_agent_mode(s, arg, value, fields);
    if (std.mem.eql(u8, action, act.cfg_workspace)) return D.on_cfg_workspace(s, arg, value, fields);
    if (std.mem.eql(u8, action, act.cfg_tools_json)) return D.on_cfg_tools_json(s, arg, value, fields);
    if (std.mem.eql(u8, action, act.set_preset)) return D.on_set_preset(s, arg, value, fields);
    if (std.mem.eql(u8, action, act.fetch_models)) return D.on_fetch_models(s, arg, value, fields);
    if (std.mem.eql(u8, action, act.load_tools_example)) return D.on_load_tools_example(s, arg, value, fields);
    if (std.mem.eql(u8, action, act.set_sysprompt)) return D.on_set_sysprompt(s, arg, value, fields);
    if (std.mem.eql(u8, action, act.cfg_mcp_servers)) return D.on_cfg_mcp_servers(s, arg, value, fields);
    if (std.mem.eql(u8, action, act.mcp_check)) return D.on_mcp_check(s, arg, value, fields);
    if (std.mem.eql(u8, action, act.clear_key)) return D.on_clear_key(s, arg, value, fields);
    if (std.mem.eql(u8, action, act.clear_chat)) return D.on_clear_chat(s, arg, value, fields);
    return error.InvalidAction;
}
