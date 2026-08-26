const std = @import("std");
const provider_set = @import("../core/gateway/provider_set.zig");
const custom_providers = @import("../core/config/custom_providers.zig");
const model_catalog = @import("../core/gateway/model_catalog.zig");
const stream_provider = @import("../core/agent/stream_provider.zig");
const gateway = @import("gateway.zig");
const openai_codex = @import("../gateway/openai_codex.zig");
const openai_codex_models = @import("../gateway/openai_codex_models.zig");
const openai_codex_permission_reviewer = @import("../gateway/openai_codex_permission_reviewer.zig");
const xai_grok = @import("../gateway/xai_grok.zig");
const xai_grok_models = @import("../gateway/xai_grok_models.zig");
const xai_grok_permission_reviewer = @import("../gateway/xai_grok_permission_reviewer.zig");
const provider_catalog = @import("../core/auth/provider_catalog.zig");
const openai_compatible = @import("../gateway/openai_compatible.zig");

pub const native = provider_set.Set{
    .gateway = gateway.provider_bundle,
    .codex = .{
        .presentation = provider_catalog.find(.codex),
        .auth_strategy = .chatgpt,
        .agent_stream = openai_codex.agent_stream_provider,
        .cli_model_catalog = openai_codex_models.cli_model_catalog_provider,
        .model_catalog = openai_codex_models.model_catalog_provider,
        .permission_reviewer = openai_codex_permission_reviewer.provider,
    },
    .grok = .{
        .presentation = provider_catalog.find(.grok),
        .auth_strategy = .grok,
        .agent_stream = xai_grok.agent_stream_provider,
        .cli_model_catalog = xai_grok_models.cli_model_catalog_provider,
        .model_catalog = xai_grok_models.model_catalog_provider,
        .permission_reviewer = xai_grok_permission_reviewer.provider,
    },
};

/// Bundle for the currently selected registered custom provider entry.
/// `entry` must outlive every in-flight stream and `catalog_context` every
/// catalog fetch (the caller keeps both alive in app-owned fields).
pub fn customBundle(
    entry: *const custom_providers.Entry,
    catalog_context: *const custom_providers.StaticCatalogContext,
) provider_set.Bundle {
    return .{
        .agent_stream = openai_compatible.provider(entry),
        .model_catalog = custom_providers.staticCatalogProvider(catalog_context),
    };
}

test "custom provider bundles route from a registered entry" {
    const alloc = std.testing.allocator;
    var registry = try custom_providers.parse(
        alloc,
        "{\"providers\":[{\"name\":\"local\",\"base_url\":\"http://127.0.0.1:1234/v1\"," ++
            "\"models\":[{\"id\":\"m\"}]}]}",
    );
    defer registry.deinit(alloc);
    const entry = registry.find("local").?;
    var context: custom_providers.StaticCatalogContext = .{
        .registry = &registry,
        .provider_name = "local",
    };
    const bundle = customBundle(entry, &context);
    try std.testing.expect(!bundle.agent_stream.?.observes_gateway_usage);
    try std.testing.expect(bundle.agent_stream.?.context != null);
    try std.testing.expect(bundle.agent_stream.?.build_fn != stream_provider.unavailable_provider.build_fn);
    try std.testing.expect(bundle.model_catalog != null);
    try std.testing.expect(bundle.permission_reviewer == null);
}
