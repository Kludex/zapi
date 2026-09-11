//! Response values accepted from endpoint handlers.
//! Values borrow their payloads until the handler result has been encoded.

const std = @import("std");
const background = @import("background.zig");
const content_types = @import("content_types.zig");
const cookies = @import("cookies.zig");
const datastructures = @import("datastructures.zig");
const headers_mod = @import("headers.zig");
const http = @import("http.zig");
const sse = @import("sse.zig");
const urls = @import("urls.zig");
const static_core = @import("static_files/core.zig");
const template_mod = @import("template.zig");

const BackgroundTask = background.BackgroundTask;
const CookieOptions = @import("sessions.zig").CookieOptions;
const CookieParams = datastructures.CookieParams;
const HeaderField = http.HeaderField;
const Status = http.Status;
const clearOwnedHeaderList = headers_mod.clearOwned;
const freeHeaderItemsAndSlice = headers_mod.freeItemsAndSlice;
const ownedHeaderField = headers_mod.owned;
const contentTypeMatches = content_types.contentTypeMatches;
const makeDeleteCookieHeader = cookies.makeDeleteCookieHeader;
const makeSetCookieHeader = cookies.makeSetCookieHeader;
const mediaTypeOnly = content_types.mediaTypeOnly;
const parseSetCookieInto = cookies.parseSetCookieInto;
const redirectNextUrl = urls.redirectNextUrl;
const httpDateAlloc = static_core.httpDateAlloc;
const requestValidatorsNotModified = static_core.requestValidatorsNotModified;
const validateHeader = http.validateHeader;

/// An empty response body.
pub const Empty = struct {};

/// A plain-text response.
pub const Text = struct {
    text: []const u8,
    status: ?Status = null,
    headers: []const HeaderField = &.{},
};

/// An HTML response.
pub const Html = struct {
    html: []const u8,
    status: ?Status = null,
    headers: []const HeaderField = &.{},
};

/// One named template value.
pub const TemplateValue = template_mod.TemplateValue;
/// Creates an HTML-escaped template value.
pub const template = template_mod.template;
/// Creates a trusted, unescaped HTML template value.
pub const templateHtml = template_mod.templateHtml;
/// A template response.
pub const Template = template_mod.Template;
/// One Server-Sent Event.
pub const ServerSentEvent = sse.ServerSentEvent;
/// Creates a data-only Server-Sent Event.
pub const serverSentEvent = sse.serverSentEvent;
/// A buffered Server-Sent Events response.
pub const EventStream = sse.EventStream;

/// A callback that writes a streaming response.
pub const StreamingWriteFn = *const fn (?*anyopaque, *std.Io.Writer) anyerror!void;

/// Transport state for a streaming response.
pub const ResponseStream = struct {
    context: ?*anyopaque = null,
    write: StreamingWriteFn,
};

/// A response written directly by the HTTP transport.
pub const StreamingResponse = struct {
    write: StreamingWriteFn,
    /// Borrowed callback state that must remain valid until writing completes.
    context: ?*anyopaque = null,
    status: ?Status = null,
    content_type: []const u8 = "application/octet-stream",
    headers: []const HeaderField = &.{},
};

/// An arbitrary byte response.
pub const Bytes = struct {
    bytes: []const u8,
    status: ?Status = null,
    content_type: []const u8 = "application/octet-stream",
    headers: []const HeaderField = &.{},
};

/// The browser disposition for a downloaded file.
pub const ContentDisposition = static_core.ContentDisposition;

/// A file response read by the application transport.
pub const File = struct {
    path: []const u8,
    status: ?Status = null,
    dir: std.Io.Dir = .cwd(),
    content_type: ?[]const u8 = null,
    filename: ?[]const u8 = null,
    content_disposition: ContentDisposition = .attachment,
    headers: []const HeaderField = &.{},
    background_tasks: []const BackgroundTask = &.{},
    owned_background_tasks: bool = false,
    max_size: std.Io.Limit = .limited(16 * 1024 * 1024),
};

/// Creates a typed JSON response value.
pub fn Json(comptime T: type) type {
    return struct {
        pub const zapi_json_response = true;
        pub const zapi_inner = T;

        value: T,
        status: ?Status = null,
        headers: []const HeaderField = &.{},
    };
}

/// A pre-encoded JSON response.
pub const RawJson = struct {
    json: []const u8,
    status: ?Status = null,
    headers: []const HeaderField = &.{},
};

/// An HTTP redirect response.
pub const Redirect = struct {
    location: []const u8,
    status: Status = .temporary_redirect,
};

/// An owned response allocated by the app that produced it.
pub const Response = struct {
    status: Status,
    headers: std.ArrayList(HeaderField),
    body: std.ArrayList(u8),
    background_tasks: std.ArrayList(BackgroundTask),
    history: std.ArrayList(Response),
    url: ?[]u8 = null,
    stream: ?ResponseStream = null,

    /// Creates an empty response without allocating.
    pub fn init(status: Status) Response {
        return .{
            .status = status,
            .headers = .empty,
            .body = .empty,
            .background_tasks = .empty,
            .history = .empty,
        };
    }

    /// Releases the response with the allocator passed to the originating app.
    pub fn deinit(self: *Response, allocator: std.mem.Allocator) void {
        for (self.history.items) |*response| {
            response.deinit(allocator);
        }
        self.history.deinit(allocator);
        if (self.url) |url| allocator.free(url);
        for (self.headers.items) |item| {
            allocator.free(item.name);
            allocator.free(item.value);
        }
        self.headers.deinit(allocator);
        self.body.deinit(allocator);
        self.background_tasks.deinit(allocator);
    }

    pub fn setHeader(self: *Response, allocator: std.mem.Allocator, name: []const u8, value: []const u8) !void {
        try validateHeader(name, value);
        var i: usize = 0;
        while (i < self.headers.items.len) {
            if (std.ascii.eqlIgnoreCase(self.headers.items[i].name, name)) {
                allocator.free(self.headers.items[i].name);
                allocator.free(self.headers.items[i].value);
                const removed = self.headers.orderedRemove(i);
                _ = removed;
            } else {
                i += 1;
            }
        }

        try self.appendHeader(allocator, name, value);
    }

    pub fn removeHeader(self: *Response, allocator: std.mem.Allocator, name: []const u8) void {
        var i: usize = 0;
        while (i < self.headers.items.len) {
            if (std.ascii.eqlIgnoreCase(self.headers.items[i].name, name)) {
                allocator.free(self.headers.items[i].name);
                allocator.free(self.headers.items[i].value);
                const removed = self.headers.orderedRemove(i);
                _ = removed;
            } else {
                i += 1;
            }
        }
    }

    pub fn clearHeaders(self: *Response, allocator: std.mem.Allocator) void {
        clearOwnedHeaderList(allocator, &self.headers);
    }

    pub fn appendHeader(self: *Response, allocator: std.mem.Allocator, name: []const u8, value: []const u8) !void {
        try validateHeader(name, value);
        const owned_name = try allocator.dupe(u8, name);
        errdefer allocator.free(owned_name);
        const owned_value = try allocator.dupe(u8, value);
        try self.headers.append(allocator, .{
            .name = owned_name,
            .value = owned_value,
        });
    }

    pub fn setCookie(self: *Response, allocator: std.mem.Allocator, name: []const u8, value: []const u8, options: CookieOptions) !void {
        const cookie_header = try makeSetCookieHeader(allocator, name, value, options);
        errdefer {
            allocator.free(cookie_header.name);
            allocator.free(cookie_header.value);
        }
        try self.headers.append(allocator, cookie_header);
    }

    pub fn deleteCookie(self: *Response, allocator: std.mem.Allocator, name: []const u8, options: CookieOptions) !void {
        const cookie_header = try makeDeleteCookieHeader(allocator, name, options);
        errdefer {
            allocator.free(cookie_header.name);
            allocator.free(cookie_header.value);
        }
        try self.headers.append(allocator, cookie_header);
    }

    pub fn header(self: Response, name: []const u8) ?[]const u8 {
        for (self.headers.items) |item| {
            if (std.ascii.eqlIgnoreCase(item.name, name)) return item.value;
        }
        return null;
    }

    pub fn hasHeader(self: Response, name: []const u8) bool {
        return self.header(name) != null;
    }

    pub fn headerValues(self: Response, allocator: std.mem.Allocator, name: []const u8) ![]const []const u8 {
        var count: usize = 0;
        for (self.headers.items) |item| {
            if (std.ascii.eqlIgnoreCase(item.name, name)) count += 1;
        }

        const values = try allocator.alloc([]const u8, count);
        var index: usize = 0;
        for (self.headers.items) |item| {
            if (!std.ascii.eqlIgnoreCase(item.name, name)) continue;
            values[index] = item.value;
            index += 1;
        }
        return values;
    }

    pub fn reason(self: Response) []const u8 {
        return self.status.reason();
    }

    pub fn statusCode(self: Response) u16 {
        return self.status.code();
    }

    pub fn isInformational(self: Response) bool {
        return self.status.isInformational();
    }

    pub fn isSuccess(self: Response) bool {
        return self.status.isSuccess();
    }

    pub fn isRedirect(self: Response) bool {
        return self.status.isRedirect();
    }

    pub fn isClientError(self: Response) bool {
        return self.status.isClientError();
    }

    pub fn isServerError(self: Response) bool {
        return self.status.isServerError();
    }

    pub fn isError(self: Response) bool {
        return self.status.isError();
    }

    pub fn expectStatus(self: Response, expected: Status) !void {
        if (self.status != expected) return error.UnexpectedStatus;
    }

    pub fn expectSuccess(self: Response) !void {
        if (!self.isSuccess()) return error.UnexpectedStatus;
    }

    pub fn raiseForStatus(self: Response) !void {
        if (self.isError()) return error.ResponseStatusError;
    }

    pub fn requestUrl(self: Response) ?[]const u8 {
        return self.url;
    }

    pub fn location(self: Response) ?[]const u8 {
        return self.header("location");
    }

    pub fn nextUrl(self: Response, allocator: std.mem.Allocator) !?[]u8 {
        if (!self.isRedirect()) return null;
        const location_value = self.location() orelse return null;
        const request_url = self.requestUrl() orelse return null;
        return try redirectNextUrl(allocator, request_url, location_value);
    }

    pub fn json(self: Response, comptime T: type, allocator: std.mem.Allocator) !std.json.Parsed(T) {
        return std.json.parseFromSlice(T, allocator, self.body.items, .{});
    }

    pub fn contentType(self: Response) ?[]const u8 {
        const value = self.header("content-type") orelse return null;
        return mediaTypeOnly(value);
    }

    pub fn hasContentType(self: Response, expected: []const u8) bool {
        const value = self.header("content-type") orelse return false;
        return contentTypeMatches(value, expected);
    }

    pub fn text(self: Response) []const u8 {
        return self.body.items;
    }

    pub fn bytes(self: Response) []const u8 {
        return self.body.items;
    }

    pub fn content(self: Response) []const u8 {
        return self.body.items;
    }

    pub fn cookies(self: Response, allocator: std.mem.Allocator) !CookieParams {
        var params = CookieParams.init(allocator);
        errdefer params.deinit();

        for (self.headers.items) |header_item| {
            if (!std.ascii.eqlIgnoreCase(header_item.name, "set-cookie")) continue;
            try parseSetCookieInto(header_item.value, &params);
        }

        return params;
    }

    pub fn cookie(self: Response, allocator: std.mem.Allocator, name: []const u8) !?[]u8 {
        var params = try self.cookies(allocator);
        defer params.deinit();
        const value = params.get(name) orelse return null;
        return try allocator.dupe(u8, value);
    }

    pub fn addBackgroundTask(self: *Response, allocator: std.mem.Allocator, task: BackgroundTask) !void {
        try self.background_tasks.append(allocator, task);
    }

    pub fn collectStream(self: *Response, allocator: std.mem.Allocator) !void {
        const stream = self.stream orelse return;
        var aw = std.Io.Writer.Allocating.fromArrayList(allocator, &self.body);
        errdefer aw.deinit();
        try stream.write(stream.context, &aw.writer);
        self.body = aw.toArrayList();
        self.stream = null;
    }

    pub fn runBackgroundTasks(self: *Response) !void {
        for (self.background_tasks.items) |task| {
            try task.run(task.context);
        }
        self.background_tasks.clearRetainingCapacity();
    }
};

pub const ConditionalOptions = struct {
    etag: ?[]const u8 = null,
    last_modified_seconds: ?i64 = null,
};

pub const ResponsePayload = struct {
    status: ?Status = null,
    content_type: []const u8 = "application/json",
    headers: []const HeaderField = &.{},
    owned_headers: bool = false,
    background_tasks: []const BackgroundTask = &.{},
    owned_background_tasks: bool = false,
    body: []const u8 = "",
    owned_body: bool = false,
    stream: ?ResponseStream = null,

    pub fn deinit(self: ResponsePayload, allocator: std.mem.Allocator) void {
        if (self.owned_body) allocator.free(self.body);
        if (self.owned_headers) {
            for (self.headers) |item| {
                allocator.free(item.name);
                allocator.free(item.value);
            }
            allocator.free(self.headers);
        }
        if (self.owned_background_tasks) allocator.free(self.background_tasks);
    }

    pub fn header(self: ResponsePayload, name: []const u8) ?[]const u8 {
        for (self.headers) |item| {
            if (std.ascii.eqlIgnoreCase(item.name, name)) return item.value;
        }
        return null;
    }

    pub fn hasHeader(self: ResponsePayload, name: []const u8) bool {
        return self.header(name) != null;
    }

    pub fn headerValues(self: ResponsePayload, allocator: std.mem.Allocator, name: []const u8) ![]const []const u8 {
        var count: usize = 0;
        for (self.headers) |item| {
            if (std.ascii.eqlIgnoreCase(item.name, name)) count += 1;
        }

        const values = try allocator.alloc([]const u8, count);
        var index: usize = 0;
        for (self.headers) |item| {
            if (!std.ascii.eqlIgnoreCase(item.name, name)) continue;
            values[index] = item.value;
            index += 1;
        }
        return values;
    }

    pub fn setHeader(self: *ResponsePayload, allocator: std.mem.Allocator, name: []const u8, value: []const u8) !void {
        var count: usize = 1;
        for (self.headers) |header_item| {
            if (!std.ascii.eqlIgnoreCase(header_item.name, name)) count += 1;
        }

        var headers = try allocator.alloc(HeaderField, count);
        var written: usize = 0;
        errdefer freeHeaderItemsAndSlice(allocator, headers, written);

        for (self.headers) |header_item| {
            if (std.ascii.eqlIgnoreCase(header_item.name, name)) continue;
            headers[written] = try ownedHeaderField(allocator, header_item.name, header_item.value);
            written += 1;
        }

        headers[written] = try ownedHeaderField(allocator, name, value);
        written += 1;

        self.replaceOwnedHeaders(allocator, headers);
    }

    pub fn appendHeader(self: *ResponsePayload, allocator: std.mem.Allocator, name: []const u8, value: []const u8) !void {
        var headers = try allocator.alloc(HeaderField, self.headers.len + 1);
        var written: usize = 0;
        errdefer freeHeaderItemsAndSlice(allocator, headers, written);

        for (self.headers) |header_item| {
            headers[written] = try ownedHeaderField(allocator, header_item.name, header_item.value);
            written += 1;
        }

        headers[written] = try ownedHeaderField(allocator, name, value);
        written += 1;

        self.replaceOwnedHeaders(allocator, headers);
    }

    pub fn removeHeader(self: *ResponsePayload, allocator: std.mem.Allocator, name: []const u8) !void {
        var count: usize = 0;
        for (self.headers) |header_item| {
            if (!std.ascii.eqlIgnoreCase(header_item.name, name)) count += 1;
        }
        if (count == self.headers.len) return;

        var headers = try allocator.alloc(HeaderField, count);
        var written: usize = 0;
        errdefer freeHeaderItemsAndSlice(allocator, headers, written);

        for (self.headers) |header_item| {
            if (std.ascii.eqlIgnoreCase(header_item.name, name)) continue;
            headers[written] = try ownedHeaderField(allocator, header_item.name, header_item.value);
            written += 1;
        }

        self.replaceOwnedHeaders(allocator, headers);
    }

    pub fn clearHeaders(self: *ResponsePayload, allocator: std.mem.Allocator) void {
        if (self.owned_headers) {
            for (self.headers) |item| {
                allocator.free(item.name);
                allocator.free(item.value);
            }
            allocator.free(self.headers);
        }
        self.headers = &.{};
        self.owned_headers = false;
    }

    pub fn makeConditional(self: *ResponsePayload, allocator: std.mem.Allocator, request: anytype, options: ConditionalOptions) !void {
        if (options.etag) |etag| {
            try self.setHeader(allocator, "etag", etag);
        }
        if (options.last_modified_seconds) |seconds| {
            const last_modified = try httpDateAlloc(allocator, seconds);
            defer allocator.free(last_modified);
            try self.setHeader(allocator, "last-modified", last_modified);
        }
        try self.removeHeader(allocator, "content-length");

        const status = self.status orelse .ok;
        if (status != .ok) return;
        if (request.method != .GET and request.method != .HEAD) return;
        if (!requestValidatorsNotModified(request, options.etag, options.last_modified_seconds)) return;

        if (self.owned_body) allocator.free(self.body);
        self.status = .not_modified;
        self.content_type = "";
        self.body = "";
        self.owned_body = false;
    }

    pub fn setCookie(self: *ResponsePayload, allocator: std.mem.Allocator, name: []const u8, value: []const u8, options: CookieOptions) !void {
        const cookie_header = try makeSetCookieHeader(allocator, name, value, options);
        defer {
            allocator.free(cookie_header.name);
            allocator.free(cookie_header.value);
        }
        try self.appendHeader(allocator, cookie_header.name, cookie_header.value);
    }

    pub fn deleteCookie(self: *ResponsePayload, allocator: std.mem.Allocator, name: []const u8, options: CookieOptions) !void {
        const cookie_header = try makeDeleteCookieHeader(allocator, name, options);
        defer {
            allocator.free(cookie_header.name);
            allocator.free(cookie_header.value);
        }
        try self.appendHeader(allocator, cookie_header.name, cookie_header.value);
    }

    pub fn addBackgroundTask(self: *ResponsePayload, allocator: std.mem.Allocator, task: BackgroundTask) !void {
        var tasks = try allocator.alloc(BackgroundTask, self.background_tasks.len + 1);
        @memcpy(tasks[0..self.background_tasks.len], self.background_tasks);
        tasks[self.background_tasks.len] = task;

        if (self.owned_background_tasks) allocator.free(self.background_tasks);
        self.background_tasks = tasks;
        self.owned_background_tasks = true;
    }

    fn replaceOwnedHeaders(self: *ResponsePayload, allocator: std.mem.Allocator, headers: []const HeaderField) void {
        if (self.owned_headers) {
            for (self.headers) |item| {
                allocator.free(item.name);
                allocator.free(item.value);
            }
            allocator.free(self.headers);
        }
        self.headers = headers;
        self.owned_headers = true;
    }
};

test {
    _ = background;
    _ = http;
    _ = sse;
    _ = template_mod;
}
