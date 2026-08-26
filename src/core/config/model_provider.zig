const std = @import("std");
const types = @import("../shared/types.zig");

pub const ProviderId = enum {
    gateway,
    codex,
    grok,
    /// A provider registered in the custom provider registry
    /// (`~/.fx/providers.json`). The registered name rides in
    /// `ProviderSelection.custom_provider`.
    custom,
};

pub const ProviderSelection = struct {
    provider: ProviderId,
    model: []const u8,
    /// Registered custom provider name. Required when `provider == .custom`.
    custom_provider: ?[]const u8 = null,
};

pub fn parse(value: []const u8) ?ProviderId {
    if (std.ascii.eqlIgnoreCase(value, "gateway")) return .gateway;
    if (std.ascii.eqlIgnoreCase(value, "codex")) return .codex;
    if (std.ascii.eqlIgnoreCase(value, "grok")) return .grok;
    if (std.ascii.eqlIgnoreCase(value, "custom")) return .custom;
    return null;
}

pub fn usesGatewayAuxiliaries(provider: ProviderId) bool {
    return provider == .gateway;
}

pub fn authorizesCredential(provider: ProviderId, source: ?types.CredentialSource) bool {
    const selected = source orelse return false;
    return switch (provider) {
        .gateway => selected != .chatgpt_subscription and selected != .grok_subscription,
        .codex => selected == .chatgpt_subscription,
        .grok => selected == .grok_subscription,
        .custom => selected == .custom_provider,
    };
}

test "explicit providers authorize only their own credential origins" {
    try std.testing.expect(authorizesCredential(.gateway, .ai_gateway_api_key));
    try std.testing.expect(authorizesCredential(.gateway, .fx_login));
    try std.testing.expect(!authorizesCredential(.gateway, .chatgpt_subscription));
    try std.testing.expect(authorizesCredential(.codex, .chatgpt_subscription));
    try std.testing.expect(!authorizesCredential(.codex, .ai_gateway_api_key));
    try std.testing.expect(!authorizesCredential(.codex, null));
    try std.testing.expect(authorizesCredential(.grok, .grok_subscription));
    try std.testing.expect(!authorizesCredential(.grok, .chatgpt_subscription));
    try std.testing.expect(!authorizesCredential(.gateway, .grok_subscription));
    try std.testing.expect(authorizesCredential(.custom, .custom_provider));
    try std.testing.expect(!authorizesCredential(.custom, .ai_gateway_api_key));
    try std.testing.expect(!authorizesCredential(.custom, null));
    try std.testing.expect(!authorizesCredential(.custom, .chatgpt_subscription));
}

test "custom providers never use Gateway auxiliaries" {
    try std.testing.expect(usesGatewayAuxiliaries(.gateway));
    try std.testing.expect(!usesGatewayAuxiliaries(.codex));
    try std.testing.expect(!usesGatewayAuxiliaries(.grok));
    try std.testing.expect(!usesGatewayAuxiliaries(.custom));
}

test "provider parsing exposes gateway codex grok and custom" {
    try std.testing.expectEqual(ProviderId.gateway, parse("gateway").?);
    try std.testing.expectEqual(ProviderId.codex, parse("CODEX").?);
    try std.testing.expectEqual(ProviderId.grok, parse("GROK").?);
    try std.testing.expectEqual(ProviderId.custom, parse("Custom").?);
    try std.testing.expect(parse("openai-codex") == null);
    try std.testing.expect(parse("") == null);
}
