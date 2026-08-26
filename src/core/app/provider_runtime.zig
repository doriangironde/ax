const std = @import("std");
const builtin = @import("builtin");
const model_provider = @import("../config/model_provider.zig");

const Allocator = std.mem.Allocator;

pub const Runtime = struct {
    const Self = @This();

    alloc: Allocator,
    active_provider: model_provider.ProviderId = .gateway,
    model: std.ArrayList(u8) = .empty,
    custom_provider: std.ArrayList(u8) = .empty,

    pub fn init(alloc: Allocator) Self {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Self) void {
        self.model.deinit(self.alloc);
        self.custom_provider.deinit(self.alloc);
        self.* = undefined;
    }

    /// The returned model slice is borrowed until the next mutation or deinit.
    pub fn selection(self: *const Self) model_provider.ProviderSelection {
        return .{
            .provider = self.active_provider,
            .model = self.model.items,
            .custom_provider = if (self.active_provider == .custom and self.custom_provider.items.len > 0)
                self.custom_provider.items
            else
                null,
        };
    }

    pub fn replaceModel(self: *Self, value: []const u8) !void {
        var owned = try self.alloc.dupe(u8, value);
        self.adoptOwned(self.active_provider, &owned, self.custom_provider.items);
    }

    pub fn replaceSelection(
        self: *Self,
        target_provider: model_provider.ProviderId,
        model_value: []const u8,
    ) !void {
        var owned = try self.alloc.dupe(u8, model_value);
        self.adoptOwned(target_provider, &owned, "");
    }

    pub fn replaceSelectionWithCustom(
        self: *Self,
        target_provider: model_provider.ProviderId,
        model_value: []const u8,
        custom_provider: []const u8,
    ) !void {
        var owned = try self.alloc.dupe(u8, model_value);
        self.adoptOwned(target_provider, &owned, custom_provider);
    }

    /// Transfers `owned_model` into the runtime. All fallible preparation must
    /// finish before this no-fail publication boundary. `custom_provider` may
    /// alias this runtime's own buffer; it is copied before any deinit.
    pub fn adoptOwned(
        self: *Self,
        target_provider: model_provider.ProviderId,
        owned_model: *[]u8,
        custom_provider: []const u8,
    ) void {
        const owned_name = if (target_provider == .custom and custom_provider.len > 0)
            self.alloc.dupe(u8, custom_provider) catch null
        else
            null;
        defer if (owned_name) |name| self.alloc.free(name);
        self.model.deinit(self.alloc);
        self.model = .fromOwnedSlice(owned_model.*);
        owned_model.* = &.{};
        self.custom_provider.deinit(self.alloc);
        self.custom_provider = .empty;
        if (owned_name) |name| self.custom_provider.appendSlice(self.alloc, name) catch {};
        self.active_provider = target_provider;
    }
};

pub fn supported(comptime App: type) bool {
    return @hasField(App, "provider_selection") or
        (builtin.is_test and @hasField(App, "selected_model"));
}

pub fn model(app: anytype) []const u8 {
    const App = @TypeOf(app.*);
    if (comptime @hasField(App, "provider_selection")) {
        return app.provider_selection.selection().model;
    }
    if (comptime builtin.is_test and @hasField(App, "selected_model")) {
        return app.selected_model.items;
    }
    @compileError("app must own provider_selection");
}

/// Adopts an owned model into the app's selection without an extra copy,
/// mirroring the runtime's no-fail publication boundary for both the real app
/// and test fakes.
pub fn adoptOwned(
    app: anytype,
    selected_provider: model_provider.ProviderId,
    owned_model: *[]u8,
    custom_provider: []const u8,
) void {
    const App = @TypeOf(app.*);
    if (comptime @hasField(App, "provider_selection")) {
        return app.provider_selection.adoptOwned(selected_provider, owned_model, custom_provider);
    }
    if (comptime builtin.is_test and @hasField(App, "selected_model")) {
        if (@hasField(App, "selected_provider")) app.selected_provider = selected_provider;
        app.selected_model.clearRetainingCapacity();
        app.selected_model.appendSlice(app.alloc, owned_model.*) catch {};
        app.alloc.free(owned_model.*);
        owned_model.* = &.{};
        return;
    }
    @compileError("app must own provider_selection");
}

pub fn customProvider(app: anytype) []const u8 {
    const App = @TypeOf(app.*);
    if (comptime @hasField(App, "provider_selection")) {
        return app.provider_selection.selection().custom_provider orelse "";
    }
    return "";
}

pub fn provider(app: anytype) model_provider.ProviderId {
    const App = @TypeOf(app.*);
    if (comptime @hasField(App, "provider_selection")) {
        return app.provider_selection.selection().provider;
    }
    if (comptime builtin.is_test and @hasField(App, "selected_provider")) {
        return app.selected_provider;
    }
    if (comptime builtin.is_test and @hasField(App, "selected_model")) {
        return .gateway;
    }
    @compileError("app must own provider_selection");
}

pub fn replaceModel(app: anytype, value: []const u8) !void {
    const App = @TypeOf(app.*);
    if (comptime @hasField(App, "provider_selection")) {
        return app.provider_selection.replaceModel(value);
    }
    if (comptime builtin.is_test and @hasField(App, "selected_model")) {
        const stable = try app.alloc.dupe(u8, value);
        defer app.alloc.free(stable);
        try app.selected_model.ensureTotalCapacity(app.alloc, stable.len);
        app.selected_model.clearRetainingCapacity();
        app.selected_model.appendSliceAssumeCapacity(stable);
        return;
    }
    @compileError("app must own provider_selection");
}

pub fn replaceSelection(
    app: anytype,
    selected_provider: model_provider.ProviderId,
    value: []const u8,
) !void {
    const App = @TypeOf(app.*);
    if (comptime @hasField(App, "provider_selection")) {
        return app.provider_selection.replaceSelection(selected_provider, value);
    }
    if (comptime builtin.is_test and @hasField(App, "selected_model")) {
        if (@hasField(App, "selected_provider")) app.selected_provider = selected_provider;
        return replaceModel(app, value);
    }
    @compileError("app must own provider_selection");
}

pub fn replaceSelectionWithCustom(
    app: anytype,
    selected_provider: model_provider.ProviderId,
    value: []const u8,
    custom_provider: []const u8,
) !void {
    const App = @TypeOf(app.*);
    if (comptime @hasField(App, "provider_selection")) {
        return app.provider_selection.replaceSelectionWithCustom(selected_provider, value, custom_provider);
    }
    if (comptime builtin.is_test and @hasField(App, "selected_model")) {
        if (@hasField(App, "selected_provider")) app.selected_provider = selected_provider;
        return replaceModel(app, value);
    }
    @compileError("app must own provider_selection");
}

test "provider runtime adopts an owned selection without a fallible publication" {
    const alloc = std.testing.allocator;
    var runtime = Runtime.init(alloc);
    defer runtime.deinit();

    var gateway_model = try alloc.dupe(u8, "gateway/model");
    runtime.adoptOwned(.gateway, &gateway_model, "");
    try std.testing.expectEqual(@as(usize, 0), gateway_model.len);
    try std.testing.expectEqual(model_provider.ProviderId.gateway, runtime.selection().provider);
    try std.testing.expectEqualStrings("gateway/model", runtime.selection().model);
    try std.testing.expect(runtime.selection().custom_provider == null);

    var codex_model = try alloc.dupe(u8, "gpt-model");
    runtime.adoptOwned(.codex, &codex_model, "");
    try std.testing.expectEqual(@as(usize, 0), codex_model.len);
    try std.testing.expectEqual(model_provider.ProviderId.codex, runtime.selection().provider);
    try std.testing.expectEqualStrings("gpt-model", runtime.selection().model);
}

test "custom provider selection carries the registered name" {
    const alloc = std.testing.allocator;
    var runtime = Runtime.init(alloc);
    defer runtime.deinit();

    var custom_model = try alloc.dupe(u8, "glm-4.6");
    runtime.adoptOwned(.custom, &custom_model, "opencode-go");
    try std.testing.expectEqual(model_provider.ProviderId.custom, runtime.selection().provider);
    try std.testing.expectEqualStrings("glm-4.6", runtime.selection().model);
    try std.testing.expectEqualStrings("opencode-go", runtime.selection().custom_provider.?);

    // A model-only replace keeps the custom provider name.
    try runtime.replaceModel("deepseek-v4");
    try std.testing.expectEqual(model_provider.ProviderId.custom, runtime.selection().provider);
    try std.testing.expectEqualStrings("deepseek-v4", runtime.selection().model);
    try std.testing.expectEqualStrings("opencode-go", runtime.selection().custom_provider.?);

    // Switching away clears the name even when the custom name aliases the
    // runtime's own buffer.
    try runtime.replaceSelectionWithCustom(.gateway, "zai/glm-5.2", runtime.selection().custom_provider.?);
    try std.testing.expectEqual(model_provider.ProviderId.gateway, runtime.selection().provider);
    try std.testing.expect(runtime.selection().custom_provider == null);
}
