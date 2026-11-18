//! zllm action manifest — `zig build gen` turns these names into the
//! comptime `act` table + dispatch arms in `gen/actions.zig`. Each name
//! needs an `on_<name>` handler decl on `LlmDeps` (app.zig); view `.on`
//! attrs reference `act.<name>` for compile-checked wiring.
pub const actions = .{
    "send",
    "stop",
    "new_chat",
    "select_chat",
    "delete_chat",
    "approve_tool",
    "reject_tool",
    "cfg_base_url",
    "cfg_api_key",
    "cfg_model",
    "cfg_system",
    "cfg_temperature",
    "cfg_top_p",
    "cfg_context_window",
    "cfg_tool_mode",
    "cfg_tools_json",
    "set_preset",
    "fetch_models",
    "load_tools_example",
    "set_sysprompt",
    "cfg_mcp_servers",
    "mcp_check",
    "clear_key",
    "clear_chat",
};
