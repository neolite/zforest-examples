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

// ── system prompt presets ────────────────────────────────────────

pub const Sysprompt = struct {
    id: []const u8,
    label: []const u8,
    text: []const u8,
};

/// One-shot fills for the system prompt textarea — "custom" is not
/// listed: it only appears as the select's fallback when the textarea
/// holds hand-written text.
pub const sysprompts = [_]Sysprompt{
    .{ .id = "assistant", .label = "Helpful assistant", .text = "You are a helpful assistant. Answer clearly and concisely. If you are unsure, say so instead of guessing." },
    .{ .id = "terse", .label = "Terse", .text = "You are a terse assistant. Answer in as few words as possible. No pleasantries, no filler." },
    .{ .id = "eli5", .label = "Explain like I'm 5", .text = "Explain concepts like I'm five years old: simple words, everyday analogies, short sentences. Still be accurate." },
    .{ .id = "code_review", .label = "Code reviewer", .text = "You are a senior code reviewer. Analyze the code for bugs, edge cases, security issues and style problems. Be specific: quote the line, explain the risk, suggest a fix." },
    .{ .id = "tool_user", .label = "Tool-using agent", .text = "You are an agent with access to tools. Prefer calling a tool over guessing facts you can look up. After a tool result, continue your answer naturally. Explain what you did in one short sentence." },
    .{ .id = "socratic", .label = "Socratic tutor", .text = "You are a Socratic tutor. Don't give the answer directly — ask guiding questions that lead the student to it. One question at a time." },
};

pub fn findSysprompt(id: []const u8) ?Sysprompt {
    for (sysprompts) |p| {
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
