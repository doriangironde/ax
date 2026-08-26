const std = @import("std");
const io_mod = @import("../shared/io.zig");
const custom_providers = @import("custom_providers.zig");

const Allocator = std.mem.Allocator;

/// A static model entry that a preset registers into providers.json. The
/// fields mirror `custom_providers.ModelEntry` without ownership.
pub const Model = struct {
    id: []const u8,
    context_window: ?u32 = null,
    max_output_tokens: ?u32 = null,
    reasoning: bool = false,
    vision: bool = false,
    file_input: bool = false,
};

/// A curated OpenAI-compatible endpoint shipped in the binary. Selecting a
/// preset that is not yet registered copies its entry into providers.json, so
/// users never hand-write the JSON for well-known endpoints. Preset entries
/// are starting points: providers.json stays authoritative and editable.
pub const Preset = struct {
    name: []const u8,
    /// Human-readable display name shown in pickers and notices.
    label: []const u8,
    base_url: []const u8,
    /// Default env var holding the API key. Null marks a keyless endpoint
    /// (for example a local Ollama server) that sends no Authorization
    /// header and never opens the inline key entry.
    api_key_env: ?[]const u8 = null,
    models: []const Model,
    /// One-line description used in listings.
    note: []const u8,
};

const opencode_go_models = [_]Model{
    .{ .id = "minimax-m3", .context_window = 200_000, .max_output_tokens = 32_768, .reasoning = true },
    .{ .id = "minimax-m2.7", .context_window = 200_000, .max_output_tokens = 32_768 },
    .{ .id = "kimi-k3", .context_window = 200_000, .max_output_tokens = 32_768, .reasoning = true },
    .{ .id = "kimi-k2.7-code", .context_window = 200_000, .max_output_tokens = 32_768 },
    .{ .id = "glm-5.3", .context_window = 200_000, .max_output_tokens = 32_768, .reasoning = true },
    .{ .id = "glm-5.2", .context_window = 200_000, .max_output_tokens = 32_768, .reasoning = true },
    .{ .id = "deepseek-v4-pro", .context_window = 200_000, .max_output_tokens = 32_768, .reasoning = true },
    .{ .id = "deepseek-v4-flash", .context_window = 200_000, .max_output_tokens = 32_768 },
    .{ .id = "deepseek-v4-flash-vision-exp", .context_window = 200_000, .max_output_tokens = 32_768, .vision = true },
    .{ .id = "qwen3.8-max", .context_window = 200_000, .max_output_tokens = 32_768, .reasoning = true },
    .{ .id = "qwen3.7-plus", .context_window = 200_000, .max_output_tokens = 32_768 },
    .{ .id = "gpt-5.6-luna", .context_window = 200_000, .max_output_tokens = 32_768 },
    .{ .id = "grok-4.5", .context_window = 200_000, .max_output_tokens = 32_768 },
};

const openrouter_models = [_]Model{
    .{ .id = "deepseek/deepseek-chat-v3-0324", .context_window = 131_072, .max_output_tokens = 8_192 },
    .{ .id = "deepseek/deepseek-reasoner", .context_window = 131_072, .max_output_tokens = 32_768, .reasoning = true },
    .{ .id = "anthropic/claude-sonnet-4.5", .context_window = 200_000, .max_output_tokens = 64_000, .vision = true },
    .{ .id = "google/gemini-2.5-flash", .context_window = 1_048_576, .max_output_tokens = 65_536, .reasoning = true, .vision = true },
    .{ .id = "qwen/qwen3-235b-a22b-instruct", .context_window = 131_072, .max_output_tokens = 8_192, .reasoning = true },
    .{ .id = "meta-llama/llama-3.3-70b-instruct", .context_window = 131_072, .max_output_tokens = 4_096 },
};

const groq_models = [_]Model{
    .{ .id = "llama-3.3-70b-versatile", .context_window = 131_072, .max_output_tokens = 32_768 },
    .{ .id = "llama-3.1-8b-instant", .context_window = 131_072, .max_output_tokens = 8_192 },
    .{ .id = "qwen-qwq-32b", .context_window = 131_072, .max_output_tokens = 32_768, .reasoning = true },
    .{ .id = "gemma2-9b-it", .context_window = 8_192, .max_output_tokens = 8_192 },
};

const deepseek_models = [_]Model{
    .{ .id = "deepseek-chat", .context_window = 131_072, .max_output_tokens = 8_192 },
    .{ .id = "deepseek-reasoner", .context_window = 131_072, .max_output_tokens = 65_536, .reasoning = true },
};

const ollama_models = [_]Model{
    .{ .id = "llama3.2", .context_window = 131_072, .max_output_tokens = 8_192 },
    .{ .id = "qwen3:8b", .context_window = 131_072, .max_output_tokens = 8_192 },
    .{ .id = "deepseek-r1:8b", .context_window = 131_072, .max_output_tokens = 8_192, .reasoning = true },
};

const together_models = [_]Model{
    .{ .id = "meta-llama/Llama-3.3-70B-Instruct-Turbo", .context_window = 131_072, .max_output_tokens = 4_096 },
    .{ .id = "deepseek-ai/DeepSeek-V3", .context_window = 131_072, .max_output_tokens = 8_192 },
    .{ .id = "Qwen/Qwen3-235B-A22B-Instruct", .context_window = 131_072, .max_output_tokens = 8_192, .reasoning = true },
    .{ .id = "meta-llama/Llama-3.2-11B-Vision-Instruct-Turbo", .context_window = 131_072, .max_output_tokens = 4_096, .vision = true },
};

const mistral_models = [_]Model{
    .{ .id = "mistral-large-latest", .context_window = 131_072, .max_output_tokens = 8_192 },
    .{ .id = "mistral-small-latest", .context_window = 131_072, .max_output_tokens = 8_192 },
    .{ .id = "codestral-latest", .context_window = 131_072, .max_output_tokens = 8_192 },
    .{ .id = "pixtral-large-latest", .context_window = 131_072, .max_output_tokens = 8_192, .vision = true },
};

const cerebras_models = [_]Model{
    .{ .id = "llama-3.3-70b", .context_window = 131_072, .max_output_tokens = 32_768 },
    .{ .id = "llama-3.1-8b", .context_window = 131_072, .max_output_tokens = 8_192 },
};

const xai_models = [_]Model{
    .{ .id = "grok-4", .context_window = 131_072, .max_output_tokens = 65_536, .reasoning = true },
    .{ .id = "grok-4-fast", .context_window = 131_072, .max_output_tokens = 65_536 },
};

const gemini_models = [_]Model{
    .{ .id = "gemini-2.5-pro", .context_window = 1_048_576, .max_output_tokens = 65_536, .reasoning = true, .vision = true },
    .{ .id = "gemini-2.5-flash", .context_window = 1_048_576, .max_output_tokens = 65_536, .reasoning = true, .vision = true },
    .{ .id = "gemini-2.5-flash-lite", .context_window = 1_048_576, .max_output_tokens = 65_536, .vision = true },
};

const perplexity_models = [_]Model{
    .{ .id = "sonar", .context_window = 131_072, .max_output_tokens = 8_192 },
    .{ .id = "sonar-pro", .context_window = 200_000, .max_output_tokens = 8_192, .reasoning = true },
    .{ .id = "sonar-reasoning", .context_window = 200_000, .max_output_tokens = 8_192, .reasoning = true },
};

const moonshot_models = [_]Model{
    .{ .id = "kimi-k2-0711-preview", .context_window = 131_072, .max_output_tokens = 32_768, .reasoning = true },
    .{ .id = "kimi-k2-turbo-preview", .context_window = 131_072, .max_output_tokens = 32_768, .reasoning = true },
};

pub const presets = [_]Preset{
    .{
        .name = "opencode-go",
        .label = "OpenCode Go",
        .base_url = "https://opencode.ai/zen/go/v1",
        .api_key_env = "OPENCODE_GO_API_KEY",
        .models = &opencode_go_models,
        .note = "Flat-rate OpenCode Go subscription catalog",
    },
    .{
        .name = "openrouter",
        .label = "OpenRouter",
        .base_url = "https://openrouter.ai/api/v1",
        .api_key_env = "OPENROUTER_API_KEY",
        .models = &openrouter_models,
        .note = "Aggregator with hundreds of hosted models",
    },
    .{
        .name = "groq",
        .label = "Groq",
        .base_url = "https://api.groq.com/openai/v1",
        .api_key_env = "GROQ_API_KEY",
        .models = &groq_models,
        .note = "Fast inference for Llama and other open models",
    },
    .{
        .name = "deepseek",
        .label = "DeepSeek",
        .base_url = "https://api.deepseek.com/v1",
        .api_key_env = "DEEPSEEK_API_KEY",
        .models = &deepseek_models,
        .note = "Official DeepSeek chat and reasoning models",
    },
    .{
        .name = "ollama",
        .label = "Ollama",
        .base_url = "http://localhost:11434/v1",
        .models = &ollama_models,
        .note = "Local models through the Ollama server, no API key",
    },
    .{
        .name = "together",
        .label = "Together AI",
        .base_url = "https://api.together.xyz/v1",
        .api_key_env = "TOGETHER_API_KEY",
        .models = &together_models,
        .note = "Cloud inference for open-weight models",
    },
    .{
        .name = "mistral",
        .label = "Mistral",
        .base_url = "https://api.mistral.ai/v1",
        .api_key_env = "MISTRAL_API_KEY",
        .models = &mistral_models,
        .note = "Mistral La Plateforme models",
    },
    .{
        .name = "cerebras",
        .label = "Cerebras",
        .base_url = "https://api.cerebras.ai/v1",
        .api_key_env = "CEREBRAS_API_KEY",
        .models = &cerebras_models,
        .note = "Fast Llama inference at scale",
    },
    .{
        .name = "xai",
        .label = "xAI",
        .base_url = "https://api.x.ai/v1",
        .api_key_env = "XAI_API_KEY",
        .models = &xai_models,
        .note = "Grok models through the xAI API",
    },
    .{
        .name = "gemini",
        .label = "Gemini",
        .base_url = "https://generativelanguage.googleapis.com/v1beta/openai",
        .api_key_env = "GEMINI_API_KEY",
        .models = &gemini_models,
        .note = "Google Gemini through its OpenAI-compatible endpoint",
    },
    .{
        .name = "perplexity",
        .label = "Perplexity",
        .base_url = "https://api.perplexity.ai",
        .api_key_env = "PERPLEXITY_API_KEY",
        .models = &perplexity_models,
        .note = "Sonar search-grounded models",
    },
    .{
        .name = "moonshot",
        .label = "Moonshot",
        .base_url = "https://api.moonshot.cn/v1",
        .api_key_env = "MOONSHOT_API_KEY",
        .models = &moonshot_models,
        .note = "Kimi models from Moonshot AI",
    },
};

/// Finds a preset by name, or null when the name is not a preset.
pub fn presetNamed(name: []const u8) ?*const Preset {
    for (&presets) |*preset| {
        if (std.mem.eql(u8, preset.name, name)) return preset;
    }
    return null;
}

/// Space-joined preset names for help text and listings.
pub const names_line: []const u8 = blk: {
    var joined: []const u8 = ""; // comptime-only accumulator
    for (&presets, 0..) |preset, index| {
        joined = if (index == 0) preset.name else joined ++ " " ++ preset.name;
    }
    break :blk joined;
};

pub const Registration = enum {
    /// The preset entry was appended to providers.json.
    registered,
    /// A provider with the same name already exists; the file is untouched.
    already_present,
};

/// Wire shapes written into providers.json. Entries are written through
/// std.json.Stringify without null optional fields, matching what the registry
/// parser accepts.
const WireModel = struct {
    id: []const u8,
    context_window: ?u32 = null,
    max_output_tokens: ?u32 = null,
    reasoning: bool = false,
    vision: bool = false,
    file_input: bool = false,
};

/// Registers a preset entry into `~/.fx/providers.json`, preserving every
/// other entry verbatim. An absent file starts a fresh registry document; a
/// provider with the preset's name already present leaves the file untouched.
/// Writes atomically with private permissions, like inline key storage.
pub fn registerPreset(
    alloc: Allocator,
    home_dir: []const u8,
    preset: *const Preset,
) !Registration {
    // Everything the registry document touches (the parsed tree, appended
    // entry keys, the serialized payload) lives in one request arena so any
    // early return cannot leak.
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const path = try custom_providers.providersPath(arena, home_dir);
    var root: *std.json.Value = undefined;
    var fresh = std.json.Value{ .object = std.json.ObjectMap{} };
    if (std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{ .mode = .read_only })) |opened| {
        var file = opened;
        defer file.close(io_mod.getIo());
        const bytes = try io_mod.readFileToEnd(arena, &file, custom_providers.max_registry_bytes);
        var parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidCustomProvidersConfig,
        };
        if (parsed != .object) return error.InvalidCustomProvidersConfig;
        root = &parsed;
    } else |err| switch (err) {
        error.FileNotFound => {
            root = &fresh;
        },
        else => return err,
    }

    if (root.object.getPtr("providers") == null) {
        try root.object.put(arena, "providers", .{ .array = std.json.Array.init(arena) });
    }
    const providers_ref = root.object.getPtr("providers").?;
    if (providers_ref.* != .array) return error.InvalidCustomProvidersConfig;
    for (providers_ref.array.items) |item| {
        if (item != .object) continue;
        const name_value = item.object.get("name") orelse continue;
        if (name_value != .string or !std.mem.eql(u8, name_value.string, preset.name)) continue;
        return .already_present;
    }
    if (providers_ref.array.items.len >= custom_providers.max_providers) {
        return error.CustomProviderLimitExceeded;
    }

    var wire_models: std.ArrayList(WireModel) = .empty;
    defer wire_models.deinit(arena);
    try wire_models.ensureTotalCapacity(arena, preset.models.len);
    for (preset.models) |model| {
        try wire_models.append(arena, .{
            .id = model.id,
            .context_window = model.context_window,
            .max_output_tokens = model.max_output_tokens,
            .reasoning = model.reasoning,
            .vision = model.vision,
            .file_input = model.file_input,
        });
    }
    try providers_ref.array.append(.{ .object = std.json.ObjectMap{} });
    const entry_object = &providers_ref.array.items[providers_ref.array.items.len - 1].object;
    try entry_object.put(arena, "name", .{ .string = preset.name });
    try entry_object.put(arena, "base_url", .{ .string = preset.base_url });
    try entry_object.put(arena, "api_type", .{ .string = "openai-completions" });
    if (preset.api_key_env) |env| {
        try entry_object.put(arena, "api_key_env", .{ .string = env });
    } else {
        try entry_object.put(arena, "keyless", .{ .bool = true });
    }
    try entry_object.put(arena, "models", .{ .array = std.json.Array.init(arena) });
    const models_value = entry_object.getPtr("models").?;
    for (wire_models.items) |model| {
        var object = std.json.ObjectMap{};
        // Ownership transfers to the tree when appended; the arena frees it.
        try object.put(arena, "id", .{ .string = model.id });
        if (model.context_window) |value| try object.put(arena, "context_window", .{ .integer = @intCast(value) });
        if (model.max_output_tokens) |value| try object.put(arena, "max_output_tokens", .{ .integer = @intCast(value) });
        if (model.reasoning) try object.put(arena, "reasoning", .{ .bool = true });
        if (model.vision) try object.put(arena, "vision", .{ .bool = true });
        if (model.file_input) try object.put(arena, "file_input", .{ .bool = true });
        try models_value.array.append(.{ .object = object });
    }

    var out: std.Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(root.*, .{ .emit_null_optional_fields = false }, &out.writer);

    const tmp_path = try std.fmt.allocPrint(arena, "{s}.tmp", .{path});
    // Registration must work when ~/.fx does not exist yet: keep the parent
    // directory present so the atomic rename below cannot fail on it.
    if (std.fs.path.dirname(path)) |parent| try io_mod.makeDirRecursive(parent);
    var tmp_file = try std.Io.Dir.createFileAbsolute(io_mod.getIo(), tmp_path, .{
        .truncate = true,
        .permissions = std.Io.File.Permissions.fromMode(0o600),
    });
    defer tmp_file.close(io_mod.getIo());
    try tmp_file.writeStreamingAll(io_mod.getIo(), out.written());
    try std.Io.Dir.renameAbsolute(tmp_path, path, io_mod.getIo());
    return .registered;
}

test "preset catalog names are unique and valid registry names" {
    for (&presets, 0..) |*preset, index| {
        try std.testing.expect(custom_providers.validName(preset.name));
        try std.testing.expect(preset.label.len > 0);
        try std.testing.expect(std.mem.find(u8, preset.base_url, "://") != null);
        try std.testing.expect(preset.models.len > 0);
        for (preset.models) |model| {
            try std.testing.expect(model.id.len > 0);
        }
        for (presets[0..index]) |*earlier| {
            try std.testing.expect(!std.mem.eql(u8, earlier.name, preset.name));
        }
        if (preset.api_key_env) |env| {
            try std.testing.expect(env.len > 0);
            for (env) |byte| {
                try std.testing.expect(std.ascii.isAlphanumeric(byte) or byte == '_');
            }
        }
    }
    try std.testing.expectEqualStrings("OpenCode Go", presetNamed("opencode-go").?.label);
    try std.testing.expectEqualStrings("OpenRouter", presetNamed("openrouter").?.label);
    try std.testing.expectEqualStrings("Ollama", presetNamed("ollama").?.label);
    try std.testing.expect(presetNamed("missing") == null);
}

test "registerPreset writes a new providers file" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "");
    defer alloc.free(home);
    try tmp.dir.createDirPath(io_mod.getIo(), ".fx");

    const preset = presetNamed("openrouter").?;
    try std.testing.expectEqual(Registration.registered, try registerPreset(alloc, home, preset));
    var registry = try custom_providers.load(alloc, home);
    defer registry.deinit(alloc);
    const entry = registry.find("openrouter").?;
    try std.testing.expectEqualStrings("https://openrouter.ai/api/v1", entry.base_url);
    try std.testing.expectEqualStrings("OPENROUTER_API_KEY", entry.api_key_env.?);
    try std.testing.expect(!entry.keyless);
    try std.testing.expectEqual(@as(usize, openrouter_models.len), entry.models.items.len);
    try std.testing.expectEqualStrings("deepseek/deepseek-chat-v3-0324", entry.models.items[0].id);
    try std.testing.expect(entry.models.items[1].reasoning);
    try std.testing.expect(entry.models.items[3].vision);
}

test "registerPreset merges with existing entries and marks keyless providers" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "");
    defer alloc.free(home);
    try tmp.dir.createDirPath(io_mod.getIo(), ".fx");
    const path = try std.fs.path.join(alloc, &.{ home, ".fx", "providers.json" });
    defer alloc.free(path);
    var file = try std.Io.Dir.createFileAbsolute(io_mod.getIo(), path, .{ .truncate = true });
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(
        io_mod.getIo(),
        "{\"providers\":[{\"name\":\"opencode-go\",\"base_url\":\"https://opencode.ai/zen/go/v1\"," ++
            "\"api_key\":\"sk-keep\",\"models\":[{\"id\":\"glm-5.2\"}]}]}",
    );

    try std.testing.expectEqual(Registration.registered, try registerPreset(alloc, home, presetNamed("ollama").?));
    var registry = try custom_providers.load(alloc, home);
    defer registry.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), registry.entries.items.len);
    const ollama = registry.find("ollama").?;
    try std.testing.expectEqualStrings("http://localhost:11434/v1", ollama.base_url);
    try std.testing.expect(ollama.keyless);
    try std.testing.expect(ollama.api_key_env == null);
    try std.testing.expect(ollama.api_key == null);
    // The untouched entry keeps its inline key.
    try std.testing.expectEqualStrings("sk-keep", registry.find("opencode-go").?.api_key.?);

    // Registration again is a no-op and keeps the document unchanged.
    const path2 = try std.fs.path.join(alloc, &.{ home, ".fx", "providers.json" });
    defer alloc.free(path2);
    var file2 = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), path2, .{ .mode = .read_only });
    defer file2.close(io_mod.getIo());
    const before = try io_mod.readFileToEnd(alloc, &file2, custom_providers.max_registry_bytes);
    defer alloc.free(before);
    try std.testing.expectEqual(Registration.already_present, try registerPreset(alloc, home, presetNamed("ollama").?));
    var file3 = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), path2, .{ .mode = .read_only });
    defer file3.close(io_mod.getIo());
    const after = try io_mod.readFileToEnd(alloc, &file3, custom_providers.max_registry_bytes);
    defer alloc.free(after);
    try std.testing.expectEqualStrings(before, after);
}

test "registerPreset rejects a malformed providers document" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "");
    defer alloc.free(home);
    try tmp.dir.createDirPath(io_mod.getIo(), ".fx");
    const path = try std.fs.path.join(alloc, &.{ home, ".fx", "providers.json" });
    defer alloc.free(path);
    var file = try std.Io.Dir.createFileAbsolute(io_mod.getIo(), path, .{ .truncate = true });
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(), "not json");

    try std.testing.expectError(
        error.InvalidCustomProvidersConfig,
        registerPreset(alloc, home, presetNamed("groq").?),
    );
}
