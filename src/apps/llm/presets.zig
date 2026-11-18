//! presets — endpoint presets for the config dropdown.
const std = @import("std");

pub const Preset = struct {
    /// Wire value of the select option.
    id: []const u8,
    label: []const u8,
    base_url: []const u8,
    /// Suggested model — user can override.
    model: []const u8,
    context_window: u32,
};

pub const presets = [_]Preset{
    .{ .id = "openai", .label = "OpenAI", .base_url = "https://api.openai.com/v1", .model = "gpt-4o-mini", .context_window = 128000 },
    .{ .id = "deepseek", .label = "DeepSeek", .base_url = "https://api.deepseek.com/v1", .model = "deepseek-chat", .context_window = 64000 },
    .{ .id = "openrouter", .label = "OpenRouter", .base_url = "https://openrouter.ai/api/v1", .model = "openai/gpt-4o-mini", .context_window = 128000 },
    .{ .id = "ollama", .label = "Ollama (local)", .base_url = "http://localhost:11434/v1", .model = "llama3.1", .context_window = 32000 },
    .{ .id = "lmstudio", .label = "LM Studio (local)", .base_url = "http://localhost:1234/v1", .model = "local-model", .context_window = 32000 },
    .{ .id = "custom", .label = "Custom…", .base_url = "", .model = "", .context_window = 64000 },
};

pub fn find(id: []const u8) ?Preset {
    for (presets) |p| {
        if (std.mem.eql(u8, p.id, id)) return p;
    }
    return null;
}

test "preset ids unique and findable" {
    try std.testing.expect(find("deepseek") != null);
    try std.testing.expect(find("nope") == null);
    var seen = std.StringHashMap(void).init(std.testing.allocator);
    defer seen.deinit();
    for (presets) |p| {
        try std.testing.expect(!seen.contains(p.id));
        try seen.put(p.id, {});
    }
}
