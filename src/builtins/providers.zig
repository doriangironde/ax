const std = @import("std");
const model_provider = @import("../core/config/model_provider.zig");
const custom_providers = @import("../core/config/custom_providers.zig");
const model_catalog = @import("../core/gateway/model_catalog.zig");
const stream_provider = @import("../core/agent/stream_provider.zig");
const gateway = @import("gateway.zig");
const openai_codex = @import("../gateway/openai_codex.zig");
const openai_codex_models = @import("../gateway/openai_codex_models.zig");
const xai_grok = @import("../gateway/xai_grok.zig");
const xai_grok_models = @import("../gateway/xai_grok_models.zig");
const openai_compatible = @import("../gateway/openai_compatible.zig");

/// The built-in dispatch cannot name the current custom entry; callers must
/// use `agentStreamForCustom` when the selection is `.custom`.
pub fn agentStream(provider: model_provider.ProviderId) stream_provider.Provider {
    return switch (provider) {
        .gateway => gateway.agent_stream_provider,
        .codex => openai_codex.agent_stream_provider,
        .grok => xai_grok.agent_stream_provider,
        .custom => stream_provider.unavailable_provider,
    };
}

/// Stream provider for a registered custom provider entry. `entry` must
/// outlive every in-flight stream.
pub fn agentStreamForCustom(entry: *const custom_providers.Entry) stream_provider.Provider {
    return openai_compatible.provider(entry);
}

pub fn modelCatalog(provider: model_provider.ProviderId) model_catalog.Provider {
    return switch (provider) {
        .gateway => gateway.model_catalog_provider,
        .codex => openai_codex_models.model_catalog_provider,
        .grok => xai_grok_models.model_catalog_provider,
        .custom => unavailable_catalog_provider,
    };
}

/// Static catalog provider for a registered custom provider entry. The
/// context must stay valid for as long as catalog fetches may run.
pub fn modelCatalogForCustom(context: *const custom_providers.StaticCatalogContext) model_catalog.Provider {
    return custom_providers.staticCatalogProvider(context);
}

const unavailable_catalog_provider = model_catalog.Provider{
    .fetch_fn = unavailableCatalogFetch,
};

fn unavailableCatalogFetch(
    _: ?*anyopaque,
    _: std.mem.Allocator,
    _: model_catalog.FetchInput,
) std.mem.Allocator.Error!model_catalog.ProviderResult {
    return .{ .failure = .{ .category = .runtime } };
}

test "subscription providers opt out of Gateway usage observation" {
    try std.testing.expect(agentStream(.gateway).observes_gateway_usage);
    try std.testing.expect(!agentStream(.codex).observes_gateway_usage);
    try std.testing.expect(!agentStream(.grok).observes_gateway_usage);
    try std.testing.expect(!agentStream(.custom).observes_gateway_usage);
}

test "custom agent stream routes from a registered entry" {
    const alloc = std.testing.allocator;
    var registry = try custom_providers.parse(
        alloc,
        "{\"providers\":[{\"name\":\"local\",\"base_url\":\"http://127.0.0.1:1234/v1\"," ++
            "\"models\":[{\"id\":\"m\"}]}]}",
    );
    defer registry.deinit(alloc);
    const entry = registry.find("local").?;
    const stream = agentStreamForCustom(entry);
    try std.testing.expect(!stream.observes_gateway_usage);
    try std.testing.expect(stream.context != null);
    try std.testing.expect(stream.build_fn != stream_provider.unavailable_provider.build_fn);
}
