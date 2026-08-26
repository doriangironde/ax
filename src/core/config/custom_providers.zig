const std = @import("std");
const io_mod = @import("../shared/io.zig");
const model_catalog = @import("../gateway/model_catalog.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;

pub const providers_file_name = "providers.json";

/// The env var that overrides where the custom provider registry is read from.
/// Absolute path to a providers.json file. Test-only and diagnostics use it;
/// normal operation resolves `~/.fx/providers.json` from HOME.
pub const path_env = "FX_CUSTOM_PROVIDERS_PATH";

/// Wire protocol families a registered provider endpoint may speak. The
/// endpoint is the API root; ax appends the protocol-specific request path.
pub const ApiType = enum {
    /// OpenAI Chat Completions (`/chat/completions`). Covers OpenAI-compatible
    /// servers, OpenCode Go, OpenRouter, Ollama, vLLM, and LM Studio.
    openai_completions,

    pub fn parse(value: []const u8) ?ApiType {
        if (std.ascii.eqlIgnoreCase(value, "openai") or
            std.ascii.eqlIgnoreCase(value, "openai-completions") or
            std.ascii.eqlIgnoreCase(value, "chat-completions"))
        {
            return .openai_completions;
        }
        return null;
    }
};

pub const max_name_bytes: usize = 64;
pub const max_base_url_bytes: usize = 2048;
pub const max_key_env_bytes: usize = 128;
pub const max_registry_bytes: usize = 1024 * 1024;
pub const max_providers: usize = 64;
pub const max_models_per_provider: usize = 512;

pub const ModelEntry = struct {
    id: []u8,
    context_window: ?u32 = null,
    max_output_tokens: ?u32 = null,
    reasoning: bool = false,
    vision: bool = false,
    file_input: bool = false,

    pub fn deinit(self: *ModelEntry, alloc: Allocator) void {
        alloc.free(self.id);
        self.* = undefined;
    }
};

pub const Entry = struct {
    name: []u8,
    base_url: []u8,
    api_type: ApiType = .openai_completions,
    /// Inline key. Prefer `api_key_env`; this stays out of the registry when
    /// the key is held in the environment.
    api_key: ?[]u8 = null,
    api_key_env: ?[]u8 = null,
    /// True when the endpoint accepts unauthenticated requests (for example a
    /// local Ollama server). Keyless entries send no Authorization header and
    /// never open the inline key entry.
    keyless: bool = false,
    models: std.ArrayList(ModelEntry) = .empty,

    pub fn deinit(self: *Entry, alloc: Allocator) void {
        alloc.free(self.name);
        alloc.free(self.base_url);
        if (self.api_key) |value| alloc.free(value);
        if (self.api_key_env) |value| alloc.free(value);
        for (self.models.items) |*model| model.deinit(alloc);
        self.models.deinit(alloc);
        self.* = undefined;
    }

    pub fn defaultModelId(self: *const Entry) ?[]const u8 {
        if (self.models.items.len == 0) return null;
        return self.models.items[0].id;
    }

    /// The resolved key bytes when the provider declares one, borrowed from
    /// the environment or the inline key. The secret is not owned by this
    /// module.
    pub fn apiKeyBytes(self: *const Entry) ?[]const u8 {
        if (self.api_key_env) |name| {
            const raw = io_mod.getenv(name) orelse return null;
            const trimmed = std.mem.trim(u8, raw, " \t\r\n");
            if (trimmed.len == 0) return null;
            return trimmed;
        }
        if (self.api_key) |key| return key;
        return null;
    }

    /// Whether the provider can be used as configured: it either declares a
    /// usable key (inline or via the environment) or is explicitly keyless.
    pub fn usableKey(self: *const Entry) bool {
        return self.keyless or self.apiKeyBytes() != null;
    }
};

pub const Registry = struct {
    entries: std.ArrayList(Entry) = .empty,

    pub fn deinit(self: *Registry, alloc: Allocator) void {
        for (self.entries.items) |*entry| entry.deinit(alloc);
        self.entries.deinit(alloc);
        self.* = undefined;
    }

    pub fn find(self: *const Registry, name: []const u8) ?*const Entry {
        for (self.entries.items) |*entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry;
        }
        return null;
    }

    pub fn contains(self: *const Registry, name: []const u8) bool {
        return self.find(name) != null;
    }
};

/// Resolves the providers.json path. `FX_CUSTOM_PROVIDERS_PATH` wins; the
/// default is `~/.fx/providers.json`.
pub fn providersPath(alloc: Allocator, home_dir: []const u8) ![]u8 {
    if (io_mod.getenv(path_env)) |override| return alloc.dupe(u8, override);
    return std.fs.path.join(alloc, &.{ home_dir, ".fx", providers_file_name });
}

/// Loads the registry. An absent file is an empty registry; a malformed file
/// is an error the caller decides how to surface. Entries are owned by the
/// returned Registry.
pub fn load(alloc: Allocator, home_dir: []const u8) !Registry {
    const path = try providersPath(alloc, home_dir);
    defer alloc.free(path);
    return loadFromPath(alloc, path);
}

pub fn loadFromPath(alloc: Allocator, path: []const u8) !Registry {
    var file = std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{ .mode = .read_only }) catch |err| switch (err) {
        // An absent file is an empty registry.
        error.FileNotFound => return .{},
        else => return err,
    };
    defer file.close(io_mod.getIo());
    const bytes = try io_mod.readFileToEnd(alloc, &file, max_registry_bytes);
    defer alloc.free(bytes);
    return parse(alloc, bytes);
}

/// Parses a registry document. Unknown keys and unknown api types are ignored
/// so the file stays forward-compatible; structural errors reject the entry.
pub fn parse(alloc: Allocator, bytes: []const u8) !Registry {
    var registry: Registry = .{};
    errdefer registry.deinit(alloc);

    var parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidCustomProvidersConfig,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidCustomProvidersConfig;
    const providers_value = parsed.value.object.get("providers") orelse return registry;
    if (providers_value != .array) return error.InvalidCustomProvidersConfig;

    for (providers_value.array.items) |item| {
        if (item != .object) return error.InvalidCustomProvidersConfig;
        var entry = parseEntry(alloc, item.object) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };
        errdefer entry.deinit(alloc);
        if (registry.find(entry.name) != null) {
            entry.deinit(alloc);
            continue;
        }
        if (registry.entries.items.len >= max_providers) {
            entry.deinit(alloc);
            continue;
        }
        try registry.entries.append(alloc, entry);
    }
    return registry;
}

fn stringField(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    if (value != .string) return null;
    return value.string;
}

fn parseEntry(alloc: Allocator, object: std.json.ObjectMap) !Entry {
    const name = stringField(object, "name") orelse return error.InvalidCustomProviderEntry;
    if (!validName(name)) return error.InvalidCustomProviderEntry;
    const base_url = stringField(object, "base_url") orelse
        stringField(object, "baseUrl") orelse return error.InvalidCustomProviderEntry;
    if (!validBaseUrl(base_url)) return error.InvalidCustomProviderEntry;

    var entry = Entry{
        .name = try alloc.dupe(u8, name),
        .base_url = try alloc.dupe(u8, base_url),
    };
    errdefer entry.deinit(alloc);

    const api_type = stringField(object, "api_type") orelse
        stringField(object, "apiType") orelse "openai-completions";
    entry.api_type = ApiType.parse(api_type) orelse return error.InvalidCustomProviderEntry;
    if (boolField(object, "keyless")) |value| entry.keyless = value;
    if (stringField(object, "api_key")) |key| entry.api_key = try alloc.dupe(u8, key);
    if (stringField(object, "api_key_env")) |name_value| {
        if (!validEnvName(name_value)) return error.InvalidCustomProviderEntry;
        entry.api_key_env = try alloc.dupe(u8, name_value);
    } else if (stringField(object, "apiKeyEnv")) |name_value| {
        if (!validEnvName(name_value)) return error.InvalidCustomProviderEntry;
        entry.api_key_env = try alloc.dupe(u8, name_value);
    }

    const models_value = object.get("models") orelse return error.InvalidCustomProviderEntry;
    if (models_value != .array or models_value.array.items.len == 0) {
        return error.InvalidCustomProviderEntry;
    }
    for (models_value.array.items) |model_item| {
        if (model_item != .object) return error.InvalidCustomProviderEntry;
        const id = stringField(model_item.object, "id") orelse return error.InvalidCustomProviderEntry;
        if (id.len == 0 or id.len > 1024) return error.InvalidCustomProviderEntry;
        var model = ModelEntry{
            .id = try alloc.dupe(u8, id),
        };
        errdefer model.deinit(alloc);
        if (boolField(model_item.object, "reasoning")) |value| model.reasoning = value;
        if (boolField(model_item.object, "vision")) |value| model.vision = value;
        if (boolField(model_item.object, "file_input")) |value| model.file_input = value;
        if (unsignedField(model_item.object, "context_window")) |value| model.context_window = value;
        if (unsignedField(model_item.object, "max_output_tokens")) |value| model.max_output_tokens = value;
        if (entry.models.items.len >= max_models_per_provider) return error.InvalidCustomProviderEntry;
        try entry.models.append(alloc, model);
    }
    return entry;
}

fn boolField(object: std.json.ObjectMap, key: []const u8) ?bool {
    const value = object.get(key) orelse return null;
    if (value != .bool) return null;
    return value.bool;
}

fn unsignedField(object: std.json.ObjectMap, key: []const u8) ?u32 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .integer => |integer| if (integer >= 0 and integer <= std.math.maxInt(u32))
            @intCast(integer)
        else
            null,
        .float => |float| if (float >= 0 and float <= std.math.maxInt(u32))
            @intFromFloat(float)
        else
            null,
        else => null,
    };
}

pub fn validName(value: []const u8) bool {
    if (value.len == 0 or value.len > max_name_bytes) return false;
    var seen_lower = false;
    for (value) |byte| {
        if (std.ascii.isAlphanumeric(byte)) {
            if (std.ascii.isUpper(byte)) return false;
            seen_lower = true;
        } else if (byte == '-') {
            continue;
        } else {
            return false;
        }
    }
    return seen_lower;
}

fn validEnvName(value: []const u8) bool {
    if (value.len == 0 or value.len > max_key_env_bytes) return false;
    for (value) |byte| {
        if (!(std.ascii.isAlphanumeric(byte) or byte == '_')) return false;
    }
    return true;
}

fn validBaseUrl(value: []const u8) bool {
    if (value.len == 0 or value.len > max_base_url_bytes) return false;
    if (std.mem.indexOf(u8, value, "://") == null) return false;
    return true;
}

pub const EnvLookup = *const fn (name: []const u8) ?[]const u8;

/// Stores an inline key for a registered provider, clearing any env reference
/// so the stored key is authoritative. Writes atomically with private
/// permissions. The provider file must already exist (the picker only lists
/// providers it loaded from there).
pub fn storeApiKey(
    alloc: Allocator,
    home_dir: []const u8,
    provider_name: []const u8,
    key: []const u8,
) !void {
    const path = try providersPath(alloc, home_dir);
    defer alloc.free(path);
    var file = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{ .mode = .read_only });
    defer file.close(io_mod.getIo());
    const bytes = try io_mod.readFileToEnd(alloc, &file, max_registry_bytes);
    defer alloc.free(bytes);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidCustomProvidersConfig;
    const providers_value = parsed.value.object.getPtr("providers") orelse
        return error.InvalidCustomProvidersConfig;
    if (providers_value.* != .array) return error.InvalidCustomProvidersConfig;
    var found = false;
    for (providers_value.array.items) |*item| {
        if (item.* != .object) continue;
        const name_value = item.object.get("name") orelse continue;
        if (name_value != .string or !std.mem.eql(u8, name_value.string, provider_name)) continue;
        try item.object.put(alloc, "api_key", .{ .string = key });
        _ = item.object.orderedRemove("api_key_env");
        _ = item.object.orderedRemove("apiKeyEnv");
        found = true;
        break;
    }
    if (!found) return error.CustomProviderNotFound;

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try std.json.Stringify.value(parsed.value, .{}, &out.writer);

    const tmp_path = try std.fmt.allocPrint(alloc, "{s}.tmp", .{path});
    defer alloc.free(tmp_path);
    var tmp_file = try std.Io.Dir.createFileAbsolute(io_mod.getIo(), tmp_path, .{
        .truncate = true,
        .permissions = std.Io.File.Permissions.fromMode(0o600),
    });
    defer tmp_file.close(io_mod.getIo());
    try tmp_file.writeStreamingAll(io_mod.getIo(), out.written());
    try std.Io.Dir.renameAbsolute(tmp_path, path, io_mod.getIo());
}

test "storeApiKey writes an inline key and clears the env reference" {
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
            "\"api_key_env\":\"OPENCODE_GO_API_KEY\",\"models\":[{\"id\":\"glm-5.2\"}]}," ++
            "{\"name\":\"other\",\"base_url\":\"https://other.test\",\"models\":[{\"id\":\"m\"}]}]}",
    );

    try storeApiKey(alloc, home, "opencode-go", "sk-live-key-123");
    var registry = try load(alloc, home);
    defer registry.deinit(alloc);
    const entry = registry.find("opencode-go").?;
    try std.testing.expectEqualStrings("sk-live-key-123", entry.api_key.?);
    try std.testing.expect(entry.api_key_env == null);
    // The untouched sibling entry keeps its shape.
    try std.testing.expect(registry.find("other").?.api_key == null);

    // Round trip through the file, not just the parsed copy.
    var file2 = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{ .mode = .read_only });
    defer file2.close(io_mod.getIo());
    const on_disk = try io_mod.readFileToEnd(alloc, &file2, 4096);
    defer alloc.free(on_disk);
    try std.testing.expect(std.mem.find(u8, on_disk, "\"api_key\":\"sk-live-key-123\"") != null);
    try std.testing.expect(std.mem.find(u8, on_disk, "api_key_env") == null);
}

test "storeApiKey rejects an unknown provider name" {
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
        "{\"providers\":[{\"name\":\"mock\",\"base_url\":\"http://127.0.0.1:1/v1\",\"models\":[{\"id\":\"m\"}]}]}",
    );
    try std.testing.expectError(
        error.CustomProviderNotFound,
        storeApiKey(alloc, home, "missing", "key"),
    );
}

/// Resolves the configured key for an entry: the env reference wins, then the
/// inline key. Returns null when the provider declares no usable key.
pub fn resolveApiKey(alloc: Allocator, entry: *const Entry) !?[]u8 {
    return resolveApiKeyWith(alloc, entry, io_mod.getenv);
}

/// Testable variant: `lookup` answers env references so key precedence can be
/// asserted without mutating the process environment.
pub fn resolveApiKeyWith(alloc: Allocator, entry: *const Entry, lookup: EnvLookup) !?[]u8 {
    if (entry.api_key_env) |name| {
        const raw = lookup(name) orelse return null;
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        if (trimmed.len == 0) return null;
        return try alloc.dupe(u8, trimmed);
    }
    if (entry.api_key) |key| return try alloc.dupe(u8, key);
    return null;
}

fn modelCatalogEntryFor(alloc: Allocator, model: *const ModelEntry) !model_catalog.ModelCatalogEntry {
    const id = try alloc.dupe(u8, model.id);
    errdefer alloc.free(id);
    const model_type = try alloc.dupe(u8, if (model.reasoning) "reasoning" else "language");
    errdefer alloc.free(model_type);
    const reasoning_efforts = try modelCatalogReasoningEfforts(alloc, model.reasoning);
    errdefer reasoning_efforts.deinit(alloc);
    return .{
        .id = id,
        .model_type = model_type,
        .has_tool_use = true,
        .has_reasoning = model.reasoning,
        .reasoning_efforts = reasoning_efforts,
        .has_vision = model.vision,
        .has_file_input = model.file_input,
        .context_window = model.context_window orelse 0,
        .max_tokens = model.max_output_tokens orelse 0,
    };
}

fn modelCatalogReasoningEfforts(
    alloc: Allocator,
    reasoning: bool,
) !std.ArrayList(types.ReasoningEffort) {
    var efforts: std.ArrayList(types.ReasoningEffort) = .empty;
    errdefer efforts.deinit(alloc);
    if (reasoning) {
        try efforts.append(alloc, types.ReasoningEffort.literal("minimal"));
        try efforts.append(alloc, types.ReasoningEffort.literal("high"));
    }
    return efforts;
}

/// Context held by the caller (the app) for the lifetime of the provider
/// routes. `provider_name` is borrowed from the registry.
pub const StaticCatalogContext = struct {
    registry: *const Registry,
    provider_name: []const u8,
};

/// A static model-catalog provider that serves the registered model list for
/// `provider_name`. The fetch never touches the network; it answers from the
/// registry owned by the caller.
pub fn staticCatalogProvider(context: *const StaticCatalogContext) model_catalog.Provider {
    return .{
        .context = @constCast(context),
        .fetch_fn = fetchStaticCatalog,
    };
}

fn fetchStaticCatalog(
    raw: ?*anyopaque,
    alloc: Allocator,
    input: model_catalog.FetchInput,
) Allocator.Error!model_catalog.ProviderResult {
    const context: *const StaticCatalogContext = @ptrCast(@alignCast(raw.?));
    _ = input;
    const entry = context.registry.find(context.provider_name) orelse
        return .{ .failure = .{ .category = .runtime } };
    var catalog: std.ArrayList(model_catalog.ModelCatalogEntry) = .empty;
    errdefer model_catalog.freeModelCatalog(alloc, &catalog);
    try catalog.ensureTotalCapacity(alloc, entry.models.items.len);
    for (entry.models.items) |*model| {
        const catalog_entry = try modelCatalogEntryFor(alloc, model);
        catalog.append(alloc, catalog_entry) catch |err| {
            model_catalog.freeModelCatalogEntry(alloc, catalog_entry);
            return err;
        };
    }
    return .{ .catalog = catalog };
}

test "static catalog serves the registered model list with capability metadata" {
    const alloc = std.testing.allocator;
    const bytes =
        "{\"providers\":[{\"name\":\"local\",\"base_url\":\"http://127.0.0.1:1234/v1\"," ++
        "\"models\":[{\"id\":\"plain\",\"context_window\":8000}," ++
        "{\"id\":\"thinker\",\"context_window\":200000,\"reasoning\":true,\"vision\":true," ++
        "\"max_output_tokens\":32768}]}]}";
    var registry = try parse(alloc, bytes);
    defer registry.deinit(alloc);
    var context = StaticCatalogContext{ .registry = &registry, .provider_name = "local" };
    const provider = staticCatalogProvider(&context);

    var result = try provider.fetch(alloc, .{ .endpoint = "" });
    defer model_catalog.freeModelCatalog(alloc, &result.catalog);
    const catalog = &result.catalog;
    try std.testing.expectEqual(@as(usize, 2), catalog.items.len);
    try std.testing.expectEqualStrings("plain", catalog.items[0].id);
    try std.testing.expectEqual(@as(u32, 8_000), catalog.items[0].context_window);
    try std.testing.expect(!catalog.items[0].has_reasoning);
    try std.testing.expect(catalog.items[0].has_tool_use);
    try std.testing.expect(catalog.items[1].has_reasoning);
    try std.testing.expect(catalog.items[1].has_vision);
    try std.testing.expectEqual(@as(u32, 32_768), catalog.items[1].max_tokens);
    try std.testing.expectEqual(@as(usize, 2), catalog.items[1].reasoning_efforts.items.len);

    var missing_context = StaticCatalogContext{ .registry = &registry, .provider_name = "gone" };
    const missing_result = try staticCatalogProvider(&missing_context).fetch(alloc, .{ .endpoint = "" });
    try std.testing.expectEqual(model_catalog.FailureCategory.runtime, missing_result.failure.category);
}

test "provider names reject slashes uppercase and empty values" {
    try std.testing.expect(validName("opencode-go"));
    try std.testing.expect(validName("a1"));
    try std.testing.expect(!validName("OpencodeGo"));
    try std.testing.expect(!validName("open/code"));
    try std.testing.expect(!validName(""));
    try std.testing.expect(!validName("has space"));
    try std.testing.expect(!validName("_"));
}

test "registry parses a complete document and owns its entries" {
    const alloc = std.testing.allocator;
    const bytes =
        "{\"providers\":[{\"name\":\"opencode-go\",\"base_url\":\"https://opencode.ai/zen/go/v1\"," ++
        "\"api_key_env\":\"OPENCODE_GO_API_KEY\",\"api_type\":\"openai-completions\"," ++
        "\"models\":[{\"id\":\"glm-4.6\",\"context_window\":200000,\"reasoning\":true," ++
        "\"vision\":true,\"max_output_tokens\":32768},{\"id\":\"deepseek-v4\",\"reasoning\":false}]}]}";
    var registry = try parse(alloc, bytes);
    defer registry.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), registry.entries.items.len);
    const entry = registry.find("opencode-go").?;
    try std.testing.expectEqualStrings("https://opencode.ai/zen/go/v1", entry.base_url);
    try std.testing.expectEqualStrings("OPENCODE_GO_API_KEY", entry.api_key_env.?);
    try std.testing.expectEqual(@as(?[]u8, null), entry.api_key);
    try std.testing.expectEqual(ApiType.openai_completions, entry.api_type);
    try std.testing.expectEqual(@as(usize, 2), entry.models.items.len);
    try std.testing.expectEqualStrings("glm-4.6", entry.models.items[0].id);
    try std.testing.expectEqual(@as(?u32, 200_000), entry.models.items[0].context_window);
    try std.testing.expect(entry.models.items[0].reasoning);
    try std.testing.expect(entry.models.items[0].vision);
    try std.testing.expectEqual(@as(?u32, 32_768), entry.models.items[0].max_output_tokens);
    try std.testing.expect(!entry.models.items[1].reasoning);
    try std.testing.expectEqualStrings("glm-4.6", entry.defaultModelId().?);
    try std.testing.expect(registry.find("missing") == null);
}

test "registry tolerates unknown fields and skips unsupported entries" {
    const alloc = std.testing.allocator;
    const bytes =
        "{\"providers\":[" ++
        "{\"name\":\"bad\",\"base_url\":\"not-a-url\",\"models\":[{\"id\":\"m\"}]}," ++
        "{\"name\":\"future\",\"base_url\":\"https://example.test/v1\",\"future_key\":1," ++
        "\"api_type\":\"future-protocol\",\"models\":[{\"id\":\"m1\"}]}," ++
        "{\"name\":\"good\",\"base_url\":\"https://example.test/v1\",\"future_key\":1," ++
        "\"models\":[{\"id\":\"m1\"}]}]}";
    var registry = try parse(alloc, bytes);
    defer registry.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), registry.entries.items.len);
    try std.testing.expect(registry.find("good") != null);
    try std.testing.expect(registry.find("bad") == null);
    try std.testing.expect(registry.find("future") == null);
}

test "registry rejects duplicate names keeping the first entry" {
    const alloc = std.testing.allocator;
    const bytes =
        "{\"providers\":[" ++
        "{\"name\":\"dup\",\"base_url\":\"https://a.test\",\"models\":[{\"id\":\"m1\"}]}," ++
        "{\"name\":\"dup\",\"base_url\":\"https://b.test\",\"models\":[{\"id\":\"m2\"}]}]}";
    var registry = try parse(alloc, bytes);
    defer registry.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), registry.entries.items.len);
    try std.testing.expectEqualStrings("https://a.test", registry.find("dup").?.base_url);
}

test "registry loads from a home directory providers file" {
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
        "{\"providers\":[{\"name\":\"local\",\"base_url\":\"http://127.0.0.1:1234/v1\"," ++
            "\"api_key\":\"secret\",\"models\":[{\"id\":\"local-model\"}]}]}",
    );

    var registry = try load(alloc, home);
    defer registry.deinit(alloc);
    const entry = registry.find("local").?;
    try std.testing.expectEqualStrings("secret", entry.api_key.?);
    try std.testing.expectEqualStrings("local-model", entry.defaultModelId().?);
}

test "registry parses keyless entries and usableKey follows the flag" {
    const alloc = std.testing.allocator;
    const bytes =
        "{\"providers\":[" ++
        "{\"name\":\"keyless\",\"base_url\":\"http://localhost:11434/v1\",\"keyless\":true," ++
        "\"models\":[{\"id\":\"llama3.2\"}]}," ++
        "{\"name\":\"keyed\",\"base_url\":\"https://k.test\",\"api_key_env\":\"FX_CUSTOM_PROVIDERS_TEST_KEY\"," ++
        "\"models\":[{\"id\":\"m\"}]}," ++
        "{\"name\":\"empty\",\"base_url\":\"https://e.test\",\"models\":[{\"id\":\"m\"}]}]}";
    var registry = try parse(alloc, bytes);
    defer registry.deinit(alloc);

    const keyless = registry.find("keyless").?;
    try std.testing.expect(keyless.keyless);
    try std.testing.expect(keyless.api_key == null);
    try std.testing.expect(keyless.api_key_env == null);
    try std.testing.expect(keyless.usableKey());
    try std.testing.expect(keyless.apiKeyBytes() == null);

    const keyed = registry.find("keyed").?;
    try std.testing.expect(!keyed.keyless);
    try std.testing.expect(!keyed.usableKey());

    const empty = registry.find("empty").?;
    try std.testing.expect(!empty.keyless);
    try std.testing.expect(!empty.usableKey());
}

test "registry is empty when the providers file is absent" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "");
    defer alloc.free(home);
    try tmp.dir.createDirPath(io_mod.getIo(), ".fx");

    var registry = try load(alloc, home);
    defer registry.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), registry.entries.items.len);
}

test "registry env references win over inline keys" {
    const alloc = std.testing.allocator;
    const bytes =
        "{\"providers\":[" ++
        "{\"name\":\"env-key\",\"base_url\":\"https://e.test\",\"api_key\":\"inline\"," ++
        "\"api_key_env\":\"FX_CUSTOM_PROVIDERS_TEST_KEY\",\"models\":[{\"id\":\"m\"}]}," ++
        "{\"name\":\"inline-key\",\"base_url\":\"https://i.test\",\"api_key\":\"inline\",\"models\":[{\"id\":\"m\"}]}]}";
    var registry = try parse(alloc, bytes);
    defer registry.deinit(alloc);

    // A controlled lookup keeps the test hermetic; the process environment is
    // never touched.
    const Env = struct {
        fn lookup(name: []const u8) ?[]const u8 {
            if (std.mem.eql(u8, name, "FX_CUSTOM_PROVIDERS_TEST_KEY")) return "env-secret";
            return null;
        }
    };
    const env_key = try resolveApiKeyWith(alloc, registry.find("env-key").?, Env.lookup);
    defer alloc.free(env_key.?);
    const inline_key = try resolveApiKeyWith(alloc, registry.find("inline-key").?, Env.lookup);
    defer alloc.free(inline_key.?);

    try std.testing.expectEqualStrings("env-secret", env_key.?);
    try std.testing.expectEqualStrings("inline", inline_key.?);

    // A configured env ref that does not resolve stays null; the inline key is
    // not a fallback because the ref explicitly owns the secret.
    const MissingEnv = struct {
        fn lookup(_: []const u8) ?[]const u8 {
            return null;
        }
    };
    try std.testing.expect((try resolveApiKeyWith(alloc, registry.find("env-key").?, MissingEnv.lookup)) == null);

    // An entry with no key at all resolves to null.
    const no_key_bytes =
        "{\"providers\":[{\"name\":\"keyless\",\"base_url\":\"https://k.test\"," ++
        "\"models\":[{\"id\":\"m\"}]}]}";
    var no_key_registry = try parse(alloc, no_key_bytes);
    defer no_key_registry.deinit(alloc);
    try std.testing.expect((try resolveApiKeyWith(alloc, no_key_registry.find("keyless").?, MissingEnv.lookup)) == null);
}
