const std = @import("std");
const custom_providers = @import("../core/config/custom_providers.zig");
const image_attachments = @import("../core/images/image_attachments.zig");
const secret = @import("../core/auth/secret.zig");
const stream_provider = @import("../core/agent/stream_provider.zig");
const model_tool_schema = @import("../core/tooling/model_tool_schema.zig");
const io_mod = @import("../core/shared/io.zig");
const types = @import("../core/shared/types.zig");
const gateway_client = @import("client.zig");

const Allocator = std.mem.Allocator;

const max_error_body_bytes: usize = 1024 * 1024;
const max_sse_line_bytes: usize = 32 * 1024 * 1024;
const max_sse_aggregate_bytes: usize = 64 * 1024 * 1024;
const max_sse_events: usize = 100_000;
const max_tool_calls: usize = 128;
const max_tool_identity_bytes: usize = 1024;
const max_tool_arguments_bytes: usize = 4 * 1024 * 1024;
const transfer_buffer_bytes: usize = 256 * 1024;
const connect_timeout_ms: i64 = 30_000;

const Limits = struct {
    aggregate_bytes: usize = max_sse_aggregate_bytes,
    events: usize = max_sse_events,
    tool_calls: usize = max_tool_calls,
    tool_identity_bytes: usize = max_tool_identity_bytes,
    tool_arguments_bytes: usize = max_tool_arguments_bytes,
};

/// Builds a stream provider for a registered custom provider. `entry` must
/// outlive every in-flight stream; the app owns the registry for its lifetime.
pub fn provider(entry: *const custom_providers.Entry) stream_provider.Provider {
    return .{
        .context = @constCast(entry),
        .stream_fn = streamCompletion,
    };
}

fn entryFor(context: ?*anyopaque) *const custom_providers.Entry {
    return @ptrCast(@alignCast(context.?));
}

fn validateModel(model: []const u8) !void {
    if (model.len == 0 or model.len > 1024) return error.InvalidOpenAICompatibleModel;
    for (model) |byte| {
        if (byte <= 0x20 or byte == 0x7f) return error.InvalidOpenAICompatibleModel;
    }
}

fn validateReplayMessage(message: types.ChatMessage, limits: Limits) !void {
    if (message.tool_calls.len > limits.tool_calls) return error.OpenAICompatibleToolCallLimitExceeded;
    for (message.tool_calls) |call| {
        if (call.id.len == 0 or call.id.len > limits.tool_identity_bytes or
            call.name.len == 0 or call.name.len > limits.tool_identity_bytes)
        {
            return error.OpenAICompatibleToolCallLimitExceeded;
        }
        if (call.arguments_json.len > limits.tool_arguments_bytes) {
            return error.OpenAICompatibleToolArgumentsTooLarge;
        }
    }
}

pub fn buildRequest(
    alloc: Allocator,
    request: stream_provider.RequestData,
) ![]u8 {
    try validateModel(request.model);
    if (request.budget) |budget| {
        if (budget.cancel_flag) |flag| if (flag.load(.seq_cst)) return error.Cancelled;
        _ = budget.deadline;
    }

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const writer = &out.writer;
    try writer.writeAll("{\"model\":");
    try std.json.Stringify.value(request.model, .{}, writer);
    try writer.writeAll(",\"stream\":true,\"messages\":[");
    try writeMessages(writer, alloc, request.messages, request.verified_images);
    try writer.writeByte(']');

    const tool_count = try writeTools(writer, alloc, request.tools);
    if (tool_count > 0) {
        try writer.writeAll(",\"tool_choice\":");
        try std.json.Stringify.value(request.tool_choice.label(), .{}, writer);
    }
    if (request.provider_options.reasoning) |effort| {
        const label = if (std.mem.eql(u8, effort.label(), "minimal")) "low" else effort.label();
        try writer.writeAll(",\"reasoning_effort\":");
        try std.json.Stringify.value(label, .{}, writer);
    }
    if (request.max_output_tokens) |tokens| {
        try writer.writeAll(",\"max_tokens\":");
        try std.json.Stringify.value(tokens, .{}, writer);
    }
    if (request.response_format) |format| {
        if (format.schema != .object) return error.InvalidStructuredResponseSchema;
        try writer.writeAll(",\"response_format\":{\"type\":\"json_schema\",\"json_schema\":{\"name\":");
        try std.json.Stringify.value(format.name, .{}, writer);
        try writer.writeAll(",\"description\":");
        try std.json.Stringify.value(format.description, .{}, writer);
        try writer.writeAll(",\"schema\":");
        try std.json.Stringify.value(format.schema, .{}, writer);
        try writer.writeAll(",\"strict\":true}}");
    }
    try writer.writeByte('}');
    return out.toOwnedSlice();
}

fn validateApiType(entry: *const custom_providers.Entry) !void {
    if (entry.api_type != .openai_completions) return error.OpenAICompatibleApiTypeUnsupported;
}

fn writeMessages(
    writer: *std.Io.Writer,
    alloc: Allocator,
    messages: []const types.ChatMessage,
    verified_images: ?[]const image_attachments.VerifiedSnapshot,
) !void {
    var first = true;
    for (messages, 0..) |message, message_index| {
        switch (message.role) {
            .system => {
                const text = message.content orelse continue;
                if (text.len == 0) continue;
                try writeComma(writer, &first);
                try writer.writeAll("{\"role\":\"system\",\"content\":");
                try std.json.Stringify.value(text, .{}, writer);
                try writer.writeByte('}');
            },
            .user => {
                try writeComma(writer, &first);
                const attach_images = verified_images != null and message_index == messages.len - 1;
                if (!attach_images) {
                    try writer.writeAll("{\"role\":\"user\",\"content\":");
                    try std.json.Stringify.value(message.content orelse "", .{}, writer);
                    try writer.writeAll("}");
                    continue;
                }
                try writer.writeAll("{\"role\":\"user\",\"content\":[");
                var first_part = true;
                if (message.content) |content| if (content.len > 0) {
                    try writer.writeAll("{\"type\":\"text\",\"text\":");
                    try std.json.Stringify.value(content, .{}, writer);
                    try writer.writeByte('}');
                    first_part = false;
                };
                if (verified_images) |images| {
                    for (images) |image| {
                        if (!first_part) try writer.writeByte(',');
                        try writeImage(writer, alloc, image);
                        first_part = false;
                    }
                }
                try writer.writeAll("]}");
            },
            .assistant => {
                try validateReplayMessage(message, .{});
                try writeComma(writer, &first);
                try writer.writeAll("{\"role\":\"assistant\"");
                if (message.content) |content| if (content.len > 0) {
                    try writer.writeAll(",\"content\":");
                    try std.json.Stringify.value(content, .{}, writer);
                };
                if (message.tool_calls.len > 0) {
                    try writer.writeAll(",\"content\":null,\"tool_calls\":[");
                    for (message.tool_calls, 0..) |call, call_index| {
                        if (call_index > 0) try writer.writeByte(',');
                        try writer.writeAll("{\"id\":");
                        try std.json.Stringify.value(call.id, .{}, writer);
                        try writer.writeAll(",\"type\":\"function\",\"function\":{\"name\":");
                        try std.json.Stringify.value(call.name, .{}, writer);
                        try writer.writeAll(",\"arguments\":");
                        try std.json.Stringify.value(call.arguments_json, .{}, writer);
                        try writer.writeAll("}}");
                    }
                    try writer.writeByte(']');
                } else if (message.content == null) {
                    try writer.writeAll(",\"content\":null");
                }
                try writer.writeByte('}');
            },
            .tool => {
                try writeComma(writer, &first);
                try writer.writeAll("{\"role\":\"tool\",\"tool_call_id\":");
                try std.json.Stringify.value(message.tool_call_id orelse "", .{}, writer);
                try writer.writeAll(",\"content\":");
                try std.json.Stringify.value(message.content orelse "", .{}, writer);
                try writer.writeByte('}');
            },
        }
    }
}

fn writeImage(writer: *std.Io.Writer, alloc: Allocator, image: image_attachments.VerifiedSnapshot) !void {
    const encoded_len = std.base64.standard.Encoder.calcSize(image.bytes.len);
    const encoded = try alloc.alloc(u8, encoded_len);
    defer alloc.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, image.bytes);
    try writer.writeAll("{\"type\":\"image_url\",\"image_url\":{\"url\":\"data:");
    try writer.writeAll(image.media_type);
    try writer.writeAll(";base64,");
    try writer.writeAll(encoded);
    try writer.writeAll("\"}}");
}

fn writeTools(
    writer: *std.Io.Writer,
    alloc: Allocator,
    tools: stream_provider.ToolSelection,
) !usize {
    var count: usize = 0;
    var tools_out: std.Io.Writer.Allocating = .init(alloc);
    defer tools_out.deinit();
    try tools_out.writer.writeAll(",\"tools\":[");
    for (tools.advertised_names) |name| {
        const tool = tools.advertisedFunction(name) orelse continue;
        if (try writeFunctionTool(&tools_out.writer, alloc, tool.name, tool.description, .{ .static = tool.input_schema }, count != 0)) count += 1;
    }
    for (tools.additional_functions) |tool| {
        if (containsName(tools.advertised_names, tool.name)) continue;
        if (try writeFunctionTool(&tools_out.writer, alloc, tool.name, tool.description, .{ .static = tool.input_schema }, count != 0)) count += 1;
    }
    for (tools.selected_dynamic) |tool| {
        if (containsName(tools.advertised_names, tool.name)) continue;
        if (try writeFunctionTool(&tools_out.writer, alloc, tool.name, tool.description, .{ .dynamic = tool.input_schema }, count != 0)) count += 1;
    }
    try tools_out.writer.writeByte(']');
    if (count > 0) try writer.writeAll(tools_out.written());
    return count;
}

const InputSchema = union(enum) {
    static: model_tool_schema.ObjectSchema,
    dynamic: std.json.Value,
};

fn writeFunctionTool(
    writer: *std.Io.Writer,
    alloc: Allocator,
    name: []const u8,
    description: []const u8,
    input_schema: InputSchema,
    comma: bool,
) !bool {
    if (name.len == 0) return false;
    // The OpenAI-compatible contract nests the tool definition under
    // `function`; strict servers (OpenCode Go, OpenRouter) reject flattened
    // tool objects.
    if (comma) try writer.writeByte(',');
    try writer.writeAll("{\"type\":\"function\",\"function\":{\"name\":");
    try std.json.Stringify.value(name, .{}, writer);
    if (description.len > 0) {
        try writer.writeAll(",\"description\":");
        try std.json.Stringify.value(description, .{}, writer);
    }
    try writer.writeAll(",\"parameters\":");
    switch (input_schema) {
        .static => |schema| try model_tool_schema.writeObjectSchema(alloc, writer, schema),
        .dynamic => |schema| {
            if (schema != .object) return error.InvalidToolSchema;
            try std.json.Stringify.value(schema, .{}, writer);
        },
    }
    try writer.writeAll(",\"strict\":false}}");
    return true;
}

fn containsName(names: []const []const u8, expected: []const u8) bool {
    for (names) |name| if (std.mem.eql(u8, name, expected)) return true;
    return false;
}

fn writeComma(writer: *std.Io.Writer, first: *bool) !void {
    if (!first.*) try writer.writeByte(',');
    first.* = false;
}

fn streamCompletion(
    context: ?*anyopaque,
    alloc: Allocator,
    request: stream_provider.ModelRequest,
) !stream_provider.Result {
    return streamCompletionCore(alloc, context, request) catch |err| {
        if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
        request.attempt_evidence.network_failure = gateway_client.networkFailureEvidence(err, request.delivery.load());
        return err;
    };
}

const OpenedRequest = struct {
    request: ?std.http.Client.Request,

    pub fn deinit(self: *OpenedRequest, _: Allocator) void {
        if (self.request) |*request| request.deinit();
        self.request = null;
    }

    pub fn take(self: *OpenedRequest) std.http.Client.Request {
        const request = self.request.?;
        self.request = null;
        return request;
    }
};

const OpenRequestOperation = struct {
    client: *std.http.Client,
    uri: std.Uri,
    auth_header: ?[]const u8,

    pub fn run(self: *@This()) !OpenedRequest {
        return .{ .request = try self.client.request(.POST, self.uri, .{
            .headers = .{
                .content_type = .{ .override = "application/json" },
                .authorization = if (self.auth_header) |header| .{ .override = header } else .omit,
                .accept_encoding = .omit,
                .user_agent = .{ .override = gateway_client.user_agent },
            },
            .extra_headers = &.{.{ .name = "accept", .value = "text/event-stream" }},
            .keep_alive = false,
            .redirect_behavior = .unhandled,
        }) };
    }
};

fn streamCompletionCore(
    alloc: Allocator,
    context: ?*anyopaque,
    request: stream_provider.ModelRequest,
) !stream_provider.Result {
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
    const entry = entryFor(context);
    try validateApiType(entry);
    try validateModel(request.model);
    if (request.credential.secret.len == 0 and !entry.keyless) return error.OpenAICompatibleCredentialRequired;

    const payload = try buildRequest(alloc, request.data());
    defer alloc.free(payload);

    const endpoint = try chatCompletionsEndpoint(alloc, entry.base_url);
    defer alloc.free(endpoint);
    const uri = std.Uri.parse(endpoint) catch return error.InvalidOpenAICompatibleEndpoint;
    if (uri.scheme.len == 0 or
        !(std.mem.eql(u8, uri.scheme, "https") or std.mem.eql(u8, uri.scheme, "http")))
    {
        return error.InvalidOpenAICompatibleEndpoint;
    }
    // A keyless entry sends no Authorization header at all.
    const auth_header: ?[]u8 = if (request.credential.secret.len > 0)
        try std.fmt.allocPrint(alloc, "Bearer {s}", .{request.credential.secret})
    else
        null;
    defer if (auth_header) |header| secret.zeroAndFree(alloc, header);

    var client: std.http.Client = .{ .allocator = alloc, .io = io_mod.getIo() };
    defer client.deinit();
    var open_operation = OpenRequestOperation{
        .client = &client,
        .uri = uri,
        .auth_header = auth_header,
    };
    const connect_deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
        .clock = .awake,
        .raw = .fromMilliseconds(connect_timeout_ms),
    });
    try request.admission.admit();
    var opened = try gateway_client.runBoundedHttpOperation(
        OpenedRequest,
        alloc,
        request.cancel_flag,
        connect_deadline,
        &open_operation,
    );
    var http_request = opened.take();
    defer http_request.deinit();
    var cancel_watch_done = std.atomic.Value(bool).init(false);
    const cancel_watcher = if (http_request.connection) |connection|
        try gateway_client.spawnHttpCancelWatcher(
            &cancel_watch_done,
            request.cancel_flag,
            connection.stream_writer.stream,
        )
    else
        null;
    defer {
        cancel_watch_done.store(true, .seq_cst);
        if (cancel_watcher) |thread| thread.join();
    }
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;

    http_request.transfer_encoding = .{ .content_length = payload.len };
    var send_buffer: [8192]u8 = undefined;
    request.delivery.markPossiblySent();
    var body_writer = try http_request.sendBodyUnflushed(&send_buffer);
    try body_writer.writer.writeAll(payload);
    try body_writer.end();
    if (http_request.connection) |connection| try connection.flush();
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;

    var response = try http_request.receiveHead(&.{});
    if (response.head.status != .ok) {
        var transfer: [16 * 1024]u8 = undefined;
        const reader = response.reader(&transfer);
        const body = reader.allocRemaining(alloc, .limited(max_error_body_bytes)) catch |err| switch (err) {
            error.StreamTooLong => try alloc.dupe(u8, "OpenAI-compatible error response exceeded the local limit"),
            else => return err,
        };
        return .{ .failed = .{
            .kind = failureKind(response.head.status),
            .detail = body,
            .ownership = .owned,
        } };
    }

    var transfer_buffer: [transfer_buffer_bytes]u8 = undefined;
    const reader = response.reader(&transfer_buffer);
    var events = request.events;
    const completion = try consumeSse(
        alloc,
        reader,
        &events,
        EventBridge.content,
        EventBridge.toolStart,
        EventBridge.reasoning,
        EventBridge.toolInput,
        request.cancel_flag,
        request.content_capture_limit,
        .{},
    );
    return .{ .completed = .{
        .completion = completion,
        .usage = .{ .unavailable = .possibly_billed },
        .ownership = .owned,
    } };
}

fn failureKind(status: std.http.Status) stream_provider.FailureKind {
    return switch (status) {
        .bad_request => .invalid_request,
        .unauthorized => .unauthorized,
        .forbidden => .forbidden,
        .payload_too_large => .request_too_large,
        .too_many_requests => .rate_limited,
        .internal_server_error => .server_error,
        .bad_gateway => .bad_gateway,
        .service_unavailable => .unavailable,
        .gateway_timeout => .gateway_timeout,
        else => .provider_error,
    };
}

const EventBridge = struct {
    fn sink(raw: *anyopaque) *stream_provider.EventSink {
        return @ptrCast(@alignCast(raw));
    }

    fn content(raw: *anyopaque, chunk: []const u8) void {
        sink(raw).emit(.{ .content_delta = chunk });
    }

    fn reasoning(raw: *anyopaque, chunk: []const u8) void {
        sink(raw).emit(.{ .reasoning_delta = chunk });
    }

    fn toolInput(raw: *anyopaque, chunk: []const u8) void {
        sink(raw).emit(.{ .tool_input_delta = chunk });
    }

    fn toolStart(raw: *anyopaque, id: []const u8, name: []const u8, label: ?[]const u8) void {
        sink(raw).emit(.{ .tool_started = .{ .id = id, .name = name, .label = label } });
    }
};

/// The chat-completions request path for an OpenAI-compatible API root.
pub fn chatCompletionsEndpoint(alloc: Allocator, base_url: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, base_url, "/");
    if (std.mem.endsWith(u8, trimmed, "/chat/completions")) return alloc.dupe(u8, trimmed);
    return std.fmt.allocPrint(alloc, "{s}/chat/completions", .{trimmed});
}

const ToolAccumulator = struct {
    index: i64,
    id: []u8,
    name: []u8,
    arguments: std.ArrayList(u8) = .empty,

    fn deinit(self: *ToolAccumulator, alloc: Allocator) void {
        alloc.free(self.id);
        alloc.free(self.name);
        self.arguments.deinit(alloc);
        self.* = undefined;
    }
};

const SseReader = struct {
    pending_line: std.ArrayList(u8) = .empty,

    fn deinit(self: *SseReader, alloc: Allocator) void {
        self.pending_line.deinit(alloc);
    }

    fn release(self: *SseReader) void {
        self.pending_line.clearRetainingCapacity();
    }

    fn next(self: *SseReader, alloc: Allocator, reader: anytype) !?[]const u8 {
        while (true) {
            const line = try self.readLine(alloc, reader) orelse return null;
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0 or trimmed[0] == ':') {
                self.release();
                continue;
            }
            if (!std.mem.startsWith(u8, trimmed, "data:")) {
                self.release();
                continue;
            }
            const data = std.mem.trim(u8, trimmed["data:".len..], " \t");
            if (std.mem.eql(u8, data, "[DONE]")) {
                self.release();
                return null;
            }
            return data;
        }
    }

    fn readLine(self: *SseReader, alloc: Allocator, reader: anytype) !?[]const u8 {
        while (true) {
            const fragment = reader.takeDelimiter('\n') catch |err| switch (err) {
                error.StreamTooLong => {
                    const buffered = reader.buffered();
                    if (buffered.len == 0) return error.OpenAICompatibleSseReadStalled;
                    if (buffered.len > max_sse_line_bytes - self.pending_line.items.len) {
                        return error.OpenAICompatibleSseEventTooLarge;
                    }
                    try self.pending_line.appendSlice(alloc, buffered);
                    reader.tossBuffered();
                    continue;
                },
                error.ReadFailed => return error.ReadFailed,
            } orelse {
                if (self.pending_line.items.len > 0) return self.pending_line.items;
                return null;
            };
            if (fragment.len > max_sse_line_bytes - self.pending_line.items.len) {
                return error.OpenAICompatibleSseEventTooLarge;
            }
            if (self.pending_line.items.len == 0) return fragment;
            try self.pending_line.appendSlice(alloc, fragment);
            return self.pending_line.items;
        }
    }
};

fn consumeSse(
    alloc: Allocator,
    reader: anytype,
    callback_ctx: *anyopaque,
    on_content_chunk: stream_provider.StreamCallback,
    on_tool_start: ?stream_provider.ToolStartCallback,
    on_reasoning_chunk: ?stream_provider.StreamCallback,
    on_tool_input_chunk: ?stream_provider.StreamCallback,
    cancel_flag: *std.atomic.Value(bool),
    content_capture_limit: ?usize,
    limits: Limits,
) !types.ModelCompletion {
    var content: std.ArrayList(u8) = .empty;
    errdefer content.deinit(alloc);
    var tools: std.ArrayList(ToolAccumulator) = .empty;
    defer {
        for (tools.items) |*tool| tool.deinit(alloc);
        tools.deinit(alloc);
    }
    var sse: SseReader = .{};
    defer sse.deinit(alloc);
    var finish_reason: ?types.ProviderFinishReason = null;
    var usage: types.Usage = .{};
    var generation_id: ?[]u8 = null;
    errdefer if (generation_id) |id| alloc.free(id);
    var saw_any_event = false;
    var event_count: usize = 0;
    var aggregate_bytes: usize = 0;

    while (try sse.next(alloc, reader)) |json_text| {
        defer sse.release();
        if (cancel_flag.load(.seq_cst)) return error.Cancelled;
        event_count = try checkedAccumulatedSize(event_count, 1, limits.events);
        aggregate_bytes = try checkedAccumulatedSize(aggregate_bytes, json_text.len, limits.aggregate_bytes);
        var parsed = std.json.parseFromSlice(std.json.Value, alloc, json_text, .{}) catch
            return error.InvalidOpenAICompatibleSseEvent;
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        saw_any_event = true;
        if (parsed.value.object.get("error") != null) return error.OpenAICompatibleResponseFailed;
        const choices = parsed.value.object.get("choices") orelse continue;
        if (choices != .array or choices.array.items.len == 0) {
            // A final chunk may carry only usage with empty choices; still let
            // a present finish reason on other chunks seal the stream.
            try captureUsage(&usage, parsed.value.object);
            continue;
        }
        const choice = choices.array.items[0];
        if (choice != .object) continue;
        if (stringField(parsed.value.object, "id")) |id| if (generation_id == null) {
            generation_id = try alloc.dupe(u8, id);
        };
        if (choice.object.get("delta")) |delta| if (delta == .object) {
            if (stringField(delta.object, "content")) |text| {
                on_content_chunk(callback_ctx, text);
                try appendCaptured(alloc, &content, text, content_capture_limit);
            }
            if (stringField(delta.object, "reasoning_content")) |text| {
                if (on_reasoning_chunk) |callback| callback(callback_ctx, text);
            } else if (stringField(delta.object, "reasoning")) |text| {
                if (on_reasoning_chunk) |callback| callback(callback_ctx, text);
            }
            if (delta.object.get("tool_calls")) |calls| if (calls == .array) {
                try accumulateToolCalls(
                    alloc,
                    &tools,
                    calls.array.items,
                    callback_ctx,
                    on_tool_start,
                    on_tool_input_chunk,
                    limits,
                );
            };
        };
        if (stringField(choice.object, "finish_reason")) |reason| {
            finish_reason = finishReasonFor(reason, tools.items.len > 0);
        }
        try captureUsage(&usage, parsed.value.object);
    }
    if (cancel_flag.load(.seq_cst)) return error.Cancelled;
    if (!saw_any_event) return error.OpenAICompatibleStreamIncomplete;

    const owned_content = if (content.items.len > 0) try content.toOwnedSlice(alloc) else null;
    if (owned_content != null) content = .empty;
    errdefer if (owned_content) |value| alloc.free(value);
    const owned_tools: []types.ToolCall = if (tools.items.len > 0)
        try alloc.alloc(types.ToolCall, tools.items.len)
    else
        &.{};
    errdefer if (owned_tools.len > 0) alloc.free(owned_tools);
    var initialized: usize = 0;
    errdefer for (owned_tools[0..initialized]) |call| {
        alloc.free(call.id);
        alloc.free(call.name);
        alloc.free(call.arguments_json);
    };
    for (tools.items, 0..) |*tool, index| {
        const arguments = if (tool.arguments.items.len > 0)
            try tool.arguments.toOwnedSlice(alloc)
        else
            try alloc.dupe(u8, "{}");
        tool.arguments = .empty;
        owned_tools[index] = .{
            .id = tool.id,
            .name = tool.name,
            .arguments_json = arguments,
        };
        tool.id = &.{};
        tool.name = &.{};
        initialized += 1;
    }
    return .{
        .content = owned_content,
        .tool_calls = owned_tools,
        .generation_id = generation_id,
        .finish_reason = finish_reason orelse if (owned_tools.len > 0) .tool_calls else .stop,
        .usage = usage,
    };
}

fn accumulateToolCalls(
    alloc: Allocator,
    tools: *std.ArrayList(ToolAccumulator),
    calls: []const std.json.Value,
    callback_ctx: *anyopaque,
    on_tool_start: ?stream_provider.ToolStartCallback,
    on_tool_input_chunk: ?stream_provider.StreamCallback,
    limits: Limits,
) !void {
    for (calls) |call| {
        if (call != .object) continue;
        const index = integerField(call.object, "index") orelse continue;
        const function_value = call.object.get("function") orelse continue;
        if (function_value != .object) continue;
        const accumulator_index = findTool(tools.items, index);
        if (accumulator_index == null) {
            const name = stringField(function_value.object, "name") orelse continue;
            const call_id = stringField(call.object, "id") orelse continue;
            try appendTool(alloc, tools, index, call_id, name, limits);
            if (on_tool_start) |callback| callback(callback_ctx, call_id, name, null);
        }
        const arguments = stringField(function_value.object, "arguments") orelse continue;
        const tool_index = findTool(tools.items, index) orelse continue;
        try appendToolArguments(alloc, &tools.items[tool_index].arguments, arguments, limits.tool_arguments_bytes);
        if (arguments.len > 0) if (on_tool_input_chunk) |callback| callback(callback_ctx, arguments);
    }
}

fn captureUsage(usage: *types.Usage, object: std.json.ObjectMap) !void {
    const value = object.get("usage") orelse return;
    if (value != .object) return;
    if (unsignedField(value.object, "prompt_tokens")) |tokens| usage.input_tokens = tokens;
    if (unsignedField(value.object, "completion_tokens")) |tokens| usage.output_tokens = tokens;
}

fn appendTool(
    alloc: Allocator,
    tools: *std.ArrayList(ToolAccumulator),
    index: i64,
    call_id: []const u8,
    name: []const u8,
    limits: Limits,
) !void {
    if (tools.items.len >= limits.tool_calls or call_id.len == 0 or call_id.len > limits.tool_identity_bytes or
        name.len == 0 or name.len > limits.tool_identity_bytes)
    {
        return error.OpenAICompatibleToolCallLimitExceeded;
    }
    const id = try alloc.dupe(u8, call_id);
    errdefer alloc.free(id);
    const owned_name = try alloc.dupe(u8, name);
    errdefer alloc.free(owned_name);
    try tools.append(alloc, .{
        .index = index,
        .id = id,
        .name = owned_name,
    });
}

fn appendToolArguments(
    alloc: Allocator,
    arguments: *std.ArrayList(u8),
    delta: []const u8,
    maximum: usize,
) !void {
    _ = checkedAccumulatedSize(arguments.items.len, delta.len, maximum) catch
        return error.OpenAICompatibleToolArgumentsTooLarge;
    try arguments.appendSlice(alloc, delta);
}

fn checkedAccumulatedSize(current: usize, additional: usize, maximum: usize) !usize {
    const next = std.math.add(usize, current, additional) catch
        return error.OpenAICompatibleResourceLimitExceeded;
    if (next > maximum) return error.OpenAICompatibleResourceLimitExceeded;
    return next;
}

fn appendCaptured(
    alloc: Allocator,
    content: *std.ArrayList(u8),
    delta: []const u8,
    limit: ?usize,
) !void {
    const remaining = if (limit) |maximum| maximum -| @min(maximum, content.items.len) else delta.len;
    try content.appendSlice(alloc, delta[0..@min(delta.len, remaining)]);
}

fn findTool(tools: []const ToolAccumulator, index: i64) ?usize {
    for (tools, 0..) |tool, i| if (tool.index == index) return i;
    return null;
}

fn finishReasonFor(reason: []const u8, has_tools: bool) types.ProviderFinishReason {
    if (std.mem.eql(u8, reason, "stop")) return .stop;
    if (std.mem.eql(u8, reason, "length")) return .length;
    if (std.mem.eql(u8, reason, "tool_calls") or std.mem.eql(u8, reason, "function_call")) return .tool_calls;
    if (std.mem.eql(u8, reason, "content_filter")) return .content_filter;
    if (std.mem.eql(u8, reason, "error")) return .provider_error;
    return if (has_tools) .tool_calls else .other;
}

fn stringField(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    if (value != .string) return null;
    return value.string;
}

fn integerField(object: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = object.get(key) orelse return null;
    if (value != .integer) return null;
    return value.integer;
}

fn unsignedField(object: std.json.ObjectMap, key: []const u8) ?u64 {
    const value = integerField(object, key) orelse return null;
    if (value < 0) return null;
    return @intCast(value);
}

test "OpenAI-compatible request builds chat messages with tools and options" {
    const alloc = std.testing.allocator;
    var registry = try custom_providers.parse(
        alloc,
        "{\"providers\":[{\"name\":\"local\",\"base_url\":\"http://127.0.0.1:1234/v1\"," ++
            "\"models\":[{\"id\":\"local-model\"}]}]}",
    );
    defer registry.deinit(alloc);
    const messages = [_]types.ChatMessage{
        .{ .role = .system, .content = "Be concise." },
        .{ .role = .user, .content = "Read it." },
        .{
            .role = .assistant,
            .tool_calls = &.{.{ .id = "call_1", .name = "read_file", .arguments_json = "{\"path\":\"README.md\"}" }},
        },
        .{ .role = .tool, .tool_call_id = "call_1", .tool_name = "read_file", .content = "contents" },
    };
    const read_schema = try std.json.parseFromSlice(std.json.Value, alloc, "{\"type\":\"object\"}", .{});
    defer read_schema.deinit();
    const response_schema = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        "{\"type\":\"object\",\"properties\":{\"ok\":{\"type\":\"boolean\"}}}",
        .{},
    );
    defer response_schema.deinit();
    const body = try buildRequest(alloc, .{
        .model = "local-model",
        .tools = .{ .selected_dynamic = &.{.{ .name = "read_file", .description = "Read", .input_schema = read_schema.value }} },
        .messages = &messages,
        .tool_choice = .auto,
        .provider_options = .{ .reasoning = types.ReasoningEffort.literal("high") },
        .max_output_tokens = 2048,
        .response_format = .{
            .name = "answer",
            .description = "The answer",
            .schema = response_schema.value,
        },
    });
    defer alloc.free(body);

    try std.testing.expect(std.mem.find(u8, body, "\"model\":\"local-model\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"stream\":true") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"role\":\"system\",\"content\":\"Be concise.\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"role\":\"assistant\",\"content\":null,\"tool_calls\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"role\":\"tool\",\"tool_call_id\":\"call_1\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"role\":\"user\",\"content\":\"Read it.\"") != null);
    try std.testing.expect(std.mem.find(u8, body, ",\"tools\":") != null);
    // Strict OpenAI-compatible servers require the nested function object.
    try std.testing.expect(std.mem.find(u8, body, "{\"type\":\"function\",\"function\":{\"name\":\"read_file\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"tool_choice\":\"auto\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"reasoning_effort\":\"high\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"max_tokens\":2048") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"response_format\":{\"type\":\"json_schema\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"parameters\":{\"type\":\"object\"}") != null);
}

test "OpenAI-compatible request omits optional controls when unset" {
    const alloc = std.testing.allocator;
    var registry = try custom_providers.parse(
        alloc,
        "{\"providers\":[{\"name\":\"local\",\"base_url\":\"http://127.0.0.1:1234/v1\"," ++
            "\"models\":[{\"id\":\"m\"}]}]}",
    );
    defer registry.deinit(alloc);
    const messages = [_]types.ChatMessage{.{ .role = .user, .content = "Hi" }};
    const body = try buildRequest(alloc, .{
        .model = "m",
        .tools = .{},
        .messages = &messages,
        .tool_choice = .none,
        .provider_options = .{},
    });
    defer alloc.free(body);

    try std.testing.expect(std.mem.find(u8, body, "\"tools\"") == null);
    try std.testing.expect(std.mem.find(u8, body, "reasoning") == null);
    try std.testing.expect(std.mem.find(u8, body, "max_tokens") == null);
    try std.testing.expect(std.mem.find(u8, body, "response_format") == null);
}

test "OpenAI-compatible request serializes verified images into the last user message" {
    const alloc = std.testing.allocator;
    var registry = try custom_providers.parse(
        alloc,
        "{\"providers\":[{\"name\":\"local\",\"base_url\":\"http://127.0.0.1:1234/v1\"," ++
            "\"models\":[{\"id\":\"m\"}]}]}",
    );
    defer registry.deinit(alloc);
    const messages = [_]types.ChatMessage{.{ .role = .user, .content = "Describe it." }};
    const images = [_]image_attachments.VerifiedSnapshot{.{
        .bytes = @constCast(&[_]u8{ 1, 2, 3, 4 }),
        .media_type = "image/png",
    }};
    const body = try buildRequest(alloc, .{
        .model = "m",
        .tools = .{},
        .messages = &messages,
        .tool_choice = .none,
        .provider_options = .{},
        .verified_images = &images,
    });
    defer alloc.free(body);

    try std.testing.expect(std.mem.find(u8, body, "\"type\":\"image_url\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "data:image/png;base64,AQIDBA==") != null);
    const marker = "\"type\":\"text\"";
    const first = std.mem.find(u8, body, marker) orelse return error.TestExpectedTextPart;
    try std.testing.expect(std.mem.findPos(u8, body, first + marker.len, marker) == null);
}

test "OpenAI-compatible build rejects empty models" {
    const alloc = std.testing.allocator;
    var registry = try custom_providers.parse(
        alloc,
        "{\"providers\":[{\"name\":\"local\",\"base_url\":\"http://127.0.0.1:1234/v1\"," ++
            "\"models\":[{\"id\":\"m\"}]}]}",
    );
    defer registry.deinit(alloc);
    const messages = [_]types.ChatMessage{.{ .role = .user, .content = "Hi" }};
    try std.testing.expectError(
        error.InvalidOpenAICompatibleModel,
        buildRequest(alloc, .{
            .model = "",
            .tools = .{},
            .messages = &messages,
            .tool_choice = .none,
            .provider_options = .{},
        }),
    );
}

test "chat completions endpoint joins the API root" {
    const alloc = std.testing.allocator;
    const first = try chatCompletionsEndpoint(alloc, "https://opencode.ai/zen/go/v1");
    defer alloc.free(first);
    try std.testing.expectEqualStrings("https://opencode.ai/zen/go/v1/chat/completions", first);
    const second = try chatCompletionsEndpoint(alloc, "http://127.0.0.1:1234/v1/");
    defer alloc.free(second);
    try std.testing.expectEqualStrings("http://127.0.0.1:1234/v1/chat/completions", second);
}

test "OpenAI-compatible SSE maps content reasoning tools usage and finish" {
    const alloc = std.testing.allocator;
    const sse_text =
        "data: {\"id\":\"chatcmpl-1\",\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"hello\"},\"finish_reason\":null}]}\n\n" ++
        "data: {\"choices\":[{\"index\":0,\"delta\":{\"reasoning_content\":\"thinking\"},\"finish_reason\":null}]}\n\n" ++
        "data: {\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_1\",\"type\":\"function\",\"function\":{\"name\":\"read_file\",\"arguments\":\"\"}}]},\"finish_reason\":null}]}\n\n" ++
        "data: {\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"{\\\"path\\\":\\\"README.md\\\"}\"}}]},\"finish_reason\":null}]}\n\n" ++
        "data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"tool_calls\"}],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":4}}\n\n" ++
        "data: [DONE]\n\n";
    var reader: std.Io.Reader = .fixed(sse_text);
    var cancelled = std.atomic.Value(bool).init(false);
    const Capture = struct {
        content: std.ArrayList(u8) = .empty,
        reasoning: std.ArrayList(u8) = .empty,
        tool_input: std.ArrayList(u8) = .empty,
        saw_read_file: bool = false,

        fn contentChunk(raw: *anyopaque, chunk: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.content.appendSlice(std.testing.allocator, chunk) catch unreachable;
        }
        fn reasoningChunk(raw: *anyopaque, chunk: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.reasoning.appendSlice(std.testing.allocator, chunk) catch unreachable;
        }
        fn toolInputChunk(raw: *anyopaque, chunk: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.tool_input.appendSlice(std.testing.allocator, chunk) catch unreachable;
        }
        fn toolStart(raw: *anyopaque, _: []const u8, name: []const u8, _: ?[]const u8) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.saw_read_file = std.mem.eql(u8, name, "read_file");
        }
    };
    var capture: Capture = .{};
    defer capture.content.deinit(alloc);
    defer capture.reasoning.deinit(alloc);
    defer capture.tool_input.deinit(alloc);
    const completion = try consumeSse(
        alloc,
        &reader,
        &capture,
        Capture.contentChunk,
        Capture.toolStart,
        Capture.reasoningChunk,
        Capture.toolInputChunk,
        &cancelled,
        null,
        .{},
    );
    defer {
        if (completion.content) |value| alloc.free(@constCast(value));
        types.freeToolCallSlice(alloc, @constCast(completion.tool_calls));
        if (completion.generation_id) |value| alloc.free(@constCast(value));
    }
    try std.testing.expectEqualStrings("hello", capture.content.items);
    try std.testing.expectEqualStrings("thinking", capture.reasoning.items);
    try std.testing.expect(capture.saw_read_file);
    try std.testing.expectEqualStrings("{\"path\":\"README.md\"}", capture.tool_input.items);
    try std.testing.expectEqual(@as(usize, 1), completion.tool_calls.len);
    try std.testing.expectEqualStrings("call_1", completion.tool_calls[0].id);
    try std.testing.expectEqualStrings("read_file", completion.tool_calls[0].name);
    try std.testing.expectEqualStrings("{\"path\":\"README.md\"}", completion.tool_calls[0].arguments_json);
    try std.testing.expectEqualStrings("chatcmpl-1", completion.generation_id.?);
    try std.testing.expectEqual(@as(?u64, 10), completion.usage.input_tokens);
    try std.testing.expectEqual(@as(?u64, 4), completion.usage.output_tokens);
    try std.testing.expectEqual(types.ProviderFinishReason.tool_calls, completion.finish_reason.?);
}

test "OpenAI-compatible SSE finishes by stop with a bare completion" {
    const alloc = std.testing.allocator;
    const sse_text =
        "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"done\"},\"finish_reason\":null}]}\n\n" ++
        "data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n";
    var reader: std.Io.Reader = .fixed(sse_text);
    var cancelled = std.atomic.Value(bool).init(false);
    var callback_context: u8 = 0;
    const completion = try consumeSse(
        alloc,
        &reader,
        &callback_context,
        struct {
            fn ignore(_: *anyopaque, _: []const u8) void {}
        }.ignore,
        null,
        null,
        null,
        &cancelled,
        null,
        .{},
    );
    defer if (completion.content) |value| alloc.free(@constCast(value));
    try std.testing.expectEqualStrings("done", completion.content.?);
    try std.testing.expectEqual(types.ProviderFinishReason.stop, completion.finish_reason.?);
    try std.testing.expectEqual(@as(usize, 0), completion.tool_calls.len);
}

test "OpenAI-compatible SSE maps an error event to provider failure" {
    const alloc = std.testing.allocator;
    const sse_text = "data: {\"error\":{\"message\":\"boom\"}}\n\n";
    var reader: std.Io.Reader = .fixed(sse_text);
    var cancelled = std.atomic.Value(bool).init(false);
    var callback_context: u8 = 0;
    try std.testing.expectError(
        error.OpenAICompatibleResponseFailed,
        consumeSse(
            alloc,
            &reader,
            &callback_context,
            struct {
                fn ignore(_: *anyopaque, _: []const u8) void {}
            }.ignore,
            null,
            null,
            null,
            &cancelled,
            null,
            .{},
        ),
    );
}

test "OpenAI-compatible SSE requires at least one event" {
    const alloc = std.testing.allocator;
    var reader: std.Io.Reader = .fixed("data: [DONE]\n\n");
    var cancelled = std.atomic.Value(bool).init(false);
    var callback_context: u8 = 0;
    try std.testing.expectError(
        error.OpenAICompatibleStreamIncomplete,
        consumeSse(
            alloc,
            &reader,
            &callback_context,
            struct {
                fn ignore(_: *anyopaque, _: []const u8) void {}
            }.ignore,
            null,
            null,
            null,
            &cancelled,
            null,
            .{},
        ),
    );
    var empty_reader: std.Io.Reader = .fixed("");
    try std.testing.expectError(
        error.OpenAICompatibleStreamIncomplete,
        consumeSse(
            alloc,
            &empty_reader,
            &callback_context,
            struct {
                fn ignore(_: *anyopaque, _: []const u8) void {}
            }.ignore,
            null,
            null,
            null,
            &cancelled,
            null,
            .{},
        ),
    );
}

fn consumeOpenAICompatibleTestSse(sse_text: []const u8, limits: Limits) !types.ModelCompletion {
    const alloc = std.testing.allocator;
    var reader: std.Io.Reader = .fixed(sse_text);
    var cancelled = std.atomic.Value(bool).init(false);
    var callback_context: u8 = 0;
    return consumeSse(
        alloc,
        &reader,
        &callback_context,
        struct {
            fn ignore(_: *anyopaque, _: []const u8) void {}
        }.ignore,
        null,
        null,
        null,
        &cancelled,
        null,
        limits,
    );
}

fn freeOpenAICompatibleTestCompletion(completion: types.ModelCompletion) void {
    if (completion.content) |value| std.testing.allocator.free(@constCast(value));
    types.freeToolCallSlice(std.testing.allocator, @constCast(completion.tool_calls));
    if (completion.generation_id) |value| std.testing.allocator.free(@constCast(value));
}

fn expectOpenAICompatibleSseError(expected: anyerror, sse_text: []const u8, limits: Limits) !void {
    const result = consumeOpenAICompatibleTestSse(sse_text, limits);
    if (result) |completion| {
        freeOpenAICompatibleTestCompletion(completion);
        return error.TestExpectedOpenAICompatibleSseError;
    } else |err| {
        try std.testing.expectEqual(expected, err);
    }
}

test "OpenAI-compatible checked stream sizes accept the bound and reject overflow" {
    try std.testing.expectEqual(@as(usize, 7), try checkedAccumulatedSize(6, 1, 7));
    try std.testing.expectError(
        error.OpenAICompatibleResourceLimitExceeded,
        checkedAccumulatedSize(std.math.maxInt(usize), 1, std.math.maxInt(usize)),
    );
}

test "OpenAI-compatible rejects cumulative event and byte limits" {
    const terminal_event = "data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n";
    const completion = try consumeOpenAICompatibleTestSse(
        terminal_event,
        .{ .events = 1, .aggregate_bytes = 100 },
    );
    defer freeOpenAICompatibleTestCompletion(completion);

    const event = "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"x\"},\"finish_reason\":null}]}\n\n";
    try expectOpenAICompatibleSseError(
        error.OpenAICompatibleResourceLimitExceeded,
        event ++ event,
        .{ .events = 1 },
    );
    try expectOpenAICompatibleSseError(
        error.OpenAICompatibleResourceLimitExceeded,
        terminal_event,
        .{ .aggregate_bytes = 30 },
    );
}

test "OpenAI-compatible replay tool limits bound identities and arguments" {
    const alloc = std.testing.allocator;
    const identity = try alloc.alloc(u8, max_tool_identity_bytes + 1);
    defer alloc.free(identity);
    @memset(identity, 'i');
    const arguments = try alloc.alloc(u8, max_tool_arguments_bytes + 1);
    defer alloc.free(arguments);
    @memset(arguments, 'a');

    var call: types.ToolCall = .{ .id = identity[0..max_tool_identity_bytes], .name = "read", .arguments_json = "{}" };
    var message: types.ChatMessage = .{ .role = .assistant, .tool_calls = &.{call} };
    try validateReplayMessage(message, .{});
    call.id = identity;
    message.tool_calls = &.{call};
    try std.testing.expectError(error.OpenAICompatibleToolCallLimitExceeded, validateReplayMessage(message, .{}));

    call = .{ .id = "call", .name = "read", .arguments_json = arguments[0..max_tool_arguments_bytes] };
    message.tool_calls = &.{call};
    try validateReplayMessage(message, .{});
    call.arguments_json = arguments;
    message.tool_calls = &.{call};
    try std.testing.expectError(error.OpenAICompatibleToolArgumentsTooLarge, validateReplayMessage(message, .{}));
}

test "provider rejects a missing credential before network I/O" {
    const alloc = std.testing.allocator;
    var registry = try custom_providers.parse(
        alloc,
        "{\"providers\":[{\"name\":\"local\",\"base_url\":\"http://127.0.0.1:1234/v1\"," ++
            "\"models\":[{\"id\":\"m\"}]}]}",
    );
    defer registry.deinit(alloc);
    var cancelled = std.atomic.Value(bool).init(false);
    var delivery = stream_provider.DeliveryCertainty.init();
    var evidence: stream_provider.AttemptEvidence = .{};
    var callback_context: u8 = 0;
    const events = stream_provider.EventSink{
        .context = &callback_context,
        .emit_fn = EventBridgeIgnore.emit,
    };
    const messages = [_]types.ChatMessage{.{ .role = .user, .content = "Hi" }};
    try std.testing.expectError(
        error.OpenAICompatibleCredentialRequired,
        provider(&registry.entries.items[0]).stream(alloc, .{
            .credential = .{ .secret = "", .source = .custom_provider },
            .model = "m",
            .retry_count = 1,
            .messages = &messages,
            .tool_choice = .auto,
            .provider_options = .{},
            .trace_ctx = .{},
            .content_capture_limit = null,
            .delivery = &delivery,
            .attempt_evidence = &evidence,
            .events = events,
            .cancel_flag = &cancelled,
        }),
    );
    try std.testing.expectEqual(stream_provider.DeliveryCertainty.State.definitely_unsent, delivery.load());
}

const EventBridgeIgnore = struct {
    fn emit(_: *anyopaque, _: stream_provider.Event) void {}

    fn admit(_: *anyopaque) anyerror!void {}
};

test "keyless provider proceeds without a credential and sends no auth header" {
    const alloc = std.testing.allocator;
    var registry = try custom_providers.parse(
        alloc,
        "{\"providers\":[{\"name\":\"local\",\"base_url\":\"http://127.0.0.1:1/v1\",\"keyless\":true," ++
            "\"models\":[{\"id\":\"m\"}]}]}",
    );
    defer registry.deinit(alloc);
    var cancelled = std.atomic.Value(bool).init(false);
    var delivery = stream_provider.DeliveryCertainty.init();
    var evidence: stream_provider.AttemptEvidence = .{};
    var callback_context: u8 = 0;
    const events = stream_provider.EventSink{
        .context = &callback_context,
        .emit_fn = EventBridgeIgnore.emit,
    };
    const admission = stream_provider.Admission{
        .context = &callback_context,
        .admit_fn = EventBridgeIgnore.admit,
    };
    const messages = [_]types.ChatMessage{.{ .role = .user, .content = "Hi" }};
    const result = provider(&registry.entries.items[0]).stream(alloc, .{
        .credential = .{ .secret = "" },
        .model = "m",
        .retry_count = 1,
        .messages = &messages,
        .tool_choice = .auto,
        .provider_options = .{},
        .trace_ctx = .{},
        .content_capture_limit = null,
        .delivery = &delivery,
        .attempt_evidence = &evidence,
        .events = events,
        .admission = admission,
        .cancel_flag = &cancelled,
    });
    // The credential guard is bypassed; the bounded connect against
    // 127.0.0.1:1 fails at the transport layer instead.
    try std.testing.expectError(error.ConnectionRefused, result);
}
