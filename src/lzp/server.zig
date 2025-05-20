const Server = @This();
const Errors = @import("errors.zig");
const Error = Errors.Error;
const Handler = @import("handler.zig");

const std = @import("std");
const zig_builtin = @import("builtin");
const lsp = @import("lsp");
const types = lsp.types;

const log = std.log.scoped(.server);

const version = "0.0.1";

// public fields
allocator: std.mem.Allocator,
/// Use `setTransport` to set the Transport.
transport: ?lsp.AnyTransport = null,
status: Status = .uninitialized,
handler: Handler,

// private fields
thread_pool: if (zig_builtin.single_threaded) void else std.Thread.Pool,
wait_group: if (zig_builtin.single_threaded) void else std.Thread.WaitGroup,
job_queue: std.fifo.LinearFifo(Job, .Dynamic),
job_queue_lock: std.Thread.Mutex = .{},
runtime_zig_version: ?std.SemanticVersion = null,
client_capabilities: ClientCapabilities = .{},

const ClientCapabilities = struct {
    supports_snippets: bool = false,
    supports_apply_edits: bool = false,
    supports_will_save_wait_until: bool = false,
    supports_publish_diagnostics: bool = false,
    supports_code_action_fixall: bool = false,
    supports_semantic_tokens_overlapping: bool = false,
    hover_supports_md: bool = false,
    signature_help_supports_md: bool = false,
    completion_doc_supports_md: bool = false,
    supports_completion_insert_replace_support: bool = false,
    /// deprecated can be marked through the `CompletionItem.deprecated` field
    supports_completion_deprecated_old: bool = false,
    /// deprecated can be marked through the `CompletionItem.tags` field
    supports_completion_deprecated_tag: bool = false,
    label_details_support: bool = false,
    supports_configuration: bool = false,
    supports_workspace_did_change_configuration_dynamic_registration: bool = false,
    supports_textDocument_definition_linkSupport: bool = false,
    /// The detail entries for big structs such as std.zig.CrossTarget were
    /// bricking the preview window in Sublime Text.
    /// https://github.com/zigtools/zls/pull/261
    max_detail_length: u32 = 1024 * 1024,
    client_name: ?[]const u8 = null,

    fn deinit(self: *ClientCapabilities, allocator: std.mem.Allocator) void {
        if (self.client_name) |name| allocator.free(name);
        self.* = undefined;
    }
};

pub const Status = enum {
    /// the server has not received a `initialize` request
    uninitialized,
    /// the server has received a `initialize` request and is awaiting the `initialized` notification
    initializing,
    /// the server has been initialized and is ready to received requests
    initialized,
    /// the server has been shutdown and can't handle any more requests
    shutdown,
    /// the server is received a `exit` notification and has been shutdown
    exiting_success,
    /// the server is received a `exit` notification but has not been shutdown
    exiting_failure,
};

const Job = union(enum) {
    incoming_message: std.json.Parsed(Message),

    fn deinit(self: Job, _: std.mem.Allocator) void {
        switch (self) {
            .incoming_message => |parsed_message| parsed_message.deinit(),
        }
    }

    const SynchronizationMode = enum {
        /// this `Job` requires exclusive access to `Server` and `DocumentStore`
        /// all previous jobs will be awaited
        exclusive,
        /// this `Job` requires shared access to `Server` and `DocumentStore`
        /// other non exclusive jobs can be processed in parallel
        shared,
    };

    fn syncMode(self: Job) SynchronizationMode {
        return switch (self) {
            .incoming_message => |parsed_message| if (isBlockingMessage(parsed_message.value)) .exclusive else .shared,
        };
    }
};

fn sendToClientResponse(server: *Server, id: lsp.JsonRPCMessage.ID, result: anytype) error{OutOfMemory}![]u8 {
    // TODO validate result type is a possible response
    // TODO validate response is from a client to server request
    // TODO validate result type

    const typeOfResult = if (@TypeOf(result) == @TypeOf(void)) null else result;

    const response: lsp.TypedJsonRPCResponse(@TypeOf(typeOfResult)) = .{
        .id = id,
        .result_or_error = .{ .result = result },
    };
    return try sendToClientInternal(server.allocator, server.transport, response);
}

fn sendToClientRequest(server: *Server, id: lsp.JsonRPCMessage.ID, method: []const u8, params: anytype) error{OutOfMemory}![]u8 {
    // TODO validate method is a request
    // TODO validate method is server to client
    // TODO validate params type

    const request: lsp.TypedJsonRPCRequest(@TypeOf(params)) = .{
        .id = id,
        .method = method,
        .params = params,
    };
    return try sendToClientInternal(server.allocator, server.transport, request);
}

fn sendToClientNotification(server: *Server, method: []const u8, params: anytype) error{OutOfMemory}![]u8 {
    // TODO validate method is a notification
    // TODO validate method is server to client
    // TODO validate params type

    const notification: lsp.TypedJsonRPCNotification(@TypeOf(params)) = .{
        .method = method,
        .params = params,
    };
    return try sendToClientInternal(server.allocator, server.transport, notification);
}

fn sendToClientResponseError(server: *Server, id: lsp.JsonRPCMessage.ID, err: lsp.JsonRPCMessage.Response.Error) error{OutOfMemory}![]u8 {
    const response: lsp.JsonRPCMessage = .{
        .response = .{ .id = id, .result_or_error = .{ .@"error" = err } },
    };

    return try sendToClientInternal(server.allocator, server.transport, response);
}

fn sendToClientInternal(allocator: std.mem.Allocator, transport: ?lsp.AnyTransport, message: anytype) error{OutOfMemory}![]u8 {
    const message_stringified = try std.json.stringifyAlloc(allocator, message, .{
        .emit_null_optional_fields = false,
    });
    errdefer allocator.free(message_stringified);

    if (transport) |t| {
        t.writeJsonMessage(message_stringified) catch |err| {
            log.err("failed to write message: {}", .{err});
        };
    }

    return message_stringified;
}

fn showMessage(
    server: *Server,
    message_type: types.MessageType,
    comptime fmt: []const u8,
    args: anytype,
) void {
    const message = std.fmt.allocPrint(server.allocator, fmt, args) catch return;
    defer server.allocator.free(message);
    switch (message_type) {
        .Error => log.err("{s}", .{message}),
        .Warning => log.warn("{s}", .{message}),
        .Info => log.info("{s}", .{message}),
        .Log, .Debug => log.debug("{s}", .{message}),
        _ => log.debug("{s}", .{message}),
    }
    switch (server.status) {
        .initializing,
        .initialized,
        => {},
        .uninitialized,
        .shutdown,
        .exiting_success,
        .exiting_failure,
        => return,
    }
    if (server.sendToClientNotification("window/showMessage", types.ShowMessageParams{
        .type = message_type,
        .message = message,
    })) |json_message| {
        server.allocator.free(json_message);
    } else |err| {
        log.warn("failed to show message: {}", .{err});
    }
}

fn initializeHandler(server: *Server, _: std.mem.Allocator, _: types.InitializeParams) Error!types.InitializeResult {
    server.status = .initializing;

    // TODO: handle initialization options

    return .{
        .serverInfo = .{
            .name = "placeholder",
            .version = version,
        },
        .capabilities = .{
            .positionEncoding = .@"utf-16", // TODO
            // .positionEncoding = switch (server.offset_encoding) {
            //     .@"utf-8" => .@"utf-8",
            //     .@"utf-16" => .@"utf-16",
            //     .@"utf-32" => .@"utf-32",
            // },
            // TODO: support this as config
            // .signatureHelpProvider = .{
            //     .triggerCharacters = &.{"("},
            //     .retriggerCharacters = &.{","},
            // },
            // TODO: notification handlers
            // .textDocumentSync = .{
            //     .TextDocumentSyncOptions = .{
            //         .openClose = true,
            //         .change = .Incremental,
            //         .save = .{ .bool = true },
            //         .willSaveWaitUntil = true,
            //     },
            // },
            .renameProvider = .{ .bool = server.handler.vtable.rename != null },
            // TODO: config
            // .completionProvider = .{
            //     .resolveProvider = false,
            //     .triggerCharacters = &.{ ".", ":", "@", "]", "\"", "/" },
            //     .completionItem = .{ .labelDetailsSupport = true },
            // },
            .documentHighlightProvider = .{ .bool = server.handler.vtable.documentHighlight != null },
            .hoverProvider = .{ .bool = server.handler.vtable.hover != null },
            // TODO
            //.codeActionProvider = .{ .CodeActionOptions = .{ .codeActionKinds = code_actions.supported_code_actions } },
            .declarationProvider = .{ .bool = server.handler.vtable.gotoDeclaration != null },
            .definitionProvider = .{ .bool = server.handler.vtable.gotoDefinition != null },
            .typeDefinitionProvider = .{ .bool = server.handler.vtable.gotoTypeDefinition != null },
            .implementationProvider = .{ .bool = server.handler.vtable.gotoImplementation != null },
            .referencesProvider = .{ .bool = server.handler.vtable.references != null },
            .documentSymbolProvider = .{ .bool = server.handler.vtable.documentSymbols != null },
            .colorProvider = .{ .bool = false }, // TODO
            .documentFormattingProvider = .{ .bool = server.handler.vtable.formatting != null },
            .documentRangeFormattingProvider = .{ .bool = false }, // TODO
            .foldingRangeProvider = .{ .bool = server.handler.vtable.foldingRange != null },
            .selectionRangeProvider = .{ .bool = server.handler.vtable.selectionRange != null },
            .workspaceSymbolProvider = .{ .bool = false }, // TODO
            // TODO: support workspace folders
            // .workspace = .{
            //     .workspaceFolders = .{
            //         .supported = true,
            //         .changeNotifications = .{ .bool = true },
            //     },
            // },
            // TODO: handle passing in legend as config
            // .semanticTokensProvider = .{
            //     .SemanticTokensOptions = .{
            //         .full = .{ .bool = support_full_semantic_tokens },
            //         .range = .{ .bool = true },
            //         .legend = .{
            //             .tokenTypes = std.meta.fieldNames(semantic_tokens.TokenType),
            //             .tokenModifiers = std.meta.fieldNames(semantic_tokens.TokenModifiers),
            //         },
            //     },
            // },
            .inlayHintProvider = .{ .bool = server.handler.vtable.inlayHint != null },
        },
    };
}

fn initializedHandler(server: *Server, _: std.mem.Allocator, notification: types.InitializedParams) Error!void {
    _ = notification;

    if (server.status != .initializing) {
        log.warn("received a initialized notification but the server has not send a initialize request!", .{});
    }

    server.status = .initialized;

    if (server.client_capabilities.supports_workspace_did_change_configuration_dynamic_registration) {
        try server.registerCapability("workspace/didChangeConfiguration");
    }

    if (server.client_capabilities.supports_configuration) {
        try server.requestConfiguration();
        // TODO if the `workspace/configuration` request fails to be handled, build on save will not be started
    }

    if (std.crypto.random.intRangeLessThan(usize, 0, 32768) == 0) {
        server.showMessage(.Warning, "HELP ME, THE ORIGINAL AUTHORS LEFT A WEIRD MESSAGE IN THIS SERVER FILE", .{});
    }
}

fn shutdownHandler(server: *Server, _: std.mem.Allocator, _: void) Error!?void {
    defer server.status = .shutdown;
    if (server.status != .initialized) return error.InvalidRequest; // received a shutdown request but the server is not initialized!
}

fn exitHandler(server: *Server, _: std.mem.Allocator, _: void) Error!void {
    server.status = switch (server.status) {
        .initialized => .exiting_failure,
        .shutdown => .exiting_success,
        else => unreachable,
    };
}

fn registerCapability(server: *Server, method: []const u8) Error!void {
    const id = try std.fmt.allocPrint(server.allocator, "register-{s}", .{method});
    defer server.allocator.free(id);

    log.debug("Dynamically registering method '{s}'", .{method});

    const json_message = try server.sendToClientRequest(
        .{ .string = id },
        "client/registerCapability",
        types.RegistrationParams{ .registrations = &.{
            .{
                .id = id,
                .method = method,
            },
        } },
    );
    server.allocator.free(json_message);
}

fn requestConfiguration(_: *Server) Error!void {}

fn handleConfiguration(_: *Server, _: std.json.Value) error{OutOfMemory}!void {}

// TODO
// fn didChangeWorkspaceFoldersHandler(server: *Server, arena: std.mem.Allocator, notification: types.DidChangeWorkspaceFoldersParams) Error!void {
// }
//
// TODO
// fn openDocumentHandler(_: *Server, _: std.mem.Allocator, _: types.DidOpenTextDocumentParams) Error!void {
// }
//
// // TODO
// fn changeDocumentHandler(_: *Server, _: std.mem.Allocator, _: types.DidChangeTextDocumentParams) Error!void {
// }
//
// // TODO
// fn saveDocumentHandler(_: *Server, _: std.mem.Allocator, _: types.DidSaveTextDocumentParams) Error!void {
// }
//
// // TODO
// fn closeDocumentHandler(_: *Server, _: std.mem.Allocator, _: types.DidCloseTextDocumentParams) error{}!void {
// }
//

const HandledRequestParams = union(enum) {
    initialize: types.InitializeParams,
    shutdown,
    @"textDocument/willSaveWaitUntil": types.WillSaveTextDocumentParams,
    @"textDocument/semanticTokens/full": types.SemanticTokensParams,
    @"textDocument/semanticTokens/range": types.SemanticTokensRangeParams,
    @"textDocument/inlayHint": types.InlayHintParams,
    @"textDocument/completion": types.CompletionParams,
    @"textDocument/signatureHelp": types.SignatureHelpParams,
    @"textDocument/definition": types.DefinitionParams,
    @"textDocument/typeDefinition": types.TypeDefinitionParams,
    @"textDocument/implementation": types.ImplementationParams,
    @"textDocument/declaration": types.DeclarationParams,
    @"textDocument/hover": types.HoverParams,
    @"textDocument/documentSymbol": types.DocumentSymbolParams,
    @"textDocument/formatting": types.DocumentFormattingParams,
    @"textDocument/rename": types.RenameParams,
    @"textDocument/references": types.ReferenceParams,
    @"textDocument/documentHighlight": types.DocumentHighlightParams,
    @"textDocument/codeAction": types.CodeActionParams,
    @"textDocument/foldingRange": types.FoldingRangeParams,
    @"textDocument/selectionRange": types.SelectionRangeParams,
    other: lsp.MethodWithParams,
};

const HandledNotificationParams = union(enum) {
    initialized: types.InitializedParams,
    exit,
    @"textDocument/didOpen": types.DidOpenTextDocumentParams,
    @"textDocument/didChange": types.DidChangeTextDocumentParams,
    @"textDocument/didSave": types.DidSaveTextDocumentParams,
    @"textDocument/didClose": types.DidCloseTextDocumentParams,
    @"workspace/didChangeWorkspaceFolders": types.DidChangeWorkspaceFoldersParams,
    @"workspace/didChangeConfiguration": types.DidChangeConfigurationParams,
    other: lsp.MethodWithParams,
};

const Message = lsp.Message(HandledRequestParams, HandledNotificationParams, .{});

fn isBlockingMessage(msg: Message) bool {
    switch (msg) {
        .request => |request| switch (request.params) {
            .initialize,
            .shutdown,
            => return true,
            .@"textDocument/willSaveWaitUntil",
            .@"textDocument/semanticTokens/full",
            .@"textDocument/semanticTokens/range",
            .@"textDocument/inlayHint",
            .@"textDocument/completion",
            .@"textDocument/signatureHelp",
            .@"textDocument/definition",
            .@"textDocument/typeDefinition",
            .@"textDocument/implementation",
            .@"textDocument/declaration",
            .@"textDocument/hover",
            .@"textDocument/documentSymbol",
            .@"textDocument/formatting",
            .@"textDocument/rename",
            .@"textDocument/references",
            .@"textDocument/documentHighlight",
            .@"textDocument/codeAction",
            .@"textDocument/foldingRange",
            .@"textDocument/selectionRange",
            => return false,
            .other => return false,
        },
        .notification => |notification| switch (notification.params) {
            .initialized,
            .exit,
            .@"textDocument/didOpen",
            .@"textDocument/didChange",
            .@"textDocument/didSave",
            .@"textDocument/didClose",
            .@"workspace/didChangeWorkspaceFolders",
            .@"workspace/didChangeConfiguration",
            => return true,
            .other => return false,
        },
        .response => return true,
    }
}

/// make sure to also set the `transport` field
pub fn create(allocator: std.mem.Allocator, handler: Handler) !*Server {
    const server = try allocator.create(Server);
    errdefer server.destroy();
    server.* = .{
        .allocator = allocator,
        .job_queue = .init(allocator),
        .thread_pool = undefined, // set below
        .wait_group = if (zig_builtin.single_threaded) {} else .{},
        .handler = handler,
    };

    if (zig_builtin.single_threaded) {
        server.thread_pool = {};
    } else {
        try server.thread_pool.init(.{
            .allocator = allocator,
            .n_jobs = @min(4, std.Thread.getCpuCount() catch 1), // what is a good value here?
        });
    }

    return server;
}

pub fn destroy(server: *Server) void {
    if (!zig_builtin.single_threaded) {
        server.wait_group.wait();
        server.thread_pool.deinit();
    }

    while (server.job_queue.readItem()) |job| job.deinit(server.allocator);
    server.job_queue.deinit();
    server.client_capabilities.deinit(server.allocator);
    server.allocator.destroy(server);
}

pub fn setTransport(server: *Server, transport: lsp.AnyTransport) void {
    server.transport = transport;
}

pub fn keepRunning(server: Server) bool {
    switch (server.status) {
        .exiting_success, .exiting_failure => return false,
        else => return true,
    }
}

pub fn waitAndWork(server: *Server) void {
    if (zig_builtin.single_threaded) return;
    server.thread_pool.waitAndWork(&server.wait_group);
    server.wait_group.reset();
}

/// The main loop of ZLS
pub fn loop(server: *Server) !void {
    std.debug.assert(server.transport != null);
    while (server.keepRunning()) {
        const json_message = try server.transport.?.readJsonMessage(server.allocator);
        defer server.allocator.free(json_message);

        try server.sendJsonMessage(json_message);

        while (server.job_queue.readItem()) |job| {
            if (zig_builtin.single_threaded) {
                server.processJob(job);
                continue;
            }

            switch (job.syncMode()) {
                .exclusive => {
                    server.waitAndWork();
                    server.processJob(job);
                },
                .shared => {
                    server.thread_pool.spawnWg(&server.wait_group, processJob, .{ server, job });
                },
            }
        }
    }
}

pub fn sendJsonMessage(server: *Server, json_message: []const u8) Error!void {
    const parsed_message = Message.parseFromSlice(
        server.allocator,
        json_message,
        .{ .ignore_unknown_fields = true, .max_value_len = null, .allocate = .alloc_always },
    ) catch return error.ParseError;
    try server.pushJob(.{ .incoming_message = parsed_message });
}

pub fn sendJsonMessageSync(server: *Server, json_message: []const u8) Error!?[]u8 {
    const parsed_message = Message.parseFromSlice(
        server.allocator,
        json_message,
        .{ .ignore_unknown_fields = true, .max_value_len = null, .allocate = .alloc_always },
    ) catch return error.ParseError;
    defer parsed_message.deinit();
    return try server.processMessage(parsed_message.value);
}

pub fn sendRequestSync(server: *Server, arena: std.mem.Allocator, comptime method: []const u8, params: lsp.ParamsType(method)) Error!lsp.ResultType(method) {
    comptime std.debug.assert(lsp.isRequestMethod(method));
    const Params = std.meta.Tag(HandledRequestParams);
    if (!@hasField(Params, method)) return null;

    const handler = server.handler;

    return switch (@field(Params, method)) {
        .initialize => try server.initializeHandler(arena, params),
        .shutdown => try server.shutdownHandler(arena, params),
        .@"textDocument/willSaveWaitUntil" => try handler.willSaveWaitUntil(params),
        .@"textDocument/semanticTokens/full" => try handler.semanticTokensFull(params),
        .@"textDocument/semanticTokens/range" => try handler.semanticTokensRange(params),
        .@"textDocument/inlayHint" => try handler.inlayHint(params),
        .@"textDocument/completion" => try handler.completion(params),
        .@"textDocument/signatureHelp" => try handler.signatureHelp(params),
        .@"textDocument/definition" => try handler.gotoDefinition(params),
        .@"textDocument/typeDefinition" => try handler.gotoTypeDefinition(params),
        .@"textDocument/implementation" => try handler.gotoImplementation(params),
        .@"textDocument/declaration" => try handler.gotoDeclaration(params),
        .@"textDocument/hover" => try handler.hover(params),
        .@"textDocument/documentSymbol" => try handler.documentSymbols(params),
        .@"textDocument/formatting" => try handler.formatting(params),
        .@"textDocument/rename" => try handler.rename(params),
        .@"textDocument/references" => try handler.references(params),
        .@"textDocument/documentHighlight" => try handler.documentHighlight(params),
        .@"textDocument/codeAction" => try handler.codeAction(params),
        .@"textDocument/foldingRange" => try handler.foldingRange(params),
        .@"textDocument/selectionRange" => try handler.selectionRange(params),
        .other => return null,
    };
}

pub fn sendNotificationSync(server: *Server, arena: std.mem.Allocator, comptime method: []const u8, params: lsp.ParamsType(method)) Error!void {
    comptime std.debug.assert(lsp.isNotificationMethod(method));
    const Params = std.meta.Tag(HandledNotificationParams);
    if (!@hasField(Params, method)) return null;

    return switch (@field(Params, method)) {
        .initialized => try server.initializedHandler(arena, params),
        .exit => try server.exitHandler(arena, params),
        // .@"textDocument/didOpen" => try server.openDocumentHandler(arena, params),
        // .@"textDocument/didChange" => try server.changeDocumentHandler(arena, params),
        // .@"textDocument/didSave" => try server.saveDocumentHandler(arena, params),
        // .@"textDocument/didClose" => try server.closeDocumentHandler(arena, params),
        // .@"workspace/didChangeWorkspaceFolders" => try server.didChangeWorkspaceFoldersHandler(arena, params),
        // .@"workspace/didChangeConfiguration" => try server.didChangeConfigurationHandler(arena, params),
        .other => {},
        else => {},
    };
}

pub fn sendMessageSync(server: *Server, arena: std.mem.Allocator, comptime method: []const u8, params: lsp.ParamsType(method)) Error!lsp.ResultType(method) {
    comptime std.debug.assert(lsp.isRequestMethod(method) or lsp.isNotificationMethod(method));

    if (comptime lsp.isRequestMethod(method)) {
        return try server.sendRequestSync(arena, method, params);
    } else if (comptime lsp.isNotificationMethod(method)) {
        return try server.sendNotificationSync(arena, method, params);
    } else unreachable;
}

fn processMessage(server: *Server, message: Message) Error!?[]u8 {
    var timer = std.time.Timer.start() catch null;
    defer if (timer) |*t| {
        const total_time = @divFloor(t.read(), std.time.ns_per_ms);
        if (zig_builtin.single_threaded) {
            log.debug("Took {d}ms to process {}", .{ total_time, fmtMessage(message) });
        } else {
            const thread_id = std.Thread.getCurrentId();
            log.debug("Took {d}ms to process {} on Thread {d}", .{ total_time, fmtMessage(message), thread_id });
        }
    };

    try server.validateMessage(message);

    var arena_allocator: std.heap.ArenaAllocator = .init(server.allocator);
    defer arena_allocator.deinit();

    switch (message) {
        .request => |request| switch (request.params) {
            .other => return try server.sendToClientResponse(request.id, @as(?void, null)),
            inline else => |params, method| {
                const result = try server.sendRequestSync(arena_allocator.allocator(), @tagName(method), params);
                return try server.sendToClientResponse(request.id, result);
            },
        },
        .notification => |notification| switch (notification.params) {
            .other => {},
            inline else => |params, method| try server.sendNotificationSync(arena_allocator.allocator(), @tagName(method), params),
        },
        .response => |response| try server.handleResponse(response),
    }
    return null;
}

fn processMessageReportError(server: *Server, message: Message) ?[]const u8 {
    return server.processMessage(message) catch |err| {
        log.err("failed to process {}: {}", .{ fmtMessage(message), err });
        if (@errorReturnTrace()) |trace| {
            std.debug.dumpStackTrace(trace.*);
        }

        switch (message) {
            .request => |request| return server.sendToClientResponseError(request.id, .{
                .code = @enumFromInt(switch (err) {
                    error.OutOfMemory => @intFromEnum(types.ErrorCodes.InternalError),
                    error.ParseError => @intFromEnum(types.ErrorCodes.ParseError),
                    error.InvalidRequest => @intFromEnum(types.ErrorCodes.InvalidRequest),
                    error.MethodNotFound => @intFromEnum(types.ErrorCodes.MethodNotFound),
                    error.InvalidParams => @intFromEnum(types.ErrorCodes.InvalidParams),
                    error.InternalError => @intFromEnum(types.ErrorCodes.InternalError),
                    error.ServerNotInitialized => @intFromEnum(types.ErrorCodes.ServerNotInitialized),
                    error.RequestFailed => @intFromEnum(types.LSPErrorCodes.RequestFailed),
                    error.ServerCancelled => @intFromEnum(types.LSPErrorCodes.ServerCancelled),
                    error.ContentModified => @intFromEnum(types.LSPErrorCodes.ContentModified),
                    error.RequestCancelled => @intFromEnum(types.LSPErrorCodes.RequestCancelled),
                }),
                .message = @errorName(err),
            }) catch null,
            .notification, .response => return null,
        }
    };
}

fn processJob(server: *Server, job: Job) void {
    defer job.deinit(server.allocator);

    switch (job) {
        .incoming_message => |parsed_message| {
            const response = server.processMessageReportError(parsed_message.value) orelse return;
            server.allocator.free(response);
        },
    }
}

fn validateMessage(server: *const Server, message: Message) Error!void {
    const method = switch (message) {
        .request => |request| switch (request.params) {
            .other => |info| info.method,
            else => @tagName(request.params),
        },
        .notification => |notification| switch (notification.params) {
            .other => |info| info.method,
            else => @tagName(notification.params),
        },
        .response => return, // validation happens in `handleResponse`
    };

    // https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#dollarRequests
    if (message == .request and std.mem.startsWith(u8, method, "$/")) return error.MethodNotFound;
    if (message == .notification and std.mem.startsWith(u8, method, "$/")) return;

    switch (server.status) {
        .uninitialized => blk: {
            if (std.mem.eql(u8, method, "initialize")) break :blk;
            if (std.mem.eql(u8, method, "exit")) break :blk;

            return error.ServerNotInitialized; // server received a request before being initialized!
        },
        .initializing => blk: {
            if (std.mem.eql(u8, method, "initialized")) break :blk;
            if (std.mem.eql(u8, method, "$/progress")) break :blk;

            std.debug.print("TODO: req during initialization", .{});
            return error.InvalidRequest; // server received a request during initialization!
        },
        .initialized => {},
        .shutdown => blk: {
            if (std.mem.eql(u8, method, "exit")) break :blk;

            std.debug.print("TODO: req during shutdown", .{});
            return error.InvalidRequest; // server received a request after shutdown!
        },
        .exiting_success,
        .exiting_failure,
        => unreachable,
    }
}

fn handleResponse(server: *Server, response: lsp.JsonRPCMessage.Response) Error!void {
    if (response.id == null) {
        log.warn("received response from client without id!", .{});
        return;
    }

    const id: []const u8 = switch (response.id.?) {
        .string => |id| id,
        .number => |id| {
            log.warn("received response from client with id '{d}' that has no handler!", .{id});
            return;
        },
    };

    const result = switch (response.result_or_error) {
        .result => |result| result,
        .@"error" => |err| {
            log.err("Error response for '{s}': {}, {s}", .{ id, err.code, err.message });
            return;
        },
    };

    if (std.mem.eql(u8, id, "semantic_tokens_refresh")) {
        // TODO
    } else if (std.mem.eql(u8, id, "inlay_hints_refresh")) {
        // TODO
    } else if (std.mem.eql(u8, id, "progress")) {
        // TODO
    } else if (std.mem.startsWith(u8, id, "register")) {
        // TODO
    } else if (std.mem.eql(u8, id, "apply_edit")) {
        // TODO
    } else if (std.mem.eql(u8, id, "i_haz_configuration")) {
        try server.handleConfiguration(result orelse .null);
    } else {
        log.warn("received response from client with id '{s}' that has no handler!", .{id});
    }
}

/// takes ownership of `job`
fn pushJob(server: *Server, job: Job) error{OutOfMemory}!void {
    server.job_queue_lock.lock();
    defer server.job_queue_lock.unlock();
    server.job_queue.writeItem(job) catch |err| {
        job.deinit(server.allocator);
        return err;
    };
}

pub fn formatMessage(
    message: Message,
    comptime fmt: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    _ = options;
    if (fmt.len != 0) std.fmt.invalidFmtError(fmt, message);
    switch (message) {
        .request => |request| try writer.print("request-{}-{s}", .{ std.json.fmt(request.id, .{}), @tagName(request.params) }),
        .notification => |notification| try writer.print("notification-{s}", .{@tagName(notification.params)}),
        .response => |response| try writer.print("response-{?}", .{std.json.fmt(response.id, .{})}),
    }
}

fn fmtMessage(message: Message) std.fmt.Formatter(formatMessage) {
    return .{ .data = message };
}
