//! Core application implementation for zapi.
//! Protocol values and independent codecs live in leaf modules.

const std = @import("std");
const authentication = @import("authentication.zig");
const background = @import("background.zig");
const content_types = @import("content_types.zig");
const cookies_mod = @import("cookies.zig");
const datastructures = @import("datastructures.zig");
const docs_ui = @import("docs_ui.zig");
const headers_mod = @import("headers.zig");
const http = @import("http.zig");
const middleware_options = @import("middleware/options.zig");
const requests = @import("requests.zig");
const responses = @import("responses.zig");
const routing = @import("routing.zig");
const sessions = @import("sessions.zig");
const static_files_mod = @import("static_files/core.zig");
const scalar = @import("scalar.zig");
const sse = @import("sse.zig");
const template_mod = @import("template.zig");
const urls = @import("urls.zig");
const websockets = @import("websockets.zig");
const testing = std.testing;

/// An HTTP request method supported by zapi.
pub const Method = http.Method;
/// An HTTP response status, including extension status codes.
pub const Status = http.Status;
/// A borrowed HTTP header name and value.
pub const HeaderField = http.HeaderField;

const validateHeader = http.validateHeader;

test {
    _ = authentication;
    _ = background;
    _ = content_types;
    _ = cookies_mod;
    _ = datastructures;
    _ = docs_ui;
    _ = headers_mod;
    _ = http;
    _ = middleware_options;
    _ = requests;
    _ = responses;
    _ = routing;
    _ = sessions;
    _ = static_files_mod;
    _ = scalar;
    _ = sse;
    _ = template_mod;
    _ = urls;
    _ = websockets;
}

const ownedHeaderField = headers_mod.owned;

fn ownedRedirectLocationHeader(allocator: std.mem.Allocator, location: []const u8) !HeaderField {
    const owned_name = try allocator.dupe(u8, "location");
    errdefer allocator.free(owned_name);
    const owned_value = try quoteRedirectLocation(allocator, location);
    return .{ .name = owned_name, .value = owned_value };
}

const freeHeaderItemsAndSlice = headers_mod.freeItemsAndSlice;
const appendOwnedHeader = headers_mod.appendOwned;

/// One uploaded file.
pub const UploadFile = datastructures.UploadFile;
/// One named multipart upload.
pub const MultipartFileField = datastructures.MultipartFileField;

/// A canonical textual UUID.
pub const Uuid = scalar.Uuid;
/// An RFC 3339 full-date value.
pub const Date = scalar.Date;
/// An RFC 3339 date-time value.
pub const DateTime = scalar.DateTime;
/// A validated email address.
pub const Email = scalar.Email;
/// A validated URI.
pub const Url = scalar.Url;

/// Bearer credentials.
pub const BearerAuth = authentication.BearerAuth;
/// One OAuth2 scope.
pub const OAuth2Scope = authentication.OAuth2Scope;
/// OAuth2 password bearer credentials.
pub const OAuth2PasswordBearer = authentication.OAuth2PasswordBearer;
/// OAuth2 authorization code bearer credentials.
pub const OAuth2AuthorizationCodeBearer = authentication.OAuth2AuthorizationCodeBearer;
/// OAuth2 client credentials bearer credentials.
pub const OAuth2ClientCredentialsBearer = authentication.OAuth2ClientCredentialsBearer;
/// OAuth2 implicit bearer credentials.
pub const OAuth2ImplicitBearer = authentication.OAuth2ImplicitBearer;
/// Basic authentication credentials.
pub const BasicAuth = authentication.BasicAuth;
/// An API key request location.
pub const ApiKeyLocation = authentication.ApiKeyLocation;
/// A header API key credential type.
pub const ApiKeyHeader = authentication.ApiKeyHeader;
/// A query API key credential type.
pub const ApiKeyQuery = authentication.ApiKeyQuery;
/// A cookie API key credential type.
pub const ApiKeyCookie = authentication.ApiKeyCookie;

/// A background callback.
pub const BackgroundTaskFn = background.BackgroundTaskFn;
/// One background task.
pub const BackgroundTask = background.BackgroundTask;
/// An owned background task collection.
pub const BackgroundTasks = background.BackgroundTasks;
/// A remote request address.
pub const ClientAddress = datastructures.ClientAddress;

/// Buffered request streaming options.
pub const BodyStreamOptions = requests.BodyStreamOptions;
/// An iterator over buffered request body chunks.
pub const BodyStream = requests.BodyStream;
/// A bounded reader for transport request bodies.
pub const RequestBodyReader = requests.RequestBodyReader;

pub const Request = struct {
    method: Method,
    scheme: []const u8 = "http",
    path: []const u8,
    query: []const u8 = "",
    root_path: []const u8 = "",
    headers: []const HeaderField = &.{},
    path_params: []const HeaderField = &.{},
    host_params: []const HeaderField = &.{},
    client: ?ClientAddress = null,
    body: []const u8 = "",
    body_reader: ?*RequestBodyReader = null,
    state_ptr: ?*anyopaque = null,
    session_ptr: ?*Session = null,
    url_resolver: ?requests.URLResolver = null,
    url_root_path: ?[]const u8 = null,
    inherited_io: ?std.Io = null,

    pub fn init(method: Method, target: []const u8) Request {
        if (std.mem.indexOfScalar(u8, target, '?')) |idx| {
            return .{
                .method = method,
                .path = target[0..idx],
                .query = target[idx + 1 ..],
            };
        }

        return .{
            .method = method,
            .path = target,
        };
    }

    pub fn builder(allocator: std.mem.Allocator, method: Method, target: []const u8) RequestBuilder {
        return RequestBuilder.init(allocator, method, target);
    }

    pub fn header(self: Request, name: []const u8) ?[]const u8 {
        for (self.headers) |item| {
            if (std.ascii.eqlIgnoreCase(item.name, name)) return item.value;
        }
        return null;
    }

    pub fn hasHeader(self: Request, name: []const u8) bool {
        return self.header(name) != null;
    }

    pub fn headerValues(self: Request, allocator: std.mem.Allocator, name: []const u8) ![]const []const u8 {
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

    pub fn queryParam(self: Request, allocator: std.mem.Allocator, name: []const u8) !?[]u8 {
        var result: ?[]u8 = null;
        errdefer if (result) |value| allocator.free(value);

        var it = std.mem.splitScalar(u8, self.query, '&');
        while (it.next()) |part| {
            if (part.len == 0) continue;
            const eq_idx = std.mem.indexOfScalar(u8, part, '=') orelse part.len;
            const key = try percentDecode(allocator, part[0..eq_idx]);
            defer allocator.free(key);
            const value = if (eq_idx < part.len) try percentDecode(allocator, part[eq_idx + 1 ..]) else try allocator.dupe(u8, "");
            errdefer allocator.free(value);

            if (std.mem.eql(u8, key, name)) {
                if (result) |previous| allocator.free(previous);
                result = value;
            } else {
                allocator.free(value);
            }
        }

        return result;
    }

    pub fn queryParams(self: Request, allocator: std.mem.Allocator) !QueryParams {
        var params = QueryParams.init(allocator);
        errdefer params.deinit();
        try parseUrlEncodedMultiInto(allocator, self.query, &params);
        return params;
    }

    pub fn json(self: Request, comptime T: type, allocator: std.mem.Allocator) !std.json.Parsed(T) {
        if (!requestHasJsonBodyContentType(self)) return error.Validation;
        return std.json.parseFromSlice(T, allocator, self.body, .{}) catch error.Validation;
    }

    pub fn contentType(self: Request) ?[]const u8 {
        const value = self.header("content-type") orelse return null;
        return mediaTypeOnly(value);
    }

    pub fn hasContentType(self: Request, expected: []const u8) bool {
        const value = self.header("content-type") orelse return false;
        return contentTypeMatches(value, expected);
    }

    pub fn accepts(self: Request, media_type: []const u8) bool {
        const accept = self.header("accept") orelse return true;
        return acceptMatch(accept, media_type) != null;
    }

    pub fn preferredAccepted(self: Request, offers: []const []const u8) ?[]const u8 {
        if (offers.len == 0) return null;
        const accept = self.header("accept") orelse return offers[0];
        return preferredAcceptMatch(accept, offers);
    }

    pub fn ifNoneMatch(self: Request, etag: []const u8) bool {
        return requestEtagMatches(self, etag);
    }

    pub fn ifModifiedSince(self: Request, last_modified_seconds: i64) bool {
        return requestModifiedSince(self, last_modified_seconds);
    }

    pub fn isNotModified(self: Request, options: ConditionalOptions) bool {
        return requestValidatorsNotModified(self, options.etag, options.last_modified_seconds);
    }

    pub fn text(self: Request) []const u8 {
        return self.body;
    }

    pub fn bytes(self: Request) []const u8 {
        return self.body;
    }

    pub fn content(self: Request) []const u8 {
        return self.body;
    }

    pub fn stream(self: Request, options: BodyStreamOptions) BodyStream {
        return .{
            .body = self.body,
            .chunk_size = if (options.chunk_size == 0) self.body.len else options.chunk_size,
        };
    }

    pub fn streamReader(self: Request) ?*RequestBodyReader {
        return self.body_reader;
    }

    pub fn formParams(self: Request, allocator: std.mem.Allocator) !QueryParams {
        const content_type = self.header("content-type") orelse "";
        if (!contentTypeMatches(content_type, "application/x-www-form-urlencoded")) return error.Validation;

        var params = QueryParams.init(allocator);
        errdefer params.deinit();
        try parseUrlEncodedMultiInto(allocator, self.body, &params);
        return params;
    }

    pub fn formData(self: Request, allocator: std.mem.Allocator) !FormData {
        var form = FormData.init(allocator);
        errdefer form.deinit();

        const content_type = self.header("content-type") orelse "";
        if (contentTypeMatches(content_type, "application/x-www-form-urlencoded")) {
            try parseUrlEncodedFormInto(allocator, self.body, &form);
        } else if (contentTypeMatches(content_type, "multipart/form-data")) {
            const boundary = contentTypeParam(content_type, "boundary") orelse return error.Validation;
            try parseMultipartFormInto(allocator, self.body, boundary, &form);
        } else {
            return error.Validation;
        }

        return form;
    }

    pub fn cookie(self: Request, name: []const u8) ?[]const u8 {
        var result: ?[]const u8 = null;
        for (self.headers) |item| {
            if (!std.ascii.eqlIgnoreCase(item.name, "cookie")) continue;

            var cookie_it = std.mem.splitScalar(u8, item.value, ';');
            while (cookie_it.next()) |raw_part| {
                const pair = parseCookieHeaderPair(raw_part) orelse continue;
                if (!std.mem.eql(u8, pair.name, name)) continue;
                result = pair.value;
            }
        }
        return result;
    }

    pub fn cookies(self: Request, allocator: std.mem.Allocator) !CookieParams {
        var params = CookieParams.init(allocator);
        errdefer params.deinit();
        try parseCookieParamsInto(self, &params);
        return params;
    }

    pub fn pathValue(self: Request, name: []const u8) ?[]const u8 {
        for (self.path_params) |item| {
            if (std.mem.eql(u8, item.name, name)) return item.value;
        }
        return null;
    }

    pub fn pathParam(self: Request, allocator: std.mem.Allocator, name: []const u8) !?[]u8 {
        const raw = self.pathValue(name) orelse return null;
        return try percentDecodePath(allocator, raw);
    }

    pub fn pathParams(self: Request, allocator: std.mem.Allocator) !QueryParams {
        var params = QueryParams.init(allocator);
        errdefer params.deinit();

        for (self.path_params) |item| {
            const value = try percentDecodePath(allocator, item.value);
            errdefer allocator.free(value);
            try params.append(item.name, value);
        }

        return params;
    }

    pub fn url(self: Request, allocator: std.mem.Allocator) ![]u8 {
        const path = try self.fullPath(allocator);
        errdefer allocator.free(path);

        const host = self.header("host") orelse return path;
        defer allocator.free(path);
        return std.fmt.allocPrint(allocator, "{s}://{s}{s}", .{ self.scheme, host, path });
    }

    pub fn urlIncludeQueryParam(self: Request, allocator: std.mem.Allocator, name: []const u8, value: []const u8) ![]u8 {
        const path = try requestFullPathIncludeQueryParam(allocator, self, name, value);
        return self.urlFromFullPath(allocator, path);
    }

    pub fn urlReplaceQueryParam(self: Request, allocator: std.mem.Allocator, name: []const u8, value: []const u8) ![]u8 {
        const path = try requestFullPathReplaceQueryParam(allocator, self, name, value);
        return self.urlFromFullPath(allocator, path);
    }

    pub fn urlRemoveQueryParam(self: Request, allocator: std.mem.Allocator, name: []const u8) ![]u8 {
        const path = try requestFullPathRemoveQueryParam(allocator, self, name);
        return self.urlFromFullPath(allocator, path);
    }

    pub fn urlPath(self: Request, allocator: std.mem.Allocator) ![]u8 {
        return self.fullPath(allocator);
    }

    pub fn urlPathIncludeQueryParam(self: Request, allocator: std.mem.Allocator, name: []const u8, value: []const u8) ![]u8 {
        return requestFullPathIncludeQueryParam(allocator, self, name, value);
    }

    pub fn urlPathReplaceQueryParam(self: Request, allocator: std.mem.Allocator, name: []const u8, value: []const u8) ![]u8 {
        return requestFullPathReplaceQueryParam(allocator, self, name, value);
    }

    pub fn urlPathRemoveQueryParam(self: Request, allocator: std.mem.Allocator, name: []const u8) ![]u8 {
        return requestFullPathRemoveQueryParam(allocator, self, name);
    }

    pub fn baseUrl(self: Request, allocator: std.mem.Allocator) ![]u8 {
        const suffix: []const u8 = if (self.root_path.len == 0 or self.root_path[self.root_path.len - 1] != '/') "/" else "";
        const host = self.header("host") orelse return std.fmt.allocPrint(allocator, "{s}{s}", .{ self.root_path, suffix });
        return std.fmt.allocPrint(allocator, "{s}://{s}{s}{s}", .{ self.scheme, host, self.root_path, suffix });
    }

    pub fn fullPath(self: Request, allocator: std.mem.Allocator) ![]u8 {
        const path = try joinRequestPath(allocator, self.root_path, self.path);
        errdefer allocator.free(path);

        if (self.query.len == 0) return path;
        defer allocator.free(path);
        return std.fmt.allocPrint(allocator, "{s}?{s}", .{ path, self.query });
    }

    fn urlFromFullPath(self: Request, allocator: std.mem.Allocator, path: []u8) ![]u8 {
        errdefer allocator.free(path);
        const host = self.header("host") orelse return path;
        defer allocator.free(path);
        return std.fmt.allocPrint(allocator, "{s}://{s}{s}", .{ self.scheme, host, path });
    }

    pub fn urlPathFor(self: Request, allocator: std.mem.Allocator, name: []const u8, params: anytype) anyerror![]u8 {
        const resolver = self.url_resolver orelse return error.NoRoute;
        const path = try resolver.pathFor(allocator, name, params);
        defer allocator.free(path);

        const root_path = self.url_root_path orelse self.root_path;
        if (root_path.len == 0) return allocator.dupe(u8, path);
        return joinRequestPath(allocator, root_path, path);
    }

    pub fn urlFor(self: Request, allocator: std.mem.Allocator, name: []const u8, params: anytype) anyerror![]u8 {
        const path = try self.urlPathFor(allocator, name, params);
        errdefer allocator.free(path);

        const host = self.header("host") orelse return path;
        defer allocator.free(path);
        return std.fmt.allocPrint(allocator, "{s}://{s}{s}", .{ self.scheme, host, path });
    }

    pub fn setState(self: *Request, state_ptr: anytype) void {
        self.state_ptr = @ptrCast(state_ptr);
    }

    pub fn state(self: Request, comptime T: type) *T {
        return @ptrCast(@alignCast(self.state_ptr.?));
    }

    pub fn maybeState(self: Request, comptime T: type) ?*T {
        const ptr = self.state_ptr orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    pub fn session(self: Request) *Session {
        return self.session_ptr.?;
    }
};

fn requestPathParamFields(allocator: std.mem.Allocator, host_params: []const HeaderField, route_path: []const u8, params: *const std.StringHashMap([]const u8)) ![]HeaderField {
    var fields: std.ArrayList(HeaderField) = .empty;
    errdefer fields.deinit(allocator);

    var used = std.StringHashMap(void).init(allocator);
    defer used.deinit();

    for (host_params) |param| {
        try appendRequestPathParamField(allocator, &fields, &used, param.name, params);
    }

    var i: usize = 0;
    while (i < route_path.len) {
        if (route_path[i] == '{') {
            const end = std.mem.indexOfScalarPos(u8, route_path, i + 1, '}') orelse route_path.len;
            if (end < route_path.len) {
                if (parseRouteParam(route_path[i .. end + 1])) |param| {
                    try appendRequestPathParamField(allocator, &fields, &used, param.name, params);
                }
            }
            i = @min(end + 1, route_path.len);
        } else {
            i += 1;
        }
    }

    var it = params.iterator();
    while (it.next()) |entry| {
        if (used.contains(entry.key_ptr.*)) continue;
        try fields.append(allocator, .{
            .name = entry.key_ptr.*,
            .value = entry.value_ptr.*,
        });
    }

    return try fields.toOwnedSlice(allocator);
}

fn appendRequestPathParamField(allocator: std.mem.Allocator, fields: *std.ArrayList(HeaderField), used: *std.StringHashMap(void), name: []const u8, params: *const std.StringHashMap([]const u8)) !void {
    if (used.contains(name)) return;
    const value = params.get(name) orelse return;
    try fields.append(allocator, .{ .name = name, .value = value });
    try used.put(name, {});
}

fn requestFullPathIncludeQueryParam(allocator: std.mem.Allocator, request: Request, name: []const u8, value: []const u8) ![]u8 {
    var query: std.ArrayList(u8) = .empty;
    defer query.deinit(allocator);

    if (request.query.len > 0) try query.appendSlice(allocator, request.query);
    try appendEncodedQueryParam(allocator, &query, name, value);
    return requestFullPathWithQuery(allocator, request, query.items);
}

fn requestFullPathReplaceQueryParam(allocator: std.mem.Allocator, request: Request, name: []const u8, value: []const u8) ![]u8 {
    var query: std.ArrayList(u8) = .empty;
    defer query.deinit(allocator);

    try appendQueryWithoutParam(allocator, &query, request.query, name);
    try appendEncodedQueryParam(allocator, &query, name, value);
    return requestFullPathWithQuery(allocator, request, query.items);
}

fn requestFullPathRemoveQueryParam(allocator: std.mem.Allocator, request: Request, name: []const u8) ![]u8 {
    var query: std.ArrayList(u8) = .empty;
    defer query.deinit(allocator);

    try appendQueryWithoutParam(allocator, &query, request.query, name);
    return requestFullPathWithQuery(allocator, request, query.items);
}

fn requestFullPathWithQuery(allocator: std.mem.Allocator, request: Request, query: []const u8) ![]u8 {
    const path = try joinRequestPath(allocator, request.root_path, request.path);
    errdefer allocator.free(path);

    if (query.len == 0) return path;
    defer allocator.free(path);
    return std.fmt.allocPrint(allocator, "{s}?{s}", .{ path, query });
}

fn appendQueryWithoutParam(allocator: std.mem.Allocator, out: *std.ArrayList(u8), query: []const u8, name: []const u8) !void {
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |part| {
        if (part.len == 0) continue;
        const eq_idx = std.mem.indexOfScalar(u8, part, '=') orelse part.len;
        const key = percentDecode(allocator, part[0..eq_idx]) catch return error.Validation;
        defer allocator.free(key);
        if (std.mem.eql(u8, key, name)) continue;

        if (out.items.len > 0) try out.append(allocator, '&');
        try out.appendSlice(allocator, part);
    }
}

fn appendEncodedQueryParam(allocator: std.mem.Allocator, out: *std.ArrayList(u8), name: []const u8, value: []const u8) !void {
    if (out.items.len > 0) try out.append(allocator, '&');
    try appendUrlEncodedQueryComponent(out, allocator, name);
    try out.append(allocator, '=');
    try appendUrlEncodedQueryComponent(out, allocator, value);
}

pub const RequestBuilder = struct {
    allocator: std.mem.Allocator,
    value: Request,
    headers: std.ArrayList(HeaderField) = .empty,
    query_bytes: std.ArrayList(u8) = .empty,
    body_bytes: std.ArrayList(u8) = .empty,
    multipart_boundary: ?[]const u8 = null,
    urlencoded_form_active: bool = false,

    pub fn init(allocator: std.mem.Allocator, method: Method, target: []const u8) RequestBuilder {
        return .{
            .allocator = allocator,
            .value = Request.init(method, target),
        };
    }

    pub fn deinit(self: *RequestBuilder) void {
        for (self.headers.items) |header_item| {
            self.allocator.free(header_item.name);
            self.allocator.free(header_item.value);
        }
        self.headers.deinit(self.allocator);
        self.query_bytes.deinit(self.allocator);
        self.body_bytes.deinit(self.allocator);
    }

    pub fn request(self: *RequestBuilder) Request {
        self.value.headers = self.headers.items;
        if (self.query_bytes.items.len > 0) self.value.query = self.query_bytes.items;
        self.value.body = self.body_bytes.items;
        return self.value;
    }

    pub fn send(self: *RequestBuilder, app: *ZAPI) !Response {
        return app.handle(self.request());
    }

    pub fn sendOrRaise(self: *RequestBuilder, app: *ZAPI) !Response {
        return app.handleOrRaise(self.request());
    }

    pub fn sendFollowRedirects(self: *RequestBuilder, app: *ZAPI, options: FollowRedirectOptions) !Response {
        return self.sendFollowRedirectsMode(app, options, false);
    }

    pub fn sendFollowRedirectsOrRaise(self: *RequestBuilder, app: *ZAPI, options: FollowRedirectOptions) !Response {
        return self.sendFollowRedirectsMode(app, options, true);
    }

    fn sendFollowRedirectsMode(self: *RequestBuilder, app: *ZAPI, options: FollowRedirectOptions, raise_server_errors: bool) !Response {
        var current = self.request();
        const base_headers = current.headers;
        var owned_target: ?[]u8 = null;
        defer if (owned_target) |target| self.allocator.free(target);

        var redirect_headers: std.ArrayList(HeaderField) = .empty;
        defer {
            clearOwnedHeaderList(self.allocator, &redirect_headers);
            redirect_headers.deinit(self.allocator);
        }

        var cookie_jar = CookieJar.init(self.allocator);
        defer cookie_jar.deinit();
        try cookie_jar.loadRequestHeaders(base_headers);

        var history: std.ArrayList(Response) = .empty;
        errdefer {
            for (history.items) |*history_response| history_response.deinit(self.allocator);
            history.deinit(self.allocator);
        }

        var redirect_count: usize = 0;
        while (true) {
            var response = if (raise_server_errors) try app.handleOrRaise(current) else try app.handle(current);
            const status = response.status;
            if (!redirectStatus(status)) {
                response.history = history;
                return response;
            }

            const location = response.header("location") orelse return response;
            if (redirect_count >= options.max_redirects) {
                response.deinit(self.allocator);
                return error.TooManyRedirects;
            }
            redirect_count += 1;

            const target = redirectTarget(self.allocator, current, location) catch |err| {
                response.deinit(self.allocator);
                return err;
            };
            errdefer self.allocator.free(target.path);
            const next_method = redirectMethod(current.method, status);
            const preserve_body = redirectPreservesBody(status);
            const request_scheme = target.scheme orelse current.scheme;
            const request_host = target.host orelse current.header("host");
            const root_path = current.root_path;
            const client_address = current.client;
            const body = current.body;
            try cookie_jar.applyResponseHeaders(response.headers.items, current.header("host"), current.path);
            const next_path = stripRootPathPrefix(target.path, root_path);
            const next_request = Request.init(next_method, next_path);
            try buildRedirectHeaders(self.allocator, &redirect_headers, base_headers, preserve_body, &cookie_jar, request_host, next_request.path, request_scheme);

            try history.append(self.allocator, response);
            if (owned_target) |previous_target| self.allocator.free(previous_target);
            owned_target = target.path;

            current = next_request;
            current.scheme = request_scheme;
            current.root_path = root_path;
            current.client = client_address;
            current.headers = redirect_headers.items;
            if (preserve_body) current.body = body;
        }
    }

    pub fn header(self: *RequestBuilder, name: []const u8, value: []const u8) !void {
        try appendOwnedHeader(self.allocator, &self.headers, name, value);
        self.value.headers = self.headers.items;
    }

    pub fn headerValue(self: *RequestBuilder, name: []const u8) ?[]const u8 {
        return self.request().header(name);
    }

    pub fn hasHeader(self: *RequestBuilder, name: []const u8) bool {
        return self.headerValue(name) != null;
    }

    pub fn headerValues(self: *RequestBuilder, allocator: std.mem.Allocator, name: []const u8) ![]const []const u8 {
        return self.request().headerValues(allocator, name);
    }

    pub fn setHeader(self: *RequestBuilder, name: []const u8, value: []const u8) !void {
        self.removeHeader(name);
        try self.header(name, value);
    }

    pub fn accept(self: *RequestBuilder, value: []const u8) !void {
        try self.setHeader("accept", value);
    }

    pub fn contentType(self: *RequestBuilder, value: []const u8) !void {
        try self.setHeader("content-type", value);
    }

    pub fn userAgent(self: *RequestBuilder, value: []const u8) !void {
        try self.setHeader("user-agent", value);
    }

    pub fn removeHeader(self: *RequestBuilder, name: []const u8) void {
        removeOwnedHeaders(self.allocator, &self.headers, name);
        self.value.headers = self.headers.items;
    }

    pub fn clearHeaders(self: *RequestBuilder) void {
        clearOwnedHeaderList(self.allocator, &self.headers);
        self.value.headers = self.headers.items;
    }

    pub fn cookie(self: *RequestBuilder, name: []const u8, value: []const u8) !void {
        try validateCookieToken(name);
        try validateCookieValue(value);
        const header_value = try std.fmt.allocPrint(self.allocator, "{s}={s}", .{ name, value });
        defer self.allocator.free(header_value);
        try self.header("cookie", header_value);
    }

    pub fn client(self: *RequestBuilder, address: ?ClientAddress) void {
        self.value.client = address;
    }

    pub fn scheme(self: *RequestBuilder, value: []const u8) void {
        self.value.scheme = value;
    }

    pub fn rootPath(self: *RequestBuilder, value: []const u8) void {
        self.value.root_path = value;
    }

    pub fn host(self: *RequestBuilder, value: []const u8) !void {
        try self.setHeader("host", value);
    }

    pub fn bearerAuth(self: *RequestBuilder, token: []const u8) !void {
        const header_value = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{token});
        defer self.allocator.free(header_value);
        try self.setHeader("authorization", header_value);
    }

    pub fn basicAuth(self: *RequestBuilder, username: []const u8, password: []const u8) !void {
        const raw = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ username, password });
        defer self.allocator.free(raw);

        const encoded = try self.allocator.alloc(u8, std.base64.standard.Encoder.calcSize(raw.len));
        defer self.allocator.free(encoded);
        const encoded_value = std.base64.standard.Encoder.encode(encoded, raw);

        const header_value = try std.fmt.allocPrint(self.allocator, "Basic {s}", .{encoded_value});
        defer self.allocator.free(header_value);
        try self.setHeader("authorization", header_value);
    }

    pub fn apiKeyHeader(self: *RequestBuilder, name: []const u8, key: []const u8) !void {
        try self.setHeader(name, key);
    }

    pub fn apiKeyQuery(self: *RequestBuilder, name: []const u8, key: []const u8) !void {
        try self.queryParam(name, key);
    }

    pub fn apiKeyCookie(self: *RequestBuilder, name: []const u8, key: []const u8) !void {
        try self.cookie(name, key);
    }

    pub fn queryParam(self: *RequestBuilder, name: []const u8, value: []const u8) !void {
        if (self.query_bytes.items.len == 0 and self.value.query.len > 0) {
            try self.query_bytes.appendSlice(self.allocator, self.value.query);
        }
        try self.appendQueryParamEncoded(name, value);
        self.value.query = self.query_bytes.items;
    }

    pub fn queryParamValue(self: *RequestBuilder, allocator: std.mem.Allocator, name: []const u8) !?[]u8 {
        return self.request().queryParam(allocator, name);
    }

    pub fn queryParams(self: *RequestBuilder, allocator: std.mem.Allocator) !QueryParams {
        return self.request().queryParams(allocator);
    }

    pub fn hasQueryParam(self: *RequestBuilder, allocator: std.mem.Allocator, name: []const u8) !bool {
        const value = try self.queryParamValue(allocator, name);
        defer if (value) |owned_value| allocator.free(owned_value);
        return value != null;
    }

    pub fn setQueryParam(self: *RequestBuilder, name: []const u8, value: []const u8) !void {
        try self.removeQueryParam(name);
        try self.queryParam(name, value);
    }

    pub fn removeQueryParam(self: *RequestBuilder, name: []const u8) !void {
        const raw = try self.allocator.dupe(u8, self.value.query);
        defer self.allocator.free(raw);

        self.query_bytes.clearRetainingCapacity();
        var it = std.mem.splitScalar(u8, raw, '&');
        while (it.next()) |part| {
            if (part.len == 0) continue;
            const eq_idx = std.mem.indexOfScalar(u8, part, '=') orelse part.len;
            const key = try percentDecode(self.allocator, part[0..eq_idx]);
            defer self.allocator.free(key);
            if (std.mem.eql(u8, key, name)) continue;

            const value = if (eq_idx < part.len) try percentDecode(self.allocator, part[eq_idx + 1 ..]) else try self.allocator.dupe(u8, "");
            defer self.allocator.free(value);
            try self.appendQueryParamEncoded(key, value);
        }
        self.value.query = self.query_bytes.items;
    }

    pub fn clearQueryParams(self: *RequestBuilder) void {
        self.query_bytes.clearRetainingCapacity();
        self.value.query = "";
    }

    pub fn queryValue(self: *RequestBuilder, value: anytype) !void {
        const T = @TypeOf(value);
        const info = @typeInfo(T);
        if (info != .@"struct") @compileError("queryValue expects a struct or anonymous struct");

        inline for (info.@"struct".fields) |field| {
            try self.queryField(field.name, @field(value, field.name));
        }
    }

    fn queryField(self: *RequestBuilder, name: []const u8, value: anytype) !void {
        const T = @TypeOf(value);
        switch (@typeInfo(T)) {
            .optional => {
                if (value) |inner| try self.queryField(name, inner);
            },
            .pointer => |ptr| {
                switch (ptr.size) {
                    .slice => {
                        if (ptr.child == u8) {
                            try self.queryParam(name, value);
                        } else {
                            for (value) |item| try self.queryField(name, item);
                        }
                    },
                    .one => switch (@typeInfo(ptr.child)) {
                        .array => |array| {
                            if (array.child == u8) {
                                try self.queryParam(name, value);
                            } else {
                                for (value.*) |item| try self.queryField(name, item);
                            }
                        },
                        else => @compileError("queryValue pointer fields must be strings or arrays"),
                    },
                    else => @compileError("queryValue pointer fields must be strings or slices"),
                }
            },
            .array => |array| {
                if (array.child == u8) {
                    try self.queryParam(name, value[0..]);
                } else {
                    for (value) |item| try self.queryField(name, item);
                }
            },
            .bool => try self.queryParam(name, if (value) "true" else "false"),
            .int, .comptime_int, .float, .comptime_float => {
                const text = try std.fmt.allocPrint(self.allocator, "{}", .{value});
                defer self.allocator.free(text);
                try self.queryParam(name, text);
            },
            .@"enum" => try self.queryParam(name, @tagName(value)),
            .@"struct" => {
                if (@hasDecl(T, "text")) {
                    try self.queryParam(name, value.text());
                } else {
                    @compileError("queryValue struct fields must provide text() for query serialization");
                }
            },
            else => @compileError("unsupported queryValue field type"),
        }
    }

    fn appendQueryParamEncoded(self: *RequestBuilder, name: []const u8, value: []const u8) !void {
        if (self.query_bytes.items.len > 0) try self.query_bytes.append(self.allocator, '&');
        try appendUrlEncodedQueryComponent(&self.query_bytes, self.allocator, name);
        try self.query_bytes.append(self.allocator, '=');
        try appendUrlEncodedQueryComponent(&self.query_bytes, self.allocator, value);
    }

    pub fn setBody(self: *RequestBuilder, body: []const u8) !void {
        self.multipart_boundary = null;
        self.urlencoded_form_active = false;
        self.body_bytes.clearRetainingCapacity();
        try self.body_bytes.appendSlice(self.allocator, body);
        self.value.body = self.body_bytes.items;
    }

    pub fn json(self: *RequestBuilder, body: []const u8) !void {
        try self.setHeader("content-type", "application/json");
        try self.setBody(body);
    }

    pub fn jsonValue(self: *RequestBuilder, value: anytype) !void {
        try self.setHeader("content-type", "application/json");
        self.multipart_boundary = null;
        self.urlencoded_form_active = false;
        self.body_bytes.clearRetainingCapacity();

        var aw = std.Io.Writer.Allocating.fromArrayList(self.allocator, &self.body_bytes);
        errdefer aw.deinit();
        try std.json.Stringify.value(value, .{}, &aw.writer);
        self.body_bytes = aw.toArrayList();
        self.value.body = self.body_bytes.items;
    }

    pub fn form(self: *RequestBuilder, body: []const u8) !void {
        try self.setHeader("content-type", "application/x-www-form-urlencoded");
        try self.setBody(body);
        self.urlencoded_form_active = true;
    }

    pub fn formField(self: *RequestBuilder, name: []const u8, value: []const u8) !void {
        if (!self.urlencoded_form_active) {
            self.multipart_boundary = null;
            self.body_bytes.clearRetainingCapacity();
            self.urlencoded_form_active = true;
        }
        try self.setHeader("content-type", "application/x-www-form-urlencoded");
        if (self.body_bytes.items.len > 0) try self.body_bytes.append(self.allocator, '&');
        try appendUrlEncodedQueryComponent(&self.body_bytes, self.allocator, name);
        try self.body_bytes.append(self.allocator, '=');
        try appendUrlEncodedQueryComponent(&self.body_bytes, self.allocator, value);
        self.value.body = self.body_bytes.items;
    }

    pub fn formValue(self: *RequestBuilder, value: anytype) !void {
        const T = @TypeOf(value);
        const info = @typeInfo(T);
        if (info != .@"struct") @compileError("formValue expects a struct or anonymous struct");

        inline for (info.@"struct".fields) |field| {
            try self.formValueField(field.name, @field(value, field.name));
        }
    }

    fn formValueField(self: *RequestBuilder, name: []const u8, value: anytype) !void {
        const T = @TypeOf(value);
        switch (@typeInfo(T)) {
            .optional => {
                if (value) |inner| try self.formValueField(name, inner);
            },
            .pointer => |ptr| {
                switch (ptr.size) {
                    .slice => {
                        if (ptr.child == u8) {
                            try self.formField(name, value);
                        } else {
                            for (value) |item| try self.formValueField(name, item);
                        }
                    },
                    .one => switch (@typeInfo(ptr.child)) {
                        .array => |array| {
                            if (array.child == u8) {
                                try self.formField(name, value);
                            } else {
                                for (value.*) |item| try self.formValueField(name, item);
                            }
                        },
                        else => @compileError("formValue pointer fields must be strings or arrays"),
                    },
                    else => @compileError("formValue pointer fields must be strings or slices"),
                }
            },
            .array => |array| {
                if (array.child == u8) {
                    try self.formField(name, value[0..]);
                } else {
                    for (value) |item| try self.formValueField(name, item);
                }
            },
            .bool => try self.formField(name, if (value) "true" else "false"),
            .int, .comptime_int, .float, .comptime_float => {
                const text = try std.fmt.allocPrint(self.allocator, "{}", .{value});
                defer self.allocator.free(text);
                try self.formField(name, text);
            },
            .@"enum" => try self.formField(name, @tagName(value)),
            .@"struct" => {
                if (@hasDecl(T, "text")) {
                    try self.formField(name, value.text());
                } else {
                    @compileError("formValue struct fields must provide text() for form serialization");
                }
            },
            else => @compileError("unsupported formValue field type"),
        }
    }

    pub fn multipartField(self: *RequestBuilder, name: []const u8, value: []const u8) !void {
        try self.startMultipartPart();
        try appendMultipartDisposition(&self.body_bytes, self.allocator, name, null);
        try self.body_bytes.appendSlice(self.allocator, "\r\n\r\n");
        try self.body_bytes.appendSlice(self.allocator, value);
        try self.body_bytes.appendSlice(self.allocator, "\r\n");
        try self.finishMultipartBody();
    }

    pub fn multipartFile(self: *RequestBuilder, name: []const u8, filename: []const u8, content_type: []const u8, content: []const u8) !void {
        if (std.mem.indexOfAny(u8, content_type, "\r\n") != null) return error.InvalidHeader;
        try self.startMultipartPart();
        try appendMultipartDisposition(&self.body_bytes, self.allocator, name, filename);
        try self.body_bytes.appendSlice(self.allocator, "\r\ncontent-type: ");
        try self.body_bytes.appendSlice(self.allocator, content_type);
        try self.body_bytes.appendSlice(self.allocator, "\r\n\r\n");
        try self.body_bytes.appendSlice(self.allocator, content);
        try self.body_bytes.appendSlice(self.allocator, "\r\n");
        try self.finishMultipartBody();
    }

    fn startMultipartPart(self: *RequestBuilder) !void {
        const boundary = "zapi-boundary";
        if (self.multipart_boundary == null) {
            self.multipart_boundary = boundary;
            self.urlencoded_form_active = false;
            self.body_bytes.clearRetainingCapacity();
            const content_type = try std.fmt.allocPrint(self.allocator, "multipart/form-data; boundary={s}", .{boundary});
            defer self.allocator.free(content_type);
            try self.setHeader("content-type", content_type);
        } else {
            const closing = try std.fmt.allocPrint(self.allocator, "--{s}--", .{boundary});
            defer self.allocator.free(closing);
            if (std.mem.endsWith(u8, self.body_bytes.items, closing)) {
                self.body_bytes.items.len -= closing.len;
            }
        }

        try self.body_bytes.appendSlice(self.allocator, "--");
        try self.body_bytes.appendSlice(self.allocator, boundary);
        try self.body_bytes.appendSlice(self.allocator, "\r\n");
        self.value.body = self.body_bytes.items;
    }

    fn finishMultipartBody(self: *RequestBuilder) !void {
        const boundary = self.multipart_boundary.?;
        try self.body_bytes.appendSlice(self.allocator, "--");
        try self.body_bytes.appendSlice(self.allocator, boundary);
        try self.body_bytes.appendSlice(self.allocator, "--");
        self.value.body = self.body_bytes.items;
    }
};

pub const TestClient = struct {
    allocator: std.mem.Allocator,
    app: *ZAPI,
    client_options: TestClientOptions,
    default_headers: std.ArrayList(HeaderField) = .empty,
    default_query_params: std.ArrayList(HeaderField) = .empty,
    cookie_jar: CookieJar,
    started: bool = false,

    pub fn init(allocator: std.mem.Allocator, app: *ZAPI, client_options: TestClientOptions) TestClient {
        return .{
            .allocator = allocator,
            .app = app,
            .client_options = client_options,
            .cookie_jar = CookieJar.init(allocator),
        };
    }

    pub fn start(allocator: std.mem.Allocator, app: *ZAPI, client_options: TestClientOptions) !TestClient {
        var client = TestClient.init(allocator, app, client_options);
        errdefer client.deinit();
        try app.startup();
        client.started = true;
        return client;
    }

    pub fn deinit(self: *TestClient) void {
        if (self.started) {
            self.shutdown() catch {};
        }
        clearOwnedHeaderList(self.allocator, &self.default_headers);
        self.default_headers.deinit(self.allocator);
        clearOwnedHeaderList(self.allocator, &self.default_query_params);
        self.default_query_params.deinit(self.allocator);
        self.cookie_jar.deinit();
    }

    pub fn shutdown(self: *TestClient) !void {
        if (!self.started) return;
        try self.app.shutdown();
        self.started = false;
    }

    pub fn request(self: *TestClient, method: Method, target: []const u8) RequestBuilder {
        return Request.builder(self.allocator, method, target);
    }

    pub fn get(self: *TestClient, target: []const u8) !Response {
        return self.sendMethod(.GET, target);
    }

    pub fn post(self: *TestClient, target: []const u8) !Response {
        return self.sendMethod(.POST, target);
    }

    pub fn put(self: *TestClient, target: []const u8) !Response {
        return self.sendMethod(.PUT, target);
    }

    pub fn patch(self: *TestClient, target: []const u8) !Response {
        return self.sendMethod(.PATCH, target);
    }

    pub fn delete(self: *TestClient, target: []const u8) !Response {
        return self.sendMethod(.DELETE, target);
    }

    pub fn options(self: *TestClient, target: []const u8) !Response {
        return self.sendMethod(.OPTIONS, target);
    }

    pub fn head(self: *TestClient, target: []const u8) !Response {
        return self.sendMethod(.HEAD, target);
    }

    pub fn trace(self: *TestClient, target: []const u8) !Response {
        return self.sendMethod(.TRACE, target);
    }

    pub fn connect(self: *TestClient, target: []const u8) !Response {
        return self.sendMethod(.CONNECT, target);
    }

    pub fn getNoRedirects(self: *TestClient, target: []const u8) !Response {
        return self.sendMethodNoRedirects(.GET, target);
    }

    pub fn postNoRedirects(self: *TestClient, target: []const u8) !Response {
        return self.sendMethodNoRedirects(.POST, target);
    }

    pub fn putNoRedirects(self: *TestClient, target: []const u8) !Response {
        return self.sendMethodNoRedirects(.PUT, target);
    }

    pub fn patchNoRedirects(self: *TestClient, target: []const u8) !Response {
        return self.sendMethodNoRedirects(.PATCH, target);
    }

    pub fn deleteNoRedirects(self: *TestClient, target: []const u8) !Response {
        return self.sendMethodNoRedirects(.DELETE, target);
    }

    pub fn optionsNoRedirects(self: *TestClient, target: []const u8) !Response {
        return self.sendMethodNoRedirects(.OPTIONS, target);
    }

    pub fn headNoRedirects(self: *TestClient, target: []const u8) !Response {
        return self.sendMethodNoRedirects(.HEAD, target);
    }

    pub fn traceNoRedirects(self: *TestClient, target: []const u8) !Response {
        return self.sendMethodNoRedirects(.TRACE, target);
    }

    pub fn connectNoRedirects(self: *TestClient, target: []const u8) !Response {
        return self.sendMethodNoRedirects(.CONNECT, target);
    }

    pub fn getFollowRedirects(self: *TestClient, target: []const u8, follow_options: FollowRedirectOptions) !Response {
        return self.sendMethodFollowRedirects(.GET, target, follow_options);
    }

    pub fn postFollowRedirects(self: *TestClient, target: []const u8, follow_options: FollowRedirectOptions) !Response {
        return self.sendMethodFollowRedirects(.POST, target, follow_options);
    }

    pub fn putFollowRedirects(self: *TestClient, target: []const u8, follow_options: FollowRedirectOptions) !Response {
        return self.sendMethodFollowRedirects(.PUT, target, follow_options);
    }

    pub fn patchFollowRedirects(self: *TestClient, target: []const u8, follow_options: FollowRedirectOptions) !Response {
        return self.sendMethodFollowRedirects(.PATCH, target, follow_options);
    }

    pub fn deleteFollowRedirects(self: *TestClient, target: []const u8, follow_options: FollowRedirectOptions) !Response {
        return self.sendMethodFollowRedirects(.DELETE, target, follow_options);
    }

    pub fn optionsFollowRedirects(self: *TestClient, target: []const u8, follow_options: FollowRedirectOptions) !Response {
        return self.sendMethodFollowRedirects(.OPTIONS, target, follow_options);
    }

    pub fn headFollowRedirects(self: *TestClient, target: []const u8, follow_options: FollowRedirectOptions) !Response {
        return self.sendMethodFollowRedirects(.HEAD, target, follow_options);
    }

    pub fn traceFollowRedirects(self: *TestClient, target: []const u8, follow_options: FollowRedirectOptions) !Response {
        return self.sendMethodFollowRedirects(.TRACE, target, follow_options);
    }

    pub fn connectFollowRedirects(self: *TestClient, target: []const u8, follow_options: FollowRedirectOptions) !Response {
        return self.sendMethodFollowRedirects(.CONNECT, target, follow_options);
    }

    pub fn websocketText(self: *TestClient, target: []const u8, message: []const u8) !WebSocketTestResponse {
        return self.websocketTextWithHeaders(target, message, &.{});
    }

    pub fn websocketTextWithHeaders(self: *TestClient, target: []const u8, message: []const u8, headers: []const HeaderField) !WebSocketTestResponse {
        return self.websocketExchangeWithHeaders(target, &.{.{ .opcode = .text, .data = message }}, headers);
    }

    pub fn websocketJson(self: *TestClient, target: []const u8, body: []const u8) !WebSocketTestResponse {
        return self.websocketText(target, body);
    }

    pub fn websocketJsonWithHeaders(self: *TestClient, target: []const u8, body: []const u8, headers: []const HeaderField) !WebSocketTestResponse {
        return self.websocketTextWithHeaders(target, body, headers);
    }

    pub fn websocketJsonValue(self: *TestClient, target: []const u8, value: anytype) !WebSocketTestResponse {
        return self.websocketJsonValueWithHeaders(target, value, &.{});
    }

    pub fn websocketJsonValueWithHeaders(self: *TestClient, target: []const u8, value: anytype, headers: []const HeaderField) !WebSocketTestResponse {
        var body = std.Io.Writer.Allocating.init(self.allocator);
        defer body.deinit();
        try std.json.Stringify.value(value, .{}, &body.writer);
        return self.websocketJsonWithHeaders(target, body.written(), headers);
    }

    pub fn websocketExchange(self: *TestClient, target: []const u8, frames: []const WebSocketTestFrame) !WebSocketTestResponse {
        return self.websocketExchangeWithHeaders(target, frames, &.{});
    }

    pub fn websocketExchangeWithHeaders(self: *TestClient, target: []const u8, frames: []const WebSocketTestFrame, headers: []const HeaderField) !WebSocketTestResponse {
        const sec_key = "dGhlIHNhbXBsZSBub25jZQ==";

        var request_value = Request.init(.GET, target);
        const request_defaults = try testClientRequestDefaults(self.client_options);
        request_value.scheme = request_defaults.scheme;
        request_value.root_path = request_defaults.root_path;
        var request_host = request_defaults.host;
        if (try absoluteTargetForRequest(request_value)) |absolute_target| {
            request_value.scheme = absolute_target.scheme;
            request_value.path = stripRootPathPrefix(absolute_target.path, request_value.root_path);
            request_value.query = absolute_target.query;
            request_host = absolute_target.host;
        } else {
            request_value.path = stripRootPathPrefix(request_value.path, request_value.root_path);
        }

        var owned_query: ?[]u8 = null;
        defer if (owned_query) |query| self.allocator.free(query);
        if (try buildClientQuery(self.allocator, self.default_query_params.items, request_value.query)) |query| {
            owned_query = query;
            request_value.query = query;
        }

        const required_header_count: usize = 3;
        const request_headers = try self.allocator.alloc(HeaderField, required_header_count + headers.len);
        defer self.allocator.free(request_headers);
        request_headers[0] = .{ .name = "upgrade", .value = "websocket" };
        request_headers[1] = .{ .name = "connection", .value = "upgrade" };
        request_headers[2] = .{ .name = "sec-websocket-key", .value = sec_key };
        for (headers, 0..) |header_item, index| {
            request_headers[required_header_count + index] = header_item;
        }

        var request_cookie_jar = try self.cookie_jar.clone();
        defer request_cookie_jar.deinit();
        try request_cookie_jar.loadRequestHeaders(self.client_options.headers);
        try request_cookie_jar.loadRequestHeaders(self.default_headers.items);
        try request_cookie_jar.loadRequestHeaders(request_headers);

        var owned_headers: std.ArrayList(HeaderField) = .empty;
        defer {
            clearOwnedHeaderList(self.allocator, &owned_headers);
            owned_headers.deinit(self.allocator);
        }
        try buildClientHeaders(self.allocator, &owned_headers, self.client_options.headers, self.default_headers.items, request_headers, &request_cookie_jar, request_host, request_value.path, request_value.scheme);

        var request_bytes = std.Io.Writer.Allocating.init(self.allocator);
        errdefer request_bytes.deinit();
        try request_bytes.writer.writeAll("GET ");
        try request_bytes.writer.writeAll(request_value.path);
        if (request_value.query.len > 0) {
            try request_bytes.writer.writeByte('?');
            try request_bytes.writer.writeAll(request_value.query);
        }
        try request_bytes.writer.writeAll(" HTTP/1.1\r\n");
        for (owned_headers.items) |header_item| try request_bytes.writer.print("{s}: {s}\r\n", .{ header_item.name, header_item.value });
        try request_bytes.writer.writeAll("\r\n");
        for (frames) |frame| {
            try appendMaskedWebSocketFrame(&request_bytes.writer, frame.data, frame.opcode);
        }

        const owned_request = try request_bytes.toOwnedSlice();
        defer self.allocator.free(owned_request);
        var input = std.Io.Reader.fixed(owned_request);
        var output = std.Io.Writer.Allocating.init(self.allocator);
        errdefer output.deinit();

        var server = std.http.Server.init(&input, &output.writer);
        var http_request = try server.receiveHead();
        try self.app.handleHttp(&http_request);

        const raw_response = try output.toOwnedSlice();
        errdefer self.allocator.free(raw_response);
        var response = try parseWebSocketTestResponse(self.allocator, raw_response);
        errdefer response.deinit(self.allocator);
        try self.cookie_jar.applyResponseHeaders(response.headers.items, request_host, request_value.path);
        return response;
    }

    pub fn getQuery(self: *TestClient, target: []const u8, query: anytype) !Response {
        return self.sendQuery(.GET, target, query);
    }

    pub fn postQuery(self: *TestClient, target: []const u8, query: anytype) !Response {
        return self.sendQuery(.POST, target, query);
    }

    pub fn putQuery(self: *TestClient, target: []const u8, query: anytype) !Response {
        return self.sendQuery(.PUT, target, query);
    }

    pub fn patchQuery(self: *TestClient, target: []const u8, query: anytype) !Response {
        return self.sendQuery(.PATCH, target, query);
    }

    pub fn deleteQuery(self: *TestClient, target: []const u8, query: anytype) !Response {
        return self.sendQuery(.DELETE, target, query);
    }

    pub fn optionsQuery(self: *TestClient, target: []const u8, query: anytype) !Response {
        return self.sendQuery(.OPTIONS, target, query);
    }

    pub fn headQuery(self: *TestClient, target: []const u8, query: anytype) !Response {
        return self.sendQuery(.HEAD, target, query);
    }

    pub fn traceQuery(self: *TestClient, target: []const u8, query: anytype) !Response {
        return self.sendQuery(.TRACE, target, query);
    }

    pub fn connectQuery(self: *TestClient, target: []const u8, query: anytype) !Response {
        return self.sendQuery(.CONNECT, target, query);
    }

    pub fn postJson(self: *TestClient, target: []const u8, body: []const u8) !Response {
        return self.sendJson(.POST, target, body);
    }

    pub fn putJson(self: *TestClient, target: []const u8, body: []const u8) !Response {
        return self.sendJson(.PUT, target, body);
    }

    pub fn patchJson(self: *TestClient, target: []const u8, body: []const u8) !Response {
        return self.sendJson(.PATCH, target, body);
    }

    pub fn deleteJson(self: *TestClient, target: []const u8, body: []const u8) !Response {
        return self.sendJson(.DELETE, target, body);
    }

    pub fn optionsJson(self: *TestClient, target: []const u8, body: []const u8) !Response {
        return self.sendJson(.OPTIONS, target, body);
    }

    pub fn traceJson(self: *TestClient, target: []const u8, body: []const u8) !Response {
        return self.sendJson(.TRACE, target, body);
    }

    pub fn postJsonValue(self: *TestClient, target: []const u8, value: anytype) !Response {
        return self.sendJsonValue(.POST, target, value);
    }

    pub fn putJsonValue(self: *TestClient, target: []const u8, value: anytype) !Response {
        return self.sendJsonValue(.PUT, target, value);
    }

    pub fn patchJsonValue(self: *TestClient, target: []const u8, value: anytype) !Response {
        return self.sendJsonValue(.PATCH, target, value);
    }

    pub fn deleteJsonValue(self: *TestClient, target: []const u8, value: anytype) !Response {
        return self.sendJsonValue(.DELETE, target, value);
    }

    pub fn optionsJsonValue(self: *TestClient, target: []const u8, value: anytype) !Response {
        return self.sendJsonValue(.OPTIONS, target, value);
    }

    pub fn traceJsonValue(self: *TestClient, target: []const u8, value: anytype) !Response {
        return self.sendJsonValue(.TRACE, target, value);
    }

    pub fn postForm(self: *TestClient, target: []const u8, body: []const u8) !Response {
        return self.sendForm(.POST, target, body);
    }

    pub fn putForm(self: *TestClient, target: []const u8, body: []const u8) !Response {
        return self.sendForm(.PUT, target, body);
    }

    pub fn patchForm(self: *TestClient, target: []const u8, body: []const u8) !Response {
        return self.sendForm(.PATCH, target, body);
    }

    pub fn deleteForm(self: *TestClient, target: []const u8, body: []const u8) !Response {
        return self.sendForm(.DELETE, target, body);
    }

    pub fn optionsForm(self: *TestClient, target: []const u8, body: []const u8) !Response {
        return self.sendForm(.OPTIONS, target, body);
    }

    pub fn traceForm(self: *TestClient, target: []const u8, body: []const u8) !Response {
        return self.sendForm(.TRACE, target, body);
    }

    pub fn postFormFields(self: *TestClient, target: []const u8, fields: []const HeaderField) !Response {
        return self.sendFormFields(.POST, target, fields);
    }

    pub fn putFormFields(self: *TestClient, target: []const u8, fields: []const HeaderField) !Response {
        return self.sendFormFields(.PUT, target, fields);
    }

    pub fn patchFormFields(self: *TestClient, target: []const u8, fields: []const HeaderField) !Response {
        return self.sendFormFields(.PATCH, target, fields);
    }

    pub fn deleteFormFields(self: *TestClient, target: []const u8, fields: []const HeaderField) !Response {
        return self.sendFormFields(.DELETE, target, fields);
    }

    pub fn optionsFormFields(self: *TestClient, target: []const u8, fields: []const HeaderField) !Response {
        return self.sendFormFields(.OPTIONS, target, fields);
    }

    pub fn traceFormFields(self: *TestClient, target: []const u8, fields: []const HeaderField) !Response {
        return self.sendFormFields(.TRACE, target, fields);
    }

    pub fn postFormValue(self: *TestClient, target: []const u8, value: anytype) !Response {
        return self.sendFormValue(.POST, target, value);
    }

    pub fn putFormValue(self: *TestClient, target: []const u8, value: anytype) !Response {
        return self.sendFormValue(.PUT, target, value);
    }

    pub fn patchFormValue(self: *TestClient, target: []const u8, value: anytype) !Response {
        return self.sendFormValue(.PATCH, target, value);
    }

    pub fn deleteFormValue(self: *TestClient, target: []const u8, value: anytype) !Response {
        return self.sendFormValue(.DELETE, target, value);
    }

    pub fn optionsFormValue(self: *TestClient, target: []const u8, value: anytype) !Response {
        return self.sendFormValue(.OPTIONS, target, value);
    }

    pub fn traceFormValue(self: *TestClient, target: []const u8, value: anytype) !Response {
        return self.sendFormValue(.TRACE, target, value);
    }

    pub fn postMultipart(self: *TestClient, target: []const u8, fields: []const HeaderField, files: []const MultipartFileField) !Response {
        return self.sendMultipart(.POST, target, fields, files);
    }

    pub fn putMultipart(self: *TestClient, target: []const u8, fields: []const HeaderField, files: []const MultipartFileField) !Response {
        return self.sendMultipart(.PUT, target, fields, files);
    }

    pub fn patchMultipart(self: *TestClient, target: []const u8, fields: []const HeaderField, files: []const MultipartFileField) !Response {
        return self.sendMultipart(.PATCH, target, fields, files);
    }

    pub fn deleteMultipart(self: *TestClient, target: []const u8, fields: []const HeaderField, files: []const MultipartFileField) !Response {
        return self.sendMultipart(.DELETE, target, fields, files);
    }

    pub fn optionsMultipart(self: *TestClient, target: []const u8, fields: []const HeaderField, files: []const MultipartFileField) !Response {
        return self.sendMultipart(.OPTIONS, target, fields, files);
    }

    pub fn traceMultipart(self: *TestClient, target: []const u8, fields: []const HeaderField, files: []const MultipartFileField) !Response {
        return self.sendMultipart(.TRACE, target, fields, files);
    }

    pub fn header(self: *TestClient, name: []const u8, value: []const u8) !void {
        try appendOwnedHeader(self.allocator, &self.default_headers, name, value);
    }

    pub fn headerValue(self: *TestClient, name: []const u8) ?[]const u8 {
        for (self.default_headers.items) |item| {
            if (std.ascii.eqlIgnoreCase(item.name, name)) return item.value;
        }
        return null;
    }

    pub fn hasHeader(self: *TestClient, name: []const u8) bool {
        return self.headerValue(name) != null;
    }

    pub fn headerValues(self: *TestClient, allocator: std.mem.Allocator, name: []const u8) ![]const []const u8 {
        var count: usize = 0;
        for (self.default_headers.items) |item| {
            if (std.ascii.eqlIgnoreCase(item.name, name)) count += 1;
        }

        const values = try allocator.alloc([]const u8, count);
        var index: usize = 0;
        for (self.default_headers.items) |item| {
            if (!std.ascii.eqlIgnoreCase(item.name, name)) continue;
            values[index] = item.value;
            index += 1;
        }
        return values;
    }

    pub fn setHeader(self: *TestClient, name: []const u8, value: []const u8) !void {
        removeOwnedHeaders(self.allocator, &self.default_headers, name);
        try self.header(name, value);
    }

    pub fn accept(self: *TestClient, value: []const u8) !void {
        try self.setHeader("accept", value);
    }

    pub fn userAgent(self: *TestClient, value: []const u8) !void {
        try self.setHeader("user-agent", value);
    }

    pub fn removeHeader(self: *TestClient, name: []const u8) void {
        removeOwnedHeaders(self.allocator, &self.default_headers, name);
    }

    pub fn clearHeaders(self: *TestClient) void {
        clearOwnedHeaderList(self.allocator, &self.default_headers);
    }

    pub fn queryParam(self: *TestClient, name: []const u8, value: []const u8) !void {
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        const owned_value = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(owned_value);
        try self.default_query_params.append(self.allocator, .{ .name = owned_name, .value = owned_value });
    }

    pub fn queryParamValue(self: *TestClient, name: []const u8) ?[]const u8 {
        var result: ?[]const u8 = null;
        for (self.default_query_params.items) |item| {
            if (std.mem.eql(u8, item.name, name)) result = item.value;
        }
        return result;
    }

    pub fn hasQueryParam(self: *TestClient, name: []const u8) bool {
        return self.queryParamValue(name) != null;
    }

    pub fn queryParamValues(self: *TestClient, allocator: std.mem.Allocator, name: []const u8) ![]const []const u8 {
        var count: usize = 0;
        for (self.default_query_params.items) |item| {
            if (std.mem.eql(u8, item.name, name)) count += 1;
        }

        const values = try allocator.alloc([]const u8, count);
        var index: usize = 0;
        for (self.default_query_params.items) |item| {
            if (!std.mem.eql(u8, item.name, name)) continue;
            values[index] = item.value;
            index += 1;
        }
        return values;
    }

    pub fn setQueryParam(self: *TestClient, name: []const u8, value: []const u8) !void {
        removeOwnedFields(self.allocator, &self.default_query_params, name);
        try self.queryParam(name, value);
    }

    pub fn removeQueryParam(self: *TestClient, name: []const u8) void {
        removeOwnedFields(self.allocator, &self.default_query_params, name);
    }

    pub fn clearQueryParams(self: *TestClient) void {
        clearOwnedHeaderList(self.allocator, &self.default_query_params);
    }

    pub fn bearerAuth(self: *TestClient, token: []const u8) !void {
        const header_value = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{token});
        defer self.allocator.free(header_value);
        try self.setHeader("authorization", header_value);
    }

    pub fn basicAuth(self: *TestClient, username: []const u8, password: []const u8) !void {
        const raw = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ username, password });
        defer self.allocator.free(raw);

        const encoded = try self.allocator.alloc(u8, std.base64.standard.Encoder.calcSize(raw.len));
        defer self.allocator.free(encoded);
        const encoded_value = std.base64.standard.Encoder.encode(encoded, raw);

        const header_value = try std.fmt.allocPrint(self.allocator, "Basic {s}", .{encoded_value});
        defer self.allocator.free(header_value);
        try self.setHeader("authorization", header_value);
    }

    pub fn apiKeyHeader(self: *TestClient, name: []const u8, key: []const u8) !void {
        try self.setHeader(name, key);
    }

    pub fn apiKeyQuery(self: *TestClient, name: []const u8, key: []const u8) !void {
        try self.queryParam(name, key);
    }

    pub fn apiKeyCookie(self: *TestClient, name: []const u8, key: []const u8) !void {
        try self.cookie(name, key);
    }

    pub fn cookie(self: *TestClient, name: []const u8, value: []const u8) !void {
        try validateCookieToken(name);
        try validateCookieValue(value);
        try self.cookie_jar.put(name, value);
    }

    pub fn cookieValue(self: *TestClient, name: []const u8) ?[]const u8 {
        return self.cookie_jar.get(name);
    }

    pub fn cookies(self: *TestClient, allocator: std.mem.Allocator) !CookieParams {
        var params = CookieParams.init(allocator);
        errdefer params.deinit();
        for (self.cookie_jar.entries.items) |entry| {
            try params.put(entry.name, entry.value);
        }
        return params;
    }

    pub fn deleteCookie(self: *TestClient, name: []const u8) !void {
        try validateCookieToken(name);
        self.cookie_jar.remove(name);
    }

    pub fn clearCookies(self: *TestClient) void {
        self.cookie_jar.clear();
    }

    pub fn send(self: *TestClient, builder: *RequestBuilder) !Response {
        return self.sendWithOptions(builder, .{});
    }

    pub fn sendWithOptions(self: *TestClient, builder: *RequestBuilder, send_options: TestClientSendOptions) !Response {
        var request_value = builder.request();
        const request_defaults = try testClientRequestDefaults(self.client_options);
        request_value.scheme = request_defaults.scheme;
        request_value.root_path = request_defaults.root_path;
        request_value.client = self.client_options.client;
        var request_host = request_defaults.host;
        if (try absoluteTargetForRequest(request_value)) |target| {
            request_value.scheme = target.scheme;
            request_value.path = stripRootPathPrefix(target.path, request_value.root_path);
            request_value.query = target.query;
            request_host = target.host;
        } else {
            request_value.path = stripRootPathPrefix(request_value.path, request_value.root_path);
        }

        var owned_query: ?[]u8 = null;
        defer if (owned_query) |query| self.allocator.free(query);
        if (try buildClientQuery(self.allocator, self.default_query_params.items, request_value.query)) |query| {
            owned_query = query;
            request_value.query = query;
        }

        var request_cookie_jar = try self.cookie_jar.clone();
        defer request_cookie_jar.deinit();
        try request_cookie_jar.loadRequestHeaders(self.client_options.headers);
        try request_cookie_jar.loadRequestHeaders(self.default_headers.items);
        try request_cookie_jar.loadRequestHeaders(request_value.headers);

        var owned_headers: std.ArrayList(HeaderField) = .empty;
        defer {
            clearOwnedHeaderList(self.allocator, &owned_headers);
            owned_headers.deinit(self.allocator);
        }
        try buildClientHeaders(self.allocator, &owned_headers, self.client_options.headers, self.default_headers.items, request_value.headers, &request_cookie_jar, request_host, request_value.path, request_value.scheme);
        request_value.headers = owned_headers.items;

        const follow_redirects = send_options.follow_redirects orelse self.client_options.follow_redirects;
        const max_redirects = send_options.max_redirects orelse self.client_options.max_redirects;
        const raise_server_exceptions = send_options.raise_server_exceptions orelse self.client_options.raise_server_exceptions;
        if (follow_redirects) {
            return self.followRedirects(request_value, &request_cookie_jar, max_redirects, raise_server_exceptions);
        }

        var response = try self.handleAppRequest(request_value, raise_server_exceptions);
        errdefer response.deinit(self.allocator);
        try self.setResponseUrl(&response, request_value);
        try self.cookie_jar.applyResponseHeaders(response.headers.items, request_host, request_value.path);
        return response;
    }

    pub fn sendFollowRedirects(self: *TestClient, builder: *RequestBuilder, follow_options: FollowRedirectOptions) !Response {
        return self.sendWithOptions(builder, .{
            .follow_redirects = true,
            .max_redirects = follow_options.max_redirects,
        });
    }

    pub fn sendNoRedirects(self: *TestClient, builder: *RequestBuilder) !Response {
        return self.sendWithOptions(builder, .{ .follow_redirects = false });
    }

    fn handleAppRequest(self: *TestClient, request_value: Request, raise_server_exceptions: bool) !Response {
        if (raise_server_exceptions) {
            return self.app.handleOrRaise(request_value);
        }
        return self.app.handle(request_value);
    }

    fn setResponseUrl(self: *TestClient, response: *Response, request_value: Request) !void {
        if (response.url) |url| {
            self.allocator.free(url);
            response.url = null;
        }
        response.url = try request_value.url(self.allocator);
    }

    fn sendMethod(self: *TestClient, method: Method, target: []const u8) !Response {
        var builder = self.request(method, target);
        defer builder.deinit();
        return self.send(&builder);
    }

    fn sendMethodNoRedirects(self: *TestClient, method: Method, target: []const u8) !Response {
        return self.sendMethodWithOptions(method, target, .{ .follow_redirects = false });
    }

    fn sendMethodFollowRedirects(self: *TestClient, method: Method, target: []const u8, follow_options: FollowRedirectOptions) !Response {
        return self.sendMethodWithOptions(method, target, .{
            .follow_redirects = true,
            .max_redirects = follow_options.max_redirects,
        });
    }

    fn sendMethodWithOptions(self: *TestClient, method: Method, target: []const u8, send_options: TestClientSendOptions) !Response {
        var builder = self.request(method, target);
        defer builder.deinit();
        return self.sendWithOptions(&builder, send_options);
    }

    fn sendQuery(self: *TestClient, method: Method, target: []const u8, query: anytype) !Response {
        var builder = self.request(method, target);
        defer builder.deinit();
        try builder.queryValue(query);
        return self.send(&builder);
    }

    fn sendJson(self: *TestClient, method: Method, target: []const u8, body: []const u8) !Response {
        var builder = self.request(method, target);
        defer builder.deinit();
        try builder.json(body);
        return self.send(&builder);
    }

    fn sendJsonValue(self: *TestClient, method: Method, target: []const u8, value: anytype) !Response {
        var builder = self.request(method, target);
        defer builder.deinit();
        try builder.jsonValue(value);
        return self.send(&builder);
    }

    fn sendForm(self: *TestClient, method: Method, target: []const u8, body: []const u8) !Response {
        var builder = self.request(method, target);
        defer builder.deinit();
        try builder.form(body);
        return self.send(&builder);
    }

    fn sendFormFields(self: *TestClient, method: Method, target: []const u8, fields: []const HeaderField) !Response {
        var builder = self.request(method, target);
        defer builder.deinit();
        for (fields) |field| {
            try builder.formField(field.name, field.value);
        }
        return self.send(&builder);
    }

    fn sendFormValue(self: *TestClient, method: Method, target: []const u8, value: anytype) !Response {
        var builder = self.request(method, target);
        defer builder.deinit();
        try builder.formValue(value);
        return self.send(&builder);
    }

    fn sendMultipart(self: *TestClient, method: Method, target: []const u8, fields: []const HeaderField, files: []const MultipartFileField) !Response {
        var builder = self.request(method, target);
        defer builder.deinit();
        for (fields) |field| {
            try builder.multipartField(field.name, field.value);
        }
        for (files) |file| {
            try builder.multipartFile(file.name, file.filename, file.content_type, file.content);
        }
        return self.send(&builder);
    }

    fn followRedirects(self: *TestClient, request_value: Request, request_cookie_jar: *CookieJar, max_redirects: usize, raise_server_exceptions: bool) !Response {
        var current = request_value;
        const base_headers = request_value.headers;
        var owned_target: ?[]u8 = null;
        defer if (owned_target) |target| self.allocator.free(target);

        var redirect_headers: std.ArrayList(HeaderField) = .empty;
        defer {
            clearOwnedHeaderList(self.allocator, &redirect_headers);
            redirect_headers.deinit(self.allocator);
        }

        var history: std.ArrayList(Response) = .empty;
        errdefer {
            for (history.items) |*history_response| history_response.deinit(self.allocator);
            history.deinit(self.allocator);
        }

        var redirect_count: usize = 0;
        while (true) {
            var response = try self.handleAppRequest(current, raise_server_exceptions);
            errdefer response.deinit(self.allocator);
            try self.setResponseUrl(&response, current);
            try request_cookie_jar.applyResponseHeaders(response.headers.items, current.header("host"), current.path);
            try self.cookie_jar.applyResponseHeaders(response.headers.items, current.header("host"), current.path);

            const status = response.status;
            if (!redirectStatus(status)) {
                response.history = history;
                return response;
            }

            const location = response.header("location") orelse return response;
            if (redirect_count >= max_redirects) return error.TooManyRedirects;
            redirect_count += 1;

            const target = try redirectTarget(self.allocator, current, location);
            errdefer self.allocator.free(target.path);
            const next_method = redirectMethod(current.method, status);
            const preserve_body = redirectPreservesBody(status);
            const request_scheme = target.scheme orelse current.scheme;
            const request_host = target.host orelse current.header("host");
            const root_path = current.root_path;
            const client_address = current.client;
            const body = current.body;
            const next_path = stripRootPathPrefix(target.path, root_path);
            const next_request = Request.init(next_method, next_path);
            try buildRedirectHeaders(self.allocator, &redirect_headers, base_headers, preserve_body, request_cookie_jar, request_host, next_request.path, request_scheme);

            try history.append(self.allocator, response);
            if (owned_target) |previous_target| self.allocator.free(previous_target);
            owned_target = target.path;

            current = next_request;
            current.scheme = request_scheme;
            current.root_path = root_path;
            current.client = client_address;
            current.headers = redirect_headers.items;
            if (preserve_body) current.body = body;
        }
    }
};

fn appendMaskedWebSocketFrame(writer: *std.Io.Writer, data: []const u8, opcode: std.http.Server.WebSocket.Opcode) !void {
    try writer.writeByte(@as(u8, 0x80) | @as(u8, @intCast(@intFromEnum(opcode))));
    const mask_bit: u8 = 0x80;
    switch (data.len) {
        0...125 => try writer.writeByte(mask_bit | @as(u8, @intCast(data.len))),
        126...0xffff => {
            try writer.writeByte(mask_bit | 126);
            try writer.writeInt(u16, @intCast(data.len), .big);
        },
        else => {
            try writer.writeByte(mask_bit | 127);
            try writer.writeInt(u64, @intCast(data.len), .big);
        },
    }

    const mask = [_]u8{ 0x01, 0x02, 0x03, 0x04 };
    try writer.writeAll(&mask);
    for (data, 0..) |byte, index| {
        try writer.writeByte(byte ^ mask[index % mask.len]);
    }
}

fn parseWebSocketTestResponse(allocator: std.mem.Allocator, raw_response: []u8) !WebSocketTestResponse {
    const head_end = std.mem.indexOf(u8, raw_response, "\r\n\r\n") orelse return error.InvalidResponse;
    const head = raw_response[0..head_end];
    const body = raw_response[head_end + 4 ..];

    var line_it = std.mem.splitSequence(u8, head, "\r\n");
    const status_line = line_it.next() orelse return error.InvalidResponse;
    var status_it = std.mem.splitScalar(u8, status_line, ' ');
    _ = status_it.next() orelse return error.InvalidResponse;
    const status_text = status_it.next() orelse return error.InvalidResponse;
    const status_code = try std.fmt.parseInt(u16, status_text, 10);

    var headers: std.ArrayList(HeaderField) = .empty;
    errdefer {
        clearOwnedHeaderList(allocator, &headers);
        headers.deinit(allocator);
    }

    while (line_it.next()) |line| {
        if (line.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.InvalidResponse;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        try headers.append(allocator, try ownedHeaderField(allocator, name, value));
    }

    var messages: std.ArrayList(WebSocketTestMessage) = .empty;
    errdefer {
        for (messages.items) |message| allocator.free(message.data);
        messages.deinit(allocator);
    }

    var offset: usize = 0;
    while (offset < body.len) {
        const parsed = try parseWebSocketServerMessage(allocator, body[offset..]);
        errdefer allocator.free(parsed.message.data);
        try messages.append(allocator, parsed.message);
        offset += parsed.consumed;
    }

    var first_message: ?WebSocketTestMessage = null;
    errdefer if (first_message) |value| allocator.free(value.data);
    if (messages.items.len > 0) {
        first_message = .{
            .opcode = messages.items[0].opcode,
            .data = try allocator.dupe(u8, messages.items[0].data),
        };
    }

    return .{
        .status = Status.fromCode(status_code),
        .headers = headers,
        .message = first_message,
        .messages = messages,
        .raw_response = raw_response,
    };
}

const ParsedWebSocketServerMessage = struct {
    message: WebSocketTestMessage,
    consumed: usize,
};

fn parseWebSocketServerMessage(allocator: std.mem.Allocator, body: []const u8) !ParsedWebSocketServerMessage {
    if (body.len < 2) return error.InvalidResponse;
    const opcode: std.http.Server.WebSocket.Opcode = @enumFromInt(body[0] & 0x0f);
    const masked = (body[1] & 0x80) != 0;
    if (masked) return error.InvalidResponse;
    const len_code = body[1] & 0x7f;
    var offset: usize = 2;
    const len: usize = switch (len_code) {
        126 => blk: {
            if (body.len < offset + 2) return error.InvalidResponse;
            const value = std.mem.readInt(u16, body[offset..][0..2], .big);
            offset += 2;
            break :blk value;
        },
        127 => blk: {
            if (body.len < offset + 8) return error.InvalidResponse;
            const value = std.mem.readInt(u64, body[offset..][0..8], .big);
            offset += 8;
            break :blk std.math.cast(usize, value) orelse return error.InvalidResponse;
        },
        else => len_code,
    };
    if (body.len < offset + len) return error.InvalidResponse;
    return .{
        .message = .{
            .opcode = opcode,
            .data = try allocator.dupe(u8, body[offset .. offset + len]),
        },
        .consumed = offset + len,
    };
}

const ParsedSetCookie = cookies_mod.ParsedSetCookie;
const parseSetCookiePair = cookies_mod.parseSetCookiePair;
const parseSetCookieInto = cookies_mod.parseSetCookieInto;
const setCookieAttribute = cookies_mod.setCookieAttribute;
const setCookieAttributePresent = cookies_mod.setCookieAttributePresent;
const setCookieDeletes = cookies_mod.setCookieDeletes;
const cookieExpiresInPast = cookies_mod.cookieExpiresInPast;
const optionalEql = cookies_mod.optionalEql;
const normalizeCookieDomain = cookies_mod.normalizeCookieDomain;
const cookieHostName = cookies_mod.cookieHostName;
const defaultCookiePath = cookies_mod.defaultCookiePath;
const cookieEntryMatches = cookies_mod.cookieEntryMatches;
const cookieDomainMatches = cookies_mod.cookieDomainMatches;
const cookieDomainMatchesRequestHost = cookies_mod.cookieDomainMatchesRequestHost;
const cookiePathMatches = cookies_mod.cookiePathMatches;
pub const makeSetCookieHeader = cookies_mod.makeSetCookieHeader;
pub const makeDeleteCookieHeader = cookies_mod.makeDeleteCookieHeader;
const validateCookieToken = cookies_mod.validateCookieToken;
const validateCookieValue = cookies_mod.validateCookieValue;
const validateCookieAttributeValue = cookies_mod.validateCookieAttributeValue;

const CookieJarEntry = struct {
    name: []u8,
    value: []u8,
    domain: ?[]u8 = null,
    path: ?[]u8 = null,
    host_only: bool = false,
    secure: bool = false,
};

const CookieJar = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(CookieJarEntry) = .empty,

    fn init(allocator: std.mem.Allocator) CookieJar {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *CookieJar) void {
        self.clear();
        self.entries.deinit(self.allocator);
    }

    fn clear(self: *CookieJar) void {
        for (self.entries.items) |entry| {
            self.allocator.free(entry.name);
            self.allocator.free(entry.value);
            if (entry.domain) |domain| self.allocator.free(domain);
            if (entry.path) |path| self.allocator.free(path);
        }
        self.entries.clearRetainingCapacity();
    }

    fn clone(self: *CookieJar) !CookieJar {
        var cloned = CookieJar.init(self.allocator);
        errdefer cloned.deinit();
        for (self.entries.items) |entry| {
            try cloned.putScoped(entry.name, entry.value, entry.domain, entry.path, entry.host_only, entry.secure);
        }
        return cloned;
    }

    fn loadRequestHeaders(self: *CookieJar, headers: []const HeaderField) !void {
        for (headers) |header_item| {
            if (!std.ascii.eqlIgnoreCase(header_item.name, "cookie")) continue;
            try self.loadCookieHeader(header_item.value);
        }
    }

    fn loadCookieHeader(self: *CookieJar, header_value: []const u8) !void {
        var it = std.mem.splitScalar(u8, header_value, ';');
        while (it.next()) |raw_part| {
            const part = std.mem.trim(u8, raw_part, " \t");
            if (part.len == 0) continue;
            const eq_idx = std.mem.indexOfScalar(u8, part, '=') orelse continue;
            const name = std.mem.trim(u8, part[0..eq_idx], " \t");
            const value = std.mem.trim(u8, part[eq_idx + 1 ..], " \t");
            if (name.len == 0) continue;
            try self.put(name, value);
        }
    }

    fn applyResponseHeaders(self: *CookieJar, headers: []const HeaderField, request_host: ?[]const u8, request_path: []const u8) !void {
        for (headers) |header_item| {
            if (!std.ascii.eqlIgnoreCase(header_item.name, "set-cookie")) continue;
            try self.applySetCookie(header_item.value, request_host, request_path);
        }
    }

    fn applySetCookie(self: *CookieJar, header_value: []const u8, request_host: ?[]const u8, request_path: []const u8) !void {
        const parsed = parseSetCookiePair(header_value) orelse return;
        const attributes = header_value[parsed.pair_end..];
        const raw_domain = setCookieAttribute(attributes, "domain");
        const domain = if (raw_domain) |value| blk: {
            const normalized_domain = normalizeCookieDomain(value);
            if (request_host) |host| {
                if (!cookieDomainMatchesRequestHost(cookieHostName(host), normalized_domain)) return;
            }
            break :blk normalized_domain;
        } else if (request_host) |host|
            cookieHostName(host)
        else
            null;
        const path = setCookieAttribute(attributes, "path") orelse defaultCookiePath(request_path);
        const host_only = raw_domain == null and domain != null;
        const secure = setCookieAttributePresent(attributes, "secure");

        if (setCookieDeletes(attributes)) {
            self.removeScoped(parsed.name, domain, path, host_only);
            return;
        }

        try self.putScoped(parsed.name, parsed.value, domain, path, host_only, secure);
    }

    fn put(self: *CookieJar, name: []const u8, value: []const u8) !void {
        self.remove(name);
        try self.putScoped(name, value, null, "/", false, false);
    }

    fn putScoped(self: *CookieJar, name: []const u8, value: []const u8, domain: ?[]const u8, path: ?[]const u8, host_only: bool, secure: bool) !void {
        for (self.entries.items) |*entry| {
            if (!std.mem.eql(u8, entry.name, name)) continue;
            if (!optionalEql(entry.domain, domain)) continue;
            if (!optionalEql(entry.path, path)) continue;
            if (entry.host_only != host_only) continue;
            const owned_value = try self.allocator.dupe(u8, value);
            self.allocator.free(entry.value);
            entry.value = owned_value;
            entry.secure = secure;
            return;
        }

        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        const owned_value = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(owned_value);
        const owned_domain = if (domain) |domain_value| try self.allocator.dupe(u8, domain_value) else null;
        errdefer if (owned_domain) |owned_domain_value| self.allocator.free(owned_domain_value);
        const owned_path = if (path) |path_value| try self.allocator.dupe(u8, path_value) else null;
        errdefer if (owned_path) |owned_path_value| self.allocator.free(owned_path_value);
        try self.entries.append(self.allocator, .{
            .name = owned_name,
            .value = owned_value,
            .domain = owned_domain,
            .path = owned_path,
            .host_only = host_only,
            .secure = secure,
        });
    }

    fn remove(self: *CookieJar, name: []const u8) void {
        var index: usize = 0;
        while (index < self.entries.items.len) {
            if (std.mem.eql(u8, self.entries.items[index].name, name)) {
                const entry = self.entries.swapRemove(index);
                self.allocator.free(entry.name);
                self.allocator.free(entry.value);
                if (entry.domain) |domain| self.allocator.free(domain);
                if (entry.path) |path| self.allocator.free(path);
            } else {
                index += 1;
            }
        }
    }

    fn removeScoped(self: *CookieJar, name: []const u8, domain: ?[]const u8, path: ?[]const u8, host_only: bool) void {
        var index: usize = 0;
        while (index < self.entries.items.len) {
            const entry = self.entries.items[index];
            if (std.mem.eql(u8, entry.name, name) and optionalEql(entry.domain, domain) and optionalEql(entry.path, path) and entry.host_only == host_only) {
                const removed = self.entries.swapRemove(index);
                self.allocator.free(removed.name);
                self.allocator.free(removed.value);
                if (removed.domain) |removed_domain| self.allocator.free(removed_domain);
                if (removed.path) |removed_path| self.allocator.free(removed_path);
            } else {
                index += 1;
            }
        }
    }

    fn get(self: *CookieJar, name: []const u8) ?[]const u8 {
        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry.value;
        }
        return null;
    }

    fn headerValue(self: *CookieJar, host: ?[]const u8, path: []const u8, scheme: []const u8) !?[]u8 {
        var out = std.Io.Writer.Allocating.init(self.allocator);
        errdefer out.deinit();

        const written_entries = try self.allocator.alloc(bool, self.entries.items.len);
        defer self.allocator.free(written_entries);
        @memset(written_entries, false);

        var wrote = false;
        while (nextCookieHeaderEntry(self.entries.items, written_entries, host, path, scheme)) |index| {
            written_entries[index] = true;
            const entry = self.entries.items[index];
            if (wrote) try out.writer.writeAll("; ");
            wrote = true;
            try out.writer.writeAll(entry.name);
            try out.writer.writeByte('=');
            try out.writer.writeAll(entry.value);
        }

        if (!wrote) {
            out.deinit();
            return null;
        }
        const value = try out.toOwnedSlice();
        return value;
    }
};

fn nextCookieHeaderEntry(entries: []const CookieJarEntry, written_entries: []const bool, host: ?[]const u8, path: []const u8, scheme: []const u8) ?usize {
    var best: ?usize = null;
    for (entries, 0..) |entry, index| {
        if (written_entries[index]) continue;
        if (!cookieEntryMatches(entry, host, path, scheme)) continue;
        const best_index = best orelse {
            best = index;
            continue;
        };
        if (cookiePathSpecificity(entry) < cookiePathSpecificity(entries[best_index])) {
            best = index;
        }
    }
    return best;
}

fn cookiePathSpecificity(entry: CookieJarEntry) usize {
    const path = entry.path orelse @as([]const u8, "/");
    return path.len;
}

fn buildClientHeaders(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(HeaderField),
    option_headers: []const HeaderField,
    default_headers: []const HeaderField,
    request_headers: []const HeaderField,
    cookie_jar: *CookieJar,
    host: ?[]const u8,
    path: []const u8,
    scheme: []const u8,
) !void {
    clearOwnedHeaderList(allocator, out);
    errdefer clearOwnedHeaderList(allocator, out);

    for (option_headers) |header_item| {
        if (std.ascii.eqlIgnoreCase(header_item.name, "cookie")) continue;
        if (headerListContains(default_headers, header_item.name)) continue;
        if (headerListContains(request_headers, header_item.name)) continue;
        try out.append(allocator, try ownedHeaderField(allocator, header_item.name, header_item.value));
    }

    for (default_headers) |header_item| {
        if (std.ascii.eqlIgnoreCase(header_item.name, "cookie")) continue;
        if (headerListContains(request_headers, header_item.name)) continue;
        try out.append(allocator, try ownedHeaderField(allocator, header_item.name, header_item.value));
    }

    for (request_headers) |header_item| {
        if (std.ascii.eqlIgnoreCase(header_item.name, "cookie")) continue;
        try out.append(allocator, try ownedHeaderField(allocator, header_item.name, header_item.value));
    }

    try appendDefaultClientHeader(allocator, out, option_headers, default_headers, request_headers, "user-agent", "testclient");
    try appendDefaultClientHeader(allocator, out, option_headers, default_headers, request_headers, "accept", "*/*");
    try appendDefaultClientHeader(allocator, out, option_headers, default_headers, request_headers, "accept-encoding", "gzip, deflate, zstd");
    try appendDefaultClientHeader(allocator, out, option_headers, default_headers, request_headers, "connection", "keep-alive");

    if (host) |value| {
        if (!headerListContains(option_headers, "host") and !headerListContains(default_headers, "host") and !headerListContains(request_headers, "host")) {
            try out.append(allocator, try ownedHeaderField(allocator, "host", value));
        }
    }

    const cookie_header = try cookie_jar.headerValue(host, path, scheme) orelse return;
    defer allocator.free(cookie_header);
    try out.append(allocator, try ownedHeaderField(allocator, "cookie", cookie_header));
}

fn buildClientQuery(allocator: std.mem.Allocator, default_query_params: []const HeaderField, request_query: []const u8) !?[]u8 {
    if (default_query_params.len == 0) return null;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    for (default_query_params) |param| {
        if (out.items.len > 0) try out.append(allocator, '&');
        try appendUrlEncodedQueryComponent(&out, allocator, param.name);
        try out.append(allocator, '=');
        try appendUrlEncodedQueryComponent(&out, allocator, param.value);
    }

    if (request_query.len > 0) {
        if (out.items.len > 0) try out.append(allocator, '&');
        try out.appendSlice(allocator, request_query);
    }

    return try out.toOwnedSlice(allocator);
}

fn appendDefaultClientHeader(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(HeaderField),
    option_headers: []const HeaderField,
    default_headers: []const HeaderField,
    request_headers: []const HeaderField,
    name: []const u8,
    value: []const u8,
) !void {
    if (headerListContains(option_headers, name)) return;
    if (headerListContains(default_headers, name)) return;
    if (headerListContains(request_headers, name)) return;
    try out.append(allocator, try ownedHeaderField(allocator, name, value));
}

fn headerListContains(headers: []const HeaderField, name: []const u8) bool {
    for (headers) |header_item| {
        if (std.ascii.eqlIgnoreCase(header_item.name, name)) return true;
    }
    return false;
}

fn headerValue(headers: []const HeaderField, name: []const u8) ?[]const u8 {
    for (headers) |header_item| {
        if (std.ascii.eqlIgnoreCase(header_item.name, name)) return header_item.value;
    }
    return null;
}

fn buildRedirectHeaders(allocator: std.mem.Allocator, out: *std.ArrayList(HeaderField), base_headers: []const HeaderField, preserve_body: bool, cookie_jar: *CookieJar, host: ?[]const u8, path: []const u8, scheme: []const u8) !void {
    clearOwnedHeaderList(allocator, out);
    errdefer clearOwnedHeaderList(allocator, out);

    for (base_headers) |header_item| {
        if (std.ascii.eqlIgnoreCase(header_item.name, "cookie")) continue;
        if (std.ascii.eqlIgnoreCase(header_item.name, "host")) continue;
        if (!preserve_body and redirectBodyHeader(header_item.name)) continue;
        try out.append(allocator, try ownedHeaderField(allocator, header_item.name, header_item.value));
    }

    if (host) |value| {
        try out.append(allocator, try ownedHeaderField(allocator, "host", value));
    }

    const cookie_header = try cookie_jar.headerValue(host, path, scheme) orelse return;
    defer allocator.free(cookie_header);
    try out.append(allocator, try ownedHeaderField(allocator, "cookie", cookie_header));
}

fn redirectBodyHeader(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "content-type") or
        std.ascii.eqlIgnoreCase(name, "content-length") or
        std.ascii.eqlIgnoreCase(name, "transfer-encoding");
}

fn removeOwnedHeaders(allocator: std.mem.Allocator, headers: *std.ArrayList(HeaderField), name: []const u8) void {
    var write: usize = 0;
    for (headers.items) |header_item| {
        if (std.ascii.eqlIgnoreCase(header_item.name, name)) {
            allocator.free(header_item.name);
            allocator.free(header_item.value);
            continue;
        }
        headers.items[write] = header_item;
        write += 1;
    }
    headers.items = headers.items[0..write];
}

fn removeOwnedFields(allocator: std.mem.Allocator, fields: *std.ArrayList(HeaderField), name: []const u8) void {
    var write: usize = 0;
    for (fields.items) |field| {
        if (std.mem.eql(u8, field.name, name)) {
            allocator.free(field.name);
            allocator.free(field.value);
            continue;
        }
        fields.items[write] = field;
        write += 1;
    }
    fields.items = fields.items[0..write];
}

const clearOwnedHeaderList = headers_mod.clearOwned;

fn redirectStatus(status: Status) bool {
    return status == .moved_permanently or
        status == .found or
        status == .see_other or
        status == .temporary_redirect or
        status == .permanent_redirect;
}

fn redirectPreservesBody(status: Status) bool {
    return status == .temporary_redirect or status == .permanent_redirect;
}

fn redirectMethod(method: Method, status: Status) Method {
    if (redirectPreservesBody(status)) return method;
    if (status == .see_other) return if (method == .HEAD) .HEAD else .GET;
    return switch (method) {
        .GET, .HEAD, .TRACE => method,
        .CONNECT => .GET,
        else => .GET,
    };
}

const RedirectTarget = urls.RedirectTarget;
const redirectTarget = urls.redirectTarget;
const normalizeRedirectTarget = urls.normalizeRedirectTarget;
const redirectNextUrl = urls.redirectNextUrl;

fn appendMultipartDisposition(out: *std.ArrayList(u8), allocator: std.mem.Allocator, name: []const u8, filename: ?[]const u8) !void {
    try validateMultipartDispositionValue(name);
    if (filename) |value| try validateMultipartDispositionValue(value);

    try out.appendSlice(allocator, "content-disposition: form-data; name=\"");
    try out.appendSlice(allocator, name);
    try out.append(allocator, '"');
    if (filename) |value| {
        try out.appendSlice(allocator, "; filename=\"");
        try out.appendSlice(allocator, value);
        try out.append(allocator, '"');
    }
}

fn validateMultipartDispositionValue(value: []const u8) !void {
    if (value.len == 0 or std.mem.indexOfAny(u8, value, "\"\r\n") != null) return error.InvalidHeader;
}

/// An owned HTTP response.
pub const Response = responses.Response;

/// One owned WebSocket message received by the test client.
pub const WebSocketTestMessage = websockets.WebSocketTestMessage;
/// One WebSocket frame sent by the test client.
pub const WebSocketTestFrame = websockets.WebSocketTestFrame;
/// An owned WebSocket test response.
pub const WebSocketTestResponse = websockets.WebSocketTestResponse;

pub const Context = struct {
    app: *ZAPI,
    allocator: std.mem.Allocator,
    io: ?std.Io = null,
    request: Request,
    path_params: std.StringHashMap([]const u8),
    route_metadata: *const RouteMetadata,
    state_ptr: ?*anyopaque = null,

    pub fn state(self: *Context, comptime T: type) *T {
        return @ptrCast(@alignCast(self.state_ptr.?));
    }

    pub fn maybeState(self: *Context, comptime T: type) ?*T {
        const ptr = self.state_ptr orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    /// Returns the request-scoped I/O implementation supplied by the server.
    pub fn ioHandle(self: *const Context) !std.Io {
        return self.io orelse error.MissingIo;
    }

    pub fn requestState(self: *Context, comptime T: type) *T {
        return self.request.state(T);
    }

    pub fn maybeRequestState(self: *Context, comptime T: type) ?*T {
        return self.request.maybeState(T);
    }

    pub fn session(self: *Context) *Session {
        return self.request.session();
    }

    pub fn pathValue(self: *Context, name: []const u8) ?[]const u8 {
        return self.path_params.get(name);
    }

    pub fn pathParam(self: *Context, name: []const u8) !?[]u8 {
        const raw = self.pathValue(name) orelse return null;
        return try percentDecodePath(self.allocator, raw);
    }

    pub fn pathParams(self: *Context) !QueryParams {
        return self.request.pathParams(self.allocator);
    }

    pub fn urlPathFor(self: *Context, name: []const u8, params: anytype) anyerror![]u8 {
        const resolver = self.request.url_resolver orelse self.app.urlResolver();
        const path = try resolver.pathFor(self.allocator, name, params);
        defer self.allocator.free(path);

        const root_path = self.request.url_root_path orelse self.request.root_path;
        if (root_path.len == 0) return self.allocator.dupe(u8, path);
        return joinRequestPath(self.allocator, root_path, path);
    }

    pub fn urlFor(self: *Context, name: []const u8, params: anytype) anyerror![]u8 {
        const path = try self.urlPathFor(name, params);
        errdefer self.allocator.free(path);

        const host = self.request.header("host") orelse return path;
        defer self.allocator.free(path);
        return std.fmt.allocPrint(self.allocator, "{s}://{s}{s}", .{ self.request.scheme, host, path });
    }

    pub fn redirectTo(self: *Context, name: []const u8, params: anytype) !ResponsePayload {
        return self.redirectToStatus(name, params, .temporary_redirect);
    }

    pub fn redirectToStatus(self: *Context, name: []const u8, params: anytype, status: Status) !ResponsePayload {
        const location = try self.urlPathFor(name, params);
        errdefer self.allocator.free(location);

        const headers = try self.allocator.alloc(HeaderField, 1);
        errdefer self.allocator.free(headers);
        headers[0] = .{
            .name = try self.allocator.dupe(u8, "location"),
            .value = location,
        };

        return .{
            .status = status,
            .content_type = "",
            .headers = headers,
            .owned_headers = true,
        };
    }

    pub fn problem(self: *Context, status: Status, detail: []const u8) !ResponsePayload {
        return problemPayload(self.allocator, status, detail);
    }

    pub fn badRequest(self: *Context, detail: []const u8) !ResponsePayload {
        return self.problem(.bad_request, detail);
    }

    pub fn unauthorized(self: *Context, detail: []const u8) !ResponsePayload {
        return self.problem(.unauthorized, detail);
    }

    pub fn unauthorizedWithChallenge(self: *Context, detail: []const u8, www_authenticate: []const u8) !ResponsePayload {
        var payload = try self.unauthorized(detail);
        try payload.setHeader(self.allocator, "www-authenticate", www_authenticate);
        return payload;
    }

    pub fn forbidden(self: *Context, detail: []const u8) !ResponsePayload {
        return self.problem(.forbidden, detail);
    }

    pub fn notFound(self: *Context, detail: []const u8) !ResponsePayload {
        return self.problem(.not_found, detail);
    }

    pub fn conflict(self: *Context, detail: []const u8) !ResponsePayload {
        return self.problem(.conflict, detail);
    }

    pub fn payloadTooLarge(self: *Context, detail: []const u8) !ResponsePayload {
        return self.problem(.payload_too_large, detail);
    }

    pub fn unprocessableEntity(self: *Context, detail: []const u8) !ResponsePayload {
        return self.problem(.unprocessable_entity, detail);
    }

    pub fn tooManyRequests(self: *Context, detail: []const u8) !ResponsePayload {
        return self.problem(.too_many_requests, detail);
    }

    pub fn problemWithHeaders(self: *Context, status: Status, detail: []const u8, headers: []const HeaderField) !ResponsePayload {
        var payload = try problemPayload(self.allocator, status, detail);
        payload.headers = headers;
        return payload;
    }
};

pub const WebSocketContext = struct {
    app: *ZAPI,
    allocator: std.mem.Allocator,
    request: Request,
    path_params: std.StringHashMap([]const u8),
    websocket: *std.http.Server.WebSocket,
    state_ptr: ?*anyopaque = null,

    pub fn state(self: *WebSocketContext, comptime T: type) *T {
        return @ptrCast(@alignCast(self.state_ptr.?));
    }

    pub fn maybeState(self: *WebSocketContext, comptime T: type) ?*T {
        const ptr = self.state_ptr orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    pub fn pathValue(self: *WebSocketContext, name: []const u8) ?[]const u8 {
        return self.path_params.get(name);
    }

    pub fn pathParam(self: *WebSocketContext, name: []const u8) !?[]u8 {
        const raw = self.pathValue(name) orelse return null;
        return try percentDecodePath(self.allocator, raw);
    }

    pub fn readSmallMessage(self: *WebSocketContext) !std.http.Server.WebSocket.SmallMessage {
        return self.websocket.readSmallMessage();
    }

    pub fn sendText(self: *WebSocketContext, data: []const u8) !void {
        try self.websocket.writeMessage(data, .text);
    }

    pub fn sendBinary(self: *WebSocketContext, data: []const u8) !void {
        try self.websocket.writeMessage(data, .binary);
    }

    pub fn close(self: *WebSocketContext) !void {
        try self.websocket.writeMessage("", .connection_close);
    }
};

/// A typed JSON request body.
pub const Body = requests.Body;
/// Typed form data.
pub const Form = requests.Form;
/// Typed path parameters.
pub const Path = requests.Path;
/// Typed query parameters.
pub const Query = requests.Query;
/// Typed request headers.
pub const Header = requests.Header;
/// Typed request cookies.
pub const Cookie = requests.Cookie;

const WrapperKind = requests.WrapperKind;

/// An empty response body.
pub const Empty = responses.Empty;
/// A plain-text response.
pub const Text = responses.Text;
/// An HTML response.
pub const Html = responses.Html;
/// One named template value.
pub const TemplateValue = responses.TemplateValue;
/// Creates an HTML-escaped template value.
pub const template = responses.template;
/// Creates trusted, unescaped template HTML.
pub const templateHtml = responses.templateHtml;
/// A template response.
pub const Template = responses.Template;
/// One Server-Sent Event.
pub const ServerSentEvent = responses.ServerSentEvent;
/// Creates a data-only Server-Sent Event.
pub const serverSentEvent = responses.serverSentEvent;
/// A buffered Server-Sent Events response.
pub const EventStream = responses.EventStream;
/// A streaming response writer.
pub const StreamingWriteFn = responses.StreamingWriteFn;
/// Transport state for a streaming response.
pub const ResponseStream = responses.ResponseStream;
/// A response written directly by the transport.
pub const StreamingResponse = responses.StreamingResponse;
/// An arbitrary byte response.
pub const Bytes = responses.Bytes;
/// A file content disposition.
pub const ContentDisposition = responses.ContentDisposition;
/// A file response.
pub const File = responses.File;
/// A typed JSON response.
pub const Json = responses.Json;
/// A pre-encoded JSON response.
pub const RawJson = responses.RawJson;
/// An HTTP redirect response.
pub const Redirect = responses.Redirect;

pub const RouteOptions = struct {
    name: ?[]const u8 = null,
    operation_id: ?[]const u8 = null,
    status: Status = .ok,
    summary: ?[]const u8 = null,
    description: ?[]const u8 = null,
    external_docs: ?OpenApiExternalDocs = null,
    tags: []const []const u8 = &.{},
    middlewares: []const MiddlewareFn = &.{},
    include_in_schema: bool = true,
    deprecated: bool = false,
    request_examples: []const OpenApiExample = &.{},
    response_description: ?[]const u8 = null,
    response_examples: []const OpenApiExample = &.{},
    response_headers: []const OpenApiHeader = &.{},
    parameter_docs: []const OpenApiParameterDoc = &.{},
    responses: []const ResponseDoc = &.{},
};

pub const OpenApiExample = struct {
    name: []const u8,
    summary: ?[]const u8 = null,
    description: ?[]const u8 = null,
    value_json: []const u8,
};

pub const OpenApiHeader = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    schema: JsonSchema = .string,
    required: bool = false,
    deprecated: bool = false,
};

pub const OpenApiParameterLocation = enum {
    path,
    query,
    header,
    cookie,
};

pub const OpenApiParameterDoc = struct {
    name: []const u8,
    location: OpenApiParameterLocation,
    alias: ?[]const u8 = null,
    description: ?[]const u8 = null,
    example_json: ?[]const u8 = null,
    deprecated: bool = false,
};

pub const ResponseDoc = struct {
    status: Status,
    description: []const u8,
    content_type: ?[]const u8 = null,
    response_type_name: ?[]const u8 = null,
    response_inline_schema: ?JsonSchema = null,
    response_schema: ?SchemaComponent = null,
    examples: []const OpenApiExample = &.{},
    headers: []const OpenApiHeader = &.{},
};

pub fn responseDoc(comptime status: Status, comptime T: type, comptime options: anytype) ResponseDoc {
    const has_body = comptime responseBodyAllowed(status) and T != void and T != Empty;
    return .{
        .status = status,
        .description = if (@hasField(@TypeOf(options), "description")) options.description else status.reason(),
        .content_type = if (has_body) (if (@hasField(@TypeOf(options), "content_type")) options.content_type else responseContentType(T)) else null,
        .response_type_name = if (has_body) responseTypeName(T) else null,
        .response_inline_schema = if (has_body) responseInlineSchema(T) else null,
        .response_schema = if (has_body) responseSchema(T) else null,
        .examples = if (@hasField(@TypeOf(options), "examples")) options.examples else &.{},
        .headers = if (@hasField(@TypeOf(options), "headers")) options.headers else &.{},
    };
}

pub const RouteSpec = struct {
    method: Method,
    path: []const u8,
    handler_ptr: *const anyopaque,
    handler_type_name: []const u8,
    dispatch: *const fn (*Context) anyerror!ResponsePayload,
    middlewares: []const MiddlewareFn = &.{},
    metadata: RouteMetadata,
};

pub const WebSocketHandlerFn = *const fn (*WebSocketContext) anyerror!void;

pub const WebSocketRouteSpec = struct {
    path: []const u8,
    handler: WebSocketHandlerFn,
    name: ?[]const u8 = null,
};

pub const MountRouteSpec = struct {
    prefix: []const u8,
    app: *ZAPI,
    name: ?[]const u8 = null,
};

pub const HostRouteSpec = struct {
    pattern: []const u8,
    app: *ZAPI,
    name: ?[]const u8 = null,
};

pub const SchemaComponent = struct {
    name: []const u8,
    write: *const fn (*std.Io.Writer) anyerror!void,
};

pub const RouteMetadata = struct {
    name: ?[]const u8,
    name_is_explicit: bool,
    name_owned: bool = false,
    operation_id: ?[]const u8,
    status: Status,
    summary: ?[]const u8,
    description: ?[]const u8,
    external_docs: ?OpenApiExternalDocs,
    tags: []const []const u8,
    tags_owned: bool = false,
    include_in_schema: bool,
    deprecated: bool,
    request_body_type_name: ?[]const u8,
    request_body_schema: ?SchemaComponent,
    request_body_inline_schema: ?JsonSchema,
    request_body_required: bool,
    request_body_content_type: ?[]const u8,
    request_examples: []const OpenApiExample,
    response_content_type: ?[]const u8,
    response_type_name: ?[]const u8,
    response_inline_schema: ?JsonSchema,
    response_schema: ?SchemaComponent,
    response_description: ?[]const u8,
    response_examples: []const OpenApiExample,
    response_headers: []const OpenApiHeader,
    additional_responses: []const ResponseDoc,
    requires_bearer_auth: bool,
    requires_basic_auth: bool,
    oauth2_password_bearer_auth: []const OAuth2PasswordBearerSecurityMetadata,
    oauth2_authorization_code_bearer_auth: []const OAuth2AuthorizationCodeBearerSecurityMetadata,
    oauth2_client_credentials_bearer_auth: []const OAuth2ClientCredentialsBearerSecurityMetadata,
    oauth2_implicit_bearer_auth: []const OAuth2ImplicitBearerSecurityMetadata,
    api_key_auth: []const ApiKeySecurityMetadata,
    path_params: []const ParamMetadata,
    query_params: []const ParamMetadata,
    header_params: []const ParamMetadata,
    cookie_params: []const ParamMetadata,
};

pub const ApiKeySecurityMetadata = struct {
    scheme_name: []const u8,
    location: ApiKeyLocation,
    name: []const u8,
};

pub const OAuth2PasswordBearerSecurityMetadata = struct {
    scheme_name: []const u8,
    token_url: []const u8,
    scopes: []const OAuth2Scope,
};

pub const OAuth2AuthorizationCodeBearerSecurityMetadata = struct {
    scheme_name: []const u8,
    authorization_url: []const u8,
    token_url: []const u8,
    scopes: []const OAuth2Scope,
};

pub const OAuth2ClientCredentialsBearerSecurityMetadata = struct {
    scheme_name: []const u8,
    token_url: []const u8,
    scopes: []const OAuth2Scope,
};

pub const OAuth2ImplicitBearerSecurityMetadata = struct {
    scheme_name: []const u8,
    authorization_url: []const u8,
    scopes: []const OAuth2Scope,
};

pub const ParamMetadata = struct {
    field_name: []const u8,
    name: []const u8,
    schema: JsonSchema,
    required: bool,
    default_value: ?DefaultValue = null,
    description: ?[]const u8 = null,
    example_json: ?[]const u8 = null,
    deprecated: bool = false,
};

const DefaultValue = struct {
    write: *const fn (*std.Io.Writer) anyerror!void,
};

/// Validators applied to a response payload.
pub const ConditionalOptions = responses.ConditionalOptions;

pub const FollowRedirectOptions = struct {
    max_redirects: usize = 10,
};

pub const TestClientOptions = struct {
    follow_redirects: bool = true,
    max_redirects: usize = 10,
    raise_server_exceptions: bool = true,
    headers: []const HeaderField = &.{},
    base_url: ?[]const u8 = null,
    scheme: []const u8 = "http",
    host: ?[]const u8 = "testserver",
    root_path: []const u8 = "",
    client: ?ClientAddress = .{ .host = "testclient", .port = 50000 },
};

pub const TestClientSendOptions = struct {
    follow_redirects: ?bool = null,
    max_redirects: ?usize = null,
    raise_server_exceptions: ?bool = null,
};

const TestClientRequestDefaults = struct {
    scheme: []const u8,
    host: ?[]const u8,
    root_path: []const u8,
};

const AbsoluteRequestTarget = struct {
    scheme: []const u8,
    host: []const u8,
    path: []const u8,
    query: []const u8,
};

fn testClientRequestDefaults(options: TestClientOptions) !TestClientRequestDefaults {
    if (options.base_url) |base_url| {
        var defaults = try parseTestClientBaseUrl(base_url);
        if (defaults.root_path.len == 0) defaults.root_path = normalizeRootPath(options.root_path);
        return defaults;
    }
    return .{
        .scheme = options.scheme,
        .host = options.host,
        .root_path = normalizeRootPath(options.root_path),
    };
}

fn normalizeRootPath(root_path: []const u8) []const u8 {
    var normalized = root_path;
    while (normalized.len > 1 and normalized[normalized.len - 1] == '/') {
        normalized = normalized[0 .. normalized.len - 1];
    }
    if (std.mem.eql(u8, normalized, "/")) return "";
    return normalized;
}

fn absoluteTargetForRequest(request: Request) !?AbsoluteRequestTarget {
    if (std.mem.startsWith(u8, request.path, "//")) {
        const after_authority: usize = 2;
        const path_start = std.mem.indexOfAnyPos(u8, request.path, after_authority, "/#") orelse request.path.len;
        const host = request.path[after_authority..path_start];
        if (host.len == 0) return error.InvalidUrl;

        var path: []const u8 = "/";
        if (path_start < request.path.len) {
            switch (request.path[path_start]) {
                '/' => {
                    const path_end = std.mem.indexOfScalarPos(u8, request.path, path_start, '#') orelse request.path.len;
                    path = request.path[path_start..path_end];
                    if (path.len == 0) path = "/";
                },
                '#' => {},
                else => unreachable,
            }
        }

        const query_end = std.mem.indexOfScalar(u8, request.query, '#') orelse request.query.len;
        return .{
            .scheme = request.scheme,
            .host = host,
            .path = path,
            .query = request.query[0..query_end],
        };
    }

    const scheme_end = std.mem.indexOf(u8, request.path, "://") orelse return null;
    if (scheme_end == 0) return error.InvalidUrl;

    const after_scheme = scheme_end + 3;
    const path_start = std.mem.indexOfAnyPos(u8, request.path, after_scheme, "/#") orelse request.path.len;
    const host = request.path[after_scheme..path_start];
    if (host.len == 0) return error.InvalidUrl;

    var path: []const u8 = "/";
    if (path_start < request.path.len) {
        switch (request.path[path_start]) {
            '/' => {
                const path_end = std.mem.indexOfScalarPos(u8, request.path, path_start, '#') orelse request.path.len;
                path = request.path[path_start..path_end];
                if (path.len == 0) path = "/";
            },
            '#' => {},
            else => unreachable,
        }
    }

    const query_end = std.mem.indexOfScalar(u8, request.query, '#') orelse request.query.len;
    return .{
        .scheme = request.path[0..scheme_end],
        .host = host,
        .path = path,
        .query = request.query[0..query_end],
    };
}

fn stripRootPathPrefix(path: []const u8, root_path: []const u8) []const u8 {
    if (root_path.len == 0) return path;
    if (!std.mem.startsWith(u8, path, root_path)) return path;
    if (path.len == root_path.len) return "/";
    if (path[root_path.len] != '/') return path;
    return path[root_path.len..];
}

fn parseTestClientBaseUrl(base_url: []const u8) !TestClientRequestDefaults {
    const scheme_end = std.mem.indexOf(u8, base_url, "://") orelse return error.InvalidUrl;
    if (scheme_end == 0) return error.InvalidUrl;

    const after_scheme = scheme_end + 3;
    const path_start = std.mem.indexOfAnyPos(u8, base_url, after_scheme, "/?#") orelse base_url.len;
    const host = base_url[after_scheme..path_start];
    if (host.len == 0) return error.InvalidUrl;

    var root_path: []const u8 = "";
    if (path_start < base_url.len) {
        switch (base_url[path_start]) {
            '/' => {
                const path_end = std.mem.indexOfAnyPos(u8, base_url, path_start, "?#") orelse base_url.len;
                root_path = base_url[path_start..path_end];
                while (root_path.len > 1 and root_path[root_path.len - 1] == '/') {
                    root_path = root_path[0 .. root_path.len - 1];
                }
                if (std.mem.eql(u8, root_path, "/")) root_path = "";
            },
            '?', '#' => return error.InvalidUrl,
            else => unreachable,
        }
    }

    return .{
        .scheme = base_url[0..scheme_end],
        .host = host,
        .root_path = root_path,
    };
}

/// An encoded endpoint response awaiting finalization.
pub const ResponsePayload = responses.ResponsePayload;

/// A SameSite cookie policy.
pub const SameSite = sessions.SameSite;
/// Cookie serialization options.
pub const CookieOptions = sessions.CookieOptions;
/// Mutable request session data.
pub const Session = sessions.Session;

pub const Route = struct {
    pub fn init(comptime opts: anytype) RouteSpec {
        return makeRoute(opts.method, opts.path, opts.handler, if (@hasField(@TypeOf(opts), "options")) opts.options else .{});
    }

    pub fn get(comptime path: []const u8, comptime handler: anytype, comptime route_options: anytype) RouteSpec {
        return makeRoute(.GET, path, handler, route_options);
    }

    pub fn post(comptime path: []const u8, comptime handler: anytype, comptime route_options: anytype) RouteSpec {
        return makeRoute(.POST, path, handler, route_options);
    }

    pub fn put(comptime path: []const u8, comptime handler: anytype, comptime route_options: anytype) RouteSpec {
        return makeRoute(.PUT, path, handler, route_options);
    }

    pub fn patch(comptime path: []const u8, comptime handler: anytype, comptime route_options: anytype) RouteSpec {
        return makeRoute(.PATCH, path, handler, route_options);
    }

    pub fn delete(comptime path: []const u8, comptime handler: anytype, comptime route_options: anytype) RouteSpec {
        return makeRoute(.DELETE, path, handler, route_options);
    }

    pub fn options(comptime path: []const u8, comptime handler: anytype, comptime route_options: anytype) RouteSpec {
        return makeRoute(.OPTIONS, path, handler, route_options);
    }

    pub fn head(comptime path: []const u8, comptime handler: anytype, comptime route_options: anytype) RouteSpec {
        return makeRoute(.HEAD, path, handler, route_options);
    }

    pub fn trace(comptime path: []const u8, comptime handler: anytype, comptime route_options: anytype) RouteSpec {
        return makeRoute(.TRACE, path, handler, route_options);
    }

    pub fn connect(comptime path: []const u8, comptime handler: anytype, comptime route_options: anytype) RouteSpec {
        return makeRoute(.CONNECT, path, handler, route_options);
    }

    pub fn websocket(comptime path: []const u8, comptime handler: WebSocketHandlerFn, comptime route_options: anytype) WebSocketRouteSpec {
        return .{
            .path = path,
            .handler = handler,
            .name = if (@hasField(@TypeOf(route_options), "name")) route_options.name else null,
        };
    }

    pub fn mount(comptime prefix: []const u8, app: *ZAPI, comptime route_options: anytype) MountRouteSpec {
        return .{
            .prefix = prefix,
            .app = app,
            .name = if (@hasField(@TypeOf(route_options), "name")) route_options.name else null,
        };
    }

    pub fn host(comptime pattern: []const u8, app: *ZAPI, comptime route_options: anytype) HostRouteSpec {
        return .{
            .pattern = pattern,
            .app = app,
            .name = if (@hasField(@TypeOf(route_options), "name")) route_options.name else null,
        };
    }

    pub fn methods(comptime path: []const u8, comptime methods_list: []const Method, comptime handler: anytype, comptime route_options: anytype) RouterSpec {
        if (methods_list.len == 0) @compileError("Route.methods requires at least one HTTP method");
        @setEvalBranchQuota(10_000);

        return .{
            .routes = &struct {
                const value = blk: {
                    var routes: [methods_list.len]RouteSpec = undefined;
                    for (methods_list, 0..) |method, index| {
                        routes[index] = makeRoute(method, path, handler, route_options);
                    }
                    break :blk routes;
                };
            }.value,
        };
    }
};

pub fn get(comptime path: []const u8, comptime handler: anytype, comptime route_options: anytype) RouteSpec {
    return Route.get(path, handler, route_options);
}

pub fn post(comptime path: []const u8, comptime handler: anytype, comptime route_options: anytype) RouteSpec {
    return Route.post(path, handler, route_options);
}

pub fn put(comptime path: []const u8, comptime handler: anytype, comptime route_options: anytype) RouteSpec {
    return Route.put(path, handler, route_options);
}

pub fn patch(comptime path: []const u8, comptime handler: anytype, comptime route_options: anytype) RouteSpec {
    return Route.patch(path, handler, route_options);
}

pub fn delete(comptime path: []const u8, comptime handler: anytype, comptime route_options: anytype) RouteSpec {
    return Route.delete(path, handler, route_options);
}

pub fn websocket(comptime path: []const u8, comptime handler: WebSocketHandlerFn, comptime route_options: anytype) WebSocketRouteSpec {
    return Route.websocket(path, handler, route_options);
}

pub fn mount(comptime prefix: []const u8, app: *ZAPI, comptime route_options: anytype) MountRouteSpec {
    return Route.mount(prefix, app, route_options);
}

pub fn methods(comptime path: []const u8, comptime methods_list: []const Method, comptime handler: anytype, comptime route_options: anytype) RouterSpec {
    return Route.methods(path, methods_list, handler, route_options);
}

pub const RouterSpec = struct {
    prefix: []const u8 = "",
    tags: []const []const u8 = &.{},
    middlewares: []const MiddlewareFn = &.{},
    routes: []const RouteSpec,
    websocket_routes: []const WebSocketRouteSpec = &.{},
    mounts: []const MountRouteSpec = &.{},
    hosts: []const HostRouteSpec = &.{},
};

fn RouterInitResult(comptime Tags: type, comptime Middlewares: type, comptime Routes: type) type {
    return struct {
        pub const is_zapi_router_init_result = true;

        zapi_router_init_result: void = {},
        prefix: []const u8 = "",
        tags: Tags,
        middlewares: Middlewares,
        routes: Routes,
    };
}

fn isRouterInitResult(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => |info| blk: {
            inline for (info.fields) |field| {
                if (comptime std.mem.eql(u8, field.name, "zapi_router_init_result")) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

pub const Router = struct {
    pub fn init(opts: anytype) RouterInitResult(
        RouteListItemsStorage([]const u8, if (@hasField(@TypeOf(opts), "tags")) @TypeOf(opts.tags) else []const []const u8),
        RouteListItemsStorage(MiddlewareFn, if (@hasField(@TypeOf(opts), "middlewares")) @TypeOf(opts.middlewares) else []const MiddlewareFn),
        RouteEntriesStorage(@TypeOf(opts.routes)),
    ) {
        const Opts = @TypeOf(opts);
        if (!@hasField(Opts, "routes")) @compileError("Router.init requires a routes field");

        const raw_tags = if (@hasField(Opts, "tags")) opts.tags else @as([]const []const u8, &.{});
        const raw_middlewares = if (@hasField(Opts, "middlewares")) opts.middlewares else @as([]const MiddlewareFn, &.{});

        return .{
            .prefix = if (@hasField(Opts, "prefix")) opts.prefix else "",
            .tags = normalizeRouteListItems([]const u8, raw_tags),
            .middlewares = normalizeRouteListItems(MiddlewareFn, raw_middlewares),
            .routes = normalizeRouteEntries(opts.routes),
        };
    }
};

fn RouteListItemsStorage(comptime Elem: type, comptime T: type) type {
    return switch (@typeInfo(T)) {
        .pointer => |ptr| switch (@typeInfo(ptr.child)) {
            .@"struct" => |info| [info.fields.len]Elem,
            .array => |array| [array.len]Elem,
            else => T,
        },
        .array => |array| [array.len]Elem,
        else => T,
    };
}

fn RouteEntriesStorage(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .pointer => |ptr| switch (@typeInfo(ptr.child)) {
            .@"struct", .array => ptr.child,
            else => T,
        },
        else => T,
    };
}

fn normalizeRouteEntries(value: anytype) RouteEntriesStorage(@TypeOf(value)) {
    const Storage = RouteEntriesStorage(@TypeOf(value));
    return switch (@typeInfo(Storage)) {
        .@"struct", .array => blk: {
            const Value = @TypeOf(value);
            switch (@typeInfo(Value)) {
                .pointer => break :blk value.*,
                else => break :blk value,
            }
        },
        else => value,
    };
}

fn normalizeRouteListItems(comptime Elem: type, value: anytype) RouteListItemsStorage(Elem, @TypeOf(value)) {
    const Storage = RouteListItemsStorage(Elem, @TypeOf(value));
    return switch (@typeInfo(Storage)) {
        .array => blk: {
            var out: Storage = undefined;
            const Value = @TypeOf(value);
            switch (@typeInfo(Value)) {
                .pointer => |ptr| switch (@typeInfo(ptr.child)) {
                    .@"struct" => {
                        const tuple = value.*;
                        inline for (std.meta.fields(@TypeOf(tuple)), 0..) |field, index| {
                            out[index] = routeListItem(Elem, @field(tuple, field.name));
                        }
                    },
                    .array => {
                        for (value.*, 0..) |item, index| {
                            out[index] = routeListItem(Elem, item);
                        }
                    },
                    else => @compileError("unsupported includeRoutes item pointer type: " ++ @typeName(Value)),
                },
                .array => {
                    for (value, 0..) |item, index| {
                        out[index] = routeListItem(Elem, item);
                    }
                },
                else => @compileError("unsupported includeRoutes item type: " ++ @typeName(Value)),
            }
            break :blk out;
        },
        else => value,
    };
}

fn routeListItem(comptime Elem: type, item: anytype) Elem {
    return item;
}

fn routeListItemsSlice(comptime Elem: type, storage: anytype) []const Elem {
    const Storage = @typeInfo(@TypeOf(storage)).pointer.child;
    return switch (@typeInfo(Storage)) {
        .array => storage.*[0..],
        else => storage.*,
    };
}

const RegisteredRoute = struct {
    method: Method,
    path: []const u8,
    dispatch: *const fn (*Context) anyerror!ResponsePayload,
    middlewares: []const MiddlewareFn = &.{},
    middlewares_owned: bool = false,
    metadata: RouteMetadata,
};

const RegisteredWebSocketRoute = struct {
    path: []const u8,
    handler: WebSocketHandlerFn,
    name: ?[]const u8 = null,
};

fn combineRouteMiddlewares(allocator: std.mem.Allocator, outer: []const MiddlewareFn, inner: []const MiddlewareFn) !struct { value: []const MiddlewareFn, owned: bool } {
    if (outer.len == 0) return .{ .value = inner, .owned = false };
    if (inner.len == 0) return .{ .value = outer, .owned = false };

    const combined = try allocator.alloc(MiddlewareFn, outer.len + inner.len);
    @memcpy(combined[0..outer.len], outer);
    @memcpy(combined[outer.len..], inner);
    return .{ .value = combined, .owned = true };
}

fn combineRouteTags(allocator: std.mem.Allocator, outer: []const []const u8, inner: []const []const u8) !struct { value: []const []const u8, owned: bool } {
    if (outer.len == 0) return .{ .value = inner, .owned = false };
    if (inner.len == 0) return .{ .value = outer, .owned = false };

    const combined = try allocator.alloc([]const u8, outer.len + inner.len);
    @memcpy(combined[0..outer.len], outer);
    @memcpy(combined[outer.len..], inner);
    return .{ .value = combined, .owned = true };
}

pub const MiddlewareFn = *const fn (*MiddlewareContext, Request) anyerror!Response;

pub const MiddlewareContext = struct {
    app: *ZAPI,
    index: usize,
    route_item: ?*const RegisteredRoute = null,
    route_params: ?*std.StringHashMap([]const u8) = null,
    exception_mode: ExceptionMode = .catch_unhandled,

    pub fn next(self: *MiddlewareContext, request: Request) !Response {
        if (self.route_item) |route_item| {
            return self.app.handleRouteWithMiddlewareMode(request, route_item, self.route_params.?, self.index + 1, self.exception_mode);
        }
        return self.app.handleWithMiddlewareMode(request, self.index + 1, self.exception_mode);
    }
};

const ExceptionMode = enum {
    catch_unhandled,
    raise_unhandled,
};

pub const CorsOptions = middleware_options.CorsOptions;
pub const GzipOptions = middleware_options.GzipOptions;
pub const RequestBodyLimitOptions = middleware_options.RequestBodyLimitOptions;
pub const MethodOverrideOptions = middleware_options.MethodOverrideOptions;
pub const ProxyHeadersOptions = middleware_options.ProxyHeadersOptions;
pub const RequestIdOptions = middleware_options.RequestIdOptions;
pub const ResponseHeadersOptions = middleware_options.ResponseHeadersOptions;
pub const SecurityHeadersOptions = middleware_options.SecurityHeadersOptions;
pub const SessionOptions = middleware_options.SessionOptions;
const cors_all_methods = middleware_options.cors_all_methods;
const cors_safelisted_headers = middleware_options.cors_safelisted_headers;

pub fn gzipMiddleware(comptime options: GzipOptions) MiddlewareFn {
    return struct {
        fn handle(ctx: *MiddlewareContext, request: Request) !Response {
            var response = try ctx.next(request);
            errdefer response.deinit(ctx.app.allocator);

            if (!clientAcceptsGzip(request)) return response;
            if (!gzipResponseAllowed(response, options.minimum_size)) return response;

            const compressed = try gzipCompress(ctx.app.allocator, response.body.items);
            errdefer ctx.app.allocator.free(compressed);

            response.body.clearRetainingCapacity();
            try response.body.appendSlice(ctx.app.allocator, compressed);
            ctx.app.allocator.free(compressed);

            try response.setHeader(ctx.app.allocator, "content-encoding", "gzip");
            const content_length = try std.fmt.allocPrint(ctx.app.allocator, "{d}", .{response.body.items.len});
            defer ctx.app.allocator.free(content_length);
            try response.setHeader(ctx.app.allocator, "content-length", content_length);
            try addVaryHeader(ctx.app.allocator, &response, "Accept-Encoding");
            return response;
        }
    }.handle;
}

pub fn requestBodyLimitMiddleware(comptime options: RequestBodyLimitOptions) MiddlewareFn {
    return struct {
        fn handle(ctx: *MiddlewareContext, request: Request) !Response {
            if (request.body.len > options.max_size) {
                return ctx.app.problemForRequest(request, options.status, options.detail);
            }
            return ctx.next(request);
        }
    }.handle;
}

pub fn responseHeadersMiddleware(comptime options: ResponseHeadersOptions) MiddlewareFn {
    return struct {
        fn handle(ctx: *MiddlewareContext, request: Request) !Response {
            var response = try ctx.next(request);
            errdefer response.deinit(ctx.app.allocator);

            inline for (options.headers) |header| {
                if (!options.preserve_existing or response.header(header.name) == null) {
                    try response.setHeader(ctx.app.allocator, header.name, header.value);
                }
            }
            inline for (options.append_headers) |header| {
                try response.appendHeader(ctx.app.allocator, header.name, header.value);
            }

            return response;
        }
    }.handle;
}

pub fn methodOverrideMiddleware(comptime options: MethodOverrideOptions) MiddlewareFn {
    return struct {
        fn handle(ctx: *MiddlewareContext, request: Request) !Response {
            const raw_method = request.header(options.header_name) orelse return ctx.next(request);
            if (!methodOverrideOriginalAllowed(options, request.method)) return ctx.next(request);

            const trimmed_method = std.mem.trim(u8, raw_method, " \t");
            const method = methodFromText(trimmed_method) catch {
                return ctx.app.problemForRequest(request, .bad_request, "Invalid method override");
            };
            if (!methodOverrideTargetAllowed(options, method)) {
                return ctx.app.problemForRequest(request, .bad_request, "Disallowed method override");
            }

            var overridden = request;
            overridden.method = method;
            return ctx.next(overridden);
        }
    }.handle;
}

pub fn corsMiddleware(comptime options: CorsOptions) MiddlewareFn {
    return struct {
        fn handle(ctx: *MiddlewareContext, request: Request) !Response {
            const origin = request.header("origin") orelse return ctx.next(request);
            const allow_origin = corsAllowOrigin(options, request, origin);
            if (allow_origin == null) {
                if (isCorsPreflight(request)) return corsPreflightFailure(options, ctx.app, "Disallowed CORS origin", null, request.header("access-control-request-headers"));
                return ctx.next(request);
            }

            if (isCorsPreflight(request)) {
                const requested_method = request.header("access-control-request-method").?;
                if (!corsMethodAllowed(options, requested_method)) {
                    return corsPreflightFailure(options, ctx.app, "Disallowed CORS method", allow_origin, request.header("access-control-request-headers"));
                }
                if (request.header("access-control-request-headers")) |requested_headers| {
                    if (!corsHeadersAllowed(options, requested_headers)) {
                        return corsPreflightFailure(options, ctx.app, "Disallowed CORS headers", allow_origin, requested_headers);
                    }
                }

                var response = Response.init(.ok);
                try response.setHeader(ctx.app.allocator, "content-type", "text/plain; charset=utf-8");
                try response.body.appendSlice(ctx.app.allocator, "OK");
                try addCorsHeaders(options, ctx.app, &response, allow_origin.?, true, request.header("access-control-request-headers"));
                return response;
            }

            var response = try ctx.next(request);
            try addCorsHeaders(options, ctx.app, &response, allow_origin.?, false, null);
            return response;
        }
    }.handle;
}

pub fn proxyHeadersMiddleware(comptime options: ProxyHeadersOptions) MiddlewareFn {
    return struct {
        fn handle(ctx: *MiddlewareContext, request: Request) !Response {
            var forwarded = request;

            if (request.header(options.forwarded_proto_header)) |value| {
                if (forwardedHeaderFirstValue(value)) |scheme| {
                    if (validForwardedScheme(scheme)) forwarded.scheme = scheme;
                }
            }

            var owned_headers: ?[]HeaderField = null;
            defer if (owned_headers) |headers| ctx.app.allocator.free(headers);
            if (request.header(options.forwarded_host_header)) |value| {
                if (forwardedHeaderFirstValue(value)) |host| {
                    if (host.len > 0) {
                        owned_headers = try requestWithHeader(ctx.app.allocator, request, "host", host);
                        forwarded.headers = owned_headers.?;
                    }
                }
            }

            var owned_root_path: ?[]u8 = null;
            defer if (owned_root_path) |root_path| ctx.app.allocator.free(root_path);
            if (request.header(options.forwarded_prefix_header)) |value| {
                if (forwardedHeaderFirstValue(value)) |prefix| {
                    if (validForwardedPrefix(prefix)) {
                        owned_root_path = try normalizeForwardedPrefix(ctx.app.allocator, prefix);
                        forwarded.root_path = owned_root_path.?;
                    }
                }
            }

            return ctx.next(forwarded);
        }
    }.handle;
}

pub fn securityHeadersMiddleware(comptime options: SecurityHeadersOptions) MiddlewareFn {
    return struct {
        fn handle(ctx: *MiddlewareContext, request: Request) !Response {
            var response = try ctx.next(request);
            errdefer response.deinit(ctx.app.allocator);

            if (options.content_type_options) |value| try setHeaderIfMissing(ctx.app.allocator, &response, "x-content-type-options", value);
            if (options.frame_options) |value| try setHeaderIfMissing(ctx.app.allocator, &response, "x-frame-options", value);
            if (options.referrer_policy) |value| try setHeaderIfMissing(ctx.app.allocator, &response, "referrer-policy", value);
            if (options.permissions_policy) |value| try setHeaderIfMissing(ctx.app.allocator, &response, "permissions-policy", value);
            if (options.content_security_policy) |value| try setHeaderIfMissing(ctx.app.allocator, &response, "content-security-policy", value);
            if (options.strict_transport_security) |value| try setHeaderIfMissing(ctx.app.allocator, &response, "strict-transport-security", value);
            return response;
        }
    }.handle;
}

pub fn requestIdMiddleware(comptime options: RequestIdOptions) MiddlewareFn {
    return struct {
        fn handle(ctx: *MiddlewareContext, request: Request) !Response {
            var response = try ctx.next(request);
            errdefer response.deinit(ctx.app.allocator);

            const request_id = request.header(options.header_name) orelse options.default_value orelse return response;
            if (request_id.len == 0) return response;
            try response.setHeader(ctx.app.allocator, options.header_name, request_id);
            return response;
        }
    }.handle;
}

pub fn sessionMiddleware(comptime options: SessionOptions) MiddlewareFn {
    if (options.secret_key.len == 0) @compileError("sessionMiddleware requires a non-empty secret_key");

    return struct {
        fn handle(ctx: *MiddlewareContext, request: Request) !Response {
            var session = try loadSession(ctx.app.allocator, request, options);
            defer session.deinit();

            var forwarded = request;
            forwarded.session_ptr = &session;

            var response = try ctx.next(forwarded);
            errdefer response.deinit(ctx.app.allocator);

            if (!session.changed) return response;

            const cookie_options: CookieOptions = .{
                .path = options.path,
                .domain = options.domain,
                .max_age = options.max_age,
                .secure = options.https_only,
                .http_only = options.http_only,
                .same_site = options.same_site,
            };
            if (session.isEmpty()) {
                try response.deleteCookie(ctx.app.allocator, options.session_cookie, cookie_options);
            } else {
                const cookie_value = try encodeSessionCookie(ctx.app.allocator, &session, options.secret_key);
                defer ctx.app.allocator.free(cookie_value);
                try response.setCookie(ctx.app.allocator, options.session_cookie, cookie_value, cookie_options);
            }
            return response;
        }
    }.handle;
}

pub const TrustedHostOptions = middleware_options.TrustedHostOptions;
pub const HttpsRedirectOptions = middleware_options.HttpsRedirectOptions;

pub fn httpsRedirectMiddleware(comptime options: HttpsRedirectOptions) MiddlewareFn {
    return struct {
        fn handle(ctx: *MiddlewareContext, request: Request) !Response {
            const redirect_scheme = if (std.ascii.eqlIgnoreCase(request.scheme, "http"))
                "https"
            else if (std.ascii.eqlIgnoreCase(request.scheme, "ws"))
                "wss"
            else
                return ctx.next(request);

            const host = request.header("host") orelse return ctx.next(request);
            if (host.len == 0) return ctx.next(request);

            var location = std.Io.Writer.Allocating.init(ctx.app.allocator);
            defer location.deinit();
            try location.writer.writeAll(redirect_scheme);
            try location.writer.writeAll("://");
            try location.writer.writeAll(host);
            try location.writer.writeAll(request.path);
            if (request.query.len > 0) {
                try location.writer.writeAll("?");
                try location.writer.writeAll(request.query);
            }

            var response = Response.init(options.status);
            try response.setHeader(ctx.app.allocator, "location", location.written());
            return response;
        }
    }.handle;
}

pub fn trustedHostMiddleware(comptime options: TrustedHostOptions) MiddlewareFn {
    return struct {
        fn handle(ctx: *MiddlewareContext, request: Request) !Response {
            const host_header = request.header("host") orelse return trustedHostFailure(ctx.app);
            const host = trustedHostName(host_header);
            if (trustedHostAllowed(options, host)) return ctx.next(request);

            if (options.www_redirect and std.ascii.startsWithIgnoreCase(host, "www.")) {
                const bare_host = host[4..];
                if (trustedHostAllowed(options, bare_host)) {
                    return trustedHostRedirect(ctx.app, request, host_header, bare_host);
                }
            }

            if (options.www_redirect and !std.ascii.startsWithIgnoreCase(host, "www.")) {
                const www_host = try std.fmt.allocPrint(ctx.app.allocator, "www.{s}", .{host});
                defer ctx.app.allocator.free(www_host);
                if (trustedHostAllowed(options, www_host)) {
                    return trustedHostRedirect(ctx.app, request, host_header, www_host);
                }
            }

            return trustedHostFailure(ctx.app);
        }
    }.handle;
}

pub const ExceptionHandlerFn = *const fn (*ExceptionContext) anyerror!Response;

pub const ExceptionContext = struct {
    app: *ZAPI,
    request: Request,
    err: anyerror,
};

pub const StatusHandlerFn = *const fn (*StatusHandlerContext) anyerror!Response;

pub const StatusHandlerContext = struct {
    app: *ZAPI,
    request: Request,
    status: Status,
    detail: []const u8,
};

pub const LifecycleFn = *const fn (*ZAPI) anyerror!void;

const ExceptionHandler = struct {
    err: anyerror,
    handle: ExceptionHandlerFn,
};

const StatusHandler = struct {
    status: Status,
    handle: StatusHandlerFn,
};

const MountedApp = struct {
    prefix: []const u8,
    name: ?[]const u8 = null,
    app: *ZAPI,
};

const HostApp = struct {
    pattern: []const u8,
    url_pattern: []const u8,
    name: ?[]const u8 = null,
    app: *ZAPI,
};

const ProblemDetail = struct {
    detail: []const u8,
};

pub const OpenApiContact = struct {
    name: ?[]const u8 = null,
    url: ?[]const u8 = null,
    email: ?[]const u8 = null,
};

pub const OpenApiLicense = struct {
    name: []const u8,
    identifier: ?[]const u8 = null,
    url: ?[]const u8 = null,
};

pub const OpenApiExternalDocs = struct {
    url: []const u8,
    description: ?[]const u8 = null,
};

pub const OpenApiTag = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    external_docs: ?OpenApiExternalDocs = null,
};

pub const OpenApiServer = struct {
    url: []const u8,
    description: ?[]const u8 = null,
};

pub const ZAPIOptions = struct {
    title: []const u8 = "Zapi",
    version: []const u8 = "0.1.0",
    description: ?[]const u8 = null,
    terms_of_service: ?[]const u8 = null,
    contact: ?OpenApiContact = null,
    license: ?OpenApiLicense = null,
    openapi_servers: []const OpenApiServer = &.{},
    openapi_tags: []const OpenApiTag = &.{},
    external_docs: ?OpenApiExternalDocs = null,
    openapi_url: ?[]const u8 = "/openapi.json",
    docs_url: ?[]const u8 = "/docs",
    oauth2_redirect_url: ?[]const u8 = "/docs/oauth2-redirect",
    redoc_url: ?[]const u8 = "/redoc",
    max_request_body_size: ?usize = 16 * 1024 * 1024,
    redirect_slashes: bool = true,
    io: ?std.Io = null,
};

pub const ShutdownSignal = struct {
    requested: std.atomic.Value(bool) = .init(false),

    pub fn request(self: *ShutdownSignal) void {
        self.requested.store(true, .release);
    }

    pub fn reset(self: *ShutdownSignal) void {
        self.requested.store(false, .release);
    }

    pub fn isRequested(self: *ShutdownSignal) bool {
        return self.requested.load(.acquire);
    }
};

pub const ServeOptions = struct {
    listen: std.Io.net.IpAddress.ListenOptions = .{ .reuse_address = true },
    max_connections: ?usize = null,
    concurrent_connections: bool = false,
    max_concurrent_connections: usize = 256,
    shutdown_signal: ?*ShutdownSignal = null,
    buffer_request_body: bool = true,
};

pub const ServeListenerOptions = struct {
    max_connections: ?usize = null,
    concurrent_connections: bool = false,
    max_concurrent_connections: usize = 256,
    shutdown_signal: ?*ShutdownSignal = null,
    buffer_request_body: bool = true,
};

/// A named path converter.
pub const PathConvertor = routing.PathConvertor;

/// A configured application and its registered routes.
/// The allocator must be thread-safe when concurrent serving is enabled.
pub const ZAPI = struct {
    allocator: std.mem.Allocator,
    options: ZAPIOptions,
    routes: std.ArrayList(RegisteredRoute),
    route_tree: routing.RouteTree,
    websocket_routes: std.ArrayList(RegisteredWebSocketRoute),
    websocket_route_tree: routing.RouteTree,
    mounts: std.ArrayList(MountedApp),
    hosts: std.ArrayList(HostApp),
    middlewares: std.ArrayList(MiddlewareFn),
    exception_handlers: std.ArrayList(ExceptionHandler),
    status_handlers: std.ArrayList(StatusHandler),
    startup_handlers: std.ArrayList(LifecycleFn),
    shutdown_handlers: std.ArrayList(LifecycleFn),
    path_convertors: std.ArrayList(PathConvertor),
    state_ptr: ?*anyopaque = null,

    pub fn init(allocator: std.mem.Allocator, options: ZAPIOptions) ZAPI {
        return .{
            .allocator = allocator,
            .options = options,
            .routes = .empty,
            .route_tree = .{},
            .websocket_routes = .empty,
            .websocket_route_tree = .{},
            .mounts = .empty,
            .hosts = .empty,
            .middlewares = .empty,
            .exception_handlers = .empty,
            .status_handlers = .empty,
            .startup_handlers = .empty,
            .shutdown_handlers = .empty,
            .path_convertors = .empty,
        };
    }

    pub fn deinit(self: *ZAPI) void {
        self.route_tree.deinit(self.allocator);
        self.websocket_route_tree.deinit(self.allocator);
        for (self.routes.items) |registered_route| {
            self.allocator.free(registered_route.path);
            if (registered_route.middlewares_owned) self.allocator.free(registered_route.middlewares);
            if (registered_route.metadata.tags_owned) self.allocator.free(registered_route.metadata.tags);
            if (registered_route.metadata.name_owned) {
                if (registered_route.metadata.name) |name| self.allocator.free(name);
            }
        }
        for (self.websocket_routes.items) |registered_route| {
            self.allocator.free(registered_route.path);
            if (registered_route.name) |name| self.allocator.free(name);
        }
        for (self.mounts.items) |mounted_app| {
            self.allocator.free(mounted_app.prefix);
            if (mounted_app.name) |name| self.allocator.free(name);
        }
        for (self.hosts.items) |host_app| {
            self.allocator.free(host_app.pattern);
            self.allocator.free(host_app.url_pattern);
            if (host_app.name) |name| self.allocator.free(name);
        }
        for (self.path_convertors.items) |convertor| {
            self.allocator.free(convertor.name);
        }
        self.routes.deinit(self.allocator);
        self.websocket_routes.deinit(self.allocator);
        self.mounts.deinit(self.allocator);
        self.hosts.deinit(self.allocator);
        self.middlewares.deinit(self.allocator);
        self.exception_handlers.deinit(self.allocator);
        self.status_handlers.deinit(self.allocator);
        self.startup_handlers.deinit(self.allocator);
        self.shutdown_handlers.deinit(self.allocator);
        self.path_convertors.deinit(self.allocator);
    }

    pub fn setState(self: *ZAPI, state_ptr: anytype) void {
        self.state_ptr = @ptrCast(state_ptr);
    }

    pub fn state(self: *ZAPI, comptime T: type) *T {
        return @ptrCast(@alignCast(self.state_ptr.?));
    }

    pub fn maybeState(self: *ZAPI, comptime T: type) ?*T {
        const ptr = self.state_ptr orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    pub fn addPathConvertor(self: *ZAPI, name: []const u8, matches: *const fn ([]const u8) bool) !void {
        if (!validPathConvertorName(name)) return error.InvalidPathConvertor;
        if (parseBuiltinPathConverter(name) != null) return error.InvalidPathConvertor;
        for (self.path_convertors.items) |*item| {
            if (!std.mem.eql(u8, item.name, name)) continue;
            item.matches = matches;
            return;
        }

        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        try self.path_convertors.append(self.allocator, .{
            .name = owned_name,
            .matches = matches,
        });
    }

    pub fn includeRouter(self: *ZAPI, router: anytype) !void {
        const RouterType = @TypeOf(router);
        if (comptime isRouterInitResult(RouterType)) {
            var tags_storage = router.tags;
            var middlewares_storage = router.middlewares;
            const tags = routeListItemsSlice([]const u8, &tags_storage);
            const middlewares = routeListItemsSlice(MiddlewareFn, &middlewares_storage);
            try self.includeRouteEntries(router.prefix, tags, middlewares, router.routes);
            return;
        }
        if (RouterType != RouterSpec) @compileError("includeRouter requires Router.init(...) or RouterSpec");
        return self.includeRouterSpec(router);
    }

    fn includeRouterSpec(self: *ZAPI, router: RouterSpec) !void {
        for (router.routes) |route_spec| {
            try self.registerRouteSpec(router.prefix, router.tags, router.middlewares, route_spec);
        }

        for (router.websocket_routes) |route_spec| {
            try self.registerWebSocketRouteSpec(router.prefix, route_spec);
        }

        for (router.mounts) |route_spec| {
            try self.registerMountRouteSpec(router.prefix, route_spec);
        }

        for (router.hosts) |route_spec| {
            try self.registerHostRouteSpec(route_spec);
        }
    }

    pub fn includeRoutes(self: *ZAPI, opts: anytype) !void {
        const Opts = @TypeOf(opts);
        if (!@hasField(Opts, "routes")) @compileError("includeRoutes requires a routes field");

        const prefix = if (@hasField(Opts, "prefix")) opts.prefix else "";
        const raw_tags = if (@hasField(Opts, "tags")) opts.tags else &[_][]const u8{};
        const raw_middlewares = if (@hasField(Opts, "middlewares")) opts.middlewares else &[_]MiddlewareFn{};

        var tags_storage = normalizeRouteListItems([]const u8, raw_tags);
        var middlewares_storage = normalizeRouteListItems(MiddlewareFn, raw_middlewares);
        const tags = routeListItemsSlice([]const u8, &tags_storage);
        const middlewares = routeListItemsSlice(MiddlewareFn, &middlewares_storage);

        try self.includeRouteEntries(prefix, tags, middlewares, opts.routes);
    }

    fn includeRouteEntries(self: *ZAPI, prefix: []const u8, tags: []const []const u8, middlewares: []const MiddlewareFn, entries: anytype) !void {
        const Entries = @TypeOf(entries);
        switch (@typeInfo(Entries)) {
            .@"struct" => |info| {
                if (!info.is_tuple) @compileError("route lists must be tuples, arrays, slices, or single route values");
                inline for (info.fields) |field| {
                    try self.includeRouteEntry(prefix, tags, middlewares, @field(entries, field.name));
                }
            },
            .array => {
                for (entries) |entry| {
                    try self.includeRouteEntry(prefix, tags, middlewares, entry);
                }
            },
            .pointer => |ptr| {
                if (ptr.size == .slice) {
                    for (entries) |entry| {
                        try self.includeRouteEntry(prefix, tags, middlewares, entry);
                    }
                    return;
                }

                switch (@typeInfo(ptr.child)) {
                    .array => {
                        for (entries.*) |entry| {
                            try self.includeRouteEntry(prefix, tags, middlewares, entry);
                        }
                    },
                    .@"struct" => |info| {
                        if (!info.is_tuple) @compileError("route list pointers must point to tuples, arrays, or slices");
                        inline for (info.fields) |field| {
                            try self.includeRouteEntry(prefix, tags, middlewares, @field(entries.*, field.name));
                        }
                    },
                    else => @compileError("route list pointers must point to tuples, arrays, or slices"),
                }
            },
            else => try self.includeRouteEntry(prefix, tags, middlewares, entries),
        }
    }

    fn includeRouteEntry(self: *ZAPI, prefix: []const u8, tags: []const []const u8, middlewares: []const MiddlewareFn, entry: anytype) !void {
        const Entry = @TypeOf(entry);
        if (Entry == RouteSpec) {
            return self.registerRouteSpec(prefix, tags, middlewares, entry);
        }
        if (Entry == WebSocketRouteSpec) {
            return self.registerWebSocketRouteSpec(prefix, entry);
        }
        if (Entry == MountRouteSpec) {
            return self.registerMountRouteSpec(prefix, entry);
        }
        if (Entry == HostRouteSpec) {
            return self.registerHostRouteSpec(entry);
        }
        if (comptime isRouterInitResult(Entry)) {
            const nested_prefix = try joinPaths(self.allocator, prefix, entry.prefix);
            defer self.allocator.free(nested_prefix);

            var entry_tags_storage = entry.tags;
            var entry_middlewares_storage = entry.middlewares;
            const entry_tags = routeListItemsSlice([]const u8, &entry_tags_storage);
            const entry_middlewares = routeListItemsSlice(MiddlewareFn, &entry_middlewares_storage);

            const nested_tags = try combineRouteTags(self.allocator, tags, entry_tags);
            defer if (nested_tags.owned) self.allocator.free(nested_tags.value);

            const nested_middlewares = try combineRouteMiddlewares(self.allocator, middlewares, entry_middlewares);
            defer if (nested_middlewares.owned) self.allocator.free(nested_middlewares.value);

            try self.includeRouteEntries(nested_prefix, nested_tags.value, nested_middlewares.value, entry.routes);
            return;
        }
        if (Entry == RouterSpec) {
            const nested_prefix = try joinPaths(self.allocator, prefix, entry.prefix);
            defer self.allocator.free(nested_prefix);

            const nested_tags = try combineRouteTags(self.allocator, tags, entry.tags);
            defer if (nested_tags.owned) self.allocator.free(nested_tags.value);

            const nested_middlewares = try combineRouteMiddlewares(self.allocator, middlewares, entry.middlewares);
            defer if (nested_middlewares.owned) self.allocator.free(nested_middlewares.value);

            try self.includeRouterSpec(.{
                .prefix = nested_prefix,
                .tags = nested_tags.value,
                .middlewares = nested_middlewares.value,
                .routes = entry.routes,
                .websocket_routes = entry.websocket_routes,
                .mounts = entry.mounts,
                .hosts = entry.hosts,
            });
            return;
        }
        @compileError("includeRoutes routes must be RouteSpec, WebSocketRouteSpec, MountRouteSpec, HostRouteSpec, Router.init(...), or RouterSpec values; got " ++ @typeName(Entry));
    }

    fn registerRouteSpec(self: *ZAPI, prefix: []const u8, tags: []const []const u8, middlewares: []const MiddlewareFn, route_spec: RouteSpec) !void {
        const full_path = try joinPaths(self.allocator, prefix, route_spec.path);
        errdefer self.allocator.free(full_path);
        try validateRoutePath(self.allocator, full_path, self.path_convertors.items);
        var metadata = route_spec.metadata;
        var route_tags = try combineRouteTags(self.allocator, tags, metadata.tags);
        if (!route_tags.owned and route_tags.value.len > 0) {
            route_tags = .{
                .value = try self.allocator.dupe([]const u8, route_tags.value),
                .owned = true,
            };
        }
        metadata.tags = route_tags.value;
        metadata.tags_owned = route_tags.owned;
        try self.applyRegisteredRouteName(&metadata, route_spec.method, full_path);
        errdefer if (metadata.name_owned) {
            if (metadata.name) |name| self.allocator.free(name);
        };
        errdefer if (metadata.tags_owned) self.allocator.free(metadata.tags);
        try self.validateRouteNameAvailable(metadata.name, full_path);
        var route_middlewares = try combineRouteMiddlewares(self.allocator, middlewares, route_spec.middlewares);
        if (!route_middlewares.owned and route_middlewares.value.len > 0) {
            route_middlewares = .{
                .value = try self.allocator.dupe(MiddlewareFn, route_middlewares.value),
                .owned = true,
            };
        }
        errdefer if (route_middlewares.owned) self.allocator.free(route_middlewares.value);
        try self.routes.append(self.allocator, .{
            .method = route_spec.method,
            .path = full_path,
            .dispatch = route_spec.dispatch,
            .middlewares = route_middlewares.value,
            .middlewares_owned = route_middlewares.owned,
            .metadata = metadata,
        });
        errdefer _ = self.routes.pop();
        try self.route_tree.add(self.allocator, full_path, .{
            .index = self.routes.items.len - 1,
            .method = route_spec.method,
        });
    }

    fn registerWebSocketRouteSpec(self: *ZAPI, prefix: []const u8, route_spec: WebSocketRouteSpec) !void {
        const full_path = try joinPaths(self.allocator, prefix, route_spec.path);
        errdefer self.allocator.free(full_path);
        try validateRoutePath(self.allocator, full_path, self.path_convertors.items);
        const owned_name = if (route_spec.name) |name| try self.allocator.dupe(u8, name) else null;
        errdefer if (owned_name) |name| self.allocator.free(name);
        try self.websocket_routes.append(self.allocator, .{
            .path = full_path,
            .handler = route_spec.handler,
            .name = owned_name,
        });
        errdefer _ = self.websocket_routes.pop();
        try self.websocket_route_tree.add(self.allocator, full_path, .{
            .index = self.websocket_routes.items.len - 1,
        });
    }

    fn registerMountRouteSpec(self: *ZAPI, prefix: []const u8, route_spec: MountRouteSpec) !void {
        const full_prefix = try joinPaths(self.allocator, prefix, route_spec.prefix);
        defer self.allocator.free(full_prefix);
        try self.mountNamed(full_prefix, route_spec.name, route_spec.app);
    }

    fn registerHostRouteSpec(self: *ZAPI, route_spec: HostRouteSpec) !void {
        try self.hostNamed(route_spec.pattern, route_spec.name, route_spec.app);
    }

    fn applyRegisteredRouteName(self: *ZAPI, metadata: *RouteMetadata, method: Method, path: []const u8) !void {
        if (metadata.name_is_explicit) return;
        metadata.name = try routeDefaultNameAlloc(self.allocator, method, path);
        metadata.name_owned = true;
    }

    fn validateRouteNameAvailable(self: *ZAPI, name: ?[]const u8, path: []const u8) !void {
        const route_name = name orelse return;

        for (self.routes.items) |route_item| {
            const existing_name = route_item.metadata.name orelse continue;
            if (!std.mem.eql(u8, existing_name, route_name)) continue;
            if (!std.mem.eql(u8, route_item.path, path)) return error.DuplicateRouteName;
        }

        for (self.websocket_routes.items) |route_item| {
            const existing_name = route_item.name orelse continue;
            if (!std.mem.eql(u8, existing_name, route_name)) continue;
            if (!std.mem.eql(u8, route_item.path, path)) return error.DuplicateRouteName;
        }
    }

    pub fn route(self: *ZAPI, route_spec: anytype) !void {
        const Spec = @TypeOf(route_spec);
        if (Spec == RouteSpec) {
            return self.includeRouter(RouterSpec{ .routes = &.{route_spec} });
        }
        if (Spec == WebSocketRouteSpec) {
            return self.includeRouter(RouterSpec{ .routes = &.{}, .websocket_routes = &.{route_spec} });
        }
        if (Spec == MountRouteSpec) {
            return self.includeRouter(RouterSpec{ .routes = &.{}, .mounts = &.{route_spec} });
        }
        if (Spec == HostRouteSpec) {
            return self.includeRouter(RouterSpec{ .routes = &.{}, .hosts = &.{route_spec} });
        }
        if (comptime isRouterInitResult(Spec)) {
            return self.includeRouter(route_spec);
        }
        if (Spec == RouterSpec) {
            return self.includeRouter(route_spec);
        }
        @compileError("ZAPI.route requires a RouteSpec, WebSocketRouteSpec, MountRouteSpec, HostRouteSpec, or router");
    }

    pub fn mount(self: *ZAPI, prefix: []const u8, app: *ZAPI) !void {
        try self.mountNamed(prefix, null, app);
    }

    pub fn mountNamed(self: *ZAPI, prefix: []const u8, name: ?[]const u8, app: *ZAPI) !void {
        if (prefix.len == 0 or prefix[0] != '/') return error.InvalidMountPath;
        const normalized = normalizeMountPrefix(prefix);
        try validateMountPath(self.allocator, normalized, self.path_convertors.items);
        if (name) |value| {
            if (!validRouteNamespace(value)) return error.InvalidMountName;
        }

        const owned_prefix = try self.allocator.dupe(u8, normalized);
        errdefer self.allocator.free(owned_prefix);
        const owned_name = if (name) |value| try self.allocator.dupe(u8, value) else null;
        errdefer if (owned_name) |value| self.allocator.free(value);
        try self.mounts.append(self.allocator, .{
            .prefix = owned_prefix,
            .name = owned_name,
            .app = app,
        });
    }

    pub fn host(self: *ZAPI, pattern: []const u8, app: *ZAPI) !void {
        try self.hostNamed(pattern, null, app);
    }

    pub fn hostNamed(self: *ZAPI, pattern: []const u8, name: ?[]const u8, app: *ZAPI) !void {
        const match_pattern = normalizeHostMatchPattern(pattern) orelse return error.InvalidHostPattern;
        const url_pattern = normalizeHostUrlPattern(pattern) orelse return error.InvalidHostPattern;
        try validateHostPattern(self.allocator, match_pattern, self.path_convertors.items);
        if (name) |value| {
            if (!validRouteNamespace(value)) return error.InvalidHostName;
        }
        const owned_match_pattern = try self.allocator.dupe(u8, match_pattern);
        errdefer self.allocator.free(owned_match_pattern);
        const owned_url_pattern = try self.allocator.dupe(u8, url_pattern);
        errdefer self.allocator.free(owned_url_pattern);
        const owned_name = if (name) |value| try self.allocator.dupe(u8, value) else null;
        errdefer if (owned_name) |value| self.allocator.free(value);

        try self.hosts.append(self.allocator, .{
            .pattern = owned_match_pattern,
            .url_pattern = owned_url_pattern,
            .name = owned_name,
            .app = app,
        });
    }

    pub fn addMiddleware(self: *ZAPI, middleware_fn: MiddlewareFn) !void {
        try self.middlewares.append(self.allocator, middleware_fn);
    }

    pub fn middleware(self: *ZAPI, middleware_fn: MiddlewareFn) !void {
        return self.addMiddleware(middleware_fn);
    }

    pub fn addExceptionHandler(self: *ZAPI, err: anyerror, handler: ExceptionHandlerFn) !void {
        for (self.exception_handlers.items) |*item| {
            if (item.err == err) {
                item.handle = handler;
                return;
            }
        }

        try self.exception_handlers.append(self.allocator, .{
            .err = err,
            .handle = handler,
        });
    }

    pub fn addStatusHandler(self: *ZAPI, status: Status, handler: StatusHandlerFn) !void {
        for (self.status_handlers.items) |*item| {
            if (item.status == status) {
                item.handle = handler;
                return;
            }
        }

        try self.status_handlers.append(self.allocator, .{
            .status = status,
            .handle = handler,
        });
    }

    pub fn addStartupHandler(self: *ZAPI, handler: LifecycleFn) !void {
        try self.startup_handlers.append(self.allocator, handler);
    }

    pub fn addShutdownHandler(self: *ZAPI, handler: LifecycleFn) !void {
        try self.shutdown_handlers.append(self.allocator, handler);
    }

    pub fn startup(self: *ZAPI) !void {
        for (self.startup_handlers.items) |handler| {
            try handler(self);
        }
        for (self.hosts.items) |host_app| {
            try host_app.app.startup();
        }
        for (self.mounts.items) |mounted_app| {
            try mounted_app.app.startup();
        }
    }

    pub fn shutdown(self: *ZAPI) !void {
        var mount_index = self.mounts.items.len;
        while (mount_index > 0) {
            mount_index -= 1;
            try self.mounts.items[mount_index].app.shutdown();
        }

        var host_index = self.hosts.items.len;
        while (host_index > 0) {
            host_index -= 1;
            try self.hosts.items[host_index].app.shutdown();
        }

        var handler_index = self.shutdown_handlers.items.len;
        while (handler_index > 0) {
            handler_index -= 1;
            try self.shutdown_handlers.items[handler_index](self);
        }
    }

    fn urlResolver(self: *ZAPI) requests.URLResolver {
        return .{
            .context = self,
            .resolve_fn = resolveRequestPath,
        };
    }

    fn resolveRequestPath(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        name: []const u8,
        params: []const HeaderField,
    ) anyerror![]u8 {
        const self: *ZAPI = @ptrCast(@alignCast(context));
        return self.urlPathForFields(allocator, name, params);
    }

    fn urlPathForFields(
        self: *ZAPI,
        allocator: std.mem.Allocator,
        name: []const u8,
        params: []const HeaderField,
    ) anyerror![]u8 {
        const used = try allocator.alloc(bool, params.len);
        defer allocator.free(used);
        @memset(used, false);

        const path = self.urlPathForFieldsTracked(allocator, name, params, used) catch |err| switch (err) {
            error.MissingPathParam => return error.NoRoute,
            else => return err,
        };
        errdefer allocator.free(path);
        for (used) |is_used| {
            if (!is_used) return error.NoRoute;
        }
        return path;
    }

    fn urlPathForFieldsTracked(
        self: *ZAPI,
        allocator: std.mem.Allocator,
        name: []const u8,
        params: []const HeaderField,
        used: []bool,
    ) anyerror![]u8 {
        for (self.routes.items) |route_item| {
            const route_name = route_item.metadata.name orelse continue;
            if (!std.mem.eql(u8, route_name, name)) continue;
            return routing.renderPathFields(allocator, route_item.path, params, used, self.path_convertors.items);
        }

        for (self.websocket_routes.items) |route_item| {
            const route_name = route_item.name orelse continue;
            if (!std.mem.eql(u8, route_name, name)) continue;
            return routing.renderPathFields(allocator, route_item.path, params, used, self.path_convertors.items);
        }

        for (self.mounts.items) |mounted_app| {
            if (mounted_app.name) |mount_name| {
                if (std.mem.eql(u8, name, mount_name)) {
                    return routing.renderMountFields(allocator, mounted_app.prefix, params, used, self.path_convertors.items);
                }
                if (namespacedRouteName(name, mount_name)) |child_name| {
                    const candidate_used = try allocator.dupe(bool, used);
                    defer allocator.free(candidate_used);
                    const child_path = try mounted_app.app.urlPathForFieldsTracked(
                        allocator,
                        child_name,
                        params,
                        candidate_used,
                    );
                    defer allocator.free(child_path);
                    const mount_path = try routing.renderPathFields(
                        allocator,
                        mounted_app.prefix,
                        params,
                        candidate_used,
                        self.path_convertors.items,
                    );
                    defer allocator.free(mount_path);
                    @memcpy(used, candidate_used);
                    return joinMountRoutePath(allocator, mount_path, child_path);
                }
            }
        }

        for (self.hosts.items) |host_app| {
            if (host_app.name) |host_name| {
                if (std.mem.eql(u8, name, host_name)) {
                    return routing.renderMountFields(allocator, "/", params, used, self.path_convertors.items);
                }
                if (namespacedRouteName(name, host_name)) |child_name| {
                    const candidate_used = try allocator.dupe(bool, used);
                    defer allocator.free(candidate_used);
                    const child_path = try host_app.app.urlPathForFieldsTracked(
                        allocator,
                        child_name,
                        params,
                        candidate_used,
                    );
                    defer allocator.free(child_path);
                    @memcpy(used, candidate_used);
                    return allocator.dupe(u8, child_path);
                }
            }
        }

        for (self.mounts.items) |mounted_app| {
            const candidate_used = try allocator.dupe(bool, used);
            defer allocator.free(candidate_used);
            const child_path = mounted_app.app.urlPathForFieldsTracked(
                allocator,
                name,
                params,
                candidate_used,
            ) catch |err| switch (err) {
                error.NoRoute => continue,
                else => return err,
            };
            defer allocator.free(child_path);
            const mount_path = routing.renderPathFields(
                allocator,
                mounted_app.prefix,
                params,
                candidate_used,
                self.path_convertors.items,
            ) catch |err| switch (err) {
                error.MissingPathParam, error.InvalidPathParam => continue,
                else => return err,
            };
            defer allocator.free(mount_path);
            @memcpy(used, candidate_used);
            return joinMountRoutePath(allocator, mount_path, child_path);
        }

        for (self.hosts.items) |host_app| {
            const candidate_used = try allocator.dupe(bool, used);
            defer allocator.free(candidate_used);
            const child_path = host_app.app.urlPathForFieldsTracked(
                allocator,
                name,
                params,
                candidate_used,
            ) catch |err| switch (err) {
                error.NoRoute => continue,
                else => return err,
            };
            defer allocator.free(child_path);
            @memcpy(used, candidate_used);
            return allocator.dupe(u8, child_path);
        }

        return error.NoRoute;
    }

    pub fn urlPathFor(self: *ZAPI, name: []const u8, params: anytype) anyerror![]u8 {
        const Params = @TypeOf(params);
        var used = initParamUsage(Params);
        const path = self.urlPathForTracked(name, params, &used) catch |err| switch (err) {
            error.MissingPathParam => return error.NoRoute,
            else => return err,
        };
        errdefer self.allocator.free(path);
        try ensureNoUnusedUrlParams(params, used);
        return path;
    }

    fn urlPathForTracked(self: *ZAPI, name: []const u8, params: anytype, used: anytype) anyerror![]u8 {
        for (self.routes.items) |route_item| {
            const route_name = route_item.metadata.name orelse continue;
            if (!std.mem.eql(u8, route_name, name)) continue;
            return renderPathTracked(self.allocator, route_item.path, params, used, self.path_convertors.items);
        }

        for (self.websocket_routes.items) |route_item| {
            const route_name = route_item.name orelse continue;
            if (!std.mem.eql(u8, route_name, name)) continue;
            return renderPathTracked(self.allocator, route_item.path, params, used, self.path_convertors.items);
        }

        for (self.mounts.items) |mounted_app| {
            if (mounted_app.name) |mount_name| {
                if (std.mem.eql(u8, name, mount_name)) {
                    return renderMountPathTracked(self.allocator, mounted_app.prefix, params, used, self.path_convertors.items);
                }
                if (namespacedRouteName(name, mount_name)) |child_name| {
                    var candidate_used = used.*;
                    const child_path = try mounted_app.app.urlPathForTracked(child_name, params, &candidate_used);
                    defer mounted_app.app.allocator.free(child_path);
                    const mount_path = try renderPathTracked(self.allocator, mounted_app.prefix, params, &candidate_used, self.path_convertors.items);
                    defer self.allocator.free(mount_path);
                    used.* = candidate_used;
                    return joinMountRoutePath(self.allocator, mount_path, child_path);
                }
            }
        }

        for (self.hosts.items) |host_app| {
            if (host_app.name) |host_name| {
                if (std.mem.eql(u8, name, host_name)) {
                    return renderMountPathTracked(self.allocator, "/", params, used, self.path_convertors.items);
                }
                if (namespacedRouteName(name, host_name)) |child_name| {
                    var candidate_used = used.*;
                    const child_path = try host_app.app.urlPathForTracked(child_name, params, &candidate_used);
                    defer host_app.app.allocator.free(child_path);
                    used.* = candidate_used;
                    return self.allocator.dupe(u8, child_path);
                }
            }
        }

        for (self.mounts.items) |mounted_app| {
            var candidate_used = used.*;
            const child_path = mounted_app.app.urlPathForTracked(name, params, &candidate_used) catch |err| switch (err) {
                error.NoRoute => continue,
                else => return err,
            };
            defer mounted_app.app.allocator.free(child_path);
            const mount_path = renderPathTracked(self.allocator, mounted_app.prefix, params, &candidate_used, self.path_convertors.items) catch |err| switch (err) {
                error.MissingPathParam, error.InvalidPathParam => continue,
                else => return err,
            };
            defer self.allocator.free(mount_path);
            used.* = candidate_used;
            return joinMountRoutePath(self.allocator, mount_path, child_path);
        }

        for (self.hosts.items) |host_app| {
            var candidate_used = used.*;
            const child_path = host_app.app.urlPathForTracked(name, params, &candidate_used) catch |err| switch (err) {
                error.NoRoute => continue,
                else => return err,
            };
            defer host_app.app.allocator.free(child_path);
            used.* = candidate_used;
            return self.allocator.dupe(u8, child_path);
        }

        return error.NoRoute;
    }

    pub fn urlForHost(self: *ZAPI, name: []const u8, params: anytype, scheme: []const u8) anyerror![]u8 {
        const Params = @TypeOf(params);
        var used = initParamUsage(Params);
        const url = self.urlForHostTracked(name, params, scheme, &used) catch |err| switch (err) {
            error.MissingPathParam => return error.NoRoute,
            else => return err,
        };
        errdefer self.allocator.free(url);
        try ensureNoUnusedUrlParams(params, used);
        return url;
    }

    fn urlForHostTracked(self: *ZAPI, name: []const u8, params: anytype, scheme: []const u8, used: anytype) anyerror![]u8 {
        for (self.hosts.items) |host_app| {
            const host_name = host_app.name orelse continue;
            if (std.mem.eql(u8, name, host_name)) {
                const rendered_host = try renderHostPatternTracked(self.allocator, host_app.url_pattern, params, used, self.path_convertors.items);
                defer self.allocator.free(rendered_host);
                const path = try renderMountPathTracked(self.allocator, "/", params, used, self.path_convertors.items);
                defer self.allocator.free(path);
                return std.fmt.allocPrint(self.allocator, "{s}://{s}{s}", .{ scheme, rendered_host, path });
            }
            if (namespacedRouteName(name, host_name)) |child_name| {
                var candidate_used = used.*;
                const rendered_host = try renderHostPatternTracked(self.allocator, host_app.url_pattern, params, &candidate_used, self.path_convertors.items);
                defer self.allocator.free(rendered_host);
                const child_path = try host_app.app.urlPathForTracked(child_name, params, &candidate_used);
                defer host_app.app.allocator.free(child_path);
                used.* = candidate_used;
                return std.fmt.allocPrint(self.allocator, "{s}://{s}{s}", .{ scheme, rendered_host, child_path });
            }
        }

        return error.NoRoute;
    }

    pub fn handle(self: *ZAPI, request: Request) !Response {
        var response = try self.handleWithoutBackgroundTasksMode(request, .catch_unhandled);
        errdefer response.deinit(self.allocator);
        try response.collectStream(self.allocator);
        try self.finalizeResponseForRequest(request, &response);
        try response.runBackgroundTasks();
        return response;
    }

    pub fn handleOrRaise(self: *ZAPI, request: Request) !Response {
        var response = try self.handleWithoutBackgroundTasksMode(request, .raise_unhandled);
        errdefer response.deinit(self.allocator);
        try response.collectStream(self.allocator);
        try self.finalizeResponseForRequest(request, &response);
        try response.runBackgroundTasks();
        return response;
    }

    fn handleWithoutBackgroundTasks(self: *ZAPI, request: Request) !Response {
        return self.handleWithoutBackgroundTasksMode(request, .catch_unhandled);
    }

    fn handleWithoutBackgroundTasksMode(self: *ZAPI, request: Request, mode: ExceptionMode) !Response {
        var scoped_request = request;
        if (scoped_request.url_resolver == null) scoped_request.url_resolver = self.urlResolver();
        if (scoped_request.url_root_path == null) scoped_request.url_root_path = scoped_request.root_path;

        if (self.requestBodyTooLarge(scoped_request)) {
            return self.problemForRequest(scoped_request, .payload_too_large, "Request body too large");
        }
        return self.handleWithMiddlewareMode(scoped_request, 0, mode) catch |err| self.handleExceptionMode(scoped_request, err, mode);
    }

    fn requestBodyTooLarge(self: *ZAPI, request: Request) bool {
        const max_size = self.options.max_request_body_size orelse return false;
        return request.body.len > max_size;
    }

    fn handleWithMiddleware(self: *ZAPI, request: Request, index: usize) !Response {
        return self.handleWithMiddlewareMode(request, index, .catch_unhandled);
    }

    fn handleWithMiddlewareMode(self: *ZAPI, request: Request, index: usize, mode: ExceptionMode) !Response {
        if (index < self.middlewares.items.len) {
            var ctx = MiddlewareContext{
                .app = self,
                .index = index,
                .exception_mode = mode,
            };
            return self.middlewares.items[index](&ctx, request);
        }

        return self.handleCoreMode(request, mode);
    }

    fn handleRouteWithMiddleware(self: *ZAPI, request: Request, route_item: *const RegisteredRoute, params: *std.StringHashMap([]const u8), index: usize) !Response {
        return self.handleRouteWithMiddlewareMode(request, route_item, params, index, .catch_unhandled);
    }

    fn handleRouteWithMiddlewareMode(self: *ZAPI, request: Request, route_item: *const RegisteredRoute, params: *std.StringHashMap([]const u8), index: usize, mode: ExceptionMode) !Response {
        if (index < route_item.middlewares.len) {
            var ctx = MiddlewareContext{
                .app = self,
                .index = index,
                .route_item = route_item,
                .route_params = params,
                .exception_mode = mode,
            };
            return route_item.middlewares[index](&ctx, request);
        }

        return self.dispatchRoute(request, route_item, params);
    }

    fn dispatchRoute(self: *ZAPI, request: Request, route_item: *const RegisteredRoute, params: *std.StringHashMap([]const u8)) !Response {
        const request_path_params = try requestPathParamFields(self.allocator, request.host_params, route_item.path, params);
        defer self.allocator.free(request_path_params);

        var scoped_request = request;
        scoped_request.path_params = request_path_params;

        var ctx = Context{
            .app = self,
            .allocator = self.allocator,
            .request = scoped_request,
            .path_params = params.*,
            .route_metadata = &route_item.metadata,
            .state_ptr = self.state_ptr,
            .io = self.options.io orelse request.inherited_io,
        };
        const payload = route_item.dispatch(&ctx) catch |err| switch (err) {
            error.Validation => return self.problemForRequest(scoped_request, .unprocessable_entity, "Validation error"),
            error.BearerUnauthorized => return self.unauthorizedForRequest(scoped_request, "Bearer"),
            error.BasicUnauthorized => return self.unauthorizedForRequest(scoped_request, "Basic"),
            error.Unauthorized => return self.unauthorizedForRequest(scoped_request, null),
            else => return err,
        };
        defer payload.deinit(self.allocator);

        var response = Response.init(payload.status orelse route_item.metadata.status);
        errdefer response.deinit(self.allocator);
        for (payload.background_tasks) |task| {
            try response.addBackgroundTask(self.allocator, task);
        }
        for (payload.headers) |header| {
            try response.appendHeader(self.allocator, header.name, header.value);
        }
        response.stream = payload.stream;
        if (responseBodyAllowed(response.status)) {
            if (payload.content_type.len > 0 and response.header("content-type") == null) {
                try response.setHeader(self.allocator, "content-type", payload.content_type);
            }
            if (payload.stream != null) {
                if (request.method == .HEAD) try response.collectStream(self.allocator);
            } else {
                try response.body.appendSlice(self.allocator, payload.body);
            }
        }
        return response;
    }

    fn handleCore(self: *ZAPI, request: Request) !Response {
        return self.handleCoreMode(request, .catch_unhandled);
    }

    fn handleCoreMode(self: *ZAPI, request: Request, mode: ExceptionMode) !Response {
        if (self.options.openapi_url) |openapi_url| {
            if (methodReadsGetResource(request.method) and std.mem.eql(u8, request.path, openapi_url)) {
                var response = Response.init(.ok);
                try response.setHeader(self.allocator, "content-type", "application/json");
                var aw = std.Io.Writer.Allocating.fromArrayList(self.allocator, &response.body);
                errdefer aw.deinit();
                try writeOpenApi(self.allocator, &aw.writer, self, request.root_path);
                response.body = aw.toArrayList();
                return response;
            }
        }

        if (self.options.docs_url) |docs_url| {
            if (methodReadsGetResource(request.method) and std.mem.eql(u8, request.path, docs_url)) {
                var response = Response.init(.ok);
                try response.setHeader(self.allocator, "content-type", "text/html; charset=utf-8");
                var aw = std.Io.Writer.Allocating.fromArrayList(self.allocator, &response.body);
                errdefer aw.deinit();
                const docs_openapi_url = try docsOpenApiUrl(self.allocator, request.root_path, self.options.openapi_url orelse "/openapi.json");
                defer if (docs_openapi_url.owned) self.allocator.free(docs_openapi_url.value);
                const oauth2_redirect_url = if (self.options.oauth2_redirect_url) |url| try docsOpenApiUrl(self.allocator, request.root_path, url) else MaybeOwnedSlice{ .value = "" };
                defer if (oauth2_redirect_url.owned) self.allocator.free(oauth2_redirect_url.value);
                try writeSwaggerUiHtml(&aw.writer, self.options.title, docs_openapi_url.value, if (self.options.oauth2_redirect_url != null) oauth2_redirect_url.value else null);
                response.body = aw.toArrayList();
                return response;
            }
        }

        if (self.options.docs_url != null) {
            if (self.options.oauth2_redirect_url) |oauth2_redirect_url| {
                if (methodReadsGetResource(request.method) and std.mem.eql(u8, request.path, oauth2_redirect_url)) {
                    var response = Response.init(.ok);
                    try response.setHeader(self.allocator, "content-type", "text/html; charset=utf-8");
                    var aw = std.Io.Writer.Allocating.fromArrayList(self.allocator, &response.body);
                    errdefer aw.deinit();
                    try writeSwaggerUiOAuth2RedirectHtml(&aw.writer, self.options.title);
                    response.body = aw.toArrayList();
                    return response;
                }
            }
        }

        if (self.options.redoc_url) |redoc_url| {
            if (methodReadsGetResource(request.method) and std.mem.eql(u8, request.path, redoc_url)) {
                var response = Response.init(.ok);
                try response.setHeader(self.allocator, "content-type", "text/html; charset=utf-8");
                var aw = std.Io.Writer.Allocating.fromArrayList(self.allocator, &response.body);
                errdefer aw.deinit();
                const redoc_openapi_url = try docsOpenApiUrl(self.allocator, request.root_path, self.options.openapi_url orelse "/openapi.json");
                defer if (redoc_openapi_url.owned) self.allocator.free(redoc_openapi_url.value);
                try writeRedocHtml(&aw.writer, self.options.title, redoc_openapi_url.value);
                response.body = aw.toArrayList();
                return response;
            }
        }

        if (request.header("host")) |host_header| {
            if (requestHostName(host_header)) |host_name| {
                for (self.hosts.items) |host_app| {
                    var host_params = std.ArrayList(HeaderField).empty;
                    defer host_params.deinit(self.allocator);
                    if (!try matchHost(self.allocator, host_app.pattern, host_name, &host_params, self.path_convertors.items)) continue;
                    var hosted_request = request;
                    hosted_request.host_params = host_params.items;
                    hosted_request.inherited_io = self.options.io orelse request.inherited_io;
                    var hosted_response = try host_app.app.handleWithoutBackgroundTasksMode(hosted_request, mode);
                    defer hosted_response.deinit(host_app.app.allocator);
                    return try cloneResponse(self.allocator, hosted_response);
                }
            }
        }

        for (self.mounts.items) |mounted_app| {
            var mount_params = std.ArrayList(HeaderField).empty;
            defer mount_params.deinit(self.allocator);
            if (try matchMount(self.allocator, mounted_app.prefix, request.path, &mount_params, self.path_convertors.items)) |mount_match| {
                const mounted_root_path = try mountRootPath(self.allocator, request.root_path, mount_match.root_prefix);
                defer if (mounted_root_path.owned) self.allocator.free(mounted_root_path.value);
                var carried_params = std.ArrayList(HeaderField).empty;
                defer carried_params.deinit(self.allocator);
                try carried_params.appendSlice(self.allocator, request.host_params);
                try carried_params.appendSlice(self.allocator, mount_params.items);
                var mounted_request = request;
                mounted_request.path = mount_match.path;
                mounted_request.root_path = mounted_root_path.value;
                mounted_request.host_params = carried_params.items;
                mounted_request.inherited_io = self.options.io orelse request.inherited_io;
                var mounted_response = try mounted_app.app.handleWithoutBackgroundTasksMode(mounted_request, mode);
                defer mounted_response.deinit(mounted_app.app.allocator);
                return try cloneResponse(self.allocator, mounted_response);
            }
        }

        const route_matches = self.route_tree.matches(request.path, self.path_convertors.items);
        const explicit_head_route = route_matches.firstForMethod(.HEAD) != null;
        const explicit_options_route = route_matches.firstForMethod(.OPTIONS) != null;
        const route_index = route_matches.firstForMethod(request.method) orelse if (request.method == .HEAD and !explicit_head_route)
            route_matches.firstForMethod(.GET)
        else
            null;

        if (route_index) |index| {
            const route_item = &self.routes.items[index];
            var params = std.StringHashMap([]const u8).init(self.allocator);
            defer params.deinit();
            for (request.host_params) |param| try params.put(param.name, param.value);
            if (!(try matchPath(route_item.path, request.path, &params, self.path_convertors.items))) {
                return error.InvalidRouteIndex;
            }
            return self.handleRouteWithMiddlewareMode(request, route_item, &params, 0, mode);
        }

        if (route_matches.first_any != null) {
            var allowed_methods: std.ArrayList(Method) = .empty;
            defer allowed_methods.deinit(self.allocator);
            var method_buffer: [std.meta.fields(Method).len]Method = undefined;
            for (route_matches.methodsInRegistrationOrder(&method_buffer)) |method| {
                try appendAllowedMethod(self.allocator, &allowed_methods, method);
            }
            if (!explicit_options_route) try appendAllowedMethod(self.allocator, &allowed_methods, .OPTIONS);
            if (request.method == .OPTIONS and !explicit_options_route) return self.automaticOptions(request, allowed_methods.items);
            return self.methodNotAllowed(request, allowed_methods.items);
        }
        if (self.options.redirect_slashes) {
            if (try self.redirectSlash(request)) |response| return response;
        }
        return self.problemForRequest(request, .not_found, "Not found");
    }

    fn handleException(self: *ZAPI, request: Request, err: anyerror) !Response {
        return self.handleExceptionMode(request, err, .catch_unhandled);
    }

    fn handleExceptionMode(self: *ZAPI, request: Request, err: anyerror, mode: ExceptionMode) !Response {
        for (self.exception_handlers.items) |item| {
            if (item.err != err) continue;
            var ctx = ExceptionContext{
                .app = self,
                .request = request,
                .err = err,
            };
            return item.handle(&ctx);
        }

        if (err == error.Validation) return self.problemForRequest(request, .unprocessable_entity, "Validation error");
        if (err == error.RequestBodyTooLarge) return self.problemForRequest(request, .payload_too_large, "Request body too large");
        if (mode == .raise_unhandled) return err;
        return self.problemForRequest(request, .internal_server_error, "Internal server error");
    }

    pub fn handleHttp(self: *ZAPI, http_request: *std.http.Server.Request) !void {
        return self.handleHttpWithIo(http_request, self.options.io);
    }

    fn handleHttpWithIo(self: *ZAPI, http_request: *std.http.Server.Request, io: ?std.Io) !void {
        const target = try self.allocator.dupe(u8, http_request.head.target);
        defer self.allocator.free(target);
        const request_method = try methodFromHttp(http_request.head.method);

        var headers: std.ArrayList(HeaderField) = .empty;
        defer {
            for (headers.items) |item| {
                self.allocator.free(item.name);
                self.allocator.free(item.value);
            }
            headers.deinit(self.allocator);
        }

        var header_it = http_request.iterateHeaders();
        while (header_it.next()) |item| {
            try headers.append(self.allocator, .{
                .name = try self.allocator.dupe(u8, item.name),
                .value = try self.allocator.dupe(u8, item.value),
            });
        }

        var request = Request.init(request_method, target);
        request.headers = headers.items;
        request.inherited_io = io;

        if (try self.handleWebSocketHttp(http_request, request)) return;

        const body = self.readHttpRequestBody(http_request) catch |err| switch (err) {
            error.RequestBodyTooLarge => {
                var response = try self.problemForRequest(request, .payload_too_large, "Request body too large");
                defer response.deinit(self.allocator);
                try self.finalizeResponseForTransport(&response);
                try self.respondHttp(http_request, response);
                return;
            },
            else => return err,
        };
        defer self.allocator.free(body);

        request.body = body;

        var response = try self.handleWithoutBackgroundTasks(request);
        defer response.deinit(self.allocator);

        try self.finalizeResponseForTransport(&response);
        try self.respondHttp(http_request, response);
        try response.runBackgroundTasks();
    }

    pub fn handleHttpStreaming(self: *ZAPI, http_request: *std.http.Server.Request) !void {
        return self.handleHttpStreamingWithIo(http_request, self.options.io);
    }

    fn handleHttpStreamingWithIo(self: *ZAPI, http_request: *std.http.Server.Request, io: ?std.Io) !void {
        const target = try self.allocator.dupe(u8, http_request.head.target);
        defer self.allocator.free(target);
        const request_method = try methodFromHttp(http_request.head.method);

        var headers: std.ArrayList(HeaderField) = .empty;
        defer {
            for (headers.items) |item| {
                self.allocator.free(item.name);
                self.allocator.free(item.value);
            }
            headers.deinit(self.allocator);
        }

        var header_it = http_request.iterateHeaders();
        while (header_it.next()) |item| {
            try headers.append(self.allocator, .{
                .name = try self.allocator.dupe(u8, item.name),
                .value = try self.allocator.dupe(u8, item.value),
            });
        }

        var request = Request.init(request_method, target);
        request.headers = headers.items;
        request.inherited_io = io;

        if (try self.handleWebSocketHttp(http_request, request)) return;

        if (http_request.head.content_length) |len| {
            const body_len = std.math.cast(usize, len) orelse return self.respondRequestBodyTooLarge(http_request, request);
            if (self.options.max_request_body_size) |max_size| {
                if (body_len > max_size) return self.respondRequestBodyTooLarge(http_request, request);
            }
        }

        var body_buffer: [8192]u8 = undefined;
        const body_reader = http_request.readerExpectNone(&body_buffer);
        var request_body_reader = RequestBodyReader{
            .reader = body_reader,
            .max_size = self.options.max_request_body_size,
        };
        request.body_reader = &request_body_reader;

        var response = try self.handleWithoutBackgroundTasks(request);
        errdefer response.deinit(self.allocator);

        request_body_reader.discardRemaining() catch |err| switch (err) {
            error.RequestBodyTooLarge => {
                response.deinit(self.allocator);
                return self.respondRequestBodyTooLarge(http_request, request);
            },
            else => return err,
        };

        defer response.deinit(self.allocator);
        try self.finalizeResponseForTransport(&response);
        try self.respondHttp(http_request, response);
        try response.runBackgroundTasks();
    }

    fn readHttpRequestBody(self: *ZAPI, http_request: *std.http.Server.Request) ![]u8 {
        if (!http_request.head.method.requestHasBody()) return self.allocator.dupe(u8, "");

        var body_buffer: [8192]u8 = undefined;
        var body_reader = http_request.readerExpectNone(&body_buffer);
        if (http_request.head.content_length) |len| {
            const body_len = std.math.cast(usize, len) orelse return error.RequestBodyTooLarge;
            if (self.options.max_request_body_size) |max_size| {
                if (body_len > max_size) return error.RequestBodyTooLarge;
            }
            return body_reader.readAlloc(self.allocator, body_len);
        }

        if (http_request.head.transfer_encoding == .none) return self.allocator.dupe(u8, "");

        var body: std.ArrayList(u8) = .empty;
        errdefer body.deinit(self.allocator);

        var chunk: [8192]u8 = undefined;
        while (true) {
            const n = try body_reader.readSliceShort(&chunk);
            if (n == 0) break;
            if (self.options.max_request_body_size) |max_size| {
                if (n > max_size or body.items.len > max_size - n) return error.RequestBodyTooLarge;
            }
            try body.appendSlice(self.allocator, chunk[0..n]);
        }

        return body.toOwnedSlice(self.allocator);
    }

    fn respondRequestBodyTooLarge(self: *ZAPI, http_request: *std.http.Server.Request, request: Request) !void {
        var response = try self.problemForRequest(request, .payload_too_large, "Request body too large");
        defer response.deinit(self.allocator);
        try self.finalizeResponseForTransport(&response);
        try self.respondHttp(http_request, response);
    }

    fn handleWebSocketHttp(self: *ZAPI, http_request: *std.http.Server.Request, request: Request) !bool {
        if (request.header("host")) |host_header| {
            if (requestHostName(host_header)) |host_name| {
                for (self.hosts.items) |host_app| {
                    var host_params = std.ArrayList(HeaderField).empty;
                    defer host_params.deinit(self.allocator);
                    if (!try matchHost(self.allocator, host_app.pattern, host_name, &host_params, self.path_convertors.items)) continue;
                    var hosted_request = request;
                    hosted_request.host_params = host_params.items;
                    if (try host_app.app.handleWebSocketHttp(http_request, hosted_request)) return true;
                }
            }
        }

        for (self.mounts.items) |mounted_app| {
            var mount_params = std.ArrayList(HeaderField).empty;
            defer mount_params.deinit(self.allocator);
            if (try matchMount(self.allocator, mounted_app.prefix, request.path, &mount_params, self.path_convertors.items)) |mount_match| {
                const mounted_root_path = try mountRootPath(self.allocator, request.root_path, mount_match.root_prefix);
                defer if (mounted_root_path.owned) self.allocator.free(mounted_root_path.value);
                var carried_params = std.ArrayList(HeaderField).empty;
                defer carried_params.deinit(self.allocator);
                try carried_params.appendSlice(self.allocator, request.host_params);
                try carried_params.appendSlice(self.allocator, mount_params.items);
                var mounted_request = request;
                mounted_request.path = mount_match.path;
                mounted_request.root_path = mounted_root_path.value;
                mounted_request.host_params = carried_params.items;
                if (try mounted_app.app.handleWebSocketHttp(http_request, mounted_request)) return true;
            }
        }

        const route_matches = self.websocket_route_tree.matches(request.path, self.path_convertors.items);
        const route_index = route_matches.first_any orelse return false;
        const route_item = &self.websocket_routes.items[route_index];
        var params = std.StringHashMap([]const u8).init(self.allocator);
        defer params.deinit();
        for (request.host_params) |param| try params.put(param.name, param.value);
        if (!(try matchPath(route_item.path, request.path, &params, self.path_convertors.items))) {
            return error.InvalidRouteIndex;
        }
        return try self.acceptWebSocketRoute(http_request, request, route_item, &params);
    }

    fn acceptWebSocketRoute(self: *ZAPI, http_request: *std.http.Server.Request, request: Request, route_item: *const RegisteredWebSocketRoute, params: *std.StringHashMap([]const u8)) !bool {
        const upgrade = http_request.upgradeRequested();
        const key = switch (upgrade) {
            .websocket => |value| value orelse return self.respondWebSocketBadRequest(http_request),
            else => return self.respondWebSocketUpgradeRequired(http_request),
        };

        const request_path_params = try requestPathParamFields(self.allocator, request.host_params, route_item.path, params);
        defer self.allocator.free(request_path_params);

        var scoped_request = request;
        scoped_request.path_params = request_path_params;

        var websocket_connection = try http_request.respondWebSocket(.{ .key = key });
        var ctx = WebSocketContext{
            .app = self,
            .allocator = self.allocator,
            .request = scoped_request,
            .path_params = params.*,
            .websocket = &websocket_connection,
            .state_ptr = self.state_ptr,
        };
        try route_item.handler(&ctx);
        try websocket_connection.flush();
        return true;
    }

    fn respondWebSocketUpgradeRequired(self: *ZAPI, http_request: *std.http.Server.Request) !bool {
        try http_request.respond("WebSocket upgrade required", .{
            .status = .upgrade_required,
            .extra_headers = &.{
                .{ .name = "connection", .value = "upgrade" },
                .{ .name = "upgrade", .value = "websocket" },
            },
        });
        _ = self;
        return true;
    }

    fn respondWebSocketBadRequest(self: *ZAPI, http_request: *std.http.Server.Request) !bool {
        try http_request.respond("Missing Sec-WebSocket-Key", .{
            .status = .bad_request,
        });
        _ = self;
        return true;
    }

    fn respondHttp(self: *ZAPI, http_request: *std.http.Server.Request, response: Response) !void {
        const status_code = response.status.code();
        if (status_code < 100 or response.status == .continue_ or status_code > 999) return error.InvalidResponseStatus;

        var header_count: usize = 0;
        for (response.headers.items) |item| {
            try validateHeader(item.name, item.value);
            if (!isTransportFramingHeader(item.name)) header_count += 1;
        }

        const extra_headers = try self.allocator.alloc(std.http.Header, header_count);
        defer self.allocator.free(extra_headers);
        var header_index: usize = 0;
        for (response.headers.items) |item| {
            if (isTransportFramingHeader(item.name)) continue;
            extra_headers[header_index] = .{
                .name = item.name,
                .value = item.value,
            };
            header_index += 1;
        }

        if (response.stream) |stream| {
            var buffer: [8192]u8 = undefined;
            var body_writer = try http_request.respondStreaming(&buffer, .{
                .respond_options = .{
                    .status = statusToHttp(response.status),
                    .extra_headers = extra_headers,
                },
            });
            try stream.write(stream.context, &body_writer.writer);
            try body_writer.end();
            return;
        }

        try http_request.respond(response.body.items, .{
            .status = statusToHttp(response.status),
            .extra_headers = extra_headers,
        });
    }

    fn finalizeResponse(self: *ZAPI, response: *Response) !void {
        if (!contentLengthAllowed(response.status)) {
            response.removeHeader(self.allocator, "content-length");
            return;
        }
        if (response.stream != null) {
            response.removeHeader(self.allocator, "content-length");
            return;
        }
        if (response.header("content-length") != null) return;

        const content_length = try std.fmt.allocPrint(self.allocator, "{d}", .{response.body.items.len});
        defer self.allocator.free(content_length);
        try response.setHeader(self.allocator, "content-length", content_length);
    }

    fn finalizeResponseForRequest(self: *ZAPI, request: Request, response: *Response) !void {
        try self.finalizeResponseForTransport(response);
        if (request.method == .HEAD) {
            response.body.clearRetainingCapacity();
            response.stream = null;
        }
    }

    fn finalizeResponseForTransport(self: *ZAPI, response: *Response) !void {
        try self.finalizeResponse(response);
        if (!responseBodyAllowed(response.status)) {
            response.body.clearRetainingCapacity();
            response.stream = null;
        }
    }

    pub fn serve(self: *ZAPI, io: std.Io, address: std.Io.net.IpAddress, options: ServeOptions) !void {
        try self.startup();
        defer self.shutdown() catch {};

        var listener = try address.listen(io, options.listen);
        defer listener.deinit(io);
        try self.serveListener(io, &listener, .{
            .max_connections = options.max_connections,
            .concurrent_connections = options.concurrent_connections,
            .max_concurrent_connections = options.max_concurrent_connections,
            .shutdown_signal = options.shutdown_signal,
            .buffer_request_body = options.buffer_request_body,
        });
    }

    pub fn serveListener(self: *ZAPI, io: std.Io, listener: *std.Io.net.Server, options: ServeListenerOptions) !void {
        if (options.concurrent_connections and options.max_concurrent_connections == 0) {
            return error.InvalidConcurrencyLimit;
        }

        var handled_connections: usize = 0;
        var group: std.Io.Group = .init;
        defer group.cancel(io);
        var connection_permits = std.Io.Semaphore{ .permits = options.max_concurrent_connections };

        while (!serveShouldStop(options) and (options.max_connections == null or handled_connections < options.max_connections.?)) {
            if (options.concurrent_connections) try connection_permits.wait(io);
            var stream = listener.accept(io) catch |err| {
                if (options.concurrent_connections) connection_permits.post(io);
                return err;
            };
            if (options.concurrent_connections) {
                group.concurrent(io, handleStreamAndClose, .{
                    self,
                    io,
                    stream,
                    options.buffer_request_body,
                    &connection_permits,
                }) catch |err| {
                    connection_permits.post(io);
                    stream.close(io);
                    return err;
                };
            } else {
                errdefer stream.close(io);
                try self.handleStream(io, stream, options.buffer_request_body);
                stream.close(io);
            }
            handled_connections += 1;
        }

        if (options.concurrent_connections) try group.await(io);
    }

    fn serveShouldStop(options: ServeListenerOptions) bool {
        if (options.shutdown_signal) |signal| return signal.isRequested();
        return false;
    }

    fn handleStream(self: *ZAPI, io: std.Io, stream: std.Io.net.Stream, buffer_request_body: bool) !void {
        var read_buffer: [8192]u8 = undefined;
        var write_buffer: [8192]u8 = undefined;
        var connection_reader = stream.reader(io, &read_buffer);
        var connection_writer = stream.writer(io, &write_buffer);
        var server = std.http.Server.init(&connection_reader.interface, &connection_writer.interface);

        while (true) {
            var request = server.receiveHead() catch |err| switch (err) {
                error.HttpConnectionClosing => return,
                else => return err,
            };
            if (buffer_request_body) {
                try self.handleHttpWithIo(&request, io);
            } else {
                try self.handleHttpStreamingWithIo(&request, io);
            }
        }
    }

    fn handleStreamAndClose(
        self: *ZAPI,
        io: std.Io,
        stream: std.Io.net.Stream,
        buffer_request_body: bool,
        connection_permits: *std.Io.Semaphore,
    ) std.Io.Cancelable!void {
        defer connection_permits.post(io);
        defer stream.close(io);
        self.handleStream(io, stream, buffer_request_body) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => return,
        };
    }

    fn problem(self: *ZAPI, status: Status, detail: []const u8) !Response {
        return self.problemForRequest(Request.init(.GET, "/"), status, detail);
    }

    fn problemForRequest(self: *ZAPI, request: Request, status: Status, detail: []const u8) !Response {
        if (try self.handleStatus(request, status, detail)) |response| return response;
        return self.defaultProblem(status, detail);
    }

    fn handleStatus(self: *ZAPI, request: Request, status: Status, detail: []const u8) !?Response {
        for (self.status_handlers.items) |item| {
            if (item.status != status) continue;
            var ctx = StatusHandlerContext{
                .app = self,
                .request = request,
                .status = status,
                .detail = detail,
            };
            return try item.handle(&ctx);
        }
        return null;
    }

    fn defaultProblem(self: *ZAPI, status: Status, detail: []const u8) !Response {
        var response = Response.init(status);
        var payload = try problemPayload(self.allocator, status, detail);
        defer payload.deinit(self.allocator);
        try response.setHeader(self.allocator, "content-type", payload.content_type);
        try response.body.appendSlice(self.allocator, payload.body);
        return response;
    }

    fn unauthorized(self: *ZAPI, www_authenticate: ?[]const u8) !Response {
        return self.unauthorizedForRequest(Request.init(.GET, "/"), www_authenticate);
    }

    fn unauthorizedForRequest(self: *ZAPI, request: Request, www_authenticate: ?[]const u8) !Response {
        var response = try self.problemForRequest(request, .unauthorized, "Unauthorized");
        if (www_authenticate) |value| try response.setHeader(self.allocator, "www-authenticate", value);
        return response;
    }

    fn methodNotAllowed(self: *ZAPI, request: Request, allowed_methods: []const Method) !Response {
        var response = try self.problemForRequest(request, .method_not_allowed, "Method not allowed");
        try self.setAllowHeader(&response, allowed_methods);
        return response;
    }

    fn automaticOptions(self: *ZAPI, request: Request, allowed_methods: []const Method) !Response {
        _ = request;
        var response = Response.init(.ok);
        try self.setAllowHeader(&response, allowed_methods);
        return response;
    }

    fn setAllowHeader(self: *ZAPI, response: *Response, allowed_methods: []const Method) !void {
        var allow = std.Io.Writer.Allocating.init(self.allocator);
        defer allow.deinit();

        for (allowed_methods, 0..) |method, i| {
            if (i != 0) try allow.writer.writeAll(", ");
            try allow.writer.writeAll(method.text());
        }

        try response.setHeader(self.allocator, "allow", allow.written());
    }

    fn redirectSlash(self: *ZAPI, request: Request) !?Response {
        const alternate_path = if (std.mem.eql(u8, request.path, "/"))
            return null
        else if (std.mem.endsWith(u8, request.path, "/"))
            std.mem.trimEnd(u8, request.path, "/")
        else
            try std.fmt.allocPrint(self.allocator, "{s}/", .{request.path});
        defer if (!std.mem.endsWith(u8, request.path, "/")) self.allocator.free(alternate_path);

        if (self.route_tree.matches(alternate_path, self.path_convertors.items).first_any == null) return null;

        var location = std.Io.Writer.Allocating.init(self.allocator);
        defer location.deinit();
        if (request.root_path.len > 0) {
            const mounted_location = try joinPaths(self.allocator, request.root_path, alternate_path);
            defer self.allocator.free(mounted_location);
            try location.writer.writeAll(mounted_location);
        } else {
            try location.writer.writeAll(alternate_path);
        }
        if (request.query.len > 0) {
            try location.writer.writeAll("?");
            try location.writer.writeAll(request.query);
        }

        return try self.redirect(location.written(), .temporary_redirect);
    }

    fn redirect(self: *ZAPI, location: []const u8, status: Status) !Response {
        var response = Response.init(status);
        const quoted = try quoteRedirectLocation(self.allocator, location);
        defer self.allocator.free(quoted);
        try response.setHeader(self.allocator, "location", quoted);
        return response;
    }

    pub fn openapiJson(self: *ZAPI) ![]u8 {
        var out = std.Io.Writer.Allocating.init(self.allocator);
        errdefer out.deinit();
        try writeOpenApi(self.allocator, &out.writer, self, "");
        return out.toOwnedSlice();
    }
};

fn makeRoute(comptime method: Method, comptime path: []const u8, comptime handler: anytype, comptime options: anytype) RouteSpec {
    const Handler = @TypeOf(handler);
    const info = @typeInfo(Handler);
    if (info != .@"fn") @compileError("route handler must be a function");

    const fn_info = info.@"fn";
    const metadata = comptime routeMetadata(method, path, Handler, options);

    return .{
        .method = method,
        .path = path,
        .handler_ptr = @ptrCast(&handler),
        .handler_type_name = @typeName(Handler),
        .dispatch = struct {
            fn dispatch(ctx: *Context) anyerror!ResponsePayload {
                return callAndEncode(handler, fn_info.params, ctx);
            }
        }.dispatch,
        .middlewares = if (@hasField(@TypeOf(options), "middlewares")) options.middlewares else &.{},
        .metadata = metadata,
    };
}

fn callAndEncode(comptime handler: anytype, comptime params: []const std.builtin.Type.Fn.Param, ctx: *Context) !ResponsePayload {
    switch (params.len) {
        0 => {
            const value = try handler();
            return encodePayload(ctx, value);
        },
        1 => {
            var a0 = try buildArg(params[0].type.?, ctx);
            defer deinitArg(&a0);
            const value = try handler(a0);
            return encodePayload(ctx, value);
        },
        2 => {
            var a0 = try buildArg(params[0].type.?, ctx);
            defer deinitArg(&a0);
            var a1 = try buildArg(params[1].type.?, ctx);
            defer deinitArg(&a1);
            const value = try handler(a0, a1);
            return encodePayload(ctx, value);
        },
        3 => {
            var a0 = try buildArg(params[0].type.?, ctx);
            defer deinitArg(&a0);
            var a1 = try buildArg(params[1].type.?, ctx);
            defer deinitArg(&a1);
            var a2 = try buildArg(params[2].type.?, ctx);
            defer deinitArg(&a2);
            const value = try handler(a0, a1, a2);
            return encodePayload(ctx, value);
        },
        4 => {
            var a0 = try buildArg(params[0].type.?, ctx);
            defer deinitArg(&a0);
            var a1 = try buildArg(params[1].type.?, ctx);
            defer deinitArg(&a1);
            var a2 = try buildArg(params[2].type.?, ctx);
            defer deinitArg(&a2);
            var a3 = try buildArg(params[3].type.?, ctx);
            defer deinitArg(&a3);
            const value = try handler(a0, a1, a2, a3);
            return encodePayload(ctx, value);
        },
        else => @compileError("route handlers currently support up to 4 parameters"),
    }
}

fn buildArg(comptime T: type, ctx: *Context) !T {
    if (comptime T == *Context) return ctx;
    if (comptime T == Request) return ctx.request;
    if (comptime T == BearerAuth) return try parseBearerAuth(ctx.request);
    if (comptime isOAuth2PasswordBearer(T)) return try parseOAuth2PasswordBearer(T, ctx.request);
    if (comptime isOAuth2AuthorizationCodeBearer(T)) return try parseOAuth2AuthorizationCodeBearer(T, ctx.request);
    if (comptime isOAuth2ClientCredentialsBearer(T)) return try parseOAuth2ClientCredentialsBearer(T, ctx.request);
    if (comptime isOAuth2ImplicitBearer(T)) return try parseOAuth2ImplicitBearer(T, ctx.request);
    if (comptime T == BasicAuth) return try parseBasicAuth(ctx.allocator, ctx.request);
    if (comptime isApiKeyAuth(T)) return try parseApiKeyAuth(T, ctx.allocator, ctx.request);

    if (comptime isWrapper(T, .body)) {
        const Inner = wrapperInner(T);
        return try parseBody(Inner, ctx.allocator, ctx.request);
    }

    if (comptime isWrapper(T, .form)) {
        const Inner = wrapperInner(T);
        return try parseFormArg(Inner, ctx.allocator, ctx.request);
    }

    if (comptime isWrapper(T, .path)) {
        const Inner = wrapperInner(T);
        return try parsePathArg(Inner, ctx.allocator, ctx.path_params);
    }

    if (comptime isWrapper(T, .query)) {
        const Inner = wrapperInner(T);
        return try parseQueryArg(Inner, ctx.allocator, ctx.request.query, ctx.route_metadata.query_params);
    }

    if (comptime isWrapper(T, .header)) {
        const Inner = wrapperInner(T);
        return try parseHeaderArg(Inner, ctx.allocator, ctx.request, ctx.route_metadata.header_params);
    }

    if (comptime isWrapper(T, .cookie)) {
        const Inner = wrapperInner(T);
        return try parseCookieArg(Inner, ctx.allocator, ctx.request, ctx.route_metadata.cookie_params);
    }

    @compileError("unsupported handler parameter type: " ++ @typeName(T));
}

fn deinitArg(arg: anytype) void {
    const T = @TypeOf(arg.*);
    if (comptime isWrapper(T, .body) or isWrapper(T, .form) or isWrapper(T, .path) or isWrapper(T, .query) or isWrapper(T, .header) or isWrapper(T, .cookie)) {
        arg.deinit();
    }
    if (comptime isApiKeyAuth(T)) {
        arg.deinit();
    }
    if (comptime T == BasicAuth) {
        arg.deinit();
    }
}

fn isWrapper(comptime T: type, comptime kind: WrapperKind) bool {
    const ti = @typeInfo(T);
    if (ti != .@"struct") return false;
    if (!@hasDecl(T, "zapi_wrapper")) return false;
    return T.zapi_wrapper == kind;
}

fn wrapperInner(comptime T: type) type {
    return T.zapi_inner;
}

fn isApiKeyAuth(comptime T: type) bool {
    const ti = @typeInfo(T);
    if (ti != .@"struct") return false;
    return @hasDecl(T, "zapi_api_key_location") and @hasDecl(T, "zapi_api_key_name");
}

fn isOAuth2PasswordBearer(comptime T: type) bool {
    const ti = @typeInfo(T);
    if (ti != .@"struct") return false;
    return @hasDecl(T, "zapi_oauth2_password_bearer") and @hasDecl(T, "zapi_scheme_name") and @hasDecl(T, "zapi_token_url") and @hasDecl(T, "zapi_scopes");
}

fn isOAuth2AuthorizationCodeBearer(comptime T: type) bool {
    const ti = @typeInfo(T);
    if (ti != .@"struct") return false;
    return @hasDecl(T, "zapi_oauth2_authorization_code_bearer") and @hasDecl(T, "zapi_scheme_name") and @hasDecl(T, "zapi_authorization_url") and @hasDecl(T, "zapi_token_url") and @hasDecl(T, "zapi_scopes");
}

fn isOAuth2ClientCredentialsBearer(comptime T: type) bool {
    const ti = @typeInfo(T);
    if (ti != .@"struct") return false;
    return @hasDecl(T, "zapi_oauth2_client_credentials_bearer") and @hasDecl(T, "zapi_scheme_name") and @hasDecl(T, "zapi_token_url") and @hasDecl(T, "zapi_scopes");
}

fn isOAuth2ImplicitBearer(comptime T: type) bool {
    const ti = @typeInfo(T);
    if (ti != .@"struct") return false;
    return @hasDecl(T, "zapi_oauth2_implicit_bearer") and @hasDecl(T, "zapi_scheme_name") and @hasDecl(T, "zapi_authorization_url") and @hasDecl(T, "zapi_scopes");
}

fn isJsonResponse(comptime T: type) bool {
    const ti = @typeInfo(T);
    if (ti != .@"struct") return false;
    return @hasDecl(T, "zapi_json_response") and @hasDecl(T, "zapi_inner");
}

fn encodePayload(ctx: *Context, value: anytype) !ResponsePayload {
    const allocator = ctx.allocator;
    const T = @TypeOf(value);
    if (T == ResponsePayload) return value;

    if (T == Empty or T == void) {
        return .{ .content_type = "text/plain", .body = "" };
    }

    if (T == Text) {
        return .{
            .status = value.status,
            .content_type = "text/plain; charset=utf-8",
            .headers = value.headers,
            .body = value.text,
        };
    }

    if (T == Html) {
        return .{
            .status = value.status,
            .content_type = "text/html; charset=utf-8",
            .headers = value.headers,
            .body = value.html,
        };
    }

    if (T == Template) {
        return try encodeTemplatePayload(ctx, value);
    }

    if (T == EventStream) {
        return try encodeEventStreamPayload(ctx, value);
    }

    if (T == StreamingResponse) {
        return .{
            .status = value.status,
            .content_type = value.content_type,
            .headers = value.headers,
            .stream = .{
                .context = value.context,
                .write = value.write,
            },
        };
    }

    if (T == Bytes) {
        return .{
            .status = value.status,
            .content_type = value.content_type,
            .headers = value.headers,
            .body = value.bytes,
        };
    }

    if (T == RawJson) {
        return .{
            .status = value.status,
            .content_type = "application/json",
            .headers = value.headers,
            .body = value.json,
        };
    }

    if (T == File) {
        return try encodeFilePayload(ctx, value);
    }

    if (T == Redirect) {
        const headers = try allocator.alloc(HeaderField, 1);
        errdefer allocator.free(headers);
        headers[0] = try ownedRedirectLocationHeader(allocator, value.location);
        return .{
            .status = value.status,
            .content_type = "",
            .headers = headers,
            .owned_headers = true,
            .body = "",
        };
    }

    if (comptime isJsonResponse(T)) {
        var body = std.Io.Writer.Allocating.init(allocator);
        errdefer body.deinit();
        try std.json.Stringify.value(value.value, .{}, &body.writer);
        return .{
            .status = value.status,
            .content_type = "application/json",
            .headers = value.headers,
            .body = try body.toOwnedSlice(),
            .owned_body = true,
        };
    }

    var body = std.Io.Writer.Allocating.init(allocator);
    errdefer body.deinit();
    try std.json.Stringify.value(value, .{}, &body.writer);
    return .{
        .content_type = "application/json",
        .body = try body.toOwnedSlice(),
        .owned_body = true,
    };
}

fn encodeEventStreamPayload(ctx: *Context, stream: EventStream) !ResponsePayload {
    var body = std.Io.Writer.Allocating.init(ctx.allocator);
    errdefer body.deinit();
    for (stream.events) |event| {
        try sse.writeEvent(&body.writer, event);
    }

    return .{
        .status = stream.status,
        .content_type = "text/event-stream",
        .headers = stream.headers,
        .body = try body.toOwnedSlice(),
        .owned_body = true,
    };
}

fn encodeTemplatePayload(ctx: *Context, template_response: Template) !ResponsePayload {
    const io = ctx.io orelse return error.MissingIo;
    const source = try template_response.dir.readFileAlloc(io, template_response.path, ctx.allocator, template_response.max_size);
    defer ctx.allocator.free(source);

    var body = std.Io.Writer.Allocating.init(ctx.allocator);
    errdefer body.deinit();
    try template_mod.render(&body.writer, source, template_response.context);

    return .{
        .status = template_response.status,
        .content_type = template_response.content_type,
        .headers = template_response.headers,
        .body = try body.toOwnedSlice(),
        .owned_body = true,
    };
}

fn problemPayload(allocator: std.mem.Allocator, status: Status, detail: []const u8) !ResponsePayload {
    var body = std.Io.Writer.Allocating.init(allocator);
    errdefer body.deinit();
    try std.json.Stringify.value(ProblemDetail{ .detail = detail }, .{}, &body.writer);
    return .{
        .status = status,
        .content_type = "application/json",
        .body = try body.toOwnedSlice(),
        .owned_body = true,
    };
}

fn encodeFilePayload(ctx: *Context, file_response: File) !ResponsePayload {
    const io = ctx.io orelse return error.MissingIo;
    const stat = try file_response.dir.statFile(io, file_response.path, .{});
    if (stat.kind != .file) return error.IsDir;
    const full_len = try statFileSize(stat);
    const last_modified_seconds = timestampSeconds(stat.mtime);
    const last_modified = try httpDateAlloc(ctx.allocator, last_modified_seconds);
    defer ctx.allocator.free(last_modified);

    const generated_etag = try fileResponseEtag(ctx.allocator, stat);
    defer ctx.allocator.free(generated_etag);
    const etag = headerValue(file_response.headers, "etag") orelse generated_etag;
    const effective_last_modified = headerValue(file_response.headers, "last-modified") orelse last_modified;
    const effective_last_modified_seconds = if (headerValue(file_response.headers, "last-modified")) |value|
        parseHttpDate(value) orelse last_modified_seconds
    else
        last_modified_seconds;

    const not_modified = requestNotModified(ctx.request, etag, effective_last_modified_seconds);
    var range_decision = if (not_modified) ByteRangeDecision.none else try requestByteRange(ctx.allocator, ctx.request, etag, effective_last_modified_seconds, full_len);
    defer range_decision.deinit(ctx.allocator);
    switch (range_decision) {
        .malformed => |message| return .{
            .status = .bad_request,
            .content_type = "text/plain; charset=utf-8",
            .body = message,
        },
        else => {},
    }
    const status = if (not_modified) .not_modified else switch (range_decision) {
        .none => file_response.status,
        .partial => .partial_content,
        .multiple => .partial_content,
        .unsatisfiable => .requested_range_not_satisfiable,
        .malformed => unreachable,
    };

    const file_content_type = fileResponseContentType(file_response);
    const response_content_type = responseFileContentType(file_content_type, range_decision);
    var body: []const u8 = "";
    var owned_body = false;
    const body_len = switch (range_decision) {
        .none => if (not_modified or ctx.request.method == .HEAD) full_len else full_len,
        .partial => |range| range.len(),
        .multiple => |ranges| multipartByteRangesLength(ranges, multipart_range_boundary, file_content_type, full_len),
        .unsatisfiable => 0,
        .malformed => unreachable,
    };

    if (!not_modified and ctx.request.method != .HEAD and range_decision != .unsatisfiable) {
        var file_body = try file_response.dir.readFileAlloc(io, file_response.path, ctx.allocator, file_response.max_size);
        errdefer ctx.allocator.free(file_body);
        switch (range_decision) {
            .multiple => |ranges| {
                const multipart_body = try multipartByteRangesBodyAlloc(ctx.allocator, file_body, ranges, multipart_range_boundary, file_content_type, full_len);
                ctx.allocator.free(file_body);
                body = multipart_body;
                owned_body = true;
            },
            else => {
                file_body = try applyByteRange(ctx.allocator, file_body, range_decision);
                body = file_body;
                owned_body = true;
            },
        }
    }

    const headers = try responseFileHeaders(ctx.allocator, file_response.headers, body_len, full_len, etag, effective_last_modified, file_response.filename, file_response.content_disposition, status orelse .ok, range_decision);
    errdefer freeOwnedHeaders(ctx.allocator, headers);

    return .{
        .status = status,
        .content_type = response_content_type,
        .headers = headers,
        .owned_headers = true,
        .background_tasks = file_response.background_tasks,
        .owned_background_tasks = file_response.owned_background_tasks,
        .body = body,
        .owned_body = owned_body,
    };
}

fn fileResponseContentType(file_response: File) []const u8 {
    if (file_response.content_type) |content_type| return content_type;
    if (file_response.filename) |filename| return staticContentType(filename);
    return staticContentType(file_response.path);
}

const StaticPath = static_files_mod.StaticPath;
const ByteRange = static_files_mod.ByteRange;
const ByteRangeDecision = static_files_mod.ByteRangeDecision;
const multipart_range_boundary = static_files_mod.multipart_range_boundary;
const responseFileContentType = static_files_mod.responseFileContentType;
const multipartByteRangesContentType = static_files_mod.multipartByteRangesContentType;
const responseFileHeaders = static_files_mod.responseFileHeaders;
const fileContentDispositionAlloc = static_files_mod.fileContentDispositionAlloc;
const quotedFilenameSafe = static_files_mod.quotedFilenameSafe;
const percentEncodeFilenameAlloc = static_files_mod.percentEncodeFilenameAlloc;
const filenameAttrChar = static_files_mod.filenameAttrChar;
const statFileSize = static_files_mod.statFileSize;
const fileResponseEtag = static_files_mod.fileResponseEtag;
const requestEtagMatches = static_files_mod.requestEtagMatches;
const etagWeakEquals = static_files_mod.etagWeakEquals;
const weakEtagValue = static_files_mod.weakEtagValue;
const requestNotModified = static_files_mod.requestNotModified;
const requestValidatorsNotModified = static_files_mod.requestValidatorsNotModified;
const requestModifiedSince = static_files_mod.requestModifiedSince;
const requestByteRange = static_files_mod.requestByteRange;
const parseByteRange = static_files_mod.parseByteRange;
const parseByteRangePart = static_files_mod.parseByteRangePart;
const byteRangeLessThan = static_files_mod.byteRangeLessThan;
const normalizeByteRanges = static_files_mod.normalizeByteRanges;
const mergeByteRanges = static_files_mod.mergeByteRanges;
const applyByteRange = static_files_mod.applyByteRange;
const multipartByteRangesLength = static_files_mod.multipartByteRangesLength;
const multipartByteRangesBodyAlloc = static_files_mod.multipartByteRangesBodyAlloc;
const timestampSeconds = static_files_mod.timestampSeconds;
const httpDateAlloc = static_files_mod.httpDateAlloc;
const parseHttpDate = static_files_mod.parseHttpDate;
const parseHttpMonth = static_files_mod.parseHttpMonth;
const httpMonthName = static_files_mod.httpMonthName;
const httpWeekdayName = static_files_mod.httpWeekdayName;
const freeOwnedHeaders = static_files_mod.freeOwnedHeaders;
const staticFileTargetPath = static_files_mod.staticFileTargetPath;
const validateStaticPathSegments = static_files_mod.validateStaticPathSegments;
const staticContentType = static_files_mod.staticContentType;

fn appendAllowedMethod(allocator: std.mem.Allocator, allowed_methods: *std.ArrayList(Method), method: Method) !void {
    if (method == .GET) {
        try appendAllowedMethodOnce(allocator, allowed_methods, .HEAD);
    }
    try appendAllowedMethodOnce(allocator, allowed_methods, method);
}

fn appendAllowedMethodOnce(allocator: std.mem.Allocator, allowed_methods: *std.ArrayList(Method), method: Method) !void {
    for (allowed_methods.items) |existing| {
        if (existing == method) return;
    }
    try allowed_methods.append(allocator, method);
}

fn methodReadsGetResource(method: Method) bool {
    return method == .GET or method == .HEAD;
}

fn methodFromText(method: []const u8) !Method {
    if (std.ascii.eqlIgnoreCase(method, "GET")) return .GET;
    if (std.ascii.eqlIgnoreCase(method, "POST")) return .POST;
    if (std.ascii.eqlIgnoreCase(method, "PUT")) return .PUT;
    if (std.ascii.eqlIgnoreCase(method, "PATCH")) return .PATCH;
    if (std.ascii.eqlIgnoreCase(method, "DELETE")) return .DELETE;
    if (std.ascii.eqlIgnoreCase(method, "OPTIONS")) return .OPTIONS;
    if (std.ascii.eqlIgnoreCase(method, "HEAD")) return .HEAD;
    if (std.ascii.eqlIgnoreCase(method, "TRACE")) return .TRACE;
    if (std.ascii.eqlIgnoreCase(method, "CONNECT")) return .CONNECT;
    return error.UnsupportedHttpMethod;
}

fn methodFromHttp(method: std.http.Method) !Method {
    return switch (method) {
        .GET => .GET,
        .POST => .POST,
        .PUT => .PUT,
        .PATCH => .PATCH,
        .DELETE => .DELETE,
        .OPTIONS => .OPTIONS,
        .HEAD => .HEAD,
        .TRACE => .TRACE,
        .CONNECT => .CONNECT,
    };
}

fn methodOverrideOriginalAllowed(comptime options: MethodOverrideOptions, method: Method) bool {
    inline for (options.allowed_original_methods) |allowed| {
        if (method == allowed) return true;
    }
    return false;
}

fn methodOverrideTargetAllowed(comptime options: MethodOverrideOptions, method: Method) bool {
    inline for (options.allowed_override_methods) |allowed| {
        if (method == allowed) return true;
    }
    return false;
}

fn statusToHttp(status: Status) std.http.Status {
    return @enumFromInt(status.code());
}

fn isTransportFramingHeader(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "content-length") or std.ascii.eqlIgnoreCase(name, "transfer-encoding");
}

fn responseBodyAllowed(status: Status) bool {
    return !status.isInformational() and status != .no_content and status != .not_modified;
}

fn contentLengthAllowed(status: Status) bool {
    return responseBodyAllowed(status);
}

fn cloneResponse(allocator: std.mem.Allocator, source: Response) !Response {
    var response = Response.init(source.status);
    errdefer response.deinit(allocator);

    if (source.url) |url| {
        response.url = try allocator.dupe(u8, url);
    }
    for (source.headers.items) |header| {
        try response.appendHeader(allocator, header.name, header.value);
    }
    for (source.background_tasks.items) |task| {
        try response.addBackgroundTask(allocator, task);
    }
    response.stream = source.stream;
    for (source.history.items) |history_response| {
        var cloned_history_response = try cloneResponse(allocator, history_response);
        errdefer cloned_history_response.deinit(allocator);
        try response.history.append(allocator, cloned_history_response);
    }
    try response.body.appendSlice(allocator, source.body.items);
    return response;
}

fn clientAcceptsGzip(request: Request) bool {
    const header = request.header("accept-encoding") orelse return false;
    var wildcard_allowed = false;
    var it = std.mem.splitScalar(u8, header, ',');
    while (it.next()) |raw_item| {
        const item = std.mem.trim(u8, raw_item, " \t");
        if (item.len == 0) continue;
        const coding_end = std.mem.indexOfScalar(u8, item, ';') orelse item.len;
        const coding = std.mem.trim(u8, item[0..coding_end], " \t");
        const q = acceptEncodingQuality(item[coding_end..]);
        if (std.ascii.eqlIgnoreCase(coding, "gzip")) return q > 0;
        if (std.mem.eql(u8, coding, "*") and q > 0) wildcard_allowed = true;
    }
    return wildcard_allowed;
}

fn acceptEncodingQuality(parameters: []const u8) f32 {
    var it = std.mem.splitScalar(u8, parameters, ';');
    while (it.next()) |raw_param| {
        const param = std.mem.trim(u8, raw_param, " \t");
        if (param.len < 2) continue;
        const eq_idx = std.mem.indexOfScalar(u8, param, '=') orelse continue;
        const name = std.mem.trim(u8, param[0..eq_idx], " \t");
        if (!std.ascii.eqlIgnoreCase(name, "q")) continue;
        const raw_value = std.mem.trim(u8, param[eq_idx + 1 ..], " \t");
        if (raw_value.len == 0) return 0;
        return std.fmt.parseFloat(f32, raw_value) catch 0;
    }
    return 1;
}

fn gzipResponseAllowed(response: Response, minimum_size: usize) bool {
    if (response.status == .no_content or response.status == .not_modified or response.status == .partial_content or response.status == .requested_range_not_satisfiable) return false;
    if (response.stream != null) return false;
    if (response.body.items.len < minimum_size) return false;
    if (response.header("content-encoding") != null) return false;
    if (response.header("content-type")) |content_type| {
        const media_end = std.mem.indexOfScalar(u8, content_type, ';') orelse content_type.len;
        const media_type = std.mem.trim(u8, content_type[0..media_end], " \t");
        if (std.ascii.eqlIgnoreCase(media_type, "text/event-stream")) return false;
    }
    return true;
}

fn gzipCompress(allocator: std.mem.Allocator, body: []const u8) ![]u8 {
    var output = std.Io.Writer.Allocating.init(allocator);
    defer output.deinit();
    try output.writer.rebase(0, 1024);

    const compression_buffer = try allocator.alloc(u8, std.compress.flate.max_window_len);
    defer allocator.free(compression_buffer);

    var compressor = try std.compress.flate.Compress.init(&output.writer, compression_buffer, .gzip, .default);
    try compressor.writer.writeAll(body);
    try compressor.finish();
    return output.toOwnedSlice();
}

fn setHeaderIfMissing(allocator: std.mem.Allocator, response: *Response, name: []const u8, value: []const u8) !void {
    if (response.header(name) != null) return;
    try response.setHeader(allocator, name, value);
}

fn addVaryHeader(allocator: std.mem.Allocator, response: *Response, value: []const u8) !void {
    const existing = response.header("vary") orelse {
        try response.setHeader(allocator, "vary", value);
        return;
    };

    if (std.mem.eql(u8, std.mem.trim(u8, existing, " \t"), "*")) return;

    var it = std.mem.splitScalar(u8, existing, ',');
    while (it.next()) |raw_item| {
        const item = std.mem.trim(u8, raw_item, " \t");
        if (std.ascii.eqlIgnoreCase(item, value)) return;
    }

    const merged = try std.fmt.allocPrint(allocator, "{s}, {s}", .{ existing, value });
    defer allocator.free(merged);
    try response.setHeader(allocator, "vary", merged);
}

fn isCorsPreflight(request: Request) bool {
    return request.method == .OPTIONS and request.header("access-control-request-method") != null;
}

fn corsAllowOrigin(comptime options: CorsOptions, request: Request, origin: []const u8) ?[]const u8 {
    inline for (options.allow_origins) |allowed| {
        if (std.mem.eql(u8, allowed, "*")) {
            if (options.allow_credentials or request.header("cookie") != null) return origin;
            return "*";
        }
        if (std.mem.eql(u8, allowed, origin)) return origin;
    }
    inline for (options.allow_origin_patterns) |pattern| {
        if (wildcardMatch(pattern, origin)) return origin;
    }
    return null;
}

fn wildcardMatch(pattern: []const u8, value: []const u8) bool {
    var pattern_index: usize = 0;
    var value_index: usize = 0;
    var star_index: ?usize = null;
    var star_value_index: usize = 0;

    while (value_index < value.len) {
        if (pattern_index < pattern.len and pattern[pattern_index] == '*') {
            star_index = pattern_index;
            pattern_index += 1;
            star_value_index = value_index;
        } else if (pattern_index < pattern.len and pattern[pattern_index] == value[value_index]) {
            pattern_index += 1;
            value_index += 1;
        } else if (star_index) |star| {
            pattern_index = star + 1;
            star_value_index += 1;
            value_index = star_value_index;
        } else {
            return false;
        }
    }

    while (pattern_index < pattern.len and pattern[pattern_index] == '*') {
        pattern_index += 1;
    }
    return pattern_index == pattern.len;
}

fn corsMethodAllowed(comptime options: CorsOptions, requested_method: []const u8) bool {
    if (options.allow_all_methods) {
        _ = methodFromText(requested_method) catch return false;
        return true;
    }

    inline for (options.allow_methods) |method| {
        if (std.ascii.eqlIgnoreCase(method.text(), requested_method)) return true;
    }
    return false;
}

fn corsHeadersAllowed(comptime options: CorsOptions, requested_headers: []const u8) bool {
    if (comptime corsAllowsAnyHeader(options)) return true;

    var it = std.mem.splitScalar(u8, requested_headers, ',');
    while (it.next()) |raw_header| {
        const header = std.mem.trim(u8, raw_header, " \t");
        if (header.len == 0) continue;

        if (corsSafelistedHeader(header)) continue;

        var allowed = false;
        inline for (options.allow_headers) |allowed_header| {
            if (std.ascii.eqlIgnoreCase(allowed_header, header)) {
                allowed = true;
                break;
            }
        }
        if (!allowed) return false;
    }
    return true;
}

fn corsAllowsAnyHeader(comptime options: CorsOptions) bool {
    inline for (options.allow_headers) |header| {
        if (std.mem.eql(u8, header, "*")) return true;
    }
    return false;
}

fn corsSafelistedHeader(header: []const u8) bool {
    for (cors_safelisted_headers) |safe_header| {
        if (std.ascii.eqlIgnoreCase(safe_header, header)) return true;
    }
    return false;
}

fn corsPreflightFailure(comptime options: CorsOptions, app: *ZAPI, detail: []const u8, allow_origin: ?[]const u8, requested_headers: ?[]const u8) !Response {
    var response = Response.init(.bad_request);
    try response.setHeader(app.allocator, "content-type", "text/plain; charset=utf-8");
    try response.body.appendSlice(app.allocator, detail);
    try addCorsPreflightHeaders(options, app, &response, allow_origin, requested_headers);
    return response;
}

fn addCorsHeaders(comptime options: CorsOptions, app: *ZAPI, response: *Response, allow_origin: []const u8, preflight: bool, requested_headers: ?[]const u8) !void {
    try response.setHeader(app.allocator, "access-control-allow-origin", allow_origin);
    if (!std.mem.eql(u8, allow_origin, "*")) try addVaryHeader(app.allocator, response, "Origin");
    if (options.allow_credentials) try response.setHeader(app.allocator, "access-control-allow-credentials", "true");

    if (preflight) {
        try addCorsPreflightHeaders(options, app, response, null, requested_headers);
    } else if (options.expose_headers.len > 0) {
        const expose_headers = try joinHeaderValues(app.allocator, options.expose_headers);
        defer app.allocator.free(expose_headers);
        try response.setHeader(app.allocator, "access-control-expose-headers", expose_headers);
    }
}

fn addCorsPreflightHeaders(comptime options: CorsOptions, app: *ZAPI, response: *Response, allow_origin: ?[]const u8, requested_headers: ?[]const u8) !void {
    if (allow_origin) |origin| {
        try response.setHeader(app.allocator, "access-control-allow-origin", origin);
        if (!std.mem.eql(u8, origin, "*")) try addVaryHeader(app.allocator, response, "Origin");
    }
    if (options.allow_credentials) try response.setHeader(app.allocator, "access-control-allow-credentials", "true");

    const allow_methods_header = try corsAllowMethodsHeader(app.allocator, if (options.allow_all_methods) cors_all_methods else options.allow_methods);
    defer app.allocator.free(allow_methods_header);
    try response.setHeader(app.allocator, "access-control-allow-methods", allow_methods_header);

    if (requested_headers) |headers| {
        if (comptime corsAllowsAnyHeader(options)) {
            try response.setHeader(app.allocator, "access-control-allow-headers", headers);
        } else {
            const allowed_headers = try corsAllowHeadersHeader(app.allocator, options.allow_headers);
            defer app.allocator.free(allowed_headers);
            try response.setHeader(app.allocator, "access-control-allow-headers", allowed_headers);
        }
    } else if (!comptime corsAllowsAnyHeader(options)) {
        const allowed_headers = try corsAllowHeadersHeader(app.allocator, options.allow_headers);
        defer app.allocator.free(allowed_headers);
        try response.setHeader(app.allocator, "access-control-allow-headers", allowed_headers);
    }

    if (options.max_age) |max_age| {
        const value = try std.fmt.allocPrint(app.allocator, "{d}", .{max_age});
        defer app.allocator.free(value);
        try response.setHeader(app.allocator, "access-control-max-age", value);
    }
}

fn corsAllowMethodsHeader(allocator: std.mem.Allocator, allowed_methods: []const Method) ![]u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    errdefer out.deinit();

    for (allowed_methods, 0..) |method, i| {
        if (i != 0) try out.writer.writeAll(", ");
        try out.writer.writeAll(method.text());
    }

    return out.toOwnedSlice();
}

fn corsAllowHeadersHeader(allocator: std.mem.Allocator, configured_headers: []const []const u8) ![]u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    errdefer out.deinit();

    var wrote = false;
    for (cors_safelisted_headers) |header| {
        if (wrote) try out.writer.writeAll(", ");
        wrote = true;
        try out.writer.writeAll(header);
    }

    for (configured_headers) |header| {
        if (corsSafelistedHeader(header)) continue;
        if (wrote) try out.writer.writeAll(", ");
        wrote = true;
        try out.writer.writeAll(header);
    }

    return out.toOwnedSlice();
}

fn joinHeaderValues(allocator: std.mem.Allocator, values: []const []const u8) ![]u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    errdefer out.deinit();

    for (values, 0..) |value, i| {
        if (i != 0) try out.writer.writeAll(", ");
        try out.writer.writeAll(value);
    }

    return out.toOwnedSlice();
}

fn forwardedHeaderFirstValue(value: []const u8) ?[]const u8 {
    const comma = std.mem.indexOfScalar(u8, value, ',') orelse value.len;
    const first = std.mem.trim(u8, value[0..comma], " \t");
    return if (first.len == 0) null else first;
}

fn validForwardedScheme(value: []const u8) bool {
    return std.ascii.eqlIgnoreCase(value, "http") or
        std.ascii.eqlIgnoreCase(value, "https") or
        std.ascii.eqlIgnoreCase(value, "ws") or
        std.ascii.eqlIgnoreCase(value, "wss");
}

fn validForwardedPrefix(value: []const u8) bool {
    return value.len > 0 and value[0] == '/' and std.mem.indexOfAny(u8, value, "\r\n") == null;
}

fn normalizeForwardedPrefix(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    const trimmed = std.mem.trimEnd(u8, value, "/");
    if (trimmed.len == 0) return allocator.dupe(u8, "/");
    return allocator.dupe(u8, trimmed);
}

fn requestWithHeader(allocator: std.mem.Allocator, request: Request, name: []const u8, value: []const u8) ![]HeaderField {
    var replaced = false;
    var count = request.headers.len;
    for (request.headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) {
            if (replaced) count -= 1;
            replaced = true;
        }
    }
    if (!replaced) count += 1;

    const headers = try allocator.alloc(HeaderField, count);
    errdefer allocator.free(headers);

    var i: usize = 0;
    var wrote_replacement = false;
    for (request.headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) {
            if (!wrote_replacement) {
                headers[i] = .{ .name = name, .value = value };
                i += 1;
                wrote_replacement = true;
            }
            continue;
        }
        headers[i] = header;
        i += 1;
    }
    if (!wrote_replacement) headers[i] = .{ .name = name, .value = value };

    return headers;
}

fn trustedHostName(host_header: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, host_header, " \t");
    if (std.mem.startsWith(u8, trimmed, "[")) {
        const end = std.mem.indexOfScalar(u8, trimmed, ']') orelse return trimmed;
        return trimmed[0 .. end + 1];
    }
    if (std.mem.indexOfScalar(u8, trimmed, ':')) |colon| return trimmed[0..colon];
    return trimmed;
}

fn trustedHostAllowed(comptime options: TrustedHostOptions, host: []const u8) bool {
    inline for (options.allowed_hosts) |pattern| {
        if (trustedHostMatches(pattern, host)) return true;
    }
    return false;
}

fn trustedHostMatches(pattern: []const u8, host: []const u8) bool {
    if (std.mem.eql(u8, pattern, "*")) return true;
    if (std.ascii.eqlIgnoreCase(pattern, host)) return true;

    if (std.mem.startsWith(u8, pattern, "*.")) {
        const suffix = pattern[1..];
        if (!std.ascii.endsWithIgnoreCase(host, suffix)) return false;
        return host.len > suffix.len;
    }

    return false;
}

fn trustedHostRedirect(app: *ZAPI, request: Request, host_header: []const u8, redirect_host: []const u8) !Response {
    var location = std.Io.Writer.Allocating.init(app.allocator);
    defer location.deinit();
    try location.writer.writeAll(request.scheme);
    try location.writer.writeAll("://");
    try location.writer.writeAll(redirect_host);
    try location.writer.writeAll(trustedHostPortSuffix(host_header));
    try location.writer.writeAll(request.path);
    if (request.query.len > 0) {
        try location.writer.writeAll("?");
        try location.writer.writeAll(request.query);
    }

    var response = Response.init(.permanent_redirect);
    try response.setHeader(app.allocator, "location", location.written());
    return response;
}

fn trustedHostPortSuffix(host_header: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, host_header, " \t");
    if (std.mem.startsWith(u8, trimmed, "[")) {
        const end = std.mem.indexOfScalar(u8, trimmed, ']') orelse return "";
        return trimmed[end + 1 ..];
    }
    if (std.mem.indexOfScalar(u8, trimmed, ':')) |colon| return trimmed[colon..];
    return "";
}

fn trustedHostFailure(app: *ZAPI) !Response {
    var response = Response.init(.bad_request);
    try response.setHeader(app.allocator, "content-type", "text/plain; charset=utf-8");
    try response.body.appendSlice(app.allocator, "Invalid host header");
    return response;
}

fn routeMetadata(comptime method: Method, comptime path: []const u8, comptime Handler: type, comptime options: anytype) RouteMetadata {
    const fn_info = @typeInfo(Handler).@"fn";
    const parameter_docs = comptime routeParameterDocs(options);
    const status: Status = if (@hasField(@TypeOf(options), "status")) options.status else .ok;
    const response_body_allowed = responseBodyAllowed(status);
    return .{
        .name = if (@hasField(@TypeOf(options), "name")) options.name else routeDefaultName(method, path),
        .name_is_explicit = @hasField(@TypeOf(options), "name"),
        .operation_id = if (@hasField(@TypeOf(options), "operation_id")) options.operation_id else null,
        .status = status,
        .summary = if (@hasField(@TypeOf(options), "summary")) options.summary else null,
        .description = if (@hasField(@TypeOf(options), "description")) options.description else null,
        .external_docs = routeExternalDocs(options),
        .tags = if (@hasField(@TypeOf(options), "tags")) options.tags else &.{},
        .include_in_schema = if (@hasField(@TypeOf(options), "include_in_schema")) options.include_in_schema else true,
        .deprecated = if (@hasField(@TypeOf(options), "deprecated")) options.deprecated else false,
        .request_body_type_name = requestBodyTypeName(fn_info.params),
        .request_body_schema = requestBodySchema(fn_info.params),
        .request_body_inline_schema = requestBodyInlineSchema(fn_info.params),
        .request_body_required = requestBodyRequired(fn_info.params),
        .request_body_content_type = requestBodyContentType(fn_info.params),
        .request_examples = if (@hasField(@TypeOf(options), "request_examples")) options.request_examples else &.{},
        .response_content_type = if (response_body_allowed) responseContentType(fn_info.return_type.?) else null,
        .response_type_name = if (response_body_allowed) responseTypeName(fn_info.return_type.?) else null,
        .response_inline_schema = if (response_body_allowed) responseInlineSchema(fn_info.return_type.?) else null,
        .response_schema = if (response_body_allowed) responseSchema(fn_info.return_type.?) else null,
        .response_description = if (@hasField(@TypeOf(options), "response_description")) options.response_description else null,
        .response_examples = if (@hasField(@TypeOf(options), "response_examples")) options.response_examples else &.{},
        .response_headers = if (@hasField(@TypeOf(options), "response_headers")) options.response_headers else &.{},
        .additional_responses = if (@hasField(@TypeOf(options), "responses")) options.responses else &.{},
        .requires_bearer_auth = requiresBearerAuth(fn_info.params),
        .requires_basic_auth = requiresBasicAuth(fn_info.params),
        .oauth2_password_bearer_auth = oauth2PasswordBearerAuthMetadata(fn_info.params),
        .oauth2_authorization_code_bearer_auth = oauth2AuthorizationCodeBearerAuthMetadata(fn_info.params),
        .oauth2_client_credentials_bearer_auth = oauth2ClientCredentialsBearerAuthMetadata(fn_info.params),
        .oauth2_implicit_bearer_auth = oauth2ImplicitBearerAuthMetadata(fn_info.params),
        .api_key_auth = apiKeyAuthMetadata(fn_info.params),
        .path_params = paramsMetadata(fn_info.params, .path, parameter_docs),
        .query_params = paramsMetadata(fn_info.params, .query, parameter_docs),
        .header_params = paramsMetadata(fn_info.params, .header, parameter_docs),
        .cookie_params = paramsMetadata(fn_info.params, .cookie, parameter_docs),
    };
}

fn routeParameterDocs(comptime options: anytype) []const OpenApiParameterDoc {
    if (!@hasField(@TypeOf(options), "parameter_docs")) return &.{};
    return options.parameter_docs;
}

fn routeExternalDocs(comptime options: anytype) ?OpenApiExternalDocs {
    if (!@hasField(@TypeOf(options), "external_docs")) return null;

    const value = options.external_docs;
    switch (@typeInfo(@TypeOf(value))) {
        .null => return null,
        .optional => {
            if (value) |docs| return coerceOpenApiExternalDocs(docs);
            return null;
        },
        else => return coerceOpenApiExternalDocs(value),
    }
}

fn coerceOpenApiExternalDocs(comptime value: anytype) OpenApiExternalDocs {
    return .{
        .description = if (@hasField(@TypeOf(value), "description")) value.description else null,
        .url = value.url,
    };
}

fn routeDefaultName(comptime method: Method, comptime path: []const u8) []const u8 {
    const method_text = method.openapiText();
    comptime var buf: [method_text.len + path.len + "_root".len]u8 = undefined;
    comptime var len: usize = 0;

    inline for (method_text) |ch| {
        buf[len] = ch;
        len += 1;
    }

    comptime var wrote_path_token = false;
    comptime var need_separator = true;
    comptime var in_param = false;
    comptime var skip_converter = false;

    inline for (path) |ch| {
        if (ch == '{') {
            in_param = true;
            skip_converter = false;
            if (wrote_path_token) need_separator = true;
            continue;
        }
        if (ch == '}') {
            in_param = false;
            skip_converter = false;
            if (wrote_path_token) need_separator = true;
            continue;
        }
        if (in_param and ch == ':') {
            skip_converter = true;
            continue;
        }
        if (skip_converter) continue;

        if (std.ascii.isAlphanumeric(ch)) {
            if (need_separator) {
                buf[len] = '_';
                len += 1;
                need_separator = false;
            }
            buf[len] = std.ascii.toLower(ch);
            len += 1;
            wrote_path_token = true;
        } else if (wrote_path_token) {
            need_separator = true;
        }
    }

    if (!wrote_path_token) {
        inline for ("_root") |ch| {
            buf[len] = ch;
            len += 1;
        }
    }

    const final = buf[0..len].*;
    return &struct {
        const name = final;
    }.name;
}

fn routeDefaultNameAlloc(allocator: std.mem.Allocator, method: Method, path: []const u8) ![]u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    errdefer out.deinit();

    try out.writer.writeAll(method.openapiText());

    var wrote_path_token = false;
    var need_separator = true;
    var in_param = false;
    var skip_converter = false;

    for (path) |ch| {
        if (ch == '{') {
            in_param = true;
            skip_converter = false;
            if (wrote_path_token) need_separator = true;
            continue;
        }
        if (ch == '}') {
            in_param = false;
            skip_converter = false;
            if (wrote_path_token) need_separator = true;
            continue;
        }
        if (in_param and ch == ':') {
            skip_converter = true;
            continue;
        }
        if (skip_converter) continue;

        if (std.ascii.isAlphanumeric(ch)) {
            if (need_separator) {
                try out.writer.writeByte('_');
                need_separator = false;
            }
            try out.writer.writeByte(std.ascii.toLower(ch));
            wrote_path_token = true;
        } else if (wrote_path_token) {
            need_separator = true;
        }
    }

    if (!wrote_path_token) try out.writer.writeAll("_root");
    return out.toOwnedSlice();
}

const ParamKind = enum { path, query, header, cookie };

fn requiresBearerAuth(comptime params: []const std.builtin.Type.Fn.Param) bool {
    inline for (params) |param| {
        if (param.type.? == BearerAuth) return true;
    }
    return false;
}

fn requiresBasicAuth(comptime params: []const std.builtin.Type.Fn.Param) bool {
    inline for (params) |param| {
        if (param.type.? == BasicAuth) return true;
    }
    return false;
}

fn oauth2PasswordBearerAuthMetadata(comptime params: []const std.builtin.Type.Fn.Param) []const OAuth2PasswordBearerSecurityMetadata {
    const values = comptime oauth2PasswordBearerAuthMetadataArray(params);
    return &struct {
        const metadata = values;
    }.metadata;
}

fn oauth2PasswordBearerAuthMetadataArray(comptime params: []const std.builtin.Type.Fn.Param) [oauth2PasswordBearerAuthMetadataCount(params)]OAuth2PasswordBearerSecurityMetadata {
    var result: [oauth2PasswordBearerAuthMetadataCount(params)]OAuth2PasswordBearerSecurityMetadata = undefined;
    comptime var idx = 0;
    inline for (params) |param| {
        const T = param.type.?;
        if (isOAuth2PasswordBearer(T)) {
            result[idx] = .{
                .scheme_name = T.zapi_scheme_name,
                .token_url = T.zapi_token_url,
                .scopes = T.zapi_scopes,
            };
            idx += 1;
        }
    }
    return result;
}

fn oauth2PasswordBearerAuthMetadataCount(comptime params: []const std.builtin.Type.Fn.Param) usize {
    comptime var count = 0;
    inline for (params) |param| {
        if (isOAuth2PasswordBearer(param.type.?)) count += 1;
    }
    return count;
}

fn oauth2AuthorizationCodeBearerAuthMetadata(comptime params: []const std.builtin.Type.Fn.Param) []const OAuth2AuthorizationCodeBearerSecurityMetadata {
    const values = comptime oauth2AuthorizationCodeBearerAuthMetadataArray(params);
    return &struct {
        const metadata = values;
    }.metadata;
}

fn oauth2AuthorizationCodeBearerAuthMetadataArray(comptime params: []const std.builtin.Type.Fn.Param) [oauth2AuthorizationCodeBearerAuthMetadataCount(params)]OAuth2AuthorizationCodeBearerSecurityMetadata {
    var result: [oauth2AuthorizationCodeBearerAuthMetadataCount(params)]OAuth2AuthorizationCodeBearerSecurityMetadata = undefined;
    comptime var idx = 0;
    inline for (params) |param| {
        const T = param.type.?;
        if (isOAuth2AuthorizationCodeBearer(T)) {
            result[idx] = .{
                .scheme_name = T.zapi_scheme_name,
                .authorization_url = T.zapi_authorization_url,
                .token_url = T.zapi_token_url,
                .scopes = T.zapi_scopes,
            };
            idx += 1;
        }
    }
    return result;
}

fn oauth2AuthorizationCodeBearerAuthMetadataCount(comptime params: []const std.builtin.Type.Fn.Param) usize {
    comptime var count = 0;
    inline for (params) |param| {
        if (isOAuth2AuthorizationCodeBearer(param.type.?)) count += 1;
    }
    return count;
}

fn oauth2ClientCredentialsBearerAuthMetadata(comptime params: []const std.builtin.Type.Fn.Param) []const OAuth2ClientCredentialsBearerSecurityMetadata {
    const values = comptime oauth2ClientCredentialsBearerAuthMetadataArray(params);
    return &struct {
        const metadata = values;
    }.metadata;
}

fn oauth2ClientCredentialsBearerAuthMetadataArray(comptime params: []const std.builtin.Type.Fn.Param) [oauth2ClientCredentialsBearerAuthMetadataCount(params)]OAuth2ClientCredentialsBearerSecurityMetadata {
    var result: [oauth2ClientCredentialsBearerAuthMetadataCount(params)]OAuth2ClientCredentialsBearerSecurityMetadata = undefined;
    comptime var idx = 0;
    inline for (params) |param| {
        const T = param.type.?;
        if (isOAuth2ClientCredentialsBearer(T)) {
            result[idx] = .{
                .scheme_name = T.zapi_scheme_name,
                .token_url = T.zapi_token_url,
                .scopes = T.zapi_scopes,
            };
            idx += 1;
        }
    }
    return result;
}

fn oauth2ClientCredentialsBearerAuthMetadataCount(comptime params: []const std.builtin.Type.Fn.Param) usize {
    comptime var count = 0;
    inline for (params) |param| {
        if (isOAuth2ClientCredentialsBearer(param.type.?)) count += 1;
    }
    return count;
}

fn oauth2ImplicitBearerAuthMetadata(comptime params: []const std.builtin.Type.Fn.Param) []const OAuth2ImplicitBearerSecurityMetadata {
    const values = comptime oauth2ImplicitBearerAuthMetadataArray(params);
    return &struct {
        const metadata = values;
    }.metadata;
}

fn oauth2ImplicitBearerAuthMetadataArray(comptime params: []const std.builtin.Type.Fn.Param) [oauth2ImplicitBearerAuthMetadataCount(params)]OAuth2ImplicitBearerSecurityMetadata {
    var result: [oauth2ImplicitBearerAuthMetadataCount(params)]OAuth2ImplicitBearerSecurityMetadata = undefined;
    comptime var idx = 0;
    inline for (params) |param| {
        const T = param.type.?;
        if (isOAuth2ImplicitBearer(T)) {
            result[idx] = .{
                .scheme_name = T.zapi_scheme_name,
                .authorization_url = T.zapi_authorization_url,
                .scopes = T.zapi_scopes,
            };
            idx += 1;
        }
    }
    return result;
}

fn oauth2ImplicitBearerAuthMetadataCount(comptime params: []const std.builtin.Type.Fn.Param) usize {
    comptime var count = 0;
    inline for (params) |param| {
        if (isOAuth2ImplicitBearer(param.type.?)) count += 1;
    }
    return count;
}

fn apiKeyAuthMetadata(comptime params: []const std.builtin.Type.Fn.Param) []const ApiKeySecurityMetadata {
    const values = comptime apiKeyAuthMetadataArray(params);
    return &struct {
        const metadata = values;
    }.metadata;
}

fn apiKeyAuthMetadataArray(comptime params: []const std.builtin.Type.Fn.Param) [apiKeyAuthMetadataCount(params)]ApiKeySecurityMetadata {
    var result: [apiKeyAuthMetadataCount(params)]ApiKeySecurityMetadata = undefined;
    comptime var idx = 0;
    inline for (params) |param| {
        const T = param.type.?;
        if (isApiKeyAuth(T)) {
            result[idx] = .{
                .scheme_name = apiKeySchemeName(T.zapi_api_key_location, T.zapi_api_key_name),
                .location = T.zapi_api_key_location,
                .name = T.zapi_api_key_name,
            };
            idx += 1;
        }
    }
    return result;
}

fn apiKeyAuthMetadataCount(comptime params: []const std.builtin.Type.Fn.Param) usize {
    comptime var count = 0;
    inline for (params) |param| {
        if (isApiKeyAuth(param.type.?)) count += 1;
    }
    return count;
}

fn apiKeySchemeName(comptime location: ApiKeyLocation, comptime name: []const u8) []const u8 {
    const prefix = switch (location) {
        .header => "ApiKeyHeader",
        .query => "ApiKeyQuery",
        .cookie => "ApiKeyCookie",
    };

    comptime var buf: [prefix.len + 1 + name.len]u8 = undefined;
    @memcpy(buf[0..prefix.len], prefix);
    buf[prefix.len] = '_';
    inline for (name, 0..) |ch, i| {
        buf[prefix.len + 1 + i] = if (std.ascii.isAlphanumeric(ch)) ch else '_';
    }
    const value = buf;
    return &struct {
        const scheme_name = value;
    }.scheme_name;
}

fn requestBodyTypeName(comptime params: []const std.builtin.Type.Fn.Param) ?[]const u8 {
    inline for (params) |param| {
        const T = param.type.?;
        if (isWrapper(T, .body) and inlineSchemaPreferred(wrapperInner(T))) return null;
        if (isWrapper(T, .body)) return schemaName(wrapperInner(T));
        if (isWrapper(T, .form)) return schemaName(wrapperInner(T));
    }
    return null;
}

fn requestBodySchema(comptime params: []const std.builtin.Type.Fn.Param) ?SchemaComponent {
    inline for (params) |param| {
        const T = param.type.?;
        if (isWrapper(T, .body) and inlineSchemaPreferred(wrapperInner(T))) return null;
        if (isWrapper(T, .body)) return schemaComponent(wrapperInner(T));
        if (isWrapper(T, .form)) return schemaComponent(wrapperInner(T));
    }
    return null;
}

fn requestBodyInlineSchema(comptime params: []const std.builtin.Type.Fn.Param) ?JsonSchema {
    inline for (params) |param| {
        const T = param.type.?;
        if (isWrapper(T, .body) and inlineSchemaPreferred(wrapperInner(T))) return schemaFor(wrapperInner(T));
    }
    return null;
}

fn requestBodyRequired(comptime params: []const std.builtin.Type.Fn.Param) bool {
    inline for (params) |param| {
        const T = param.type.?;
        if (isWrapper(T, .body)) return !isOptional(wrapperInner(T));
        if (isWrapper(T, .form)) return true;
    }
    return false;
}

fn requestBodyContentType(comptime params: []const std.builtin.Type.Fn.Param) ?[]const u8 {
    inline for (params) |param| {
        const T = param.type.?;
        if (isWrapper(T, .body)) return "application/json";
        if (isWrapper(T, .form)) return formContentType(wrapperInner(T));
    }
    return null;
}

fn formContentType(comptime T: type) []const u8 {
    inline for (@typeInfo(T).@"struct".fields) |field| {
        if (comptime containsUploadFile(field.type)) return "multipart/form-data";
    }
    return "application/x-www-form-urlencoded";
}

fn responseContentType(comptime Return: type) ?[]const u8 {
    const Payload = responsePayloadType(Return);
    if (Payload == void or Payload == Empty or Payload == Redirect or Payload == ResponsePayload) return null;
    if (Payload == Text) return "text/plain; charset=utf-8";
    if (Payload == Html or Payload == Template) return "text/html; charset=utf-8";
    if (Payload == EventStream) return "text/event-stream";
    if (Payload == Bytes or Payload == File or Payload == StreamingResponse) return "application/octet-stream";
    if (Payload == RawJson) return "application/json";
    return "application/json";
}

fn responseTypeName(comptime Return: type) ?[]const u8 {
    const Payload = responsePayloadType(Return);
    if (isJsonResponse(Payload)) {
        if (inlineSchemaPreferred(Payload.zapi_inner)) return null;
        return schemaName(Payload.zapi_inner);
    }
    if (isSchemaFreeResponse(Payload)) return null;
    if (Payload == void or Payload == Empty) return null;
    if (inlineSchemaPreferred(Payload)) return null;
    return schemaName(Payload);
}

fn responseInlineSchema(comptime Return: type) ?JsonSchema {
    const Payload = responsePayloadType(Return);
    if (isJsonResponse(Payload) and inlineSchemaPreferred(Payload.zapi_inner)) return schemaFor(Payload.zapi_inner);
    if (Payload == Text or Payload == Html or Payload == Template) return .string;
    if (Payload == EventStream) return .string;
    if (Payload == Bytes or Payload == File or Payload == StreamingResponse) return .binary;
    if (inlineSchemaPreferred(Payload)) return schemaFor(Payload);
    return null;
}

fn responseSchema(comptime Return: type) ?SchemaComponent {
    const Payload = responsePayloadType(Return);
    if (isJsonResponse(Payload)) {
        if (inlineSchemaPreferred(Payload.zapi_inner)) return null;
        return schemaComponent(Payload.zapi_inner);
    }
    if (isSchemaFreeResponse(Payload)) return null;
    if (Payload == void or Payload == Empty) return null;
    if (inlineSchemaPreferred(Payload)) return null;
    return schemaComponent(Payload);
}

fn inlineSchemaPreferred(comptime T: type) bool {
    if (T == Uuid or T == Date or T == DateTime or T == Email or T == Url) return true;
    if (jsonMapValueType(T) != null) return true;
    return switch (@typeInfo(T)) {
        .optional => true,
        .array => true,
        .pointer => |ptr| ptr.size == .slice and ptr.child != u8,
        else => false,
    };
}

fn responsePayloadType(comptime Return: type) type {
    if (@typeInfo(Return) == .error_union) return @typeInfo(Return).error_union.payload;
    return Return;
}

fn isSchemaFreeResponse(comptime T: type) bool {
    return T == Text or T == Html or T == Template or T == EventStream or T == Bytes or T == File or T == StreamingResponse or T == RawJson or T == Redirect or T == ResponsePayload;
}

fn schemaComponent(comptime T: type) SchemaComponent {
    return .{
        .name = schemaName(T),
        .write = struct {
            fn write(writer: *std.Io.Writer) anyerror!void {
                try writeJsonSchema(T, writer);
            }
        }.write,
    };
}

fn paramsMetadata(comptime params: []const std.builtin.Type.Fn.Param, comptime kind: ParamKind, comptime docs: []const OpenApiParameterDoc) []const ParamMetadata {
    @setEvalBranchQuota(10_000);
    const values = comptime paramsMetadataArray(params, kind, docs);
    return &struct {
        const metadata = values;
    }.metadata;
}

fn paramsMetadataArray(comptime params: []const std.builtin.Type.Fn.Param, comptime kind: ParamKind, comptime docs: []const OpenApiParameterDoc) [paramsMetadataCount(params, kind)]ParamMetadata {
    comptime var count = 0;
    inline for (params) |param| {
        const T = param.type.?;
        const matches = switch (kind) {
            .path => isWrapper(T, .path),
            .query => isWrapper(T, .query),
            .header => isWrapper(T, .header),
            .cookie => isWrapper(T, .cookie),
        };
        if (matches) count += @typeInfo(wrapperInner(T)).@"struct".fields.len;
    }

    var result: [count]ParamMetadata = undefined;
    comptime var idx = 0;
    inline for (params) |param| {
        const T = param.type.?;
        const matches = switch (kind) {
            .path => isWrapper(T, .path),
            .query => isWrapper(T, .query),
            .header => isWrapper(T, .header),
            .cookie => isWrapper(T, .cookie),
        };
        if (matches) {
            inline for (@typeInfo(wrapperInner(T)).@"struct".fields) |field| {
                const default_name = if (kind == .header) headerParamName(field.name) else field.name;
                const doc = parameterDocFor(docs, kind, default_name, field.name);
                result[idx] = .{
                    .field_name = field.name,
                    .name = parameterNameForDoc(kind, default_name, doc),
                    .schema = schemaFor(field.type),
                    .required = kind == .path or (!isOptional(field.type) and field.default_value_ptr == null),
                    .default_value = if (kind == .path) null else defaultValueForField(field),
                    .description = if (doc) |value| value.description else null,
                    .example_json = if (doc) |value| value.example_json else null,
                    .deprecated = if (doc) |value| value.deprecated else false,
                };
                idx += 1;
            }
        }
    }

    return result;
}

fn paramsMetadataCount(comptime params: []const std.builtin.Type.Fn.Param, comptime kind: ParamKind) usize {
    comptime var count = 0;
    inline for (params) |param| {
        const T = param.type.?;
        const matches = switch (kind) {
            .path => isWrapper(T, .path),
            .query => isWrapper(T, .query),
            .header => isWrapper(T, .header),
            .cookie => isWrapper(T, .cookie),
        };
        if (matches) count += @typeInfo(wrapperInner(T)).@"struct".fields.len;
    }
    return count;
}

fn parameterDocFor(comptime docs: []const OpenApiParameterDoc, comptime kind: ParamKind, comptime default_name: []const u8, comptime field_name: []const u8) ?OpenApiParameterDoc {
    inline for (docs) |doc| {
        if (doc.location != parameterLocationForKind(kind)) continue;
        if (std.mem.eql(u8, doc.name, default_name) or std.mem.eql(u8, doc.name, field_name)) return doc;
    }
    return null;
}

fn parameterNameForDoc(comptime kind: ParamKind, comptime default_name: []const u8, comptime doc: ?OpenApiParameterDoc) []const u8 {
    if (kind == .path) return default_name;
    if (doc) |value| {
        if (value.alias) |alias| return alias;
    }
    return default_name;
}

fn parameterLocationForKind(comptime kind: ParamKind) OpenApiParameterLocation {
    return switch (kind) {
        .path => .path,
        .query => .query,
        .header => .header,
        .cookie => .cookie,
    };
}

fn defaultValueForField(comptime field: std.builtin.Type.StructField) ?DefaultValue {
    if (field.default_value_ptr == null) return null;

    return .{
        .write = struct {
            fn write(writer: *std.Io.Writer) anyerror!void {
                const value = @as(*const field.type, @ptrCast(@alignCast(field.default_value_ptr.?))).*;
                try std.json.Stringify.value(value, .{}, writer);
            }
        }.write,
    };
}

fn headerParamName(comptime field_name: []const u8) []const u8 {
    comptime var buf: [field_name.len]u8 = undefined;
    inline for (field_name, 0..) |ch, i| {
        buf[i] = if (ch == '_') '-' else std.ascii.toLower(ch);
    }
    const value = buf;
    return &struct {
        const name = value;
    }.name;
}

const JsonSchema = union(enum) {
    string,
    string_format: []const u8,
    binary,
    boolean,
    integer,
    number,
    array: *const JsonSchema,
    dictionary: *const JsonSchema,
    object: []const SchemaField,
    enumeration: []const []const u8,
    nullable: *const JsonSchema,
};

const SchemaField = struct {
    name: []const u8,
    schema: JsonSchema,
    required: bool,
    default_value: ?DefaultValue = null,
};

fn schemaName(comptime T: type) []const u8 {
    const raw = @typeName(T);
    if (std.mem.lastIndexOfScalar(u8, raw, '.')) |idx| return raw[idx + 1 ..];
    return raw;
}

fn schemaFor(comptime T: type) JsonSchema {
    if (T == UploadFile) return .string;
    if (T == Uuid) return .{ .string_format = "uuid" };
    if (T == Date) return .{ .string_format = "date" };
    if (T == DateTime) return .{ .string_format = "date-time" };
    if (T == Email) return .{ .string_format = "email" };
    if (T == Url) return .{ .string_format = "uri" };
    if (comptime jsonMapValueType(T)) |Value| {
        const child = comptime schemaFor(Value);
        return .{ .dictionary = &struct {
            const value = child;
        }.value };
    }

    return switch (@typeInfo(T)) {
        .bool => .boolean,
        .int, .comptime_int => .integer,
        .float, .comptime_float => .number,
        .pointer => |ptr| blk: {
            if (ptr.size == .slice and ptr.child == u8) break :blk .string;
            const child = comptime schemaFor(ptr.child);
            break :blk .{ .array = &struct {
                const value = child;
            }.value };
        },
        .array => |arr| blk: {
            const child = comptime schemaFor(arr.child);
            break :blk .{ .array = &struct {
                const value = child;
            }.value };
        },
        .optional => |opt| blk: {
            const child = comptime schemaFor(opt.child);
            break :blk .{ .nullable = &struct {
                const value = child;
            }.value };
        },
        .@"enum" => |enm| blk: {
            comptime var values: [enm.fields.len][]const u8 = undefined;
            inline for (enm.fields, 0..) |field, i| values[i] = field.name;
            const final_values = values;
            break :blk .{ .enumeration = &struct {
                const items = final_values;
            }.items };
        },
        .@"struct" => |strct| blk: {
            comptime var fields: [strct.fields.len]SchemaField = undefined;
            inline for (strct.fields, 0..) |field, i| {
                fields[i] = .{
                    .name = field.name,
                    .schema = schemaFor(field.type),
                    .required = !isOptional(field.type) and field.default_value_ptr == null,
                    .default_value = defaultValueForField(field),
                };
            }
            const final_fields = fields;
            break :blk .{ .object = &struct {
                const items = final_fields;
            }.items };
        },
        else => .string,
    };
}

fn jsonMapValueType(comptime T: type) ?type {
    if (@typeInfo(T) != .@"struct") return null;
    if (!@hasDecl(T, "jsonParse") or !@hasDecl(T, "jsonStringify")) return null;

    inline for (@typeInfo(T).@"struct".fields) |field| {
        if (!std.mem.eql(u8, field.name, "map")) continue;
        const Map = field.type;
        if (@typeInfo(Map) != .@"struct" or !@hasDecl(Map, "KV")) return null;
        const kv_info = @typeInfo(Map.KV);
        if (kv_info != .@"struct") return null;

        comptime var key_is_string = false;
        comptime var Value: ?type = null;
        inline for (kv_info.@"struct".fields) |kv_field| {
            if (std.mem.eql(u8, kv_field.name, "key")) {
                key_is_string = isStringSlice(kv_field.type);
            } else if (std.mem.eql(u8, kv_field.name, "value")) {
                Value = kv_field.type;
            }
        }
        if (key_is_string) return Value;
        return null;
    }

    return null;
}

fn isStringSlice(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |ptr| ptr.size == .slice and ptr.child == u8,
        else => false,
    };
}

fn containsUploadFile(comptime T: type) bool {
    if (T == UploadFile) return true;
    return switch (@typeInfo(T)) {
        .pointer => |ptr| ptr.size == .slice and containsUploadFile(ptr.child),
        .array => |arr| containsUploadFile(arr.child),
        .optional => |opt| containsUploadFile(opt.child),
        else => false,
    };
}

fn isOptional(comptime T: type) bool {
    return @typeInfo(T) == .optional;
}

fn parseBody(comptime T: type, allocator: std.mem.Allocator, request: Request) !Body(T) {
    if (comptime isOptional(T)) {
        if (request.body.len == 0) {
            return .{
                .value = null,
                .parsed = null,
            };
        }
    }

    if (!requestHasJsonBodyContentType(request)) return error.Validation;

    const parsed = std.json.parseFromSlice(T, allocator, request.body, .{}) catch return error.Validation;
    return .{
        .value = parsed.value,
        .parsed = parsed,
    };
}

fn parseBearerAuth(request: Request) !BearerAuth {
    const authorization = request.header("authorization") orelse return error.BearerUnauthorized;
    const token = authorizationCredentials(authorization, "Bearer") orelse return error.BearerUnauthorized;
    if (token.len == 0 or std.mem.indexOfAny(u8, token, " \t\r\n") != null) return error.BearerUnauthorized;
    return .{ .token = token };
}

fn parseOAuth2PasswordBearer(comptime T: type, request: Request) !T {
    const bearer = try parseBearerAuth(request);
    return .{ .token = bearer.token };
}

fn parseOAuth2AuthorizationCodeBearer(comptime T: type, request: Request) !T {
    const bearer = try parseBearerAuth(request);
    return .{ .token = bearer.token };
}

fn parseOAuth2ClientCredentialsBearer(comptime T: type, request: Request) !T {
    const bearer = try parseBearerAuth(request);
    return .{ .token = bearer.token };
}

fn parseOAuth2ImplicitBearer(comptime T: type, request: Request) !T {
    const bearer = try parseBearerAuth(request);
    return .{ .token = bearer.token };
}

fn parseBasicAuth(allocator: std.mem.Allocator, request: Request) !BasicAuth {
    const authorization = request.header("authorization") orelse return error.BasicUnauthorized;
    const encoded = authorizationCredentials(authorization, "Basic") orelse return error.BasicUnauthorized;
    if (encoded.len == 0 or std.mem.indexOfAny(u8, encoded, " \t\r\n") != null) return error.BasicUnauthorized;

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(encoded) catch return error.BasicUnauthorized;
    const decoded = try arena.allocator().alloc(u8, decoded_len);
    std.base64.standard.Decoder.decode(decoded, encoded) catch return error.BasicUnauthorized;

    const colon = std.mem.indexOfScalar(u8, decoded, ':') orelse return error.BasicUnauthorized;
    return .{
        .username = decoded[0..colon],
        .password = decoded[colon + 1 ..],
        .arena = arena,
    };
}

fn authorizationCredentials(authorization: []const u8, scheme: []const u8) ?[]const u8 {
    if (authorization.len <= scheme.len) return null;
    if (!std.ascii.eqlIgnoreCase(authorization[0..scheme.len], scheme)) return null;
    if (authorization[scheme.len] != ' ') return null;

    var credential_start = scheme.len + 1;
    while (credential_start < authorization.len and authorization[credential_start] == ' ') {
        credential_start += 1;
    }
    if (credential_start == authorization.len) return null;
    return authorization[credential_start..];
}

fn parseApiKeyAuth(comptime T: type, allocator: std.mem.Allocator, request: Request) !T {
    const location = comptime T.zapi_api_key_location;
    const name = comptime T.zapi_api_key_name;

    switch (location) {
        .header => {
            const value = request.header(name) orelse return error.Unauthorized;
            if (value.len == 0) return error.Unauthorized;
            return .{ .key = value };
        },
        .query => {
            var arena = std.heap.ArenaAllocator.init(allocator);
            errdefer arena.deinit();
            const value = try queryValue(arena.allocator(), request.query, name) orelse return error.Unauthorized;
            if (value.len == 0) return error.Unauthorized;
            return .{
                .key = value,
                .arena = arena,
            };
        },
        .cookie => {
            var arena = std.heap.ArenaAllocator.init(allocator);
            errdefer arena.deinit();
            const value = try cookieValue(arena.allocator(), request, name) orelse return error.Unauthorized;
            if (value.len == 0) return error.Unauthorized;
            return .{
                .key = value,
                .arena = arena,
            };
        },
    }
}

fn queryValue(allocator: std.mem.Allocator, query: []const u8, name: []const u8) !?[]const u8 {
    var parsed = std.StringHashMap([]const u8).init(allocator);
    defer parsed.deinit();
    try parseUrlEncodedInto(allocator, query, &parsed);
    return parsed.get(name);
}

fn cookieValue(allocator: std.mem.Allocator, request: Request, name: []const u8) !?[]const u8 {
    var parsed = std.StringHashMap([]const u8).init(allocator);
    defer parsed.deinit();

    try parseCookieHeadersInto(allocator, request, &parsed);
    return parsed.get(name);
}

fn loadSession(allocator: std.mem.Allocator, request: Request, comptime options: SessionOptions) !Session {
    var session = Session.init(allocator);
    errdefer session.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const raw_cookie = try cookieValue(arena.allocator(), request, options.session_cookie) orelse return session;
    const payload = decodeSessionCookie(allocator, raw_cookie, options.secret_key) catch return session;
    defer allocator.free(payload);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, payload, .{}) catch return session;
    defer parsed.deinit();

    if (parsed.value != .object) return session;
    var it = parsed.value.object.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* != .string) continue;
        try session.putLoaded(entry.key_ptr.*, entry.value_ptr.*.string);
    }
    session.changed = false;
    return session;
}

fn encodeSessionCookie(allocator: std.mem.Allocator, session: *Session, secret_key: []const u8) ![]u8 {
    var json = std.Io.Writer.Allocating.init(allocator);
    errdefer json.deinit();

    try json.writer.writeAll("{");
    var first = true;
    var it = session.values.iterator();
    while (it.next()) |entry| {
        if (!first) try json.writer.writeAll(",");
        try writeJsonString(&json.writer, entry.key_ptr.*);
        try json.writer.writeAll(":");
        try writeJsonString(&json.writer, entry.value_ptr.*);
        first = false;
    }
    try json.writer.writeAll("}");

    const payload = try json.toOwnedSlice();
    defer allocator.free(payload);
    const payload_hex = try hexEncodeAlloc(allocator, payload);
    defer allocator.free(payload_hex);
    const signature_hex = try sessionSignatureHex(allocator, payload_hex, secret_key);
    defer allocator.free(signature_hex);

    return std.fmt.allocPrint(allocator, "{s}.{s}", .{ payload_hex, signature_hex });
}

fn decodeSessionCookie(allocator: std.mem.Allocator, raw: []const u8, secret_key: []const u8) ![]u8 {
    const dot = std.mem.indexOfScalar(u8, raw, '.') orelse return error.InvalidSession;
    const payload_hex = raw[0..dot];
    const signature_hex = raw[dot + 1 ..];
    if (payload_hex.len == 0 or signature_hex.len != sessionMacHexLen()) return error.InvalidSession;

    var actual_mac: [SessionHmac.mac_length]u8 = undefined;
    _ = std.fmt.hexToBytes(&actual_mac, signature_hex) catch return error.InvalidSession;
    var expected_mac: [SessionHmac.mac_length]u8 = undefined;
    SessionHmac.create(&expected_mac, payload_hex, secret_key);
    if (!std.crypto.timing_safe.eql([SessionHmac.mac_length]u8, actual_mac, expected_mac)) return error.InvalidSession;

    const payload = try allocator.alloc(u8, payload_hex.len / 2);
    errdefer allocator.free(payload);
    _ = std.fmt.hexToBytes(payload, payload_hex) catch return error.InvalidSession;
    return payload;
}

const SessionHmac = std.crypto.auth.hmac.sha2.HmacSha256;

fn sessionSignatureHex(allocator: std.mem.Allocator, payload_hex: []const u8, secret_key: []const u8) ![]u8 {
    var mac: [SessionHmac.mac_length]u8 = undefined;
    SessionHmac.create(&mac, payload_hex, secret_key);
    return hexEncodeAlloc(allocator, &mac);
}

fn sessionMacHexLen() usize {
    return SessionHmac.mac_length * 2;
}

fn hexEncodeAlloc(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    const encoded = try allocator.alloc(u8, input.len * 2);
    const charset = "0123456789abcdef";
    for (input, 0..) |byte, index| {
        encoded[index * 2] = charset[byte >> 4];
        encoded[index * 2 + 1] = charset[byte & 0x0f];
    }
    return encoded;
}

/// A text or uploaded form value.
pub const FormValue = datastructures.FormValue;
/// One named form value.
pub const FormField = datastructures.FormField;
/// Parsed form data.
pub const FormData = datastructures.FormData;

fn parseForm(comptime T: type, allocator: std.mem.Allocator, request: Request) !T {
    var parsed = FormData.initBorrowed(allocator);
    defer parsed.deinit();

    const content_type = request.header("content-type") orelse "";
    if (contentTypeMatches(content_type, "application/x-www-form-urlencoded")) {
        try parseUrlEncodedFormInto(allocator, request.body, &parsed);
    } else if (contentTypeMatches(content_type, "multipart/form-data")) {
        const boundary = contentTypeParam(content_type, "boundary") orelse return error.Validation;
        try parseMultipartFormInto(allocator, request.body, boundary, &parsed);
    } else {
        return error.Validation;
    }

    var result: T = undefined;
    inline for (@typeInfo(T).@"struct".fields) |field| {
        try assignFormField(&result, field, allocator, parsed.getAll(field.name));
    }
    return result;
}

fn parseFormArg(comptime T: type, allocator: std.mem.Allocator, request: Request) !Form(T) {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    return .{
        .value = try parseForm(T, arena.allocator(), request),
        .arena = arena,
    };
}

fn parseParams(comptime T: type, allocator: std.mem.Allocator, params: std.StringHashMap([]const u8)) !T {
    var result: T = undefined;
    inline for (@typeInfo(T).@"struct".fields) |field| {
        const raw = params.get(field.name) orelse return error.Validation;
        const decoded = try percentDecodePath(allocator, raw);
        @field(result, field.name) = try parseScalar(field.type, allocator, decoded);
    }
    return result;
}

fn parsePathArg(comptime T: type, allocator: std.mem.Allocator, params: std.StringHashMap([]const u8)) !Path(T) {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    return .{
        .value = try parseParams(T, arena.allocator(), params),
        .arena = arena,
    };
}

fn parseQuery(comptime T: type, allocator: std.mem.Allocator, query: []const u8, params: []const ParamMetadata) !T {
    var parsed = QueryParams.initBorrowed(allocator);
    defer parsed.deinit();

    try parseUrlEncodedMultiInto(allocator, query, &parsed);
    var result: T = undefined;
    inline for (@typeInfo(T).@"struct".fields) |field| {
        const name = paramNameForField(params, field.name, field.name);
        try assignQueryField(&result, field, allocator, parsed.getAll(name));
    }
    return result;
}

/// Parsed multi-value query parameters.
pub const QueryParams = datastructures.QueryParams;

/// Parsed cookie values.
pub const CookieParams = datastructures.CookieParams;

fn parseUrlEncodedMultiInto(allocator: std.mem.Allocator, input: []const u8, parsed: *QueryParams) !void {
    var it = std.mem.splitScalar(u8, input, '&');
    while (it.next()) |part| {
        if (part.len == 0) continue;
        const eq_idx = std.mem.indexOfScalar(u8, part, '=') orelse part.len;
        const key = try percentDecode(allocator, part[0..eq_idx]);
        defer allocator.free(key);
        const value = if (eq_idx < part.len) try percentDecode(allocator, part[eq_idx + 1 ..]) else try allocator.dupe(u8, "");
        errdefer allocator.free(value);
        try parsed.append(key, value);
    }
}

fn parseUrlEncodedInto(allocator: std.mem.Allocator, input: []const u8, parsed: *std.StringHashMap([]const u8)) !void {
    var it = std.mem.splitScalar(u8, input, '&');
    while (it.next()) |part| {
        if (part.len == 0) continue;
        const eq_idx = std.mem.indexOfScalar(u8, part, '=') orelse part.len;
        const key = try percentDecode(allocator, part[0..eq_idx]);
        defer allocator.free(key);
        const value = if (eq_idx < part.len) try percentDecode(allocator, part[eq_idx + 1 ..]) else try allocator.dupe(u8, "");
        try parsed.put(try allocator.dupe(u8, key), value);
    }
}

fn parseUrlEncodedFormInto(allocator: std.mem.Allocator, input: []const u8, parsed: *FormData) !void {
    var it = std.mem.splitScalar(u8, input, '&');
    while (it.next()) |part| {
        if (part.len == 0) continue;
        const eq_idx = std.mem.indexOfScalar(u8, part, '=') orelse part.len;
        const key = try percentDecode(allocator, part[0..eq_idx]);
        defer allocator.free(key);
        const value = if (eq_idx < part.len) try percentDecode(allocator, part[eq_idx + 1 ..]) else try allocator.dupe(u8, "");
        errdefer allocator.free(value);
        try parsed.append(key, .{ .text = value }, true);
    }
}

const MultipartPartHeaders = struct {
    name: ?[]const u8 = null,
    filename: ?[]const u8 = null,
    content_type: []const u8 = "application/octet-stream",
};

fn parseMultipartFormInto(allocator: std.mem.Allocator, body: []const u8, boundary: []const u8, parsed: *FormData) !void {
    if (boundary.len == 0) return error.Validation;

    const delimiter = try std.fmt.allocPrint(allocator, "--{s}", .{boundary});
    defer allocator.free(delimiter);
    const next_delimiter = try std.fmt.allocPrint(allocator, "\r\n--{s}", .{boundary});
    defer allocator.free(next_delimiter);

    if (!std.mem.startsWith(u8, body, delimiter)) return error.Validation;
    var pos: usize = delimiter.len;

    while (true) {
        if (std.mem.startsWith(u8, body[pos..], "--")) return;
        if (!std.mem.startsWith(u8, body[pos..], "\r\n")) return error.Validation;
        pos += 2;

        const header_end = std.mem.indexOfPos(u8, body, pos, "\r\n\r\n") orelse return error.Validation;
        const headers = parseMultipartHeaders(body[pos..header_end]) orelse return error.Validation;
        const name = headers.name orelse return error.Validation;
        pos = header_end + 4;

        const part_end = std.mem.indexOfPos(u8, body, pos, next_delimiter) orelse return error.Validation;
        const content = body[pos..part_end];
        pos = part_end + next_delimiter.len;

        if (headers.filename) |filename| {
            try parsed.append(name, .{ .file = .{
                .filename = filename,
                .content_type = headers.content_type,
                .content = content,
            } }, false);
        } else {
            try parsed.append(name, .{ .text = content }, false);
        }
    }
}

fn parseMultipartHeaders(headers: []const u8) ?MultipartPartHeaders {
    var result: MultipartPartHeaders = .{};
    var it = std.mem.splitSequence(u8, headers, "\r\n");
    while (it.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return null;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(name, "content-disposition")) {
            if (!std.mem.startsWith(u8, std.mem.trim(u8, value, " \t"), "form-data")) return null;
            result.name = headerParam(value, "name");
            result.filename = headerParam(value, "filename");
        } else if (std.ascii.eqlIgnoreCase(name, "content-type")) {
            result.content_type = value;
        }
    }
    return result;
}

fn parseQueryArg(comptime T: type, allocator: std.mem.Allocator, query: []const u8, params: []const ParamMetadata) !Query(T) {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    return .{
        .value = try parseQuery(T, arena.allocator(), query, params),
        .arena = arena,
    };
}

fn parseHeaders(comptime T: type, allocator: std.mem.Allocator, request: Request, params: []const ParamMetadata) !T {
    var result: T = undefined;
    inline for (@typeInfo(T).@"struct".fields) |field| {
        const default_name = comptime headerParamName(field.name);
        const header_name = paramNameForField(params, field.name, default_name);
        const raw = try request.headerValues(allocator, header_name);
        defer allocator.free(raw);
        try assignHeaderField(&result, field, allocator, raw);
    }
    return result;
}

fn parseHeaderArg(comptime T: type, allocator: std.mem.Allocator, request: Request, params: []const ParamMetadata) !Header(T) {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    return .{
        .value = try parseHeaders(T, arena.allocator(), request, params),
        .arena = arena,
    };
}

fn parseCookies(comptime T: type, allocator: std.mem.Allocator, request: Request, params: []const ParamMetadata) !T {
    var parsed = std.StringHashMap([]const u8).init(allocator);
    defer parsed.deinit();

    try parseCookieHeadersInto(allocator, request, &parsed);

    var result: T = undefined;
    inline for (@typeInfo(T).@"struct".fields) |field| {
        const name = paramNameForField(params, field.name, field.name);
        try assignCookieField(&result, field, allocator, parsed.get(name));
    }
    return result;
}

fn parseCookieHeadersInto(allocator: std.mem.Allocator, request: Request, parsed: *std.StringHashMap([]const u8)) !void {
    for (request.headers) |item| {
        if (!std.ascii.eqlIgnoreCase(item.name, "cookie")) continue;

        var cookie_it = std.mem.splitScalar(u8, item.value, ';');
        while (cookie_it.next()) |raw_part| {
            const pair = parseCookieHeaderPair(raw_part) orelse continue;
            try parsed.put(try allocator.dupe(u8, pair.name), try allocator.dupe(u8, pair.value));
        }
    }
}

fn parseCookieParamsInto(request: Request, parsed: *CookieParams) !void {
    for (request.headers) |item| {
        if (!std.ascii.eqlIgnoreCase(item.name, "cookie")) continue;

        var cookie_it = std.mem.splitScalar(u8, item.value, ';');
        while (cookie_it.next()) |raw_part| {
            const pair = parseCookieHeaderPair(raw_part) orelse continue;
            try parsed.put(pair.name, pair.value);
        }
    }
}

const CookieHeaderPair = struct {
    name: []const u8,
    value: []const u8,
};

fn parseCookieHeaderPair(raw_part: []const u8) ?CookieHeaderPair {
    const part = std.mem.trim(u8, raw_part, " \t");
    if (part.len == 0) return null;

    const eq_idx = std.mem.indexOfScalar(u8, part, '=') orelse return .{
        .name = "",
        .value = part,
    };
    const value = std.mem.trim(u8, part[eq_idx + 1 ..], " \t");
    return .{
        .name = std.mem.trim(u8, part[0..eq_idx], " \t"),
        .value = unquoteCookieValue(value),
    };
}

fn unquoteCookieValue(value: []const u8) []const u8 {
    if (value.len < 2) return value;
    if (value[0] != '"' or value[value.len - 1] != '"') return value;
    return value[1 .. value.len - 1];
}

fn parseCookieArg(comptime T: type, allocator: std.mem.Allocator, request: Request, params: []const ParamMetadata) !Cookie(T) {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    return .{
        .value = try parseCookies(T, arena.allocator(), request, params),
        .arena = arena,
    };
}

fn paramNameForField(params: []const ParamMetadata, comptime field_name: []const u8, comptime default_name: []const u8) []const u8 {
    for (params) |param| {
        if (std.mem.eql(u8, param.field_name, field_name)) return param.name;
    }
    return default_name;
}

fn assignQueryField(result: anytype, comptime field: std.builtin.Type.StructField, allocator: std.mem.Allocator, raw: ?[]const []const u8) !void {
    if (raw) |values| {
        @field(result.*, field.name) = try parseQueryValues(field.type, allocator, values);
        return;
    }

    if (field.default_value_ptr) |default_ptr| {
        @field(result.*, field.name) = @as(*const field.type, @ptrCast(@alignCast(default_ptr))).*;
        return;
    }

    if (comptime isOptional(field.type)) {
        @field(result.*, field.name) = null;
        return;
    }

    return error.Validation;
}

fn parseQueryValues(comptime T: type, allocator: std.mem.Allocator, values: []const []const u8) !T {
    if (values.len == 0) return error.Validation;

    switch (@typeInfo(T)) {
        .pointer => |ptr| {
            if (ptr.size == .slice and ptr.child == u8) return try parseScalar(T, allocator, values[0]);
            if (ptr.size == .slice) {
                var result = try allocator.alloc(ptr.child, values.len);
                errdefer allocator.free(result);
                for (values, 0..) |value, i| {
                    result[i] = try parseScalar(ptr.child, allocator, value);
                }
                return result;
            }
        },
        .optional => |opt| {
            if (values.len == 1 and values[0].len == 0) return null;
            return try parseQueryValues(opt.child, allocator, values);
        },
        else => {},
    }

    return try parseScalar(T, allocator, values[0]);
}

fn assignFormField(result: anytype, comptime field: std.builtin.Type.StructField, allocator: std.mem.Allocator, raw: ?[]const FormValue) !void {
    if (raw) |values| {
        if (values.len == 0) return error.Validation;

        if (comptime field.type == UploadFile) {
            @field(result.*, field.name) = switch (values[0]) {
                .file => |file| file,
                .text => return error.Validation,
            };
            return;
        }

        if (comptime isOptionalUploadFile(field.type)) {
            @field(result.*, field.name) = switch (values[0]) {
                .file => |file| file,
                .text => return error.Validation,
            };
            return;
        }

        @field(result.*, field.name) = try parseFormValues(field.type, allocator, values);
        return;
    }

    if (field.default_value_ptr) |default_ptr| {
        @field(result.*, field.name) = @as(*const field.type, @ptrCast(@alignCast(default_ptr))).*;
        return;
    }

    if (comptime isOptional(field.type)) {
        @field(result.*, field.name) = null;
        return;
    }

    return error.Validation;
}

fn parseFormValues(comptime T: type, allocator: std.mem.Allocator, values: []const FormValue) !T {
    if (values.len == 0) return error.Validation;
    if (comptime T == UploadFile) return try formFile(values[0]);

    switch (@typeInfo(T)) {
        .pointer => |ptr| {
            if (ptr.size == .slice and ptr.child == u8) return try parseScalar(T, allocator, try formText(values[0]));
            if (ptr.size == .slice) {
                var result = try allocator.alloc(ptr.child, values.len);
                errdefer allocator.free(result);
                for (values, 0..) |value, i| {
                    if (comptime ptr.child == UploadFile) {
                        result[i] = try formFile(value);
                    } else {
                        result[i] = try parseScalar(ptr.child, allocator, try formText(value));
                    }
                }
                return result;
            }
        },
        .optional => |opt| {
            if (values.len == 1) {
                switch (values[0]) {
                    .text => |text| if (text.len == 0) return null,
                    .file => {},
                }
            }
            return try parseFormValues(opt.child, allocator, values);
        },
        else => {},
    }

    return try parseScalar(T, allocator, try formText(values[0]));
}

fn formText(value: FormValue) ![]const u8 {
    return switch (value) {
        .text => |text| text,
        .file => error.Validation,
    };
}

fn formFile(value: FormValue) !UploadFile {
    return switch (value) {
        .file => |file| file,
        .text => error.Validation,
    };
}

fn isOptionalUploadFile(comptime T: type) bool {
    if (@typeInfo(T) != .optional) return false;
    return @typeInfo(T).optional.child == UploadFile;
}

fn assignCookieField(result: anytype, comptime field: std.builtin.Type.StructField, allocator: std.mem.Allocator, raw: ?[]const u8) !void {
    if (raw) |value| {
        @field(result.*, field.name) = try parseScalar(field.type, allocator, value);
        return;
    }

    if (field.default_value_ptr) |default_ptr| {
        @field(result.*, field.name) = @as(*const field.type, @ptrCast(@alignCast(default_ptr))).*;
        return;
    }

    if (comptime isOptional(field.type)) {
        @field(result.*, field.name) = null;
        return;
    }

    return error.Validation;
}

fn assignHeaderField(result: anytype, comptime field: std.builtin.Type.StructField, allocator: std.mem.Allocator, raw: []const []const u8) !void {
    if (raw.len > 0) {
        if (comptime isRepeatedHeaderField(field.type)) {
            @field(result.*, field.name) = try parseQueryValues(field.type, allocator, raw);
            return;
        }

        const owned = try allocator.dupe(u8, raw[0]);
        @field(result.*, field.name) = try parseScalar(field.type, allocator, owned);
        return;
    }

    if (field.default_value_ptr) |default_ptr| {
        @field(result.*, field.name) = @as(*const field.type, @ptrCast(@alignCast(default_ptr))).*;
        return;
    }

    if (comptime isOptional(field.type)) {
        @field(result.*, field.name) = null;
        return;
    }

    return error.Validation;
}

fn isRepeatedHeaderField(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |ptr| ptr.size == .slice and ptr.child != u8,
        .optional => |opt| isRepeatedHeaderField(opt.child),
        else => false,
    };
}

fn parseScalar(comptime T: type, allocator: std.mem.Allocator, raw: []const u8) !T {
    if (comptime T == Uuid) return try Uuid.parse(raw);
    if (comptime T == Date) return try Date.parse(raw);
    if (comptime T == DateTime) return try DateTime.parse(raw);
    if (comptime T == Email) return try Email.parse(raw);
    if (comptime T == Url) return try Url.parse(raw);
    return switch (@typeInfo(T)) {
        .int => std.fmt.parseInt(T, raw, 10) catch error.Validation,
        .float => std.fmt.parseFloat(T, raw) catch error.Validation,
        .bool => blk: {
            if (parseBool(raw)) |value| break :blk value;
            return error.Validation;
        },
        .optional => |opt| if (raw.len == 0) null else try parseScalar(opt.child, allocator, raw),
        .@"enum" => std.meta.stringToEnum(T, raw) orelse error.Validation,
        .pointer => |ptr| blk: {
            if (ptr.size == .slice and ptr.child == u8) break :blk raw;
            return error.Validation;
        },
        else => error.Validation,
    };
}

fn parseBool(raw: []const u8) ?bool {
    if (std.ascii.eqlIgnoreCase(raw, "true")) return true;
    if (std.ascii.eqlIgnoreCase(raw, "1")) return true;
    if (std.ascii.eqlIgnoreCase(raw, "on")) return true;
    if (std.ascii.eqlIgnoreCase(raw, "yes")) return true;

    if (std.ascii.eqlIgnoreCase(raw, "false")) return false;
    if (std.ascii.eqlIgnoreCase(raw, "0")) return false;
    if (std.ascii.eqlIgnoreCase(raw, "off")) return false;
    if (std.ascii.eqlIgnoreCase(raw, "no")) return false;
    return null;
}

const BuiltinPathConverter = routing.BuiltinPathConverter;
const PathConverter = routing.PathConverter;
const RouteParam = routing.RouteParam;
const matchPath = routing.matchPath;
const parseRouteParam = routing.parseRouteParam;
const validPathParamName = routing.validPathParamName;
const validPathConvertorName = routing.validPathConvertorName;
const parsePathConverter = routing.parsePathConverter;
const parseBuiltinPathConverter = routing.parseBuiltinPathConverter;
const pathConverterRegistered = routing.pathConverterRegistered;
const pathConverterIsPath = routing.pathConverterIsPath;
const findPathConvertor = routing.findPathConvertor;
const validateRoutePath = routing.validateRoutePath;
const validateMountPath = routing.validateMountPath;
const pathParamIsTerminalSegment = routing.pathParamIsTerminalSegment;
const pathSegmentMatches = routing.pathSegmentMatches;
const terminalPathParamSegment = routing.terminalPathParamSegment;
const matchPathSegment = routing.matchPathSegment;
const isPathFloat = routing.isPathFloat;
const NextStatic = routing.NextStatic;
const nextStaticInSegment = routing.nextStaticInSegment;
const joinPaths = routing.joinPaths;
const joinRequestPath = routing.joinRequestPath;
const joinMountRoutePath = routing.joinMountRoutePath;
const MaybeOwnedSlice = routing.MaybeOwnedSlice;
const mountRootPath = routing.mountRootPath;
const docsOpenApiUrl = routing.docsOpenApiUrl;
const normalizeMountPrefix = routing.normalizeMountPrefix;
const normalizeHostMatchPattern = routing.normalizeHostMatchPattern;
const normalizeHostUrlPattern = routing.normalizeHostUrlPattern;
const hostPatternMatchName = routing.hostPatternMatchName;
const validateHostPattern = routing.validateHostPattern;
const requestHostName = routing.requestHostName;
const validRouteNamespace = routing.validRouteNamespace;
const namespacedRouteName = routing.namespacedRouteName;
const matchHost = routing.matchHost;
const indexOfIgnoreCasePos = routing.indexOfIgnoreCasePos;
const ParamUsage = routing.ParamUsage;
const initParamUsage = routing.initParamUsage;
const markParamUsed = routing.markParamUsed;
const ensureNoUnusedUrlParams = routing.ensureNoUnusedUrlParams;
const MountMatch = routing.MountMatch;
const matchMount = routing.matchMount;
const renderPath = routing.renderPath;
const renderPathTracked = routing.renderPathTracked;
const renderHostPattern = routing.renderHostPattern;
const renderHostPatternTracked = routing.renderHostPatternTracked;
const RenderTarget = routing.RenderTarget;
const renderPattern = routing.renderPattern;
const renderMountPath = routing.renderMountPath;
const renderMountPathTracked = routing.renderMountPathTracked;
const renderMountPathWithUsage = routing.renderMountPathWithUsage;
const writeParamValue = routing.writeParamValue;
const writeUrlScalar = routing.writeUrlScalar;
const writePercentEncodedPath = routing.writePercentEncodedPath;

fn quoteRedirectLocation(allocator: std.mem.Allocator, location: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    const hex = "0123456789ABCDEF";
    for (location) |ch| {
        if (redirectLocationCharSafe(ch)) {
            try out.append(allocator, ch);
        } else {
            try out.append(allocator, '%');
            try out.append(allocator, hex[ch >> 4]);
            try out.append(allocator, hex[ch & 0x0f]);
        }
    }

    return out.toOwnedSlice(allocator);
}

fn appendUrlEncodedQueryComponent(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (value) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '.' or ch == '_' or ch == '~') {
            try out.append(allocator, ch);
        } else if (ch == ' ') {
            try out.append(allocator, '+');
        } else {
            try out.append(allocator, '%');
            try out.append(allocator, hex[ch >> 4]);
            try out.append(allocator, hex[ch & 0x0f]);
        }
    }
}

fn redirectLocationCharSafe(ch: u8) bool {
    if (std.ascii.isAlphanumeric(ch)) return true;
    return switch (ch) {
        '-',
        '.',
        '_',
        '~',
        ':',
        '/',
        '%',
        '#',
        '?',
        '=',
        '@',
        '[',
        ']',
        '!',
        '$',
        '&',
        '\'',
        '(',
        ')',
        '*',
        '+',
        ',',
        ';',
        => true,
        else => false,
    };
}

fn percentDecode(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    return percentDecodeWithOptions(allocator, input, true);
}

fn percentDecodePath(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    return percentDecodeWithOptions(allocator, input, false);
}

fn percentDecodeWithOptions(allocator: std.mem.Allocator, input: []const u8, plus_as_space: bool) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < input.len) {
        switch (input[i]) {
            '+' => {
                try out.append(allocator, if (plus_as_space) ' ' else '+');
                i += 1;
            },
            '%' => {
                if (i + 2 >= input.len) return error.Validation;
                const byte = std.fmt.parseInt(u8, input[i + 1 .. i + 3], 16) catch return error.Validation;
                try out.append(allocator, byte);
                i += 3;
            },
            else => |ch| {
                try out.append(allocator, ch);
                i += 1;
            },
        }
    }
    return out.toOwnedSlice(allocator);
}

const AcceptMatch = content_types.AcceptMatch;
const mediaTypeOnly = content_types.mediaTypeOnly;
const contentTypeMatches = content_types.contentTypeMatches;
const acceptMatch = content_types.acceptMatch;
const preferredAcceptMatch = content_types.preferredAcceptMatch;
const acceptSpecificity = content_types.acceptSpecificity;
const acceptQuality = content_types.acceptQuality;
const parseQuality = content_types.parseQuality;
const acceptMatchBetter = content_types.acceptMatchBetter;
const acceptPreferredBetter = content_types.acceptPreferredBetter;
const contentTypeParam = content_types.contentTypeParam;
const headerParam = content_types.headerParam;

fn requestHasJsonBodyContentType(request: Request) bool {
    const content_type = request.header("content-type") orelse return true;
    const media_type = mediaTypeOnly(content_type);
    if (std.ascii.eqlIgnoreCase(media_type, "application/json")) return true;
    const slash = std.mem.indexOfScalar(u8, media_type, '/') orelse return false;
    return std.ascii.eqlIgnoreCase(media_type[0..slash], "application") and std.ascii.endsWithIgnoreCase(media_type[slash + 1 ..], "+json");
}

fn writeOpenApi(allocator: std.mem.Allocator, writer: *std.Io.Writer, app: *ZAPI, root_path: []const u8) !void {
    try writer.writeAll("{\"openapi\":\"3.1.0\",\"info\":");
    try writeOpenApiInfo(writer, app.options);
    if (root_path.len > 0 or app.options.openapi_servers.len > 0) {
        try writer.writeAll(",\"servers\":[");
        var first_server = true;
        if (root_path.len > 0) {
            try writeOpenApiServerEntry(writer, root_path, null);
            first_server = false;
        }
        for (app.options.openapi_servers) |server| {
            try writeCommaBefore(writer, &first_server);
            try writeOpenApiServerEntry(writer, server.url, server.description);
        }
        try writer.writeAll("]");
    }
    if (app.options.openapi_tags.len > 0) {
        try writer.writeAll(",\"tags\":[");
        for (app.options.openapi_tags, 0..) |tag, i| {
            if (i != 0) try writer.writeAll(",");
            try writeOpenApiTag(writer, tag);
        }
        try writer.writeAll("]");
    }
    if (app.options.external_docs) |external_docs| {
        try writer.writeAll(",\"externalDocs\":");
        try writeOpenApiExternalDocs(writer, external_docs);
    }
    try writer.writeAll(",\"paths\":{");

    var first_path = true;
    for (app.routes.items, 0..) |route_item, i| {
        if (!routeIncludedInOpenApi(route_item)) continue;
        if (try openApiPathAlreadyWritten(allocator, app.routes.items[0..i], route_item.path)) continue;

        if (!first_path) try writer.writeAll(",");
        try writeOpenApiPath(writer, route_item.path);
        try writer.writeAll(":{");

        var first_method = true;
        for (app.routes.items, 0..) |operation_route, operation_i| {
            if (!routeIncludedInOpenApi(operation_route)) continue;
            if (!(try openApiPathsEqual(allocator, route_item.path, operation_route.path))) continue;
            if (try openApiMethodAlreadyWritten(allocator, app.routes.items[0..operation_i], operation_route.path, operation_route.method)) continue;

            if (!first_method) try writer.writeAll(",");
            try writer.print("\"{s}\":", .{operation_route.method.openapiText()});
            try writeOperation(writer, operation_route);
            first_method = false;
        }

        try writer.writeAll("}");
        first_path = false;
    }

    try writer.writeAll("},\"components\":{\"schemas\":{");
    try writeComponents(allocator, writer, app);
    try writer.writeAll("}");
    if (appUsesSecurity(app)) {
        try writer.writeAll(",\"securitySchemes\":{");
        try writeSecuritySchemes(allocator, writer, app);
        try writer.writeAll("}");
    }
    try writer.writeAll("}}");
}

fn routeIncludedInOpenApi(route_item: RegisteredRoute) bool {
    return route_item.metadata.include_in_schema and route_item.method.supportsOpenApi();
}

fn writeOpenApiInfo(writer: *std.Io.Writer, options: ZAPIOptions) !void {
    try writer.writeAll("{\"title\":");
    try writeJsonString(writer, options.title);
    if (options.description) |description| {
        try writer.writeAll(",\"description\":");
        try writeJsonString(writer, description);
    }
    if (options.terms_of_service) |terms| {
        try writer.writeAll(",\"termsOfService\":");
        try writeJsonString(writer, terms);
    }
    if (options.contact) |contact| {
        try writer.writeAll(",\"contact\":{");
        var first = true;
        if (contact.name) |name| {
            try writeCommaBefore(writer, &first);
            try writer.writeAll("\"name\":");
            try writeJsonString(writer, name);
        }
        if (contact.url) |url| {
            try writeCommaBefore(writer, &first);
            try writer.writeAll("\"url\":");
            try writeJsonString(writer, url);
        }
        if (contact.email) |email| {
            try writeCommaBefore(writer, &first);
            try writer.writeAll("\"email\":");
            try writeJsonString(writer, email);
        }
        try writer.writeAll("}");
    }
    if (options.license) |license| {
        try writer.writeAll(",\"license\":{\"name\":");
        try writeJsonString(writer, license.name);
        if (license.identifier) |identifier| {
            try writer.writeAll(",\"identifier\":");
            try writeJsonString(writer, identifier);
        }
        if (license.url) |url| {
            try writer.writeAll(",\"url\":");
            try writeJsonString(writer, url);
        }
        try writer.writeAll("}");
    }
    try writer.writeAll(",\"version\":");
    try writeJsonString(writer, options.version);
    try writer.writeAll("}");
}

fn writeCommaBefore(writer: *std.Io.Writer, first: *bool) !void {
    if (!first.*) try writer.writeAll(",");
    first.* = false;
}

fn writeOpenApiTag(writer: *std.Io.Writer, tag: OpenApiTag) !void {
    try writer.writeAll("{\"name\":");
    try writeJsonString(writer, tag.name);
    if (tag.description) |description| {
        try writer.writeAll(",\"description\":");
        try writeJsonString(writer, description);
    }
    if (tag.external_docs) |external_docs| {
        try writer.writeAll(",\"externalDocs\":");
        try writeOpenApiExternalDocs(writer, external_docs);
    }
    try writer.writeAll("}");
}

fn writeOpenApiExternalDocs(writer: *std.Io.Writer, external_docs: OpenApiExternalDocs) !void {
    try writer.writeAll("{");
    var first = true;
    if (external_docs.description) |description| {
        try writeCommaBefore(writer, &first);
        try writer.writeAll("\"description\":");
        try writeJsonString(writer, description);
    }
    try writeCommaBefore(writer, &first);
    try writer.writeAll("\"url\":");
    try writeJsonString(writer, external_docs.url);
    try writer.writeAll("}");
}

fn writeOpenApiServerEntry(writer: *std.Io.Writer, url: []const u8, description: ?[]const u8) !void {
    try writer.writeAll("{\"url\":");
    try writeJsonString(writer, url);
    if (description) |value| {
        try writer.writeAll(",\"description\":");
        try writeJsonString(writer, value);
    }
    try writer.writeAll("}");
}

fn writeOpenApiPath(writer: *std.Io.Writer, path: []const u8) !void {
    try writer.writeAll("\"");

    var i: usize = 0;
    while (i < path.len) {
        if (path[i] == '{') {
            const end = std.mem.indexOfScalarPos(u8, path, i + 1, '}') orelse return error.InvalidRoutePath;
            const param = parseRouteParam(path[i .. end + 1]) orelse return error.InvalidRoutePath;
            try writer.writeAll("{");
            try writeJsonStringContents(writer, param.name);
            try writer.writeAll("}");
            i = end + 1;
        } else {
            try writeJsonStringContents(writer, path[i .. i + 1]);
            i += 1;
        }
    }

    try writer.writeAll("\"");
}

fn openApiPathAlreadyWritten(allocator: std.mem.Allocator, previous_routes: []const RegisteredRoute, path: []const u8) !bool {
    for (previous_routes) |route_item| {
        if (!routeIncludedInOpenApi(route_item)) continue;
        if (try openApiPathsEqual(allocator, route_item.path, path)) return true;
    }
    return false;
}

fn openApiMethodAlreadyWritten(allocator: std.mem.Allocator, previous_routes: []const RegisteredRoute, path: []const u8, method: Method) !bool {
    for (previous_routes) |route_item| {
        if (!routeIncludedInOpenApi(route_item)) continue;
        if (route_item.method == method and try openApiPathsEqual(allocator, route_item.path, path)) return true;
    }
    return false;
}

fn openApiPathsEqual(allocator: std.mem.Allocator, a: []const u8, b: []const u8) !bool {
    const normalized_a = try normalizedOpenApiPath(allocator, a);
    defer allocator.free(normalized_a);
    const normalized_b = try normalizedOpenApiPath(allocator, b);
    defer allocator.free(normalized_b);
    return std.mem.eql(u8, normalized_a, normalized_b);
}

fn normalizedOpenApiPath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    errdefer out.deinit();

    var i: usize = 0;
    while (i < path.len) {
        if (path[i] == '{') {
            const end = std.mem.indexOfScalarPos(u8, path, i + 1, '}') orelse return error.InvalidRoutePath;
            const param = parseRouteParam(path[i .. end + 1]) orelse return error.InvalidRoutePath;
            try out.writer.writeAll("{");
            try out.writer.writeAll(param.name);
            try out.writer.writeAll("}");
            i = end + 1;
        } else {
            try out.writer.writeByte(path[i]);
            i += 1;
        }
    }

    return out.toOwnedSlice();
}

fn writeOperation(writer: anytype, route_item: RegisteredRoute) !void {
    const meta = route_item.metadata;
    try writer.writeAll("{");
    try writer.writeAll("\"operationId\":");
    try writeOperationId(writer, route_item);
    var wrote = true;

    if (meta.summary) |summary| {
        if (wrote) try writer.writeAll(",");
        try writer.writeAll("\"summary\":");
        try writeJsonString(writer, summary);
        wrote = true;
    }

    if (meta.description) |description| {
        if (wrote) try writer.writeAll(",");
        try writer.writeAll("\"description\":");
        try writeJsonString(writer, description);
        wrote = true;
    }

    if (meta.tags.len > 0) {
        if (wrote) try writer.writeAll(",");
        try writer.writeAll("\"tags\":[");
        for (meta.tags, 0..) |tag, i| {
            if (i != 0) try writer.writeAll(",");
            try writeJsonString(writer, tag);
        }
        try writer.writeAll("]");
        wrote = true;
    }

    if (meta.external_docs) |external_docs| {
        if (wrote) try writer.writeAll(",");
        try writer.writeAll("\"externalDocs\":");
        try writeOpenApiExternalDocs(writer, external_docs);
        wrote = true;
    }

    if (meta.deprecated) {
        if (wrote) try writer.writeAll(",");
        try writer.writeAll("\"deprecated\":true");
        wrote = true;
    }

    if (meta.requires_bearer_auth or meta.requires_basic_auth or meta.oauth2_password_bearer_auth.len > 0 or meta.oauth2_authorization_code_bearer_auth.len > 0 or meta.oauth2_client_credentials_bearer_auth.len > 0 or meta.oauth2_implicit_bearer_auth.len > 0 or meta.api_key_auth.len > 0) {
        if (wrote) try writer.writeAll(",");
        try writer.writeAll("\"security\":[{");
        var first_scheme = true;
        if (meta.requires_bearer_auth) {
            try writer.writeAll("\"BearerAuth\":[]");
            first_scheme = false;
        }
        if (meta.requires_basic_auth) {
            if (!first_scheme) try writer.writeAll(",");
            try writer.writeAll("\"BasicAuth\":[]");
            first_scheme = false;
        }
        for (meta.oauth2_password_bearer_auth, 0..) |oauth2, i| {
            if (oauth2SchemeAlreadyWritten(meta.oauth2_password_bearer_auth, i)) continue;
            if (!first_scheme) try writer.writeAll(",");
            try writeJsonString(writer, oauth2.scheme_name);
            try writer.writeAll(":[");
            for (oauth2.scopes, 0..) |scope, scope_i| {
                if (scope_i != 0) try writer.writeAll(",");
                try writeJsonString(writer, scope.name);
            }
            try writer.writeAll("]");
            first_scheme = false;
        }
        for (meta.oauth2_authorization_code_bearer_auth, 0..) |oauth2, i| {
            if (oauth2AuthorizationCodeSchemeAlreadyWritten(meta.oauth2_authorization_code_bearer_auth, i)) continue;
            if (!first_scheme) try writer.writeAll(",");
            try writeJsonString(writer, oauth2.scheme_name);
            try writer.writeAll(":[");
            for (oauth2.scopes, 0..) |scope, scope_i| {
                if (scope_i != 0) try writer.writeAll(",");
                try writeJsonString(writer, scope.name);
            }
            try writer.writeAll("]");
            first_scheme = false;
        }
        for (meta.oauth2_client_credentials_bearer_auth, 0..) |oauth2, i| {
            if (oauth2ClientCredentialsSchemeAlreadyWritten(meta.oauth2_client_credentials_bearer_auth, i)) continue;
            if (!first_scheme) try writer.writeAll(",");
            try writeJsonString(writer, oauth2.scheme_name);
            try writer.writeAll(":[");
            for (oauth2.scopes, 0..) |scope, scope_i| {
                if (scope_i != 0) try writer.writeAll(",");
                try writeJsonString(writer, scope.name);
            }
            try writer.writeAll("]");
            first_scheme = false;
        }
        for (meta.oauth2_implicit_bearer_auth, 0..) |oauth2, i| {
            if (oauth2ImplicitSchemeAlreadyWritten(meta.oauth2_implicit_bearer_auth, i)) continue;
            if (!first_scheme) try writer.writeAll(",");
            try writeJsonString(writer, oauth2.scheme_name);
            try writer.writeAll(":[");
            for (oauth2.scopes, 0..) |scope, scope_i| {
                if (scope_i != 0) try writer.writeAll(",");
                try writeJsonString(writer, scope.name);
            }
            try writer.writeAll("]");
            first_scheme = false;
        }
        for (meta.api_key_auth, 0..) |api_key, i| {
            if (apiKeySchemeAlreadyWritten(meta.api_key_auth, i)) continue;
            if (!first_scheme) try writer.writeAll(",");
            try writeJsonString(writer, api_key.scheme_name);
            try writer.writeAll(":[]");
            first_scheme = false;
        }
        try writer.writeAll("}]");
        wrote = true;
    }

    if (meta.path_params.len > 0 or meta.query_params.len > 0 or meta.header_params.len > 0 or meta.cookie_params.len > 0) {
        if (wrote) try writer.writeAll(",");
        try writer.writeAll("\"parameters\":[");
        var first_param = true;
        for (meta.path_params) |param| {
            if (!first_param) try writer.writeAll(",");
            try writeParameter(writer, param, "path");
            first_param = false;
        }
        for (meta.query_params) |param| {
            if (!first_param) try writer.writeAll(",");
            try writeParameter(writer, param, "query");
            first_param = false;
        }
        for (meta.header_params) |param| {
            if (!first_param) try writer.writeAll(",");
            try writeParameter(writer, param, "header");
            first_param = false;
        }
        for (meta.cookie_params) |param| {
            if (!first_param) try writer.writeAll(",");
            try writeParameter(writer, param, "cookie");
            first_param = false;
        }
        try writer.writeAll("]");
        wrote = true;
    }

    if (meta.request_body_type_name != null or meta.request_body_inline_schema != null) {
        if (wrote) try writer.writeAll(",");
        try writer.writeAll("\"requestBody\":{\"required\":");
        try writer.writeAll(if (meta.request_body_required) "true" else "false");
        try writer.writeAll(",\"content\":{");
        try writeJsonString(writer, meta.request_body_content_type orelse "application/json");
        try writer.writeAll(":{\"schema\":");
        if (meta.request_body_inline_schema) |schema| {
            try writeInlineSchema(writer, schema);
        } else {
            const name = meta.request_body_type_name.?;
            try writer.writeAll("{\"$ref\":");
            try writeSchemaRef(writer, name);
            try writer.writeAll("}");
        }
        try writeOpenApiExamples(writer, meta.request_examples);
        try writer.writeAll("}}}");
        wrote = true;
    }

    if (wrote) try writer.writeAll(",");
    try writer.writeAll("\"responses\":{");
    try writer.print("\"{d}\":", .{meta.status.code()});
    try writeOpenApiResponse(writer, meta.response_description orelse meta.status.reason(), meta.response_content_type, meta.response_type_name, meta.response_inline_schema, meta.response_examples, meta.response_headers);
    for (meta.additional_responses) |extra| {
        if (extra.status == meta.status) continue;
        try writer.writeAll(",");
        try writer.print("\"{d}\":", .{extra.status.code()});
        try writeOpenApiResponse(writer, extra.description, extra.content_type, extra.response_type_name, extra.response_inline_schema, extra.examples, extra.headers);
    }
    if (routeHasValidationResponse(meta) and meta.status != .unprocessable_entity and !additionalResponseHasStatus(meta, .unprocessable_entity)) {
        try writer.writeAll(",\"422\":");
        try writeOpenApiResponse(writer, "Validation Error", "application/json", schemaName(ProblemDetail), null, &.{}, &.{});
    }
    try writer.writeAll("}}");
}

fn routeHasValidationResponse(meta: RouteMetadata) bool {
    return meta.request_body_type_name != null or
        meta.request_body_inline_schema != null or
        meta.path_params.len > 0 or
        meta.query_params.len > 0 or
        meta.header_params.len > 0 or
        meta.cookie_params.len > 0;
}

fn additionalResponseHasStatus(meta: RouteMetadata, status: Status) bool {
    for (meta.additional_responses) |response_doc| {
        if (response_doc.status == status) return true;
    }
    return false;
}

fn writeOperationId(writer: *std.Io.Writer, route_item: RegisteredRoute) !void {
    if (route_item.metadata.operation_id) |operation_id| {
        try writeJsonString(writer, operation_id);
        return;
    }

    if (route_item.metadata.name) |name| {
        try writeJsonString(writer, name);
        return;
    }

    try writer.writeAll("\"");
    try writer.writeAll(route_item.method.openapiText());

    var wrote_path_token = false;
    var need_separator = true;
    var in_param = false;
    var skip_converter = false;

    for (route_item.path) |ch| {
        if (ch == '{') {
            in_param = true;
            skip_converter = false;
            if (wrote_path_token) need_separator = true;
            continue;
        }
        if (ch == '}') {
            in_param = false;
            skip_converter = false;
            if (wrote_path_token) need_separator = true;
            continue;
        }
        if (in_param and ch == ':') {
            skip_converter = true;
            continue;
        }
        if (skip_converter) continue;

        if (std.ascii.isAlphanumeric(ch)) {
            if (need_separator) {
                try writer.writeAll("_");
                need_separator = false;
            }
            try writer.writeByte(std.ascii.toLower(ch));
            wrote_path_token = true;
        } else {
            if (wrote_path_token) need_separator = true;
        }
    }

    if (!wrote_path_token) try writer.writeAll("_root");
    try writer.writeAll("\"");
}

fn writeOpenApiResponse(
    writer: *std.Io.Writer,
    description: []const u8,
    content_type: ?[]const u8,
    response_type_name: ?[]const u8,
    inline_schema: ?JsonSchema,
    examples: []const OpenApiExample,
    headers: []const OpenApiHeader,
) !void {
    try writer.writeAll("{\"description\":");
    try writeJsonString(writer, description);
    try writeOpenApiHeaders(writer, headers);
    if (content_type != null or response_type_name != null or inline_schema != null) {
        try writer.writeAll(",\"content\":{");
        try writeJsonString(writer, content_type orelse "application/json");
        try writer.writeAll(":{");
        if (response_type_name != null or inline_schema != null) {
            try writer.writeAll("\"schema\":");
            if (response_type_name) |name| {
                try writer.writeAll("{\"$ref\":");
                try writeSchemaRef(writer, name);
                try writer.writeAll("}");
            } else if (inline_schema) |schema| {
                try writeInlineSchema(writer, schema);
            }
            try writeOpenApiExamples(writer, examples);
        } else if (examples.len > 0) {
            try writeOpenApiExamplesField(writer, examples);
        }
        try writer.writeAll("}}");
    }
    try writer.writeAll("}");
}

fn writeOpenApiHeaders(writer: *std.Io.Writer, headers: []const OpenApiHeader) !void {
    if (headers.len == 0) return;

    try writer.writeAll(",\"headers\":{");
    for (headers, 0..) |header, i| {
        if (i != 0) try writer.writeAll(",");
        try writeJsonString(writer, header.name);
        try writer.writeAll(":{");

        var wrote = false;
        if (header.description) |description| {
            try writer.writeAll("\"description\":");
            try writeJsonString(writer, description);
            wrote = true;
        }
        if (header.required) {
            if (wrote) try writer.writeAll(",");
            try writer.writeAll("\"required\":true");
            wrote = true;
        }
        if (header.deprecated) {
            if (wrote) try writer.writeAll(",");
            try writer.writeAll("\"deprecated\":true");
            wrote = true;
        }
        if (wrote) try writer.writeAll(",");
        try writer.writeAll("\"schema\":");
        try writeInlineSchema(writer, header.schema);
        try writer.writeAll("}");
    }
    try writer.writeAll("}");
}

fn writeOpenApiExamples(writer: *std.Io.Writer, examples: []const OpenApiExample) !void {
    if (examples.len == 0) return;

    try writer.writeAll(",\"examples\":{");
    try writeOpenApiExamplesContent(writer, examples);
}

fn writeOpenApiExamplesField(writer: *std.Io.Writer, examples: []const OpenApiExample) !void {
    if (examples.len == 0) return;

    try writer.writeAll("\"examples\":{");
    try writeOpenApiExamplesContent(writer, examples);
}

fn writeOpenApiExamplesContent(writer: *std.Io.Writer, examples: []const OpenApiExample) !void {
    for (examples, 0..) |example, i| {
        if (i != 0) try writer.writeAll(",");
        try writeJsonString(writer, example.name);
        try writer.writeAll(":{");

        var wrote = false;
        if (example.summary) |summary| {
            try writer.writeAll("\"summary\":");
            try writeJsonString(writer, summary);
            wrote = true;
        }
        if (example.description) |description| {
            if (wrote) try writer.writeAll(",");
            try writer.writeAll("\"description\":");
            try writeJsonString(writer, description);
            wrote = true;
        }
        if (wrote) try writer.writeAll(",");
        try writer.writeAll("\"value\":");
        try writer.writeAll(example.value_json);
        try writer.writeAll("}");
    }
    try writer.writeAll("}");
}

fn writeParameter(writer: anytype, param: ParamMetadata, location: []const u8) !void {
    try writer.writeAll("{\"name\":");
    try writeJsonString(writer, param.name);
    try writer.writeAll(",\"in\":");
    try writeJsonString(writer, location);
    if (param.description) |description| {
        try writer.writeAll(",\"description\":");
        try writeJsonString(writer, description);
    }
    if (param.deprecated) {
        try writer.writeAll(",\"deprecated\":true");
    }
    if (param.example_json) |example_json| {
        try writer.writeAll(",\"example\":");
        try writer.writeAll(example_json);
    }
    try writer.print(",\"required\":{}", .{param.required});
    try writer.writeAll(",\"schema\":");
    try writeInlineSchemaWithDefault(writer, param.schema, param.default_value);
    try writer.writeAll("}");
}

fn writeInlineSchema(writer: anytype, schema: JsonSchema) anyerror!void {
    try writeInlineSchemaWithDefault(writer, schema, null);
}

fn writeInlineSchemaWithDefault(writer: anytype, schema: JsonSchema, default_value: ?DefaultValue) anyerror!void {
    switch (schema) {
        .string => {
            try writer.writeAll("{\"type\":\"string\"");
            try writeSchemaDefault(writer, default_value);
            try writer.writeAll("}");
        },
        .string_format => |format| {
            try writer.writeAll("{\"type\":\"string\",\"format\":");
            try writeJsonString(writer, format);
            try writeSchemaDefault(writer, default_value);
            try writer.writeAll("}");
        },
        .binary => {
            try writer.writeAll("{\"type\":\"string\",\"format\":\"binary\"");
            try writeSchemaDefault(writer, default_value);
            try writer.writeAll("}");
        },
        .boolean => {
            try writer.writeAll("{\"type\":\"boolean\"");
            try writeSchemaDefault(writer, default_value);
            try writer.writeAll("}");
        },
        .integer => {
            try writer.writeAll("{\"type\":\"integer\"");
            try writeSchemaDefault(writer, default_value);
            try writer.writeAll("}");
        },
        .number => {
            try writer.writeAll("{\"type\":\"number\"");
            try writeSchemaDefault(writer, default_value);
            try writer.writeAll("}");
        },
        .array => |child| {
            try writer.writeAll("{\"type\":\"array\",\"items\":");
            try writeInlineSchema(writer, child.*);
            try writeSchemaDefault(writer, default_value);
            try writer.writeAll("}");
        },
        .dictionary => |child| {
            try writer.writeAll("{\"type\":\"object\",\"additionalProperties\":");
            try writeInlineSchema(writer, child.*);
            try writeSchemaDefault(writer, default_value);
            try writer.writeAll("}");
        },
        .nullable => |child| {
            try writer.writeAll("{\"anyOf\":[");
            try writeInlineSchema(writer, child.*);
            try writer.writeAll(",{\"type\":\"null\"}]");
            try writeSchemaDefault(writer, default_value);
            try writer.writeAll("}");
        },
        .enumeration => |values| {
            try writer.writeAll("{\"type\":\"string\",\"enum\":[");
            for (values, 0..) |value, i| {
                if (i != 0) try writer.writeAll(",");
                try writeJsonString(writer, value);
            }
            try writer.writeAll("]");
            try writeSchemaDefault(writer, default_value);
            try writer.writeAll("}");
        },
        .object => |fields| {
            try writer.writeAll("{\"type\":\"object\",\"properties\":{");
            for (fields, 0..) |field, i| {
                if (i != 0) try writer.writeAll(",");
                try writeJsonString(writer, field.name);
                try writer.writeAll(":");
                try writeInlineSchemaWithDefault(writer, field.schema, field.default_value);
            }
            try writer.writeAll("}");

            var required_count: usize = 0;
            for (fields) |field| {
                if (field.required) required_count += 1;
            }
            if (required_count > 0) {
                try writer.writeAll(",\"required\":[");
                var required_index: usize = 0;
                for (fields) |field| {
                    if (field.required) {
                        if (required_index != 0) try writer.writeAll(",");
                        try writeJsonString(writer, field.name);
                        required_index += 1;
                    }
                }
                try writer.writeAll("]");
            }

            try writeSchemaDefault(writer, default_value);
            try writer.writeAll(",\"additionalProperties\":false}");
        },
    }
}

fn writeSchemaDefault(writer: anytype, default_value: ?DefaultValue) anyerror!void {
    if (default_value) |value| {
        try writer.writeAll(",\"default\":");
        try value.write(writer);
    }
}

fn writeSchemaRef(writer: *std.Io.Writer, name: []const u8) !void {
    try writer.writeAll("\"#/components/schemas/");
    try writeJsonStringContents(writer, name);
    try writer.writeAll("\"");
}

fn writeJsonString(writer: *std.Io.Writer, value: []const u8) !void {
    try writer.writeAll("\"");
    try writeJsonStringContents(writer, value);
    try writer.writeAll("\"");
}

fn writeJsonStringContents(writer: *std.Io.Writer, value: []const u8) !void {
    for (value) |ch| {
        switch (ch) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0x00...0x07 => try writer.print("\\u{x:0>4}", .{ch}),
            0x08 => try writer.writeAll("\\b"),
            0x0c => try writer.writeAll("\\f"),
            0x0e...0x1f => try writer.print("\\u{x:0>4}", .{ch}),
            else => try writer.writeByte(ch),
        }
    }
}

fn writeComponents(allocator: std.mem.Allocator, writer: *std.Io.Writer, app: *ZAPI) !void {
    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();

    var first = true;
    for (app.routes.items) |route_item| {
        if (!routeIncludedInOpenApi(route_item)) continue;
        if (routeHasValidationResponse(route_item.metadata) and route_item.metadata.status != .unprocessable_entity and !additionalResponseHasStatus(route_item.metadata, .unprocessable_entity)) {
            try writeComponentOnce(&seen, writer, schemaComponent(ProblemDetail), &first);
        }
        if (route_item.metadata.request_body_schema) |component| {
            try writeComponentOnce(&seen, writer, component, &first);
        }
        if (route_item.metadata.response_schema) |component| {
            try writeComponentOnce(&seen, writer, component, &first);
        }
        for (route_item.metadata.additional_responses) |response_doc| {
            if (response_doc.response_schema) |component| {
                try writeComponentOnce(&seen, writer, component, &first);
            }
        }
    }
}

fn appUsesSecurity(app: *ZAPI) bool {
    for (app.routes.items) |route_item| {
        if (!routeIncludedInOpenApi(route_item)) continue;
        if (route_item.metadata.requires_bearer_auth) return true;
        if (route_item.metadata.requires_basic_auth) return true;
        if (route_item.metadata.oauth2_password_bearer_auth.len > 0) return true;
        if (route_item.metadata.oauth2_authorization_code_bearer_auth.len > 0) return true;
        if (route_item.metadata.oauth2_client_credentials_bearer_auth.len > 0) return true;
        if (route_item.metadata.oauth2_implicit_bearer_auth.len > 0) return true;
        if (route_item.metadata.api_key_auth.len > 0) return true;
    }
    return false;
}

fn writeSecuritySchemes(allocator: std.mem.Allocator, writer: *std.Io.Writer, app: *ZAPI) !void {
    var first = true;
    if (appUsesBearerAuth(app)) {
        try writer.writeAll("\"BearerAuth\":{\"type\":\"http\",\"scheme\":\"bearer\"}");
        first = false;
    }
    if (appUsesBasicAuth(app)) {
        if (!first) try writer.writeAll(",");
        try writer.writeAll("\"BasicAuth\":{\"type\":\"http\",\"scheme\":\"basic\"}");
        first = false;
    }
    var seen_oauth2 = std.StringHashMap(void).init(allocator);
    defer seen_oauth2.deinit();

    for (app.routes.items) |route_item| {
        if (!routeIncludedInOpenApi(route_item)) continue;
        for (route_item.metadata.oauth2_password_bearer_auth) |oauth2| {
            if (seen_oauth2.contains(oauth2.scheme_name)) continue;
            try seen_oauth2.put(oauth2.scheme_name, {});
            if (!first) try writer.writeAll(",");
            try writeJsonString(writer, oauth2.scheme_name);
            try writer.writeAll(":{\"type\":\"oauth2\",\"flows\":{\"password\":{\"tokenUrl\":");
            try writeJsonString(writer, oauth2.token_url);
            try writer.writeAll(",\"scopes\":{");
            for (oauth2.scopes, 0..) |scope, i| {
                if (i != 0) try writer.writeAll(",");
                try writeJsonString(writer, scope.name);
                try writer.writeAll(":");
                try writeJsonString(writer, scope.description);
            }
            try writer.writeAll("}}}}");
            first = false;
        }
    }

    for (app.routes.items) |route_item| {
        if (!routeIncludedInOpenApi(route_item)) continue;
        for (route_item.metadata.oauth2_authorization_code_bearer_auth) |oauth2| {
            if (seen_oauth2.contains(oauth2.scheme_name)) continue;
            try seen_oauth2.put(oauth2.scheme_name, {});
            if (!first) try writer.writeAll(",");
            try writeJsonString(writer, oauth2.scheme_name);
            try writer.writeAll(":{\"type\":\"oauth2\",\"flows\":{\"authorizationCode\":{\"authorizationUrl\":");
            try writeJsonString(writer, oauth2.authorization_url);
            try writer.writeAll(",\"tokenUrl\":");
            try writeJsonString(writer, oauth2.token_url);
            try writer.writeAll(",\"scopes\":{");
            for (oauth2.scopes, 0..) |scope, i| {
                if (i != 0) try writer.writeAll(",");
                try writeJsonString(writer, scope.name);
                try writer.writeAll(":");
                try writeJsonString(writer, scope.description);
            }
            try writer.writeAll("}}}}");
            first = false;
        }
    }

    for (app.routes.items) |route_item| {
        if (!routeIncludedInOpenApi(route_item)) continue;
        for (route_item.metadata.oauth2_client_credentials_bearer_auth) |oauth2| {
            if (seen_oauth2.contains(oauth2.scheme_name)) continue;
            try seen_oauth2.put(oauth2.scheme_name, {});
            if (!first) try writer.writeAll(",");
            try writeJsonString(writer, oauth2.scheme_name);
            try writer.writeAll(":{\"type\":\"oauth2\",\"flows\":{\"clientCredentials\":{\"tokenUrl\":");
            try writeJsonString(writer, oauth2.token_url);
            try writer.writeAll(",\"scopes\":{");
            for (oauth2.scopes, 0..) |scope, i| {
                if (i != 0) try writer.writeAll(",");
                try writeJsonString(writer, scope.name);
                try writer.writeAll(":");
                try writeJsonString(writer, scope.description);
            }
            try writer.writeAll("}}}}");
            first = false;
        }
    }

    for (app.routes.items) |route_item| {
        if (!routeIncludedInOpenApi(route_item)) continue;
        for (route_item.metadata.oauth2_implicit_bearer_auth) |oauth2| {
            if (seen_oauth2.contains(oauth2.scheme_name)) continue;
            try seen_oauth2.put(oauth2.scheme_name, {});
            if (!first) try writer.writeAll(",");
            try writeJsonString(writer, oauth2.scheme_name);
            try writer.writeAll(":{\"type\":\"oauth2\",\"flows\":{\"implicit\":{\"authorizationUrl\":");
            try writeJsonString(writer, oauth2.authorization_url);
            try writer.writeAll(",\"scopes\":{");
            for (oauth2.scopes, 0..) |scope, i| {
                if (i != 0) try writer.writeAll(",");
                try writeJsonString(writer, scope.name);
                try writer.writeAll(":");
                try writeJsonString(writer, scope.description);
            }
            try writer.writeAll("}}}}");
            first = false;
        }
    }

    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();

    for (app.routes.items) |route_item| {
        if (!routeIncludedInOpenApi(route_item)) continue;
        for (route_item.metadata.api_key_auth) |api_key| {
            if (seen.contains(api_key.scheme_name)) continue;
            try seen.put(api_key.scheme_name, {});
            if (!first) try writer.writeAll(",");
            try writeJsonString(writer, api_key.scheme_name);
            try writer.writeAll(":{\"type\":\"apiKey\",\"in\":");
            try writeJsonString(writer, api_key.location.openapiText());
            try writer.writeAll(",\"name\":");
            try writeJsonString(writer, api_key.name);
            try writer.writeAll("}");
            first = false;
        }
    }
}

fn appUsesBearerAuth(app: *ZAPI) bool {
    for (app.routes.items) |route_item| {
        if (!routeIncludedInOpenApi(route_item)) continue;
        if (route_item.metadata.requires_bearer_auth) return true;
    }
    return false;
}

fn appUsesBasicAuth(app: *ZAPI) bool {
    for (app.routes.items) |route_item| {
        if (!routeIncludedInOpenApi(route_item)) continue;
        if (route_item.metadata.requires_basic_auth) return true;
    }
    return false;
}

fn apiKeySchemeAlreadyWritten(api_keys: []const ApiKeySecurityMetadata, index: usize) bool {
    for (api_keys[0..index]) |previous| {
        if (std.mem.eql(u8, previous.scheme_name, api_keys[index].scheme_name)) return true;
    }
    return false;
}

fn oauth2SchemeAlreadyWritten(schemes: []const OAuth2PasswordBearerSecurityMetadata, index: usize) bool {
    for (schemes[0..index]) |previous| {
        if (std.mem.eql(u8, previous.scheme_name, schemes[index].scheme_name)) return true;
    }
    return false;
}

fn oauth2AuthorizationCodeSchemeAlreadyWritten(schemes: []const OAuth2AuthorizationCodeBearerSecurityMetadata, index: usize) bool {
    for (schemes[0..index]) |previous| {
        if (std.mem.eql(u8, previous.scheme_name, schemes[index].scheme_name)) return true;
    }
    return false;
}

fn oauth2ClientCredentialsSchemeAlreadyWritten(schemes: []const OAuth2ClientCredentialsBearerSecurityMetadata, index: usize) bool {
    for (schemes[0..index]) |previous| {
        if (std.mem.eql(u8, previous.scheme_name, schemes[index].scheme_name)) return true;
    }
    return false;
}

fn oauth2ImplicitSchemeAlreadyWritten(schemes: []const OAuth2ImplicitBearerSecurityMetadata, index: usize) bool {
    for (schemes[0..index]) |previous| {
        if (std.mem.eql(u8, previous.scheme_name, schemes[index].scheme_name)) return true;
    }
    return false;
}

fn writeComponentOnce(seen: *std.StringHashMap(void), writer: *std.Io.Writer, component: SchemaComponent, first: *bool) !void {
    if (seen.contains(component.name)) return;
    try seen.put(component.name, {});
    if (!first.*) try writer.writeAll(",");
    try writeJsonString(writer, component.name);
    try writer.writeAll(":");
    try component.write(writer);
    first.* = false;
}

fn writeJsonSchema(comptime T: type, writer: *std.Io.Writer) !void {
    try writeJsonSchemaWithDefault(T, writer, null);
}

fn writeJsonSchemaWithDefault(comptime T: type, writer: *std.Io.Writer, default_value: ?DefaultValue) anyerror!void {
    if (T == UploadFile) {
        try writer.writeAll("{\"type\":\"string\",\"format\":\"binary\"");
        try writeSchemaDefault(writer, default_value);
        try writer.writeAll("}");
        return;
    }
    if (T == Uuid) {
        try writer.writeAll("{\"type\":\"string\",\"format\":\"uuid\"");
        try writeSchemaDefault(writer, default_value);
        try writer.writeAll("}");
        return;
    }
    if (T == Date) {
        try writer.writeAll("{\"type\":\"string\",\"format\":\"date\"");
        try writeSchemaDefault(writer, default_value);
        try writer.writeAll("}");
        return;
    }
    if (T == DateTime) {
        try writer.writeAll("{\"type\":\"string\",\"format\":\"date-time\"");
        try writeSchemaDefault(writer, default_value);
        try writer.writeAll("}");
        return;
    }
    if (T == Email) {
        try writer.writeAll("{\"type\":\"string\",\"format\":\"email\"");
        try writeSchemaDefault(writer, default_value);
        try writer.writeAll("}");
        return;
    }
    if (T == Url) {
        try writer.writeAll("{\"type\":\"string\",\"format\":\"uri\"");
        try writeSchemaDefault(writer, default_value);
        try writer.writeAll("}");
        return;
    }
    if (comptime jsonMapValueType(T)) |Value| {
        try writer.writeAll("{\"type\":\"object\",\"additionalProperties\":");
        try writeJsonSchema(Value, writer);
        try writeSchemaDefault(writer, default_value);
        try writer.writeAll("}");
        return;
    }

    switch (@typeInfo(T)) {
        .bool => {
            try writer.writeAll("{\"type\":\"boolean\"");
            try writeSchemaDefault(writer, default_value);
            try writer.writeAll("}");
        },
        .int, .comptime_int => {
            try writer.writeAll("{\"type\":\"integer\"");
            try writeSchemaDefault(writer, default_value);
            try writer.writeAll("}");
        },
        .float, .comptime_float => {
            try writer.writeAll("{\"type\":\"number\"");
            try writeSchemaDefault(writer, default_value);
            try writer.writeAll("}");
        },
        .pointer => |ptr| {
            if (ptr.size == .slice and ptr.child == u8) {
                try writer.writeAll("{\"type\":\"string\"");
                try writeSchemaDefault(writer, default_value);
                try writer.writeAll("}");
            } else {
                try writer.writeAll("{\"type\":\"array\",\"items\":");
                try writeJsonSchema(ptr.child, writer);
                try writeSchemaDefault(writer, default_value);
                try writer.writeAll("}");
            }
        },
        .array => |arr| {
            try writer.writeAll("{\"type\":\"array\",\"items\":");
            try writeJsonSchema(arr.child, writer);
            try writeSchemaDefault(writer, default_value);
            try writer.writeAll("}");
        },
        .optional => |opt| {
            try writer.writeAll("{\"anyOf\":[");
            try writeJsonSchema(opt.child, writer);
            try writer.writeAll(",{\"type\":\"null\"}]");
            try writeSchemaDefault(writer, default_value);
            try writer.writeAll("}");
        },
        .@"enum" => |enm| {
            try writer.writeAll("{\"type\":\"string\",\"enum\":[");
            inline for (enm.fields, 0..) |field, i| {
                if (i != 0) try writer.writeAll(",");
                try writeJsonString(writer, field.name);
            }
            try writer.writeAll("]");
            try writeSchemaDefault(writer, default_value);
            try writer.writeAll("}");
        },
        .@"struct" => |strct| {
            try writer.writeAll("{\"type\":\"object\",\"properties\":{");
            inline for (strct.fields, 0..) |field, i| {
                if (i != 0) try writer.writeAll(",");
                try writeJsonString(writer, field.name);
                try writer.writeAll(":");
                try writeJsonSchemaWithDefault(field.type, writer, defaultValueForField(field));
            }
            try writer.writeAll("}");

            var required_count: usize = 0;
            inline for (strct.fields) |field| {
                if (!isOptional(field.type) and field.default_value_ptr == null) required_count += 1;
            }
            if (required_count > 0) {
                try writer.writeAll(",\"required\":[");
                var required_index: usize = 0;
                inline for (strct.fields) |field| {
                    if (!isOptional(field.type) and field.default_value_ptr == null) {
                        if (required_index != 0) try writer.writeAll(",");
                        try writeJsonString(writer, field.name);
                        required_index += 1;
                    }
                }
                try writer.writeAll("]");
            }

            try writeSchemaDefault(writer, default_value);
            try writer.writeAll(",\"additionalProperties\":false}");
        },
        else => {
            try writer.writeAll("{\"type\":\"string\"");
            try writeSchemaDefault(writer, default_value);
            try writer.writeAll("}");
        },
    }
}

const writeSwaggerUiHtml = docs_ui.writeSwaggerUiHtml;
const writeSwaggerUiOAuth2RedirectHtml = docs_ui.writeSwaggerUiOAuth2RedirectHtml;
const writeRedocHtml = docs_ui.writeRedocHtml;

fn expectJsonEqual(expected_json: []const u8, actual_json: []const u8) !void {
    const expected = try std.json.parseFromSlice(std.json.Value, testing.allocator, expected_json, .{});
    defer expected.deinit();
    const actual = try std.json.parseFromSlice(std.json.Value, testing.allocator, actual_json, .{});
    defer actual.deinit();
    try testing.expect(jsonValueEql(expected.value, actual.value));
}

fn jsonValueEql(expected: std.json.Value, actual: std.json.Value) bool {
    if (std.meta.activeTag(expected) != std.meta.activeTag(actual)) return false;

    return switch (expected) {
        .null => true,
        .bool => |value| value == actual.bool,
        .integer => |value| value == actual.integer,
        .float => |value| value == actual.float,
        .number_string => |value| std.mem.eql(u8, value, actual.number_string),
        .string => |value| std.mem.eql(u8, value, actual.string),
        .array => |expected_array| blk: {
            const actual_array = actual.array;
            if (expected_array.items.len != actual_array.items.len) break :blk false;
            for (expected_array.items, actual_array.items) |expected_item, actual_item| {
                if (!jsonValueEql(expected_item, actual_item)) break :blk false;
            }
            break :blk true;
        },
        .object => |expected_object| blk: {
            const actual_object = actual.object;
            if (expected_object.count() != actual_object.count()) break :blk false;
            var it = expected_object.iterator();
            while (it.next()) |entry| {
                const actual_value = actual_object.get(entry.key_ptr.*) orelse break :blk false;
                if (!jsonValueEql(entry.value_ptr.*, actual_value)) break :blk false;
            }
            break :blk true;
        },
    };
}

const TestUser = struct {
    id: u64,
    email: []const u8,
};

const CreateUser = struct {
    email: []const u8,
};

const create_user_list_fixture = [_]CreateUser{
    .{ .email = "ada@example.com" },
    .{ .email = "grace@example.com" },
};

const ScoresMap = std.json.ArrayHashMap(u32);

const OptionalCreateResult = struct {
    email: ?[]const u8,
};

const UserList = struct {
    users: []const TestUser,
};

const EscapedMessage = struct {
    message: []const u8,
};

const DeprecatedMessage = struct {
    message: []const u8,
};

const InternalInput = struct {
    secret: []const u8,
};

const InternalOutput = struct {
    token: []const u8,
    secret: []const u8,
};

const HeaderEcho = struct {
    token: []const u8,
    debug: bool,
    retries: u8,
};

const MethodEcho = struct {
    method: []const u8,
};

const RequestPathParamEcho = struct {
    raw: []const u8,
    missing: bool,
    method: []const u8,
};

const RequestPathParamsEcho = struct {
    raw_item: []const u8,
    category: []const u8,
    item: []const u8,
    missing: bool,
    count: usize,
    first_name: []const u8,
    first_value: []const u8,
    second_name: []const u8,
    second_value: []const u8,
};

const NegotiationEcho = struct {
    content_type: ?[]const u8,
    has_json: bool,
    accepts_json: bool,
    accepts_html: bool,
    preferred: []const u8,
};

const ClientHeaderDefaultsEcho = struct {
    user_agent: ?[]const u8,
    accept: ?[]const u8,
    accept_encoding: ?[]const u8,
    connection: ?[]const u8,
};

const HeaderListEcho = struct {
    tokens: []const []const u8,
};

const UuidBody = struct {
    id: Uuid,
};

const UuidEcho = struct {
    id: Uuid,
};

const DateBody = struct {
    date: Date,
    timestamp: DateTime,
};

const DateEcho = struct {
    date: Date,
    timestamp: DateTime,
};

const EmailBody = struct {
    email: Email,
};

const EmailEcho = struct {
    email: Email,
};

const UrlBody = struct {
    url: Url,
};

const UrlScalarEcho = struct {
    url: Url,
};

const CookieEcho = struct {
    session_id: []const u8,
    preview: bool,
    visits: u8,
};

const ScopedCookieEcho = struct {
    scoped: ?[]const u8,
};

const AliasParamsEcho = struct {
    page_size: u32,
    token: []const u8,
    session: []const u8,
};

const LoginForm = struct {
    username: []const u8,
    password: []const u8,
    remember: bool = false,
    attempts: u8 = 1,
};

const LoginResult = struct {
    username: []const u8,
    remember: bool,
    attempts: u8,
};

const PreferencesForm = struct {
    username: []const u8,
    tag: []const []const u8,
    level: []const u32,
};

const PreferencesResult = struct {
    username: []const u8,
    tags: []const []const u8,
    levels: []const u32,
};

const ProfileUpload = struct {
    username: []const u8,
    avatar: UploadFile,
};

const UploadResult = struct {
    username: []const u8,
    filename: []const u8,
    content_type: []const u8,
    size: usize,
};

const GalleryUpload = struct {
    username: []const u8,
    photos: []const UploadFile,
};

const GalleryResult = struct {
    username: []const u8,
    first_filename: []const u8,
    second_filename: []const u8,
    total_size: usize,
};

const ErrorMessage = struct {
    detail: []const u8,
};

const JsonMessage = struct {
    message: []const u8,
};

const WebSocketJsonInput = struct {
    name: []const u8,
    count: u8,
};

const WebSocketJsonOutput = struct {
    name: []const u8,
    count: u8,
    token: ?[]const u8,
};

const MethodBodyEcho = struct {
    method: []const u8,
    body: []const u8,
};

const MethodBodyHeaderEcho = struct {
    method: []const u8,
    body: []const u8,
    content_type: ?[]const u8,
};

const RawBodyEcho = struct {
    text: []const u8,
    bytes_len: usize,
    content_len: usize,
};

const RedirectCookieEcho = struct {
    session: ?[]const u8,
    theme: ?[]const u8,
};

const AuthEcho = struct {
    token: []const u8,
};

const OAuth2TestAuth = OAuth2PasswordBearer(.{
    .token_url = "/token",
    .scopes = &[_]OAuth2Scope{
        .{ .name = "users:read", .description = "Read users" },
        .{ .name = "users:write", .description = "Write users" },
    },
});

const OAuth2AuthorizationCodeTestAuth = OAuth2AuthorizationCodeBearer(.{
    .authorization_url = "/authorize",
    .token_url = "/token",
    .scopes = &[_]OAuth2Scope{
        .{ .name = "profile", .description = "Read profile" },
        .{ .name = "email", .description = "Read email" },
    },
});

const OAuth2ClientCredentialsTestAuth = OAuth2ClientCredentialsBearer(.{
    .token_url = "/machine-token",
    .scopes = &[_]OAuth2Scope{
        .{ .name = "jobs:read", .description = "Read jobs" },
        .{ .name = "jobs:write", .description = "Write jobs" },
    },
});

const OAuth2ImplicitTestAuth = OAuth2ImplicitBearer(.{
    .authorization_url = "/authorize-implicit",
    .scopes = &[_]OAuth2Scope{
        .{ .name = "browser:read", .description = "Read browser data" },
        .{ .name = "browser:write", .description = "Write browser data" },
    },
});

const BasicAuthEcho = struct {
    username: []const u8,
    password: []const u8,
};

const BackgroundState = struct {
    count: usize = 0,
};

const TemplateState = struct {
    dir: std.Io.Dir,
};

const StreamingState = struct {
    chunks: []const []const u8,
    writes: usize = 0,
};

const RequestTraceState = struct {
    trace_id: []const u8,
    handler_seen: bool = false,
};

const LifecycleState = struct {
    events: std.ArrayList([]const u8) = .empty,
};

const PathEcho = struct {
    value: []const u8,
};

const FloatEcho = struct {
    value: f64,
};

const SearchUsersResult = struct {
    q: []const u8,
    limit: u32,
};

const TagSearchResult = struct {
    tags: []const []const u8,
    limits: []const u32,
};

const UserState = enum {
    active,
    disabled,
};

const StateEcho = struct {
    state: UserState,
};

const RequestScopeEcho = struct {
    scheme: []const u8,
    host: []const u8,
    root_path: []const u8,
};

const RequestTargetEcho = struct {
    scheme: []const u8,
    host: []const u8,
    root_path: []const u8,
    path: []const u8,
    query: []const u8,
};

const RequestClientEcho = struct {
    host: ?[]const u8,
    port: ?u16,
};

const UrlPathEcho = struct {
    path: []const u8,
};

const UrlEcho = struct {
    url: []const u8,
    request_url: []const u8,
};

const RequestUrlPartsEcho = struct {
    url: []const u8,
    url_path: []const u8,
    base_url: []const u8,
};

const RequestUrlMutationEcho = struct {
    included: []const u8,
    replaced: []const u8,
    removed: []const u8,
    path_included: []const u8,
    path_replaced: []const u8,
    path_removed: []const u8,
};

const NamedRootUrlEcho = struct {
    index: []const u8,
};

const MountedRootUrlEcho = struct {
    index: []const u8,
    submount: []const u8,
};

const HostedUrlEcho = struct {
    local_path: []const u8,
    local_url: []const u8,
    namespaced_url: []const u8,
};

const TenantPathEcho = struct {
    tenant: []const u8,
    id: u64,
    root_path: []const u8,
};

const SessionEcho = struct {
    user: ?[]const u8,
};

const RawRequestEcho = struct {
    item: []const u8,
    token: []const u8,
    tokens: []const []const u8,
    missing_header_count: usize,
    q: []const u8,
    tag: []const u8,
    tags: []const []const u8,
    empty: []const u8,
    missing_query: bool,
    theme: []const u8,
    session: []const u8,
    missing_cookie: bool,
};

const RawJsonInput = struct {
    name: []const u8,
    count: u8,
};

const RawJsonEcho = struct {
    name: []const u8,
    count: u8,
};

const RawFormEcho = struct {
    username: []const u8,
    tag: []const u8,
    tags: []const []const u8,
    empty: []const u8,
};

const RawMultipartEcho = struct {
    title: []const u8,
    filename: []const u8,
    content_type: []const u8,
    content: []const u8,
    file_count: usize,
};

const test_file_response_path = "zapi-file-response.txt";
const conditional_last_modified_seconds: i64 = 1_700_000_000;
const repeated_sse_events = [_]ServerSentEvent{.{ .data = "zapi" }} ** 80;
const rich_sse_events = [_]ServerSentEvent{
    .{ .comment = "connected" },
    .{
        .event = "message",
        .id = "42",
        .retry = 1500,
        .data = "hello\nworld\r\nagain",
    },
    .{ .data = "" },
};
const template_page_context = [_]TemplateValue{
    .{ .name = "title", .value = "Hello <Zig>" },
    .{ .name = "body", .value = "<strong>trusted</strong>", .escape = false },
};

fn hello(ctx: *Context) !struct { message: []const u8 } {
    _ = ctx;
    return .{ .message = "Hello from Zig" };
}

fn escapedHello(ctx: *Context) !EscapedMessage {
    _ = ctx;
    return .{ .message = "ok" };
}

fn deprecatedMessage(ctx: *Context) !DeprecatedMessage {
    _ = ctx;
    return .{ .message = "old" };
}

fn hiddenInternal(ctx: *Context, auth: BearerAuth, body: Body(InternalInput)) !InternalOutput {
    _ = ctx;
    return .{
        .token = auth.token,
        .secret = body.value.secret,
    };
}

fn createUser(ctx: *Context, body: Body(CreateUser)) !TestUser {
    _ = ctx;
    return .{ .id = 1, .email = body.value.email };
}

fn maybeCreateUser(ctx: *Context, body: Body(?CreateUser)) !OptionalCreateResult {
    _ = ctx;
    return .{ .email = if (body.value) |value| value.email else null };
}

fn echoCreateUsers(ctx: *Context, body: Body([]const CreateUser)) ![]const CreateUser {
    _ = ctx;
    return body.value;
}

fn listCreateUsers(ctx: *Context) ![]const CreateUser {
    _ = ctx;
    return create_user_list_fixture[0..];
}

fn echoScores(ctx: *Context, body: Body(ScoresMap)) !ScoresMap {
    _ = ctx;
    return body.value;
}

fn listUsers(ctx: *Context) !UserList {
    _ = ctx;
    return .{ .users = &.{.{ .id = 1, .email = "ada@example.com" }} };
}

fn getUser(ctx: *Context, path: Path(struct { id: u64 }), query: Query(struct { verbose: ?bool = null })) !TestUser {
    _ = ctx;
    _ = query;
    return .{ .id = path.value.id, .email = "ada@example.com" };
}

fn maybeGetUser(ctx: *Context) !?TestUser {
    _ = ctx;
    return null;
}

fn noBodyUser(ctx: *Context, path: Path(struct { id: u64 })) !TestUser {
    _ = ctx;
    _ = path;
    return .{ .id = 1, .email = "ada@example.com" };
}

fn disableUser(ctx: *Context, path: Path(struct { username: []const u8 })) !PathEcho {
    _ = ctx;
    return .{ .value = path.value.username };
}

fn getPathTail(ctx: *Context, path: Path(struct { rest: []const u8 })) !PathEcho {
    _ = ctx;
    return .{ .value = path.value.rest };
}

fn getUuid(ctx: *Context, path: Path(struct { id: []const u8 })) !PathEcho {
    _ = ctx;
    return .{ .value = path.value.id };
}

fn getFloat(ctx: *Context, path: Path(struct { value: f64 })) !FloatEcho {
    _ = ctx;
    return .{ .value = path.value.value };
}

fn getSlug(ctx: *Context, path: Path(struct { slug: []const u8 })) !PathEcho {
    _ = ctx;
    return .{ .value = path.value.slug };
}

fn slugMatches(value: []const u8) bool {
    if (value.len == 0) return false;
    if (value[0] == '-' or value[value.len - 1] == '-') return false;
    for (value) |ch| {
        if (std.ascii.isLower(ch) or std.ascii.isDigit(ch) or ch == '-') continue;
        return false;
    }
    return true;
}

fn slugWithoutDigitsMatches(value: []const u8) bool {
    if (value.len == 0) return false;
    if (value[0] == '-' or value[value.len - 1] == '-') return false;
    for (value) |ch| {
        if (std.ascii.isLower(ch) or ch == '-') continue;
        return false;
    }
    return true;
}

fn mountedTenantUser(ctx: *Context, path: Path(struct { tenant: []const u8, id: u64 })) !TenantPathEcho {
    return .{
        .tenant = path.value.tenant,
        .id = path.value.id,
        .root_path = ctx.request.root_path,
    };
}

fn echoRequestMethod(ctx: *Context) !MethodEcho {
    return .{ .method = ctx.request.method.text() };
}

fn echoRequestArgumentMethod(request: Request) !MethodEcho {
    return .{ .method = request.method.text() };
}

fn echoRequestPathParams(request: Request) !RequestPathParamEcho {
    return .{
        .raw = request.pathValue("item") orelse "",
        .missing = request.pathValue("missing") == null,
        .method = request.method.text(),
    };
}

fn echoDecodedRequestPathParam(ctx: *Context, request: Request) !ResponsePayload {
    const item = try request.pathParam(ctx.allocator, "item") orelse try ctx.allocator.dupe(u8, "");
    defer ctx.allocator.free(item);

    var body = std.Io.Writer.Allocating.init(ctx.allocator);
    errdefer body.deinit();
    try std.json.Stringify.value(PathEcho{ .value = item }, .{}, &body.writer);

    return .{
        .content_type = "application/json",
        .body = try body.toOwnedSlice(),
        .owned_body = true,
    };
}

fn echoDecodedRequestPathParams(ctx: *Context) !ResponsePayload {
    var params = try ctx.pathParams();
    defer params.deinit();

    const items = params.multiItems();
    var body = std.Io.Writer.Allocating.init(ctx.allocator);
    errdefer body.deinit();
    try std.json.Stringify.value(RequestPathParamsEcho{
        .raw_item = ctx.pathValue("item") orelse "",
        .category = params.get("category") orelse "",
        .item = params.get("item") orelse "",
        .missing = params.get("missing") == null,
        .count = items.len,
        .first_name = if (items.len > 0) items[0].name else "",
        .first_value = if (items.len > 0) items[0].value else "",
        .second_name = if (items.len > 1) items[1].name else "",
        .second_value = if (items.len > 1) items[1].value else "",
    }, .{}, &body.writer);

    return .{
        .content_type = "application/json",
        .body = try body.toOwnedSlice(),
        .owned_body = true,
    };
}

fn echoNegotiation(request: Request) !NegotiationEcho {
    return .{
        .content_type = request.contentType(),
        .has_json = request.hasContentType("application/json"),
        .accepts_json = request.accepts("application/json"),
        .accepts_html = request.accepts("text/html"),
        .preferred = request.preferredAccepted(&.{ "application/json", "text/html", "text/plain" }) orelse "none",
    };
}

fn searchUsers(ctx: *Context, query: Query(struct { q: []const u8, limit: u32 = 10 })) !SearchUsersResult {
    _ = ctx;
    return .{ .q = query.value.q, .limit = query.value.limit };
}

fn searchTags(ctx: *Context, query: Query(struct { tag: []const []const u8, limit: []const u32 = &.{10} })) !TagSearchResult {
    _ = ctx;
    return .{
        .tags = query.value.tag,
        .limits = query.value.limit,
    };
}

fn echoRawRequest(ctx: *Context) !ResponsePayload {
    const item = try ctx.pathParam("item") orelse try ctx.allocator.dupe(u8, "");
    defer ctx.allocator.free(item);
    var query_params = try ctx.request.queryParams(ctx.allocator);
    defer query_params.deinit();
    var cookies = try ctx.request.cookies(ctx.allocator);
    defer cookies.deinit();
    const tokens = try ctx.request.headerValues(ctx.allocator, "x-token");
    defer ctx.allocator.free(tokens);
    const missing_headers = try ctx.request.headerValues(ctx.allocator, "x-missing");
    defer ctx.allocator.free(missing_headers);

    var body = std.Io.Writer.Allocating.init(ctx.allocator);
    errdefer body.deinit();
    try std.json.Stringify.value(RawRequestEcho{
        .item = item,
        .token = ctx.request.header("x-token") orelse "",
        .tokens = tokens,
        .missing_header_count = missing_headers.len,
        .q = query_params.get("q") orelse "",
        .tag = query_params.get("tag") orelse "",
        .tags = query_params.getAll("tag") orelse &.{},
        .empty = query_params.get("empty") orelse "",
        .missing_query = query_params.get("missing") == null,
        .theme = cookies.get("theme") orelse "",
        .session = cookies.get("session_id") orelse "",
        .missing_cookie = cookies.get("missing") == null,
    }, .{}, &body.writer);

    return .{
        .content_type = "application/json",
        .body = try body.toOwnedSlice(),
        .owned_body = true,
    };
}

fn echoRawJson(ctx: *Context) !ResponsePayload {
    const parsed = try ctx.request.json(RawJsonInput, ctx.allocator);
    defer parsed.deinit();

    var body = std.Io.Writer.Allocating.init(ctx.allocator);
    errdefer body.deinit();
    try std.json.Stringify.value(RawJsonEcho{
        .name = parsed.value.name,
        .count = parsed.value.count,
    }, .{}, &body.writer);

    return .{
        .content_type = "application/json",
        .body = try body.toOwnedSlice(),
        .owned_body = true,
    };
}

fn echoRawBody(ctx: *Context) !ResponsePayload {
    var body = std.Io.Writer.Allocating.init(ctx.allocator);
    errdefer body.deinit();
    try std.json.Stringify.value(RawBodyEcho{
        .text = ctx.request.text(),
        .bytes_len = ctx.request.bytes().len,
        .content_len = ctx.request.content().len,
    }, .{}, &body.writer);

    return .{
        .content_type = "application/json",
        .body = try body.toOwnedSlice(),
        .owned_body = true,
    };
}

fn echoRawForm(ctx: *Context) !ResponsePayload {
    var form = try ctx.request.formParams(ctx.allocator);
    defer form.deinit();

    var body = std.Io.Writer.Allocating.init(ctx.allocator);
    errdefer body.deinit();
    try std.json.Stringify.value(RawFormEcho{
        .username = form.get("username") orelse "",
        .tag = form.get("tag") orelse "",
        .tags = form.getAll("tag") orelse &.{},
        .empty = form.get("empty") orelse "",
    }, .{}, &body.writer);

    return .{
        .content_type = "application/json",
        .body = try body.toOwnedSlice(),
        .owned_body = true,
    };
}

fn echoRawFormData(ctx: *Context) !ResponsePayload {
    var form = try ctx.request.formData(ctx.allocator);
    defer form.deinit();

    const file = form.getFile("document") orelse return error.Validation;
    const files = form.getAll("document") orelse &.{};

    var body = std.Io.Writer.Allocating.init(ctx.allocator);
    errdefer body.deinit();
    try std.json.Stringify.value(RawMultipartEcho{
        .title = form.getText("title") orelse "",
        .filename = file.filename,
        .content_type = file.content_type,
        .content = file.content,
        .file_count = files.len,
    }, .{}, &body.writer);

    return .{
        .content_type = "application/json",
        .body = try body.toOwnedSlice(),
        .owned_body = true,
    };
}

fn echoQueryState(ctx: *Context, query: Query(struct { state: UserState })) !StateEcho {
    _ = ctx;
    return .{ .state = query.value.state };
}

fn echoPathState(ctx: *Context, path: Path(struct { state: UserState })) !StateEcho {
    _ = ctx;
    return .{ .state = path.value.state };
}

fn echoRequestScope(ctx: *Context) !RequestScopeEcho {
    return .{
        .scheme = ctx.request.scheme,
        .host = ctx.request.header("host") orelse "",
        .root_path = ctx.request.root_path,
    };
}

fn echoRequestTarget(ctx: *Context) !RequestTargetEcho {
    return .{
        .scheme = ctx.request.scheme,
        .host = ctx.request.header("host") orelse "",
        .root_path = ctx.request.root_path,
        .path = ctx.request.path,
        .query = ctx.request.query,
    };
}

fn echoQueryHeader(ctx: *Context) !ResponsePayload {
    var payload = ResponsePayload{ .content_type = "text/plain", .body = "" };
    try payload.setHeader(ctx.allocator, "x-query", ctx.request.query);
    return payload;
}

fn echoRequestClient(ctx: *Context) !RequestClientEcho {
    if (ctx.request.client) |client| {
        return .{ .host = client.host, .port = client.port };
    }
    return .{ .host = null, .port = null };
}

fn echoHeaders(ctx: *Context, headers: Header(struct { x_token: []const u8, x_debug: bool = false, x_retries: u8 })) !HeaderEcho {
    _ = ctx;
    return .{
        .token = headers.value.x_token,
        .debug = headers.value.x_debug,
        .retries = headers.value.x_retries,
    };
}

fn echoClientHeaderDefaults(ctx: *Context) !ClientHeaderDefaultsEcho {
    return .{
        .user_agent = ctx.request.header("user-agent"),
        .accept = ctx.request.header("accept"),
        .accept_encoding = ctx.request.header("accept-encoding"),
        .connection = ctx.request.header("connection"),
    };
}

fn echoHeaderList(ctx: *Context, headers: Header(struct { x_token: []const []const u8 })) !HeaderListEcho {
    _ = ctx;
    return .{
        .tokens = headers.value.x_token,
    };
}

fn echoCookies(ctx: *Context, cookies: Cookie(struct { session_id: []const u8, preview: bool = false, visits: u8 })) !CookieEcho {
    _ = ctx;
    return .{
        .session_id = cookies.value.session_id,
        .preview = cookies.value.preview,
        .visits = cookies.value.visits,
    };
}

fn echoAliasParams(
    ctx: *Context,
    query: Query(struct { page_size: u32 }),
    headers: Header(struct { api_key: []const u8 }),
    cookies: Cookie(struct { session_id: []const u8 }),
) !AliasParamsEcho {
    _ = ctx;
    return .{
        .page_size = query.value.page_size,
        .token = headers.value.api_key,
        .session = cookies.value.session_id,
    };
}

fn login(ctx: *Context, form: Form(LoginForm)) !LoginResult {
    _ = ctx;
    _ = form.value.password;
    return .{
        .username = form.value.username,
        .remember = form.value.remember,
        .attempts = form.value.attempts,
    };
}

fn preferences(ctx: *Context, form: Form(PreferencesForm)) !PreferencesResult {
    _ = ctx;
    return .{
        .username = form.value.username,
        .tags = form.value.tag,
        .levels = form.value.level,
    };
}

fn uploadProfile(ctx: *Context, form: Form(ProfileUpload)) !UploadResult {
    _ = ctx;
    return .{
        .username = form.value.username,
        .filename = form.value.avatar.filename,
        .content_type = form.value.avatar.content_type,
        .size = form.value.avatar.content.len,
    };
}

fn uploadGallery(ctx: *Context, form: Form(GalleryUpload)) !GalleryResult {
    _ = ctx;
    if (form.value.photos.len < 2) return error.Validation;

    var total_size: usize = 0;
    for (form.value.photos) |photo| {
        total_size += photo.content.len;
    }

    return .{
        .username = form.value.username,
        .first_filename = form.value.photos[0].filename,
        .second_filename = form.value.photos[1].filename,
        .total_size = total_size,
    };
}

fn secureMe(ctx: *Context, auth: BearerAuth) !AuthEcho {
    _ = ctx;
    return .{ .token = auth.token };
}

fn secureOAuth2(ctx: *Context, auth: OAuth2TestAuth) !AuthEcho {
    _ = ctx;
    return .{ .token = auth.token };
}

fn secureOAuth2AuthorizationCode(ctx: *Context, auth: OAuth2AuthorizationCodeTestAuth) !AuthEcho {
    _ = ctx;
    return .{ .token = auth.token };
}

fn secureOAuth2ClientCredentials(ctx: *Context, auth: OAuth2ClientCredentialsTestAuth) !AuthEcho {
    _ = ctx;
    return .{ .token = auth.token };
}

fn secureOAuth2Implicit(ctx: *Context, auth: OAuth2ImplicitTestAuth) !AuthEcho {
    _ = ctx;
    return .{ .token = auth.token };
}

fn secureBasic(ctx: *Context, auth: BasicAuth) !BasicAuthEcho {
    _ = ctx;
    return .{ .username = auth.username, .password = auth.password };
}

fn secureHeaderKey(ctx: *Context, auth: ApiKeyHeader("x-api-key")) !AuthEcho {
    _ = ctx;
    return .{ .token = auth.key };
}

fn secureQueryKey(ctx: *Context, auth: ApiKeyQuery("api_key")) !AuthEcho {
    _ = ctx;
    return .{ .token = auth.key };
}

fn secureCookieKey(ctx: *Context, auth: ApiKeyCookie("session")) !AuthEcho {
    _ = ctx;
    return .{ .token = auth.key };
}

fn userWithHeaders(
    ctx: *Context,
    path: Path(struct { id: u64 }),
    query: Query(struct { verbose: ?bool = null }),
    headers: Header(struct { x_token: []const u8 }),
) !TestUser {
    _ = ctx;
    _ = query;
    _ = headers;
    return .{ .id = path.value.id, .email = "ada@example.com" };
}

fn userWithCookies(
    ctx: *Context,
    path: Path(struct { id: u64 }),
    cookies: Cookie(struct { session_id: []const u8 }),
) !TestUser {
    _ = ctx;
    _ = cookies;
    return .{ .id = path.value.id, .email = "ada@example.com" };
}

fn plainText(ctx: *Context) !Text {
    _ = ctx;
    return .{ .text = "Hello, world" };
}

fn invalidResponseHeader(ctx: *Context) !Text {
    _ = ctx;
    return .{
        .text = "unsafe",
        .headers = &.{.{ .name = "x-safe", .value = "ok\r\nx-injected: yes" }},
    };
}

fn conflictingContentLength(ctx: *Context) !Text {
    _ = ctx;
    return .{
        .text = "Hello, world",
        .headers = &.{.{ .name = "content-length", .value = "999" }},
    };
}

fn explicitContentTypeText(ctx: *Context) !Text {
    _ = ctx;
    return .{
        .text = "typed",
        .headers = &.{.{ .name = "content-type", .value = "text/x-zapi" }},
    };
}

fn explicitContentTypePayload(ctx: *Context) !ResponsePayload {
    _ = ctx;
    return .{
        .headers = &.{.{ .name = "content-type", .value = "text/x-payload" }},
        .body = "payload",
    };
}

fn bodySize(ctx: *Context) !struct { size: usize } {
    return .{ .size = ctx.request.body.len };
}

fn streamBody(ctx: *Context) !ResponsePayload {
    var stream = ctx.request.stream(.{ .chunk_size = 3 });

    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(ctx.allocator);

    var body = std.Io.Writer.Allocating.init(ctx.allocator);
    errdefer body.deinit();

    try body.writer.writeAll("{\"chunks\":[");
    var first = true;
    while (stream.next()) |chunk| {
        if (first) {
            first = false;
        } else {
            try body.writer.writeByte(',');
        }
        try writeJsonString(&body.writer, chunk);
        try joined.appendSlice(ctx.allocator, chunk);
    }
    try body.writer.writeAll("],\"joined\":");
    try writeJsonString(&body.writer, joined.items);
    try body.writer.writeByte('}');

    const owned_body = try body.toOwnedSlice();
    return .{
        .content_type = "application/json",
        .body = owned_body,
        .owned_body = true,
    };
}

fn streamReaderBody(ctx: *Context) !ResponsePayload {
    var reader = ctx.request.streamReader() orelse return error.Validation;

    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(ctx.allocator);

    var body = std.Io.Writer.Allocating.init(ctx.allocator);
    errdefer body.deinit();

    try body.writer.writeAll("{\"chunks\":[");
    var first = true;
    var chunk: [3]u8 = undefined;
    while (true) {
        const n = try reader.read(&chunk);
        if (n == 0) break;
        if (first) {
            first = false;
        } else {
            try body.writer.writeByte(',');
        }
        try writeJsonString(&body.writer, chunk[0..n]);
        try joined.appendSlice(ctx.allocator, chunk[0..n]);
    }
    try body.writer.writeAll("],\"joined\":");
    try writeJsonString(&body.writer, joined.items);
    try body.writer.writeByte('}');

    const owned_body = try body.toOwnedSlice();
    return .{
        .content_type = "application/json",
        .body = owned_body,
        .owned_body = true,
    };
}

fn hostText(ctx: *Context) !Text {
    _ = ctx;
    return .{ .text = "hosted" };
}

fn hostParamEcho(ctx: *Context, path: Path(struct { subdomain: []const u8 })) !PathEcho {
    _ = ctx;
    return .{ .value = path.value.subdomain };
}

fn hostedUrlEcho(ctx: *Context) !ResponsePayload {
    const local_path = try ctx.urlPathFor("users", .{});
    defer ctx.allocator.free(local_path);
    const local_url = try ctx.urlFor("users", .{});
    defer ctx.allocator.free(local_url);
    const namespaced_url = try ctx.urlFor("api:users", .{});
    defer ctx.allocator.free(namespaced_url);

    var body = std.Io.Writer.Allocating.init(ctx.allocator);
    errdefer body.deinit();
    try std.json.Stringify.value(HostedUrlEcho{
        .local_path = local_path,
        .local_url = local_url,
        .namespaced_url = namespaced_url,
    }, .{}, &body.writer);
    return .{
        .content_type = "application/json",
        .body = try body.toOwnedSlice(),
        .owned_body = true,
    };
}

fn echoRequestState(ctx: *Context) !struct { trace_id: []const u8 } {
    const state = ctx.requestState(RequestTraceState);
    state.handler_seen = true;
    return .{ .trace_id = state.trace_id };
}

fn echoMaybeState(ctx: *Context) !struct {
    app_state: bool,
    context_state: bool,
    request_state: bool,
    trace_id: ?[]const u8,
} {
    const request_state = ctx.maybeRequestState(RequestTraceState);
    if (request_state) |state| state.handler_seen = true;
    return .{
        .app_state = ctx.app.maybeState(BackgroundState) != null,
        .context_state = ctx.maybeState(BackgroundState) != null,
        .request_state = request_state != null,
        .trace_id = if (request_state) |state| state.trace_id else null,
    };
}

fn echoUuid(
    ctx: *Context,
    path: Path(struct { id: Uuid }),
    query: Query(struct { trace_id: ?Uuid = null }),
) !UuidEcho {
    _ = ctx;
    return .{ .id = query.value.trace_id orelse path.value.id };
}

fn createUuid(ctx: *Context, body: Body(UuidBody)) !UuidEcho {
    _ = ctx;
    return .{ .id = body.value.id };
}

fn echoDate(
    ctx: *Context,
    query: Query(struct {
        date: Date,
        timestamp: DateTime,
    }),
) !DateEcho {
    _ = ctx;
    return .{ .date = query.value.date, .timestamp = query.value.timestamp };
}

fn createDate(ctx: *Context, body: Body(DateBody)) !DateEcho {
    _ = ctx;
    return .{ .date = body.value.date, .timestamp = body.value.timestamp };
}

fn echoEmail(ctx: *Context, query: Query(struct { email: Email })) !EmailEcho {
    _ = ctx;
    return .{ .email = query.value.email };
}

fn createEmail(ctx: *Context, body: Body(EmailBody)) !EmailEcho {
    _ = ctx;
    return .{ .email = body.value.email };
}

fn echoUrlScalar(ctx: *Context, query: Query(struct { url: Url })) !UrlScalarEcho {
    _ = ctx;
    return .{ .url = query.value.url };
}

fn createUrlScalar(ctx: *Context, body: Body(UrlBody)) !UrlScalarEcho {
    _ = ctx;
    return .{ .url = body.value.url };
}

fn setSessionUser(ctx: *Context) !Text {
    try ctx.session().put("user", "ada");
    return .{ .text = "set" };
}

fn readSessionUser(ctx: *Context) !SessionEcho {
    return .{ .user = ctx.session().get("user") };
}

fn clearSessionUser(ctx: *Context) !Text {
    ctx.session().clear();
    return .{ .text = "cleared" };
}

fn largePlainText(ctx: *Context) !Text {
    _ = ctx;
    return .{ .text = "zapi " ** 200 };
}

fn varyingLargePlainText(ctx: *Context) !Text {
    _ = ctx;
    return .{
        .text = "zapi " ** 200,
        .headers = &.{.{ .name = "vary", .value = "Accept-Language" }},
    };
}

fn eventStream(ctx: *Context) !EventStream {
    _ = ctx;
    return .{
        .events = &repeated_sse_events,
    };
}

fn richEventStream(ctx: *Context) !EventStream {
    _ = ctx;
    return .{
        .status = .accepted,
        .headers = &.{.{ .name = "x-events", .value = "yes" }},
        .events = &rich_sse_events,
    };
}

fn streamingPlainText(ctx: *Context) !StreamingResponse {
    return .{
        .status = .accepted,
        .content_type = "text/plain; charset=utf-8",
        .headers = &.{.{ .name = "x-stream", .value = "yes" }},
        .context = ctx.state(StreamingState),
        .write = writeStreamingState,
    };
}

fn writeStreamingState(context: ?*anyopaque, writer: *std.Io.Writer) !void {
    const state: *StreamingState = @ptrCast(@alignCast(context.?));
    for (state.chunks) |chunk| {
        try writer.writeAll(chunk);
        try writer.flush();
        state.writes += 1;
    }
}

fn websocketEcho(ctx: *WebSocketContext) !void {
    const message = try ctx.readSmallMessage();
    const room = ctx.pathValue("room") orelse "default";
    var body = std.Io.Writer.Allocating.init(ctx.allocator);
    defer body.deinit();
    try body.writer.print("{s}:{s}", .{ room, message.data });
    try ctx.sendText(body.written());
}

fn websocketDoubleEcho(ctx: *WebSocketContext) !void {
    const first = try ctx.readSmallMessage();
    const second = try ctx.readSmallMessage();
    try ctx.sendText(first.data);
    try ctx.sendBinary(second.data);
}

fn websocketJsonEcho(ctx: *WebSocketContext) !void {
    const message = try ctx.readSmallMessage();
    const parsed = try std.json.parseFromSlice(WebSocketJsonInput, ctx.allocator, message.data, .{});
    defer parsed.deinit();

    var body = std.Io.Writer.Allocating.init(ctx.allocator);
    defer body.deinit();
    try std.json.Stringify.value(WebSocketJsonOutput{
        .name = parsed.value.name,
        .count = parsed.value.count,
        .token = ctx.request.header("x-token"),
    }, .{}, &body.writer);
    try ctx.sendText(body.written());
}

fn websocketRequestEcho(ctx: *WebSocketContext) !void {
    const message = try ctx.readSmallMessage();
    const host = ctx.request.header("host") orelse "";
    const cookie = ctx.request.header("cookie") orelse "";
    const token = ctx.request.header("x-token") orelse "";
    var body = std.Io.Writer.Allocating.init(ctx.allocator);
    defer body.deinit();
    try body.writer.print("{s}|{s}|{s}|{s}|{s}|{s}", .{
        ctx.request.path,
        ctx.request.query,
        host,
        cookie,
        token,
        message.data,
    });
    try ctx.sendText(body.written());
}

fn alreadyEncoded(ctx: *Context) !ResponsePayload {
    _ = ctx;
    return .{
        .content_type = "text/plain; charset=utf-8",
        .headers = &.{.{ .name = "content-encoding", .value = "br" }},
        .body = "encoded " ** 100,
    };
}

fn htmlPage(ctx: *Context) !Html {
    _ = ctx;
    return .{
        .html = "<h1>Hello</h1>",
        .headers = &.{.{ .name = "x-html", .value = "yes" }},
    };
}

fn templatePage(ctx: *Context) !Template {
    const state = ctx.state(TemplateState);
    return .{
        .path = "pages/home.html",
        .dir = state.dir,
        .status = .accepted,
        .headers = &.{.{ .name = "x-template", .value = "yes" }},
        .context = &template_page_context,
    };
}

fn missingTemplateValue(ctx: *Context) !Template {
    const state = ctx.state(TemplateState);
    return .{
        .path = "pages/missing-value.html",
        .dir = state.dir,
    };
}

fn binaryData(ctx: *Context) !Bytes {
    _ = ctx;
    return .{
        .bytes = "\x00\x01zapi",
        .content_type = "application/x-zapi-bytes",
        .headers = &.{.{ .name = "x-bytes", .value = "yes" }},
    };
}

fn explicitJson(ctx: *Context) !Json(JsonMessage) {
    _ = ctx;
    return .{
        .value = .{ .message = "explicit" },
        .status = .accepted,
        .headers = &.{.{ .name = "x-json", .value = "yes" }},
    };
}

fn explicitRawJson(ctx: *Context) !RawJson {
    _ = ctx;
    return .{
        .json = "{\"message\":\"raw\"}",
        .status = .created,
        .headers = &.{.{ .name = "x-json", .value = "raw" }},
    };
}

fn explicitHead(ctx: *Context) !Text {
    _ = ctx;
    return .{
        .text = "HEAD only",
        .status = .accepted,
        .headers = &.{.{ .name = "x-head", .value = "explicit" }},
    };
}

fn downloadFile(ctx: *Context) !File {
    _ = ctx;
    return .{
        .path = test_file_response_path,
        .content_type = "text/plain; charset=utf-8",
        .filename = "notes.txt",
        .headers = &.{.{ .name = "x-file", .value = "yes" }},
    };
}

fn inlineFile(ctx: *Context) !File {
    _ = ctx;
    return .{
        .path = test_file_response_path,
        .content_type = "text/plain; charset=utf-8",
        .filename = "notes.txt",
        .content_disposition = .@"inline",
    };
}

fn unicodeFilenameFile(ctx: *Context) !File {
    _ = ctx;
    return .{
        .path = test_file_response_path,
        .content_type = "text/plain; charset=utf-8",
        .filename = "\xe4\xbd\xa0\xe5\xa5\xbd.txt",
    };
}

fn inferredFile(ctx: *Context) !File {
    _ = ctx;
    return .{
        .path = test_file_response_path,
    };
}

fn filenameInferredFile(ctx: *Context) !File {
    _ = ctx;
    return .{
        .path = test_file_response_path,
        .filename = "style.css",
    };
}

fn explicitOctetFile(ctx: *Context) !File {
    _ = ctx;
    return .{
        .path = test_file_response_path,
        .content_type = "application/octet-stream",
    };
}

fn metadataOnlyFile(ctx: *Context) !File {
    _ = ctx;
    return .{
        .path = test_file_response_path,
        .max_size = .limited(0),
    };
}

fn backgroundFile(ctx: *Context) !File {
    const state = ctx.state(BackgroundState);
    const tasks = try ctx.allocator.alloc(BackgroundTask, 1);
    errdefer ctx.allocator.free(tasks);
    tasks[0] = .{ .run = incrementBackgroundTask, .context = state };
    return .{
        .path = test_file_response_path,
        .background_tasks = tasks,
        .owned_background_tasks = true,
    };
}

fn customHeaderFile(ctx: *Context) !File {
    _ = ctx;
    return .{
        .path = test_file_response_path,
        .content_type = "text/plain; charset=utf-8",
        .filename = "notes.txt",
        .headers = &.{
            .{ .name = "content-disposition", .value = "attachment; filename=\"custom.txt\"" },
            .{ .name = "accept-ranges", .value = "none" },
        },
    };
}

fn customValidatorFile(ctx: *Context) !File {
    _ = ctx;
    return .{
        .path = test_file_response_path,
        .content_type = "text/plain; charset=utf-8",
        .headers = &.{
            .{ .name = "etag", .value = "\"custom-etag\"" },
        },
    };
}

fn missingFile(ctx: *Context) !File {
    _ = ctx;
    return .{
        .path = "zapi-missing-file-response.txt",
        .content_type = "text/plain; charset=utf-8",
    };
}

fn redirectToUsers(ctx: *Context) !Redirect {
    _ = ctx;
    return .{ .location = "/users" };
}

fn redirectToQuotedPath(ctx: *Context) !Redirect {
    _ = ctx;
    return .{ .location = "/quoted/I \xe2\x99\xa5 Zapi/" };
}

fn relativeDotRedirect(ctx: *Context) !Redirect {
    _ = ctx;
    return .{ .location = "../new/./target?x=1" };
}

fn foundRedirectToUsers(ctx: *Context) !Redirect {
    _ = ctx;
    return .{ .location = "/users", .status = .found };
}

fn foundRedirectToRequestHeaders(ctx: *Context) !Redirect {
    _ = ctx;
    return .{ .location = "/echo-request-headers", .status = .found };
}

fn movedRedirectToUsers(ctx: *Context) !Redirect {
    _ = ctx;
    return .{ .location = "/users", .status = .moved_permanently };
}

fn seeOtherRedirectToUsers(ctx: *Context) !Redirect {
    _ = ctx;
    return .{ .location = "/users", .status = .see_other };
}

fn absoluteDotRedirect(ctx: *Context) !Redirect {
    _ = ctx;
    return .{ .location = "https://example.test/old/../new/target?abs=1", .status = .found };
}

fn schemeRelativeRedirect(ctx: *Context) !Redirect {
    _ = ctx;
    return .{ .location = "//example.test/old/../new/target?proto=1", .status = .found };
}

fn externalSchemeRelativeRedirect(ctx: *Context) !Redirect {
    _ = ctx;
    return .{ .location = "//external.test/new/target", .status = .found };
}

fn externalAbsoluteDotRedirect(ctx: *Context) !Redirect {
    _ = ctx;
    return .{ .location = "https://elsewhere.test/old/../new/target?external=1", .status = .found };
}

fn redirectWithCookie(ctx: *Context) !ResponsePayload {
    var headers = try ctx.allocator.alloc(HeaderField, 2);
    errdefer ctx.allocator.free(headers);
    headers[0] = try ownedHeaderField(ctx.allocator, "location", "/redirect-cookies");
    errdefer {
        ctx.allocator.free(headers[0].name);
        ctx.allocator.free(headers[0].value);
    }
    headers[1] = try makeSetCookieHeader(ctx.allocator, "session", "redirected", .{});
    return .{
        .status = .found,
        .content_type = "",
        .headers = headers,
        .owned_headers = true,
    };
}

fn redirectDeletingCookie(ctx: *Context) !ResponsePayload {
    var headers = try ctx.allocator.alloc(HeaderField, 2);
    errdefer ctx.allocator.free(headers);
    headers[0] = try ownedHeaderField(ctx.allocator, "location", "/redirect-cookies");
    errdefer {
        ctx.allocator.free(headers[0].name);
        ctx.allocator.free(headers[0].value);
    }
    headers[1] = try makeDeleteCookieHeader(ctx.allocator, "session", .{});
    return .{
        .status = .found,
        .content_type = "",
        .headers = headers,
        .owned_headers = true,
    };
}

fn temporaryRedirectToEcho(ctx: *Context) !Redirect {
    _ = ctx;
    return .{ .location = "/echo-request", .status = .temporary_redirect };
}

fn temporaryRedirectToRequestHeaders(ctx: *Context) !Redirect {
    _ = ctx;
    return .{ .location = "/echo-request-headers", .status = .temporary_redirect };
}

fn permanentRedirectToEcho(ctx: *Context) !Redirect {
    _ = ctx;
    return .{ .location = "/echo-request", .status = .permanent_redirect };
}

fn redirectToClientEcho(ctx: *Context) !Redirect {
    _ = ctx;
    return .{ .location = "/client", .status = .found };
}

fn absoluteRedirectToUsers(ctx: *Context) !Redirect {
    _ = ctx;
    return .{ .location = "http://example.test/users", .status = .found };
}

fn externalRedirect(ctx: *Context) !Redirect {
    _ = ctx;
    return .{ .location = "https://elsewhere.test/users", .status = .found };
}

fn redirectLoop(ctx: *Context) !Redirect {
    _ = ctx;
    return .{ .location = "/loop", .status = .found };
}

fn redirectToUnhandled(ctx: *Context) !Redirect {
    _ = ctx;
    return .{ .location = "/unhandled", .status = .found };
}

fn echoMethodAndBody(ctx: *Context) !MethodBodyEcho {
    return .{
        .method = ctx.request.method.text(),
        .body = ctx.request.body,
    };
}

fn echoMethodBodyAndContentType(ctx: *Context) !MethodBodyHeaderEcho {
    return .{
        .method = ctx.request.method.text(),
        .body = ctx.request.body,
        .content_type = ctx.request.header("content-type"),
    };
}

fn echoRedirectCookies(ctx: *Context) !RedirectCookieEcho {
    return .{
        .session = ctx.request.cookie("session"),
        .theme = ctx.request.cookie("theme"),
    };
}

fn echoScopedCookie(ctx: *Context) !ScopedCookieEcho {
    return .{ .scoped = ctx.request.cookie("scoped") };
}

fn setExampleDomainCookie(ctx: *Context) !ResponsePayload {
    var payload = ResponsePayload{ .content_type = "text/plain; charset=utf-8", .body = "set" };
    try payload.setCookie(ctx.allocator, "scoped", "example", .{ .domain = "example.test" });
    return payload;
}

fn setOtherDomainCookie(ctx: *Context) !ResponsePayload {
    var payload = ResponsePayload{ .content_type = "text/plain; charset=utf-8", .body = "set" };
    try payload.setCookie(ctx.allocator, "scoped", "other", .{ .domain = "elsewhere.test" });
    return payload;
}

fn setTestserverDomainCookie(ctx: *Context) !ResponsePayload {
    var payload = ResponsePayload{ .content_type = "text/plain; charset=utf-8", .body = "set" };
    try payload.setCookie(ctx.allocator, "scoped", "testserver", .{ .domain = "testserver" });
    return payload;
}

fn setTestserverLocalDomainCookie(ctx: *Context) !ResponsePayload {
    var payload = ResponsePayload{ .content_type = "text/plain; charset=utf-8", .body = "set" };
    try payload.setCookie(ctx.allocator, "scoped", "testserver-local", .{ .domain = "testserver.local" });
    return payload;
}

fn setLocalhostDomainCookie(ctx: *Context) !ResponsePayload {
    var payload = ResponsePayload{ .content_type = "text/plain; charset=utf-8", .body = "set" };
    try payload.setCookie(ctx.allocator, "scoped", "localhost", .{ .domain = "localhost" });
    return payload;
}

fn setAdminPathCookie(ctx: *Context) !ResponsePayload {
    var payload = ResponsePayload{ .content_type = "text/plain; charset=utf-8", .body = "set" };
    try payload.setCookie(ctx.allocator, "scoped", "admin", .{ .path = "/admin" });
    return payload;
}

fn setRootPathCookie(ctx: *Context) !ResponsePayload {
    var payload = ResponsePayload{ .content_type = "text/plain; charset=utf-8", .body = "set" };
    try payload.setCookie(ctx.allocator, "scoped", "root", .{ .path = "/" });
    return payload;
}

fn setSecureScopedCookie(ctx: *Context) !ResponsePayload {
    var payload = ResponsePayload{ .content_type = "text/plain; charset=utf-8", .body = "set" };
    try payload.setCookie(ctx.allocator, "scoped", "secure", .{ .secure = true });
    return payload;
}

fn echoNamedUserPath(ctx: *Context, path: Path(struct { id: u64 })) !ResponsePayload {
    const url_path = try ctx.urlPathFor("user_detail", .{ .id = path.value.id });
    defer ctx.allocator.free(url_path);

    var body = std.Io.Writer.Allocating.init(ctx.allocator);
    errdefer body.deinit();
    try std.json.Stringify.value(UrlPathEcho{ .path = url_path }, .{}, &body.writer);
    return .{
        .content_type = "application/json",
        .body = try body.toOwnedSlice(),
        .owned_body = true,
    };
}

fn echoRequestUrlPath(ctx: *Context) !ResponsePayload {
    return .{
        .content_type = "text/plain; charset=utf-8",
        .body = try ctx.request.urlPath(ctx.allocator),
        .owned_body = true,
    };
}

fn echoNamedUserUrl(ctx: *Context, path: Path(struct { id: u64 })) !ResponsePayload {
    const url = try ctx.urlFor("user_detail", .{ .id = path.value.id });
    defer ctx.allocator.free(url);
    const request_url = try ctx.request.url(ctx.allocator);
    defer ctx.allocator.free(request_url);

    var body = std.Io.Writer.Allocating.init(ctx.allocator);
    errdefer body.deinit();
    try std.json.Stringify.value(UrlEcho{ .url = url, .request_url = request_url }, .{}, &body.writer);
    return .{
        .content_type = "application/json",
        .body = try body.toOwnedSlice(),
        .owned_body = true,
    };
}

fn echoRequestNamedUserUrl(ctx: *Context, request: Request, path: Path(struct { id: u64 })) !ResponsePayload {
    const url_path = try request.urlPathFor(ctx.allocator, "user_detail", .{ .id = path.value.id });
    defer ctx.allocator.free(url_path);
    const url = try request.urlFor(ctx.allocator, "user_detail", .{ .id = path.value.id });
    defer ctx.allocator.free(url);

    var body = std.Io.Writer.Allocating.init(ctx.allocator);
    errdefer body.deinit();
    try std.json.Stringify.value(struct {
        path: []const u8,
        url: []const u8,
    }{ .path = url_path, .url = url }, .{}, &body.writer);
    return .{
        .content_type = "application/json",
        .body = try body.toOwnedSlice(),
        .owned_body = true,
    };
}

fn echoRequestUrlParts(ctx: *Context) !ResponsePayload {
    const url = try ctx.request.url(ctx.allocator);
    defer ctx.allocator.free(url);
    const url_path = try ctx.request.urlPath(ctx.allocator);
    defer ctx.allocator.free(url_path);
    const base_url = try ctx.request.baseUrl(ctx.allocator);
    defer ctx.allocator.free(base_url);

    var body = std.Io.Writer.Allocating.init(ctx.allocator);
    errdefer body.deinit();
    try std.json.Stringify.value(RequestUrlPartsEcho{
        .url = url,
        .url_path = url_path,
        .base_url = base_url,
    }, .{}, &body.writer);
    return .{
        .content_type = "application/json",
        .body = try body.toOwnedSlice(),
        .owned_body = true,
    };
}

fn echoRequestUrlMutations(ctx: *Context) !ResponsePayload {
    const included = try ctx.request.urlIncludeQueryParam(ctx.allocator, "tag", "zig api");
    defer ctx.allocator.free(included);
    const replaced = try ctx.request.urlReplaceQueryParam(ctx.allocator, "next", "2");
    defer ctx.allocator.free(replaced);
    const removed = try ctx.request.urlRemoveQueryParam(ctx.allocator, "tab");
    defer ctx.allocator.free(removed);
    const path_included = try ctx.request.urlPathIncludeQueryParam(ctx.allocator, "tag", "zig api");
    defer ctx.allocator.free(path_included);
    const path_replaced = try ctx.request.urlPathReplaceQueryParam(ctx.allocator, "next", "2");
    defer ctx.allocator.free(path_replaced);
    const path_removed = try ctx.request.urlPathRemoveQueryParam(ctx.allocator, "tab");
    defer ctx.allocator.free(path_removed);

    var body = std.Io.Writer.Allocating.init(ctx.allocator);
    errdefer body.deinit();
    try std.json.Stringify.value(RequestUrlMutationEcho{
        .included = included,
        .replaced = replaced,
        .removed = removed,
        .path_included = path_included,
        .path_replaced = path_replaced,
        .path_removed = path_removed,
    }, .{}, &body.writer);
    return .{
        .content_type = "application/json",
        .body = try body.toOwnedSlice(),
        .owned_body = true,
    };
}

fn echoNamedRootUrl(ctx: *Context) !ResponsePayload {
    const index = try ctx.urlFor("homepage", .{});
    defer ctx.allocator.free(index);

    var body = std.Io.Writer.Allocating.init(ctx.allocator);
    errdefer body.deinit();
    try std.json.Stringify.value(NamedRootUrlEcho{ .index = index }, .{}, &body.writer);
    return .{
        .content_type = "application/json",
        .body = try body.toOwnedSlice(),
        .owned_body = true,
    };
}

fn echoMountedRootUrls(ctx: *Context) !ResponsePayload {
    const index = try ctx.urlFor("index", .{});
    defer ctx.allocator.free(index);
    const submount = try ctx.urlFor("mount:submount", .{});
    defer ctx.allocator.free(submount);

    var body = std.Io.Writer.Allocating.init(ctx.allocator);
    errdefer body.deinit();
    try std.json.Stringify.value(MountedRootUrlEcho{
        .index = index,
        .submount = submount,
    }, .{}, &body.writer);
    return .{
        .content_type = "application/json",
        .body = try body.toOwnedSlice(),
        .owned_body = true,
    };
}

fn redirectToNamedRoot(ctx: *Context) !ResponsePayload {
    return try ctx.redirectTo("homepage", .{});
}

fn redirectToNamedUser(ctx: *Context, path: Path(struct { id: u64 })) !ResponsePayload {
    return try ctx.redirectTo("user_detail", .{ .id = path.value.id });
}

fn customPayload(ctx: *Context) !ResponsePayload {
    _ = ctx;
    return .{
        .status = .accepted,
        .content_type = "text/custom",
        .headers = &.{.{ .name = "x-zapi", .value = "ok" }},
        .body = "accepted",
    };
}

fn customExtensionStatus(ctx: *Context) !Text {
    _ = ctx;
    return .{
        .status = Status.fromCode(299),
        .text = "custom",
    };
}

fn conditionalPayload(ctx: *Context) !ResponsePayload {
    var payload = ResponsePayload{
        .content_type = "text/plain; charset=utf-8",
        .headers = &.{
            .{ .name = "x-cacheable", .value = "yes" },
            .{ .name = "content-length", .value = "stale" },
        },
        .body = "cache me",
    };
    try payload.makeConditional(ctx.allocator, ctx.request, .{
        .etag = "\"v1\"",
        .last_modified_seconds = conditional_last_modified_seconds,
    });
    return payload;
}

fn conditionalLastModifiedPayload(ctx: *Context) !ResponsePayload {
    var payload = ResponsePayload{
        .content_type = "text/plain; charset=utf-8",
        .body = "cache me",
    };
    try payload.makeConditional(ctx.allocator, ctx.request, .{
        .last_modified_seconds = conditional_last_modified_seconds,
    });
    return payload;
}

fn noContentPayload(ctx: *Context) !ResponsePayload {
    _ = ctx;
    return .{
        .content_type = "text/should-not-be-sent",
        .headers = &.{.{ .name = "x-empty", .value = "kept" }},
        .body = "should not be sent",
    };
}

fn informationalPayload(ctx: *Context) !ResponsePayload {
    _ = ctx;
    return .{
        .status = .early_hints,
        .content_type = "text/should-not-be-sent",
        .headers = &.{.{ .name = "x-hint", .value = "kept" }},
        .body = "should not be sent",
    };
}

fn problemResponse(ctx: *Context) !ResponsePayload {
    return try ctx.problem(.not_found, "User \"ada\" not found\ntry again");
}

fn problemWithHeaderResponse(ctx: *Context) !ResponsePayload {
    return try ctx.problemWithHeaders(.too_many_requests, "Slow down", &.{
        .{ .name = "retry-after", .value = "30" },
    });
}

fn problemShortcutResponse(ctx: *Context, path: Path(struct { kind: []const u8 })) !ResponsePayload {
    if (std.mem.eql(u8, path.value.kind, "bad")) return try ctx.badRequest("Bad request");
    if (std.mem.eql(u8, path.value.kind, "bearer")) return try ctx.unauthorizedWithChallenge("Missing bearer token", "Bearer");
    if (std.mem.eql(u8, path.value.kind, "unauthorized")) return try ctx.unauthorized("Missing token");
    if (std.mem.eql(u8, path.value.kind, "forbidden")) return try ctx.forbidden("Forbidden");
    if (std.mem.eql(u8, path.value.kind, "missing")) return try ctx.notFound("Missing resource");
    if (std.mem.eql(u8, path.value.kind, "conflict")) return try ctx.conflict("Conflict");
    if (std.mem.eql(u8, path.value.kind, "large")) return try ctx.payloadTooLarge("Payload too large");
    if (std.mem.eql(u8, path.value.kind, "limited")) return try ctx.tooManyRequests("Too many requests");
    return try ctx.unprocessableEntity("Invalid state");
}

fn incrementBackgroundTask(context: ?*anyopaque) !void {
    const state: *BackgroundState = @ptrCast(@alignCast(context.?));
    state.count += 1;
}

fn backgroundPayload(ctx: *Context) !ResponsePayload {
    const state = ctx.state(BackgroundState);
    const tasks = try ctx.allocator.alloc(BackgroundTask, 1);
    errdefer ctx.allocator.free(tasks);
    tasks[0] = .{ .run = incrementBackgroundTask, .context = state };
    return .{
        .content_type = "text/plain; charset=utf-8",
        .body = "queued",
        .background_tasks = tasks,
        .owned_background_tasks = true,
    };
}

fn backgroundTasksPayload(ctx: *Context) !ResponsePayload {
    const state = ctx.state(BackgroundState);
    var tasks = BackgroundTasks.init(ctx.allocator);
    errdefer tasks.deinit();
    try tasks.addTask(incrementBackgroundTask, state);
    try tasks.append(.{ .run = incrementBackgroundTask, .context = state });
    try testing.expectEqual(@as(usize, 2), tasks.len());
    try testing.expect(!tasks.isEmpty());
    try testing.expectEqual(@as(usize, 2), tasks.items().len);
    return .{
        .content_type = "text/plain; charset=utf-8",
        .body = "queued-list",
        .background_tasks = try tasks.toOwnedSlice(),
        .owned_background_tasks = true,
    };
}

fn requestShutdown(ctx: *Context) !Text {
    ctx.state(ShutdownSignal).request();
    return .{ .text = "stopping" };
}

fn appendLifecycleEvent(app: *ZAPI, event: []const u8) !void {
    const state = app.state(LifecycleState);
    try state.events.append(app.allocator, event);
}

fn parentStartup(app: *ZAPI) !void {
    try appendLifecycleEvent(app, "parent-startup");
}

fn childStartup(app: *ZAPI) !void {
    try appendLifecycleEvent(app, "child-startup");
}

fn parentShutdown(app: *ZAPI) !void {
    try appendLifecycleEvent(app, "parent-shutdown");
}

fn childShutdown(app: *ZAPI) !void {
    try appendLifecycleEvent(app, "child-shutdown");
}

fn failingRoute(ctx: *Context) !Text {
    _ = ctx;
    return error.Teapot;
}

fn unhandledFailingRoute(ctx: *Context) !Text {
    _ = ctx;
    return error.UnhandledBoom;
}

fn setCookieResponse(ctx: *Context) !ResponsePayload {
    var headers = try ctx.allocator.alloc(HeaderField, 1);
    errdefer ctx.allocator.free(headers);
    headers[0] = try makeSetCookieHeader(ctx.allocator, "session", "abc123", .{
        .max_age = 3600,
        .secure = true,
        .http_only = true,
        .same_site = .lax,
    });

    return .{
        .content_type = "text/plain; charset=utf-8",
        .headers = headers,
        .owned_headers = true,
        .body = "ok",
    };
}

fn deleteCookieResponse(ctx: *Context) !ResponsePayload {
    var headers = try ctx.allocator.alloc(HeaderField, 1);
    errdefer ctx.allocator.free(headers);
    headers[0] = try makeDeleteCookieHeader(ctx.allocator, "session", .{});

    return .{
        .content_type = "text/plain; charset=utf-8",
        .headers = headers,
        .owned_headers = true,
        .body = "deleted",
    };
}

fn expiresOnlyDeleteCookieResponse(ctx: *Context) !ResponsePayload {
    var headers = try ctx.allocator.alloc(HeaderField, 1);
    errdefer ctx.allocator.free(headers);
    headers[0] = try makeSetCookieHeader(ctx.allocator, "session", "", .{
        .expires = "Thu, 01 Jan 1970 00:00:00 GMT",
    });

    return .{
        .content_type = "text/plain; charset=utf-8",
        .headers = headers,
        .owned_headers = true,
        .body = "expired",
    };
}

fn nonEmptyMaxAgeDeleteCookieResponse(ctx: *Context) !ResponsePayload {
    var headers = try ctx.allocator.alloc(HeaderField, 1);
    errdefer ctx.allocator.free(headers);
    headers[0] = try makeSetCookieHeader(ctx.allocator, "session", "deleted", .{
        .max_age = 0,
    });

    return .{
        .content_type = "text/plain; charset=utf-8",
        .headers = headers,
        .owned_headers = true,
        .body = "deleted",
    };
}

fn nonEmptyExpiresDeleteCookieResponse(ctx: *Context) !ResponsePayload {
    var headers = try ctx.allocator.alloc(HeaderField, 1);
    errdefer ctx.allocator.free(headers);
    headers[0] = try makeSetCookieHeader(ctx.allocator, "session", "expired", .{
        .expires = "Thu, 01 Jan 1970 00:00:00 GMT",
    });

    return .{
        .content_type = "text/plain; charset=utf-8",
        .headers = headers,
        .owned_headers = true,
        .body = "expired",
    };
}

fn maxAgePrecedenceCookieResponse(ctx: *Context) !ResponsePayload {
    var headers = try ctx.allocator.alloc(HeaderField, 1);
    errdefer ctx.allocator.free(headers);
    headers[0] = try makeSetCookieHeader(ctx.allocator, "session", "kept", .{
        .max_age = 3600,
        .expires = "Thu, 01 Jan 1970 00:00:00 GMT",
    });

    return .{
        .content_type = "text/plain; charset=utf-8",
        .headers = headers,
        .owned_headers = true,
        .body = "kept",
    };
}

fn payloadHelpersResponse(ctx: *Context) !ResponsePayload {
    var payload = ResponsePayload{
        .content_type = "text/plain; charset=utf-8",
        .headers = &.{.{ .name = "x-mode", .value = "literal" }},
        .body = "helpers",
    };
    try payload.setHeader(ctx.allocator, "x-mode", "owned");
    try payload.appendHeader(ctx.allocator, "x-extra", "a");
    try payload.appendHeader(ctx.allocator, "x-extra", "b");
    try payload.setCookie(ctx.allocator, "session", "abc123", .{
        .path = "/",
        .http_only = true,
        .same_site = .lax,
    });
    try payload.deleteCookie(ctx.allocator, "preview", .{});
    try payload.addBackgroundTask(ctx.allocator, .{
        .run = incrementBackgroundTask,
        .context = ctx.state(BackgroundState),
    });
    return payload;
}

fn addMiddlewareHeader(ctx: *MiddlewareContext, request: Request) !Response {
    var response = try ctx.next(request);
    try response.setHeader(ctx.app.allocator, "x-middleware", "yes");
    return response;
}

fn addRouteMiddlewareHeader(ctx: *MiddlewareContext, request: Request) !Response {
    var response = try ctx.next(request);
    try response.setHeader(ctx.app.allocator, "x-route-middleware", "yes");
    return response;
}

fn setFrameOptionsMiddleware(ctx: *MiddlewareContext, request: Request) !Response {
    var response = try ctx.next(request);
    try response.setHeader(ctx.app.allocator, "x-frame-options", "SAMEORIGIN");
    return response;
}

fn appendOrderOuter(ctx: *MiddlewareContext, request: Request) !Response {
    var response = try ctx.next(request);
    try response.setHeader(ctx.app.allocator, "x-order", "outer");
    return response;
}

fn appendOrderInner(ctx: *MiddlewareContext, request: Request) !Response {
    var response = try ctx.next(request);
    try response.setHeader(ctx.app.allocator, "x-order", "inner");
    return response;
}

fn appendRouterOuter(ctx: *MiddlewareContext, request: Request) !Response {
    var response = try ctx.next(request);
    errdefer response.deinit(ctx.app.allocator);
    try response.appendHeader(ctx.app.allocator, "x-router-order", "outer");
    return response;
}

fn appendRouterInner(ctx: *MiddlewareContext, request: Request) !Response {
    var response = try ctx.next(request);
    errdefer response.deinit(ctx.app.allocator);
    try response.appendHeader(ctx.app.allocator, "x-router-order", "inner");
    return response;
}

fn blockMiddleware(ctx: *MiddlewareContext, request: Request) !Response {
    if (request.header("x-block")) |value| {
        if (std.mem.eql(u8, value, "true")) {
            var response = Response.init(.forbidden);
            try response.setHeader(ctx.app.allocator, "content-type", "text/plain; charset=utf-8");
            try response.body.appendSlice(ctx.app.allocator, "blocked");
            return response;
        }
    }

    return ctx.next(request);
}

fn informationalMiddleware(ctx: *MiddlewareContext, request: Request) !Response {
    _ = request;
    var response = Response.init(.processing);
    try response.setHeader(ctx.app.allocator, "x-info", "kept");
    try response.setHeader(ctx.app.allocator, "content-length", "18");
    try response.body.appendSlice(ctx.app.allocator, "middleware body");
    return response;
}

fn failMiddleware(ctx: *MiddlewareContext, request: Request) !Response {
    _ = ctx;
    _ = request;
    return error.MiddlewareBoom;
}

fn requestStateMiddleware(ctx: *MiddlewareContext, request: Request) !Response {
    var state = RequestTraceState{
        .trace_id = request.header("x-trace-id") orelse "generated",
    };
    var forwarded = request;
    forwarded.setState(&state);

    var response = try ctx.next(forwarded);
    errdefer response.deinit(ctx.app.allocator);
    try response.setHeader(ctx.app.allocator, "x-handler-seen-state", if (state.handler_seen) "yes" else "no");
    return response;
}

fn handleTeapot(ctx: *ExceptionContext) !Response {
    var response = Response.init(.conflict);
    try response.setHeader(ctx.app.allocator, "content-type", "text/plain; charset=utf-8");
    try response.setHeader(ctx.app.allocator, "x-error", @errorName(ctx.err));
    try response.body.appendSlice(ctx.app.allocator, "handled ");
    try response.body.appendSlice(ctx.app.allocator, ctx.request.path);
    return response;
}

fn handleTeapotReplacement(ctx: *ExceptionContext) !Response {
    var response = Response.init(.accepted);
    try response.setHeader(ctx.app.allocator, "content-type", "text/plain; charset=utf-8");
    try response.body.appendSlice(ctx.app.allocator, "replacement");
    return response;
}

fn handleMiddlewareBoom(ctx: *ExceptionContext) !Response {
    var response = Response.init(.forbidden);
    try response.setHeader(ctx.app.allocator, "content-type", "text/plain; charset=utf-8");
    try response.body.appendSlice(ctx.app.allocator, "middleware ");
    try response.body.appendSlice(ctx.app.allocator, ctx.request.path);
    return response;
}

fn handleStatusPlain(ctx: *StatusHandlerContext) !Response {
    var response = Response.init(ctx.status);
    try response.setHeader(ctx.app.allocator, "content-type", "text/plain; charset=utf-8");
    const body = try std.fmt.allocPrint(ctx.app.allocator, "{d} {s} {s}", .{ ctx.status.code(), ctx.request.path, ctx.detail });
    defer ctx.app.allocator.free(body);
    try response.body.appendSlice(ctx.app.allocator, body);
    return response;
}

fn handleStatusReplacement(ctx: *StatusHandlerContext) !Response {
    var response = Response.init(ctx.status);
    try response.setHeader(ctx.app.allocator, "content-type", "text/plain; charset=utf-8");
    try response.body.appendSlice(ctx.app.allocator, "status replacement");
    return response;
}

fn decompressGzipForTest(allocator: std.mem.Allocator, compressed: []const u8) ![]u8 {
    var input = std.Io.Reader.fixed(compressed);
    var decompress_buffer: [std.compress.flate.max_window_len]u8 = undefined;
    var decompressor: std.compress.flate.Decompress = .init(&input, .gzip, &decompress_buffer);

    var output = std.Io.Writer.Allocating.init(allocator);
    errdefer output.deinit();
    _ = try decompressor.reader.streamRemaining(&output.writer);
    return output.toOwnedSlice();
}

fn ioAvailable(ctx: *Context) !struct { available: bool } {
    _ = try ctx.ioHandle();
    return .{ .available = true };
}

fn serveBoundOnce(app: *ZAPI, io: std.Io, listener: *std.Io.net.Server) !void {
    try app.serveListener(io, listener, .{ .max_connections = 1 });
}

fn serveBoundStreamingOnce(app: *ZAPI, io: std.Io, listener: *std.Io.net.Server) !void {
    try app.serveListener(io, listener, .{
        .max_connections = 1,
        .buffer_request_body = false,
    });
}

fn serveBoundConcurrentTwo(app: *ZAPI, io: std.Io, listener: *std.Io.net.Server) !void {
    try app.serveListener(io, listener, .{
        .max_connections = 2,
        .concurrent_connections = true,
    });
}

fn serveUntilShutdown(app: *ZAPI, io: std.Io, listener: *std.Io.net.Server, shutdown_signal: *ShutdownSignal) !void {
    try app.serveListener(io, listener, .{ .shutdown_signal = shutdown_signal });
}

fn exerciseRegistrationAllocationFailures(gpa: std.mem.Allocator) !void {
    var child = ZAPI.init(gpa, .{});
    defer child.deinit();
    var app = ZAPI.init(gpa, .{});
    defer app.deinit();

    try app.addPathConvertor("slug", slugMatches);
    try app.route(Route.websocket("/ws", websocketEcho, .{ .name = "socket" }));
    try app.mountNamed("/child", "child", &child);

    var builder = Request.builder(gpa, .GET, "/");
    defer builder.deinit();
    try builder.header("x-test", "value");

    var client = TestClient.init(gpa, &app, .{});
    defer client.deinit();
    try client.header("x-test", "value");
    try client.queryParam("filter[name]", "value");
}

test "registration and builders clean up every allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, exerciseRegistrationAllocationFailures, .{});
}

fn fuzzRequestParsers(_: void, smith: *testing.Smith) !void {
    var input: [1024]u8 = undefined;
    const len = smith.sliceWeightedBytes(&input, &.{
        .rangeAtMost(u8, 0x00, 0xff, 1),
        .rangeAtMost(u8, 0x20, 0x7e, 4),
        .value(u8, '%', 4),
        .value(u8, '&', 4),
        .value(u8, '=', 4),
    });

    var request = Request.init(.GET, "/");
    request.query = input[0..len];
    var query = request.queryParams(testing.allocator) catch return;
    defer query.deinit();
}

test "request parsers reject arbitrary input without leaking" {
    try testing.fuzz({}, fuzzRequestParsers, .{});
}

test "handles registered routes and serializes json" {
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    try app.route(Route.get("/", hello, .{ .summary = "Hello world" }));

    var response = try app.handle(Request.init(.GET, "/"));
    defer response.deinit(testing.allocator);

    try testing.expectEqual(Status.ok, response.status);
    try testing.expectEqualStrings("{\"message\":\"Hello from Zig\"}", response.body.items);
}

test "parses json bodies and route status metadata" {
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    try app.route(Route.post("/users", createUser, .{ .status = .created }));
    try app.route(Route.post("/maybe-users", maybeCreateUser, .{}));

    var req = Request.init(.POST, "/users");
    req.body = "{\"email\":\"ada@example.com\"}";
    var response = try app.handle(req);
    defer response.deinit(testing.allocator);

    try testing.expectEqual(Status.created, response.status);
    try testing.expectEqualStrings("{\"id\":1,\"email\":\"ada@example.com\"}", response.body.items);

    var json_req = Request.init(.POST, "/users");
    json_req.headers = &.{.{ .name = "content-type", .value = "application/json; charset=utf-8" }};
    json_req.body = "{\"email\":\"grace@example.com\"}";
    var json_response = try app.handle(json_req);
    defer json_response.deinit(testing.allocator);
    try testing.expectEqual(Status.created, json_response.status);
    try testing.expectEqualStrings("{\"id\":1,\"email\":\"grace@example.com\"}", json_response.body.items);

    var vendor_json_req = Request.init(.POST, "/users");
    vendor_json_req.headers = &.{.{ .name = "content-type", .value = "application/vnd.zapi.user+json" }};
    vendor_json_req.body = "{\"email\":\"vendor@example.com\"}";
    var vendor_json = try app.handle(vendor_json_req);
    defer vendor_json.deinit(testing.allocator);
    try testing.expectEqual(Status.created, vendor_json.status);
    try testing.expectEqualStrings("{\"id\":1,\"email\":\"vendor@example.com\"}", vendor_json.body.items);

    var wrong_content_type = Request.init(.POST, "/users");
    wrong_content_type.headers = &.{.{ .name = "content-type", .value = "text/plain" }};
    wrong_content_type.body = "{\"email\":\"ada@example.com\"}";
    var wrong_content_type_response = try app.handle(wrong_content_type);
    defer wrong_content_type_response.deinit(testing.allocator);
    try testing.expectEqual(Status.unprocessable_entity, wrong_content_type_response.status);

    var invalid_req = Request.init(.POST, "/users");
    invalid_req.body = "{\"email\":123}";
    var invalid = try app.handle(invalid_req);
    defer invalid.deinit(testing.allocator);
    try testing.expectEqual(Status.unprocessable_entity, invalid.status);

    var empty_optional = try app.handle(Request.init(.POST, "/maybe-users"));
    defer empty_optional.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, empty_optional.status);
    try testing.expectEqualStrings("{\"email\":null}", empty_optional.body.items);

    var null_optional_req = Request.init(.POST, "/maybe-users");
    null_optional_req.body = "null";
    var null_optional = try app.handle(null_optional_req);
    defer null_optional.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, null_optional.status);
    try testing.expectEqualStrings("{\"email\":null}", null_optional.body.items);

    var optional_req = Request.init(.POST, "/maybe-users");
    optional_req.body = "{\"email\":\"grace@example.com\"}";
    var optional = try app.handle(optional_req);
    defer optional.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, optional.status);
    try testing.expectEqualStrings("{\"email\":\"grace@example.com\"}", optional.body.items);

    var invalid_optional_req = Request.init(.POST, "/maybe-users");
    invalid_optional_req.body = "{\"email\":123}";
    var invalid_optional = try app.handle(invalid_optional_req);
    defer invalid_optional.deinit(testing.allocator);
    try testing.expectEqual(Status.unprocessable_entity, invalid_optional.status);
}

test "parses json object maps" {
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    try app.route(Route.post("/scores", echoScores, .{}));

    var req = Request.init(.POST, "/scores");
    req.body = "{\"zig\":10,\"api\":7}";
    var response = try app.handle(req);
    defer response.deinit(testing.allocator);

    try testing.expectEqual(Status.ok, response.status);
    try testing.expectEqualStrings("{\"zig\":10,\"api\":7}", response.body.items);

    var invalid_req = Request.init(.POST, "/scores");
    invalid_req.body = "[]";
    var invalid = try app.handle(invalid_req);
    defer invalid.deinit(testing.allocator);
    try testing.expectEqual(Status.unprocessable_entity, invalid.status);
}

test "parses and returns direct json arrays" {
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    try app.route(Route.post("/users/bulk", echoCreateUsers, .{}));
    try app.route(Route.get("/users/bulk", listCreateUsers, .{}));

    var req = Request.init(.POST, "/users/bulk");
    req.body = "[{\"email\":\"ada@example.com\"},{\"email\":\"grace@example.com\"}]";
    var response = try app.handle(req);
    defer response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, response.status);
    try testing.expectEqualStrings("[{\"email\":\"ada@example.com\"},{\"email\":\"grace@example.com\"}]", response.body.items);

    var invalid_req = Request.init(.POST, "/users/bulk");
    invalid_req.body = "{\"email\":\"ada@example.com\"}";
    var invalid = try app.handle(invalid_req);
    defer invalid.deinit(testing.allocator);
    try testing.expectEqual(Status.unprocessable_entity, invalid.status);

    var list = try app.handle(Request.init(.GET, "/users/bulk"));
    defer list.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, list.status);
    try testing.expectEqualStrings("[{\"email\":\"ada@example.com\"},{\"email\":\"grace@example.com\"}]", list.body.items);
}

test "request stream iterates body chunks" {
    var req = Request.init(.POST, "/stream");
    req.body = "abcdefg";

    var stream = req.stream(.{ .chunk_size = 3 });
    try testing.expectEqualStrings("abc", stream.next().?);
    try testing.expectEqualStrings("def", stream.next().?);
    try testing.expectEqualStrings("g", stream.next().?);
    try testing.expect(stream.next() == null);

    stream.reset();
    try testing.expectEqualStrings("abc", stream.next().?);

    var whole = req.stream(.{ .chunk_size = 0 });
    try testing.expectEqualStrings("abcdefg", whole.next().?);
    try testing.expect(whole.next() == null);

    var empty_req = Request.init(.POST, "/stream");
    var empty = empty_req.stream(.{ .chunk_size = 0 });
    try testing.expect(empty.next() == null);
}

test "handlers can read streaming request bodies" {
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    try app.route(Route.post("/stream", streamBody, .{}));

    var req = Request.init(.POST, "/stream");
    req.body = "abcdefg";
    var response = try app.handle(req);
    defer response.deinit(testing.allocator);

    try testing.expectEqual(Status.ok, response.status);
    try testing.expectEqualStrings("{\"chunks\":[\"abc\",\"def\",\"g\"],\"joined\":\"abcdefg\"}", response.body.items);

    var builder = Request.builder(testing.allocator, .POST, "/stream");
    defer builder.deinit();
    try builder.setBody("zig");
    var built = try builder.send(&app);
    defer built.deinit(testing.allocator);

    try testing.expectEqual(Status.ok, built.status);
    try testing.expectEqualStrings("{\"chunks\":[\"zig\"],\"joined\":\"zig\"}", built.body.items);
}

test "app handle enforces configured request body size limit" {
    var limited_app = ZAPI.init(testing.allocator, .{ .max_request_body_size = 8 });
    defer limited_app.deinit();
    try limited_app.route(Route.post("/users", createUser, .{}));

    var too_large_req = Request.init(.POST, "/users");
    too_large_req.body = "{\"email\":\"ada@example.com\"}";
    var too_large = try limited_app.handle(too_large_req);
    defer too_large.deinit(testing.allocator);
    try testing.expectEqual(Status.payload_too_large, too_large.status);
    try testing.expectEqualStrings("{\"detail\":\"Request body too large\"}", too_large.body.items);

    var unlimited_app = ZAPI.init(testing.allocator, .{ .max_request_body_size = null });
    defer unlimited_app.deinit();
    try unlimited_app.route(Route.post("/users", createUser, .{ .status = .created }));

    var allowed_req = Request.init(.POST, "/users");
    allowed_req.body = "{\"email\":\"ada@example.com\"}";
    var allowed = try unlimited_app.handle(allowed_req);
    defer allowed.deinit(testing.allocator);
    try testing.expectEqual(Status.created, allowed.status);
    try testing.expectEqualStrings("{\"id\":1,\"email\":\"ada@example.com\"}", allowed.body.items);
}

test "request body limit middleware applies globally routes and routers" {
    var global_app = ZAPI.init(testing.allocator, .{});
    defer global_app.deinit();
    try global_app.addMiddleware(requestBodyLimitMiddleware(.{ .max_size = 4 }));
    try global_app.route(Route.post("/body", bodySize, .{}));

    var global_ok_req = Request.init(.POST, "/body");
    global_ok_req.body = "1234";
    var global_ok = try global_app.handle(global_ok_req);
    defer global_ok.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, global_ok.status);
    try testing.expectEqualStrings("{\"size\":4}", global_ok.body.items);

    var global_blocked_req = Request.init(.POST, "/body");
    global_blocked_req.body = "12345";
    var global_blocked = try global_app.handle(global_blocked_req);
    defer global_blocked.deinit(testing.allocator);
    try testing.expectEqual(Status.payload_too_large, global_blocked.status);
    try testing.expectEqualStrings("{\"detail\":\"Request body too large\"}", global_blocked.body.items);

    var route_app = ZAPI.init(testing.allocator, .{});
    defer route_app.deinit();
    try route_app.route(Route.post("/open", bodySize, .{}));
    try route_app.route(Route.post("/limited", bodySize, .{
        .middlewares = &.{requestBodyLimitMiddleware(.{
            .max_size = 4,
            .detail = "Route body too large",
        })},
    }));

    var open_req = Request.init(.POST, "/open");
    open_req.body = "12345";
    var open = try route_app.handle(open_req);
    defer open.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, open.status);
    try testing.expectEqualStrings("{\"size\":5}", open.body.items);

    var route_blocked_req = Request.init(.POST, "/limited");
    route_blocked_req.body = "12345";
    var route_blocked = try route_app.handle(route_blocked_req);
    defer route_blocked.deinit(testing.allocator);
    try testing.expectEqual(Status.payload_too_large, route_blocked.status);
    try testing.expectEqualStrings("{\"detail\":\"Route body too large\"}", route_blocked.body.items);

    var router_app = ZAPI.init(testing.allocator, .{});
    defer router_app.deinit();
    const api = Router.init(.{
        .prefix = "/api",
        .middlewares = &.{requestBodyLimitMiddleware(.{ .max_size = 2 })},
        .routes = .{
            Route.post("/one", bodySize, .{}),
            Route.post("/two", bodySize, .{}),
        },
    });
    try router_app.includeRouter(api);

    var router_ok_req = Request.init(.POST, "/api/one");
    router_ok_req.body = "12";
    var router_ok = try router_app.handle(router_ok_req);
    defer router_ok.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, router_ok.status);
    try testing.expectEqualStrings("{\"size\":2}", router_ok.body.items);

    var router_blocked_req = Request.init(.POST, "/api/two");
    router_blocked_req.body = "123";
    var router_blocked = try router_app.handle(router_blocked_req);
    defer router_blocked.deinit(testing.allocator);
    try testing.expectEqual(Status.payload_too_large, router_blocked.status);
    try testing.expectEqualStrings("{\"detail\":\"Request body too large\"}", router_blocked.body.items);
}

test "raw request helpers read decoded query cookies and path params" {
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    try app.route(Route.get("/raw/{item:path}", echoRawRequest, .{}));

    var req = Request.init(.GET, "/raw/zig%2Fapi?q=hello+zig&tag=first&empty=&tag=last%20tag");
    req.headers = &.{
        .{ .name = "x-token", .value = "first" },
        .{ .name = "X-Token", .value = "second" },
        .{ .name = "cookie", .value = "theme=dark; session_id=abc123" },
        .{ .name = "cookie", .value = "session_id=latest" },
    };
    var response = try app.handle(req);
    defer response.deinit(testing.allocator);

    try testing.expectEqual(Status.ok, response.status);
    try testing.expectEqualStrings(
        "{\"item\":\"zig/api\",\"token\":\"first\",\"tokens\":[\"first\",\"second\"],\"missing_header_count\":0,\"q\":\"hello zig\",\"tag\":\"last tag\",\"tags\":[\"first\",\"last tag\"],\"empty\":\"\",\"missing_query\":true,\"theme\":\"dark\",\"session\":\"latest\",\"missing_cookie\":true}",
        response.body.items,
    );

    const token_values = try req.headerValues(testing.allocator, "x-token");
    defer testing.allocator.free(token_values);
    try testing.expect(req.hasHeader("X-Token"));
    try testing.expectEqual(@as(usize, 2), token_values.len);
    try testing.expectEqualStrings("first", token_values[0]);
    try testing.expectEqualStrings("second", token_values[1]);
    const missing_header_values = try req.headerValues(testing.allocator, "x-missing");
    defer testing.allocator.free(missing_header_values);
    try testing.expect(!req.hasHeader("x-missing"));
    try testing.expectEqual(@as(usize, 0), missing_header_values.len);

    var query_params = try req.queryParams(testing.allocator);
    defer query_params.deinit();
    try testing.expectEqual(@as(usize, 3), query_params.len());
    try testing.expect(!query_params.isEmpty());
    try testing.expect(query_params.contains("q"));
    try testing.expect(!query_params.contains("missing"));
    try testing.expectEqualStrings("hello zig", query_params.get("q").?);
    try testing.expectEqualStrings("last tag", query_params.get("tag").?);
    const tags = query_params.getAll("tag").?;
    try testing.expectEqual(@as(usize, 2), tags.len);
    try testing.expectEqualStrings("first", tags[0]);
    try testing.expectEqualStrings("last tag", tags[1]);
    const query_items = query_params.multiItems();
    try testing.expectEqual(@as(usize, 4), query_items.len);
    const query_items_alias = query_params.items();
    try testing.expectEqual(@as(usize, 4), query_items_alias.len);
    try testing.expectEqualStrings("q", query_items[0].name);
    try testing.expectEqualStrings("hello zig", query_items[0].value);
    try testing.expectEqualStrings("tag", query_items[1].name);
    try testing.expectEqualStrings("first", query_items[1].value);
    try testing.expectEqualStrings("empty", query_items[2].name);
    try testing.expectEqualStrings("", query_items[2].value);
    try testing.expectEqualStrings("tag", query_items[3].name);
    try testing.expectEqualStrings("last tag", query_items[3].value);
    try testing.expect(query_params.get("missing") == null);

    const invalid_req = Request.init(.GET, "/raw?bad%ZZ=value");
    try testing.expectError(error.Validation, invalid_req.queryParam(testing.allocator, "bad"));
    try testing.expectError(error.Validation, invalid_req.queryParams(testing.allocator));
    const empty_query_req = Request.init(.GET, "/raw");
    var empty_query = try empty_query_req.queryParams(testing.allocator);
    defer empty_query.deinit();
    try testing.expectEqual(@as(usize, 0), empty_query.len());
    try testing.expect(empty_query.isEmpty());
    try testing.expectEqual(@as(usize, 0), empty_query.multiItems().len);
    var cookies = try req.cookies(testing.allocator);
    defer cookies.deinit();
    try testing.expectEqual(@as(usize, 2), cookies.len());
    try testing.expect(!cookies.isEmpty());
    try testing.expect(cookies.contains("theme"));
    try testing.expect(!cookies.contains("missing"));
    try testing.expectEqualStrings("dark", cookies.get("theme").?);
    try testing.expectEqualStrings("latest", cookies.get("session_id").?);
    try testing.expect(cookies.get("missing") == null);
    const cookie_items = try cookies.items(testing.allocator);
    defer testing.allocator.free(cookie_items);
    try testing.expectEqual(@as(usize, 2), cookie_items.len);
    var saw_theme = false;
    var saw_session = false;
    for (cookie_items) |item| {
        if (std.mem.eql(u8, item.name, "theme")) {
            saw_theme = true;
            try testing.expectEqualStrings("dark", item.value);
        } else if (std.mem.eql(u8, item.name, "session_id")) {
            saw_session = true;
            try testing.expectEqualStrings("latest", item.value);
        }
    }
    try testing.expect(saw_theme);
    try testing.expect(saw_session);
    try testing.expect(req.cookie("missing") == null);
    var empty_cookies = try empty_query_req.cookies(testing.allocator);
    defer empty_cookies.deinit();
    try testing.expectEqual(@as(usize, 0), empty_cookies.len());
    try testing.expect(empty_cookies.isEmpty());
}

test "request handler arguments expose matched path params" {
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    try app.route(Route.get("/method", echoRequestArgumentMethod, .{}));
    try app.route(Route.get("/request-path/{item}", echoRequestPathParams, .{}));
    try app.route(Route.get("/decoded-path/{item}", echoDecodedRequestPathParam, .{}));
    try app.route(Route.get("/decoded-paths/{category}/{item:path}", echoDecodedRequestPathParams, .{}));

    var method = try app.handle(Request.init(.GET, "/method"));
    defer method.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, method.status);
    try testing.expectEqualStrings("{\"method\":\"GET\"}", method.body.items);

    var raw = try app.handle(Request.init(.GET, "/request-path/zig%20api"));
    defer raw.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, raw.status);
    try testing.expectEqualStrings("{\"raw\":\"zig%20api\",\"missing\":true,\"method\":\"GET\"}", raw.body.items);

    var decoded = try app.handle(Request.init(.GET, "/decoded-path/zig%20api"));
    defer decoded.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, decoded.status);
    try testing.expectEqualStrings("{\"value\":\"zig api\"}", decoded.body.items);

    var decoded_params = try app.handle(Request.init(.GET, "/decoded-paths/books/zig%20api%2Ftail"));
    defer decoded_params.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, decoded_params.status);
    try testing.expectEqualStrings(
        "{\"raw_item\":\"zig%20api%2Ftail\",\"category\":\"books\",\"item\":\"zig api/tail\",\"missing\":true,\"count\":2,\"first_name\":\"category\",\"first_value\":\"books\",\"second_name\":\"item\",\"second_value\":\"zig api/tail\"}",
        decoded_params.body.items,
    );

    var bare = Request.init(.GET, "/request-path/zig");
    try testing.expect(bare.pathValue("item") == null);
    const missing_path_param = try bare.pathParam(testing.allocator, "item");
    try testing.expect(missing_path_param == null);
    var empty_path_params = try bare.pathParams(testing.allocator);
    defer empty_path_params.deinit();
    try testing.expectEqual(@as(usize, 0), empty_path_params.len());
    try testing.expect(empty_path_params.isEmpty());
}

test "request helpers negotiate content types and accept headers" {
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    try app.route(Route.post("/negotiate", echoNegotiation, .{}));

    var req = Request.init(.POST, "/negotiate");
    req.headers = &.{
        .{ .name = "content-type", .value = "Application/JSON; charset=utf-8" },
        .{ .name = "accept", .value = "text/html;q=0.9, application/json;q=0.4, text/plain;q=0" },
    };
    var response = try app.handle(req);
    defer response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, response.status);
    try testing.expectEqualStrings(
        "{\"content_type\":\"Application/JSON\",\"has_json\":true,\"accepts_json\":true,\"accepts_html\":true,\"preferred\":\"text/html\"}",
        response.body.items,
    );

    try testing.expectEqualStrings("Application/JSON", req.contentType().?);
    try testing.expect(req.hasContentType("application/json"));
    try testing.expect(req.hasContentType("application/json; charset=ignored"));
    try testing.expect(req.accepts("application/json"));
    try testing.expect(req.accepts("text/html"));
    try testing.expect(!req.accepts("text/plain"));
    try testing.expectEqualStrings("text/html", req.preferredAccepted(&.{ "application/json", "text/html" }).?);

    var wildcard_req = Request.init(.GET, "/");
    wildcard_req.headers = &.{.{ .name = "accept", .value = "application/*;q=0.8, */*;q=0.1" }};
    try testing.expect(wildcard_req.accepts("application/problem+json"));
    try testing.expect(wildcard_req.accepts("image/png"));
    try testing.expectEqualStrings("application/json", wildcard_req.preferredAccepted(&.{ "image/png", "application/json" }).?);

    var suffix_req = Request.init(.GET, "/");
    suffix_req.headers = &.{.{ .name = "accept", .value = "application/*+json" }};
    try testing.expect(suffix_req.accepts("application/problem+json"));
    try testing.expect(suffix_req.accepts("application/vnd.api+json"));
    try testing.expect(!suffix_req.accepts("application/json"));
    try testing.expectEqualStrings("application/problem+json", suffix_req.preferredAccepted(&.{ "application/xml", "application/problem+json" }).?);

    var suffix_preference_req = Request.init(.GET, "/");
    suffix_preference_req.headers = &.{.{ .name = "accept", .value = "application/*+json;q=0.8, application/*;q=0.4, */*;q=0.1" }};
    try testing.expectEqualStrings("application/problem+json", suffix_preference_req.preferredAccepted(&.{ "application/xml", "application/problem+json" }).?);
    try testing.expectEqualStrings("application/vnd.api+json", suffix_req.preferredAccepted(&.{ "application/vnd.api+json", "application/problem+json" }).?);

    var rejected_req = Request.init(.GET, "/");
    rejected_req.headers = &.{.{ .name = "accept", .value = "application/json;q=0, text/*;q=0.5" }};
    try testing.expect(!rejected_req.accepts("application/json"));
    try testing.expect(rejected_req.accepts("text/plain; charset=utf-8"));
    try testing.expectEqualStrings("text/plain", rejected_req.preferredAccepted(&.{ "application/json", "text/plain" }).?);

    var default_req = Request.init(.GET, "/");
    try testing.expect(default_req.accepts("application/json"));
    try testing.expectEqualStrings("application/json", default_req.preferredAccepted(&.{ "application/json", "text/html" }).?);
    try testing.expect(default_req.preferredAccepted(&.{}) == null);
    try testing.expect(default_req.contentType() == null);
    try testing.expect(!default_req.hasContentType("application/json"));

    var builder_req = Request.builder(testing.allocator, .POST, "/negotiate");
    defer builder_req.deinit();
    try builder_req.contentType("application/json; charset=utf-8");
    try builder_req.accept("text/plain, application/json;q=0.8");
    try builder_req.setBody("{}");
    var builder_response = try builder_req.send(&app);
    defer builder_response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, builder_response.status);
    try testing.expectEqualStrings(
        "{\"content_type\":\"application/json\",\"has_json\":true,\"accepts_json\":true,\"accepts_html\":false,\"preferred\":\"text/plain\"}",
        builder_response.body.items,
    );
}

test "request cookies parse browser-compatible edge cases" {
    var unnamed_req = Request.init(.GET, "/");
    unnamed_req.headers = &.{.{ .name = "cookie", .value = "abc=def; unnamed; django_language=en" }};
    var unnamed = try unnamed_req.cookies(testing.allocator);
    defer unnamed.deinit();
    try testing.expectEqual(@as(usize, 3), unnamed.len());
    try testing.expectEqualStrings("def", unnamed.get("abc").?);
    try testing.expectEqualStrings("unnamed", unnamed.get("").?);
    try testing.expectEqualStrings("en", unnamed.get("django_language").?);
    try testing.expectEqualStrings("unnamed", unnamed_req.cookie("").?);

    var quoted_unnamed_req = Request.init(.GET, "/");
    quoted_unnamed_req.headers = &.{.{ .name = "cookie", .value = "a=b; \"; c=d" }};
    var quoted_unnamed = try quoted_unnamed_req.cookies(testing.allocator);
    defer quoted_unnamed.deinit();
    try testing.expectEqual(@as(usize, 3), quoted_unnamed.len());
    try testing.expectEqualStrings("b", quoted_unnamed.get("a").?);
    try testing.expectEqualStrings("\"", quoted_unnamed.get("").?);
    try testing.expectEqualStrings("d", quoted_unnamed.get("c").?);

    var duplicate_req = Request.init(.GET, "/");
    duplicate_req.headers = &.{.{ .name = "cookie", .value = "a=b; h=i; a=c" }};
    var duplicate = try duplicate_req.cookies(testing.allocator);
    defer duplicate.deinit();
    try testing.expectEqual(@as(usize, 2), duplicate.len());
    try testing.expectEqualStrings("c", duplicate.get("a").?);
    try testing.expectEqualStrings("c", duplicate_req.cookie("a").?);
    try testing.expectEqualStrings("i", duplicate.get("h").?);

    var spaces_req = Request.init(.GET, "/");
    spaces_req.headers = &.{.{ .name = "cookie", .value = "a b c=d e = f; gh=i" }};
    var spaces = try spaces_req.cookies(testing.allocator);
    defer spaces.deinit();
    try testing.expectEqualStrings("d e = f", spaces.get("a b c").?);
    try testing.expectEqualStrings("i", spaces.get("gh").?);

    var quoted_value_req = Request.init(.GET, "/");
    quoted_value_req.headers = &.{.{ .name = "cookie", .value = "theme=\"dark mode\"; broken=\"left; empty=\"\"" }};
    var quoted_value = try quoted_value_req.cookies(testing.allocator);
    defer quoted_value.deinit();
    try testing.expectEqualStrings("dark mode", quoted_value.get("theme").?);
    try testing.expectEqualStrings("\"left", quoted_value.get("broken").?);
    try testing.expectEqualStrings("", quoted_value.get("empty").?);
    try testing.expectEqualStrings("dark mode", quoted_value_req.cookie("theme").?);
}

test "request cookies merge multiple cookie headers" {
    var req = Request.init(.GET, "/");
    req.headers = &.{
        .{ .name = "cookie", .value = "a=abc" },
        .{ .name = "cookie", .value = "b=def" },
        .{ .name = "cookie", .value = "c=ghi" },
    };

    var cookies = try req.cookies(testing.allocator);
    defer cookies.deinit();
    try testing.expectEqual(@as(usize, 3), cookies.len());
    try testing.expectEqualStrings("abc", cookies.get("a").?);
    try testing.expectEqualStrings("def", cookies.get("b").?);
    try testing.expectEqualStrings("ghi", cookies.get("c").?);
}

test "request builder owns headers cookies and bodies for app handle" {
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    try app.route(Route.get("/raw/{item:path}", echoRawRequest, .{}));
    try app.route(Route.get("/tags", searchTags, .{}));
    try app.route(Route.post("/raw-body", echoRawBody, .{}));
    try app.route(Route.post("/raw-form-data", echoRawFormData, .{}));
    try app.route(Route.post("/users", createUser, .{ .status = .created }));
    try app.route(Route.post("/login", login, .{}));
    try app.route(Route.post("/preferences", preferences, .{}));
    try app.route(Route.post("/gallery", uploadGallery, .{}));
    try app.route(Route.get("/client", echoRequestClient, .{}));

    var raw = Request.builder(testing.allocator, .GET, "/raw/zig?empty=");
    defer raw.deinit();
    try raw.queryParam("q", "hello zig");
    try raw.queryParam("tag", "first");
    try raw.queryParam("tag", "last");
    try raw.header("x-token", "first");
    try raw.header("X-Token", "second");
    try raw.cookie("theme", "dark");
    try raw.cookie("session_id", "latest");

    var raw_response = try raw.send(&app);
    defer raw_response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, raw_response.status);
    try testing.expectEqualStrings(
        "{\"item\":\"zig\",\"token\":\"first\",\"tokens\":[\"first\",\"second\"],\"missing_header_count\":0,\"q\":\"hello zig\",\"tag\":\"last\",\"tags\":[\"first\",\"last\"],\"empty\":\"\",\"missing_query\":true,\"theme\":\"dark\",\"session\":\"latest\",\"missing_cookie\":true}",
        raw_response.body.items,
    );

    var header_controls = Request.builder(testing.allocator, .GET, "/raw/zig");
    defer header_controls.deinit();
    try header_controls.header("x-token", "first");
    try header_controls.header("X-Token", "second");
    header_controls.removeHeader("x-token");
    try header_controls.header("x-token", "restored");

    var removed_headers_response = try header_controls.send(&app);
    defer removed_headers_response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, removed_headers_response.status);
    try testing.expectEqualStrings(
        "{\"item\":\"zig\",\"token\":\"restored\",\"tokens\":[\"restored\"],\"missing_header_count\":0,\"q\":\"\",\"tag\":\"\",\"tags\":[],\"empty\":\"\",\"missing_query\":true,\"theme\":\"\",\"session\":\"\",\"missing_cookie\":true}",
        removed_headers_response.body.items,
    );

    header_controls.clearHeaders();
    var cleared_headers_response = try header_controls.send(&app);
    defer cleared_headers_response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, cleared_headers_response.status);
    try testing.expectEqualStrings(
        "{\"item\":\"zig\",\"token\":\"\",\"tokens\":[],\"missing_header_count\":0,\"q\":\"\",\"tag\":\"\",\"tags\":[],\"empty\":\"\",\"missing_query\":true,\"theme\":\"\",\"session\":\"\",\"missing_cookie\":true}",
        cleared_headers_response.body.items,
    );

    var replaced_query = Request.builder(testing.allocator, .GET, "/raw/zig?q=initial&tag=first&empty=&encoded%20key=gone");
    defer replaced_query.deinit();
    try replaced_query.queryParam("tag", "second");
    try replaced_query.setQueryParam("q", "overridden");
    try replaced_query.removeQueryParam("tag");
    try replaced_query.removeQueryParam("encoded key");
    try replaced_query.queryParam("tag", "final");
    var replaced_query_response = try replaced_query.send(&app);
    defer replaced_query_response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, replaced_query_response.status);
    try testing.expectEqualStrings(
        "{\"item\":\"zig\",\"token\":\"\",\"tokens\":[],\"missing_header_count\":0,\"q\":\"overridden\",\"tag\":\"final\",\"tags\":[\"final\"],\"empty\":\"\",\"missing_query\":true,\"theme\":\"\",\"session\":\"\",\"missing_cookie\":true}",
        replaced_query_response.body.items,
    );

    var cleared_query = Request.builder(testing.allocator, .GET, "/raw/zig?q=initial&tag=first");
    defer cleared_query.deinit();
    cleared_query.clearQueryParams();
    try cleared_query.queryParam("q", "fresh");
    var cleared_query_response = try cleared_query.send(&app);
    defer cleared_query_response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, cleared_query_response.status);
    try testing.expectEqualStrings(
        "{\"item\":\"zig\",\"token\":\"\",\"tokens\":[],\"missing_header_count\":0,\"q\":\"fresh\",\"tag\":\"\",\"tags\":[],\"empty\":\"\",\"missing_query\":true,\"theme\":\"\",\"session\":\"\",\"missing_cookie\":true}",
        cleared_query_response.body.items,
    );

    var invalid_query = Request.builder(testing.allocator, .GET, "/raw/zig?bad%ZZ=value");
    defer invalid_query.deinit();
    try testing.expectError(error.Validation, invalid_query.removeQueryParam("bad"));

    var tags = Request.builder(testing.allocator, .GET, "/tags");
    defer tags.deinit();
    try tags.queryParam("tag", "zig api");
    try tags.queryParam("tag", "web+framework");
    try tags.queryParam("limit", "10");
    try tags.queryParam("limit", "20");
    var tags_response = try tags.send(&app);
    defer tags_response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, tags_response.status);
    try testing.expectEqualStrings("{\"tags\":[\"zig api\",\"web+framework\"],\"limits\":[10,20]}", tags_response.body.items);

    var typed_tags = Request.builder(testing.allocator, .GET, "/tags?tag=existing");
    defer typed_tags.deinit();
    try typed_tags.queryValue(.{
        .tag = [_][]const u8{ "zig api", "web+framework" },
        .limit = [_]u32{ 10, 20 },
        .missing = @as(?[]const u8, null),
    });
    var typed_tags_response = try typed_tags.send(&app);
    defer typed_tags_response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, typed_tags_response.status);
    try testing.expectEqualStrings("{\"tags\":[\"existing\",\"zig api\",\"web+framework\"],\"limits\":[10,20]}", typed_tags_response.body.items);

    var json = Request.builder(testing.allocator, .POST, "/users");
    defer json.deinit();
    try json.json("{\"email\":\"ada@example.com\"}");
    var json_response = try json.send(&app);
    defer json_response.deinit(testing.allocator);
    try testing.expectEqual(Status.created, json_response.status);
    try testing.expectEqualStrings("{\"id\":1,\"email\":\"ada@example.com\"}", json_response.body.items);

    var json_value = Request.builder(testing.allocator, .POST, "/users");
    defer json_value.deinit();
    try json_value.jsonValue(CreateUser{ .email = "quoted \"user\"\n@example.com" });
    var json_value_response = try json_value.send(&app);
    defer json_value_response.deinit(testing.allocator);
    try testing.expectEqual(Status.created, json_value_response.status);
    var json_value_user = try json_value_response.json(TestUser, testing.allocator);
    defer json_value_user.deinit();
    try testing.expectEqualStrings("quoted \"user\"\n@example.com", json_value_user.value.email);

    var raw_body = Request.builder(testing.allocator, .POST, "/raw-body");
    defer raw_body.deinit();
    try raw_body.setBody("hello\nzapi");
    var raw_body_response = try raw_body.send(&app);
    defer raw_body_response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, raw_body_response.status);
    try testing.expectEqualStrings("{\"text\":\"hello\\nzapi\",\"bytes_len\":10,\"content_len\":10}", raw_body_response.body.items);

    var form = Request.builder(testing.allocator, .POST, "/login");
    defer form.deinit();
    try form.form("username=ada&password=secret&remember=yes&attempts=2");
    var form_response = try form.send(&app);
    defer form_response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, form_response.status);
    try testing.expectEqualStrings("{\"username\":\"ada\",\"remember\":true,\"attempts\":2}", form_response.body.items);

    var form_fields = Request.builder(testing.allocator, .POST, "/login");
    defer form_fields.deinit();
    try form_fields.formField("username", "ada lovelace");
    try form_fields.formField("password", "s/ecret value");
    try form_fields.formField("remember", "true");
    try form_fields.formField("attempts", "3");
    var form_fields_response = try form_fields.send(&app);
    defer form_fields_response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, form_fields_response.status);
    try testing.expectEqualStrings("{\"username\":\"ada lovelace\",\"remember\":true,\"attempts\":3}", form_fields_response.body.items);

    var form_value = Request.builder(testing.allocator, .POST, "/login");
    defer form_value.deinit();
    try form_value.formValue(.{
        .username = "grace hopper",
        .password = "s/ecret value",
        .remember = true,
        .attempts = @as(u8, 4),
        .unused = @as(?[]const u8, null),
    });
    var form_value_response = try form_value.send(&app);
    defer form_value_response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, form_value_response.status);
    try testing.expectEqualStrings("{\"username\":\"grace hopper\",\"remember\":true,\"attempts\":4}", form_value_response.body.items);

    var repeated_form_value = Request.builder(testing.allocator, .POST, "/preferences");
    defer repeated_form_value.deinit();
    try repeated_form_value.formValue(.{
        .username = "ada lovelace",
        .tag = [_][]const u8{ "zig api", "web+framework" },
        .level = [_]u32{ 1, 2 },
        .skip = @as(?[]const u8, null),
    });
    var repeated_form_value_response = try repeated_form_value.send(&app);
    defer repeated_form_value_response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, repeated_form_value_response.status);
    try testing.expectEqualStrings("{\"username\":\"ada lovelace\",\"tags\":[\"zig api\",\"web+framework\"],\"levels\":[1,2]}", repeated_form_value_response.body.items);

    var replaced_json_form = Request.builder(testing.allocator, .POST, "/login");
    defer replaced_json_form.deinit();
    try replaced_json_form.json("{\"username\":\"wrong\"}");
    try replaced_json_form.formField("username", "grace hopper");
    try replaced_json_form.formField("password", "secret");
    var replaced_json_form_response = try replaced_json_form.send(&app);
    defer replaced_json_form_response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, replaced_json_form_response.status);
    try testing.expectEqualStrings("{\"username\":\"grace hopper\",\"remember\":false,\"attempts\":1}", replaced_json_form_response.body.items);

    var replaced_form_json = Request.builder(testing.allocator, .POST, "/users");
    defer replaced_form_json.deinit();
    try replaced_form_json.formField("email", "wrong@example.com");
    try replaced_form_json.jsonValue(CreateUser{ .email = "json-wins@example.com" });
    var replaced_form_json_response = try replaced_form_json.send(&app);
    defer replaced_form_json_response.deinit(testing.allocator);
    try testing.expectEqual(Status.created, replaced_form_json_response.status);
    var replaced_form_json_user = try replaced_form_json_response.json(TestUser, testing.allocator);
    defer replaced_form_json_user.deinit();
    try testing.expectEqualStrings("json-wins@example.com", replaced_form_json_user.value.email);

    var extended_raw_form = Request.builder(testing.allocator, .POST, "/login");
    defer extended_raw_form.deinit();
    try extended_raw_form.form("username=grace&password=secret");
    try extended_raw_form.formField("attempts", "4");
    var extended_raw_form_response = try extended_raw_form.send(&app);
    defer extended_raw_form_response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, extended_raw_form_response.status);
    try testing.expectEqualStrings("{\"username\":\"grace\",\"remember\":false,\"attempts\":4}", extended_raw_form_response.body.items);

    var multipart = Request.builder(testing.allocator, .POST, "/raw-form-data");
    defer multipart.deinit();
    try multipart.multipartField("title", "Quarterly report");
    try multipart.multipartFile("document", "report.txt", "text/plain", "hello file");
    var multipart_response = try multipart.send(&app);
    defer multipart_response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, multipart_response.status);
    try testing.expectEqualStrings("{\"title\":\"Quarterly report\",\"filename\":\"report.txt\",\"content_type\":\"text/plain\",\"content\":\"hello file\",\"file_count\":1}", multipart_response.body.items);

    var replaced_form_multipart = Request.builder(testing.allocator, .POST, "/raw-form-data");
    defer replaced_form_multipart.deinit();
    try replaced_form_multipart.formField("title", "wrong");
    try replaced_form_multipart.multipartField("title", "Field report");
    try replaced_form_multipart.multipartFile("document", "report.txt", "text/plain", "hello file");
    var replaced_form_multipart_response = try replaced_form_multipart.send(&app);
    defer replaced_form_multipart_response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, replaced_form_multipart_response.status);
    try testing.expectEqualStrings("{\"title\":\"Field report\",\"filename\":\"report.txt\",\"content_type\":\"text/plain\",\"content\":\"hello file\",\"file_count\":1}", replaced_form_multipart_response.body.items);

    var gallery = Request.builder(testing.allocator, .POST, "/gallery");
    defer gallery.deinit();
    try gallery.multipartField("username", "ada");
    try gallery.multipartFile("photos", "one.txt", "text/plain", "one");
    try gallery.multipartFile("photos", "two.txt", "text/plain", "two-two");
    var gallery_response = try gallery.send(&app);
    defer gallery_response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, gallery_response.status);
    try testing.expectEqualStrings("{\"username\":\"ada\",\"first_filename\":\"one.txt\",\"second_filename\":\"two.txt\",\"total_size\":10}", gallery_response.body.items);

    var invalid_cookie = Request.builder(testing.allocator, .GET, "/raw/zig");
    defer invalid_cookie.deinit();
    try testing.expectError(error.InvalidCookie, invalid_cookie.cookie("bad name", "value"));

    var invalid_multipart = Request.builder(testing.allocator, .POST, "/raw-form-data");
    defer invalid_multipart.deinit();
    try testing.expectError(error.InvalidHeader, invalid_multipart.multipartField("bad\"name", "value"));

    var client_request = Request.builder(testing.allocator, .GET, "/client");
    defer client_request.deinit();
    client_request.client(.{ .host = "198.51.100.7", .port = 8181 });
    var client_response = try client_request.send(&app);
    defer client_response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, client_response.status);
    try testing.expectEqualStrings("{\"host\":\"198.51.100.7\",\"port\":8181}", client_response.body.items);
}

test "response json helper parses typed response bodies" {
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    try app.route(Route.post("/users", createUser, .{ .status = .created }));
    try app.route(Route.get("/users/bulk", listCreateUsers, .{}));

    var request = Request.builder(testing.allocator, .POST, "/users");
    defer request.deinit();
    try request.json("{\"email\":\"ada@example.com\"}");

    var response = try request.send(&app);
    defer response.deinit(testing.allocator);
    try testing.expectEqual(Status.created, response.status);

    var user = try response.json(TestUser, testing.allocator);
    defer user.deinit();
    try testing.expectEqual(@as(u64, 1), user.value.id);
    try testing.expectEqualStrings("ada@example.com", user.value.email);

    var list_response = try app.handle(Request.init(.GET, "/users/bulk"));
    defer list_response.deinit(testing.allocator);
    var users = try list_response.json([]const CreateUser, testing.allocator);
    defer users.deinit();
    try testing.expectEqual(@as(usize, 2), users.value.len);
    try testing.expectEqualStrings("ada@example.com", users.value[0].email);
    try testing.expectEqualStrings("grace@example.com", users.value[1].email);
}

test "request builder can follow redirects like an in-process client" {
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    try app.route(Route.get("/users", plainText, .{}));
    try app.route(Route.get("/redirect", redirectToUsers, .{}));
    try app.route(Route.get("/old/path", relativeDotRedirect, .{}));
    try app.route(Route.get("/new/target", echoRequestTarget, .{}));
    try app.route(Route.post("/found", foundRedirectToUsers, .{}));
    try app.route(Route.post("/found-headers", foundRedirectToRequestHeaders, .{}));
    try app.route(Route.post("/moved", movedRedirectToUsers, .{}));
    try app.route(Route.post("/see-other", seeOtherRedirectToUsers, .{}));
    try app.route(Route.get("/absolute-dot", absoluteDotRedirect, .{}));
    try app.route(Route.get("/scheme-relative", schemeRelativeRedirect, .{}));
    try app.route(Route.get("/external-scheme-relative", externalSchemeRelativeRedirect, .{}));
    try app.route(Route.get("/external-absolute-dot", externalAbsoluteDotRedirect, .{}));
    try app.route(Route.get("/redirect-set-cookie", redirectWithCookie, .{}));
    try app.route(Route.get("/redirect-delete-cookie", redirectDeletingCookie, .{}));
    try app.route(Route.get("/redirect-cookies", echoRedirectCookies, .{}));
    try app.route(Route.post("/temporary", temporaryRedirectToEcho, .{}));
    try app.route(Route.post("/temporary-headers", temporaryRedirectToRequestHeaders, .{}));
    try app.route(Route.post("/permanent", permanentRedirectToEcho, .{}));
    try app.route(Route.post("/echo-request", echoMethodAndBody, .{}));
    try app.route(Route.get("/echo-request-headers", echoMethodBodyAndContentType, .{}));
    try app.route(Route.post("/echo-request-headers", echoMethodBodyAndContentType, .{}));
    try app.route(Route.get("/absolute", absoluteRedirectToUsers, .{}));
    try app.route(Route.get("/external", externalRedirect, .{}));
    try app.route(Route.get("/loop", redirectLoop, .{}));
    try app.route(Route.get("/redirect-unhandled", redirectToUnhandled, .{}));
    try app.route(Route.get("/unhandled", unhandledFailingRoute, .{}));
    try app.route(Route.get("/client", echoRequestClient, .{}));
    try app.route(Route.get("/redirect-client", redirectToClientEcho, .{}));

    var no_follow = Request.builder(testing.allocator, .GET, "/redirect");
    defer no_follow.deinit();
    var redirect = try no_follow.send(&app);
    defer redirect.deinit(testing.allocator);
    try testing.expectEqual(Status.temporary_redirect, redirect.status);
    try testing.expect(redirect.isRedirect());
    try testing.expectEqualStrings("/users", redirect.header("location").?);
    try testing.expectEqualStrings("/users", redirect.location().?);
    try testing.expect(try redirect.nextUrl(testing.allocator) == null);

    var get_request = Request.builder(testing.allocator, .GET, "/redirect");
    defer get_request.deinit();
    var get_response = try get_request.sendFollowRedirects(&app, .{});
    defer get_response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, get_response.status);
    try testing.expectEqualStrings("Hello, world", get_response.body.items);
    try testing.expectEqual(@as(usize, 1), get_response.history.items.len);
    try testing.expectEqual(Status.temporary_redirect, get_response.history.items[0].status);
    try testing.expectEqualStrings("/users", get_response.history.items[0].header("location").?);

    var relative_dot = Request.builder(testing.allocator, .GET, "/old/path");
    defer relative_dot.deinit();
    var relative_dot_response = try relative_dot.sendFollowRedirects(&app, .{});
    defer relative_dot_response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, relative_dot_response.status);
    try testing.expectEqualStrings("{\"scheme\":\"http\",\"host\":\"\",\"root_path\":\"\",\"path\":\"/new/target\",\"query\":\"x=1\"}", relative_dot_response.body.items);

    var found = Request.builder(testing.allocator, .POST, "/found");
    defer found.deinit();
    try found.setBody("dropped");
    var found_response = try found.sendFollowRedirects(&app, .{});
    defer found_response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, found_response.status);
    try testing.expectEqualStrings("Hello, world", found_response.body.items);
    try testing.expectEqual(Status.found, found_response.history.items[0].status);

    var moved = Request.builder(testing.allocator, .POST, "/moved");
    defer moved.deinit();
    try moved.setBody("dropped");
    var moved_response = try moved.sendFollowRedirects(&app, .{});
    defer moved_response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, moved_response.status);
    try testing.expectEqualStrings("Hello, world", moved_response.body.items);
    try testing.expectEqual(Status.moved_permanently, moved_response.history.items[0].status);

    var see_other = Request.builder(testing.allocator, .POST, "/see-other");
    defer see_other.deinit();
    try see_other.setBody("dropped");
    var see_other_response = try see_other.sendFollowRedirects(&app, .{});
    defer see_other_response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, see_other_response.status);
    try testing.expectEqualStrings("Hello, world", see_other_response.body.items);
    try testing.expectEqual(Status.see_other, see_other_response.history.items[0].status);

    var found_headers = Request.builder(testing.allocator, .POST, "/found-headers");
    defer found_headers.deinit();
    try found_headers.json("{\"dropped\":true}");
    var found_headers_response = try found_headers.sendFollowRedirects(&app, .{});
    defer found_headers_response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, found_headers_response.status);
    try testing.expectEqualStrings("{\"method\":\"GET\",\"body\":\"\",\"content_type\":null}", found_headers_response.body.items);

    var temporary = Request.builder(testing.allocator, .POST, "/temporary");
    defer temporary.deinit();
    try temporary.setBody("preserved");
    var temporary_response = try temporary.sendFollowRedirects(&app, .{});
    defer temporary_response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, temporary_response.status);
    try testing.expectEqualStrings("{\"method\":\"POST\",\"body\":\"preserved\"}", temporary_response.body.items);

    var temporary_headers = Request.builder(testing.allocator, .POST, "/temporary-headers");
    defer temporary_headers.deinit();
    try temporary_headers.json("{\"preserved\":true}");
    var temporary_headers_response = try temporary_headers.sendFollowRedirects(&app, .{});
    defer temporary_headers_response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, temporary_headers_response.status);
    try testing.expectEqualStrings("{\"method\":\"POST\",\"body\":\"{\\\"preserved\\\":true}\",\"content_type\":\"application/json\"}", temporary_headers_response.body.items);

    var permanent = Request.builder(testing.allocator, .POST, "/permanent");
    defer permanent.deinit();
    try permanent.setBody("preserved");
    var permanent_response = try permanent.sendFollowRedirects(&app, .{});
    defer permanent_response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, permanent_response.status);
    try testing.expectEqualStrings("{\"method\":\"POST\",\"body\":\"preserved\"}", permanent_response.body.items);
    try testing.expectEqual(Status.permanent_redirect, permanent_response.history.items[0].status);

    var absolute = Request.builder(testing.allocator, .GET, "/absolute");
    defer absolute.deinit();
    try absolute.header("host", "example.test");
    var absolute_response = try absolute.sendFollowRedirects(&app, .{});
    defer absolute_response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, absolute_response.status);
    try testing.expectEqualStrings("Hello, world", absolute_response.body.items);

    var absolute_dot = Request.builder(testing.allocator, .GET, "/absolute-dot");
    defer absolute_dot.deinit();
    try absolute_dot.header("host", "example.test");
    var absolute_dot_response = try absolute_dot.sendFollowRedirects(&app, .{});
    defer absolute_dot_response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, absolute_dot_response.status);
    try testing.expectEqualStrings("{\"scheme\":\"https\",\"host\":\"example.test\",\"root_path\":\"\",\"path\":\"/new/target\",\"query\":\"abs=1\"}", absolute_dot_response.body.items);

    var scheme_relative = Request.builder(testing.allocator, .GET, "/scheme-relative");
    defer scheme_relative.deinit();
    scheme_relative.scheme("https");
    try scheme_relative.header("host", "example.test");
    var scheme_relative_response = try scheme_relative.sendFollowRedirects(&app, .{});
    defer scheme_relative_response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, scheme_relative_response.status);
    try testing.expectEqualStrings("{\"scheme\":\"https\",\"host\":\"example.test\",\"root_path\":\"\",\"path\":\"/new/target\",\"query\":\"proto=1\"}", scheme_relative_response.body.items);

    var cookie_redirect = Request.builder(testing.allocator, .GET, "/redirect-set-cookie");
    defer cookie_redirect.deinit();
    try cookie_redirect.cookie("theme", "dark");
    try cookie_redirect.cookie("session", "initial");
    var cookie_response = try cookie_redirect.sendFollowRedirects(&app, .{});
    defer cookie_response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, cookie_response.status);
    try testing.expectEqualStrings("{\"session\":\"redirected\",\"theme\":\"dark\"}", cookie_response.body.items);
    try testing.expectEqual(@as(usize, 1), cookie_response.history.items.len);
    var redirect_cookies = try cookie_response.history.items[0].cookies(testing.allocator);
    defer redirect_cookies.deinit();
    try testing.expectEqualStrings("redirected", redirect_cookies.get("session").?);

    var delete_cookie_redirect = Request.builder(testing.allocator, .GET, "/redirect-delete-cookie");
    defer delete_cookie_redirect.deinit();
    try delete_cookie_redirect.cookie("theme", "dark");
    try delete_cookie_redirect.cookie("session", "initial");
    var delete_cookie_response = try delete_cookie_redirect.sendFollowRedirects(&app, .{});
    defer delete_cookie_response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, delete_cookie_response.status);
    try testing.expectEqualStrings("{\"session\":null,\"theme\":\"dark\"}", delete_cookie_response.body.items);

    var external_scheme_relative = Request.builder(testing.allocator, .GET, "/external-scheme-relative");
    defer external_scheme_relative.deinit();
    external_scheme_relative.scheme("https");
    try external_scheme_relative.header("host", "example.test");
    var external_scheme_relative_response = try external_scheme_relative.sendFollowRedirects(&app, .{});
    defer external_scheme_relative_response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, external_scheme_relative_response.status);
    try testing.expectEqualStrings("{\"scheme\":\"https\",\"host\":\"external.test\",\"root_path\":\"\",\"path\":\"/new/target\",\"query\":\"\"}", external_scheme_relative_response.body.items);

    var external_absolute_dot = Request.builder(testing.allocator, .GET, "/external-absolute-dot");
    defer external_absolute_dot.deinit();
    try external_absolute_dot.header("host", "example.test");
    var external_absolute_dot_response = try external_absolute_dot.sendFollowRedirects(&app, .{});
    defer external_absolute_dot_response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, external_absolute_dot_response.status);
    try testing.expectEqualStrings("{\"scheme\":\"https\",\"host\":\"elsewhere.test\",\"root_path\":\"\",\"path\":\"/new/target\",\"query\":\"external=1\"}", external_absolute_dot_response.body.items);

    var external = Request.builder(testing.allocator, .GET, "/external");
    defer external.deinit();
    try external.header("host", "example.test");
    var external_response = try external.sendFollowRedirects(&app, .{});
    defer external_response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, external_response.status);
    try testing.expectEqualStrings("Hello, world", external_response.body.items);

    var loop = Request.builder(testing.allocator, .GET, "/loop");
    defer loop.deinit();
    try testing.expectError(error.TooManyRedirects, loop.sendFollowRedirects(&app, .{ .max_redirects = 2 }));

    var captured_unhandled = Request.builder(testing.allocator, .GET, "/redirect-unhandled");
    defer captured_unhandled.deinit();
    var captured_unhandled_response = try captured_unhandled.sendFollowRedirects(&app, .{});
    defer captured_unhandled_response.deinit(testing.allocator);
    try testing.expectEqual(Status.internal_server_error, captured_unhandled_response.status);
    try testing.expectEqualStrings("{\"detail\":\"Internal server error\"}", captured_unhandled_response.body.items);
    try testing.expectEqual(@as(usize, 1), captured_unhandled_response.history.items.len);
    try testing.expectEqual(Status.found, captured_unhandled_response.history.items[0].status);

    var raised_unhandled = Request.builder(testing.allocator, .GET, "/redirect-unhandled");
    defer raised_unhandled.deinit();
    try testing.expectError(error.UnhandledBoom, raised_unhandled.sendFollowRedirectsOrRaise(&app, .{}));

    var client_redirect = Request.builder(testing.allocator, .GET, "/redirect-client");
    defer client_redirect.deinit();
    client_redirect.client(.{ .host = "198.51.100.9", .port = 9191 });
    var client_redirect_response = try client_redirect.sendFollowRedirects(&app, .{});
    defer client_redirect_response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, client_redirect_response.status);
    try testing.expectEqualStrings("{\"host\":\"198.51.100.9\",\"port\":9191}", client_redirect_response.body.items);

    var client = TestClient.init(testing.allocator, &app, .{});
    defer client.deinit();
    var client_relative_dot = try client.get("/old/path");
    defer client_relative_dot.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, client_relative_dot.status);
    try testing.expectEqualStrings("{\"scheme\":\"http\",\"host\":\"testserver\",\"root_path\":\"\",\"path\":\"/new/target\",\"query\":\"x=1\"}", client_relative_dot.body.items);

    var client_redirect_request = client.request(.GET, "/redirect");
    defer client_redirect_request.deinit();
    var client_no_follow_redirect = try client.sendNoRedirects(&client_redirect_request);
    defer client_no_follow_redirect.deinit(testing.allocator);
    try testing.expectEqual(Status.temporary_redirect, client_no_follow_redirect.status);
    try testing.expectEqualStrings("/users", client_no_follow_redirect.location().?);
    const client_redirect_next = (try client_no_follow_redirect.nextUrl(testing.allocator)).?;
    defer testing.allocator.free(client_redirect_next);
    try testing.expectEqualStrings("http://testserver/users", client_redirect_next);

    var client_relative_dot_request = client.request(.GET, "/old/path");
    defer client_relative_dot_request.deinit();
    var client_relative_dot_redirect = try client.sendNoRedirects(&client_relative_dot_request);
    defer client_relative_dot_redirect.deinit(testing.allocator);
    const client_relative_dot_next = (try client_relative_dot_redirect.nextUrl(testing.allocator)).?;
    defer testing.allocator.free(client_relative_dot_next);
    try testing.expectEqualStrings("http://testserver/new/target?x=1", client_relative_dot_next);

    var client_found_headers = try client.postJson("/found-headers", "{\"dropped\":true}");
    defer client_found_headers.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, client_found_headers.status);
    try testing.expectEqualStrings("{\"method\":\"GET\",\"body\":\"\",\"content_type\":null}", client_found_headers.body.items);

    var client_temporary_headers = try client.postJson("/temporary-headers", "{\"preserved\":true}");
    defer client_temporary_headers.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, client_temporary_headers.status);
    try testing.expectEqualStrings("{\"method\":\"POST\",\"body\":\"{\\\"preserved\\\":true}\",\"content_type\":\"application/json\"}", client_temporary_headers.body.items);

    var same_host_client = TestClient.init(testing.allocator, &app, .{ .base_url = "http://example.test" });
    defer same_host_client.deinit();
    var client_absolute_dot = try same_host_client.get("/absolute-dot");
    defer client_absolute_dot.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, client_absolute_dot.status);
    try testing.expectEqualStrings("{\"scheme\":\"https\",\"host\":\"example.test\",\"root_path\":\"\",\"path\":\"/new/target\",\"query\":\"abs=1\"}", client_absolute_dot.body.items);

    var client_absolute_dot_request = same_host_client.request(.GET, "/absolute-dot");
    defer client_absolute_dot_request.deinit();
    var client_absolute_dot_redirect = try same_host_client.sendNoRedirects(&client_absolute_dot_request);
    defer client_absolute_dot_redirect.deinit(testing.allocator);
    const client_absolute_dot_next = (try client_absolute_dot_redirect.nextUrl(testing.allocator)).?;
    defer testing.allocator.free(client_absolute_dot_next);
    try testing.expectEqualStrings("https://example.test/new/target?abs=1", client_absolute_dot_next);

    var secure_same_host_client = TestClient.init(testing.allocator, &app, .{ .base_url = "https://example.test" });
    defer secure_same_host_client.deinit();
    var client_scheme_relative = try secure_same_host_client.get("/scheme-relative");
    defer client_scheme_relative.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, client_scheme_relative.status);
    try testing.expectEqualStrings("{\"scheme\":\"https\",\"host\":\"example.test\",\"root_path\":\"\",\"path\":\"/new/target\",\"query\":\"proto=1\"}", client_scheme_relative.body.items);

    var client_scheme_relative_request = secure_same_host_client.request(.GET, "/scheme-relative");
    defer client_scheme_relative_request.deinit();
    var client_scheme_relative_redirect = try secure_same_host_client.sendNoRedirects(&client_scheme_relative_request);
    defer client_scheme_relative_redirect.deinit(testing.allocator);
    const client_scheme_relative_next = (try client_scheme_relative_redirect.nextUrl(testing.allocator)).?;
    defer testing.allocator.free(client_scheme_relative_next);
    try testing.expectEqualStrings("https://example.test/new/target?proto=1", client_scheme_relative_next);

    var client_external_scheme_relative = try secure_same_host_client.get("/external-scheme-relative");
    defer client_external_scheme_relative.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, client_external_scheme_relative.status);
    try testing.expectEqualStrings("{\"scheme\":\"https\",\"host\":\"external.test\",\"root_path\":\"\",\"path\":\"/new/target\",\"query\":\"\"}", client_external_scheme_relative.body.items);

    var direct_scheme_relative = try secure_same_host_client.get("//external.test/new/target?direct=1");
    defer direct_scheme_relative.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, direct_scheme_relative.status);
    try testing.expectEqualStrings("https://external.test/new/target?direct=1", direct_scheme_relative.requestUrl().?);
    try testing.expectEqualStrings("{\"scheme\":\"https\",\"host\":\"external.test\",\"root_path\":\"\",\"path\":\"/new/target\",\"query\":\"direct=1\"}", direct_scheme_relative.body.items);

    var rooted_client = TestClient.init(testing.allocator, &app, .{ .base_url = "https://example.test/root" });
    defer rooted_client.deinit();
    var rooted_scheme_relative = try rooted_client.get("//external.test/root/new/target?direct=1");
    defer rooted_scheme_relative.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, rooted_scheme_relative.status);
    try testing.expectEqualStrings("https://external.test/root/new/target?direct=1", rooted_scheme_relative.requestUrl().?);
    try testing.expectEqualStrings("{\"scheme\":\"https\",\"host\":\"external.test\",\"root_path\":\"/root\",\"path\":\"/new/target\",\"query\":\"direct=1\"}", rooted_scheme_relative.body.items);

    var client_external_absolute_dot = try same_host_client.get("/external-absolute-dot");
    defer client_external_absolute_dot.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, client_external_absolute_dot.status);
    try testing.expectEqualStrings("{\"scheme\":\"https\",\"host\":\"elsewhere.test\",\"root_path\":\"\",\"path\":\"/new/target\",\"query\":\"external=1\"}", client_external_absolute_dot.body.items);
}

test "test client keeps default headers and cookies across requests" {
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    try app.route(Route.get("/headers", echoHeaders, .{}));
    try app.route(Route.get("/set-cookie", setCookieResponse, .{}));
    try app.route(Route.get("/delete-cookie", deleteCookieResponse, .{}));
    try app.route(Route.get("/expires-delete-cookie", expiresOnlyDeleteCookieResponse, .{}));
    try app.route(Route.get("/non-empty-max-age-delete-cookie", nonEmptyMaxAgeDeleteCookieResponse, .{}));
    try app.route(Route.get("/non-empty-expires-delete-cookie", nonEmptyExpiresDeleteCookieResponse, .{}));
    try app.route(Route.get("/max-age-precedence-cookie", maxAgePrecedenceCookieResponse, .{}));
    try app.route(Route.get("/redirect-set-cookie", redirectWithCookie, .{}));
    try app.route(Route.get("/redirect-delete-cookie", redirectDeletingCookie, .{}));
    try app.route(Route.get("/redirect-cookies", echoRedirectCookies, .{}));

    var client = TestClient.init(testing.allocator, &app, .{ .base_url = "https://testclient" });
    defer client.deinit();
    try client.setHeader("x-token", "client-token");
    try client.setHeader("x-retries", "3");
    try client.cookie("theme", "dark");
    try testing.expectEqualStrings("dark", client.cookieValue("theme").?);
    try testing.expect(client.cookieValue("session") == null);

    var headers = try client.get("/headers");
    defer headers.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, headers.status);
    try testing.expectEqualStrings("{\"token\":\"client-token\",\"debug\":false,\"retries\":3}", headers.body.items);

    var override_headers = client.request(.GET, "/headers");
    defer override_headers.deinit();
    try override_headers.header("x-token", "request-token");
    try override_headers.header("x-retries", "9");
    var overridden_headers = try client.send(&override_headers);
    defer overridden_headers.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, overridden_headers.status);
    try testing.expectEqualStrings("{\"token\":\"request-token\",\"debug\":false,\"retries\":9}", overridden_headers.body.items);

    var restored_headers = try client.get("/headers");
    defer restored_headers.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, restored_headers.status);
    try testing.expectEqualStrings("{\"token\":\"client-token\",\"debug\":false,\"retries\":3}", restored_headers.body.items);

    client.removeHeader("x-retries");
    var removed_header = try client.get("/headers");
    defer removed_header.deinit(testing.allocator);
    try testing.expectEqual(Status.unprocessable_entity, removed_header.status);
    try client.setHeader("x-retries", "3");
    var restored_after_remove = try client.get("/headers");
    defer restored_after_remove.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, restored_after_remove.status);
    try testing.expectEqualStrings("{\"token\":\"client-token\",\"debug\":false,\"retries\":3}", restored_after_remove.body.items);

    client.clearHeaders();
    var cleared_headers = try client.get("/headers");
    defer cleared_headers.deinit(testing.allocator);
    try testing.expectEqual(Status.unprocessable_entity, cleared_headers.status);
    try client.setHeader("x-token", "client-token");
    try client.setHeader("x-retries", "3");

    var initial_cookies = try client.get("/redirect-cookies");
    defer initial_cookies.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, initial_cookies.status);
    try testing.expectEqualStrings("https://testclient/redirect-cookies", initial_cookies.requestUrl().?);
    try testing.expectEqualStrings("{\"session\":null,\"theme\":\"dark\"}", initial_cookies.body.items);

    var set = try client.get("/set-cookie");
    defer set.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, set.status);
    try testing.expectEqualStrings("abc123", client.cookieValue("session").?);

    var after_set = try client.get("/redirect-cookies");
    defer after_set.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, after_set.status);
    try testing.expectEqualStrings("{\"session\":\"abc123\",\"theme\":\"dark\"}", after_set.body.items);

    var redirect_set = try client.get("/redirect-set-cookie");
    defer redirect_set.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, redirect_set.status);
    try testing.expectEqualStrings("https://testclient/redirect-cookies", redirect_set.requestUrl().?);
    try testing.expectEqualStrings("{\"session\":\"redirected\",\"theme\":\"dark\"}", redirect_set.body.items);
    try testing.expectEqualStrings("redirected", client.cookieValue("session").?);
    try testing.expectEqual(@as(usize, 1), redirect_set.history.items.len);
    try testing.expectEqual(Status.found, redirect_set.history.items[0].status);
    try testing.expectEqualStrings("https://testclient/redirect-set-cookie", redirect_set.history.items[0].requestUrl().?);
    try testing.expectEqualStrings("/redirect-cookies", redirect_set.history.items[0].header("location").?);

    var cookie_snapshot = try client.cookies(testing.allocator);
    defer cookie_snapshot.deinit();
    try testing.expectEqual(@as(usize, 2), cookie_snapshot.len());
    try testing.expectEqualStrings("dark", cookie_snapshot.get("theme").?);
    try testing.expectEqualStrings("redirected", cookie_snapshot.get("session").?);

    var one_off = client.request(.GET, "/redirect-cookies");
    defer one_off.deinit();
    try one_off.cookie("session", "one-off");
    var one_off_response = try client.send(&one_off);
    defer one_off_response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, one_off_response.status);
    try testing.expectEqualStrings("{\"session\":\"one-off\",\"theme\":\"dark\"}", one_off_response.body.items);

    var after_one_off = try client.get("/redirect-cookies");
    defer after_one_off.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, after_one_off.status);
    try testing.expectEqualStrings("{\"session\":\"redirected\",\"theme\":\"dark\"}", after_one_off.body.items);

    var redirect_delete = try client.get("/redirect-delete-cookie");
    defer redirect_delete.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, redirect_delete.status);
    try testing.expectEqualStrings("{\"session\":null,\"theme\":\"dark\"}", redirect_delete.body.items);
    try testing.expect(client.cookieValue("session") == null);

    var after_delete = try client.get("/redirect-cookies");
    defer after_delete.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, after_delete.status);
    try testing.expectEqualStrings("{\"session\":null,\"theme\":\"dark\"}", after_delete.body.items);

    var set_again = try client.get("/set-cookie");
    defer set_again.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, set_again.status);
    try testing.expectEqualStrings("abc123", client.cookieValue("session").?);

    var expires_delete = try client.get("/expires-delete-cookie");
    defer expires_delete.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, expires_delete.status);
    try testing.expect(client.cookieValue("session") == null);

    var set_before_non_empty_max_age_delete = try client.get("/set-cookie");
    defer set_before_non_empty_max_age_delete.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, set_before_non_empty_max_age_delete.status);
    try testing.expectEqualStrings("abc123", client.cookieValue("session").?);

    var non_empty_max_age_delete = try client.get("/non-empty-max-age-delete-cookie");
    defer non_empty_max_age_delete.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, non_empty_max_age_delete.status);
    try testing.expect(client.cookieValue("session") == null);

    var set_before_non_empty_expires_delete = try client.get("/set-cookie");
    defer set_before_non_empty_expires_delete.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, set_before_non_empty_expires_delete.status);
    try testing.expectEqualStrings("abc123", client.cookieValue("session").?);

    var non_empty_expires_delete = try client.get("/non-empty-expires-delete-cookie");
    defer non_empty_expires_delete.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, non_empty_expires_delete.status);
    try testing.expect(client.cookieValue("session") == null);

    var max_age_wins = try client.get("/max-age-precedence-cookie");
    defer max_age_wins.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, max_age_wins.status);
    try testing.expectEqualStrings("kept", client.cookieValue("session").?);

    try client.cookie("session", "manual");
    try client.deleteCookie("theme");
    try testing.expectEqualStrings("manual", client.cookieValue("session").?);
    try testing.expect(client.cookieValue("theme") == null);
    try testing.expectEqualStrings("redirected", cookie_snapshot.get("session").?);
    try testing.expectEqualStrings("dark", cookie_snapshot.get("theme").?);
    var after_client_delete = try client.get("/redirect-cookies");
    defer after_client_delete.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, after_client_delete.status);
    try testing.expectEqualStrings("{\"session\":\"manual\",\"theme\":null}", after_client_delete.body.items);

    try testing.expectError(error.InvalidCookie, client.deleteCookie("bad name"));

    client.clearCookies();
    try testing.expect(client.cookieValue("session") == null);
    try testing.expect(client.cookieValue("theme") == null);
    var after_clear_cookies = try client.get("/redirect-cookies");
    defer after_clear_cookies.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, after_clear_cookies.status);
    try testing.expectEqualStrings("{\"session\":null,\"theme\":null}", after_clear_cookies.body.items);
}

test "test client keeps default query params across requests" {
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    try app.route(Route.get("/raw/{item:path}", echoRawRequest, .{}));
    try app.route(Route.get("/query-auth", secureQueryKey, .{}));
    try app.route(Route.get("/search", searchUsers, .{}));

    var client = TestClient.init(testing.allocator, &app, .{});
    defer client.deinit();
    try client.queryParam("q", "client q");
    try client.setQueryParam("q", "client default");
    try client.queryParam("tag", "client");
    try client.apiKeyQuery("api_key", "client-key");
    try testing.expect(client.hasQueryParam("q"));
    try testing.expectEqualStrings("client default", client.queryParamValue("q").?);
    const client_tags = try client.queryParamValues(testing.allocator, "tag");
    defer testing.allocator.free(client_tags);
    try testing.expectEqual(@as(usize, 1), client_tags.len);
    try testing.expectEqualStrings("client", client_tags[0]);

    var defaults = try client.get("/raw/zig?empty=");
    defer defaults.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, defaults.status);
    try testing.expectEqualStrings(
        "{\"item\":\"zig\",\"token\":\"\",\"tokens\":[],\"missing_header_count\":0,\"q\":\"client default\",\"tag\":\"client\",\"tags\":[\"client\"],\"empty\":\"\",\"missing_query\":true,\"theme\":\"\",\"session\":\"\",\"missing_cookie\":true}",
        defaults.body.items,
    );

    var override_request = client.request(.GET, "/raw/zig?tag=request&empty=");
    defer override_request.deinit();
    try override_request.queryParam("q", "request q");
    try testing.expect(try override_request.hasQueryParam(testing.allocator, "q"));
    const override_q = (try override_request.queryParamValue(testing.allocator, "q")).?;
    defer testing.allocator.free(override_q);
    try testing.expectEqualStrings("request q", override_q);
    var override_query = try override_request.queryParams(testing.allocator);
    defer override_query.deinit();
    try testing.expectEqualStrings("request", override_query.get("tag").?);
    try testing.expectEqualStrings("", override_query.get("empty").?);
    var override = try client.send(&override_request);
    defer override.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, override.status);
    try testing.expectEqualStrings(
        "{\"item\":\"zig\",\"token\":\"\",\"tokens\":[],\"missing_header_count\":0,\"q\":\"request q\",\"tag\":\"request\",\"tags\":[\"client\",\"request\"],\"empty\":\"\",\"missing_query\":true,\"theme\":\"\",\"session\":\"\",\"missing_cookie\":true}",
        override.body.items,
    );

    var auth = try client.get("/query-auth");
    defer auth.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, auth.status);
    try testing.expectEqualStrings("{\"token\":\"client-key\"}", auth.body.items);

    client.removeQueryParam("q");
    try testing.expect(!client.hasQueryParam("q"));
    var removed = try client.get("/raw/zig");
    defer removed.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, removed.status);
    try testing.expectEqualStrings(
        "{\"item\":\"zig\",\"token\":\"\",\"tokens\":[],\"missing_header_count\":0,\"q\":\"\",\"tag\":\"client\",\"tags\":[\"client\"],\"empty\":\"\",\"missing_query\":true,\"theme\":\"\",\"session\":\"\",\"missing_cookie\":true}",
        removed.body.items,
    );

    client.clearQueryParams();
    try testing.expect(!client.hasQueryParam("tag"));
    var cleared_auth = try client.get("/query-auth");
    defer cleared_auth.deinit(testing.allocator);
    try testing.expectEqual(Status.unauthorized, cleared_auth.status);
    try testing.expectEqualStrings("{\"detail\":\"Unauthorized\"}", cleared_auth.body.items);

    const unicode_cases = &.{
        "2020-07-14T00:00:00+00:00",
        "Espa\xc3\xb1a",
        "voil\xc3\xa0",
    };
    inline for (unicode_cases) |value| {
        var response = try client.getQuery("/search", .{ .q = value });
        defer response.deinit(testing.allocator);
        try testing.expectEqual(Status.ok, response.status);
        var parsed = try response.json(SearchUsersResult, testing.allocator);
        defer parsed.deinit();
        try testing.expectEqualStrings(value, parsed.value.q);
        try testing.expectEqual(@as(u32, 10), parsed.value.limit);
    }
}

test "test client sends default headers and allows overrides" {
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    try app.route(Route.get("/headers", echoHeaders, .{}));
    try app.route(Route.get("/client-headers", echoClientHeaderDefaults, .{}));
    try app.route(Route.get("/header-list", echoHeaderList, .{}));

    var client = TestClient.init(testing.allocator, &app, .{});
    defer client.deinit();

    var default_response = try client.get("/client-headers");
    defer default_response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, default_response.status);
    try testing.expectEqualStrings("{\"user_agent\":\"testclient\",\"accept\":\"*/*\",\"accept_encoding\":\"gzip, deflate, zstd\",\"connection\":\"keep-alive\"}", default_response.text());

    var option_agent_client = TestClient.init(testing.allocator, &app, .{
        .headers = &.{.{ .name = "user-agent", .value = "non-default-agent" }},
    });
    defer option_agent_client.deinit();
    var option_agent_response = try option_agent_client.get("/client-headers");
    defer option_agent_response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, option_agent_response.status);
    try testing.expectEqualStrings("{\"user_agent\":\"non-default-agent\",\"accept\":\"*/*\",\"accept_encoding\":\"gzip, deflate, zstd\",\"connection\":\"keep-alive\"}", option_agent_response.text());

    var option_header_client = TestClient.init(testing.allocator, &app, .{
        .headers = &.{
            .{ .name = "x-token", .value = "option-token" },
            .{ .name = "x-retries", .value = "4" },
        },
    });
    defer option_header_client.deinit();
    var option_header_response = try option_header_client.get("/headers");
    defer option_header_response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, option_header_response.status);
    try testing.expectEqualStrings("{\"token\":\"option-token\",\"debug\":false,\"retries\":4}", option_header_response.text());

    try option_header_client.setHeader("x-token", "client-token");
    try testing.expect(option_header_client.hasHeader("X-Token"));
    try testing.expectEqualStrings("client-token", option_header_client.headerValue("X-Token").?);
    const option_token_headers = try option_header_client.headerValues(testing.allocator, "x-token");
    defer testing.allocator.free(option_token_headers);
    try testing.expectEqual(@as(usize, 1), option_token_headers.len);
    try testing.expectEqualStrings("client-token", option_token_headers[0]);
    var option_header_override = try option_header_client.get("/headers");
    defer option_header_override.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, option_header_override.status);
    try testing.expectEqualStrings("{\"token\":\"client-token\",\"debug\":false,\"retries\":4}", option_header_override.text());

    try client.userAgent("non-default-agent");
    try client.accept("application/json");
    try client.setHeader("accept-encoding", "identity");
    try client.setHeader("connection", "close");
    try testing.expect(client.hasHeader("Accept"));
    try testing.expectEqualStrings("application/json", client.headerValue("ACCEPT").?);
    var client_override = try client.get("/client-headers");
    defer client_override.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, client_override.status);
    try testing.expectEqualStrings("{\"user_agent\":\"non-default-agent\",\"accept\":\"application/json\",\"accept_encoding\":\"identity\",\"connection\":\"close\"}", client_override.text());

    var request_override = client.request(.GET, "/client-headers");
    defer request_override.deinit();
    try request_override.userAgent("request-agent");
    try request_override.accept("text/plain");
    try request_override.header("accept-encoding", "br");
    try request_override.header("connection", "upgrade");
    try testing.expect(request_override.hasHeader("User-Agent"));
    try testing.expectEqualStrings("request-agent", request_override.headerValue("user-agent").?);
    var request_override_response = try client.send(&request_override);
    defer request_override_response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, request_override_response.status);
    try testing.expectEqualStrings("{\"user_agent\":\"request-agent\",\"accept\":\"text/plain\",\"accept_encoding\":\"br\",\"connection\":\"upgrade\"}", request_override_response.text());

    var duplicate_headers = client.request(.GET, "/header-list");
    defer duplicate_headers.deinit();
    try duplicate_headers.header("x-token", "foo");
    try duplicate_headers.header("x-token", "bar");
    const duplicate_token_headers = try duplicate_headers.headerValues(testing.allocator, "X-Token");
    defer testing.allocator.free(duplicate_token_headers);
    try testing.expectEqual(@as(usize, 2), duplicate_token_headers.len);
    try testing.expectEqualStrings("foo", duplicate_token_headers[0]);
    try testing.expectEqualStrings("bar", duplicate_token_headers[1]);
    var duplicate_header_response = try client.send(&duplicate_headers);
    defer duplicate_header_response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, duplicate_header_response.status);
    try testing.expectEqualStrings("{\"tokens\":[\"foo\",\"bar\"]}", duplicate_header_response.text());

    duplicate_headers.removeHeader("x-token");
    try testing.expect(!duplicate_headers.hasHeader("x-token"));
    client.removeHeader("accept");
    try testing.expect(!client.hasHeader("accept"));
    client.clearHeaders();
    try testing.expect(!client.hasHeader("connection"));
}

test "test client respects response cookie domain and path scope" {
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    try app.route(Route.get("/set-example-domain-cookie", setExampleDomainCookie, .{}));
    try app.route(Route.get("/set-other-domain-cookie", setOtherDomainCookie, .{}));
    try app.route(Route.get("/set-testserver-domain-cookie", setTestserverDomainCookie, .{}));
    try app.route(Route.get("/set-testserver-local-domain-cookie", setTestserverLocalDomainCookie, .{}));
    try app.route(Route.get("/set-localhost-domain-cookie", setLocalhostDomainCookie, .{}));
    try app.route(Route.get("/set-admin-path-cookie", setAdminPathCookie, .{}));
    try app.route(Route.get("/set-root-path-cookie", setRootPathCookie, .{}));
    try app.route(Route.get("/set-secure-scoped-cookie", setSecureScopedCookie, .{}));
    try app.route(Route.get("/echo-scoped-cookie", echoScopedCookie, .{}));
    try app.route(Route.get("/admin/echo-scoped-cookie", echoScopedCookie, .{}));

    var client = TestClient.init(testing.allocator, &app, .{
        .base_url = "https://api.example.test",
    });
    defer client.deinit();

    var other_domain = try client.get("/set-other-domain-cookie");
    defer other_domain.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, other_domain.status);
    try testing.expect(client.cookieValue("scoped") == null);

    var hidden = try client.get("/echo-scoped-cookie");
    defer hidden.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, hidden.status);
    try testing.expectEqualStrings("{\"scoped\":null}", hidden.text());

    var example_domain = try client.get("/set-example-domain-cookie");
    defer example_domain.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, example_domain.status);

    var visible = try client.get("/echo-scoped-cookie");
    defer visible.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, visible.status);
    try testing.expectEqualStrings("{\"scoped\":\"example\"}", visible.text());

    var visible_subdomain = try client.get("https://www.example.test/echo-scoped-cookie");
    defer visible_subdomain.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, visible_subdomain.status);
    try testing.expectEqualStrings("{\"scoped\":\"example\"}", visible_subdomain.text());

    var hidden_other_host = try client.get("https://elsewhere.test/echo-scoped-cookie");
    defer hidden_other_host.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, hidden_other_host.status);
    try testing.expectEqualStrings("{\"scoped\":null}", hidden_other_host.text());

    var local_domain_client = TestClient.init(testing.allocator, &app, .{});
    defer local_domain_client.deinit();

    var testserver_domain = try local_domain_client.get("/set-testserver-domain-cookie");
    defer testserver_domain.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, testserver_domain.status);
    var visible_testserver = try local_domain_client.get("/echo-scoped-cookie");
    defer visible_testserver.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, visible_testserver.status);
    try testing.expectEqualStrings("{\"scoped\":\"testserver\"}", visible_testserver.text());

    local_domain_client.clearCookies();
    var testserver_local_domain = try local_domain_client.get("/set-testserver-local-domain-cookie");
    defer testserver_local_domain.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, testserver_local_domain.status);
    var visible_testserver_local = try local_domain_client.get("/echo-scoped-cookie");
    defer visible_testserver_local.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, visible_testserver_local.status);
    try testing.expectEqualStrings("{\"scoped\":\"testserver-local\"}", visible_testserver_local.text());

    local_domain_client.clearCookies();
    var localhost_domain = try local_domain_client.get("/set-localhost-domain-cookie");
    defer localhost_domain.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, localhost_domain.status);
    try testing.expect(local_domain_client.cookieValue("scoped") == null);
    var hidden_localhost = try local_domain_client.get("/echo-scoped-cookie");
    defer hidden_localhost.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, hidden_localhost.status);
    try testing.expectEqualStrings("{\"scoped\":null}", hidden_localhost.text());

    var path_client = TestClient.init(testing.allocator, &app, .{
        .base_url = "https://api.example.test",
    });
    defer path_client.deinit();

    var set_path = try path_client.get("/set-admin-path-cookie");
    defer set_path.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, set_path.status);

    var outside_path = try path_client.get("/echo-scoped-cookie");
    defer outside_path.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, outside_path.status);
    try testing.expectEqualStrings("{\"scoped\":null}", outside_path.text());

    var set_root = try path_client.get("/set-root-path-cookie");
    defer set_root.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, set_root.status);

    var outside_path_after_root = try path_client.get("/echo-scoped-cookie");
    defer outside_path_after_root.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, outside_path_after_root.status);
    try testing.expectEqualStrings("{\"scoped\":\"root\"}", outside_path_after_root.text());

    var inside_path = try path_client.get("/admin/echo-scoped-cookie");
    defer inside_path.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, inside_path.status);
    try testing.expectEqualStrings("{\"scoped\":\"admin\"}", inside_path.text());

    var secure_client = TestClient.init(testing.allocator, &app, .{
        .base_url = "https://api.example.test",
    });
    defer secure_client.deinit();

    var set_secure = try secure_client.get("/set-secure-scoped-cookie");
    defer set_secure.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, set_secure.status);
    try testing.expectEqualStrings("secure", secure_client.cookieValue("scoped").?);

    var sent_over_https = try secure_client.get("/echo-scoped-cookie");
    defer sent_over_https.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, sent_over_https.status);
    try testing.expectEqualStrings("{\"scoped\":\"secure\"}", sent_over_https.text());

    var hidden_over_http = try secure_client.get("http://api.example.test/echo-scoped-cookie");
    defer hidden_over_http.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, hidden_over_http.status);
    try testing.expectEqualStrings("{\"scoped\":null}", hidden_over_http.text());
}

test "test client can raise or capture server exceptions" {
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    try app.addExceptionHandler(error.Teapot, handleTeapot);
    try app.route(Route.get("/handled", failingRoute, .{}));
    try app.route(Route.get("/unhandled", unhandledFailingRoute, .{}));
    try app.route(Route.get("/redirect-unhandled", redirectToUnhandled, .{}));
    try app.route(Route.get("/route-middleware-unhandled", unhandledFailingRoute, .{
        .middlewares = &.{addRouteMiddlewareHeader},
    }));

    try testing.expectError(error.UnhandledBoom, app.handleOrRaise(Request.init(.GET, "/unhandled")));

    var raising_builder = Request.builder(testing.allocator, .GET, "/unhandled");
    defer raising_builder.deinit();
    try testing.expectError(error.UnhandledBoom, raising_builder.sendOrRaise(&app));

    var capturing_builder = Request.builder(testing.allocator, .GET, "/unhandled");
    defer capturing_builder.deinit();
    var builder_response = try capturing_builder.send(&app);
    defer builder_response.deinit(testing.allocator);
    try testing.expectEqual(Status.internal_server_error, builder_response.status);
    try testing.expectEqualStrings("{\"detail\":\"Internal server error\"}", builder_response.body.items);

    var runtime_response = try app.handle(Request.init(.GET, "/unhandled"));
    defer runtime_response.deinit(testing.allocator);
    try testing.expectEqual(Status.internal_server_error, runtime_response.status);
    try testing.expectEqualStrings("{\"detail\":\"Internal server error\"}", runtime_response.body.items);

    var raising_client = TestClient.init(testing.allocator, &app, .{});
    defer raising_client.deinit();
    try testing.expectError(error.UnhandledBoom, raising_client.get("/unhandled"));

    var handled = try raising_client.get("/handled");
    defer handled.deinit(testing.allocator);
    try testing.expectEqual(Status.conflict, handled.status);
    try testing.expectEqualStrings("handled /handled", handled.body.items);

    var capturing_client = TestClient.init(testing.allocator, &app, .{ .raise_server_exceptions = false });
    defer capturing_client.deinit();
    var captured = try capturing_client.get("/unhandled");
    defer captured.deinit(testing.allocator);
    try testing.expectEqual(Status.internal_server_error, captured.status);
    try testing.expectEqualStrings("{\"detail\":\"Internal server error\"}", captured.body.items);

    var raising_override = raising_client.request(.GET, "/unhandled");
    defer raising_override.deinit();
    var captured_override = try raising_client.sendWithOptions(&raising_override, .{ .raise_server_exceptions = false });
    defer captured_override.deinit(testing.allocator);
    try testing.expectEqual(Status.internal_server_error, captured_override.status);
    try testing.expectEqualStrings("{\"detail\":\"Internal server error\"}", captured_override.body.items);

    var capturing_override = capturing_client.request(.GET, "/unhandled");
    defer capturing_override.deinit();
    try testing.expectError(error.UnhandledBoom, capturing_client.sendWithOptions(&capturing_override, .{ .raise_server_exceptions = true }));

    var redirect_capture_override = raising_client.request(.GET, "/redirect-unhandled");
    defer redirect_capture_override.deinit();
    var redirect_captured_override = try raising_client.sendWithOptions(&redirect_capture_override, .{ .raise_server_exceptions = false });
    defer redirect_captured_override.deinit(testing.allocator);
    try testing.expectEqual(Status.internal_server_error, redirect_captured_override.status);
    try testing.expectEqual(@as(usize, 1), redirect_captured_override.history.items.len);
    try testing.expectEqual(Status.found, redirect_captured_override.history.items[0].status);

    var redirect_raising_override = capturing_client.request(.GET, "/redirect-unhandled");
    defer redirect_raising_override.deinit();
    try testing.expectError(error.UnhandledBoom, capturing_client.sendWithOptions(&redirect_raising_override, .{ .raise_server_exceptions = true }));

    try testing.expectError(error.UnhandledBoom, raising_client.get("/route-middleware-unhandled"));
    var captured_route_middleware = try capturing_client.get("/route-middleware-unhandled");
    defer captured_route_middleware.deinit(testing.allocator);
    try testing.expectEqual(Status.internal_server_error, captured_route_middleware.status);

    var parent = ZAPI.init(testing.allocator, .{});
    defer parent.deinit();
    var child = ZAPI.init(testing.allocator, .{});
    defer child.deinit();
    try child.route(Route.get("/unhandled", unhandledFailingRoute, .{}));
    try parent.mount("/child", &child);

    var mounted_client = TestClient.init(testing.allocator, &parent, .{});
    defer mounted_client.deinit();
    try testing.expectError(error.UnhandledBoom, mounted_client.get("/child/unhandled"));

    var mounted_capturing_client = TestClient.init(testing.allocator, &parent, .{ .raise_server_exceptions = false });
    defer mounted_capturing_client.deinit();
    var mounted_captured = try mounted_capturing_client.get("/child/unhandled");
    defer mounted_captured.deinit(testing.allocator);
    try testing.expectEqual(Status.internal_server_error, mounted_captured.status);
}

test "test client can leave redirects unfollowed while keeping response cookies" {
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    try app.route(Route.get("/redirect-set-cookie", redirectWithCookie, .{}));
    try app.route(Route.get("/redirect-cookies", echoRedirectCookies, .{}));

    var client = TestClient.init(testing.allocator, &app, .{
        .base_url = "https://api.example.test/root",
        .follow_redirects = false,
    });
    defer client.deinit();

    var redirect = try client.get("/redirect-set-cookie");
    defer redirect.deinit(testing.allocator);
    try testing.expectEqual(Status.found, redirect.status);
    try testing.expectEqualStrings("https://api.example.test/root/redirect-set-cookie", redirect.requestUrl().?);
    try testing.expectEqualStrings("/redirect-cookies", redirect.header("location").?);
    try testing.expectEqual(@as(usize, 0), redirect.history.items.len);

    var cookies = try client.get("/redirect-cookies");
    defer cookies.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, cookies.status);
    try testing.expectEqualStrings("https://api.example.test/root/redirect-cookies", cookies.requestUrl().?);
    try testing.expectEqualStrings("{\"session\":\"redirected\",\"theme\":null}", cookies.body.items);
}

test "test client can override redirect following per request" {
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    try app.route(Route.get("/redirect-set-cookie", redirectWithCookie, .{}));
    try app.route(Route.get("/redirect-cookies", echoRedirectCookies, .{}));
    try app.route(Route.get("/loop", redirectLoop, .{}));

    var following_client = TestClient.init(testing.allocator, &app, .{});
    defer following_client.deinit();

    var no_follow_request = following_client.request(.GET, "/redirect-set-cookie");
    defer no_follow_request.deinit();
    var no_follow = try following_client.sendNoRedirects(&no_follow_request);
    defer no_follow.deinit(testing.allocator);
    try testing.expectEqual(Status.found, no_follow.status);
    try testing.expectEqualStrings("/redirect-cookies", no_follow.header("location").?);
    try testing.expectEqual(@as(usize, 0), no_follow.history.items.len);
    try testing.expectEqualStrings("redirected", following_client.cookieValue("session").?);

    var cookies_after_no_follow = try following_client.get("/redirect-cookies");
    defer cookies_after_no_follow.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, cookies_after_no_follow.status);
    try testing.expectEqualStrings("{\"session\":\"redirected\",\"theme\":null}", cookies_after_no_follow.body.items);

    var options_no_follow_request = following_client.request(.GET, "/redirect-set-cookie");
    defer options_no_follow_request.deinit();
    var options_no_follow = try following_client.sendWithOptions(&options_no_follow_request, .{ .follow_redirects = false });
    defer options_no_follow.deinit(testing.allocator);
    try testing.expectEqual(Status.found, options_no_follow.status);
    try testing.expectEqual(@as(usize, 0), options_no_follow.history.items.len);

    var direct_no_follow = try following_client.getNoRedirects("/redirect-set-cookie");
    defer direct_no_follow.deinit(testing.allocator);
    try testing.expectEqual(Status.found, direct_no_follow.status);
    try testing.expectEqualStrings("/redirect-cookies", direct_no_follow.location().?);
    try testing.expectEqual(@as(usize, 0), direct_no_follow.history.items.len);

    var limited_redirects = following_client.request(.GET, "/loop");
    defer limited_redirects.deinit();
    try testing.expectError(error.TooManyRedirects, following_client.sendWithOptions(&limited_redirects, .{ .max_redirects = 2 }));
    try testing.expectError(error.TooManyRedirects, following_client.getFollowRedirects("/loop", .{ .max_redirects = 2 }));

    var non_following_client = TestClient.init(testing.allocator, &app, .{ .follow_redirects = false });
    defer non_following_client.deinit();

    var follow_request = non_following_client.request(.GET, "/redirect-set-cookie");
    defer follow_request.deinit();
    var followed = try non_following_client.sendFollowRedirects(&follow_request, .{});
    defer followed.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, followed.status);
    try testing.expectEqualStrings("{\"session\":\"redirected\",\"theme\":null}", followed.body.items);
    try testing.expectEqual(@as(usize, 1), followed.history.items.len);
    try testing.expectEqual(Status.found, followed.history.items[0].status);
    try testing.expectEqualStrings("redirected", non_following_client.cookieValue("session").?);

    var options_follow_request = non_following_client.request(.GET, "/redirect-set-cookie");
    defer options_follow_request.deinit();
    var options_followed = try non_following_client.sendWithOptions(&options_follow_request, .{ .follow_redirects = true });
    defer options_followed.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, options_followed.status);
    try testing.expectEqual(@as(usize, 1), options_followed.history.items.len);

    var direct_followed = try non_following_client.getFollowRedirects("/redirect-set-cookie", .{});
    defer direct_followed.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, direct_followed.status);
    try testing.expectEqualStrings("{\"session\":\"redirected\",\"theme\":null}", direct_followed.body.items);
    try testing.expectEqual(@as(usize, 1), direct_followed.history.items.len);
}

test "test client uses starlette style default request scope" {
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    try app.route(Route.get("/", echoRequestScope, .{}));

    var client = TestClient.init(testing.allocator, &app, .{});
    defer client.deinit();

    var scope = try client.get("/");
    defer scope.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, scope.status);
    try testing.expectEqualStrings("{\"scheme\":\"http\",\"host\":\"testserver\",\"root_path\":\"\"}", scope.body.items);

    var hostless_client = TestClient.init(testing.allocator, &app, .{ .host = null });
    defer hostless_client.deinit();

    var hostless_scope = try hostless_client.get("/");
    defer hostless_scope.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, hostless_scope.status);
    try testing.expectEqualStrings("{\"scheme\":\"http\",\"host\":\"\",\"root_path\":\"\"}", hostless_scope.body.items);
}

test "test client applies request scope defaults" {
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    try app.route(Route.get("/", echoRequestScope, .{}));
    try app.route(Route.get("/users", plainText, .{}));
    try app.route(Route.get("/absolute", absoluteRedirectToUsers, .{}));

    var client = TestClient.init(testing.allocator, &app, .{
        .scheme = "https",
        .host = "example.test",
        .root_path = "/api",
    });
    defer client.deinit();

    var scope = try client.get("/");
    defer scope.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, scope.status);
    try testing.expectEqualStrings("{\"scheme\":\"https\",\"host\":\"example.test\",\"root_path\":\"/api\"}", scope.body.items);

    var absolute = try client.get("/absolute");
    defer absolute.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, absolute.status);
    try testing.expectEqualStrings("Hello, world", absolute.body.items);

    var override_host = client.request(.GET, "/");
    defer override_host.deinit();
    try override_host.header("host", "override.test");
    var overridden = try client.send(&override_host);
    defer overridden.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, overridden.status);
    try testing.expectEqualStrings("{\"scheme\":\"https\",\"host\":\"override.test\",\"root_path\":\"/api\"}", overridden.body.items);
}

test "test client strips root path from relative targets like Starlette" {
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    try app.route(Route.get("/", echoNamedRootUrl, .{ .name = "homepage" }));
    try app.route(Route.get("/to-home", redirectToNamedRoot, .{}));

    var client = TestClient.init(testing.allocator, &app, .{
        .base_url = "https://www.example.org/",
        .root_path = "/sub_path/",
    });
    defer client.deinit();

    var response = try client.get("/sub_path/");
    defer response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, response.status);
    try testing.expectEqualStrings("{\"index\":\"https://www.example.org/sub_path/\"}", response.body.items);
    try testing.expectEqualStrings("https://www.example.org/sub_path/", response.requestUrl().?);

    var app_relative = try client.get("/");
    defer app_relative.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, app_relative.status);
    try testing.expectEqualStrings("{\"index\":\"https://www.example.org/sub_path/\"}", app_relative.body.items);
    try testing.expectEqualStrings("https://www.example.org/sub_path/", app_relative.requestUrl().?);

    var redirect_request = client.request(.GET, "/sub_path/to-home");
    defer redirect_request.deinit();
    var redirect = try client.sendNoRedirects(&redirect_request);
    defer redirect.deinit(testing.allocator);
    try testing.expectEqual(Status.temporary_redirect, redirect.status);
    try testing.expectEqualStrings("/sub_path/", redirect.header("location").?);
    try testing.expectEqualStrings("https://www.example.org/sub_path/to-home", redirect.requestUrl().?);

    var followed = try client.get("/sub_path/to-home");
    defer followed.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, followed.status);
    try testing.expectEqual(@as(usize, 1), followed.history.items.len);
    try testing.expectEqual(Status.temporary_redirect, followed.history.items[0].status);
    try testing.expectEqualStrings("/sub_path/", followed.history.items[0].header("location").?);
    try testing.expectEqualStrings("https://www.example.org/sub_path/to-home", followed.history.items[0].requestUrl().?);
    try testing.expectEqualStrings("{\"index\":\"https://www.example.org/sub_path/\"}", followed.body.items);
    try testing.expectEqualStrings("https://www.example.org/sub_path/", followed.requestUrl().?);
}

test "url generation uses outer router from mounted apps with root path like Starlette" {
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    var child = ZAPI.init(testing.allocator, .{});
    defer child.deinit();

    try app.route(Route.get("/", echoMountedRootUrls, .{ .name = "index" }));
    try child.route(Route.get("/", echoMountedRootUrls, .{ .name = "submount" }));
    try app.mountNamed("/submount", "mount", &child);

    var client = TestClient.init(testing.allocator, &app, .{
        .base_url = "https://www.example.org/",
        .root_path = "/sub_path",
    });
    defer client.deinit();

    const expected = "{\"index\":\"https://www.example.org/sub_path/\",\"submount\":\"https://www.example.org/sub_path/submount/\"}";

    var root = try client.get("/sub_path/");
    defer root.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, root.status);
    try testing.expectEqualStrings(expected, root.body.items);
    try testing.expectEqualStrings("https://www.example.org/sub_path/", root.requestUrl().?);

    var mounted = try client.get("/sub_path/submount/");
    defer mounted.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, mounted.status);
    try testing.expectEqualStrings(expected, mounted.body.items);
    try testing.expectEqualStrings("https://www.example.org/sub_path/submount/", mounted.requestUrl().?);
}

test "test client can derive request scope defaults from base url" {
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    try app.route(Route.get("/", echoRequestScope, .{}));
    try app.route(Route.get("/users", plainText, .{}));
    try app.route(Route.get("/absolute", absoluteRedirectToUsers, .{}));

    var client = TestClient.init(testing.allocator, &app, .{
        .base_url = "https://example.test/api/",
        .scheme = "http",
        .host = "ignored.test",
        .root_path = "/ignored",
    });
    defer client.deinit();

    var scope = try client.get("/");
    defer scope.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, scope.status);
    try testing.expectEqualStrings("{\"scheme\":\"https\",\"host\":\"example.test\",\"root_path\":\"/api\"}", scope.body.items);

    var absolute = try client.get("/absolute");
    defer absolute.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, absolute.status);
    try testing.expectEqualStrings("Hello, world", absolute.body.items);

    var override_host = client.request(.GET, "/");
    defer override_host.deinit();
    try override_host.header("host", "override.test");
    var overridden = try client.send(&override_host);
    defer overridden.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, overridden.status);
    try testing.expectEqualStrings("{\"scheme\":\"https\",\"host\":\"override.test\",\"root_path\":\"/api\"}", overridden.body.items);
}

test "test client merges base url path into request url helpers like Starlette" {
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    try app.route(Route.get("/bar", echoRequestUrlPath, .{}));

    var client = TestClient.init(testing.allocator, &app, .{
        .base_url = "http://testserver/api/v1/",
    });
    defer client.deinit();

    var response = try client.get("/bar");
    defer response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, response.status);
    try testing.expectEqualStrings("/api/v1/bar", response.text());
    try testing.expectEqualStrings("http://testserver/api/v1/bar", response.requestUrl().?);
}

test "test client accepts absolute request urls" {
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    try app.route(Route.get("/target", echoRequestTarget, .{}));
    try app.route(Route.get("/apiary/target", echoRequestTarget, .{}));

    var client = TestClient.init(testing.allocator, &app, .{
        .base_url = "http://base.test/root",
    });
    defer client.deinit();

    var response = try client.get("https://api.example.test/target?search=zig#section");
    defer response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, response.status);
    try testing.expectEqualStrings("{\"scheme\":\"https\",\"host\":\"api.example.test\",\"root_path\":\"/root\",\"path\":\"/target\",\"query\":\"search=zig\"}", response.body.items);

    var rooted_response = try client.get("https://api.example.test/root/target?search=zig");
    defer rooted_response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, rooted_response.status);
    try testing.expectEqualStrings("{\"scheme\":\"https\",\"host\":\"api.example.test\",\"root_path\":\"/root\",\"path\":\"/target\",\"query\":\"search=zig\"}", rooted_response.body.items);

    var boundary_response = try client.get("https://api.example.test/rooted/target");
    defer boundary_response.deinit(testing.allocator);
    try testing.expectEqual(Status.not_found, boundary_response.status);

    var similar_prefix_response = try client.get("https://api.example.test/apiary/target");
    defer similar_prefix_response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, similar_prefix_response.status);
    try testing.expectEqualStrings("{\"scheme\":\"https\",\"host\":\"api.example.test\",\"root_path\":\"/root\",\"path\":\"/apiary/target\",\"query\":\"\"}", similar_prefix_response.body.items);
}

test "test client rejects invalid absolute request urls" {
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    try app.route(Route.get("/", echoRequestScope, .{}));

    var client = TestClient.init(testing.allocator, &app, .{});
    defer client.deinit();

    try testing.expectError(error.InvalidUrl, client.get("https:///"));
}

test "test client provides request client address" {
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    try app.route(Route.get("/client", echoRequestClient, .{}));
    try app.route(Route.get("/redirect-client", redirectToClientEcho, .{}));

    var default_client = TestClient.init(testing.allocator, &app, .{});
    defer default_client.deinit();

    var default_response = try default_client.get("/client");
    defer default_response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, default_response.status);
    try testing.expectEqualStrings("{\"host\":\"testclient\",\"port\":50000}", default_response.body.items);

    var configured_client = TestClient.init(testing.allocator, &app, .{
        .client = .{ .host = "203.0.113.10", .port = 4242 },
    });
    defer configured_client.deinit();

    var configured_response = try configured_client.get("/client");
    defer configured_response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, configured_response.status);
    try testing.expectEqualStrings("{\"host\":\"203.0.113.10\",\"port\":4242}", configured_response.body.items);

    var redirect_response = try configured_client.get("/redirect-client");
    defer redirect_response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, redirect_response.status);
    try testing.expectEqualStrings("{\"host\":\"203.0.113.10\",\"port\":4242}", redirect_response.body.items);
}

test "test client rejects invalid base url" {
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    try app.route(Route.get("/", echoRequestScope, .{}));

    var client = TestClient.init(testing.allocator, &app, .{ .base_url = "example.test" });
    defer client.deinit();

    try testing.expectError(error.InvalidUrl, client.get("/"));
}

test "test client has ergonomic method body helpers" {
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    try app.route(Route.post("/users", createUser, .{ .status = .created }));
    try app.route(Route.post("/raw-body", echoRawBody, .{}));
    try app.includeRouter(Route.methods("/login", &.{ .POST, .PUT, .PATCH, .DELETE, .OPTIONS, .TRACE }, login, .{}));
    try app.includeRouter(Route.methods("/preferences", &.{ .POST, .PUT, .PATCH, .DELETE, .OPTIONS, .TRACE }, preferences, .{}));
    try app.includeRouter(Route.methods("/profile", &.{ .POST, .PUT, .PATCH, .DELETE, .OPTIONS, .TRACE }, uploadProfile, .{}));
    try app.route(Route.post("/gallery", uploadGallery, .{}));
    try app.route(Route.get("/tags", searchTags, .{}));
    try app.includeRouter(Route.methods("/query", &.{ .POST, .PUT, .PATCH, .DELETE, .OPTIONS, .TRACE }, echoRequestTarget, .{}));
    try app.route(Route.head("/query", echoQueryHeader, .{}));
    try app.route(Route.put("/method", echoMethodAndBody, .{}));
    try app.route(Route.patch("/method", echoMethodAndBody, .{}));
    try app.route(Route.delete("/method", echoMethodAndBody, .{}));
    try app.route(Route.options("/method", echoMethodAndBody, .{}));
    try app.route(Route.trace("/method", echoMethodAndBody, .{}));
    try app.route(Route.get("/head", plainText, .{}));

    var client = TestClient.init(testing.allocator, &app, .{});
    defer client.deinit();

    var created = try client.postJson("/users", "{\"email\":\"ada@example.com\"}");
    defer created.deinit(testing.allocator);
    try testing.expectEqual(Status.created, created.status);
    try testing.expectEqualStrings("{\"id\":1,\"email\":\"ada@example.com\"}", created.body.items);

    var created_value = try client.postJsonValue("/users", CreateUser{ .email = "grace@example.com" });
    defer created_value.deinit(testing.allocator);
    try testing.expectEqual(Status.created, created_value.status);
    var created_value_user = try created_value.json(TestUser, testing.allocator);
    defer created_value_user.deinit();
    try testing.expectEqualStrings("grace@example.com", created_value_user.value.email);

    var raw_body = try client.postJson("/raw-body", "{\"message\":\"hello\"}");
    defer raw_body.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, raw_body.status);
    try testing.expectEqualStrings("{\"text\":\"{\\\"message\\\":\\\"hello\\\"}\",\"bytes_len\":19,\"content_len\":19}", raw_body.body.items);

    var queried = try client.getQuery("/tags", .{
        .tag = [_][]const u8{ "zig api", "web+framework" },
        .limit = [_]u32{ 10, 20 },
        .missing = @as(?[]const u8, null),
    });
    defer queried.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, queried.status);
    try testing.expectEqualStrings("{\"tags\":[\"zig api\",\"web+framework\"],\"limits\":[10,20]}", queried.body.items);

    var post_query = try client.postQuery("/query?existing=1", .{
        .tag = [_][]const u8{ "zig api", "web+framework" },
        .limit = 20,
    });
    defer post_query.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, post_query.status);
    try testing.expectEqualStrings("{\"scheme\":\"http\",\"host\":\"testserver\",\"root_path\":\"\",\"path\":\"/query\",\"query\":\"existing=1&tag=zig+api&tag=web%2Bframework&limit=20\"}", post_query.body.items);

    var put_query = try client.putQuery("/query", .{ .page = 2 });
    defer put_query.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, put_query.status);
    try testing.expectEqualStrings("{\"scheme\":\"http\",\"host\":\"testserver\",\"root_path\":\"\",\"path\":\"/query\",\"query\":\"page=2\"}", put_query.body.items);

    var patch_query = try client.patchQuery("/query", .{ .enabled = true });
    defer patch_query.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, patch_query.status);
    try testing.expectEqualStrings("{\"scheme\":\"http\",\"host\":\"testserver\",\"root_path\":\"\",\"path\":\"/query\",\"query\":\"enabled=true\"}", patch_query.body.items);

    var delete_query = try client.deleteQuery("/query", .{ .id = [_]u32{ 1, 2 } });
    defer delete_query.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, delete_query.status);
    try testing.expectEqualStrings("{\"scheme\":\"http\",\"host\":\"testserver\",\"root_path\":\"\",\"path\":\"/query\",\"query\":\"id=1&id=2\"}", delete_query.body.items);

    var options_query = try client.optionsQuery("/query", .{ .probe = "cors" });
    defer options_query.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, options_query.status);
    try testing.expectEqualStrings("{\"scheme\":\"http\",\"host\":\"testserver\",\"root_path\":\"\",\"path\":\"/query\",\"query\":\"probe=cors\"}", options_query.body.items);

    var head_query = try client.headQuery("/query", .{ .check = "yes" });
    defer head_query.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, head_query.status);
    try testing.expectEqual(@as(usize, 0), head_query.body.items.len);
    try testing.expectEqualStrings("check=yes", head_query.header("x-query").?);

    var trace_query = try client.traceQuery("/query", .{ .trace = "abc123" });
    defer trace_query.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, trace_query.status);
    try testing.expectEqualStrings("{\"scheme\":\"http\",\"host\":\"testserver\",\"root_path\":\"\",\"path\":\"/query\",\"query\":\"trace=abc123\"}", trace_query.body.items);

    var form = try client.postForm("/login", "username=ada&password=secret&remember=yes&attempts=2");
    defer form.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, form.status);
    try testing.expectEqualStrings("{\"username\":\"ada\",\"remember\":true,\"attempts\":2}", form.body.items);

    var put_form = try client.putForm("/login", "username=ada&password=secret&remember=no&attempts=5");
    defer put_form.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, put_form.status);
    try testing.expectEqualStrings("{\"username\":\"ada\",\"remember\":false,\"attempts\":5}", put_form.body.items);

    var patch_form = try client.patchForm("/login", "username=grace&password=secret&remember=on&attempts=6");
    defer patch_form.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, patch_form.status);
    try testing.expectEqualStrings("{\"username\":\"grace\",\"remember\":true,\"attempts\":6}", patch_form.body.items);

    var delete_form = try client.deleteForm("/login", "username=alan&password=secret&remember=false&attempts=9");
    defer delete_form.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, delete_form.status);
    try testing.expectEqualStrings("{\"username\":\"alan\",\"remember\":false,\"attempts\":9}", delete_form.body.items);

    var options_form = try client.optionsForm("/login", "username=marie&password=secret&remember=true&attempts=10");
    defer options_form.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, options_form.status);
    try testing.expectEqualStrings("{\"username\":\"marie\",\"remember\":true,\"attempts\":10}", options_form.body.items);

    var trace_form = try client.traceForm("/login", "username=katherine&password=secret&remember=yes&attempts=11");
    defer trace_form.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, trace_form.status);
    try testing.expectEqualStrings("{\"username\":\"katherine\",\"remember\":true,\"attempts\":11}", trace_form.body.items);

    var form_fields = try client.postFormFields("/preferences", &.{
        .{ .name = "username", .value = "ada lovelace" },
        .{ .name = "tag", .value = "zig api" },
        .{ .name = "tag", .value = "web+framework" },
        .{ .name = "level", .value = "1" },
        .{ .name = "level", .value = "2" },
    });
    defer form_fields.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, form_fields.status);
    try testing.expectEqualStrings("{\"username\":\"ada lovelace\",\"tags\":[\"zig api\",\"web+framework\"],\"levels\":[1,2]}", form_fields.body.items);

    var put_form_fields = try client.putFormFields("/preferences", &.{
        .{ .name = "username", .value = "ada lovelace" },
        .{ .name = "tag", .value = "zig api" },
        .{ .name = "tag", .value = "web+framework" },
        .{ .name = "level", .value = "3" },
        .{ .name = "level", .value = "4" },
    });
    defer put_form_fields.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, put_form_fields.status);
    try testing.expectEqualStrings("{\"username\":\"ada lovelace\",\"tags\":[\"zig api\",\"web+framework\"],\"levels\":[3,4]}", put_form_fields.body.items);

    var patch_form_fields = try client.patchFormFields("/preferences", &.{
        .{ .name = "username", .value = "grace hopper" },
        .{ .name = "tag", .value = "compiler" },
        .{ .name = "tag", .value = "navy" },
        .{ .name = "level", .value = "5" },
        .{ .name = "level", .value = "6" },
    });
    defer patch_form_fields.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, patch_form_fields.status);
    try testing.expectEqualStrings("{\"username\":\"grace hopper\",\"tags\":[\"compiler\",\"navy\"],\"levels\":[5,6]}", patch_form_fields.body.items);

    var delete_form_fields = try client.deleteFormFields("/preferences", &.{
        .{ .name = "username", .value = "alan turing" },
        .{ .name = "tag", .value = "math" },
        .{ .name = "tag", .value = "logic" },
        .{ .name = "level", .value = "7" },
        .{ .name = "level", .value = "8" },
    });
    defer delete_form_fields.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, delete_form_fields.status);
    try testing.expectEqualStrings("{\"username\":\"alan turing\",\"tags\":[\"math\",\"logic\"],\"levels\":[7,8]}", delete_form_fields.body.items);

    var options_form_fields = try client.optionsFormFields("/preferences", &.{
        .{ .name = "username", .value = "marie curie" },
        .{ .name = "tag", .value = "physics" },
        .{ .name = "tag", .value = "chemistry" },
        .{ .name = "level", .value = "9" },
        .{ .name = "level", .value = "10" },
    });
    defer options_form_fields.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, options_form_fields.status);
    try testing.expectEqualStrings("{\"username\":\"marie curie\",\"tags\":[\"physics\",\"chemistry\"],\"levels\":[9,10]}", options_form_fields.body.items);

    var trace_form_fields = try client.traceFormFields("/preferences", &.{
        .{ .name = "username", .value = "katherine johnson" },
        .{ .name = "tag", .value = "orbit" },
        .{ .name = "tag", .value = "navigation" },
        .{ .name = "level", .value = "11" },
        .{ .name = "level", .value = "12" },
    });
    defer trace_form_fields.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, trace_form_fields.status);
    try testing.expectEqualStrings("{\"username\":\"katherine johnson\",\"tags\":[\"orbit\",\"navigation\"],\"levels\":[11,12]}", trace_form_fields.body.items);

    var form_value = try client.postFormValue("/login", .{
        .username = "grace hopper",
        .password = "secret value",
        .remember = true,
        .attempts = @as(u8, 4),
        .unused = @as(?[]const u8, null),
    });
    defer form_value.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, form_value.status);
    try testing.expectEqualStrings("{\"username\":\"grace hopper\",\"remember\":true,\"attempts\":4}", form_value.body.items);

    var put_form_value = try client.putFormValue("/login", .{
        .username = "ada lovelace",
        .password = "secret value",
        .remember = false,
        .attempts = @as(u8, 7),
    });
    defer put_form_value.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, put_form_value.status);
    try testing.expectEqualStrings("{\"username\":\"ada lovelace\",\"remember\":false,\"attempts\":7}", put_form_value.body.items);

    var patch_form_value = try client.patchFormValue("/login", .{
        .username = "grace hopper",
        .password = "secret value",
        .remember = true,
        .attempts = @as(u8, 8),
    });
    defer patch_form_value.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, patch_form_value.status);
    try testing.expectEqualStrings("{\"username\":\"grace hopper\",\"remember\":true,\"attempts\":8}", patch_form_value.body.items);

    var delete_form_value = try client.deleteFormValue("/login", .{
        .username = "alan turing",
        .password = "secret value",
        .remember = false,
        .attempts = @as(u8, 9),
    });
    defer delete_form_value.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, delete_form_value.status);
    try testing.expectEqualStrings("{\"username\":\"alan turing\",\"remember\":false,\"attempts\":9}", delete_form_value.body.items);

    var options_form_value = try client.optionsFormValue("/login", .{
        .username = "marie curie",
        .password = "secret value",
        .remember = true,
        .attempts = @as(u8, 10),
    });
    defer options_form_value.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, options_form_value.status);
    try testing.expectEqualStrings("{\"username\":\"marie curie\",\"remember\":true,\"attempts\":10}", options_form_value.body.items);

    var trace_form_value = try client.traceFormValue("/login", .{
        .username = "katherine johnson",
        .password = "secret value",
        .remember = true,
        .attempts = @as(u8, 11),
    });
    defer trace_form_value.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, trace_form_value.status);
    try testing.expectEqualStrings("{\"username\":\"katherine johnson\",\"remember\":true,\"attempts\":11}", trace_form_value.body.items);

    var repeated_form_value = try client.postFormValue("/preferences", .{
        .username = "grace hopper",
        .tag = [_][]const u8{ "zig api", "web+framework" },
        .level = [_]u32{ 1, 2 },
        .skip = @as(?[]const u8, null),
    });
    defer repeated_form_value.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, repeated_form_value.status);
    try testing.expectEqualStrings("{\"username\":\"grace hopper\",\"tags\":[\"zig api\",\"web+framework\"],\"levels\":[1,2]}", repeated_form_value.body.items);

    var multipart = try client.postMultipart(
        "/profile",
        &.{.{ .name = "username", .value = "ada" }},
        &.{.{ .name = "avatar", .filename = "avatar.txt", .content_type = "text/plain", .content = "hello file" }},
    );
    defer multipart.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, multipart.status);
    try testing.expectEqualStrings("{\"username\":\"ada\",\"filename\":\"avatar.txt\",\"content_type\":\"text/plain\",\"size\":10}", multipart.body.items);

    var put_multipart = try client.putMultipart(
        "/profile",
        &.{.{ .name = "username", .value = "grace" }},
        &.{.{ .name = "avatar", .filename = "avatar.txt", .content_type = "text/plain", .content = "updated file" }},
    );
    defer put_multipart.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, put_multipart.status);
    try testing.expectEqualStrings("{\"username\":\"grace\",\"filename\":\"avatar.txt\",\"content_type\":\"text/plain\",\"size\":12}", put_multipart.body.items);

    var patch_multipart = try client.patchMultipart(
        "/profile",
        &.{.{ .name = "username", .value = "alan" }},
        &.{.{ .name = "avatar", .filename = "avatar.txt", .content_type = "text/plain", .content = "patch" }},
    );
    defer patch_multipart.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, patch_multipart.status);
    try testing.expectEqualStrings("{\"username\":\"alan\",\"filename\":\"avatar.txt\",\"content_type\":\"text/plain\",\"size\":5}", patch_multipart.body.items);

    var delete_multipart = try client.deleteMultipart(
        "/profile",
        &.{.{ .name = "username", .value = "marie" }},
        &.{.{ .name = "avatar", .filename = "avatar.txt", .content_type = "text/plain", .content = "delete" }},
    );
    defer delete_multipart.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, delete_multipart.status);
    try testing.expectEqualStrings("{\"username\":\"marie\",\"filename\":\"avatar.txt\",\"content_type\":\"text/plain\",\"size\":6}", delete_multipart.body.items);

    var options_multipart = try client.optionsMultipart(
        "/profile",
        &.{.{ .name = "username", .value = "katherine" }},
        &.{.{ .name = "avatar", .filename = "avatar.txt", .content_type = "text/plain", .content = "options" }},
    );
    defer options_multipart.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, options_multipart.status);
    try testing.expectEqualStrings("{\"username\":\"katherine\",\"filename\":\"avatar.txt\",\"content_type\":\"text/plain\",\"size\":7}", options_multipart.body.items);

    var trace_multipart = try client.traceMultipart(
        "/profile",
        &.{.{ .name = "username", .value = "dorothy" }},
        &.{.{ .name = "avatar", .filename = "avatar.txt", .content_type = "text/plain", .content = "trace" }},
    );
    defer trace_multipart.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, trace_multipart.status);
    try testing.expectEqualStrings("{\"username\":\"dorothy\",\"filename\":\"avatar.txt\",\"content_type\":\"text/plain\",\"size\":5}", trace_multipart.body.items);

    var gallery = try client.postMultipart(
        "/gallery",
        &.{.{ .name = "username", .value = "ada" }},
        &.{
            .{ .name = "photos", .filename = "one.txt", .content_type = "text/plain", .content = "one" },
            .{ .name = "photos", .filename = "two.txt", .content_type = "text/plain", .content = "two-two" },
        },
    );
    defer gallery.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, gallery.status);
    try testing.expectEqualStrings("{\"username\":\"ada\",\"first_filename\":\"one.txt\",\"second_filename\":\"two.txt\",\"total_size\":10}", gallery.body.items);

    var put_response = try client.putJson("/method", "{\"op\":\"replace\"}");
    defer put_response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, put_response.status);
    try testing.expectEqualStrings("{\"method\":\"PUT\",\"body\":\"{\\\"op\\\":\\\"replace\\\"}\"}", put_response.body.items);

    var put_value = try client.putJsonValue("/method", .{ .op = "replace" });
    defer put_value.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, put_value.status);
    try testing.expectEqualStrings("{\"method\":\"PUT\",\"body\":\"{\\\"op\\\":\\\"replace\\\"}\"}", put_value.body.items);

    var patch_response = try client.patchJson("/method", "{\"op\":\"patch\"}");
    defer patch_response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, patch_response.status);
    try testing.expectEqualStrings("{\"method\":\"PATCH\",\"body\":\"{\\\"op\\\":\\\"patch\\\"}\"}", patch_response.body.items);

    var patch_value = try client.patchJsonValue("/method", .{ .op = "patch" });
    defer patch_value.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, patch_value.status);
    try testing.expectEqualStrings("{\"method\":\"PATCH\",\"body\":\"{\\\"op\\\":\\\"patch\\\"}\"}", patch_value.body.items);

    var delete_json = try client.deleteJson("/method", "{\"op\":\"delete\"}");
    defer delete_json.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, delete_json.status);
    try testing.expectEqualStrings("{\"method\":\"DELETE\",\"body\":\"{\\\"op\\\":\\\"delete\\\"}\"}", delete_json.body.items);

    var delete_json_value = try client.deleteJsonValue("/method", .{ .op = "delete" });
    defer delete_json_value.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, delete_json_value.status);
    try testing.expectEqualStrings("{\"method\":\"DELETE\",\"body\":\"{\\\"op\\\":\\\"delete\\\"}\"}", delete_json_value.body.items);

    var options_json = try client.optionsJson("/method", "{\"op\":\"options\"}");
    defer options_json.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, options_json.status);
    try testing.expectEqualStrings("{\"method\":\"OPTIONS\",\"body\":\"{\\\"op\\\":\\\"options\\\"}\"}", options_json.body.items);

    var options_json_value = try client.optionsJsonValue("/method", .{ .op = "options" });
    defer options_json_value.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, options_json_value.status);
    try testing.expectEqualStrings("{\"method\":\"OPTIONS\",\"body\":\"{\\\"op\\\":\\\"options\\\"}\"}", options_json_value.body.items);

    var trace_json = try client.traceJson("/method", "{\"op\":\"trace\"}");
    defer trace_json.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, trace_json.status);
    try testing.expectEqualStrings("{\"method\":\"TRACE\",\"body\":\"{\\\"op\\\":\\\"trace\\\"}\"}", trace_json.body.items);

    var trace_json_value = try client.traceJsonValue("/method", .{ .op = "trace" });
    defer trace_json_value.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, trace_json_value.status);
    try testing.expectEqualStrings("{\"method\":\"TRACE\",\"body\":\"{\\\"op\\\":\\\"trace\\\"}\"}", trace_json_value.body.items);

    var deleted = try client.delete("/method");
    defer deleted.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, deleted.status);
    try testing.expectEqualStrings("{\"method\":\"DELETE\",\"body\":\"\"}", deleted.body.items);

    var options = try client.options("/method");
    defer options.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, options.status);
    try testing.expectEqualStrings("{\"method\":\"OPTIONS\",\"body\":\"\"}", options.body.items);

    var head = try client.head("/head");
    defer head.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, head.status);
    try testing.expectEqual(@as(usize, 0), head.body.items.len);
}

test "started test client runs lifespan handlers and can shut down explicitly" {
    var state: LifecycleState = .{};
    defer state.events.deinit(testing.allocator);

    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    app.setState(&state);
    try app.addStartupHandler(parentStartup);
    try app.addShutdownHandler(parentShutdown);
    try app.route(Route.get("/", plainText, .{}));

    {
        var client = try TestClient.start(testing.allocator, &app, .{});
        defer client.deinit();
        try testing.expectEqual(@as(usize, 1), state.events.items.len);
        try testing.expectEqualStrings("parent-startup", state.events.items[0]);

        var response = try client.get("/");
        defer response.deinit(testing.allocator);
        try testing.expectEqual(Status.ok, response.status);
        try testing.expectEqualStrings("Hello, world", response.body.items);

        try client.shutdown();
        try testing.expectEqual(@as(usize, 2), state.events.items.len);
        try testing.expectEqualStrings("parent-shutdown", state.events.items[1]);
    }

    try testing.expectEqual(@as(usize, 2), state.events.items.len);
}

test "started test client deinit shuts down mounted app lifespan" {
    var state: LifecycleState = .{};
    defer state.events.deinit(testing.allocator);

    var parent = ZAPI.init(testing.allocator, .{});
    defer parent.deinit();
    var child = ZAPI.init(testing.allocator, .{});
    defer child.deinit();

    parent.setState(&state);
    child.setState(&state);
    try parent.addStartupHandler(parentStartup);
    try parent.addShutdownHandler(parentShutdown);
    try child.addStartupHandler(childStartup);
    try child.addShutdownHandler(childShutdown);
    try child.route(Route.get("/", plainText, .{}));
    try parent.mount("/child", &child);

    {
        var client = try TestClient.start(testing.allocator, &parent, .{});
        defer client.deinit();

        var response = try client.get("/child");
        defer response.deinit(testing.allocator);
        try testing.expectEqual(Status.ok, response.status);
        try testing.expectEqualStrings("Hello, world", response.body.items);
        try testing.expectEqual(@as(usize, 2), state.events.items.len);
        try testing.expectEqualStrings("parent-startup", state.events.items[0]);
        try testing.expectEqualStrings("child-startup", state.events.items[1]);
    }

    try testing.expectEqual(@as(usize, 4), state.events.items.len);
    try testing.expectEqualStrings("child-shutdown", state.events.items[2]);
    try testing.expectEqualStrings("parent-shutdown", state.events.items[3]);
}

test "raw request helpers parse json and urlencoded form bodies" {
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    try app.route(Route.post("/raw-json", echoRawJson, .{}));
    try app.route(Route.post("/raw-form", echoRawForm, .{}));
    try app.route(Route.post("/raw-form-data", echoRawFormData, .{}));

    var json_req = Request.init(.POST, "/raw-json");
    json_req.body = "{\"name\":\"ada\",\"count\":3}";
    var json_response = try app.handle(json_req);
    defer json_response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, json_response.status);
    try testing.expectEqualStrings("{\"name\":\"ada\",\"count\":3}", json_response.body.items);

    var typed_json_req = Request.init(.POST, "/raw-json");
    typed_json_req.headers = &.{.{ .name = "content-type", .value = "application/problem+json; charset=utf-8" }};
    typed_json_req.body = "{\"name\":\"grace\",\"count\":4}";
    var typed_json = try app.handle(typed_json_req);
    defer typed_json.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, typed_json.status);
    try testing.expectEqualStrings("{\"name\":\"grace\",\"count\":4}", typed_json.body.items);

    var invalid_json_req = Request.init(.POST, "/raw-json");
    invalid_json_req.body = "{\"name\":123}";
    var invalid_json = try app.handle(invalid_json_req);
    defer invalid_json.deinit(testing.allocator);
    try testing.expectEqual(Status.unprocessable_entity, invalid_json.status);

    var wrong_json_type_req = Request.init(.POST, "/raw-json");
    wrong_json_type_req.headers = &.{.{ .name = "content-type", .value = "text/plain" }};
    wrong_json_type_req.body = "{\"name\":\"ada\",\"count\":3}";
    var wrong_json_type = try app.handle(wrong_json_type_req);
    defer wrong_json_type.deinit(testing.allocator);
    try testing.expectEqual(Status.unprocessable_entity, wrong_json_type.status);

    var form_req = Request.init(.POST, "/raw-form");
    form_req.headers = &.{.{ .name = "content-type", .value = "application/x-www-form-urlencoded; charset=utf-8" }};
    form_req.body = "username=ada&tag=first&empty=&tag=last+tag";
    var form_response = try app.handle(form_req);
    defer form_response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, form_response.status);
    try testing.expectEqualStrings("{\"username\":\"ada\",\"tag\":\"last tag\",\"tags\":[\"first\",\"last tag\"],\"empty\":\"\"}", form_response.body.items);

    var direct_form = try form_req.formData(testing.allocator);
    defer direct_form.deinit();
    try testing.expectEqual(@as(usize, 3), direct_form.len());
    try testing.expect(!direct_form.isEmpty());
    try testing.expect(direct_form.contains("username"));
    try testing.expect(!direct_form.contains("missing"));
    try testing.expectEqualStrings("ada", direct_form.getText("username").?);
    try testing.expectEqualStrings("last tag", direct_form.getText("tag").?);
    const direct_tags = direct_form.getAll("tag").?;
    try testing.expectEqual(@as(usize, 2), direct_tags.len);
    try testing.expectEqualStrings("first", switch (direct_tags[0]) {
        .text => |text| text,
        .file => return error.TestUnexpectedResult,
    });
    const direct_items = direct_form.multiItems();
    try testing.expectEqual(@as(usize, 4), direct_items.len);
    const direct_items_alias = direct_form.items();
    try testing.expectEqual(@as(usize, 4), direct_items_alias.len);
    try testing.expectEqualStrings("username", direct_items[0].name);
    try testing.expectEqualStrings("ada", switch (direct_items[0].value) {
        .text => |text| text,
        .file => return error.TestUnexpectedResult,
    });
    try testing.expectEqualStrings("tag", direct_items[1].name);
    try testing.expectEqualStrings("first", switch (direct_items[1].value) {
        .text => |text| text,
        .file => return error.TestUnexpectedResult,
    });
    try testing.expectEqualStrings("empty", direct_items[2].name);
    try testing.expectEqualStrings("", switch (direct_items[2].value) {
        .text => |text| text,
        .file => return error.TestUnexpectedResult,
    });
    try testing.expectEqualStrings("tag", direct_items[3].name);
    try testing.expectEqualStrings("last tag", switch (direct_items[3].value) {
        .text => |text| text,
        .file => return error.TestUnexpectedResult,
    });
    const direct_tag_text = (try direct_form.getAllText(testing.allocator, "tag")).?;
    defer testing.allocator.free(direct_tag_text);
    try testing.expectEqual(@as(usize, 2), direct_tag_text.len);
    try testing.expectEqualStrings("first", direct_tag_text[0]);
    try testing.expectEqualStrings("last tag", direct_tag_text[1]);
    const missing_text = try direct_form.getAllText(testing.allocator, "missing");
    try testing.expect(missing_text == null);
    try testing.expect(direct_form.getFile("tag") == null);

    var empty_form_req = Request.init(.POST, "/raw-form");
    empty_form_req.headers = &.{.{ .name = "content-type", .value = "application/x-www-form-urlencoded" }};
    empty_form_req.body = "";
    var empty_form = try empty_form_req.formData(testing.allocator);
    defer empty_form.deinit();
    try testing.expectEqual(@as(usize, 0), empty_form.len());
    try testing.expect(empty_form.isEmpty());
    try testing.expectEqual(@as(usize, 0), empty_form.multiItems().len);

    var multipart_req = Request.init(.POST, "/raw-form-data");
    multipart_req.headers = &.{.{ .name = "content-type", .value = "multipart/form-data; boundary=zapi-boundary" }};
    multipart_req.body =
        "--zapi-boundary\r\n" ++
        "content-disposition: form-data; name=\"title\"\r\n" ++
        "\r\n" ++
        "Quarterly report\r\n" ++
        "--zapi-boundary\r\n" ++
        "content-disposition: form-data; name=\"document\"; filename=\"report.txt\"\r\n" ++
        "content-type: text/plain\r\n" ++
        "\r\n" ++
        "hello file\r\n" ++
        "--zapi-boundary--";
    var multipart_response = try app.handle(multipart_req);
    defer multipart_response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, multipart_response.status);
    try testing.expectEqualStrings("{\"title\":\"Quarterly report\",\"filename\":\"report.txt\",\"content_type\":\"text/plain\",\"content\":\"hello file\",\"file_count\":1}", multipart_response.body.items);

    var direct_multipart = try multipart_req.formData(testing.allocator);
    defer direct_multipart.deinit();
    const multipart_items = direct_multipart.multiItems();
    try testing.expectEqual(@as(usize, 2), multipart_items.len);
    try testing.expectEqualStrings("title", multipart_items[0].name);
    try testing.expectEqualStrings("Quarterly report", switch (multipart_items[0].value) {
        .text => |text| text,
        .file => return error.TestUnexpectedResult,
    });
    try testing.expectEqualStrings("document", multipart_items[1].name);
    try testing.expectEqualStrings("report.txt", switch (multipart_items[1].value) {
        .text => return error.TestUnexpectedResult,
        .file => |file| file.filename,
    });
    const title_text = (try direct_multipart.getAllText(testing.allocator, "title")).?;
    defer testing.allocator.free(title_text);
    try testing.expectEqual(@as(usize, 1), title_text.len);
    try testing.expectEqualStrings("Quarterly report", title_text[0]);
    const document_files = (try direct_multipart.getAllFiles(testing.allocator, "document")).?;
    defer testing.allocator.free(document_files);
    try testing.expectEqual(@as(usize, 1), document_files.len);
    try testing.expectEqualStrings("report.txt", document_files[0].filename);
    try testing.expectEqualStrings("hello file", document_files[0].content);
    const title_files = (try direct_multipart.getAllFiles(testing.allocator, "title")).?;
    defer testing.allocator.free(title_files);
    try testing.expectEqual(@as(usize, 0), title_files.len);

    var missing_boundary_req = Request.init(.POST, "/raw-form-data");
    missing_boundary_req.headers = &.{.{ .name = "content-type", .value = "multipart/form-data" }};
    missing_boundary_req.body = multipart_req.body;
    var missing_boundary = try app.handle(missing_boundary_req);
    defer missing_boundary.deinit(testing.allocator);
    try testing.expectEqual(Status.unprocessable_entity, missing_boundary.status);

    var wrong_form_type_req = Request.init(.POST, "/raw-form");
    wrong_form_type_req.body = "username=ada";
    var wrong_form_type = try app.handle(wrong_form_type_req);
    defer wrong_form_type.deinit(testing.allocator);
    try testing.expectEqual(Status.unprocessable_entity, wrong_form_type.status);

    var invalid_form_req = Request.init(.POST, "/raw-form");
    invalid_form_req.headers = &.{.{ .name = "content-type", .value = "application/x-www-form-urlencoded" }};
    invalid_form_req.body = "bad%ZZ=value";
    var invalid_form = try app.handle(invalid_form_req);
    defer invalid_form.deinit(testing.allocator);
    try testing.expectEqual(Status.unprocessable_entity, invalid_form.status);
}

test "supports routers with prefixes and path/query validation" {
    const users = comptime Router.init(.{
        .prefix = "/users",
        .tags = &.{"users"},
        .routes = .{
            Route.put("/{username}:disable", disableUser, .{ .name = "disable_user" }),
            Route.get("/path-with-parentheses({id:int})", getUser, .{ .name = "path_with_parentheses" }),
            Route.get("/{id}", getUser, .{ .summary = "Get user" }),
        },
    });

    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    try app.includeRouter(users);

    var response = try app.handle(Request.init(.GET, "/users/42?verbose=true"));
    defer response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, response.status);
    try testing.expectEqualStrings("{\"id\":42,\"email\":\"ada@example.com\"}", response.body.items);

    var invalid = try app.handle(Request.init(.GET, "/users/not-an-int"));
    defer invalid.deinit(testing.allocator);
    try testing.expectEqual(Status.unprocessable_entity, invalid.status);

    var disabled = try app.handle(Request.init(.PUT, "/users/ada:disable"));
    defer disabled.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, disabled.status);
    try testing.expectEqualStrings("{\"value\":\"ada\"}", disabled.body.items);

    var disabled_miss = try app.handle(Request.init(.PUT, "/users/ada"));
    defer disabled_miss.deinit(testing.allocator);
    try testing.expectEqual(Status.method_not_allowed, disabled_miss.status);

    var parenthesized = try app.handle(Request.init(.GET, "/users/path-with-parentheses(7)"));
    defer parenthesized.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, parenthesized.status);
    try testing.expectEqualStrings("{\"id\":7,\"email\":\"ada@example.com\"}", parenthesized.body.items);

    const disabled_path = try app.urlPathFor("disable_user", .{ .username = "ada" });
    defer testing.allocator.free(disabled_path);
    try testing.expectEqualStrings("/users/ada:disable", disabled_path);

    const parenthesized_path = try app.urlPathFor("path_with_parentheses", .{ .id = 7 });
    defer testing.allocator.free(parenthesized_path);
    try testing.expectEqualStrings("/users/path-with-parentheses(7)", parenthesized_path);
}

test "route registration rejects malformed and duplicate path parameters" {
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();

    try testing.expectError(error.DuplicatePathParam, app.route(Route.get("/{id}/{id}", getUser, .{})));
    try testing.expectError(error.InvalidRoutePath, app.route(Route.get("/users/{id", getUser, .{})));
    try testing.expectError(error.InvalidRoutePath, app.route(Route.get("/users/{id:missing}", getUser, .{})));
    try testing.expectError(error.InvalidRoutePath, app.route(Route.get("/users/{user-id}", getUser, .{})));
    try testing.expectError(error.InvalidRoutePath, app.route(Route.get("/users/{1id}", getUser, .{})));
    try testing.expectError(error.InvalidRoutePath, app.route(Route.get("/files/prefix-{rest:path}", getPathTail, .{})));
    try testing.expectError(error.InvalidRoutePath, app.route(Route.get("/files/{rest:path}/suffix", getPathTail, .{})));

    const router = Router.init(.{
        .prefix = "/{tenant}",
        .routes = .{
            Route.get("/users/{tenant}", plainText, .{}),
        },
    });
    try testing.expectError(error.DuplicatePathParam, app.includeRouter(router));
}

test "route registration rejects ambiguous duplicate route names" {
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();

    try app.route(Route.get("/users/{id:int}", getUser, .{ .name = "detail" }));
    try testing.expectError(error.DuplicateRouteName, app.route(Route.get("/teams/{id:int}", getUser, .{ .name = "detail" })));

    try app.route(Route.get("/health", plainText, .{ .name = "health" }));
    try app.route(Route.post("/health", plainText, .{ .name = "health" }));

    const health_path = try app.urlPathFor("health", .{});
    defer testing.allocator.free(health_path);
    try testing.expectEqualStrings("/health", health_path);
}

test "router registration rejects duplicate route names across prefixes" {
    const users = comptime Router.init(.{
        .prefix = "/users",
        .routes = .{
            Route.get("/{id:int}", getUser, .{ .name = "detail" }),
        },
    });
    const teams = Router.init(.{
        .prefix = "/teams",
        .routes = .{
            Route.get("/{id:int}", getUser, .{ .name = "detail" }),
        },
    });

    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();

    try app.includeRouter(users);
    try testing.expectError(error.DuplicateRouteName, app.includeRouter(teams));
}

test "generated route names include router prefixes" {
    const users = comptime Router.init(.{
        .prefix = "/users",
        .routes = .{
            Route.get("/", plainText, .{}),
            Route.get("/{id:int}", getUser, .{}),
        },
    });
    const teams = Router.init(.{
        .prefix = "/teams",
        .routes = .{
            Route.get("/", plainText, .{}),
            Route.get("/{id:int}", getUser, .{}),
        },
    });

    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();

    try app.includeRouter(users);
    try app.includeRouter(teams);

    const users_path = try app.urlPathFor("get_users", .{});
    defer testing.allocator.free(users_path);
    try testing.expectEqualStrings("/users", users_path);

    const user_path = try app.urlPathFor("get_users_id", .{ .id = 7 });
    defer testing.allocator.free(user_path);
    try testing.expectEqualStrings("/users/7", user_path);

    const teams_path = try app.urlPathFor("get_teams", .{});
    defer testing.allocator.free(teams_path);
    try testing.expectEqualStrings("/teams", teams_path);

    const team_path = try app.urlPathFor("get_teams_id", .{ .id = 8 });
    defer testing.allocator.free(team_path);
    try testing.expectEqualStrings("/teams/8", team_path);
}

test "explicit null route names remain unnamed under router prefixes" {
    const admin = Router.init(.{
        .prefix = "/admin",
        .routes = .{
            Route.get("/panel", plainText, .{ .name = null }),
        },
    });

    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    try app.includeRouter(admin);

    var response = try app.handle(Request.init(.GET, "/admin/panel"));
    defer response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, response.status);
    try testing.expectEqualStrings("Hello, world", response.body.items);

    try testing.expectError(error.NoRoute, app.urlPathFor("get_admin_panel", .{}));
}

test "router route groups register multiple methods for one handler" {
    const router = Router.init(.{
        .routes = .{
            Route.methods("/ping", &.{ .GET, .POST }, plainText, .{ .summary = "Ping" }),
        },
    });

    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    try app.includeRouter(router);
    try app.route(Route.methods("/direct", &.{ .PUT, .PATCH }, plainText, .{ .name = "direct_group" }));

    var get_response = try app.handle(Request.init(.GET, "/ping"));
    defer get_response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, get_response.status);
    try testing.expectEqualStrings("Hello, world", get_response.body.items);

    var post_response = try app.handle(Request.init(.POST, "/ping"));
    defer post_response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, post_response.status);
    try testing.expectEqualStrings("Hello, world", post_response.body.items);

    var head_response = try app.handle(Request.init(.HEAD, "/ping"));
    defer head_response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, head_response.status);
    try testing.expectEqual(@as(usize, 0), head_response.body.items.len);

    var put_response = try app.handle(Request.init(.PUT, "/direct"));
    defer put_response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, put_response.status);
    try testing.expectEqualStrings("Hello, world", put_response.body.items);

    var patch_response = try app.handle(Request.init(.PATCH, "/direct"));
    defer patch_response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, patch_response.status);
    try testing.expectEqualStrings("Hello, world", patch_response.body.items);

    const direct_path = try app.urlPathFor("direct_group", .{});
    defer testing.allocator.free(direct_path);
    try testing.expectEqualStrings("/direct", direct_path);
}

test "nested routers preserve prefixes tags route groups and reversing" {
    const users = comptime Router.init(.{
        .prefix = "/users",
        .tags = &.{"users"},
        .routes = .{
            Route.get("/{id:int}", getUser, .{ .name = "nested_user" }),
            Route.methods("/ping", &.{ .GET, .POST }, plainText, .{ .name = "nested_ping" }),
        },
    });

    const api = comptime Router.init(.{
        .prefix = "/api",
        .tags = &.{"api"},
        .routes = .{
            users,
            Route.get("/status", plainText, .{ .name = "api_status" }),
        },
    });

    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    try app.includeRouter(api);

    var user = try app.handle(Request.init(.GET, "/api/users/42"));
    defer user.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, user.status);
    try testing.expectEqualStrings("{\"id\":42,\"email\":\"ada@example.com\"}", user.body.items);

    var ping = try app.handle(Request.init(.POST, "/api/users/ping"));
    defer ping.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, ping.status);
    try testing.expectEqualStrings("Hello, world", ping.body.items);

    var status = try app.handle(Request.init(.GET, "/api/status"));
    defer status.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, status.status);
    try testing.expectEqualStrings("Hello, world", status.body.items);

    const user_path = try app.urlPathFor("nested_user", .{ .id = 42 });
    defer testing.allocator.free(user_path);
    try testing.expectEqualStrings("/api/users/42", user_path);

    const ping_path = try app.urlPathFor("nested_ping", .{});
    defer testing.allocator.free(ping_path);
    try testing.expectEqualStrings("/api/users/ping", ping_path);
}

test "validates required query params and applies defaults" {
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    try app.route(Route.get("/search", searchUsers, .{}));
    try app.route(Route.get("/users/{id}", getUser, .{}));

    var missing = try app.handle(Request.init(.GET, "/search"));
    defer missing.deinit(testing.allocator);
    try testing.expectEqual(Status.unprocessable_entity, missing.status);

    var response = try app.handle(Request.init(.GET, "/search?q=ada"));
    defer response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, response.status);
    try testing.expectEqualStrings("{\"q\":\"ada\",\"limit\":10}", response.body.items);

    var plus_response = try app.handle(Request.init(.GET, "/search?q=ada+lovelace&limit=2"));
    defer plus_response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, plus_response.status);
    try testing.expectEqualStrings("{\"q\":\"ada lovelace\",\"limit\":2}", plus_response.body.items);

    var bool_response = try app.handle(Request.init(.GET, "/users/42?verbose=YES"));
    defer bool_response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, bool_response.status);
}

test "openapi snapshot includes scalar query defaults" {
    var app = ZAPI.init(testing.allocator, .{ .title = "Search API", .version = "1.0.0" });
    defer app.deinit();
    try app.route(Route.get("/search", searchUsers, .{
        .name = "search_users",
        .summary = "Search users",
    }));

    var openapi = try app.handle(Request.init(.GET, "/openapi.json"));
    defer openapi.deinit(testing.allocator);
    try expectJsonEqual(
        \\{
        \\  "openapi": "3.1.0",
        \\  "info": {
        \\    "title": "Search API",
        \\    "version": "1.0.0"
        \\  },
        \\  "paths": {
        \\    "/search": {
        \\      "get": {
        \\        "operationId": "search_users",
        \\        "summary": "Search users",
        \\        "parameters": [
        \\          {"name": "q", "in": "query", "required": true, "schema": {"type": "string"}},
        \\          {"name": "limit", "in": "query", "required": false, "schema": {"type": "integer", "default": 10}}
        \\        ],
        \\        "responses": {
        \\          "200": {
        \\            "description": "OK",
        \\            "content": {
        \\              "application/json": {
        \\                "schema": {"$ref": "#/components/schemas/SearchUsersResult"}
        \\              }
        \\            }
        \\          },
        \\          "422": {
        \\            "description": "Validation Error",
        \\            "content": {
        \\              "application/json": {
        \\                "schema": {"$ref": "#/components/schemas/ProblemDetail"}
        \\              }
        \\            }
        \\          }
        \\        }
        \\      }
        \\    }
        \\  },
        \\  "components": {
        \\    "schemas": {
        \\      "SearchUsersResult": {
        \\        "type": "object",
        \\        "properties": {
        \\          "q": {"type": "string"},
        \\          "limit": {"type": "integer"}
        \\        },
        \\        "required": ["q", "limit"],
        \\        "additionalProperties": false
        \\      },
        \\      "ProblemDetail": {
        \\        "type": "object",
        \\        "properties": {
        \\          "detail": {"type": "string"}
        \\        },
        \\        "required": ["detail"],
        \\        "additionalProperties": false
        \\      }
        \\    }
        \\  }
        \\}
    ,
        openapi.body.items,
    );
}

test "parses repeated query params into arrays" {
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    try app.route(Route.get("/tags", searchTags, .{}));

    var response = try app.handle(Request.init(.GET, "/tags?tag=zig&tag=api&limit=10&limit=20"));
    defer response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, response.status);
    try testing.expectEqualStrings("{\"tags\":[\"zig\",\"api\"],\"limits\":[10,20]}", response.body.items);

    var plus_response = try app.handle(Request.init(.GET, "/tags?tag=zig+api&tag=web%20framework"));
    defer plus_response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, plus_response.status);
    try testing.expectEqualStrings("{\"tags\":[\"zig api\",\"web framework\"],\"limits\":[10]}", plus_response.body.items);

    var default_limit = try app.handle(Request.init(.GET, "/tags?tag=zig"));
    defer default_limit.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, default_limit.status);
    try testing.expectEqualStrings("{\"tags\":[\"zig\"],\"limits\":[10]}", default_limit.body.items);

    var missing = try app.handle(Request.init(.GET, "/tags"));
    defer missing.deinit(testing.allocator);
    try testing.expectEqual(Status.unprocessable_entity, missing.status);

    var invalid = try app.handle(Request.init(.GET, "/tags?tag=zig&limit=nope"));
    defer invalid.deinit(testing.allocator);
    try testing.expectEqual(Status.unprocessable_entity, invalid.status);
}

test "validates enum path and query parameters" {
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    try app.route(Route.get("/states", echoQueryState, .{}));
    try app.route(Route.get("/states/{state}", echoPathState, .{ .name = "state_detail" }));

    var query_response = try app.handle(Request.init(.GET, "/states?state=active"));
    defer query_response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, query_response.status);
    try testing.expectEqualStrings("{\"state\":\"active\"}", query_response.body.items);

    var path_response = try app.handle(Request.init(.GET, "/states/disabled"));
    defer path_response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, path_response.status);
    try testing.expectEqualStrings("{\"state\":\"disabled\"}", path_response.body.items);

    var invalid_query = try app.handle(Request.init(.GET, "/states?state=deleted"));
    defer invalid_query.deinit(testing.allocator);
    try testing.expectEqual(Status.unprocessable_entity, invalid_query.status);

    var invalid_path = try app.handle(Request.init(.GET, "/states/deleted"));
    defer invalid_path.deinit(testing.allocator);
    try testing.expectEqual(Status.unprocessable_entity, invalid_path.status);

    const path = try app.urlPathFor("state_detail", .{ .state = UserState.disabled });
    defer testing.allocator.free(path);
    try testing.expectEqualStrings("/states/disabled", path);
}

test "validates typed headers with case-insensitive lookup and defaults" {
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    try app.route(Route.get("/headers", echoHeaders, .{}));

    var req = Request.init(.GET, "/headers");
    req.headers = &.{
        .{ .name = "X-Token", .value = "secret" },
        .{ .name = "x-retries", .value = "3" },
    };
    var response = try app.handle(req);
    defer response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, response.status);
    try testing.expectEqualStrings("{\"token\":\"secret\",\"debug\":false,\"retries\":3}", response.body.items);

    var bool_req = Request.init(.GET, "/headers");
    bool_req.headers = &.{
        .{ .name = "x-token", .value = "secret" },
        .{ .name = "x-debug", .value = "on" },
        .{ .name = "x-retries", .value = "3" },
    };
    var bool_response = try app.handle(bool_req);
    defer bool_response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, bool_response.status);
    try testing.expectEqualStrings("{\"token\":\"secret\",\"debug\":true,\"retries\":3}", bool_response.body.items);

    var missing = try app.handle(Request.init(.GET, "/headers"));
    defer missing.deinit(testing.allocator);
    try testing.expectEqual(Status.unprocessable_entity, missing.status);

    var invalid_req = Request.init(.GET, "/headers");
    invalid_req.headers = &.{
        .{ .name = "x-token", .value = "secret" },
        .{ .name = "x-retries", .value = "not-a-number" },
    };
    var invalid = try app.handle(invalid_req);
    defer invalid.deinit(testing.allocator);
    try testing.expectEqual(Status.unprocessable_entity, invalid.status);
}

test "parses repeated typed headers into arrays" {
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    try app.route(Route.get("/header-list", echoHeaderList, .{}));

    var req = Request.init(.GET, "/header-list");
    req.headers = &.{
        .{ .name = "X-Token", .value = "first" },
        .{ .name = "x-token", .value = "second" },
    };
    var response = try app.handle(req);
    defer response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, response.status);
    try testing.expectEqualStrings("{\"tokens\":[\"first\",\"second\"]}", response.body.items);

    var missing = try app.handle(Request.init(.GET, "/header-list"));
    defer missing.deinit(testing.allocator);
    try testing.expectEqual(Status.unprocessable_entity, missing.status);
}

test "validates typed cookies with defaults" {
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    try app.route(Route.get("/cookies", echoCookies, .{}));

    var req = Request.init(.GET, "/cookies");
    req.headers = &.{
        .{ .name = "cookie", .value = "theme=dark; session_id=abc123; visits=4" },
    };
    var response = try app.handle(req);
    defer response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, response.status);
    try testing.expectEqualStrings("{\"session_id\":\"abc123\",\"preview\":false,\"visits\":4}", response.body.items);

    var bool_req = Request.init(.GET, "/cookies");
    bool_req.headers = &.{
        .{ .name = "cookie", .value = "session_id=abc123; preview=1; visits=4" },
    };
    var bool_response = try app.handle(bool_req);
    defer bool_response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, bool_response.status);
    try testing.expectEqualStrings("{\"session_id\":\"abc123\",\"preview\":true,\"visits\":4}", bool_response.body.items);

    var missing = try app.handle(Request.init(.GET, "/cookies"));
    defer missing.deinit(testing.allocator);
    try testing.expectEqual(Status.unprocessable_entity, missing.status);

    var invalid_req = Request.init(.GET, "/cookies");
    invalid_req.headers = &.{
        .{ .name = "cookie", .value = "session_id=abc123; visits=not-a-number" },
    };
    var invalid = try app.handle(invalid_req);
    defer invalid.deinit(testing.allocator);
    try testing.expectEqual(Status.unprocessable_entity, invalid.status);
}

test "typed query header and cookie params use route aliases" {
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    try app.route(Route.get("/aliases", echoAliasParams, .{
        .parameter_docs = &[_]OpenApiParameterDoc{
            .{ .name = "page_size", .location = .query, .alias = "page-size" },
            .{ .name = "api_key", .location = .header, .alias = "x-api-key" },
            .{ .name = "session_id", .location = .cookie, .alias = "session-id" },
        },
    }));

    var req = Request.init(.GET, "/aliases?page-size=25");
    req.headers = &.{
        .{ .name = "x-api-key", .value = "secret" },
        .{ .name = "cookie", .value = "session-id=abc123" },
    };
    var response = try app.handle(req);
    defer response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, response.status);
    try testing.expectEqualStrings("{\"page_size\":25,\"token\":\"secret\",\"session\":\"abc123\"}", response.body.items);

    var default_names_req = Request.init(.GET, "/aliases?page_size=25");
    default_names_req.headers = &.{
        .{ .name = "api-key", .value = "secret" },
        .{ .name = "cookie", .value = "session_id=abc123" },
    };
    var default_names = try app.handle(default_names_req);
    defer default_names.deinit(testing.allocator);
    try testing.expectEqual(Status.unprocessable_entity, default_names.status);
}

test "validates urlencoded forms with defaults" {
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    try app.route(Route.post("/login", login, .{}));
    try app.route(Route.post("/preferences", preferences, .{}));

    var req = Request.init(.POST, "/login");
    req.headers = &.{.{ .name = "content-type", .value = "application/x-www-form-urlencoded; charset=utf-8" }};
    req.body = "username=ada%20lovelace&password=secret&remember=true";
    var response = try app.handle(req);
    defer response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, response.status);
    try testing.expectEqualStrings("{\"username\":\"ada lovelace\",\"remember\":true,\"attempts\":1}", response.body.items);

    var plus_req = Request.init(.POST, "/login");
    plus_req.headers = &.{.{ .name = "content-type", .value = "application/x-www-form-urlencoded" }};
    plus_req.body = "username=ada+lovelace&password=secret&attempts=2";
    var plus_response = try app.handle(plus_req);
    defer plus_response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, plus_response.status);
    try testing.expectEqualStrings("{\"username\":\"ada lovelace\",\"remember\":false,\"attempts\":2}", plus_response.body.items);

    var bool_req = Request.init(.POST, "/login");
    bool_req.headers = &.{.{ .name = "content-type", .value = "application/x-www-form-urlencoded" }};
    bool_req.body = "username=ada&password=secret&remember=off";
    var bool_response = try app.handle(bool_req);
    defer bool_response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, bool_response.status);
    try testing.expectEqualStrings("{\"username\":\"ada\",\"remember\":false,\"attempts\":1}", bool_response.body.items);

    var repeated_req = Request.init(.POST, "/preferences");
    repeated_req.headers = &.{.{ .name = "content-type", .value = "application/x-www-form-urlencoded" }};
    repeated_req.body = "username=ada&tag=zig&tag=api&level=1&level=2";
    var repeated_response = try app.handle(repeated_req);
    defer repeated_response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, repeated_response.status);
    try testing.expectEqualStrings("{\"username\":\"ada\",\"tags\":[\"zig\",\"api\"],\"levels\":[1,2]}", repeated_response.body.items);

    var invalid_repeated_req = Request.init(.POST, "/preferences");
    invalid_repeated_req.headers = &.{.{ .name = "content-type", .value = "application/x-www-form-urlencoded" }};
    invalid_repeated_req.body = "username=ada&tag=zig&level=nope";
    var invalid_repeated = try app.handle(invalid_repeated_req);
    defer invalid_repeated.deinit(testing.allocator);
    try testing.expectEqual(Status.unprocessable_entity, invalid_repeated.status);

    var missing = Request.init(.POST, "/login");
    missing.headers = &.{.{ .name = "content-type", .value = "application/x-www-form-urlencoded" }};
    missing.body = "username=ada";
    var missing_response = try app.handle(missing);
    defer missing_response.deinit(testing.allocator);
    try testing.expectEqual(Status.unprocessable_entity, missing_response.status);

    var wrong_content_type = Request.init(.POST, "/login");
    wrong_content_type.headers = &.{.{ .name = "content-type", .value = "application/json" }};
    wrong_content_type.body = "username=ada&password=secret";
    var wrong_response = try app.handle(wrong_content_type);
    defer wrong_response.deinit(testing.allocator);
    try testing.expectEqual(Status.unprocessable_entity, wrong_response.status);

    var invalid = Request.init(.POST, "/login");
    invalid.headers = &.{.{ .name = "content-type", .value = "application/x-www-form-urlencoded" }};
    invalid.body = "username=ada&password=secret&attempts=not-a-number";
    var invalid_response = try app.handle(invalid);
    defer invalid_response.deinit(testing.allocator);
    try testing.expectEqual(Status.unprocessable_entity, invalid_response.status);
}

test "validates multipart forms with uploaded files" {
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    try app.route(Route.post("/profile", uploadProfile, .{}));
    try app.route(Route.post("/gallery", uploadGallery, .{}));

    const body =
        "--zapi-boundary\r\n" ++
        "Content-Disposition: form-data; name=\"username\"\r\n" ++
        "\r\n" ++
        "ada\r\n" ++
        "--zapi-boundary\r\n" ++
        "Content-Disposition: form-data; name=\"avatar\"; filename=\"avatar.txt\"\r\n" ++
        "Content-Type: text/plain\r\n" ++
        "\r\n" ++
        "hello file\r\n" ++
        "--zapi-boundary--\r\n";

    var req = Request.init(.POST, "/profile");
    req.headers = &.{.{ .name = "content-type", .value = "multipart/form-data; boundary=zapi-boundary" }};
    req.body = body;
    var response = try app.handle(req);
    defer response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, response.status);
    try testing.expectEqualStrings("{\"username\":\"ada\",\"filename\":\"avatar.txt\",\"content_type\":\"text/plain\",\"size\":10}", response.body.items);

    const missing_file_body =
        "--zapi-boundary\r\n" ++
        "Content-Disposition: form-data; name=\"username\"\r\n" ++
        "\r\n" ++
        "ada\r\n" ++
        "--zapi-boundary--\r\n";

    var missing_file = Request.init(.POST, "/profile");
    missing_file.headers = &.{.{ .name = "content-type", .value = "multipart/form-data; boundary=zapi-boundary" }};
    missing_file.body = missing_file_body;
    var missing_file_response = try app.handle(missing_file);
    defer missing_file_response.deinit(testing.allocator);
    try testing.expectEqual(Status.unprocessable_entity, missing_file_response.status);

    var missing_boundary = Request.init(.POST, "/profile");
    missing_boundary.headers = &.{.{ .name = "content-type", .value = "multipart/form-data" }};
    missing_boundary.body = body;
    var missing_boundary_response = try app.handle(missing_boundary);
    defer missing_boundary_response.deinit(testing.allocator);
    try testing.expectEqual(Status.unprocessable_entity, missing_boundary_response.status);

    const gallery_body =
        "--zapi-boundary\r\n" ++
        "Content-Disposition: form-data; name=\"username\"\r\n" ++
        "\r\n" ++
        "ada\r\n" ++
        "--zapi-boundary\r\n" ++
        "Content-Disposition: form-data; name=\"photos\"; filename=\"one.txt\"\r\n" ++
        "Content-Type: text/plain\r\n" ++
        "\r\n" ++
        "one\r\n" ++
        "--zapi-boundary\r\n" ++
        "Content-Disposition: form-data; name=\"photos\"; filename=\"two.txt\"\r\n" ++
        "Content-Type: text/plain\r\n" ++
        "\r\n" ++
        "two-two\r\n" ++
        "--zapi-boundary--\r\n";

    var gallery_req = Request.init(.POST, "/gallery");
    gallery_req.headers = &.{.{ .name = "content-type", .value = "multipart/form-data; boundary=zapi-boundary" }};
    gallery_req.body = gallery_body;
    var gallery_response = try app.handle(gallery_req);
    defer gallery_response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, gallery_response.status);
    try testing.expectEqualStrings("{\"username\":\"ada\",\"first_filename\":\"one.txt\",\"second_filename\":\"two.txt\",\"total_size\":10}", gallery_response.body.items);

    const text_photo_body =
        "--zapi-boundary\r\n" ++
        "Content-Disposition: form-data; name=\"username\"\r\n" ++
        "\r\n" ++
        "ada\r\n" ++
        "--zapi-boundary\r\n" ++
        "Content-Disposition: form-data; name=\"photos\"\r\n" ++
        "\r\n" ++
        "not a file\r\n" ++
        "--zapi-boundary--\r\n";

    var text_photo_req = Request.init(.POST, "/gallery");
    text_photo_req.headers = &.{.{ .name = "content-type", .value = "multipart/form-data; boundary=zapi-boundary" }};
    text_photo_req.body = text_photo_body;
    var text_photo_response = try app.handle(text_photo_req);
    defer text_photo_response.deinit(testing.allocator);
    try testing.expectEqual(Status.unprocessable_entity, text_photo_response.status);
}

test "validates bearer auth handler parameters" {
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    try app.route(Route.get("/me", secureMe, .{}));

    var req = Request.builder(testing.allocator, .GET, "/me");
    defer req.deinit();
    try req.bearerAuth("secret-token");
    var response = try req.send(&app);
    defer response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, response.status);
    try testing.expectEqualStrings("{\"token\":\"secret-token\"}", response.body.items);

    var lower_scheme_req = Request.init(.GET, "/me");
    lower_scheme_req.headers = &.{.{ .name = "authorization", .value = "bearer lower-token" }};
    var lower_scheme = try app.handle(lower_scheme_req);
    defer lower_scheme.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, lower_scheme.status);
    try testing.expectEqualStrings("{\"token\":\"lower-token\"}", lower_scheme.body.items);

    var spaced_scheme_req = Request.init(.GET, "/me");
    spaced_scheme_req.headers = &.{.{ .name = "authorization", .value = "Bearer    spaced-token" }};
    var spaced_scheme = try app.handle(spaced_scheme_req);
    defer spaced_scheme.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, spaced_scheme.status);
    try testing.expectEqualStrings("{\"token\":\"spaced-token\"}", spaced_scheme.body.items);

    var missing = try app.handle(Request.init(.GET, "/me"));
    defer missing.deinit(testing.allocator);
    try testing.expectEqual(Status.unauthorized, missing.status);
    try testing.expectEqualStrings("Bearer", missing.header("www-authenticate").?);
    try testing.expectEqualStrings("{\"detail\":\"Unauthorized\"}", missing.body.items);

    var malformed_req = Request.init(.GET, "/me");
    malformed_req.headers = &.{.{ .name = "authorization", .value = "Basic abc" }};
    var malformed = try app.handle(malformed_req);
    defer malformed.deinit(testing.allocator);
    try testing.expectEqual(Status.unauthorized, malformed.status);
    try testing.expectEqualStrings("Bearer", malformed.header("www-authenticate").?);

    var empty_req = Request.init(.GET, "/me");
    empty_req.headers = &.{.{ .name = "authorization", .value = "Bearer    " }};
    var empty = try app.handle(empty_req);
    defer empty.deinit(testing.allocator);
    try testing.expectEqual(Status.unauthorized, empty.status);
    try testing.expectEqualStrings("Bearer", empty.header("www-authenticate").?);
}

test "validates oauth2 password bearer handler parameters" {
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    try app.route(Route.get("/oauth2", secureOAuth2, .{}));

    var req = Request.builder(testing.allocator, .GET, "/oauth2");
    defer req.deinit();
    try req.bearerAuth("oauth-token");
    var response = try req.send(&app);
    defer response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, response.status);
    try testing.expectEqualStrings("{\"token\":\"oauth-token\"}", response.body.items);

    var mixed_scheme_req = Request.init(.GET, "/oauth2");
    mixed_scheme_req.headers = &.{.{ .name = "authorization", .value = "bEaReR mixed-token" }};
    var mixed_scheme = try app.handle(mixed_scheme_req);
    defer mixed_scheme.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, mixed_scheme.status);
    try testing.expectEqualStrings("{\"token\":\"mixed-token\"}", mixed_scheme.body.items);

    var missing = try app.handle(Request.init(.GET, "/oauth2"));
    defer missing.deinit(testing.allocator);
    try testing.expectEqual(Status.unauthorized, missing.status);
    try testing.expectEqualStrings("Bearer", missing.header("www-authenticate").?);
    try testing.expectEqualStrings("{\"detail\":\"Unauthorized\"}", missing.body.items);

    var malformed_req = Request.init(.GET, "/oauth2");
    malformed_req.headers = &.{.{ .name = "authorization", .value = "Bearer invalid token" }};
    var malformed = try app.handle(malformed_req);
    defer malformed.deinit(testing.allocator);
    try testing.expectEqual(Status.unauthorized, malformed.status);
    try testing.expectEqualStrings("Bearer", malformed.header("www-authenticate").?);
}

test "validates oauth2 authorization code bearer handler parameters" {
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    try app.route(Route.get("/oauth2-code", secureOAuth2AuthorizationCode, .{}));

    var req = Request.builder(testing.allocator, .GET, "/oauth2-code");
    defer req.deinit();
    try req.bearerAuth("auth-code-token");
    var response = try req.send(&app);
    defer response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, response.status);
    try testing.expectEqualStrings("{\"token\":\"auth-code-token\"}", response.body.items);

    var missing = try app.handle(Request.init(.GET, "/oauth2-code"));
    defer missing.deinit(testing.allocator);
    try testing.expectEqual(Status.unauthorized, missing.status);
    try testing.expectEqualStrings("Bearer", missing.header("www-authenticate").?);
    try testing.expectEqualStrings("{\"detail\":\"Unauthorized\"}", missing.body.items);
}

test "validates oauth2 client credentials bearer handler parameters" {
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    try app.route(Route.get("/oauth2-client", secureOAuth2ClientCredentials, .{}));

    var req = Request.builder(testing.allocator, .GET, "/oauth2-client");
    defer req.deinit();
    try req.bearerAuth("machine-token");
    var response = try req.send(&app);
    defer response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, response.status);
    try testing.expectEqualStrings("{\"token\":\"machine-token\"}", response.body.items);

    var missing = try app.handle(Request.init(.GET, "/oauth2-client"));
    defer missing.deinit(testing.allocator);
    try testing.expectEqual(Status.unauthorized, missing.status);
    try testing.expectEqualStrings("Bearer", missing.header("www-authenticate").?);
    try testing.expectEqualStrings("{\"detail\":\"Unauthorized\"}", missing.body.items);
}

test "validates oauth2 implicit bearer handler parameters" {
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    try app.route(Route.get("/oauth2-implicit", secureOAuth2Implicit, .{}));

    var req = Request.builder(testing.allocator, .GET, "/oauth2-implicit");
    defer req.deinit();
    try req.bearerAuth("browser-token");
    var response = try req.send(&app);
    defer response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, response.status);
    try testing.expectEqualStrings("{\"token\":\"browser-token\"}", response.body.items);

    var missing = try app.handle(Request.init(.GET, "/oauth2-implicit"));
    defer missing.deinit(testing.allocator);
    try testing.expectEqual(Status.unauthorized, missing.status);
    try testing.expectEqualStrings("Bearer", missing.header("www-authenticate").?);
    try testing.expectEqualStrings("{\"detail\":\"Unauthorized\"}", missing.body.items);
}

test "validates basic auth handler parameters" {
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    try app.route(Route.get("/basic", secureBasic, .{}));

    var req = Request.builder(testing.allocator, .GET, "/basic");
    defer req.deinit();
    try req.basicAuth("ada", "secret");
    var response = try req.send(&app);
    defer response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, response.status);
    try testing.expectEqualStrings("{\"username\":\"ada\",\"password\":\"secret\"}", response.body.items);

    var mixed_scheme_req = Request.init(.GET, "/basic");
    mixed_scheme_req.headers = &.{.{ .name = "authorization", .value = "bAsIc YWRhOnNlY3JldA==" }};
    var mixed_scheme = try app.handle(mixed_scheme_req);
    defer mixed_scheme.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, mixed_scheme.status);
    try testing.expectEqualStrings("{\"username\":\"ada\",\"password\":\"secret\"}", mixed_scheme.body.items);

    var spaced_scheme_req = Request.init(.GET, "/basic");
    spaced_scheme_req.headers = &.{.{ .name = "authorization", .value = "Basic    YWRhOnNlY3JldA==" }};
    var spaced_scheme = try app.handle(spaced_scheme_req);
    defer spaced_scheme.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, spaced_scheme.status);
    try testing.expectEqualStrings("{\"username\":\"ada\",\"password\":\"secret\"}", spaced_scheme.body.items);

    var missing = try app.handle(Request.init(.GET, "/basic"));
    defer missing.deinit(testing.allocator);
    try testing.expectEqual(Status.unauthorized, missing.status);
    try testing.expectEqualStrings("Basic", missing.header("www-authenticate").?);
    try testing.expectEqualStrings("{\"detail\":\"Unauthorized\"}", missing.body.items);

    var malformed_req = Request.init(.GET, "/basic");
    malformed_req.headers = &.{.{ .name = "authorization", .value = "Basic not-base64" }};
    var malformed = try app.handle(malformed_req);
    defer malformed.deinit(testing.allocator);
    try testing.expectEqual(Status.unauthorized, malformed.status);
    try testing.expectEqualStrings("Basic", malformed.header("www-authenticate").?);

    var no_colon_req = Request.init(.GET, "/basic");
    no_colon_req.headers = &.{.{ .name = "authorization", .value = "Basic YWRh" }};
    var no_colon = try app.handle(no_colon_req);
    defer no_colon.deinit(testing.allocator);
    try testing.expectEqual(Status.unauthorized, no_colon.status);
    try testing.expectEqualStrings("Basic", no_colon.header("www-authenticate").?);
}

test "validates api key auth handler parameters" {
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    try app.route(Route.get("/header", secureHeaderKey, .{}));
    try app.route(Route.get("/query", secureQueryKey, .{}));
    try app.route(Route.get("/cookie", secureCookieKey, .{}));

    var header_req = Request.builder(testing.allocator, .GET, "/header");
    defer header_req.deinit();
    try header_req.apiKeyHeader("X-API-Key", "header-secret");
    var header_response = try header_req.send(&app);
    defer header_response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, header_response.status);
    try testing.expectEqualStrings("{\"token\":\"header-secret\"}", header_response.body.items);

    var query_req = Request.builder(testing.allocator, .GET, "/query");
    defer query_req.deinit();
    try query_req.apiKeyQuery("api_key", "query secret");
    var query_response = try query_req.send(&app);
    defer query_response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, query_response.status);
    try testing.expectEqualStrings("{\"token\":\"query secret\"}", query_response.body.items);

    var plus_query_response = try app.handle(Request.init(.GET, "/query?api_key=query+secret"));
    defer plus_query_response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, plus_query_response.status);
    try testing.expectEqualStrings("{\"token\":\"query secret\"}", plus_query_response.body.items);

    var cookie_req = Request.builder(testing.allocator, .GET, "/cookie");
    defer cookie_req.deinit();
    try cookie_req.cookie("theme", "dark");
    try cookie_req.apiKeyCookie("session", "cookie-secret");
    var cookie_response = try cookie_req.send(&app);
    defer cookie_response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, cookie_response.status);
    try testing.expectEqualStrings("{\"token\":\"cookie-secret\"}", cookie_response.body.items);

    var missing = try app.handle(Request.init(.GET, "/header"));
    defer missing.deinit(testing.allocator);
    try testing.expectEqual(Status.unauthorized, missing.status);
    try testing.expect(missing.header("www-authenticate") == null);
    try testing.expectEqualStrings("{\"detail\":\"Unauthorized\"}", missing.body.items);
}

test "test client sets default auth helpers" {
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    try app.route(Route.get("/bearer", secureMe, .{}));
    try app.route(Route.get("/basic", secureBasic, .{}));
    try app.route(Route.get("/header", secureHeaderKey, .{}));
    try app.route(Route.get("/cookie", secureCookieKey, .{}));

    var client = TestClient.init(testing.allocator, &app, .{});
    defer client.deinit();

    try client.bearerAuth("client-token");
    var bearer = try client.get("/bearer");
    defer bearer.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, bearer.status);
    try testing.expectEqualStrings("{\"token\":\"client-token\"}", bearer.body.items);

    var override_req = client.request(.GET, "/bearer");
    defer override_req.deinit();
    try override_req.bearerAuth("request-token");
    var override = try client.send(&override_req);
    defer override.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, override.status);
    try testing.expectEqualStrings("{\"token\":\"request-token\"}", override.body.items);

    try client.basicAuth("ada", "secret");
    var basic = try client.get("/basic");
    defer basic.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, basic.status);
    try testing.expectEqualStrings("{\"username\":\"ada\",\"password\":\"secret\"}", basic.body.items);

    try client.apiKeyHeader("x-api-key", "header-secret");
    var header = try client.get("/header");
    defer header.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, header.status);
    try testing.expectEqualStrings("{\"token\":\"header-secret\"}", header.body.items);

    try client.apiKeyCookie("session", "cookie-secret");
    var cookie_response = try client.get("/cookie");
    defer cookie_response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, cookie_response.status);
    try testing.expectEqualStrings("{\"token\":\"cookie-secret\"}", cookie_response.body.items);
}

test "openapi snapshot includes path query and header parameters" {
    var app = ZAPI.init(testing.allocator, .{ .title = "Param API", .version = "1.0.0" });
    defer app.deinit();
    try app.route(Route.get("/users/{id}", userWithHeaders, .{
        .name = "user_with_headers",
        .summary = "Get user with headers",
        .tags = &.{"users"},
    }));

    var openapi = try app.handle(Request.init(.GET, "/openapi.json"));
    defer openapi.deinit(testing.allocator);

    try expectJsonEqual(
        \\{
        \\  "openapi": "3.1.0",
        \\  "info": {
        \\    "title": "Param API",
        \\    "version": "1.0.0"
        \\  },
        \\  "paths": {
        \\    "/users/{id}": {
        \\      "get": {
        \\        "operationId": "user_with_headers",
        \\        "summary": "Get user with headers",
        \\        "tags": ["users"],
        \\        "parameters": [
        \\          {"name": "id", "in": "path", "required": true, "schema": {"type": "integer"}},
        \\          {"name": "verbose", "in": "query", "required": false, "schema": {"anyOf": [{"type": "boolean"}, {"type": "null"}], "default": null}},
        \\          {"name": "x-token", "in": "header", "required": true, "schema": {"type": "string"}}
        \\        ],
        \\        "responses": {
        \\          "200": {
        \\            "description": "OK",
        \\            "content": {
        \\              "application/json": {
        \\                "schema": {"$ref": "#/components/schemas/TestUser"}
        \\              }
        \\            }
        \\          },
        \\          "422": {
        \\            "description": "Validation Error",
        \\            "content": {
        \\              "application/json": {
        \\                "schema": {"$ref": "#/components/schemas/ProblemDetail"}
        \\              }
        \\            }
        \\          }
        \\        }
        \\      }
        \\    }
        \\  },
        \\  "components": {
        \\    "schemas": {
        \\      "ProblemDetail": {
        \\        "type": "object",
        \\        "properties": {
        \\          "detail": {"type": "string"}
        \\        },
        \\        "required": ["detail"],
        \\        "additionalProperties": false
        \\      },
        \\      "TestUser": {
        \\        "type": "object",
        \\        "properties": {
        \\          "id": {"type": "integer"},
        \\          "email": {"type": "string"}
        \\        },
        \\        "required": ["id", "email"],
        \\        "additionalProperties": false
        \\      }
        \\    }
        \\  }
        \\}
    ,
        openapi.body.items,
    );
}

test "openapi snapshot includes documented parameters" {
    var app = ZAPI.init(testing.allocator, .{ .title = "Documented Param API", .version = "1.0.0" });
    defer app.deinit();
    try app.route(Route.get("/users/{id}", userWithHeaders, .{
        .name = "documented_user_params",
        .summary = "Documented user params",
        .parameter_docs = &[_]OpenApiParameterDoc{
            .{
                .name = "id",
                .location = .path,
                .description = "User id",
            },
            .{
                .name = "verbose",
                .location = .query,
                .description = "Include verbose output",
                .deprecated = true,
            },
            .{
                .name = "x-token",
                .location = .header,
                .description = "Caller token",
            },
        },
    }));
    try app.route(Route.get("/sessions/{id}", userWithCookies, .{
        .name = "documented_cookie_params",
        .summary = "Documented cookie params",
        .parameter_docs = &[_]OpenApiParameterDoc{
            .{
                .name = "id",
                .location = .path,
                .description = "Session user id",
            },
            .{
                .name = "session_id",
                .location = .cookie,
                .description = "Session cookie id",
            },
        },
    }));

    var openapi = try app.handle(Request.init(.GET, "/openapi.json"));
    defer openapi.deinit(testing.allocator);

    try expectJsonEqual(
        \\{
        \\  "openapi": "3.1.0",
        \\  "info": {
        \\    "title": "Documented Param API",
        \\    "version": "1.0.0"
        \\  },
        \\  "paths": {
        \\    "/users/{id}": {
        \\      "get": {
        \\        "operationId": "documented_user_params",
        \\        "summary": "Documented user params",
        \\        "parameters": [
        \\          {"name": "id", "in": "path", "description": "User id", "required": true, "schema": {"type": "integer"}},
        \\          {"name": "verbose", "in": "query", "description": "Include verbose output", "deprecated": true, "required": false, "schema": {"anyOf": [{"type": "boolean"}, {"type": "null"}], "default": null}},
        \\          {"name": "x-token", "in": "header", "description": "Caller token", "required": true, "schema": {"type": "string"}}
        \\        ],
        \\        "responses": {
        \\          "200": {
        \\            "description": "OK",
        \\            "content": {
        \\              "application/json": {
        \\                "schema": {"$ref": "#/components/schemas/TestUser"}
        \\              }
        \\            }
        \\          },
        \\          "422": {
        \\            "description": "Validation Error",
        \\            "content": {
        \\              "application/json": {
        \\                "schema": {"$ref": "#/components/schemas/ProblemDetail"}
        \\              }
        \\            }
        \\          }
        \\        }
        \\      }
        \\    },
        \\    "/sessions/{id}": {
        \\      "get": {
        \\        "operationId": "documented_cookie_params",
        \\        "summary": "Documented cookie params",
        \\        "parameters": [
        \\          {"name": "id", "in": "path", "description": "Session user id", "required": true, "schema": {"type": "integer"}},
        \\          {"name": "session_id", "in": "cookie", "description": "Session cookie id", "required": true, "schema": {"type": "string"}}
        \\        ],
        \\        "responses": {
        \\          "200": {
        \\            "description": "OK",
        \\            "content": {
        \\              "application/json": {
        \\                "schema": {"$ref": "#/components/schemas/TestUser"}
        \\              }
        \\            }
        \\          },
        \\          "422": {
        \\            "description": "Validation Error",
        \\            "content": {
        \\              "application/json": {
        \\                "schema": {"$ref": "#/components/schemas/ProblemDetail"}
        \\              }
        \\            }
        \\          }
        \\        }
        \\      }
        \\    }
        \\  },
        \\  "components": {
        \\    "schemas": {
        \\      "ProblemDetail": {
        \\        "type": "object",
        \\        "properties": {
        \\          "detail": {"type": "string"}
        \\        },
        \\        "required": ["detail"],
        \\        "additionalProperties": false
        \\      },
        \\      "TestUser": {
        \\        "type": "object",
        \\        "properties": {
        \\          "id": {"type": "integer"},
        \\          "email": {"type": "string"}
        \\        },
        \\        "required": ["id", "email"],
        \\        "additionalProperties": false
        \\      }
        \\    }
        \\  }
        \\}
    ,
        openapi.body.items,
    );
}

test "openapi snapshot includes parameter aliases" {
    var app = ZAPI.init(testing.allocator, .{ .title = "Alias Param API", .version = "1.0.0" });
    defer app.deinit();
    try app.route(Route.get("/aliases", echoAliasParams, .{
        .name = "alias_params",
        .summary = "Alias params",
        .parameter_docs = &[_]OpenApiParameterDoc{
            .{
                .name = "page_size",
                .location = .query,
                .alias = "page-size",
                .description = "Page size",
                .example_json = "25",
            },
            .{
                .name = "api_key",
                .location = .header,
                .alias = "x-api-key",
                .description = "API key",
                .example_json = "\"secret\"",
            },
            .{
                .name = "session_id",
                .location = .cookie,
                .alias = "session-id",
                .description = "Session cookie",
                .example_json = "\"abc123\"",
            },
        },
    }));

    var openapi = try app.handle(Request.init(.GET, "/openapi.json"));
    defer openapi.deinit(testing.allocator);

    try expectJsonEqual(
        \\{
        \\  "openapi": "3.1.0",
        \\  "info": {
        \\    "title": "Alias Param API",
        \\    "version": "1.0.0"
        \\  },
        \\  "paths": {
        \\    "/aliases": {
        \\      "get": {
        \\        "operationId": "alias_params",
        \\        "summary": "Alias params",
        \\        "parameters": [
        \\          {"name": "page-size", "in": "query", "description": "Page size", "example": 25, "required": true, "schema": {"type": "integer"}},
        \\          {"name": "x-api-key", "in": "header", "description": "API key", "example": "secret", "required": true, "schema": {"type": "string"}},
        \\          {"name": "session-id", "in": "cookie", "description": "Session cookie", "example": "abc123", "required": true, "schema": {"type": "string"}}
        \\        ],
        \\        "responses": {
        \\          "200": {
        \\            "description": "OK",
        \\            "content": {
        \\              "application/json": {
        \\                "schema": {"$ref": "#/components/schemas/AliasParamsEcho"}
        \\              }
        \\            }
        \\          },
        \\          "422": {
        \\            "description": "Validation Error",
        \\            "content": {
        \\              "application/json": {
        \\                "schema": {"$ref": "#/components/schemas/ProblemDetail"}
        \\              }
        \\            }
        \\          }
        \\        }
        \\      }
        \\    }
        \\  },
        \\  "components": {
        \\    "schemas": {
        \\      "AliasParamsEcho": {
        \\        "type": "object",
        \\        "properties": {
        \\          "page_size": {"type": "integer"},
        \\          "token": {"type": "string"},
        \\          "session": {"type": "string"}
        \\        },
        \\        "required": ["page_size", "token", "session"],
        \\        "additionalProperties": false
        \\      },
        \\      "ProblemDetail": {
        \\        "type": "object",
        \\        "properties": {
        \\          "detail": {"type": "string"}
        \\        },
        \\        "required": ["detail"],
        \\        "additionalProperties": false
        \\      }
        \\    }
        \\  }
        \\}
    ,
        openapi.body.items,
    );
}

test "openapi snapshot includes array query parameters" {
    var app = ZAPI.init(testing.allocator, .{ .title = "Array Query API", .version = "1.0.0" });
    defer app.deinit();
    try app.route(Route.get("/tags", searchTags, .{
        .name = "search_tags",
        .summary = "Search tags",
    }));

    var openapi = try app.handle(Request.init(.GET, "/openapi.json"));
    defer openapi.deinit(testing.allocator);

    try expectJsonEqual(
        \\{
        \\  "openapi": "3.1.0",
        \\  "info": {
        \\    "title": "Array Query API",
        \\    "version": "1.0.0"
        \\  },
        \\  "paths": {
        \\    "/tags": {
        \\      "get": {
        \\        "operationId": "search_tags",
        \\        "summary": "Search tags",
        \\        "parameters": [
        \\          {"name": "tag", "in": "query", "required": true, "schema": {"type": "array", "items": {"type": "string"}}},
        \\          {"name": "limit", "in": "query", "required": false, "schema": {"type": "array", "items": {"type": "integer"}, "default": [10]}}
        \\        ],
        \\        "responses": {
        \\          "200": {
        \\            "description": "OK",
        \\            "content": {
        \\              "application/json": {
        \\                "schema": {"$ref": "#/components/schemas/TagSearchResult"}
        \\              }
        \\            }
        \\          },
        \\          "422": {
        \\            "description": "Validation Error",
        \\            "content": {
        \\              "application/json": {
        \\                "schema": {"$ref": "#/components/schemas/ProblemDetail"}
        \\              }
        \\            }
        \\          }
        \\        }
        \\      }
        \\    }
        \\  },
        \\  "components": {
        \\    "schemas": {
        \\      "ProblemDetail": {
        \\        "type": "object",
        \\        "properties": {
        \\          "detail": {"type": "string"}
        \\        },
        \\        "required": ["detail"],
        \\        "additionalProperties": false
        \\      },
        \\      "TagSearchResult": {
        \\        "type": "object",
        \\        "properties": {
        \\          "tags": {"type": "array", "items": {"type": "string"}},
        \\          "limits": {"type": "array", "items": {"type": "integer"}}
        \\        },
        \\        "required": ["tags", "limits"],
        \\        "additionalProperties": false
        \\      }
        \\    }
        \\  }
        \\}
    ,
        openapi.body.items,
    );
}

test "openapi snapshot includes array header parameters" {
    var app = ZAPI.init(testing.allocator, .{ .title = "Array Header API", .version = "1.0.0" });
    defer app.deinit();
    try app.route(Route.get("/header-list", echoHeaderList, .{
        .name = "header_list",
        .summary = "Header list",
    }));

    var openapi = try app.handle(Request.init(.GET, "/openapi.json"));
    defer openapi.deinit(testing.allocator);

    try expectJsonEqual(
        \\{
        \\  "openapi": "3.1.0",
        \\  "info": {
        \\    "title": "Array Header API",
        \\    "version": "1.0.0"
        \\  },
        \\  "paths": {
        \\    "/header-list": {
        \\      "get": {
        \\        "operationId": "header_list",
        \\        "summary": "Header list",
        \\        "parameters": [
        \\          {"name": "x-token", "in": "header", "required": true, "schema": {"type": "array", "items": {"type": "string"}}}
        \\        ],
        \\        "responses": {
        \\          "200": {
        \\            "description": "OK",
        \\            "content": {
        \\              "application/json": {
        \\                "schema": {"$ref": "#/components/schemas/HeaderListEcho"}
        \\              }
        \\            }
        \\          },
        \\          "422": {
        \\            "description": "Validation Error",
        \\            "content": {
        \\              "application/json": {
        \\                "schema": {"$ref": "#/components/schemas/ProblemDetail"}
        \\              }
        \\            }
        \\          }
        \\        }
        \\      }
        \\    }
        \\  },
        \\  "components": {
        \\    "schemas": {
        \\      "ProblemDetail": {
        \\        "type": "object",
        \\        "properties": {
        \\          "detail": {"type": "string"}
        \\        },
        \\        "required": ["detail"],
        \\        "additionalProperties": false
        \\      },
        \\      "HeaderListEcho": {
        \\        "type": "object",
        \\        "properties": {
        \\          "tokens": {"type": "array", "items": {"type": "string"}}
        \\        },
        \\        "required": ["tokens"],
        \\        "additionalProperties": false
        \\      }
        \\    }
        \\  }
        \\}
    ,
        openapi.body.items,
    );
}

test "openapi snapshot includes uuid parameter and body schemas" {
    var app = ZAPI.init(testing.allocator, .{ .title = "UUID API", .version = "1.0.0" });
    defer app.deinit();
    try app.route(Route.get("/widgets/{id:uuid}", echoUuid, .{
        .name = "get_uuid",
        .summary = "Get UUID",
    }));
    try app.route(Route.post("/uuids", createUuid, .{
        .name = "create_uuid",
        .summary = "Create UUID",
    }));

    var openapi = try app.handle(Request.init(.GET, "/openapi.json"));
    defer openapi.deinit(testing.allocator);

    try expectJsonEqual(
        \\{
        \\  "openapi": "3.1.0",
        \\  "info": {
        \\    "title": "UUID API",
        \\    "version": "1.0.0"
        \\  },
        \\  "paths": {
        \\    "/widgets/{id}": {
        \\      "get": {
        \\        "operationId": "get_uuid",
        \\        "summary": "Get UUID",
        \\        "parameters": [
        \\          {"name": "id", "in": "path", "required": true, "schema": {"type": "string", "format": "uuid"}},
        \\          {"name": "trace_id", "in": "query", "required": false, "schema": {"anyOf": [{"type": "string", "format": "uuid"}, {"type": "null"}], "default": null}}
        \\        ],
        \\        "responses": {
        \\          "200": {
        \\            "description": "OK",
        \\            "content": {
        \\              "application/json": {
        \\                "schema": {"$ref": "#/components/schemas/UuidEcho"}
        \\              }
        \\            }
        \\          },
        \\          "422": {
        \\            "description": "Validation Error",
        \\            "content": {
        \\              "application/json": {
        \\                "schema": {"$ref": "#/components/schemas/ProblemDetail"}
        \\              }
        \\            }
        \\          }
        \\        }
        \\      }
        \\    },
        \\    "/uuids": {
        \\      "post": {
        \\        "operationId": "create_uuid",
        \\        "summary": "Create UUID",
        \\        "requestBody": {
        \\          "required": true,
        \\          "content": {
        \\            "application/json": {
        \\              "schema": {"$ref": "#/components/schemas/UuidBody"}
        \\            }
        \\          }
        \\        },
        \\        "responses": {
        \\          "200": {
        \\            "description": "OK",
        \\            "content": {
        \\              "application/json": {
        \\                "schema": {"$ref": "#/components/schemas/UuidEcho"}
        \\              }
        \\            }
        \\          },
        \\          "422": {
        \\            "description": "Validation Error",
        \\            "content": {
        \\              "application/json": {
        \\                "schema": {"$ref": "#/components/schemas/ProblemDetail"}
        \\              }
        \\            }
        \\          }
        \\        }
        \\      }
        \\    }
        \\  },
        \\  "components": {
        \\    "schemas": {
        \\      "ProblemDetail": {
        \\        "type": "object",
        \\        "properties": {
        \\          "detail": {"type": "string"}
        \\        },
        \\        "required": ["detail"],
        \\        "additionalProperties": false
        \\      },
        \\      "UuidEcho": {
        \\        "type": "object",
        \\        "properties": {
        \\          "id": {"type": "string", "format": "uuid"}
        \\        },
        \\        "required": ["id"],
        \\        "additionalProperties": false
        \\      },
        \\      "UuidBody": {
        \\        "type": "object",
        \\        "properties": {
        \\          "id": {"type": "string", "format": "uuid"}
        \\        },
        \\        "required": ["id"],
        \\        "additionalProperties": false
        \\      }
        \\    }
        \\  }
        \\}
    ,
        openapi.body.items,
    );
}

test "openapi snapshot includes date and datetime schemas" {
    var app = ZAPI.init(testing.allocator, .{ .title = "Date API", .version = "1.0.0" });
    defer app.deinit();
    try app.route(Route.get("/dates", echoDate, .{
        .name = "get_dates",
        .summary = "Get dates",
    }));
    try app.route(Route.post("/dates", createDate, .{
        .name = "create_dates",
        .summary = "Create dates",
    }));

    var openapi = try app.handle(Request.init(.GET, "/openapi.json"));
    defer openapi.deinit(testing.allocator);

    try expectJsonEqual(
        \\{
        \\  "openapi": "3.1.0",
        \\  "info": {
        \\    "title": "Date API",
        \\    "version": "1.0.0"
        \\  },
        \\  "paths": {
        \\    "/dates": {
        \\      "get": {
        \\        "operationId": "get_dates",
        \\        "summary": "Get dates",
        \\        "parameters": [
        \\          {"name": "date", "in": "query", "required": true, "schema": {"type": "string", "format": "date"}},
        \\          {"name": "timestamp", "in": "query", "required": true, "schema": {"type": "string", "format": "date-time"}}
        \\        ],
        \\        "responses": {
        \\          "200": {
        \\            "description": "OK",
        \\            "content": {
        \\              "application/json": {
        \\                "schema": {"$ref": "#/components/schemas/DateEcho"}
        \\              }
        \\            }
        \\          },
        \\          "422": {
        \\            "description": "Validation Error",
        \\            "content": {
        \\              "application/json": {
        \\                "schema": {"$ref": "#/components/schemas/ProblemDetail"}
        \\              }
        \\            }
        \\          }
        \\        }
        \\      },
        \\      "post": {
        \\        "operationId": "create_dates",
        \\        "summary": "Create dates",
        \\        "requestBody": {
        \\          "required": true,
        \\          "content": {
        \\            "application/json": {
        \\              "schema": {"$ref": "#/components/schemas/DateBody"}
        \\            }
        \\          }
        \\        },
        \\        "responses": {
        \\          "200": {
        \\            "description": "OK",
        \\            "content": {
        \\              "application/json": {
        \\                "schema": {"$ref": "#/components/schemas/DateEcho"}
        \\              }
        \\            }
        \\          },
        \\          "422": {
        \\            "description": "Validation Error",
        \\            "content": {
        \\              "application/json": {
        \\                "schema": {"$ref": "#/components/schemas/ProblemDetail"}
        \\              }
        \\            }
        \\          }
        \\        }
        \\      }
        \\    }
        \\  },
        \\  "components": {
        \\    "schemas": {
        \\      "ProblemDetail": {
        \\        "type": "object",
        \\        "properties": {
        \\          "detail": {"type": "string"}
        \\        },
        \\        "required": ["detail"],
        \\        "additionalProperties": false
        \\      },
        \\      "DateEcho": {
        \\        "type": "object",
        \\        "properties": {
        \\          "date": {"type": "string", "format": "date"},
        \\          "timestamp": {"type": "string", "format": "date-time"}
        \\        },
        \\        "required": ["date", "timestamp"],
        \\        "additionalProperties": false
        \\      },
        \\      "DateBody": {
        \\        "type": "object",
        \\        "properties": {
        \\          "date": {"type": "string", "format": "date"},
        \\          "timestamp": {"type": "string", "format": "date-time"}
        \\        },
        \\        "required": ["date", "timestamp"],
        \\        "additionalProperties": false
        \\      }
        \\    }
        \\  }
        \\}
    ,
        openapi.body.items,
    );
}

test "openapi snapshot includes email schemas" {
    var app = ZAPI.init(testing.allocator, .{ .title = "Email API", .version = "1.0.0" });
    defer app.deinit();
    try app.route(Route.get("/emails", echoEmail, .{
        .name = "get_email",
        .summary = "Get email",
    }));
    try app.route(Route.post("/emails", createEmail, .{
        .name = "create_email",
        .summary = "Create email",
    }));

    var openapi = try app.handle(Request.init(.GET, "/openapi.json"));
    defer openapi.deinit(testing.allocator);

    try expectJsonEqual(
        \\{
        \\  "openapi": "3.1.0",
        \\  "info": {
        \\    "title": "Email API",
        \\    "version": "1.0.0"
        \\  },
        \\  "paths": {
        \\    "/emails": {
        \\      "get": {
        \\        "operationId": "get_email",
        \\        "summary": "Get email",
        \\        "parameters": [
        \\          {"name": "email", "in": "query", "required": true, "schema": {"type": "string", "format": "email"}}
        \\        ],
        \\        "responses": {
        \\          "200": {
        \\            "description": "OK",
        \\            "content": {
        \\              "application/json": {
        \\                "schema": {"$ref": "#/components/schemas/EmailEcho"}
        \\              }
        \\            }
        \\          },
        \\          "422": {
        \\            "description": "Validation Error",
        \\            "content": {
        \\              "application/json": {
        \\                "schema": {"$ref": "#/components/schemas/ProblemDetail"}
        \\              }
        \\            }
        \\          }
        \\        }
        \\      },
        \\      "post": {
        \\        "operationId": "create_email",
        \\        "summary": "Create email",
        \\        "requestBody": {
        \\          "required": true,
        \\          "content": {
        \\            "application/json": {
        \\              "schema": {"$ref": "#/components/schemas/EmailBody"}
        \\            }
        \\          }
        \\        },
        \\        "responses": {
        \\          "200": {
        \\            "description": "OK",
        \\            "content": {
        \\              "application/json": {
        \\                "schema": {"$ref": "#/components/schemas/EmailEcho"}
        \\              }
        \\            }
        \\          },
        \\          "422": {
        \\            "description": "Validation Error",
        \\            "content": {
        \\              "application/json": {
        \\                "schema": {"$ref": "#/components/schemas/ProblemDetail"}
        \\              }
        \\            }
        \\          }
        \\        }
        \\      }
        \\    }
        \\  },
        \\  "components": {
        \\    "schemas": {
        \\      "ProblemDetail": {
        \\        "type": "object",
        \\        "properties": {
        \\          "detail": {"type": "string"}
        \\        },
        \\        "required": ["detail"],
        \\        "additionalProperties": false
        \\      },
        \\      "EmailEcho": {
        \\        "type": "object",
        \\        "properties": {
        \\          "email": {"type": "string", "format": "email"}
        \\        },
        \\        "required": ["email"],
        \\        "additionalProperties": false
        \\      },
        \\      "EmailBody": {
        \\        "type": "object",
        \\        "properties": {
        \\          "email": {"type": "string", "format": "email"}
        \\        },
        \\        "required": ["email"],
        \\        "additionalProperties": false
        \\      }
        \\    }
        \\  }
        \\}
    ,
        openapi.body.items,
    );
}

test "openapi snapshot includes url schemas" {
    var app = ZAPI.init(testing.allocator, .{ .title = "URL API", .version = "1.0.0" });
    defer app.deinit();
    try app.route(Route.get("/urls", echoUrlScalar, .{
        .name = "get_url",
        .summary = "Get URL",
    }));
    try app.route(Route.post("/urls", createUrlScalar, .{
        .name = "create_url",
        .summary = "Create URL",
    }));

    var openapi = try app.handle(Request.init(.GET, "/openapi.json"));
    defer openapi.deinit(testing.allocator);

    try expectJsonEqual(
        \\{
        \\  "openapi": "3.1.0",
        \\  "info": {
        \\    "title": "URL API",
        \\    "version": "1.0.0"
        \\  },
        \\  "paths": {
        \\    "/urls": {
        \\      "get": {
        \\        "operationId": "get_url",
        \\        "summary": "Get URL",
        \\        "parameters": [
        \\          {"name": "url", "in": "query", "required": true, "schema": {"type": "string", "format": "uri"}}
        \\        ],
        \\        "responses": {
        \\          "200": {
        \\            "description": "OK",
        \\            "content": {
        \\              "application/json": {
        \\                "schema": {"$ref": "#/components/schemas/UrlScalarEcho"}
        \\              }
        \\            }
        \\          },
        \\          "422": {
        \\            "description": "Validation Error",
        \\            "content": {
        \\              "application/json": {
        \\                "schema": {"$ref": "#/components/schemas/ProblemDetail"}
        \\              }
        \\            }
        \\          }
        \\        }
        \\      },
        \\      "post": {
        \\        "operationId": "create_url",
        \\        "summary": "Create URL",
        \\        "requestBody": {
        \\          "required": true,
        \\          "content": {
        \\            "application/json": {
        \\              "schema": {"$ref": "#/components/schemas/UrlBody"}
        \\            }
        \\          }
        \\        },
        \\        "responses": {
        \\          "200": {
        \\            "description": "OK",
        \\            "content": {
        \\              "application/json": {
        \\                "schema": {"$ref": "#/components/schemas/UrlScalarEcho"}
        \\              }
        \\            }
        \\          },
        \\          "422": {
        \\            "description": "Validation Error",
        \\            "content": {
        \\              "application/json": {
        \\                "schema": {"$ref": "#/components/schemas/ProblemDetail"}
        \\              }
        \\            }
        \\          }
        \\        }
        \\      }
        \\    }
        \\  },
        \\  "components": {
        \\    "schemas": {
        \\      "ProblemDetail": {
        \\        "type": "object",
        \\        "properties": {
        \\          "detail": {"type": "string"}
        \\        },
        \\        "required": ["detail"],
        \\        "additionalProperties": false
        \\      },
        \\      "UrlScalarEcho": {
        \\        "type": "object",
        \\        "properties": {
        \\          "url": {"type": "string", "format": "uri"}
        \\        },
        \\        "required": ["url"],
        \\        "additionalProperties": false
        \\      },
        \\      "UrlBody": {
        \\        "type": "object",
        \\        "properties": {
        \\          "url": {"type": "string", "format": "uri"}
        \\        },
        \\        "required": ["url"],
        \\        "additionalProperties": false
        \\      }
        \\    }
        \\  }
        \\}
    ,
        openapi.body.items,
    );
}

test "openapi snapshot includes enum parameters and schemas" {
    var app = ZAPI.init(testing.allocator, .{ .title = "Enum API", .version = "1.0.0" });
    defer app.deinit();
    try app.route(Route.get("/states", echoQueryState, .{
        .name = "query_state",
        .summary = "Query state",
        .tags = &.{"states"},
    }));
    try app.route(Route.get("/states/{state}", echoPathState, .{
        .name = "state_detail",
        .summary = "State detail",
        .tags = &.{"states"},
    }));

    var openapi = try app.handle(Request.init(.GET, "/openapi.json"));
    defer openapi.deinit(testing.allocator);

    try expectJsonEqual(
        \\{
        \\  "openapi": "3.1.0",
        \\  "info": {
        \\    "title": "Enum API",
        \\    "version": "1.0.0"
        \\  },
        \\  "paths": {
        \\    "/states": {
        \\      "get": {
        \\        "operationId": "query_state",
        \\        "summary": "Query state",
        \\        "tags": ["states"],
        \\        "parameters": [
        \\          {"name": "state", "in": "query", "required": true, "schema": {"type": "string", "enum": ["active", "disabled"]}}
        \\        ],
        \\        "responses": {
        \\          "200": {
        \\            "description": "OK",
        \\            "content": {
        \\              "application/json": {
        \\                "schema": {"$ref": "#/components/schemas/StateEcho"}
        \\              }
        \\            }
        \\          },
        \\          "422": {
        \\            "description": "Validation Error",
        \\            "content": {
        \\              "application/json": {
        \\                "schema": {"$ref": "#/components/schemas/ProblemDetail"}
        \\              }
        \\            }
        \\          }
        \\        }
        \\      }
        \\    },
        \\    "/states/{state}": {
        \\      "get": {
        \\        "operationId": "state_detail",
        \\        "summary": "State detail",
        \\        "tags": ["states"],
        \\        "parameters": [
        \\          {"name": "state", "in": "path", "required": true, "schema": {"type": "string", "enum": ["active", "disabled"]}}
        \\        ],
        \\        "responses": {
        \\          "200": {
        \\            "description": "OK",
        \\            "content": {
        \\              "application/json": {
        \\                "schema": {"$ref": "#/components/schemas/StateEcho"}
        \\              }
        \\            }
        \\          },
        \\          "422": {
        \\            "description": "Validation Error",
        \\            "content": {
        \\              "application/json": {
        \\                "schema": {"$ref": "#/components/schemas/ProblemDetail"}
        \\              }
        \\            }
        \\          }
        \\        }
        \\      }
        \\    }
        \\  },
        \\  "components": {
        \\    "schemas": {
        \\      "ProblemDetail": {
        \\        "type": "object",
        \\        "properties": {
        \\          "detail": {"type": "string"}
        \\        },
        \\        "required": ["detail"],
        \\        "additionalProperties": false
        \\      },
        \\      "StateEcho": {
        \\        "type": "object",
        \\        "properties": {
        \\          "state": {"type": "string", "enum": ["active", "disabled"]}
        \\        },
        \\        "required": ["state"],
        \\        "additionalProperties": false
        \\      }
        \\    }
        \\  }
        \\}
    ,
        openapi.body.items,
    );
}

test "openapi snapshot groups multiple methods under one path" {
    var app = ZAPI.init(testing.allocator, .{ .title = "Grouped API", .version = "1.0.0" });
    defer app.deinit();
    try app.route(Route.get("/users", listUsers, .{
        .name = "list_users",
        .summary = "List users",
        .tags = &.{"users"},
    }));
    try app.route(Route.post("/users", createUser, .{
        .name = "create_user",
        .summary = "Create user",
        .status = .created,
        .tags = &.{"users"},
    }));
    try app.route(Route.options("/users", plainText, .{
        .name = "users_options",
        .summary = "Users options",
        .tags = &.{"users"},
    }));
    try app.route(Route.head("/users", explicitHead, .{
        .name = "users_head",
        .summary = "Users head",
        .status = .accepted,
        .tags = &.{"users"},
    }));

    var openapi = try app.handle(Request.init(.GET, "/openapi.json"));
    defer openapi.deinit(testing.allocator);

    try expectJsonEqual(
        \\{
        \\  "openapi": "3.1.0",
        \\  "info": {
        \\    "title": "Grouped API",
        \\    "version": "1.0.0"
        \\  },
        \\  "paths": {
        \\    "/users": {
        \\      "get": {
        \\        "operationId": "list_users",
        \\        "summary": "List users",
        \\        "tags": ["users"],
        \\        "responses": {
        \\          "200": {
        \\            "description": "OK",
        \\            "content": {
        \\              "application/json": {
        \\                "schema": {"$ref": "#/components/schemas/UserList"}
        \\              }
        \\            }
        \\          }
        \\        }
        \\      },
        \\      "post": {
        \\        "operationId": "create_user",
        \\        "summary": "Create user",
        \\        "tags": ["users"],
        \\        "requestBody": {
        \\          "required": true,
        \\          "content": {
        \\            "application/json": {
        \\              "schema": {"$ref": "#/components/schemas/CreateUser"}
        \\            }
        \\          }
        \\        },
        \\        "responses": {
        \\          "201": {
        \\            "description": "Created",
        \\            "content": {
        \\              "application/json": {
        \\                "schema": {"$ref": "#/components/schemas/TestUser"}
        \\              }
        \\            }
        \\          },
        \\          "422": {
        \\            "description": "Validation Error",
        \\            "content": {
        \\              "application/json": {
        \\                "schema": {"$ref": "#/components/schemas/ProblemDetail"}
        \\              }
        \\            }
        \\          }
        \\        }
        \\      },
        \\      "options": {
        \\        "operationId": "users_options",
        \\        "summary": "Users options",
        \\        "tags": ["users"],
        \\        "responses": {
        \\          "200": {
        \\            "description": "OK",
        \\            "content": {
        \\              "text/plain; charset=utf-8": {
        \\                "schema": {"type": "string"}
        \\              }
        \\            }
        \\          }
        \\        }
        \\      },
        \\      "head": {
        \\        "operationId": "users_head",
        \\        "summary": "Users head",
        \\        "tags": ["users"],
        \\        "responses": {
        \\          "202": {
        \\            "description": "Accepted",
        \\            "content": {
        \\              "text/plain; charset=utf-8": {
        \\                "schema": {"type": "string"}
        \\              }
        \\            }
        \\          }
        \\        }
        \\      }
        \\    }
        \\  },
        \\  "components": {
        \\    "schemas": {
        \\      "ProblemDetail": {
        \\        "type": "object",
        \\        "properties": {
        \\          "detail": {"type": "string"}
        \\        },
        \\        "required": ["detail"],
        \\        "additionalProperties": false
        \\      },
        \\      "UserList": {
        \\        "type": "object",
        \\        "properties": {
        \\          "users": {
        \\            "type": "array",
        \\            "items": {
        \\              "type": "object",
        \\              "properties": {
        \\                "id": {"type": "integer"},
        \\                "email": {"type": "string"}
        \\              },
        \\              "required": ["id", "email"],
        \\              "additionalProperties": false
        \\            }
        \\          }
        \\        },
        \\        "required": ["users"],
        \\        "additionalProperties": false
        \\      },
        \\      "CreateUser": {
        \\        "type": "object",
        \\        "properties": {
        \\          "email": {"type": "string"}
        \\        },
        \\        "required": ["email"],
        \\        "additionalProperties": false
        \\      },
        \\      "TestUser": {
        \\        "type": "object",
        \\        "properties": {
        \\          "id": {"type": "integer"},
        \\          "email": {"type": "string"}
        \\        },
        \\        "required": ["id", "email"],
        \\        "additionalProperties": false
        \\      }
        \\    }
        \\  }
        \\}
    ,
        openapi.body.items,
    );
}

test "openapi snapshot normalizes typed path convertors" {
    var app = ZAPI.init(testing.allocator, .{ .title = "Convertor API", .version = "1.0.0" });
    defer app.deinit();
    try app.addPathConvertor("slug", slugMatches);
    try app.route(Route.get("/items/{id:int}", getUser, .{
        .name = "item_detail",
        .summary = "Get item",
        .tags = &.{"items"},
    }));
    try app.route(Route.get("/posts/{slug:slug}", getSlug, .{
        .name = "post_detail",
        .summary = "Get post",
        .tags = &.{"posts"},
    }));

    var openapi = try app.handle(Request.init(.GET, "/openapi.json"));
    defer openapi.deinit(testing.allocator);

    try expectJsonEqual(
        \\{
        \\  "openapi": "3.1.0",
        \\  "info": {
        \\    "title": "Convertor API",
        \\    "version": "1.0.0"
        \\  },
        \\  "paths": {
        \\    "/items/{id}": {
        \\      "get": {
        \\        "operationId": "item_detail",
        \\        "summary": "Get item",
        \\        "tags": ["items"],
        \\        "parameters": [
        \\          {"name": "id", "in": "path", "required": true, "schema": {"type": "integer"}},
        \\          {"name": "verbose", "in": "query", "required": false, "schema": {"anyOf": [{"type": "boolean"}, {"type": "null"}], "default": null}}
        \\        ],
        \\        "responses": {
        \\          "200": {
        \\            "description": "OK",
        \\            "content": {
        \\              "application/json": {
        \\                "schema": {"$ref": "#/components/schemas/TestUser"}
        \\              }
        \\            }
        \\          },
        \\          "422": {
        \\            "description": "Validation Error",
        \\            "content": {
        \\              "application/json": {
        \\                "schema": {"$ref": "#/components/schemas/ProblemDetail"}
        \\              }
        \\            }
        \\          }
        \\        }
        \\      }
        \\    },
        \\    "/posts/{slug}": {
        \\      "get": {
        \\        "operationId": "post_detail",
        \\        "summary": "Get post",
        \\        "tags": ["posts"],
        \\        "parameters": [
        \\          {"name": "slug", "in": "path", "required": true, "schema": {"type": "string"}}
        \\        ],
        \\        "responses": {
        \\          "200": {
        \\            "description": "OK",
        \\            "content": {
        \\              "application/json": {
        \\                "schema": {"$ref": "#/components/schemas/PathEcho"}
        \\              }
        \\            }
        \\          },
        \\          "422": {
        \\            "description": "Validation Error",
        \\            "content": {
        \\              "application/json": {
        \\                "schema": {"$ref": "#/components/schemas/ProblemDetail"}
        \\              }
        \\            }
        \\          }
        \\        }
        \\      }
        \\    }
        \\  },
        \\  "components": {
        \\    "schemas": {
        \\      "ProblemDetail": {
        \\        "type": "object",
        \\        "properties": {
        \\          "detail": {"type": "string"}
        \\        },
        \\        "required": ["detail"],
        \\        "additionalProperties": false
        \\      },
        \\      "TestUser": {
        \\        "type": "object",
        \\        "properties": {
        \\          "id": {"type": "integer"},
        \\          "email": {"type": "string"}
        \\        },
        \\        "required": ["id", "email"],
        \\        "additionalProperties": false
        \\      },
        \\      "PathEcho": {
        \\        "type": "object",
        \\        "properties": {
        \\          "value": {"type": "string"}
        \\        },
        \\        "required": ["value"],
        \\        "additionalProperties": false
        \\      }
        \\    }
        \\  }
        \\}
    ,
        openapi.body.items,
    );
}

test "openapi snapshot includes documented response variants" {
    var app = ZAPI.init(testing.allocator, .{ .title = "Responses API", .version = "1.0.0" });
    defer app.deinit();
    try app.route(Route.get("/users/{id}", getUser, .{
        .name = "get_user",
        .summary = "Get user",
        .tags = &.{"users"},
        .responses = &.{
            responseDoc(.not_found, ErrorMessage, .{ .description = "User not found" }),
            responseDoc(.bad_request, Text, .{ .description = "Plain validation hint" }),
            responseDoc(.conflict, Bytes, .{ .description = "Binary conflict payload" }),
            responseDoc(.no_content, void, .{ .description = "No user content" }),
        },
    }));

    var openapi = try app.handle(Request.init(.GET, "/openapi.json"));
    defer openapi.deinit(testing.allocator);

    try expectJsonEqual(
        \\{
        \\  "openapi": "3.1.0",
        \\  "info": {
        \\    "title": "Responses API",
        \\    "version": "1.0.0"
        \\  },
        \\  "paths": {
        \\    "/users/{id}": {
        \\      "get": {
        \\        "operationId": "get_user",
        \\        "summary": "Get user",
        \\        "tags": ["users"],
        \\        "parameters": [
        \\          {"name": "id", "in": "path", "required": true, "schema": {"type": "integer"}},
        \\          {"name": "verbose", "in": "query", "required": false, "schema": {"anyOf": [{"type": "boolean"}, {"type": "null"}], "default": null}}
        \\        ],
        \\        "responses": {
        \\          "200": {
        \\            "description": "OK",
        \\            "content": {
        \\              "application/json": {
        \\                "schema": {"$ref": "#/components/schemas/TestUser"}
        \\              }
        \\            }
        \\          },
        \\          "404": {
        \\            "description": "User not found",
        \\            "content": {
        \\              "application/json": {
        \\                "schema": {"$ref": "#/components/schemas/ErrorMessage"}
        \\              }
        \\            }
        \\          },
        \\          "400": {
        \\            "description": "Plain validation hint",
        \\            "content": {
        \\              "text/plain; charset=utf-8": {
        \\                "schema": {"type": "string"}
        \\              }
        \\            }
        \\          },
        \\          "409": {
        \\            "description": "Binary conflict payload",
        \\            "content": {
        \\              "application/octet-stream": {
        \\                "schema": {"type": "string", "format": "binary"}
        \\              }
        \\            }
        \\          },
        \\          "204": {
        \\            "description": "No user content"
        \\          },
        \\          "422": {
        \\            "description": "Validation Error",
        \\            "content": {
        \\              "application/json": {
        \\                "schema": {"$ref": "#/components/schemas/ProblemDetail"}
        \\              }
        \\            }
        \\          }
        \\        }
        \\      }
        \\    }
        \\  },
        \\  "components": {
        \\    "schemas": {
        \\      "ProblemDetail": {
        \\        "type": "object",
        \\        "properties": {
        \\          "detail": {"type": "string"}
        \\        },
        \\        "required": ["detail"],
        \\        "additionalProperties": false
        \\      },
        \\      "TestUser": {
        \\        "type": "object",
        \\        "properties": {
        \\          "id": {"type": "integer"},
        \\          "email": {"type": "string"}
        \\        },
        \\        "required": ["id", "email"],
        \\        "additionalProperties": false
        \\      },
        \\      "ErrorMessage": {
        \\        "type": "object",
        \\        "properties": {
        \\          "detail": {"type": "string"}
        \\        },
        \\        "required": ["detail"],
        \\        "additionalProperties": false
        \\      }
        \\    }
        \\  }
        \\}
    ,
        openapi.body.items,
    );
}

test "openapi omits content for no body response statuses" {
    var app = ZAPI.init(testing.allocator, .{ .title = "No Body API", .version = "1.0.0" });
    defer app.deinit();
    try app.route(Route.delete("/users/{id}", noBodyUser, .{
        .status = .no_content,
        .summary = "Delete user",
        .responses = &.{
            responseDoc(.early_hints, TestUser, .{ .description = "Link hints" }),
            responseDoc(.not_modified, Text, .{ .description = "Cached delete result" }),
        },
    }));

    var response = try app.handle(Request.init(.DELETE, "/users/1"));
    defer response.deinit(testing.allocator);
    try testing.expectEqual(Status.no_content, response.status);
    try testing.expect(response.header("content-type") == null);
    try testing.expect(response.header("content-length") == null);
    try testing.expectEqual(@as(usize, 0), response.body.items.len);

    var openapi = try app.handle(Request.init(.GET, "/openapi.json"));
    defer openapi.deinit(testing.allocator);

    try expectJsonEqual(
        \\{
        \\  "openapi": "3.1.0",
        \\  "info": {
        \\    "title": "No Body API",
        \\    "version": "1.0.0"
        \\  },
        \\  "paths": {
        \\    "/users/{id}": {
        \\      "delete": {
        \\        "operationId": "delete_users_id",
        \\        "summary": "Delete user",
        \\        "parameters": [
        \\          {"name": "id", "in": "path", "required": true, "schema": {"type": "integer"}}
        \\        ],
        \\        "responses": {
        \\          "204": {
        \\            "description": "No Content"
        \\          },
        \\          "103": {
        \\            "description": "Link hints"
        \\          },
        \\          "304": {
        \\            "description": "Cached delete result"
        \\          },
        \\          "422": {
        \\            "description": "Validation Error",
        \\            "content": {
        \\              "application/json": {
        \\                "schema": {"$ref": "#/components/schemas/ProblemDetail"}
        \\              }
        \\            }
        \\          }
        \\        }
        \\      }
        \\    }
        \\  },
        \\  "components": {
        \\    "schemas": {
        \\      "ProblemDetail": {
        \\        "type": "object",
        \\        "properties": {
        \\          "detail": {"type": "string"}
        \\        },
        \\        "required": ["detail"],
        \\        "additionalProperties": false
        \\      }
        \\    }
        \\  }
        \\}
    ,
        openapi.body.items,
    );
}

test "openapi snapshot includes documented response headers" {
    var app = ZAPI.init(testing.allocator, .{ .title = "Response Header API", .version = "1.0.0" });
    defer app.deinit();
    try app.route(Route.get("/users/{id}", getUser, .{
        .name = "get_user_headers",
        .summary = "Get user with response headers",
        .response_headers = &[_]OpenApiHeader{
            .{
                .name = "x-request-id",
                .description = "Request correlation id",
                .required = true,
            },
            .{
                .name = "x-ratelimit-remaining",
                .description = "Remaining requests",
                .schema = .integer,
            },
        },
        .responses = &.{
            responseDoc(.too_many_requests, ErrorMessage, .{
                .description = "Rate limited",
                .headers = &[_]OpenApiHeader{
                    .{
                        .name = "retry-after",
                        .description = "Retry delay in seconds",
                        .schema = .integer,
                    },
                    .{
                        .name = "x-old-limit",
                        .description = "Deprecated limit header",
                        .deprecated = true,
                    },
                },
            }),
        },
    }));

    var openapi = try app.handle(Request.init(.GET, "/openapi.json"));
    defer openapi.deinit(testing.allocator);

    try expectJsonEqual(
        \\{
        \\  "openapi": "3.1.0",
        \\  "info": {
        \\    "title": "Response Header API",
        \\    "version": "1.0.0"
        \\  },
        \\  "paths": {
        \\    "/users/{id}": {
        \\      "get": {
        \\        "operationId": "get_user_headers",
        \\        "summary": "Get user with response headers",
        \\        "parameters": [
        \\          {"name": "id", "in": "path", "required": true, "schema": {"type": "integer"}},
        \\          {"name": "verbose", "in": "query", "required": false, "schema": {"anyOf": [{"type": "boolean"}, {"type": "null"}], "default": null}}
        \\        ],
        \\        "responses": {
        \\          "200": {
        \\            "description": "OK",
        \\            "headers": {
        \\              "x-request-id": {
        \\                "description": "Request correlation id",
        \\                "required": true,
        \\                "schema": {"type": "string"}
        \\              },
        \\              "x-ratelimit-remaining": {
        \\                "description": "Remaining requests",
        \\                "schema": {"type": "integer"}
        \\              }
        \\            },
        \\            "content": {
        \\              "application/json": {
        \\                "schema": {"$ref": "#/components/schemas/TestUser"}
        \\              }
        \\            }
        \\          },
        \\          "429": {
        \\            "description": "Rate limited",
        \\            "headers": {
        \\              "retry-after": {
        \\                "description": "Retry delay in seconds",
        \\                "schema": {"type": "integer"}
        \\              },
        \\              "x-old-limit": {
        \\                "description": "Deprecated limit header",
        \\                "deprecated": true,
        \\                "schema": {"type": "string"}
        \\              }
        \\            },
        \\            "content": {
        \\              "application/json": {
        \\                "schema": {"$ref": "#/components/schemas/ErrorMessage"}
        \\              }
        \\            }
        \\          },
        \\          "422": {
        \\            "description": "Validation Error",
        \\            "content": {
        \\              "application/json": {
        \\                "schema": {"$ref": "#/components/schemas/ProblemDetail"}
        \\              }
        \\            }
        \\          }
        \\        }
        \\      }
        \\    }
        \\  },
        \\  "components": {
        \\    "schemas": {
        \\      "ProblemDetail": {
        \\        "type": "object",
        \\        "properties": {
        \\          "detail": {"type": "string"}
        \\        },
        \\        "required": ["detail"],
        \\        "additionalProperties": false
        \\      },
        \\      "TestUser": {
        \\        "type": "object",
        \\        "properties": {
        \\          "id": {"type": "integer"},
        \\          "email": {"type": "string"}
        \\        },
        \\        "required": ["id", "email"],
        \\        "additionalProperties": false
        \\      },
        \\      "ErrorMessage": {
        \\        "type": "object",
        \\        "properties": {
        \\          "detail": {"type": "string"}
        \\        },
        \\        "required": ["detail"],
        \\        "additionalProperties": false
        \\      }
        \\    }
        \\  }
        \\}
    ,
        openapi.body.items,
    );
}

test "openapi snapshot includes request and response examples" {
    var app = ZAPI.init(testing.allocator, .{ .title = "Examples API", .version = "1.0.0" });
    defer app.deinit();
    try app.route(Route.post("/users", createUser, .{
        .name = "create_user",
        .summary = "Create user",
        .status = .created,
        .request_examples = &[_]OpenApiExample{.{
            .name = "ada",
            .summary = "Ada Lovelace",
            .value_json = "{\"email\":\"ada@example.com\"}",
        }},
        .response_examples = &[_]OpenApiExample{.{
            .name = "created",
            .summary = "Created user",
            .description = "The user returned after creation.",
            .value_json = "{\"id\":1,\"email\":\"ada@example.com\"}",
        }},
        .responses = &.{
            responseDoc(.bad_request, ErrorMessage, .{
                .description = "Invalid user",
                .examples = &[_]OpenApiExample{.{
                    .name = "invalid_email",
                    .summary = "Invalid email",
                    .value_json = "{\"detail\":\"Invalid email\"}",
                }},
            }),
        },
    }));

    var openapi = try app.handle(Request.init(.GET, "/openapi.json"));
    defer openapi.deinit(testing.allocator);

    try expectJsonEqual(
        \\{
        \\  "openapi": "3.1.0",
        \\  "info": {
        \\    "title": "Examples API",
        \\    "version": "1.0.0"
        \\  },
        \\  "paths": {
        \\    "/users": {
        \\      "post": {
        \\        "operationId": "create_user",
        \\        "summary": "Create user",
        \\        "requestBody": {
        \\          "required": true,
        \\          "content": {
        \\            "application/json": {
        \\              "schema": {"$ref": "#/components/schemas/CreateUser"},
        \\              "examples": {
        \\                "ada": {
        \\                  "summary": "Ada Lovelace",
        \\                  "value": {"email": "ada@example.com"}
        \\                }
        \\              }
        \\            }
        \\          }
        \\        },
        \\        "responses": {
        \\          "201": {
        \\            "description": "Created",
        \\            "content": {
        \\              "application/json": {
        \\                "schema": {"$ref": "#/components/schemas/TestUser"},
        \\                "examples": {
        \\                  "created": {
        \\                    "summary": "Created user",
        \\                    "description": "The user returned after creation.",
        \\                    "value": {"id": 1, "email": "ada@example.com"}
        \\                  }
        \\                }
        \\              }
        \\            }
        \\          },
        \\          "400": {
        \\            "description": "Invalid user",
        \\            "content": {
        \\              "application/json": {
        \\                "schema": {"$ref": "#/components/schemas/ErrorMessage"},
        \\                "examples": {
        \\                  "invalid_email": {
        \\                    "summary": "Invalid email",
        \\                    "value": {"detail": "Invalid email"}
        \\                  }
        \\                }
        \\              }
        \\            }
        \\          },
        \\          "422": {
        \\            "description": "Validation Error",
        \\            "content": {
        \\              "application/json": {
        \\                "schema": {"$ref": "#/components/schemas/ProblemDetail"}
        \\              }
        \\            }
        \\          }
        \\        }
        \\      }
        \\    }
        \\  },
        \\  "components": {
        \\    "schemas": {
        \\      "ProblemDetail": {
        \\        "type": "object",
        \\        "properties": {
        \\          "detail": {"type": "string"}
        \\        },
        \\        "required": ["detail"],
        \\        "additionalProperties": false
        \\      },
        \\      "CreateUser": {
        \\        "type": "object",
        \\        "properties": {
        \\          "email": {"type": "string"}
        \\        },
        \\        "required": ["email"],
        \\        "additionalProperties": false
        \\      },
        \\      "TestUser": {
        \\        "type": "object",
        \\        "properties": {
        \\          "id": {"type": "integer"},
        \\          "email": {"type": "string"}
        \\        },
        \\        "required": ["id", "email"],
        \\        "additionalProperties": false
        \\      },
        \\      "ErrorMessage": {
        \\        "type": "object",
        \\        "properties": {
        \\          "detail": {"type": "string"}
        \\        },
        \\        "required": ["detail"],
        \\        "additionalProperties": false
        \\      }
        \\    }
        \\  }
        \\}
    ,
        openapi.body.items,
    );
}

test "openapi snapshot inlines nullable response schemas without component collisions" {
    var app = ZAPI.init(testing.allocator, .{ .title = "Nullable Response API", .version = "1.0.0" });
    defer app.deinit();
    try app.route(Route.get("/users/{id}", getUser, .{
        .name = "get_user",
        .summary = "Get user",
    }));
    try app.route(Route.get("/maybe-user", maybeGetUser, .{
        .name = "maybe_get_user",
        .summary = "Maybe get user",
    }));

    var openapi = try app.handle(Request.init(.GET, "/openapi.json"));
    defer openapi.deinit(testing.allocator);

    try expectJsonEqual(
        \\{
        \\  "openapi": "3.1.0",
        \\  "info": {
        \\    "title": "Nullable Response API",
        \\    "version": "1.0.0"
        \\  },
        \\  "paths": {
        \\    "/users/{id}": {
        \\      "get": {
        \\        "operationId": "get_user",
        \\        "summary": "Get user",
        \\        "parameters": [
        \\          {"name": "id", "in": "path", "required": true, "schema": {"type": "integer"}},
        \\          {"name": "verbose", "in": "query", "required": false, "schema": {"anyOf": [{"type": "boolean"}, {"type": "null"}], "default": null}}
        \\        ],
        \\        "responses": {
        \\          "200": {
        \\            "description": "OK",
        \\            "content": {
        \\              "application/json": {
        \\                "schema": {"$ref": "#/components/schemas/TestUser"}
        \\              }
        \\            }
        \\          },
        \\          "422": {
        \\            "description": "Validation Error",
        \\            "content": {
        \\              "application/json": {
        \\                "schema": {"$ref": "#/components/schemas/ProblemDetail"}
        \\              }
        \\            }
        \\          }
        \\        }
        \\      }
        \\    },
        \\    "/maybe-user": {
        \\      "get": {
        \\        "operationId": "maybe_get_user",
        \\        "summary": "Maybe get user",
        \\        "responses": {
        \\          "200": {
        \\            "description": "OK",
        \\            "content": {
        \\              "application/json": {
        \\                "schema": {
        \\                  "anyOf": [
        \\                    {
        \\                      "type": "object",
        \\                      "properties": {
        \\                        "id": {"type": "integer"},
        \\                        "email": {"type": "string"}
        \\                      },
        \\                      "required": ["id", "email"],
        \\                      "additionalProperties": false
        \\                    },
        \\                    {"type": "null"}
        \\                  ]
        \\                }
        \\              }
        \\            }
        \\          }
        \\        }
        \\      }
        \\    }
        \\  },
        \\  "components": {
        \\    "schemas": {
        \\      "ProblemDetail": {
        \\        "type": "object",
        \\        "properties": {
        \\          "detail": {"type": "string"}
        \\        },
        \\        "required": ["detail"],
        \\        "additionalProperties": false
        \\      },
        \\      "TestUser": {
        \\        "type": "object",
        \\        "properties": {
        \\          "id": {"type": "integer"},
        \\          "email": {"type": "string"}
        \\        },
        \\        "required": ["id", "email"],
        \\        "additionalProperties": false
        \\      }
        \\    }
        \\  }
        \\}
    ,
        openapi.body.items,
    );
}

test "openapi snapshot uses explicit json response inner schema" {
    var app = ZAPI.init(testing.allocator, .{ .title = "Explicit JSON API", .version = "1.0.0" });
    defer app.deinit();
    try app.route(Route.get("/json", explicitJson, .{
        .name = "explicit_json",
        .summary = "Explicit JSON",
    }));
    try app.route(Route.get("/raw-json", explicitRawJson, .{
        .name = "explicit_raw_json",
        .summary = "Explicit raw JSON",
    }));

    var openapi = try app.handle(Request.init(.GET, "/openapi.json"));
    defer openapi.deinit(testing.allocator);

    try expectJsonEqual(
        \\{
        \\  "openapi": "3.1.0",
        \\  "info": {
        \\    "title": "Explicit JSON API",
        \\    "version": "1.0.0"
        \\  },
        \\  "paths": {
        \\    "/json": {
        \\      "get": {
        \\        "operationId": "explicit_json",
        \\        "summary": "Explicit JSON",
        \\        "responses": {
        \\          "200": {
        \\            "description": "OK",
        \\            "content": {
        \\              "application/json": {
        \\                "schema": {"$ref": "#/components/schemas/JsonMessage"}
        \\              }
        \\            }
        \\          }
        \\        }
        \\      }
        \\    },
        \\    "/raw-json": {
        \\      "get": {
        \\        "operationId": "explicit_raw_json",
        \\        "summary": "Explicit raw JSON",
        \\        "responses": {
        \\          "200": {
        \\            "description": "OK",
        \\            "content": {
        \\              "application/json": {}
        \\            }
        \\          }
        \\        }
        \\      }
        \\    }
        \\  },
        \\  "components": {
        \\    "schemas": {
        \\      "JsonMessage": {
        \\        "type": "object",
        \\        "properties": {
        \\          "message": {"type": "string"}
        \\        },
        \\        "required": ["message"],
        \\        "additionalProperties": false
        \\      }
        \\    }
        \\  }
        \\}
    ,
        openapi.body.items,
    );
}

test "openapi snapshot includes schema free response media types" {
    var app = ZAPI.init(testing.allocator, .{ .title = "Media API", .version = "1.0.0" });
    defer app.deinit();
    try app.route(Route.get("/text", plainText, .{
        .name = "plain_text",
        .summary = "Plain text",
    }));
    try app.route(Route.get("/html", htmlPage, .{
        .name = "html_page",
        .summary = "HTML page",
    }));
    try app.route(Route.get("/template", templatePage, .{
        .name = "template_page",
        .summary = "Template page",
    }));
    try app.route(Route.get("/events", richEventStream, .{
        .name = "event_stream",
        .summary = "Event stream",
    }));
    try app.route(Route.get("/stream", streamingPlainText, .{
        .name = "streaming_plain_text",
        .summary = "Streaming bytes",
    }));
    try app.route(Route.get("/bytes", binaryData, .{
        .name = "binary_data",
        .summary = "Binary data",
    }));
    try app.route(Route.get("/download", downloadFile, .{
        .name = "download_file",
        .summary = "Download file",
    }));

    var openapi = try app.handle(Request.init(.GET, "/openapi.json"));
    defer openapi.deinit(testing.allocator);

    try expectJsonEqual(
        \\{
        \\  "openapi": "3.1.0",
        \\  "info": {
        \\    "title": "Media API",
        \\    "version": "1.0.0"
        \\  },
        \\  "paths": {
        \\    "/text": {
        \\      "get": {
        \\        "operationId": "plain_text",
        \\        "summary": "Plain text",
        \\        "responses": {
        \\          "200": {
        \\            "description": "OK",
        \\            "content": {
        \\              "text/plain; charset=utf-8": {
        \\                "schema": {"type": "string"}
        \\              }
        \\            }
        \\          }
        \\        }
        \\      }
        \\    },
        \\    "/html": {
        \\      "get": {
        \\        "operationId": "html_page",
        \\        "summary": "HTML page",
        \\        "responses": {
        \\          "200": {
        \\            "description": "OK",
        \\            "content": {
        \\              "text/html; charset=utf-8": {
        \\                "schema": {"type": "string"}
        \\              }
        \\            }
        \\          }
        \\        }
        \\      }
        \\    },
        \\    "/template": {
        \\      "get": {
        \\        "operationId": "template_page",
        \\        "summary": "Template page",
        \\        "responses": {
        \\          "200": {
        \\            "description": "OK",
        \\            "content": {
        \\              "text/html; charset=utf-8": {
        \\                "schema": {"type": "string"}
        \\              }
        \\            }
        \\          }
        \\        }
        \\      }
        \\    },
        \\    "/events": {
        \\      "get": {
        \\        "operationId": "event_stream",
        \\        "summary": "Event stream",
        \\        "responses": {
        \\          "200": {
        \\            "description": "OK",
        \\            "content": {
        \\              "text/event-stream": {
        \\                "schema": {"type": "string"}
        \\              }
        \\            }
        \\          }
        \\        }
        \\      }
        \\    },
        \\    "/stream": {
        \\      "get": {
        \\        "operationId": "streaming_plain_text",
        \\        "summary": "Streaming bytes",
        \\        "responses": {
        \\          "200": {
        \\            "description": "OK",
        \\            "content": {
        \\              "application/octet-stream": {
        \\                "schema": {"type": "string", "format": "binary"}
        \\              }
        \\            }
        \\          }
        \\        }
        \\      }
        \\    },
        \\    "/bytes": {
        \\      "get": {
        \\        "operationId": "binary_data",
        \\        "summary": "Binary data",
        \\        "responses": {
        \\          "200": {
        \\            "description": "OK",
        \\            "content": {
        \\              "application/octet-stream": {
        \\                "schema": {"type": "string", "format": "binary"}
        \\              }
        \\            }
        \\          }
        \\        }
        \\      }
        \\    },
        \\    "/download": {
        \\      "get": {
        \\        "operationId": "download_file",
        \\        "summary": "Download file",
        \\        "responses": {
        \\          "200": {
        \\            "description": "OK",
        \\            "content": {
        \\              "application/octet-stream": {
        \\                "schema": {"type": "string", "format": "binary"}
        \\              }
        \\            }
        \\          }
        \\        }
        \\      }
        \\    }
        \\  },
        \\  "components": {
        \\    "schemas": {}
        \\  }
        \\}
    ,
        openapi.body.items,
    );
}

test "openapi snapshot includes bearer auth security scheme" {
    var app = ZAPI.init(testing.allocator, .{ .title = "Security API", .version = "1.0.0" });
    defer app.deinit();
    try app.route(Route.get("/me", secureMe, .{
        .name = "secure_me",
        .summary = "Current user token",
        .tags = &.{"auth"},
    }));

    var openapi = try app.handle(Request.init(.GET, "/openapi.json"));
    defer openapi.deinit(testing.allocator);

    try expectJsonEqual(
        \\{
        \\  "openapi": "3.1.0",
        \\  "info": {
        \\    "title": "Security API",
        \\    "version": "1.0.0"
        \\  },
        \\  "paths": {
        \\    "/me": {
        \\      "get": {
        \\        "operationId": "secure_me",
        \\        "summary": "Current user token",
        \\        "tags": ["auth"],
        \\        "security": [
        \\          {"BearerAuth": []}
        \\        ],
        \\        "responses": {
        \\          "200": {
        \\            "description": "OK",
        \\            "content": {
        \\              "application/json": {
        \\                "schema": {"$ref": "#/components/schemas/AuthEcho"}
        \\              }
        \\            }
        \\          }
        \\        }
        \\      }
        \\    }
        \\  },
        \\  "components": {
        \\    "schemas": {
        \\      "AuthEcho": {
        \\        "type": "object",
        \\        "properties": {
        \\          "token": {"type": "string"}
        \\        },
        \\        "required": ["token"],
        \\        "additionalProperties": false
        \\      }
        \\    },
        \\    "securitySchemes": {
        \\      "BearerAuth": {
        \\        "type": "http",
        \\        "scheme": "bearer"
        \\      }
        \\    }
        \\  }
        \\}
    ,
        openapi.body.items,
    );
}

test "openapi snapshot includes oauth2 password bearer security scheme" {
    var app = ZAPI.init(testing.allocator, .{ .title = "OAuth2 API", .version = "1.0.0" });
    defer app.deinit();
    try app.route(Route.get("/oauth2", secureOAuth2, .{
        .name = "secure_oauth2",
        .summary = "Current OAuth2 token",
        .tags = &.{"auth"},
    }));

    var openapi = try app.handle(Request.init(.GET, "/openapi.json"));
    defer openapi.deinit(testing.allocator);

    try expectJsonEqual(
        \\{
        \\  "openapi": "3.1.0",
        \\  "info": {
        \\    "title": "OAuth2 API",
        \\    "version": "1.0.0"
        \\  },
        \\  "paths": {
        \\    "/oauth2": {
        \\      "get": {
        \\        "operationId": "secure_oauth2",
        \\        "summary": "Current OAuth2 token",
        \\        "tags": ["auth"],
        \\        "security": [
        \\          {"OAuth2PasswordBearer": ["users:read", "users:write"]}
        \\        ],
        \\        "responses": {
        \\          "200": {
        \\            "description": "OK",
        \\            "content": {
        \\              "application/json": {
        \\                "schema": {"$ref": "#/components/schemas/AuthEcho"}
        \\              }
        \\            }
        \\          }
        \\        }
        \\      }
        \\    }
        \\  },
        \\  "components": {
        \\    "schemas": {
        \\      "AuthEcho": {
        \\        "type": "object",
        \\        "properties": {
        \\          "token": {"type": "string"}
        \\        },
        \\        "required": ["token"],
        \\        "additionalProperties": false
        \\      }
        \\    },
        \\    "securitySchemes": {
        \\      "OAuth2PasswordBearer": {
        \\        "type": "oauth2",
        \\        "flows": {
        \\          "password": {
        \\            "tokenUrl": "/token",
        \\            "scopes": {
        \\              "users:read": "Read users",
        \\              "users:write": "Write users"
        \\            }
        \\          }
        \\        }
        \\      }
        \\    }
        \\  }
        \\}
    ,
        openapi.body.items,
    );
}

test "openapi snapshot includes oauth2 authorization code bearer security scheme" {
    var app = ZAPI.init(testing.allocator, .{ .title = "OAuth2 Code API", .version = "1.0.0" });
    defer app.deinit();
    try app.route(Route.get("/oauth2-code", secureOAuth2AuthorizationCode, .{
        .name = "secure_oauth2_code",
        .summary = "Current OAuth2 authorization code token",
        .tags = &.{"auth"},
    }));

    var openapi = try app.handle(Request.init(.GET, "/openapi.json"));
    defer openapi.deinit(testing.allocator);

    try expectJsonEqual(
        \\{
        \\  "openapi": "3.1.0",
        \\  "info": {
        \\    "title": "OAuth2 Code API",
        \\    "version": "1.0.0"
        \\  },
        \\  "paths": {
        \\    "/oauth2-code": {
        \\      "get": {
        \\        "operationId": "secure_oauth2_code",
        \\        "summary": "Current OAuth2 authorization code token",
        \\        "tags": ["auth"],
        \\        "security": [
        \\          {"OAuth2AuthorizationCodeBearer": ["profile", "email"]}
        \\        ],
        \\        "responses": {
        \\          "200": {
        \\            "description": "OK",
        \\            "content": {
        \\              "application/json": {
        \\                "schema": {"$ref": "#/components/schemas/AuthEcho"}
        \\              }
        \\            }
        \\          }
        \\        }
        \\      }
        \\    }
        \\  },
        \\  "components": {
        \\    "schemas": {
        \\      "AuthEcho": {
        \\        "type": "object",
        \\        "properties": {
        \\          "token": {"type": "string"}
        \\        },
        \\        "required": ["token"],
        \\        "additionalProperties": false
        \\      }
        \\    },
        \\    "securitySchemes": {
        \\      "OAuth2AuthorizationCodeBearer": {
        \\        "type": "oauth2",
        \\        "flows": {
        \\          "authorizationCode": {
        \\            "authorizationUrl": "/authorize",
        \\            "tokenUrl": "/token",
        \\            "scopes": {
        \\              "profile": "Read profile",
        \\              "email": "Read email"
        \\            }
        \\          }
        \\        }
        \\      }
        \\    }
        \\  }
        \\}
    ,
        openapi.body.items,
    );
}

test "openapi snapshot includes oauth2 client credentials bearer security scheme" {
    var app = ZAPI.init(testing.allocator, .{ .title = "OAuth2 Client API", .version = "1.0.0" });
    defer app.deinit();
    try app.route(Route.get("/oauth2-client", secureOAuth2ClientCredentials, .{
        .name = "secure_oauth2_client",
        .summary = "Current OAuth2 client credentials token",
        .tags = &.{"auth"},
    }));

    var openapi = try app.handle(Request.init(.GET, "/openapi.json"));
    defer openapi.deinit(testing.allocator);

    try expectJsonEqual(
        \\{
        \\  "openapi": "3.1.0",
        \\  "info": {
        \\    "title": "OAuth2 Client API",
        \\    "version": "1.0.0"
        \\  },
        \\  "paths": {
        \\    "/oauth2-client": {
        \\      "get": {
        \\        "operationId": "secure_oauth2_client",
        \\        "summary": "Current OAuth2 client credentials token",
        \\        "tags": ["auth"],
        \\        "security": [
        \\          {"OAuth2ClientCredentialsBearer": ["jobs:read", "jobs:write"]}
        \\        ],
        \\        "responses": {
        \\          "200": {
        \\            "description": "OK",
        \\            "content": {
        \\              "application/json": {
        \\                "schema": {"$ref": "#/components/schemas/AuthEcho"}
        \\              }
        \\            }
        \\          }
        \\        }
        \\      }
        \\    }
        \\  },
        \\  "components": {
        \\    "schemas": {
        \\      "AuthEcho": {
        \\        "type": "object",
        \\        "properties": {
        \\          "token": {"type": "string"}
        \\        },
        \\        "required": ["token"],
        \\        "additionalProperties": false
        \\      }
        \\    },
        \\    "securitySchemes": {
        \\      "OAuth2ClientCredentialsBearer": {
        \\        "type": "oauth2",
        \\        "flows": {
        \\          "clientCredentials": {
        \\            "tokenUrl": "/machine-token",
        \\            "scopes": {
        \\              "jobs:read": "Read jobs",
        \\              "jobs:write": "Write jobs"
        \\            }
        \\          }
        \\        }
        \\      }
        \\    }
        \\  }
        \\}
    ,
        openapi.body.items,
    );
}

test "openapi snapshot includes oauth2 implicit bearer security scheme" {
    var app = ZAPI.init(testing.allocator, .{ .title = "OAuth2 Implicit API", .version = "1.0.0" });
    defer app.deinit();
    try app.route(Route.get("/oauth2-implicit", secureOAuth2Implicit, .{
        .name = "secure_oauth2_implicit",
        .summary = "Current OAuth2 implicit token",
        .tags = &.{"auth"},
    }));

    var openapi = try app.handle(Request.init(.GET, "/openapi.json"));
    defer openapi.deinit(testing.allocator);

    try expectJsonEqual(
        \\{
        \\  "openapi": "3.1.0",
        \\  "info": {
        \\    "title": "OAuth2 Implicit API",
        \\    "version": "1.0.0"
        \\  },
        \\  "paths": {
        \\    "/oauth2-implicit": {
        \\      "get": {
        \\        "operationId": "secure_oauth2_implicit",
        \\        "summary": "Current OAuth2 implicit token",
        \\        "tags": ["auth"],
        \\        "security": [
        \\          {"OAuth2ImplicitBearer": ["browser:read", "browser:write"]}
        \\        ],
        \\        "responses": {
        \\          "200": {
        \\            "description": "OK",
        \\            "content": {
        \\              "application/json": {
        \\                "schema": {"$ref": "#/components/schemas/AuthEcho"}
        \\              }
        \\            }
        \\          }
        \\        }
        \\      }
        \\    }
        \\  },
        \\  "components": {
        \\    "schemas": {
        \\      "AuthEcho": {
        \\        "type": "object",
        \\        "properties": {
        \\          "token": {"type": "string"}
        \\        },
        \\        "required": ["token"],
        \\        "additionalProperties": false
        \\      }
        \\    },
        \\    "securitySchemes": {
        \\      "OAuth2ImplicitBearer": {
        \\        "type": "oauth2",
        \\        "flows": {
        \\          "implicit": {
        \\            "authorizationUrl": "/authorize-implicit",
        \\            "scopes": {
        \\              "browser:read": "Read browser data",
        \\              "browser:write": "Write browser data"
        \\            }
        \\          }
        \\        }
        \\      }
        \\    }
        \\  }
        \\}
    ,
        openapi.body.items,
    );
}

test "openapi snapshot includes basic auth security scheme" {
    var app = ZAPI.init(testing.allocator, .{ .title = "Basic Security API", .version = "1.0.0" });
    defer app.deinit();
    try app.route(Route.get("/basic", secureBasic, .{
        .name = "secure_basic",
        .summary = "Current basic credentials",
        .tags = &.{"auth"},
    }));

    var openapi = try app.handle(Request.init(.GET, "/openapi.json"));
    defer openapi.deinit(testing.allocator);

    try expectJsonEqual(
        \\{
        \\  "openapi": "3.1.0",
        \\  "info": {
        \\    "title": "Basic Security API",
        \\    "version": "1.0.0"
        \\  },
        \\  "paths": {
        \\    "/basic": {
        \\      "get": {
        \\        "operationId": "secure_basic",
        \\        "summary": "Current basic credentials",
        \\        "tags": ["auth"],
        \\        "security": [
        \\          {"BasicAuth": []}
        \\        ],
        \\        "responses": {
        \\          "200": {
        \\            "description": "OK",
        \\            "content": {
        \\              "application/json": {
        \\                "schema": {"$ref": "#/components/schemas/BasicAuthEcho"}
        \\              }
        \\            }
        \\          }
        \\        }
        \\      }
        \\    }
        \\  },
        \\  "components": {
        \\    "schemas": {
        \\      "BasicAuthEcho": {
        \\        "type": "object",
        \\        "properties": {
        \\          "username": {"type": "string"},
        \\          "password": {"type": "string"}
        \\        },
        \\        "required": ["username", "password"],
        \\        "additionalProperties": false
        \\      }
        \\    },
        \\    "securitySchemes": {
        \\      "BasicAuth": {
        \\        "type": "http",
        \\        "scheme": "basic"
        \\      }
        \\    }
        \\  }
        \\}
    ,
        openapi.body.items,
    );
}

test "openapi snapshot includes api key security schemes" {
    var app = ZAPI.init(testing.allocator, .{ .title = "API Key Security", .version = "1.0.0" });
    defer app.deinit();
    try app.route(Route.get("/header", secureHeaderKey, .{
        .name = "secure_header_key",
        .summary = "Header API key",
        .tags = &.{"auth"},
    }));
    try app.route(Route.get("/query", secureQueryKey, .{
        .name = "secure_query_key",
        .summary = "Query API key",
        .tags = &.{"auth"},
    }));
    try app.route(Route.get("/cookie", secureCookieKey, .{
        .name = "secure_cookie_key",
        .summary = "Cookie API key",
        .tags = &.{"auth"},
    }));

    var openapi = try app.handle(Request.init(.GET, "/openapi.json"));
    defer openapi.deinit(testing.allocator);

    try expectJsonEqual(
        \\{
        \\  "openapi": "3.1.0",
        \\  "info": {
        \\    "title": "API Key Security",
        \\    "version": "1.0.0"
        \\  },
        \\  "paths": {
        \\    "/header": {
        \\      "get": {
        \\        "operationId": "secure_header_key",
        \\        "summary": "Header API key",
        \\        "tags": ["auth"],
        \\        "security": [
        \\          {"ApiKeyHeader_x_api_key": []}
        \\        ],
        \\        "responses": {
        \\          "200": {
        \\            "description": "OK",
        \\            "content": {
        \\              "application/json": {
        \\                "schema": {"$ref": "#/components/schemas/AuthEcho"}
        \\              }
        \\            }
        \\          }
        \\        }
        \\      }
        \\    },
        \\    "/query": {
        \\      "get": {
        \\        "operationId": "secure_query_key",
        \\        "summary": "Query API key",
        \\        "tags": ["auth"],
        \\        "security": [
        \\          {"ApiKeyQuery_api_key": []}
        \\        ],
        \\        "responses": {
        \\          "200": {
        \\            "description": "OK",
        \\            "content": {
        \\              "application/json": {
        \\                "schema": {"$ref": "#/components/schemas/AuthEcho"}
        \\              }
        \\            }
        \\          }
        \\        }
        \\      }
        \\    },
        \\    "/cookie": {
        \\      "get": {
        \\        "operationId": "secure_cookie_key",
        \\        "summary": "Cookie API key",
        \\        "tags": ["auth"],
        \\        "security": [
        \\          {"ApiKeyCookie_session": []}
        \\        ],
        \\        "responses": {
        \\          "200": {
        \\            "description": "OK",
        \\            "content": {
        \\              "application/json": {
        \\                "schema": {"$ref": "#/components/schemas/AuthEcho"}
        \\              }
        \\            }
        \\          }
        \\        }
        \\      }
        \\    }
        \\  },
        \\  "components": {
        \\    "schemas": {
        \\      "AuthEcho": {
        \\        "type": "object",
        \\        "properties": {
        \\          "token": {"type": "string"}
        \\        },
        \\        "required": ["token"],
        \\        "additionalProperties": false
        \\      }
        \\    },
        \\    "securitySchemes": {
        \\      "ApiKeyHeader_x_api_key": {
        \\        "type": "apiKey",
        \\        "in": "header",
        \\        "name": "x-api-key"
        \\      },
        \\      "ApiKeyQuery_api_key": {
        \\        "type": "apiKey",
        \\        "in": "query",
        \\        "name": "api_key"
        \\      },
        \\      "ApiKeyCookie_session": {
        \\        "type": "apiKey",
        \\        "in": "cookie",
        \\        "name": "session"
        \\      }
        \\    }
        \\  }
        \\}
    ,
        openapi.body.items,
    );
}

test "openapi snapshot includes cookie parameters" {
    var app = ZAPI.init(testing.allocator, .{ .title = "Cookie API", .version = "1.0.0" });
    defer app.deinit();
    try app.route(Route.get("/users/{id}", userWithCookies, .{
        .name = "user_with_cookies",
        .summary = "Get user with cookies",
        .tags = &.{"users"},
    }));

    var openapi = try app.handle(Request.init(.GET, "/openapi.json"));
    defer openapi.deinit(testing.allocator);

    try expectJsonEqual(
        \\{
        \\  "openapi": "3.1.0",
        \\  "info": {
        \\    "title": "Cookie API",
        \\    "version": "1.0.0"
        \\  },
        \\  "paths": {
        \\    "/users/{id}": {
        \\      "get": {
        \\        "operationId": "user_with_cookies",
        \\        "summary": "Get user with cookies",
        \\        "tags": ["users"],
        \\        "parameters": [
        \\          {"name": "id", "in": "path", "required": true, "schema": {"type": "integer"}},
        \\          {"name": "session_id", "in": "cookie", "required": true, "schema": {"type": "string"}}
        \\        ],
        \\        "responses": {
        \\          "200": {
        \\            "description": "OK",
        \\            "content": {
        \\              "application/json": {
        \\                "schema": {"$ref": "#/components/schemas/TestUser"}
        \\              }
        \\            }
        \\          },
        \\          "422": {
        \\            "description": "Validation Error",
        \\            "content": {
        \\              "application/json": {
        \\                "schema": {"$ref": "#/components/schemas/ProblemDetail"}
        \\              }
        \\            }
        \\          }
        \\        }
        \\      }
        \\    }
        \\  },
        \\  "components": {
        \\    "schemas": {
        \\      "ProblemDetail": {
        \\        "type": "object",
        \\        "properties": {
        \\          "detail": {"type": "string"}
        \\        },
        \\        "required": ["detail"],
        \\        "additionalProperties": false
        \\      },
        \\      "TestUser": {
        \\        "type": "object",
        \\        "properties": {
        \\          "id": {"type": "integer"},
        \\          "email": {"type": "string"}
        \\        },
        \\        "required": ["id", "email"],
        \\        "additionalProperties": false
        \\      }
        \\    }
        \\  }
        \\}
    ,
        openapi.body.items,
    );
}

test "openapi snapshot includes optional json request body" {
    var app = ZAPI.init(testing.allocator, .{ .title = "Optional Body API", .version = "1.0.0" });
    defer app.deinit();
    try app.route(Route.post("/maybe-users", maybeCreateUser, .{
        .name = "maybe_create_user",
        .summary = "Maybe create user",
        .tags = &.{"users"},
    }));

    var openapi = try app.handle(Request.init(.GET, "/openapi.json"));
    defer openapi.deinit(testing.allocator);

    try expectJsonEqual(
        \\{
        \\  "openapi": "3.1.0",
        \\  "info": {
        \\    "title": "Optional Body API",
        \\    "version": "1.0.0"
        \\  },
        \\  "paths": {
        \\    "/maybe-users": {
        \\      "post": {
        \\        "operationId": "maybe_create_user",
        \\        "summary": "Maybe create user",
        \\        "tags": ["users"],
        \\        "requestBody": {
        \\          "required": false,
        \\          "content": {
        \\            "application/json": {
        \\              "schema": {
        \\                "anyOf": [
        \\                  {
        \\                    "type": "object",
        \\                    "properties": {
        \\                      "email": {"type": "string"}
        \\                    },
        \\                    "required": ["email"],
        \\                    "additionalProperties": false
        \\                  },
        \\                  {"type": "null"}
        \\                ]
        \\              }
        \\            }
        \\          }
        \\        },
        \\        "responses": {
        \\          "200": {
        \\            "description": "OK",
        \\            "content": {
        \\              "application/json": {
        \\                "schema": {"$ref": "#/components/schemas/OptionalCreateResult"}
        \\              }
        \\            }
        \\          },
        \\          "422": {
        \\            "description": "Validation Error",
        \\            "content": {
        \\              "application/json": {
        \\                "schema": {"$ref": "#/components/schemas/ProblemDetail"}
        \\              }
        \\            }
        \\          }
        \\        }
        \\      }
        \\    }
        \\  },
        \\  "components": {
        \\    "schemas": {
        \\      "ProblemDetail": {
        \\        "type": "object",
        \\        "properties": {
        \\          "detail": {"type": "string"}
        \\        },
        \\        "required": ["detail"],
        \\        "additionalProperties": false
        \\      },
        \\      "OptionalCreateResult": {
        \\        "type": "object",
        \\        "properties": {
        \\          "email": {"anyOf": [{"type": "string"}, {"type": "null"}]}
        \\        },
        \\        "additionalProperties": false
        \\      }
        \\    }
        \\  }
        \\}
    ,
        openapi.body.items,
    );
}

test "openapi snapshot includes json object maps" {
    var app = ZAPI.init(testing.allocator, .{ .title = "Map Body API", .version = "1.0.0" });
    defer app.deinit();
    try app.route(Route.post("/scores", echoScores, .{
        .name = "echo_scores",
        .summary = "Echo scores",
    }));

    var openapi = try app.handle(Request.init(.GET, "/openapi.json"));
    defer openapi.deinit(testing.allocator);

    try expectJsonEqual(
        \\{
        \\  "openapi": "3.1.0",
        \\  "info": {
        \\    "title": "Map Body API",
        \\    "version": "1.0.0"
        \\  },
        \\  "paths": {
        \\    "/scores": {
        \\      "post": {
        \\        "operationId": "echo_scores",
        \\        "summary": "Echo scores",
        \\        "requestBody": {
        \\          "required": true,
        \\          "content": {
        \\            "application/json": {
        \\              "schema": {
        \\                "type": "object",
        \\                "additionalProperties": {"type": "integer"}
        \\              }
        \\            }
        \\          }
        \\        },
        \\        "responses": {
        \\          "200": {
        \\            "description": "OK",
        \\            "content": {
        \\              "application/json": {
        \\                "schema": {
        \\                  "type": "object",
        \\                  "additionalProperties": {"type": "integer"}
        \\                }
        \\              }
        \\            }
        \\          },
        \\          "422": {
        \\            "description": "Validation Error",
        \\            "content": {
        \\              "application/json": {
        \\                "schema": {"$ref": "#/components/schemas/ProblemDetail"}
        \\              }
        \\            }
        \\          }
        \\        }
        \\      }
        \\    }
        \\  },
        \\  "components": {
        \\    "schemas": {
        \\      "ProblemDetail": {
        \\        "type": "object",
        \\        "properties": {
        \\          "detail": {"type": "string"}
        \\        },
        \\        "required": ["detail"],
        \\        "additionalProperties": false
        \\      }
        \\    }
        \\  }
        \\}
    ,
        openapi.body.items,
    );
}

test "openapi snapshot includes explicit main response description" {
    var app = ZAPI.init(testing.allocator, .{ .title = "Response Description API", .version = "1.0.0" });
    defer app.deinit();
    try app.route(Route.get("/text", plainText, .{
        .name = "text_operation",
        .summary = "Text",
        .response_description = "Plain text body",
    }));

    var openapi = try app.handle(Request.init(.GET, "/openapi.json"));
    defer openapi.deinit(testing.allocator);

    try expectJsonEqual(
        \\{
        \\  "openapi": "3.1.0",
        \\  "info": {
        \\    "title": "Response Description API",
        \\    "version": "1.0.0"
        \\  },
        \\  "paths": {
        \\    "/text": {
        \\      "get": {
        \\        "operationId": "text_operation",
        \\        "summary": "Text",
        \\        "responses": {
        \\          "200": {
        \\            "description": "Plain text body",
        \\            "content": {
        \\              "text/plain; charset=utf-8": {
        \\                "schema": {"type": "string"}
        \\              }
        \\            }
        \\          }
        \\        }
        \\      }
        \\    }
        \\  },
        \\  "components": {
        \\    "schemas": {}
        \\  }
        \\}
    ,
        openapi.body.items,
    );
}

test "openapi snapshot inlines direct json array bodies and responses" {
    var app = ZAPI.init(testing.allocator, .{ .title = "Array Body API", .version = "1.0.0" });
    defer app.deinit();
    try app.route(Route.get("/users/bulk", listCreateUsers, .{
        .name = "list_create_users",
        .summary = "List create users",
        .tags = &.{"users"},
    }));
    try app.route(Route.post("/users/bulk", echoCreateUsers, .{
        .name = "echo_create_users",
        .summary = "Echo create users",
        .tags = &.{"users"},
    }));

    var openapi = try app.handle(Request.init(.GET, "/openapi.json"));
    defer openapi.deinit(testing.allocator);

    try expectJsonEqual(
        \\{
        \\  "openapi": "3.1.0",
        \\  "info": {
        \\    "title": "Array Body API",
        \\    "version": "1.0.0"
        \\  },
        \\  "paths": {
        \\    "/users/bulk": {
        \\      "get": {
        \\        "operationId": "list_create_users",
        \\        "summary": "List create users",
        \\        "tags": ["users"],
        \\        "responses": {
        \\          "200": {
        \\            "description": "OK",
        \\            "content": {
        \\              "application/json": {
        \\                "schema": {
        \\                  "type": "array",
        \\                  "items": {
        \\                    "type": "object",
        \\                    "properties": {
        \\                      "email": {"type": "string"}
        \\                    },
        \\                    "required": ["email"],
        \\                    "additionalProperties": false
        \\                  }
        \\                }
        \\              }
        \\            }
        \\          }
        \\        }
        \\      },
        \\      "post": {
        \\        "operationId": "echo_create_users",
        \\        "summary": "Echo create users",
        \\        "tags": ["users"],
        \\        "requestBody": {
        \\          "required": true,
        \\          "content": {
        \\            "application/json": {
        \\              "schema": {
        \\                "type": "array",
        \\                "items": {
        \\                  "type": "object",
        \\                  "properties": {
        \\                    "email": {"type": "string"}
        \\                  },
        \\                  "required": ["email"],
        \\                  "additionalProperties": false
        \\                }
        \\              }
        \\            }
        \\          }
        \\        },
        \\        "responses": {
        \\          "200": {
        \\            "description": "OK",
        \\            "content": {
        \\              "application/json": {
        \\                "schema": {
        \\                  "type": "array",
        \\                  "items": {
        \\                    "type": "object",
        \\                    "properties": {
        \\                      "email": {"type": "string"}
        \\                    },
        \\                    "required": ["email"],
        \\                    "additionalProperties": false
        \\                  }
        \\                }
        \\              }
        \\            }
        \\          },
        \\          "422": {
        \\            "description": "Validation Error",
        \\            "content": {
        \\              "application/json": {
        \\                "schema": {"$ref": "#/components/schemas/ProblemDetail"}
        \\              }
        \\            }
        \\          }
        \\        }
        \\      }
        \\    }
        \\  },
        \\  "components": {
        \\    "schemas": {
        \\      "ProblemDetail": {
        \\        "type": "object",
        \\        "properties": {
        \\          "detail": {"type": "string"}
        \\        },
        \\        "required": ["detail"],
        \\        "additionalProperties": false
        \\      }
        \\    }
        \\  }
        \\}
    ,
        openapi.body.items,
    );
}

test "openapi snapshot includes methods route groups" {
    var app = ZAPI.init(testing.allocator, .{ .title = "Route Group API", .version = "1.0.0" });
    defer app.deinit();
    const router = Router.init(.{
        .tags = &.{"tools"},
        .routes = .{
            Route.methods("/ping", &.{ .GET, .POST, .TRACE }, plainText, .{ .summary = "Ping" }),
        },
    });
    try app.includeRouter(router);

    var openapi = try app.handle(Request.init(.GET, "/openapi.json"));
    defer openapi.deinit(testing.allocator);

    try expectJsonEqual(
        \\{
        \\  "openapi": "3.1.0",
        \\  "info": {
        \\    "title": "Route Group API",
        \\    "version": "1.0.0"
        \\  },
        \\  "paths": {
        \\    "/ping": {
        \\      "get": {
        \\        "operationId": "get_ping",
        \\        "summary": "Ping",
        \\        "tags": ["tools"],
        \\        "responses": {
        \\          "200": {
        \\            "description": "OK",
        \\            "content": {
        \\              "text/plain; charset=utf-8": {
        \\                "schema": {"type": "string"}
        \\              }
        \\            }
        \\          }
        \\        }
        \\      },
        \\      "post": {
        \\        "operationId": "post_ping",
        \\        "summary": "Ping",
        \\        "tags": ["tools"],
        \\        "responses": {
        \\          "200": {
        \\            "description": "OK",
        \\            "content": {
        \\              "text/plain; charset=utf-8": {
        \\                "schema": {"type": "string"}
        \\              }
        \\            }
        \\          }
        \\        }
        \\      },
        \\      "trace": {
        \\        "operationId": "trace_ping",
        \\        "summary": "Ping",
        \\        "tags": ["tools"],
        \\        "responses": {
        \\          "200": {
        \\            "description": "OK",
        \\            "content": {
        \\              "text/plain; charset=utf-8": {
        \\                "schema": {"type": "string"}
        \\              }
        \\            }
        \\          }
        \\        }
        \\      }
        \\    }
        \\  },
        \\  "components": {
        \\    "schemas": {}
        \\  }
        \\}
    ,
        openapi.body.items,
    );
}

test "openapi snapshot includes nested router prefixes and tags" {
    var app = ZAPI.init(testing.allocator, .{ .title = "Nested Router API", .version = "1.0.0" });
    defer app.deinit();

    const users = comptime Router.init(.{
        .prefix = "/users",
        .tags = &.{"users"},
        .routes = .{
            Route.get("/{id:int}", getUser, .{
                .name = "nested_user",
                .summary = "Nested user",
                .tags = &.{"detail"},
            }),
        },
    });

    const api = comptime Router.init(.{
        .prefix = "/api",
        .tags = &.{"api"},
        .routes = .{
            users,
            Route.get("/status", plainText, .{
                .name = "api_status",
                .summary = "API status",
            }),
        },
    });
    try app.includeRouter(api);

    var openapi = try app.handle(Request.init(.GET, "/openapi.json"));
    defer openapi.deinit(testing.allocator);

    try expectJsonEqual(
        \\{
        \\  "openapi": "3.1.0",
        \\  "info": {
        \\    "title": "Nested Router API",
        \\    "version": "1.0.0"
        \\  },
        \\  "paths": {
        \\    "/api/users/{id}": {
        \\      "get": {
        \\        "operationId": "nested_user",
        \\        "summary": "Nested user",
        \\        "tags": ["api", "users", "detail"],
        \\        "parameters": [
        \\          {"name": "id", "in": "path", "required": true, "schema": {"type": "integer"}},
        \\          {"name": "verbose", "in": "query", "required": false, "schema": {"anyOf": [{"type": "boolean"}, {"type": "null"}], "default": null}}
        \\        ],
        \\        "responses": {
        \\          "200": {
        \\            "description": "OK",
        \\            "content": {
        \\              "application/json": {
        \\                "schema": {"$ref": "#/components/schemas/TestUser"}
        \\              }
        \\            }
        \\          },
        \\          "422": {
        \\            "description": "Validation Error",
        \\            "content": {
        \\              "application/json": {
        \\                "schema": {"$ref": "#/components/schemas/ProblemDetail"}
        \\              }
        \\            }
        \\          }
        \\        }
        \\      }
        \\    },
        \\    "/api/status": {
        \\      "get": {
        \\        "operationId": "api_status",
        \\        "summary": "API status",
        \\        "tags": ["api"],
        \\        "responses": {
        \\          "200": {
        \\            "description": "OK",
        \\            "content": {
        \\              "text/plain; charset=utf-8": {
        \\                "schema": {"type": "string"}
        \\              }
        \\            }
        \\          }
        \\        }
        \\      }
        \\    }
        \\  },
        \\  "components": {
        \\    "schemas": {
        \\      "ProblemDetail": {
        \\        "type": "object",
        \\        "properties": {
        \\          "detail": {"type": "string"}
        \\        },
        \\        "required": ["detail"],
        \\        "additionalProperties": false
        \\      },
        \\      "TestUser": {
        \\        "type": "object",
        \\        "properties": {
        \\          "id": {"type": "integer"},
        \\          "email": {"type": "string"}
        \\        },
        \\        "required": ["id", "email"],
        \\        "additionalProperties": false
        \\      }
        \\    }
        \\  }
        \\}
    ,
        openapi.body.items,
    );
}

test "openapi snapshot includes form request body" {
    var app = ZAPI.init(testing.allocator, .{ .title = "Form API", .version = "1.0.0" });
    defer app.deinit();
    try app.route(Route.post("/login", login, .{
        .name = "login",
        .summary = "Login",
        .tags = &.{"auth"},
    }));

    var openapi = try app.handle(Request.init(.GET, "/openapi.json"));
    defer openapi.deinit(testing.allocator);

    try expectJsonEqual(
        \\{
        \\  "openapi": "3.1.0",
        \\  "info": {
        \\    "title": "Form API",
        \\    "version": "1.0.0"
        \\  },
        \\  "paths": {
        \\    "/login": {
        \\      "post": {
        \\        "operationId": "login",
        \\        "summary": "Login",
        \\        "tags": ["auth"],
        \\        "requestBody": {
        \\          "required": true,
        \\          "content": {
        \\            "application/x-www-form-urlencoded": {
        \\              "schema": {"$ref": "#/components/schemas/LoginForm"}
        \\            }
        \\          }
        \\        },
        \\        "responses": {
        \\          "200": {
        \\            "description": "OK",
        \\            "content": {
        \\              "application/json": {
        \\                "schema": {"$ref": "#/components/schemas/LoginResult"}
        \\              }
        \\            }
        \\          },
        \\          "422": {
        \\            "description": "Validation Error",
        \\            "content": {
        \\              "application/json": {
        \\                "schema": {"$ref": "#/components/schemas/ProblemDetail"}
        \\              }
        \\            }
        \\          }
        \\        }
        \\      }
        \\    }
        \\  },
        \\  "components": {
        \\    "schemas": {
        \\      "ProblemDetail": {
        \\        "type": "object",
        \\        "properties": {
        \\          "detail": {"type": "string"}
        \\        },
        \\        "required": ["detail"],
        \\        "additionalProperties": false
        \\      },
        \\      "LoginForm": {
        \\        "type": "object",
        \\        "properties": {
        \\          "username": {"type": "string"},
        \\          "password": {"type": "string"},
        \\          "remember": {"type": "boolean", "default": false},
        \\          "attempts": {"type": "integer", "default": 1}
        \\        },
        \\        "required": ["username", "password"],
        \\        "additionalProperties": false
        \\      },
        \\      "LoginResult": {
        \\        "type": "object",
        \\        "properties": {
        \\          "username": {"type": "string"},
        \\          "remember": {"type": "boolean"},
        \\          "attempts": {"type": "integer"}
        \\        },
        \\        "required": ["username", "remember", "attempts"],
        \\        "additionalProperties": false
        \\      }
        \\    }
        \\  }
        \\}
    ,
        openapi.body.items,
    );
}

test "openapi snapshot includes repeated form fields" {
    var app = ZAPI.init(testing.allocator, .{ .title = "Preferences API", .version = "1.0.0" });
    defer app.deinit();
    try app.route(Route.post("/preferences", preferences, .{
        .name = "save_preferences",
        .summary = "Save preferences",
        .tags = &.{"preferences"},
    }));

    var openapi = try app.handle(Request.init(.GET, "/openapi.json"));
    defer openapi.deinit(testing.allocator);

    try expectJsonEqual(
        \\{
        \\  "openapi": "3.1.0",
        \\  "info": {
        \\    "title": "Preferences API",
        \\    "version": "1.0.0"
        \\  },
        \\  "paths": {
        \\    "/preferences": {
        \\      "post": {
        \\        "operationId": "save_preferences",
        \\        "summary": "Save preferences",
        \\        "tags": ["preferences"],
        \\        "requestBody": {
        \\          "required": true,
        \\          "content": {
        \\            "application/x-www-form-urlencoded": {
        \\              "schema": {"$ref": "#/components/schemas/PreferencesForm"}
        \\            }
        \\          }
        \\        },
        \\        "responses": {
        \\          "200": {
        \\            "description": "OK",
        \\            "content": {
        \\              "application/json": {
        \\                "schema": {"$ref": "#/components/schemas/PreferencesResult"}
        \\              }
        \\            }
        \\          },
        \\          "422": {
        \\            "description": "Validation Error",
        \\            "content": {
        \\              "application/json": {
        \\                "schema": {"$ref": "#/components/schemas/ProblemDetail"}
        \\              }
        \\            }
        \\          }
        \\        }
        \\      }
        \\    }
        \\  },
        \\  "components": {
        \\    "schemas": {
        \\      "ProblemDetail": {
        \\        "type": "object",
        \\        "properties": {
        \\          "detail": {"type": "string"}
        \\        },
        \\        "required": ["detail"],
        \\        "additionalProperties": false
        \\      },
        \\      "PreferencesForm": {
        \\        "type": "object",
        \\        "properties": {
        \\          "username": {"type": "string"},
        \\          "tag": {"type": "array", "items": {"type": "string"}},
        \\          "level": {"type": "array", "items": {"type": "integer"}}
        \\        },
        \\        "required": ["username", "tag", "level"],
        \\        "additionalProperties": false
        \\      },
        \\      "PreferencesResult": {
        \\        "type": "object",
        \\        "properties": {
        \\          "username": {"type": "string"},
        \\          "tags": {"type": "array", "items": {"type": "string"}},
        \\          "levels": {"type": "array", "items": {"type": "integer"}}
        \\        },
        \\        "required": ["username", "tags", "levels"],
        \\        "additionalProperties": false
        \\      }
        \\    }
        \\  }
        \\}
    ,
        openapi.body.items,
    );
}

test "openapi snapshot includes multipart file request body" {
    var app = ZAPI.init(testing.allocator, .{ .title = "Upload API", .version = "1.0.0" });
    defer app.deinit();
    try app.route(Route.post("/profile", uploadProfile, .{
        .name = "upload_profile",
        .summary = "Upload profile",
        .tags = &.{"uploads"},
    }));

    var openapi = try app.handle(Request.init(.GET, "/openapi.json"));
    defer openapi.deinit(testing.allocator);

    try expectJsonEqual(
        \\{
        \\  "openapi": "3.1.0",
        \\  "info": {
        \\    "title": "Upload API",
        \\    "version": "1.0.0"
        \\  },
        \\  "paths": {
        \\    "/profile": {
        \\      "post": {
        \\        "operationId": "upload_profile",
        \\        "summary": "Upload profile",
        \\        "tags": ["uploads"],
        \\        "requestBody": {
        \\          "required": true,
        \\          "content": {
        \\            "multipart/form-data": {
        \\              "schema": {"$ref": "#/components/schemas/ProfileUpload"}
        \\            }
        \\          }
        \\        },
        \\        "responses": {
        \\          "200": {
        \\            "description": "OK",
        \\            "content": {
        \\              "application/json": {
        \\                "schema": {"$ref": "#/components/schemas/UploadResult"}
        \\              }
        \\            }
        \\          },
        \\          "422": {
        \\            "description": "Validation Error",
        \\            "content": {
        \\              "application/json": {
        \\                "schema": {"$ref": "#/components/schemas/ProblemDetail"}
        \\              }
        \\            }
        \\          }
        \\        }
        \\      }
        \\    }
        \\  },
        \\  "components": {
        \\    "schemas": {
        \\      "ProblemDetail": {
        \\        "type": "object",
        \\        "properties": {
        \\          "detail": {"type": "string"}
        \\        },
        \\        "required": ["detail"],
        \\        "additionalProperties": false
        \\      },
        \\      "ProfileUpload": {
        \\        "type": "object",
        \\        "properties": {
        \\          "username": {"type": "string"},
        \\          "avatar": {"type": "string", "format": "binary"}
        \\        },
        \\        "required": ["username", "avatar"],
        \\        "additionalProperties": false
        \\      },
        \\      "UploadResult": {
        \\        "type": "object",
        \\        "properties": {
        \\          "username": {"type": "string"},
        \\          "filename": {"type": "string"},
        \\          "content_type": {"type": "string"},
        \\          "size": {"type": "integer"}
        \\        },
        \\        "required": ["username", "filename", "content_type", "size"],
        \\        "additionalProperties": false
        \\      }
        \\    }
        \\  }
        \\}
    ,
        openapi.body.items,
    );
}

test "openapi snapshot includes repeated multipart file fields" {
    var app = ZAPI.init(testing.allocator, .{ .title = "Gallery API", .version = "1.0.0" });
    defer app.deinit();
    try app.route(Route.post("/gallery", uploadGallery, .{
        .name = "upload_gallery",
        .summary = "Upload gallery",
        .tags = &.{"uploads"},
    }));

    var openapi = try app.handle(Request.init(.GET, "/openapi.json"));
    defer openapi.deinit(testing.allocator);

    try expectJsonEqual(
        \\{
        \\  "openapi": "3.1.0",
        \\  "info": {
        \\    "title": "Gallery API",
        \\    "version": "1.0.0"
        \\  },
        \\  "paths": {
        \\    "/gallery": {
        \\      "post": {
        \\        "operationId": "upload_gallery",
        \\        "summary": "Upload gallery",
        \\        "tags": ["uploads"],
        \\        "requestBody": {
        \\          "required": true,
        \\          "content": {
        \\            "multipart/form-data": {
        \\              "schema": {"$ref": "#/components/schemas/GalleryUpload"}
        \\            }
        \\          }
        \\        },
        \\        "responses": {
        \\          "200": {
        \\            "description": "OK",
        \\            "content": {
        \\              "application/json": {
        \\                "schema": {"$ref": "#/components/schemas/GalleryResult"}
        \\              }
        \\            }
        \\          },
        \\          "422": {
        \\            "description": "Validation Error",
        \\            "content": {
        \\              "application/json": {
        \\                "schema": {"$ref": "#/components/schemas/ProblemDetail"}
        \\              }
        \\            }
        \\          }
        \\        }
        \\      }
        \\    }
        \\  },
        \\  "components": {
        \\    "schemas": {
        \\      "ProblemDetail": {
        \\        "type": "object",
        \\        "properties": {
        \\          "detail": {"type": "string"}
        \\        },
        \\        "required": ["detail"],
        \\        "additionalProperties": false
        \\      },
        \\      "GalleryUpload": {
        \\        "type": "object",
        \\        "properties": {
        \\          "username": {"type": "string"},
        \\          "photos": {"type": "array", "items": {"type": "string", "format": "binary"}}
        \\        },
        \\        "required": ["username", "photos"],
        \\        "additionalProperties": false
        \\      },
        \\      "GalleryResult": {
        \\        "type": "object",
        \\        "properties": {
        \\          "username": {"type": "string"},
        \\          "first_filename": {"type": "string"},
        \\          "second_filename": {"type": "string"},
        \\          "total_size": {"type": "integer"}
        \\        },
        \\        "required": ["username", "first_filename", "second_filename", "total_size"],
        \\        "additionalProperties": false
        \\      }
        \\    }
        \\  }
        \\}
    ,
        openapi.body.items,
    );
}

test "returns not found and method not allowed like Starlette-style routing" {
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    try app.route(Route.get("/", hello, .{}));

    var missing = try app.handle(Request.init(.GET, "/missing"));
    defer missing.deinit(testing.allocator);
    try testing.expectEqual(Status.not_found, missing.status);
    try testing.expectEqualStrings("22", missing.header("content-length").?);

    var wrong_method = try app.handle(Request.init(.POST, "/"));
    defer wrong_method.deinit(testing.allocator);
    try testing.expectEqual(Status.method_not_allowed, wrong_method.status);
    try testing.expectEqualStrings("HEAD, GET, OPTIONS", wrong_method.header("allow").?);
    try testing.expectEqualStrings("application/json", wrong_method.header("content-type").?);
    try testing.expectEqualStrings("{\"detail\":\"Method not allowed\"}", wrong_method.body.items);
    try testing.expectEqualStrings("31", wrong_method.header("content-length").?);

    var automatic_options = try app.handle(Request.init(.OPTIONS, "/"));
    defer automatic_options.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, automatic_options.status);
    try testing.expectEqualStrings("HEAD, GET, OPTIONS", automatic_options.header("allow").?);
    try testing.expectEqualStrings("0", automatic_options.header("content-length").?);
    try testing.expectEqual(@as(usize, 0), automatic_options.body.items.len);
}

test "method not allowed allow header deduplicates explicit and implicit head" {
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    try app.route(Route.head("/resource", explicitHead, .{}));
    try app.route(Route.get("/resource", plainText, .{}));

    var wrong_method = try app.handle(Request.init(.POST, "/resource"));
    defer wrong_method.deinit(testing.allocator);
    try testing.expectEqual(Status.method_not_allowed, wrong_method.status);
    try testing.expectEqualStrings("HEAD, GET, OPTIONS", wrong_method.header("allow").?);
}

test "explicit options routes override automatic options" {
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    try app.route(Route.get("/resource", plainText, .{}));
    try app.route(Route.options("/resource", echoRequestMethod, .{}));

    var options = try app.handle(Request.init(.OPTIONS, "/resource"));
    defer options.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, options.status);
    try testing.expect(options.header("allow") == null);
    try testing.expectEqualStrings("{\"method\":\"OPTIONS\"}", options.body.items);

    var wrong_method = try app.handle(Request.init(.POST, "/resource"));
    defer wrong_method.deinit(testing.allocator);
    try testing.expectEqual(Status.method_not_allowed, wrong_method.status);
    try testing.expectEqualStrings("HEAD, GET, OPTIONS", wrong_method.header("allow").?);
}

test "response status helpers classify status code ranges" {
    try testing.expectEqual(@as(u16, 100), Status.continue_.code());
    try testing.expectEqual(@as(u16, 102), Status.processing.code());
    try testing.expectEqual(@as(u16, 103), Status.early_hints.code());
    try testing.expectEqual(@as(u16, 203), Status.non_authoritative_information.code());
    try testing.expectEqual(@as(u16, 207), Status.multi_status.code());
    try testing.expectEqual(@as(u16, 418), Status.im_a_teapot.code());
    try testing.expectEqual(@as(u16, 421), Status.misdirected_request.code());
    try testing.expectEqual(@as(u16, 503), Status.service_unavailable.code());
    try testing.expectEqual(@as(u16, 511), Status.network_authentication_required.code());
    const custom_status = Status.fromCode(299);
    try testing.expectEqual(@as(u16, 299), custom_status.code());
    try testing.expectEqualStrings("Continue", Status.continue_.reason());
    try testing.expectEqualStrings("Processing", Status.processing.reason());
    try testing.expectEqualStrings("Early Hints", Status.early_hints.reason());
    try testing.expectEqualStrings("Non-Authoritative Information", Status.non_authoritative_information.reason());
    try testing.expectEqualStrings("Multi-Status", Status.multi_status.reason());
    try testing.expectEqualStrings("Use Proxy", Status.use_proxy.reason());
    try testing.expectEqualStrings("I'm a Teapot", Status.im_a_teapot.reason());
    try testing.expectEqualStrings("Misdirected Request", Status.misdirected_request.reason());
    try testing.expectEqualStrings("Service Unavailable", Status.service_unavailable.reason());
    try testing.expectEqualStrings("Network Authentication Required", Status.network_authentication_required.reason());
    try testing.expectEqualStrings("Unknown Status", custom_status.reason());
    try testing.expect(Status.continue_.isInformational());
    try testing.expect(Status.early_hints.isInformational());
    try testing.expect(Status.multi_status.isSuccess());
    try testing.expect(custom_status.isSuccess());
    try testing.expect(!custom_status.isError());
    try testing.expect(Status.multiple_choices.isRedirect());
    try testing.expect(Status.use_proxy.isRedirect());
    try testing.expect(Status.im_a_teapot.isClientError());
    try testing.expect(Status.misdirected_request.isClientError());
    try testing.expect(Status.service_unavailable.isServerError());
    try testing.expect(Status.network_authentication_required.isServerError());
    try testing.expect(Status.ok.isSuccess());
    try testing.expect(!Status.ok.isError());
    try testing.expect(Status.temporary_redirect.isRedirect());
    try testing.expect(Status.not_found.isClientError());
    try testing.expect(Status.internal_server_error.isServerError());
    try testing.expect(Status.internal_server_error.isError());
    try testing.expect(!Status.ok.isInformational());

    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    try app.route(Route.get("/", plainText, .{}));
    try app.route(Route.get("/redirect", redirectToUsers, .{}));
    try app.route(Route.get("/unhandled", unhandledFailingRoute, .{}));
    try app.route(Route.get("/custom-status", customExtensionStatus, .{ .status = Status.fromCode(299) }));

    var ok = try app.handle(Request.init(.GET, "/"));
    defer ok.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 200), ok.statusCode());
    try testing.expectEqualStrings("OK", ok.reason());
    try testing.expect(ok.isSuccess());
    try testing.expect(!ok.isRedirect());
    try testing.expect(!ok.isError());
    try ok.expectStatus(.ok);
    try ok.expectSuccess();
    try ok.raiseForStatus();

    var redirect = try app.handle(Request.init(.GET, "/redirect"));
    defer redirect.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 307), redirect.statusCode());
    try testing.expectEqualStrings("Temporary Redirect", redirect.reason());
    try testing.expect(redirect.isRedirect());
    try testing.expect(!redirect.isSuccess());
    try testing.expect(!redirect.isError());
    try redirect.expectStatus(.temporary_redirect);
    try testing.expectError(error.UnexpectedStatus, redirect.expectSuccess());
    try redirect.raiseForStatus();

    var missing = try app.handle(Request.init(.GET, "/missing"));
    defer missing.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 404), missing.statusCode());
    try testing.expectEqualStrings("Not Found", missing.reason());
    try testing.expect(missing.isClientError());
    try testing.expect(missing.isError());
    try testing.expect(!missing.isServerError());
    try missing.expectStatus(.not_found);
    try testing.expectError(error.UnexpectedStatus, missing.expectStatus(.ok));
    try testing.expectError(error.UnexpectedStatus, missing.expectSuccess());
    try testing.expectError(error.ResponseStatusError, missing.raiseForStatus());

    var server_error = try app.handle(Request.init(.GET, "/unhandled"));
    defer server_error.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 500), server_error.statusCode());
    try testing.expectEqualStrings("Internal Server Error", server_error.reason());
    try testing.expect(server_error.isServerError());
    try testing.expect(server_error.isError());
    try testing.expect(!server_error.isClientError());
    try server_error.expectStatus(.internal_server_error);
    try testing.expectError(error.UnexpectedStatus, server_error.expectSuccess());
    try testing.expectError(error.ResponseStatusError, server_error.raiseForStatus());

    var custom_response = try app.handle(Request.init(.GET, "/custom-status"));
    defer custom_response.deinit(testing.allocator);
    try custom_response.expectStatus(Status.fromCode(299));
    try testing.expectEqual(@as(u16, 299), custom_response.statusCode());
    try testing.expectEqualStrings("Unknown Status", custom_response.reason());
    try testing.expect(custom_response.isSuccess());
    try custom_response.raiseForStatus();
    try testing.expectEqualStrings("custom", custom_response.body.items);
}

test "supports trace routes through app test client and std.http adapter" {
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    try app.route(Route.trace("/trace", echoRequestMethod, .{}));

    var direct = try app.handle(Request.init(.TRACE, "/trace"));
    defer direct.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, direct.status);
    try testing.expectEqualStrings("{\"method\":\"TRACE\"}", direct.body.items);

    var wrong_method = try app.handle(Request.init(.GET, "/trace"));
    defer wrong_method.deinit(testing.allocator);
    try testing.expectEqual(Status.method_not_allowed, wrong_method.status);
    try testing.expectEqualStrings("TRACE, OPTIONS", wrong_method.header("allow").?);

    var client = TestClient.init(testing.allocator, &app, .{});
    defer client.deinit();
    var client_response = try client.trace("/trace");
    defer client_response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, client_response.status);
    try testing.expectEqualStrings("{\"method\":\"TRACE\"}", client_response.text());

    const raw_request =
        "TRACE /trace HTTP/1.1\r\n" ++
        "host: example.test\r\n" ++
        "\r\n";

    var input = std.Io.Reader.fixed(raw_request);
    var output = std.Io.Writer.Allocating.init(testing.allocator);
    defer output.deinit();

    var server = std.http.Server.init(&input, &output.writer);
    var http_request = try server.receiveHead();
    try app.handleHttp(&http_request);

    try testing.expect(std.mem.indexOf(u8, output.written(), "HTTP/1.1 200 OK\r\n") != null);
    try testing.expect(std.mem.endsWith(u8, output.written(), "{\"method\":\"TRACE\"}"));
}

test "supports connect routes through app test client and std.http adapter" {
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    try app.route(Route.connect("/connect", echoRequestMethod, .{}));
    try app.route(Route.get("/connect-query", echoRequestTarget, .{}));
    try app.route(Route.connect("/connect-query", echoRequestTarget, .{}));

    var direct = try app.handle(Request.init(.CONNECT, "/connect"));
    defer direct.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, direct.status);
    try testing.expectEqualStrings("{\"method\":\"CONNECT\"}", direct.body.items);

    var wrong_method = try app.handle(Request.init(.GET, "/connect"));
    defer wrong_method.deinit(testing.allocator);
    try testing.expectEqual(Status.method_not_allowed, wrong_method.status);
    try testing.expectEqualStrings("CONNECT, OPTIONS", wrong_method.header("allow").?);

    var client = TestClient.init(testing.allocator, &app, .{});
    defer client.deinit();
    var client_response = try client.connect("/connect");
    defer client_response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, client_response.status);
    try testing.expectEqualStrings("{\"method\":\"CONNECT\"}", client_response.text());

    var client_query = try client.connectQuery("/connect-query?existing=1", .{ .mode = "tunnel" });
    defer client_query.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, client_query.status);
    try testing.expectEqualStrings("{\"scheme\":\"http\",\"host\":\"testserver\",\"root_path\":\"\",\"path\":\"/connect-query\",\"query\":\"existing=1&mode=tunnel\"}", client_query.body.items);

    const raw_request =
        "CONNECT /connect HTTP/1.1\r\n" ++
        "host: example.test\r\n" ++
        "\r\n";

    var input = std.Io.Reader.fixed(raw_request);
    var output = std.Io.Writer.Allocating.init(testing.allocator);
    defer output.deinit();

    var server = std.http.Server.init(&input, &output.writer);
    var http_request = try server.receiveHead();
    try app.handleHttp(&http_request);

    try testing.expect(std.mem.indexOf(u8, output.written(), "HTTP/1.1 200 OK\r\n") != null);
    try testing.expect(std.mem.endsWith(u8, output.written(), "{\"method\":\"CONNECT\"}"));
}

test "supports text redirect custom payload and head responses" {
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    try app.route(Route.get("/", plainText, .{}));
    try app.route(Route.get("/html", htmlPage, .{}));
    try app.route(Route.get("/bytes", binaryData, .{}));
    try app.route(Route.get("/json", explicitJson, .{}));
    try app.route(Route.get("/raw-json", explicitRawJson, .{}));
    try app.route(Route.get("/redirect", redirectToUsers, .{}));
    try app.route(Route.get("/quoted-redirect", redirectToQuotedPath, .{}));
    try app.route(Route.get("/quoted/{rest:path}", getPathTail, .{}));
    try app.route(Route.get("/explicit-content-type-text", explicitContentTypeText, .{}));
    try app.route(Route.get("/explicit-content-type-payload", explicitContentTypePayload, .{}));
    try app.route(Route.post("/custom", customPayload, .{}));
    try app.route(Route.delete("/empty", noContentPayload, .{ .status = .no_content }));
    try app.route(Route.get("/informational", informationalPayload, .{}));

    var text = try app.handle(Request.init(.GET, "/"));
    defer text.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, text.status);
    try testing.expectEqualStrings("text/plain; charset=utf-8", text.header("content-type").?);
    try testing.expectEqualStrings("text/plain", text.contentType().?);
    try testing.expect(text.hasContentType("text/plain"));
    try testing.expect(text.hasContentType("text/plain; charset=ignored"));
    try testing.expect(!text.hasContentType("application/json"));
    try testing.expectEqualStrings("12", text.header("content-length").?);
    try testing.expectEqualStrings("Hello, world", text.body.items);

    var head = try app.handle(Request.init(.HEAD, "/"));
    defer head.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, head.status);
    try testing.expectEqualStrings("text/plain; charset=utf-8", head.header("content-type").?);
    try testing.expectEqualStrings("12", head.header("content-length").?);
    try testing.expectEqual(@as(usize, 0), head.body.items.len);

    try app.route(Route.head("/head", explicitHead, .{}));
    try app.route(Route.options("/head", plainText, .{}));

    var explicit_head = try app.handle(Request.init(.HEAD, "/head"));
    defer explicit_head.deinit(testing.allocator);
    try testing.expectEqual(Status.accepted, explicit_head.status);
    try testing.expectEqualStrings("explicit", explicit_head.header("x-head").?);
    try testing.expectEqualStrings("9", explicit_head.header("content-length").?);
    try testing.expectEqual(@as(usize, 0), explicit_head.body.items.len);

    var options = try app.handle(Request.init(.OPTIONS, "/head"));
    defer options.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, options.status);
    try testing.expectEqualStrings("12", options.header("content-length").?);
    try testing.expectEqualStrings("Hello, world", options.body.items);
    try testing.expectEqualStrings("Hello, world", options.text());
    try testing.expectEqualStrings("Hello, world", options.content());

    var html = try app.handle(Request.init(.GET, "/html"));
    defer html.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, html.status);
    try testing.expectEqualStrings("text/html; charset=utf-8", html.header("content-type").?);
    try testing.expectEqualStrings("14", html.header("content-length").?);
    try testing.expectEqualStrings("yes", html.header("x-html").?);
    try testing.expectEqualStrings("<h1>Hello</h1>", html.body.items);

    var bytes = try app.handle(Request.init(.GET, "/bytes"));
    defer bytes.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, bytes.status);
    try testing.expectEqualStrings("application/x-zapi-bytes", bytes.header("content-type").?);
    try testing.expectEqualStrings("6", bytes.header("content-length").?);
    try testing.expectEqualStrings("yes", bytes.header("x-bytes").?);
    try testing.expectEqualSlices(u8, "\x00\x01zapi", bytes.body.items);
    try testing.expectEqualSlices(u8, "\x00\x01zapi", bytes.bytes());
    try testing.expectEqualSlices(u8, "\x00\x01zapi", bytes.content());

    var json = try app.handle(Request.init(.GET, "/json"));
    defer json.deinit(testing.allocator);
    try testing.expectEqual(Status.accepted, json.status);
    try testing.expectEqualStrings("application/json", json.header("content-type").?);
    try testing.expectEqualStrings("application/json", json.contentType().?);
    try testing.expect(json.hasContentType("application/json"));
    try testing.expectEqualStrings("22", json.header("content-length").?);
    try testing.expectEqualStrings("yes", json.header("x-json").?);
    try testing.expectEqualStrings("{\"message\":\"explicit\"}", json.body.items);

    var raw_json = try app.handle(Request.init(.GET, "/raw-json"));
    defer raw_json.deinit(testing.allocator);
    try testing.expectEqual(Status.created, raw_json.status);
    try testing.expectEqualStrings("application/json", raw_json.header("content-type").?);
    try testing.expectEqualStrings("17", raw_json.header("content-length").?);
    try testing.expectEqualStrings("raw", raw_json.header("x-json").?);
    try testing.expectEqualStrings("{\"message\":\"raw\"}", raw_json.body.items);

    var redirect = try app.handle(Request.init(.GET, "/redirect"));
    defer redirect.deinit(testing.allocator);
    try testing.expectEqual(Status.temporary_redirect, redirect.status);
    try testing.expectEqualStrings("/users", redirect.header("location").?);
    try testing.expectEqualStrings("0", redirect.header("content-length").?);

    var quoted_redirect = try app.handle(Request.init(.GET, "/quoted-redirect"));
    defer quoted_redirect.deinit(testing.allocator);
    try testing.expectEqual(Status.temporary_redirect, quoted_redirect.status);
    try testing.expectEqualStrings("/quoted/I%20%E2%99%A5%20Zapi/", quoted_redirect.header("location").?);

    var client = TestClient.init(testing.allocator, &app, .{});
    defer client.deinit();
    var followed_quoted_redirect = try client.get("/quoted-redirect");
    defer followed_quoted_redirect.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, followed_quoted_redirect.status);
    try testing.expectEqualStrings("http://testserver/quoted/I%20%E2%99%A5%20Zapi/", followed_quoted_redirect.requestUrl().?);
    try testing.expectEqualStrings("{\"value\":\"I \xe2\x99\xa5 Zapi/\"}", followed_quoted_redirect.text());

    var explicit_text_type = try app.handle(Request.init(.GET, "/explicit-content-type-text"));
    defer explicit_text_type.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, explicit_text_type.status);
    try testing.expectEqualStrings("text/x-zapi", explicit_text_type.header("content-type").?);
    try testing.expectEqualStrings("typed", explicit_text_type.body.items);

    var explicit_payload_type = try app.handle(Request.init(.GET, "/explicit-content-type-payload"));
    defer explicit_payload_type.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, explicit_payload_type.status);
    try testing.expectEqualStrings("text/x-payload", explicit_payload_type.header("content-type").?);
    try testing.expectEqualStrings("payload", explicit_payload_type.body.items);

    var custom = try app.handle(Request.init(.POST, "/custom"));
    defer custom.deinit(testing.allocator);
    try testing.expectEqual(Status.accepted, custom.status);
    try testing.expectEqualStrings("text/custom", custom.header("content-type").?);
    try testing.expectEqualStrings("8", custom.header("content-length").?);
    try testing.expectEqualStrings("ok", custom.header("x-zapi").?);
    try testing.expectEqualStrings("accepted", custom.body.items);

    var empty = try app.handle(Request.init(.DELETE, "/empty"));
    defer empty.deinit(testing.allocator);
    try testing.expectEqual(Status.no_content, empty.status);
    try testing.expectEqualStrings("kept", empty.header("x-empty").?);
    try testing.expect(empty.header("content-type") == null);
    try testing.expect(empty.contentType() == null);
    try testing.expect(!empty.hasContentType("application/json"));
    try testing.expect(empty.header("content-length") == null);
    try testing.expectEqual(@as(usize, 0), empty.body.items.len);

    var informational = try app.handle(Request.init(.GET, "/informational"));
    defer informational.deinit(testing.allocator);
    try testing.expectEqual(Status.early_hints, informational.status);
    try testing.expectEqualStrings("kept", informational.header("x-hint").?);
    try testing.expect(informational.header("content-type") == null);
    try testing.expect(informational.header("content-length") == null);
    try testing.expectEqual(@as(usize, 0), informational.body.items.len);
}

test "supports template responses" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "pages");
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "pages/home.html",
        .data = "<title>{{ title }}</title><main>{{{ body }}}</main>",
    });
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "pages/missing-value.html",
        .data = "<p>{{ missing }}</p>",
    });

    var state = TemplateState{ .dir = tmp.dir };
    var app = ZAPI.init(testing.allocator, .{ .io = testing.io });
    defer app.deinit();
    app.setState(&state);
    try app.route(Route.get("/template", templatePage, .{}));
    try app.route(Route.get("/missing-template-value", missingTemplateValue, .{}));

    var response = try app.handle(Request.init(.GET, "/template"));
    defer response.deinit(testing.allocator);
    try testing.expectEqual(Status.accepted, response.status);
    try testing.expectEqualStrings("text/html; charset=utf-8", response.header("content-type").?);
    try testing.expectEqualStrings("yes", response.header("x-template").?);
    try testing.expectEqualStrings("<title>Hello &lt;Zig&gt;</title><main><strong>trusted</strong></main>", response.body.items);

    var head = try app.handle(Request.init(.HEAD, "/template"));
    defer head.deinit(testing.allocator);
    try testing.expectEqual(Status.accepted, head.status);
    try testing.expectEqualStrings("69", head.header("content-length").?);
    try testing.expectEqual(@as(usize, 0), head.body.items.len);

    var missing = try app.handle(Request.init(.GET, "/missing-template-value"));
    defer missing.deinit(testing.allocator);
    try testing.expectEqual(Status.internal_server_error, missing.status);
    try testing.expectEqualStrings("{\"detail\":\"Internal server error\"}", missing.body.items);
}

test "supports event stream responses" {
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    try app.route(Route.get("/events", richEventStream, .{}));

    const expected =
        ": connected\n" ++
        "\n" ++
        "event: message\n" ++
        "id: 42\n" ++
        "retry: 1500\n" ++
        "data: hello\n" ++
        "data: world\n" ++
        "data: again\n" ++
        "\n" ++
        "data: \n" ++
        "\n";

    var response = try app.handle(Request.init(.GET, "/events"));
    defer response.deinit(testing.allocator);
    try testing.expectEqual(Status.accepted, response.status);
    try testing.expectEqualStrings("text/event-stream", response.header("content-type").?);
    try testing.expectEqualStrings("yes", response.header("x-events").?);
    try testing.expectEqualStrings(expected, response.body.items);

    var head = try app.handle(Request.init(.HEAD, "/events"));
    defer head.deinit(testing.allocator);
    try testing.expectEqual(Status.accepted, head.status);
    try testing.expectEqualStrings("92", head.header("content-length").?);
    try testing.expectEqual(@as(usize, 0), head.body.items.len);
}

test "supports transport streaming responses" {
    const chunks = [_][]const u8{ "hello ", "stream" };

    var state = StreamingState{ .chunks = &chunks };
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    app.setState(&state);
    try app.route(Route.get("/stream", streamingPlainText, .{}));

    var response = try app.handle(Request.init(.GET, "/stream"));
    defer response.deinit(testing.allocator);
    try testing.expectEqual(Status.accepted, response.status);
    try testing.expectEqualStrings("text/plain; charset=utf-8", response.header("content-type").?);
    try testing.expectEqualStrings("yes", response.header("x-stream").?);
    try testing.expectEqualStrings("12", response.header("content-length").?);
    try testing.expectEqualStrings("hello stream", response.body.items);
    try testing.expectEqual(@as(usize, 2), state.writes);

    var head = try app.handle(Request.init(.HEAD, "/stream"));
    defer head.deinit(testing.allocator);
    try testing.expectEqual(Status.accepted, head.status);
    try testing.expectEqualStrings("12", head.header("content-length").?);
    try testing.expectEqual(@as(usize, 0), head.body.items.len);
    try testing.expectEqual(@as(usize, 4), state.writes);

    var http_state = StreamingState{ .chunks = &chunks };
    var http_app = ZAPI.init(testing.allocator, .{});
    defer http_app.deinit();
    http_app.setState(&http_state);
    try http_app.route(Route.get("/stream", streamingPlainText, .{}));

    const raw_request =
        "GET /stream HTTP/1.1\r\n" ++
        "host: example.test\r\n" ++
        "\r\n";

    var input = std.Io.Reader.fixed(raw_request);
    var output = std.Io.Writer.Allocating.init(testing.allocator);
    defer output.deinit();

    var server = std.http.Server.init(&input, &output.writer);
    var http_request = try server.receiveHead();
    try http_app.handleHttp(&http_request);

    try testing.expect(std.mem.indexOf(u8, output.written(), "HTTP/1.1 202 Accepted\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, output.written(), "transfer-encoding: chunked\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, output.written(), "content-length:") == null);
    try testing.expect(std.mem.indexOf(u8, output.written(), "6\r\nhello \r\n") != null);
    try testing.expect(std.mem.indexOf(u8, output.written(), "6\r\nstream\r\n") != null);
    try testing.expect(std.mem.endsWith(u8, output.written(), "0\r\n\r\n"));
    try testing.expectEqual(@as(usize, 2), http_state.writes);
}

test "supports websocket routes through std.http adapter" {
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    const router = Router.init(.{
        .routes = .{
            Route.websocket("/ws/{room}", websocketEcho, .{ .name = "ws_room" }),
            Route.websocket("/ws-double", websocketDoubleEcho, .{}),
            Route.websocket("/ws-json", websocketJsonEcho, .{}),
            Route.websocket("/ws-scope", websocketRequestEcho, .{}),
            Route.get("/http", plainText, .{}),
        },
    });
    try app.includeRouter(router);

    const ws_path = try app.urlPathFor("ws_room", .{ .room = "zig" });
    defer testing.allocator.free(ws_path);
    try testing.expectEqualStrings("/ws/zig", ws_path);

    var openapi = try app.handle(Request.init(.GET, "/openapi.json"));
    defer openapi.deinit(testing.allocator);
    try testing.expect(std.mem.indexOf(u8, openapi.body.items, "/ws/{room}") == null);
    try testing.expect(std.mem.indexOf(u8, openapi.body.items, "/http") != null);

    const raw_request_bytes =
        "GET /ws/zig HTTP/1.1\r\n" ++
        "host: example.test\r\n" ++
        "upgrade: websocket\r\n" ++
        "connection: upgrade\r\n" ++
        "sec-websocket-key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ++
        "\r\n" ++
        "\x81\x84\x01\x02\x03\x04qkmc";
    var raw_request: [raw_request_bytes.len]u8 = raw_request_bytes.*;

    var input = std.Io.Reader.fixed(raw_request[0..]);
    var output = std.Io.Writer.Allocating.init(testing.allocator);
    defer output.deinit();

    var server = std.http.Server.init(&input, &output.writer);
    var http_request = try server.receiveHead();
    try app.handleHttp(&http_request);

    try testing.expect(std.mem.indexOf(u8, output.written(), "HTTP/1.1 101 Switching Protocols\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, output.written(), "upgrade: websocket\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, output.written(), "sec-websocket-accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n") != null);
    try testing.expect(std.mem.endsWith(u8, output.written(), "\x81\x08zig:ping"));

    var client = TestClient.init(testing.allocator, &app, .{});
    defer client.deinit();
    var exchange = try client.websocketText("/ws/zig", "pong");
    defer exchange.deinit(testing.allocator);
    try testing.expectEqual(Status.switching_protocols, exchange.status);
    try exchange.expectStatus(.switching_protocols);
    try testing.expectError(error.UnexpectedStatus, exchange.expectStatus(.ok));
    try testing.expectEqual(@as(u16, 101), exchange.statusCode());
    try testing.expectEqualStrings("Switching Protocols", exchange.reason());
    try testing.expect(exchange.hasHeader("Upgrade"));
    try testing.expect(!exchange.hasHeader("x-missing"));
    try testing.expectEqualStrings("websocket", exchange.header("upgrade").?);
    const upgrade_headers = try exchange.headerValues(testing.allocator, "Upgrade");
    defer testing.allocator.free(upgrade_headers);
    try testing.expectEqual(@as(usize, 1), upgrade_headers.len);
    try testing.expectEqualStrings("websocket", upgrade_headers[0]);
    const missing_headers = try exchange.headerValues(testing.allocator, "x-missing");
    defer testing.allocator.free(missing_headers);
    try testing.expectEqual(@as(usize, 0), missing_headers.len);
    try testing.expect(exchange.message != null);
    try testing.expectEqual(std.http.Server.WebSocket.Opcode.text, exchange.message.?.opcode);
    try testing.expectEqualStrings("zig:pong", exchange.message.?.data);
    try testing.expectEqualStrings("zig:pong", exchange.text().?);
    try testing.expect(exchange.binary() == null);
    try testing.expectEqual(@as(usize, 1), exchange.messages.items.len);
    try testing.expectEqualStrings("zig:pong", exchange.messages.items[0].data);

    var scripted = try client.websocketExchange("/ws-double", &.{
        .{ .opcode = .text, .data = "first" },
        .{ .opcode = .binary, .data = "second" },
    });
    defer scripted.deinit(testing.allocator);
    try testing.expectEqual(Status.switching_protocols, scripted.status);
    try testing.expectEqual(@as(usize, 2), scripted.messages.items.len);
    try testing.expectEqual(std.http.Server.WebSocket.Opcode.text, scripted.messages.items[0].opcode);
    try testing.expectEqualStrings("first", scripted.messages.items[0].data);
    try testing.expectEqual(std.http.Server.WebSocket.Opcode.binary, scripted.messages.items[1].opcode);
    try testing.expectEqualStrings("second", scripted.messages.items[1].data);
    try testing.expectEqualStrings("first", scripted.message.?.data);
    try testing.expectEqualStrings("first", scripted.text().?);
    try testing.expect(scripted.binary() == null);
    const scripted_text_messages = try scripted.textMessages(testing.allocator);
    defer testing.allocator.free(scripted_text_messages);
    try testing.expectEqual(@as(usize, 1), scripted_text_messages.len);
    try testing.expectEqualStrings("first", scripted_text_messages[0]);
    const scripted_binary_messages = try scripted.binaryMessages(testing.allocator);
    defer testing.allocator.free(scripted_binary_messages);
    try testing.expectEqual(@as(usize, 1), scripted_binary_messages.len);
    try testing.expectEqualStrings("second", scripted_binary_messages[0]);

    var json_exchange = try client.websocketJsonValueWithHeaders("/ws-json", WebSocketJsonInput{
        .name = "ada",
        .count = 3,
    }, &.{.{ .name = "x-token", .value = "secret" }});
    defer json_exchange.deinit(testing.allocator);
    try testing.expectEqual(Status.switching_protocols, json_exchange.status);
    try testing.expectEqualStrings("{\"name\":\"ada\",\"count\":3,\"token\":\"secret\"}", json_exchange.text().?);
    var json_payload = try json_exchange.json(WebSocketJsonOutput, testing.allocator);
    defer json_payload.deinit();
    try testing.expectEqualStrings("ada", json_payload.value.name);
    try testing.expectEqual(@as(u8, 3), json_payload.value.count);
    try testing.expectEqualStrings("secret", json_payload.value.token.?);

    var raw_json_exchange = try client.websocketJson("/ws-json", "{\"name\":\"grace\",\"count\":4}");
    defer raw_json_exchange.deinit(testing.allocator);
    var raw_json_payload = try raw_json_exchange.json(WebSocketJsonOutput, testing.allocator);
    defer raw_json_payload.deinit();
    try testing.expectEqualStrings("grace", raw_json_payload.value.name);
    try testing.expectEqual(@as(u8, 4), raw_json_payload.value.count);
    try testing.expect(raw_json_payload.value.token == null);

    var scoped_client = TestClient.init(testing.allocator, &app, .{ .base_url = "https://example.test/root" });
    defer scoped_client.deinit();
    try scoped_client.queryParam("default", "yes");
    try scoped_client.cookie("theme", "dark");
    var scoped = try scoped_client.websocketTextWithHeaders("/root/ws-scope?request=1", "scoped", &.{.{ .name = "x-token", .value = "secret" }});
    defer scoped.deinit(testing.allocator);
    try testing.expectEqual(Status.switching_protocols, scoped.status);
    try testing.expectEqualStrings("/ws-scope|default=yes&request=1|example.test|theme=dark|secret|scoped", scoped.message.?.data);
    try testing.expectEqualStrings("/ws-scope|default=yes&request=1|example.test|theme=dark|secret|scoped", scoped.text().?);

    const plain_request =
        "GET /ws/zig HTTP/1.1\r\n" ++
        "host: example.test\r\n" ++
        "\r\n";
    var plain_input = std.Io.Reader.fixed(plain_request);
    var plain_output = std.Io.Writer.Allocating.init(testing.allocator);
    defer plain_output.deinit();

    var plain_server = std.http.Server.init(&plain_input, &plain_output.writer);
    var plain_http_request = try plain_server.receiveHead();
    try app.handleHttp(&plain_http_request);

    try testing.expect(std.mem.indexOf(u8, plain_output.written(), "HTTP/1.1 426 Upgrade Required\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, plain_output.written(), "upgrade: websocket\r\n") != null);
    try testing.expect(std.mem.endsWith(u8, plain_output.written(), "WebSocket upgrade required"));
}

test "response payload conditional requests return not modified" {
    const last_modified = try httpDateAlloc(testing.allocator, conditional_last_modified_seconds);
    defer testing.allocator.free(last_modified);

    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    try app.route(Route.get("/conditional", conditionalPayload, .{}));
    try app.route(Route.post("/conditional", conditionalPayload, .{}));
    try app.route(Route.get("/last-modified", conditionalLastModifiedPayload, .{}));

    var fresh = try app.handle(Request.init(.GET, "/conditional"));
    defer fresh.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, fresh.status);
    try testing.expectEqualStrings("\"v1\"", fresh.header("etag").?);
    try testing.expectEqualStrings(last_modified, fresh.header("last-modified").?);
    try testing.expectEqualStrings("yes", fresh.header("x-cacheable").?);
    try testing.expectEqualStrings("8", fresh.header("content-length").?);
    try testing.expectEqualStrings("cache me", fresh.body.items);

    var etag_req = Request.init(.GET, "/conditional");
    etag_req.headers = &.{.{ .name = "if-none-match", .value = "\"v1\"" }};
    var etag_response = try app.handle(etag_req);
    defer etag_response.deinit(testing.allocator);
    try testing.expectEqual(Status.not_modified, etag_response.status);
    try testing.expect(etag_req.ifNoneMatch("\"v1\""));
    try testing.expect(etag_req.isNotModified(.{ .etag = "\"v1\"", .last_modified_seconds = conditional_last_modified_seconds }));
    try testing.expect(!etag_req.ifModifiedSince(conditional_last_modified_seconds));
    try testing.expectEqualStrings("\"v1\"", etag_response.header("etag").?);
    try testing.expectEqualStrings(last_modified, etag_response.header("last-modified").?);
    try testing.expectEqualStrings("yes", etag_response.header("x-cacheable").?);
    try testing.expect(etag_response.header("content-type") == null);
    try testing.expect(etag_response.header("content-length") == null);
    try testing.expectEqual(@as(usize, 0), etag_response.body.items.len);

    var weak_etag_req = Request.init(.GET, "/conditional");
    weak_etag_req.headers = &.{.{ .name = "if-none-match", .value = "W/\"stale\", W/\"v1\"" }};
    var weak_etag_response = try app.handle(weak_etag_req);
    defer weak_etag_response.deinit(testing.allocator);
    try testing.expectEqual(Status.not_modified, weak_etag_response.status);
    try testing.expect(weak_etag_req.ifNoneMatch("\"v1\""));
    try testing.expect(weak_etag_req.ifNoneMatch("W/\"v1\""));
    try testing.expect(!weak_etag_req.ifNoneMatch("\"v2\""));

    var wildcard_etag_req = Request.init(.GET, "/conditional");
    wildcard_etag_req.headers = &.{.{ .name = "if-none-match", .value = "*" }};
    var wildcard_etag_response = try app.handle(wildcard_etag_req);
    defer wildcard_etag_response.deinit(testing.allocator);
    try testing.expectEqual(Status.not_modified, wildcard_etag_response.status);
    try testing.expect(wildcard_etag_req.ifNoneMatch("\"anything\""));

    var stale_etag_req = Request.init(.GET, "/conditional");
    stale_etag_req.headers = &.{
        .{ .name = "if-none-match", .value = "\"stale\"" },
        .{ .name = "if-modified-since", .value = last_modified },
    };
    var stale_etag = try app.handle(stale_etag_req);
    defer stale_etag.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, stale_etag.status);
    try testing.expectEqualStrings("cache me", stale_etag.body.items);

    var last_modified_req = Request.init(.GET, "/last-modified");
    last_modified_req.headers = &.{.{ .name = "if-modified-since", .value = last_modified }};
    var last_modified_response = try app.handle(last_modified_req);
    defer last_modified_response.deinit(testing.allocator);
    try testing.expectEqual(Status.not_modified, last_modified_response.status);
    try testing.expect(last_modified_req.ifModifiedSince(conditional_last_modified_seconds));
    try testing.expect(last_modified_req.isNotModified(.{ .last_modified_seconds = conditional_last_modified_seconds }));
    try testing.expect(last_modified_req.isNotModified(.{ .etag = "\"v1\"", .last_modified_seconds = conditional_last_modified_seconds }));
    try testing.expect(last_modified_response.header("etag") == null);
    try testing.expectEqualStrings(last_modified, last_modified_response.header("last-modified").?);
    try testing.expectEqual(@as(usize, 0), last_modified_response.body.items.len);

    var post_req = Request.init(.POST, "/conditional");
    post_req.headers = &.{.{ .name = "if-none-match", .value = "\"v1\"" }};
    var post_response = try app.handle(post_req);
    defer post_response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, post_response.status);
    try testing.expectEqualStrings("cache me", post_response.body.items);
}

test "supports file responses" {
    const cwd = std.Io.Dir.cwd();
    try cwd.writeFile(testing.io, .{
        .sub_path = test_file_response_path,
        .data = "file response body",
    });
    defer cwd.deleteFile(testing.io, test_file_response_path) catch {};

    var state: BackgroundState = .{};
    var app = ZAPI.init(testing.allocator, .{ .io = testing.io });
    defer app.deinit();
    app.setState(&state);
    try app.route(Route.get("/download", downloadFile, .{}));
    try app.route(Route.get("/inline", inlineFile, .{}));
    try app.route(Route.get("/unicode-filename", unicodeFilenameFile, .{}));
    try app.route(Route.get("/inferred", inferredFile, .{}));
    try app.route(Route.get("/filename-inferred", filenameInferredFile, .{}));
    try app.route(Route.get("/explicit-octet", explicitOctetFile, .{}));
    try app.route(Route.get("/metadata-only", metadataOnlyFile, .{}));
    try app.route(Route.get("/background-file", backgroundFile, .{}));
    try app.route(Route.get("/custom-headers", customHeaderFile, .{}));
    try app.route(Route.get("/custom-validator", customValidatorFile, .{}));

    var response = try app.handle(Request.init(.GET, "/download"));
    defer response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, response.status);
    try testing.expectEqualStrings("text/plain; charset=utf-8", response.header("content-type").?);
    try testing.expectEqualStrings("18", response.header("content-length").?);
    const etag = response.header("etag").?;
    try testing.expect(std.mem.startsWith(u8, etag, "\""));
    try testing.expect(std.mem.endsWith(u8, etag, "\""));
    try testing.expectEqualStrings("bytes", response.header("accept-ranges").?);
    const last_modified = response.header("last-modified").?;
    try testing.expect(std.mem.endsWith(u8, last_modified, " GMT"));
    try testing.expectEqualStrings("yes", response.header("x-file").?);
    try testing.expectEqualStrings("attachment; filename=\"notes.txt\"", response.header("content-disposition").?);
    try testing.expectEqualStrings("file response body", response.body.items);

    var conditional_req = Request.init(.GET, "/download");
    conditional_req.headers = &.{.{ .name = "if-none-match", .value = etag }};
    var conditional = try app.handle(conditional_req);
    defer conditional.deinit(testing.allocator);
    try testing.expectEqual(Status.not_modified, conditional.status);
    try testing.expectEqualStrings(etag, conditional.header("etag").?);
    try testing.expectEqualStrings(last_modified, conditional.header("last-modified").?);
    try testing.expect(conditional.header("content-type") == null);
    try testing.expect(conditional.header("content-length") == null);
    try testing.expectEqual(@as(usize, 0), conditional.body.items.len);

    var modified_since_req = Request.init(.GET, "/download");
    modified_since_req.headers = &.{.{ .name = "if-modified-since", .value = last_modified }};
    var modified_since = try app.handle(modified_since_req);
    defer modified_since.deinit(testing.allocator);
    try testing.expectEqual(Status.not_modified, modified_since.status);
    try testing.expectEqualStrings(etag, modified_since.header("etag").?);
    try testing.expectEqualStrings(last_modified, modified_since.header("last-modified").?);
    try testing.expect(modified_since.header("content-type") == null);
    try testing.expect(modified_since.header("content-length") == null);
    try testing.expectEqual(@as(usize, 0), modified_since.body.items.len);

    var inline_response = try app.handle(Request.init(.GET, "/inline"));
    defer inline_response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, inline_response.status);
    try testing.expectEqualStrings("inline; filename=\"notes.txt\"", inline_response.header("content-disposition").?);
    try testing.expectEqualStrings("file response body", inline_response.body.items);

    var unicode_response = try app.handle(Request.init(.GET, "/unicode-filename"));
    defer unicode_response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, unicode_response.status);
    try testing.expectEqualStrings("attachment; filename*=utf-8''%E4%BD%A0%E5%A5%BD.txt", unicode_response.header("content-disposition").?);
    try testing.expectEqualStrings("file response body", unicode_response.body.items);

    var inferred_response = try app.handle(Request.init(.GET, "/inferred"));
    defer inferred_response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, inferred_response.status);
    try testing.expectEqualStrings("text/plain; charset=utf-8", inferred_response.header("content-type").?);
    try testing.expect(inferred_response.header("content-disposition") == null);
    try testing.expectEqualStrings("file response body", inferred_response.body.items);

    var filename_inferred_response = try app.handle(Request.init(.GET, "/filename-inferred"));
    defer filename_inferred_response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, filename_inferred_response.status);
    try testing.expectEqualStrings("text/css; charset=utf-8", filename_inferred_response.header("content-type").?);
    try testing.expectEqualStrings("attachment; filename=\"style.css\"", filename_inferred_response.header("content-disposition").?);
    try testing.expectEqualStrings("file response body", filename_inferred_response.body.items);

    var explicit_octet_response = try app.handle(Request.init(.GET, "/explicit-octet"));
    defer explicit_octet_response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, explicit_octet_response.status);
    try testing.expectEqualStrings("application/octet-stream", explicit_octet_response.header("content-type").?);
    try testing.expectEqualStrings("file response body", explicit_octet_response.body.items);

    var metadata_only_head = try app.handle(Request.init(.HEAD, "/metadata-only"));
    defer metadata_only_head.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, metadata_only_head.status);
    try testing.expectEqualStrings("text/plain; charset=utf-8", metadata_only_head.header("content-type").?);
    try testing.expectEqualStrings("18", metadata_only_head.header("content-length").?);
    try testing.expect(metadata_only_head.header("etag") != null);
    try testing.expect(metadata_only_head.header("last-modified") != null);
    try testing.expectEqual(@as(usize, 0), metadata_only_head.body.items.len);

    var background_file = try app.handle(Request.init(.GET, "/background-file"));
    defer background_file.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, background_file.status);
    try testing.expectEqualStrings("file response body", background_file.body.items);
    try testing.expectEqual(@as(usize, 1), state.count);
    try testing.expectEqual(@as(usize, 0), background_file.background_tasks.items.len);

    var custom_headers = try app.handle(Request.init(.GET, "/custom-headers"));
    defer custom_headers.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, custom_headers.status);
    try testing.expectEqualStrings("attachment; filename=\"custom.txt\"", custom_headers.header("content-disposition").?);
    try testing.expectEqualStrings("none", custom_headers.header("accept-ranges").?);
    try testing.expectEqualStrings("file response body", custom_headers.body.items);

    var custom_validator = try app.handle(Request.init(.GET, "/custom-validator"));
    defer custom_validator.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, custom_validator.status);
    try testing.expectEqualStrings("\"custom-etag\"", custom_validator.header("etag").?);
    try testing.expectEqualStrings("18", custom_validator.header("content-length").?);
    try testing.expectEqualStrings("file response body", custom_validator.body.items);

    var custom_validator_conditional_req = Request.init(.GET, "/custom-validator");
    custom_validator_conditional_req.headers = &.{.{ .name = "if-none-match", .value = "\"custom-etag\"" }};
    var custom_validator_conditional = try app.handle(custom_validator_conditional_req);
    defer custom_validator_conditional.deinit(testing.allocator);
    try testing.expectEqual(Status.not_modified, custom_validator_conditional.status);
    try testing.expectEqualStrings("\"custom-etag\"", custom_validator_conditional.header("etag").?);
    try testing.expect(custom_validator_conditional.header("content-length") == null);
    try testing.expectEqual(@as(usize, 0), custom_validator_conditional.body.items.len);

    var custom_validator_range_req = Request.init(.GET, "/custom-validator");
    custom_validator_range_req.headers = &.{
        .{ .name = "range", .value = "bytes=0-3" },
        .{ .name = "if-range", .value = "\"custom-etag\"" },
    };
    var custom_validator_range = try app.handle(custom_validator_range_req);
    defer custom_validator_range.deinit(testing.allocator);
    try testing.expectEqual(Status.partial_content, custom_validator_range.status);
    try testing.expectEqualStrings("\"custom-etag\"", custom_validator_range.header("etag").?);
    try testing.expectEqualStrings("bytes 0-3/18", custom_validator_range.header("content-range").?);
    try testing.expectEqualStrings("file", custom_validator_range.body.items);

    var range_req = Request.init(.GET, "/download");
    range_req.headers = &.{.{ .name = "range", .value = "bytes=0-3" }};
    var range_response = try app.handle(range_req);
    defer range_response.deinit(testing.allocator);
    try testing.expectEqual(Status.partial_content, range_response.status);
    try testing.expectEqualStrings("bytes", range_response.header("accept-ranges").?);
    try testing.expectEqualStrings("bytes 0-3/18", range_response.header("content-range").?);
    try testing.expectEqualStrings("4", range_response.header("content-length").?);
    try testing.expectEqualStrings("file", range_response.body.items);

    const expected_multipart_body =
        "--zapi-boundary\r\n" ++
        "Content-Type: text/plain; charset=utf-8\r\n" ++
        "Content-Range: bytes 0-3/18\r\n" ++
        "\r\n" ++
        "file\r\n" ++
        "--zapi-boundary\r\n" ++
        "Content-Type: text/plain; charset=utf-8\r\n" ++
        "Content-Range: bytes 14-17/18\r\n" ++
        "\r\n" ++
        "body\r\n" ++
        "--zapi-boundary--";

    var multipart_range_req = Request.init(.GET, "/download");
    multipart_range_req.headers = &.{.{ .name = "range", .value = "bytes=0-3,14-17" }};
    var multipart_range = try app.handle(multipart_range_req);
    defer multipart_range.deinit(testing.allocator);
    try testing.expectEqual(Status.partial_content, multipart_range.status);
    try testing.expectEqualStrings("multipart/byteranges; boundary=zapi-boundary", multipart_range.header("content-type").?);
    try testing.expect(multipart_range.header("content-range") == null);
    try testing.expectEqualStrings("bytes", multipart_range.header("accept-ranges").?);
    try testing.expectEqualStrings("209", multipart_range.header("content-length").?);
    try testing.expectEqualStrings(expected_multipart_body, multipart_range.body.items);

    var multipart_head_req = Request.init(.HEAD, "/metadata-only");
    multipart_head_req.headers = &.{.{ .name = "range", .value = "bytes=0-3,14-17" }};
    var multipart_head = try app.handle(multipart_head_req);
    defer multipart_head.deinit(testing.allocator);
    try testing.expectEqual(Status.partial_content, multipart_head.status);
    try testing.expectEqualStrings("multipart/byteranges; boundary=zapi-boundary", multipart_head.header("content-type").?);
    try testing.expectEqualStrings("209", multipart_head.header("content-length").?);
    try testing.expect(multipart_head.header("content-range") == null);
    try testing.expectEqual(@as(usize, 0), multipart_head.body.items.len);

    var overlapping_range_req = Request.init(.GET, "/download");
    overlapping_range_req.headers = &.{.{ .name = "range", .value = "bytes=0-3,2-5" }};
    var overlapping_range = try app.handle(overlapping_range_req);
    defer overlapping_range.deinit(testing.allocator);
    try testing.expectEqual(Status.partial_content, overlapping_range.status);
    try testing.expectEqualStrings("text/plain; charset=utf-8", overlapping_range.header("content-type").?);
    try testing.expectEqualStrings("bytes 0-5/18", overlapping_range.header("content-range").?);
    try testing.expectEqualStrings("file r", overlapping_range.body.items);

    var suffix_req = Request.init(.GET, "/download");
    suffix_req.headers = &.{.{ .name = "range", .value = "bytes=-4" }};
    var suffix_response = try app.handle(suffix_req);
    defer suffix_response.deinit(testing.allocator);
    try testing.expectEqual(Status.partial_content, suffix_response.status);
    try testing.expectEqualStrings("bytes 14-17/18", suffix_response.header("content-range").?);
    try testing.expectEqualStrings("body", suffix_response.body.items);

    var stale_if_range_req = Request.init(.GET, "/download");
    stale_if_range_req.headers = &.{
        .{ .name = "range", .value = "bytes=0-3" },
        .{ .name = "if-range", .value = "\"not-the-etag\"" },
    };
    var stale_if_range = try app.handle(stale_if_range_req);
    defer stale_if_range.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, stale_if_range.status);
    try testing.expect(stale_if_range.header("content-range") == null);
    try testing.expectEqualStrings("18", stale_if_range.header("content-length").?);
    try testing.expectEqualStrings("file response body", stale_if_range.body.items);

    var malformed_unit_req = Request.init(.GET, "/download");
    malformed_unit_req.headers = &.{.{ .name = "range", .value = "items=0-3" }};
    var malformed_unit = try app.handle(malformed_unit_req);
    defer malformed_unit.deinit(testing.allocator);
    try testing.expectEqual(Status.bad_request, malformed_unit.status);
    try testing.expectEqualStrings("text/plain; charset=utf-8", malformed_unit.header("content-type").?);
    try testing.expectEqualStrings("Only support bytes range", malformed_unit.body.items);

    var malformed_syntax_req = Request.init(.GET, "/download");
    malformed_syntax_req.headers = &.{.{ .name = "range", .value = "bytes" }};
    var malformed_syntax = try app.handle(malformed_syntax_req);
    defer malformed_syntax.deinit(testing.allocator);
    try testing.expectEqual(Status.bad_request, malformed_syntax.status);
    try testing.expectEqualStrings("Malformed range header.", malformed_syntax.body.items);

    var malformed_order_req = Request.init(.GET, "/download");
    malformed_order_req.headers = &.{.{ .name = "range", .value = "bytes=5-3" }};
    var malformed_order = try app.handle(malformed_order_req);
    defer malformed_order.deinit(testing.allocator);
    try testing.expectEqual(Status.bad_request, malformed_order.status);
    try testing.expectEqualStrings("Range header: start must be less than end", malformed_order.body.items);

    var unsatisfiable_req = Request.init(.GET, "/download");
    unsatisfiable_req.headers = &.{.{ .name = "range", .value = "bytes=99-120" }};
    var unsatisfiable = try app.handle(unsatisfiable_req);
    defer unsatisfiable.deinit(testing.allocator);
    try testing.expectEqual(Status.requested_range_not_satisfiable, unsatisfiable.status);
    try testing.expectEqualStrings("bytes */18", unsatisfiable.header("content-range").?);
    try testing.expectEqualStrings("0", unsatisfiable.header("content-length").?);
    try testing.expectEqual(@as(usize, 0), unsatisfiable.body.items.len);
}

test "file responses require io and surface missing files as server errors" {
    var no_io_app = ZAPI.init(testing.allocator, .{});
    defer no_io_app.deinit();
    try no_io_app.route(Route.get("/download", downloadFile, .{}));

    var no_io = try no_io_app.handle(Request.init(.GET, "/download"));
    defer no_io.deinit(testing.allocator);
    try testing.expectEqual(Status.internal_server_error, no_io.status);
    try testing.expectEqualStrings("{\"detail\":\"Internal server error\"}", no_io.body.items);

    var app = ZAPI.init(testing.allocator, .{ .io = testing.io });
    defer app.deinit();
    try app.route(Route.get("/missing-file", missingFile, .{}));

    var missing = try app.handle(Request.init(.GET, "/missing-file"));
    defer missing.deinit(testing.allocator);
    try testing.expectEqual(Status.internal_server_error, missing.status);
    try testing.expectEqualStrings("{\"detail\":\"Internal server error\"}", missing.body.items);
}

test "context problem returns structured json error responses" {
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    try app.route(Route.get("/problem", problemResponse, .{}));
    try app.route(Route.get("/limited", problemWithHeaderResponse, .{}));
    try app.route(Route.get("/problems/{kind}", problemShortcutResponse, .{}));

    var response = try app.handle(Request.init(.GET, "/problem"));
    defer response.deinit(testing.allocator);
    try testing.expectEqual(Status.not_found, response.status);
    try testing.expectEqualStrings("application/json", response.header("content-type").?);
    try testing.expectEqualStrings("{\"detail\":\"User \\\"ada\\\" not found\\ntry again\"}", response.body.items);

    var limited = try app.handle(Request.init(.GET, "/limited"));
    defer limited.deinit(testing.allocator);
    try testing.expectEqual(Status.too_many_requests, limited.status);
    try testing.expectEqualStrings("application/json", limited.header("content-type").?);
    try testing.expectEqualStrings("30", limited.header("retry-after").?);
    try testing.expectEqualStrings("{\"detail\":\"Slow down\"}", limited.body.items);

    const cases = &.{
        .{ .path = "/problems/bad", .status = Status.bad_request, .body = "{\"detail\":\"Bad request\"}" },
        .{ .path = "/problems/unauthorized", .status = Status.unauthorized, .body = "{\"detail\":\"Missing token\"}" },
        .{ .path = "/problems/forbidden", .status = Status.forbidden, .body = "{\"detail\":\"Forbidden\"}" },
        .{ .path = "/problems/missing", .status = Status.not_found, .body = "{\"detail\":\"Missing resource\"}" },
        .{ .path = "/problems/conflict", .status = Status.conflict, .body = "{\"detail\":\"Conflict\"}" },
        .{ .path = "/problems/large", .status = Status.payload_too_large, .body = "{\"detail\":\"Payload too large\"}" },
        .{ .path = "/problems/limited", .status = Status.too_many_requests, .body = "{\"detail\":\"Too many requests\"}" },
        .{ .path = "/problems/invalid", .status = Status.unprocessable_entity, .body = "{\"detail\":\"Invalid state\"}" },
    };

    inline for (cases) |case| {
        var shortcut = try app.handle(Request.init(.GET, case.path));
        defer shortcut.deinit(testing.allocator);
        try testing.expectEqual(case.status, shortcut.status);
        try testing.expectEqualStrings("application/json", shortcut.header("content-type").?);
        try testing.expectEqualStrings(case.body, shortcut.body.items);
    }

    var bearer = try app.handle(Request.init(.GET, "/problems/bearer"));
    defer bearer.deinit(testing.allocator);
    try testing.expectEqual(Status.unauthorized, bearer.status);
    try testing.expectEqualStrings("application/json", bearer.header("content-type").?);
    try testing.expectEqualStrings("Bearer", bearer.header("www-authenticate").?);
    try testing.expectEqualStrings("{\"detail\":\"Missing bearer token\"}", bearer.body.items);
}

test "framework problem responses escape json details" {
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    var response = try app.problem(.bad_request, "Bad \"input\"\nagain");
    defer response.deinit(testing.allocator);

    try testing.expectEqual(Status.bad_request, response.status);
    try testing.expectEqualStrings("application/json", response.header("content-type").?);
    try testing.expectEqualStrings("{\"detail\":\"Bad \\\"input\\\"\\nagain\"}", response.body.items);
}

test "runs response background tasks after app handle" {
    var state: BackgroundState = .{};
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    app.setState(&state);
    try app.route(Route.get("/background", backgroundPayload, .{}));
    try app.route(Route.get("/background-list", backgroundTasksPayload, .{}));

    var response = try app.handle(Request.init(.GET, "/background"));
    defer response.deinit(testing.allocator);

    try testing.expectEqual(Status.ok, response.status);
    try testing.expectEqualStrings("queued", response.body.items);
    try testing.expectEqual(@as(usize, 1), state.count);
    try testing.expectEqual(@as(usize, 0), response.background_tasks.items.len);
}

test "background tasks accumulator transfers owned task slices" {
    var state: BackgroundState = .{};
    var tasks = BackgroundTasks.init(testing.allocator);
    defer tasks.deinit();

    try testing.expect(tasks.isEmpty());
    try tasks.addTask(incrementBackgroundTask, &state);
    try tasks.append(.{ .run = incrementBackgroundTask, .context = &state });
    try testing.expectEqual(@as(usize, 2), tasks.len());
    try testing.expectEqual(@as(usize, 2), tasks.items().len);

    const owned = try tasks.toOwnedSlice();
    defer testing.allocator.free(owned);
    try testing.expect(tasks.isEmpty());
    try testing.expectEqual(@as(usize, 2), owned.len);

    for (owned) |task| try task.run(task.context);
    try testing.expectEqual(@as(usize, 2), state.count);
}

test "background tasks accumulator runs after app handle" {
    var state: BackgroundState = .{};
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    app.setState(&state);
    try app.route(Route.get("/background-list", backgroundTasksPayload, .{}));

    var response = try app.handle(Request.init(.GET, "/background-list"));
    defer response.deinit(testing.allocator);

    try testing.expectEqual(Status.ok, response.status);
    try testing.expectEqualStrings("queued-list", response.body.items);
    try testing.expectEqual(@as(usize, 2), state.count);
    try testing.expectEqual(@as(usize, 0), response.background_tasks.items.len);
}

test "lifespan handlers run in order and cascade through mounted apps" {
    var state: LifecycleState = .{};
    defer state.events.deinit(testing.allocator);

    var parent = ZAPI.init(testing.allocator, .{});
    defer parent.deinit();
    var child = ZAPI.init(testing.allocator, .{});
    defer child.deinit();

    parent.setState(&state);
    child.setState(&state);
    try parent.addStartupHandler(parentStartup);
    try parent.addShutdownHandler(parentShutdown);
    try child.addStartupHandler(childStartup);
    try child.addShutdownHandler(childShutdown);
    try parent.mount("/child", &child);

    try parent.startup();
    try parent.shutdown();

    try testing.expectEqual(@as(usize, 4), state.events.items.len);
    try testing.expectEqualStrings("parent-startup", state.events.items[0]);
    try testing.expectEqualStrings("child-startup", state.events.items[1]);
    try testing.expectEqualStrings("child-shutdown", state.events.items[2]);
    try testing.expectEqualStrings("parent-shutdown", state.events.items[3]);
}

test "serve runs lifespan handlers around listener lifecycle" {
    const io = testing.io;
    var state: LifecycleState = .{};
    defer state.events.deinit(testing.allocator);

    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    app.setState(&state);
    try app.addStartupHandler(parentStartup);
    try app.addShutdownHandler(parentShutdown);

    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    try app.serve(io, address, .{ .max_connections = 0 });

    try testing.expectEqual(@as(usize, 2), state.events.items.len);
    try testing.expectEqualStrings("parent-startup", state.events.items[0]);
    try testing.expectEqualStrings("parent-shutdown", state.events.items[1]);
}

test "sets and deletes response cookies" {
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    try app.route(Route.get("/set-cookie", setCookieResponse, .{}));
    try app.route(Route.get("/delete-cookie", deleteCookieResponse, .{}));
    try app.route(Route.get("/expires-delete-cookie", expiresOnlyDeleteCookieResponse, .{}));
    try app.route(Route.get("/non-empty-max-age-delete-cookie", nonEmptyMaxAgeDeleteCookieResponse, .{}));
    try app.route(Route.get("/non-empty-expires-delete-cookie", nonEmptyExpiresDeleteCookieResponse, .{}));
    try app.route(Route.get("/max-age-precedence-cookie", maxAgePrecedenceCookieResponse, .{}));

    var set_response = try app.handle(Request.init(.GET, "/set-cookie"));
    defer set_response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, set_response.status);
    try testing.expectEqualStrings("ok", set_response.body.items);
    try testing.expectEqualStrings("session=abc123; Max-Age=3600; Path=/; Secure; HttpOnly; SameSite=lax", set_response.header("set-cookie").?);
    var set_cookies = try set_response.cookies(testing.allocator);
    defer set_cookies.deinit();
    try testing.expectEqualStrings("abc123", set_cookies.get("session").?);
    const set_session_cookie = try set_response.cookie(testing.allocator, "session");
    defer testing.allocator.free(set_session_cookie.?);
    try testing.expectEqualStrings("abc123", set_session_cookie.?);
    try testing.expect(try set_response.cookie(testing.allocator, "missing") == null);

    var delete_response = try app.handle(Request.init(.GET, "/delete-cookie"));
    defer delete_response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, delete_response.status);
    try testing.expectEqualStrings("deleted", delete_response.body.items);
    try testing.expectEqualStrings("session=; Max-Age=0; Expires=Thu, 01 Jan 1970 00:00:00 GMT; Path=/; SameSite=lax", delete_response.header("set-cookie").?);
    var delete_cookies = try delete_response.cookies(testing.allocator);
    defer delete_cookies.deinit();
    try testing.expect(delete_cookies.get("session") == null);
    try testing.expect(try delete_response.cookie(testing.allocator, "session") == null);

    var expires_delete_response = try app.handle(Request.init(.GET, "/expires-delete-cookie"));
    defer expires_delete_response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, expires_delete_response.status);
    try testing.expectEqualStrings("session=; Expires=Thu, 01 Jan 1970 00:00:00 GMT; Path=/; SameSite=lax", expires_delete_response.header("set-cookie").?);
    var expires_delete_cookies = try expires_delete_response.cookies(testing.allocator);
    defer expires_delete_cookies.deinit();
    try testing.expect(expires_delete_cookies.get("session") == null);

    var non_empty_max_age_delete_response = try app.handle(Request.init(.GET, "/non-empty-max-age-delete-cookie"));
    defer non_empty_max_age_delete_response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, non_empty_max_age_delete_response.status);
    try testing.expectEqualStrings("session=deleted; Max-Age=0; Path=/; SameSite=lax", non_empty_max_age_delete_response.header("set-cookie").?);
    var non_empty_max_age_delete_cookies = try non_empty_max_age_delete_response.cookies(testing.allocator);
    defer non_empty_max_age_delete_cookies.deinit();
    try testing.expect(non_empty_max_age_delete_cookies.get("session") == null);

    var non_empty_expires_delete_response = try app.handle(Request.init(.GET, "/non-empty-expires-delete-cookie"));
    defer non_empty_expires_delete_response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, non_empty_expires_delete_response.status);
    try testing.expectEqualStrings("session=expired; Expires=Thu, 01 Jan 1970 00:00:00 GMT; Path=/; SameSite=lax", non_empty_expires_delete_response.header("set-cookie").?);
    var non_empty_expires_delete_cookies = try non_empty_expires_delete_response.cookies(testing.allocator);
    defer non_empty_expires_delete_cookies.deinit();
    try testing.expect(non_empty_expires_delete_cookies.get("session") == null);

    var max_age_response = try app.handle(Request.init(.GET, "/max-age-precedence-cookie"));
    defer max_age_response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, max_age_response.status);
    try testing.expectEqualStrings("session=kept; Max-Age=3600; Expires=Thu, 01 Jan 1970 00:00:00 GMT; Path=/; SameSite=lax", max_age_response.header("set-cookie").?);
    var max_age_cookies = try max_age_response.cookies(testing.allocator);
    defer max_age_cookies.deinit();
    try testing.expectEqualStrings("kept", max_age_cookies.get("session").?);

    var direct_set_then_delete = Response.init(.ok);
    defer direct_set_then_delete.deinit(testing.allocator);
    try direct_set_then_delete.setCookie(testing.allocator, "session", "abc123", .{});
    try direct_set_then_delete.setCookie(testing.allocator, "preview", "yes", .{});
    try direct_set_then_delete.deleteCookie(testing.allocator, "session", .{});
    var set_then_delete_cookies = try direct_set_then_delete.cookies(testing.allocator);
    defer set_then_delete_cookies.deinit();
    try testing.expect(set_then_delete_cookies.get("session") == null);
    try testing.expectEqualStrings("yes", set_then_delete_cookies.get("preview").?);
    try testing.expect(try direct_set_then_delete.cookie(testing.allocator, "session") == null);
    const preview_cookie = try direct_set_then_delete.cookie(testing.allocator, "preview");
    defer testing.allocator.free(preview_cookie.?);
    try testing.expectEqualStrings("yes", preview_cookie.?);

    var direct_delete_then_set = Response.init(.ok);
    defer direct_delete_then_set.deinit(testing.allocator);
    try direct_delete_then_set.deleteCookie(testing.allocator, "session", .{});
    try direct_delete_then_set.setCookie(testing.allocator, "session", "replacement", .{});
    var delete_then_set_cookies = try direct_delete_then_set.cookies(testing.allocator);
    defer delete_then_set_cookies.deinit();
    try testing.expectEqualStrings("replacement", delete_then_set_cookies.get("session").?);
    const replacement_cookie = try direct_delete_then_set.cookie(testing.allocator, "session");
    defer testing.allocator.free(replacement_cookie.?);
    try testing.expectEqualStrings("replacement", replacement_cookie.?);

    var direct = Response.init(.ok);
    defer direct.deinit(testing.allocator);
    try direct.setCookie(testing.allocator, "session", "abc123", .{
        .max_age = 3600,
        .secure = true,
        .http_only = true,
        .same_site = .lax,
        .partitioned = true,
    });
    try direct.deleteCookie(testing.allocator, "preview", .{ .partitioned = true });

    try testing.expectEqualStrings("session=abc123; Max-Age=3600; Path=/; Secure; HttpOnly; SameSite=lax; Partitioned", direct.header("set-cookie").?);
    try testing.expectEqualStrings("preview=; Max-Age=0; Expires=Thu, 01 Jan 1970 00:00:00 GMT; Path=/; SameSite=lax; Partitioned", direct.headers.items[1].value);

    var set_cookie_count: usize = 0;
    for (direct.headers.items) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "set-cookie")) set_cookie_count += 1;
    }
    try testing.expectEqual(@as(usize, 2), set_cookie_count);
    var direct_cookies = try direct.cookies(testing.allocator);
    defer direct_cookies.deinit();
    try testing.expectEqualStrings("abc123", direct_cookies.get("session").?);
    try testing.expect(direct_cookies.get("preview") == null);

    const pathless_cookie = try makeSetCookieHeader(testing.allocator, "pathless", "value", .{ .path = null });
    defer {
        testing.allocator.free(pathless_cookie.name);
        testing.allocator.free(pathless_cookie.value);
    }
    try testing.expectEqualStrings("pathless=value; SameSite=lax", pathless_cookie.value);

    const samesite_none_cookie = try makeSetCookieHeader(testing.allocator, "bare", "value", .{ .same_site = null });
    defer {
        testing.allocator.free(samesite_none_cookie.name);
        testing.allocator.free(samesite_none_cookie.value);
    }
    try testing.expectEqualStrings("bare=value; Path=/", samesite_none_cookie.value);

    try testing.expectError(error.InvalidCookie, makeSetCookieHeader(testing.allocator, "bad name", "value", .{}));
    try testing.expectError(error.InvalidCookie, makeSetCookieHeader(testing.allocator, "session", "bad;value", .{}));
    try testing.expectError(error.InvalidCookie, direct.setCookie(testing.allocator, "bad name", "value", .{}));
}

test "response payload helpers own headers cookies and background tasks" {
    var state: BackgroundState = .{};
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    app.setState(&state);
    try app.route(Route.get("/payload-helpers", payloadHelpersResponse, .{}));

    var response = try app.handle(Request.init(.GET, "/payload-helpers"));
    defer response.deinit(testing.allocator);

    try testing.expectEqual(Status.ok, response.status);
    try testing.expectEqualStrings("helpers", response.body.items);
    try testing.expectEqualStrings("owned", response.header("x-mode").?);
    try testing.expectEqual(@as(usize, 1), state.count);
    try testing.expectEqual(@as(usize, 0), response.background_tasks.items.len);

    var x_extra_count: usize = 0;
    var set_cookie_count: usize = 0;
    var saw_set_session = false;
    var saw_delete_preview = false;
    for (response.headers.items) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "x-extra")) {
            x_extra_count += 1;
        } else if (std.ascii.eqlIgnoreCase(header.name, "set-cookie")) {
            set_cookie_count += 1;
            if (std.mem.eql(u8, header.value, "session=abc123; Path=/; HttpOnly; SameSite=lax")) saw_set_session = true;
            if (std.mem.eql(u8, header.value, "preview=; Max-Age=0; Expires=Thu, 01 Jan 1970 00:00:00 GMT; Path=/; SameSite=lax")) saw_delete_preview = true;
        }
    }

    try testing.expectEqual(@as(usize, 2), x_extra_count);
    try testing.expectEqual(@as(usize, 2), set_cookie_count);
    try testing.expect(saw_set_session);
    try testing.expect(saw_delete_preview);
    var response_cookies = try response.cookies(testing.allocator);
    defer response_cookies.deinit();
    try testing.expectEqualStrings("abc123", response_cookies.get("session").?);
    try testing.expect(response_cookies.get("preview") == null);

    var payload = ResponsePayload{};
    defer payload.deinit(testing.allocator);
    try payload.setHeader(testing.allocator, "x-one", "1");
    try testing.expect(payload.hasHeader("X-One"));
    try testing.expectEqualStrings("1", payload.header("X-One").?);
    try payload.appendHeader(testing.allocator, "x-extra", "a");
    try payload.appendHeader(testing.allocator, "X-Extra", "b");
    try testing.expect(payload.hasHeader("x-extra"));
    const payload_extra = try payload.headerValues(testing.allocator, "x-extra");
    defer testing.allocator.free(payload_extra);
    try testing.expectEqual(@as(usize, 2), payload_extra.len);
    try testing.expectEqualStrings("a", payload_extra[0]);
    try testing.expectEqualStrings("b", payload_extra[1]);
    try payload.removeHeader(testing.allocator, "X-Extra");
    try testing.expect(payload.header("x-extra") == null);
    try testing.expect(!payload.hasHeader("x-extra"));
    const payload_removed_extra = try payload.headerValues(testing.allocator, "x-extra");
    defer testing.allocator.free(payload_removed_extra);
    try testing.expectEqual(@as(usize, 0), payload_removed_extra.len);
    try payload.removeHeader(testing.allocator, "x-missing");
    const payload_missing = try payload.headerValues(testing.allocator, "x-missing");
    defer testing.allocator.free(payload_missing);
    try testing.expectEqual(@as(usize, 0), payload_missing.len);

    try payload.appendHeader(testing.allocator, "x-clear", "yes");
    payload.clearHeaders(testing.allocator);
    try testing.expectEqual(@as(usize, 0), payload.headers.len);
    try testing.expect(payload.header("x-one") == null);
    try testing.expect(payload.header("x-clear") == null);
    try testing.expect(!payload.hasHeader("x-one"));
    try testing.expect(!payload.hasHeader("x-clear"));
    payload.clearHeaders(testing.allocator);

    var borrowed_payload = ResponsePayload{
        .headers = &.{.{ .name = "x-borrowed", .value = "yes" }},
    };
    borrowed_payload.clearHeaders(testing.allocator);
    try testing.expectEqual(@as(usize, 0), borrowed_payload.headers.len);
    borrowed_payload.deinit(testing.allocator);

    try testing.expectError(error.InvalidCookie, payload.setCookie(testing.allocator, "bad name", "value", .{}));
}

test "middleware can mutate responses short circuit and preserve order" {
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    try app.middleware(addMiddlewareHeader);
    try app.addMiddleware(blockMiddleware);
    try app.addMiddleware(appendOrderOuter);
    try app.addMiddleware(appendOrderInner);
    try app.route(Route.get("/", plainText, .{}));

    var response = try app.handle(Request.init(.GET, "/"));
    defer response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, response.status);
    try testing.expectEqualStrings("yes", response.header("x-middleware").?);
    try testing.expectEqualStrings("outer", response.header("x-order").?);
    var order_header_count: usize = 0;
    for (response.headers.items) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "x-order")) order_header_count += 1;
    }
    try testing.expectEqual(@as(usize, 1), order_header_count);

    var blocked_req = Request.init(.GET, "/");
    blocked_req.headers = &.{.{ .name = "x-block", .value = "true" }};
    var blocked = try app.handle(blocked_req);
    defer blocked.deinit(testing.allocator);
    try testing.expectEqual(Status.forbidden, blocked.status);
    try testing.expectEqualStrings("blocked", blocked.body.items);
    try testing.expectEqualStrings("yes", blocked.header("x-middleware").?);
    try testing.expectEqual(null, blocked.header("x-order"));
}

test "middleware informational responses do not send content length or body" {
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    try app.addMiddleware(informationalMiddleware);
    try app.route(Route.get("/", plainText, .{}));

    var response = try app.handle(Request.init(.GET, "/"));
    defer response.deinit(testing.allocator);
    try testing.expectEqual(Status.processing, response.status);
    try testing.expectEqualStrings("kept", response.header("x-info").?);
    try testing.expect(response.header("content-length") == null);
    try testing.expectEqual(@as(usize, 0), response.body.items.len);
}

test "method override middleware rewrites configured source methods before routing" {
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    try app.addMiddleware(methodOverrideMiddleware(.{}));
    try app.route(Route.get("/items/{id:int}", echoMethodAndBody, .{}));
    try app.route(Route.delete("/items/{id:int}", echoMethodAndBody, .{}));
    try app.route(Route.patch("/items/{id:int}", echoMethodAndBody, .{}));

    var delete_req = Request.init(.POST, "/items/1");
    delete_req.headers = &.{.{ .name = "x-http-method-override", .value = "DELETE" }};
    delete_req.body = "payload";
    var deleted = try app.handle(delete_req);
    defer deleted.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, deleted.status);
    try testing.expectEqualStrings("{\"method\":\"DELETE\",\"body\":\"payload\"}", deleted.body.items);

    var patch_req = Request.init(.POST, "/items/1");
    patch_req.headers = &.{.{ .name = "x-http-method-override", .value = " patch " }};
    patch_req.body = "{\"name\":\"Ada\"}";
    var patched = try app.handle(patch_req);
    defer patched.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, patched.status);
    try testing.expectEqualStrings("{\"method\":\"PATCH\",\"body\":\"{\\\"name\\\":\\\"Ada\\\"}\"}", patched.body.items);

    var ignored_req = Request.init(.GET, "/items/1");
    ignored_req.headers = &.{.{ .name = "x-http-method-override", .value = "DELETE" }};
    var ignored = try app.handle(ignored_req);
    defer ignored.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, ignored.status);
    try testing.expectEqualStrings("{\"method\":\"GET\",\"body\":\"\"}", ignored.body.items);

    var disallowed_req = Request.init(.POST, "/items/1");
    disallowed_req.headers = &.{.{ .name = "x-http-method-override", .value = "GET" }};
    var disallowed = try app.handle(disallowed_req);
    defer disallowed.deinit(testing.allocator);
    try testing.expectEqual(Status.bad_request, disallowed.status);
    try testing.expectEqualStrings("{\"detail\":\"Disallowed method override\"}", disallowed.body.items);

    var disallowed_trace_req = Request.init(.POST, "/items/1");
    disallowed_trace_req.headers = &.{.{ .name = "x-http-method-override", .value = "TRACE" }};
    var disallowed_trace = try app.handle(disallowed_trace_req);
    defer disallowed_trace.deinit(testing.allocator);
    try testing.expectEqual(Status.bad_request, disallowed_trace.status);
    try testing.expectEqualStrings("{\"detail\":\"Disallowed method override\"}", disallowed_trace.body.items);

    var disallowed_connect_req = Request.init(.POST, "/items/1");
    disallowed_connect_req.headers = &.{.{ .name = "x-http-method-override", .value = "CONNECT" }};
    var disallowed_connect = try app.handle(disallowed_connect_req);
    defer disallowed_connect.deinit(testing.allocator);
    try testing.expectEqual(Status.bad_request, disallowed_connect.status);
    try testing.expectEqualStrings("{\"detail\":\"Disallowed method override\"}", disallowed_connect.body.items);

    var invalid_req = Request.init(.POST, "/items/1");
    invalid_req.headers = &.{.{ .name = "x-http-method-override", .value = "BREW" }};
    var invalid = try app.handle(invalid_req);
    defer invalid.deinit(testing.allocator);
    try testing.expectEqual(Status.bad_request, invalid.status);
    try testing.expectEqualStrings("{\"detail\":\"Invalid method override\"}", invalid.body.items);
}

test "response headers middleware sets preserves and appends configured headers" {
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    try app.addMiddleware(responseHeadersMiddleware(.{
        .headers = &.{
            .{ .name = "x-zapi", .value = "middleware" },
            .{ .name = "cache-control", .value = "no-store" },
        },
        .append_headers = &.{
            .{ .name = "x-extra", .value = "one" },
            .{ .name = "x-extra", .value = "two" },
        },
    }));
    try app.route(Route.post("/custom", customPayload, .{}));

    var response = try app.handle(Request.init(.POST, "/custom"));
    defer response.deinit(testing.allocator);
    try testing.expectEqual(Status.accepted, response.status);
    try testing.expectEqualStrings("middleware", response.header("x-zapi").?);
    try testing.expectEqualStrings("no-store", response.header("cache-control").?);
    const extra = try response.headerValues(testing.allocator, "x-extra");
    defer testing.allocator.free(extra);
    try testing.expectEqual(@as(usize, 2), extra.len);
    try testing.expectEqualStrings("one", extra[0]);
    try testing.expectEqualStrings("two", extra[1]);

    var preserve_app = ZAPI.init(testing.allocator, .{});
    defer preserve_app.deinit();
    try preserve_app.addMiddleware(responseHeadersMiddleware(.{
        .headers = &.{
            .{ .name = "x-zapi", .value = "middleware" },
            .{ .name = "cache-control", .value = "no-store" },
        },
        .preserve_existing = true,
    }));
    try preserve_app.route(Route.post("/custom", customPayload, .{}));

    var preserved = try preserve_app.handle(Request.init(.POST, "/custom"));
    defer preserved.deinit(testing.allocator);
    try testing.expectEqualStrings("ok", preserved.header("x-zapi").?);
    try testing.expectEqualStrings("no-store", preserved.header("cache-control").?);
}

test "route middleware applies only to selected routes and preserves app ordering" {
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    try app.addMiddleware(appendOrderOuter);
    try app.route(Route.get("/with", plainText, .{
        .middlewares = &.{ addRouteMiddlewareHeader, blockMiddleware, appendOrderInner },
    }));
    try app.route(Route.get("/without", plainText, .{}));

    var routed = try app.handle(Request.init(.GET, "/with"));
    defer routed.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, routed.status);
    try testing.expectEqualStrings("Hello, world", routed.body.items);
    try testing.expectEqualStrings("yes", routed.header("x-route-middleware").?);
    try testing.expectEqualStrings("outer", routed.header("x-order").?);

    var plain = try app.handle(Request.init(.GET, "/without"));
    defer plain.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, plain.status);
    try testing.expect(plain.header("x-route-middleware") == null);
    try testing.expectEqualStrings("outer", plain.header("x-order").?);

    var blocked_req = Request.init(.GET, "/with");
    blocked_req.headers = &.{.{ .name = "x-block", .value = "true" }};
    var blocked = try app.handle(blocked_req);
    defer blocked.deinit(testing.allocator);
    try testing.expectEqual(Status.forbidden, blocked.status);
    try testing.expectEqualStrings("blocked", blocked.body.items);
    try testing.expectEqualStrings("yes", blocked.header("x-route-middleware").?);
    try testing.expectEqualStrings("outer", blocked.header("x-order").?);

    var unblocked_req = Request.init(.GET, "/without");
    unblocked_req.headers = &.{.{ .name = "x-block", .value = "true" }};
    var unblocked = try app.handle(unblocked_req);
    defer unblocked.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, unblocked.status);
    try testing.expectEqualStrings("Hello, world", unblocked.body.items);
}

test "router middleware applies to contained routes and nested routers" {
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();

    const nested = comptime Router.init(.{
        .prefix = "/nested",
        .middlewares = &.{appendRouterInner},
        .routes = .{
            Route.get("/item", plainText, .{}),
        },
    });
    const router = comptime Router.init(.{
        .prefix = "/api",
        .middlewares = &.{appendRouterOuter},
        .routes = .{
            Route.get("/dashboard", plainText, .{}),
            nested,
        },
    });
    const blocked_router = comptime Router.init(.{
        .prefix = "/blocked",
        .middlewares = &.{blockMiddleware},
        .routes = .{
            Route.get("/", plainText, .{}),
        },
    });

    try app.includeRouter(router);
    try app.includeRouter(blocked_router);
    try app.route(Route.get("/public", plainText, .{}));

    var dashboard = try app.handle(Request.init(.GET, "/api/dashboard"));
    defer dashboard.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, dashboard.status);
    const dashboard_order = try dashboard.headerValues(testing.allocator, "x-router-order");
    defer testing.allocator.free(dashboard_order);
    try testing.expectEqual(@as(usize, 1), dashboard_order.len);
    try testing.expectEqualStrings("outer", dashboard_order[0]);

    var nested_response = try app.handle(Request.init(.GET, "/api/nested/item"));
    defer nested_response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, nested_response.status);
    const nested_order = try nested_response.headerValues(testing.allocator, "x-router-order");
    defer testing.allocator.free(nested_order);
    try testing.expectEqual(@as(usize, 2), nested_order.len);
    try testing.expectEqualStrings("inner", nested_order[0]);
    try testing.expectEqualStrings("outer", nested_order[1]);

    var public = try app.handle(Request.init(.GET, "/public"));
    defer public.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, public.status);
    try testing.expect(public.header("x-router-order") == null);

    var blocked_req = Request.init(.GET, "/blocked");
    blocked_req.headers = &.{.{ .name = "x-block", .value = "true" }};
    var blocked = try app.handle(blocked_req);
    defer blocked.deinit(testing.allocator);
    try testing.expectEqual(Status.forbidden, blocked.status);
    try testing.expectEqualStrings("blocked", blocked.body.items);
}

test "middleware can pass request state to handlers" {
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    try app.addMiddleware(requestStateMiddleware);
    try app.route(Route.get("/state", echoRequestState, .{}));
    try app.route(Route.get("/maybe-state", echoMaybeState, .{}));

    var req = Request.init(.GET, "/state");
    req.headers = &.{.{ .name = "x-trace-id", .value = "trace-123" }};
    var response = try app.handle(req);
    defer response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, response.status);
    try testing.expectEqualStrings("{\"trace_id\":\"trace-123\"}", response.body.items);
    try testing.expectEqualStrings("yes", response.header("x-handler-seen-state").?);

    var fallback = try app.handle(Request.init(.GET, "/state"));
    defer fallback.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, fallback.status);
    try testing.expectEqualStrings("{\"trace_id\":\"generated\"}", fallback.body.items);
    try testing.expectEqualStrings("yes", fallback.header("x-handler-seen-state").?);

    var state: BackgroundState = .{};
    app.setState(&state);
    var maybe_req = Request.init(.GET, "/maybe-state");
    maybe_req.headers = &.{.{ .name = "x-trace-id", .value = "trace-456" }};
    var maybe = try app.handle(maybe_req);
    defer maybe.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, maybe.status);
    try testing.expectEqualStrings("{\"app_state\":true,\"context_state\":true,\"request_state\":true,\"trace_id\":\"trace-456\"}", maybe.body.items);
    try testing.expectEqualStrings("yes", maybe.header("x-handler-seen-state").?);

    var bare = ZAPI.init(testing.allocator, .{});
    defer bare.deinit();
    try bare.route(Route.get("/maybe-state", echoMaybeState, .{}));
    try testing.expect(bare.maybeState(BackgroundState) == null);
    var missing = try bare.handle(Request.init(.GET, "/maybe-state"));
    defer missing.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, missing.status);
    try testing.expectEqualStrings("{\"app_state\":false,\"context_state\":false,\"request_state\":false,\"trace_id\":null}", missing.body.items);
}

test "session middleware signs persists ignores tampering and clears cookies" {
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    try app.addMiddleware(sessionMiddleware(.{
        .secret_key = "test-secret",
        .max_age = 3600,
    }));
    try app.route(Route.get("/session/set", setSessionUser, .{}));
    try app.route(Route.get("/session/read", readSessionUser, .{}));
    try app.route(Route.get("/session/clear", clearSessionUser, .{}));

    var empty = try app.handle(Request.init(.GET, "/session/read"));
    defer empty.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, empty.status);
    try testing.expectEqualStrings("{\"user\":null}", empty.body.items);
    try testing.expect(empty.header("set-cookie") == null);

    var set = try app.handle(Request.init(.GET, "/session/set"));
    defer set.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, set.status);
    try testing.expectEqualStrings("set", set.body.items);
    const set_cookie = set.header("set-cookie").?;
    try testing.expect(std.mem.startsWith(u8, set_cookie, "session="));
    try testing.expect(std.mem.indexOf(u8, set_cookie, "; Max-Age=3600; Path=/; HttpOnly; SameSite=lax") != null);

    const cookie_pair_end = std.mem.indexOfScalar(u8, set_cookie, ';') orelse set_cookie.len;
    const cookie_pair = set_cookie[0..cookie_pair_end];

    var read_req = Request.init(.GET, "/session/read");
    read_req.headers = &.{.{ .name = "cookie", .value = cookie_pair }};
    var read = try app.handle(read_req);
    defer read.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, read.status);
    try testing.expectEqualStrings("{\"user\":\"ada\"}", read.body.items);
    try testing.expect(read.header("set-cookie") == null);

    const tampered_cookie = try std.fmt.allocPrint(testing.allocator, "{s}0", .{cookie_pair});
    defer testing.allocator.free(tampered_cookie);
    var tampered_req = Request.init(.GET, "/session/read");
    tampered_req.headers = &.{.{ .name = "cookie", .value = tampered_cookie }};
    var tampered = try app.handle(tampered_req);
    defer tampered.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, tampered.status);
    try testing.expectEqualStrings("{\"user\":null}", tampered.body.items);
    try testing.expect(tampered.header("set-cookie") == null);

    var clear_req = Request.init(.GET, "/session/clear");
    clear_req.headers = &.{.{ .name = "cookie", .value = cookie_pair }};
    var clear = try app.handle(clear_req);
    defer clear.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, clear.status);
    try testing.expectEqualStrings("cleared", clear.body.items);
    try testing.expectEqualStrings("session=; Max-Age=0; Expires=Thu, 01 Jan 1970 00:00:00 GMT; Path=/; HttpOnly; SameSite=lax", clear.header("set-cookie").?);
}

test "response headers can replace or append explicitly" {
    var response = Response.init(.ok);
    defer response.deinit(testing.allocator);

    try response.setHeader(testing.allocator, "X-Trace", "one");
    try response.setHeader(testing.allocator, "x-trace", "two");
    try testing.expect(response.hasHeader("X-Trace"));
    try testing.expectEqualStrings("two", response.header("x-trace").?);

    var trace_header_count: usize = 0;
    for (response.headers.items) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "x-trace")) trace_header_count += 1;
    }
    try testing.expectEqual(@as(usize, 1), trace_header_count);

    try response.appendHeader(testing.allocator, "set-cookie", "a=1");
    try response.appendHeader(testing.allocator, "set-cookie", "b=2");
    try testing.expect(response.hasHeader("Set-Cookie"));

    var cookie_header_count: usize = 0;
    for (response.headers.items) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "set-cookie")) cookie_header_count += 1;
    }
    try testing.expectEqual(@as(usize, 2), cookie_header_count);

    const cookie_headers = try response.headerValues(testing.allocator, "Set-Cookie");
    defer testing.allocator.free(cookie_headers);
    try testing.expectEqual(@as(usize, 2), cookie_headers.len);
    try testing.expectEqualStrings("a=1", cookie_headers[0]);
    try testing.expectEqualStrings("b=2", cookie_headers[1]);

    response.removeHeader(testing.allocator, "Set-Cookie");
    try testing.expect(response.header("set-cookie") == null);
    try testing.expect(!response.hasHeader("set-cookie"));
    const removed_cookie_headers = try response.headerValues(testing.allocator, "set-cookie");
    defer testing.allocator.free(removed_cookie_headers);
    try testing.expectEqual(@as(usize, 0), removed_cookie_headers.len);

    response.removeHeader(testing.allocator, "x-missing");
    const missing_headers = try response.headerValues(testing.allocator, "x-missing");
    defer testing.allocator.free(missing_headers);
    try testing.expectEqual(@as(usize, 0), missing_headers.len);

    try response.appendHeader(testing.allocator, "x-clear", "one");
    try response.appendHeader(testing.allocator, "x-clear", "two");
    response.clearHeaders(testing.allocator);
    try testing.expectEqual(@as(usize, 0), response.headers.items.len);
    try testing.expect(response.header("x-trace") == null);
    try testing.expect(response.header("x-clear") == null);
    try testing.expect(!response.hasHeader("x-trace"));
    try testing.expect(!response.hasHeader("x-clear"));
    response.clearHeaders(testing.allocator);
}

test "gzip middleware compresses accepted response bodies" {
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    try app.addMiddleware(gzipMiddleware(.{ .minimum_size = 10 }));
    try app.route(Route.get("/large", largePlainText, .{}));
    try app.route(Route.get("/varying", varyingLargePlainText, .{}));

    var req = Request.init(.GET, "/large");
    req.headers = &.{.{ .name = "accept-encoding", .value = "br, gzip;q=1.0" }};
    var response = try app.handle(req);
    defer response.deinit(testing.allocator);

    try testing.expectEqual(Status.ok, response.status);
    try testing.expectEqualStrings("gzip", response.header("content-encoding").?);
    try testing.expectEqualStrings("Accept-Encoding", response.header("vary").?);
    const compressed_len = try std.fmt.parseInt(usize, response.header("content-length").?, 10);
    try testing.expectEqual(response.body.items.len, compressed_len);
    try testing.expect(response.body.items.len < ("zapi " ** 200).len);

    const decompressed = try decompressGzipForTest(testing.allocator, response.body.items);
    defer testing.allocator.free(decompressed);
    try testing.expectEqualStrings("zapi " ** 200, decompressed);

    var varying_req = Request.init(.GET, "/varying");
    varying_req.headers = &.{.{ .name = "accept-encoding", .value = "gzip" }};
    var varying = try app.handle(varying_req);
    defer varying.deinit(testing.allocator);
    try testing.expectEqualStrings("gzip", varying.header("content-encoding").?);
    try testing.expectEqualStrings("Accept-Language, Accept-Encoding", varying.header("vary").?);
    const varying_compressed_len = try std.fmt.parseInt(usize, varying.header("content-length").?, 10);
    try testing.expectEqual(varying.body.items.len, varying_compressed_len);
}

test "gzip middleware skips small unaccepted encoded and event stream responses" {
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    try app.addMiddleware(gzipMiddleware(.{ .minimum_size = 500 }));
    try app.route(Route.get("/small", plainText, .{}));
    try app.route(Route.get("/large", largePlainText, .{}));
    try app.route(Route.get("/encoded", alreadyEncoded, .{}));
    try app.route(Route.get("/events", eventStream, .{}));

    var small_req = Request.init(.GET, "/small");
    small_req.headers = &.{.{ .name = "accept-encoding", .value = "gzip" }};
    var small = try app.handle(small_req);
    defer small.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, small.status);
    try testing.expect(small.header("content-encoding") == null);
    try testing.expectEqualStrings("Hello, world", small.body.items);

    var unaccepted = try app.handle(Request.init(.GET, "/large"));
    defer unaccepted.deinit(testing.allocator);
    try testing.expect(unaccepted.header("content-encoding") == null);
    try testing.expectEqualStrings("zapi " ** 200, unaccepted.body.items);

    var encoded_req = Request.init(.GET, "/encoded");
    encoded_req.headers = &.{.{ .name = "accept-encoding", .value = "gzip" }};
    var encoded = try app.handle(encoded_req);
    defer encoded.deinit(testing.allocator);
    try testing.expectEqualStrings("br", encoded.header("content-encoding").?);
    try testing.expectEqualStrings("encoded " ** 100, encoded.body.items);

    var events_req = Request.init(.GET, "/events");
    events_req.headers = &.{.{ .name = "accept-encoding", .value = "gzip" }};
    var events = try app.handle(events_req);
    defer events.deinit(testing.allocator);
    try testing.expect(events.header("content-encoding") == null);
    try testing.expectEqualStrings("data: zapi\n\n" ** 80, events.body.items);
}

test "gzip middleware respects accept encoding quality values" {
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    try app.addMiddleware(gzipMiddleware(.{ .minimum_size = 10 }));
    try app.route(Route.get("/large", largePlainText, .{}));

    var rejected_req = Request.init(.GET, "/large");
    rejected_req.headers = &.{.{ .name = "accept-encoding", .value = "br, gzip;q=0" }};
    var rejected = try app.handle(rejected_req);
    defer rejected.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, rejected.status);
    try testing.expect(rejected.header("content-encoding") == null);
    try testing.expectEqualStrings("zapi " ** 200, rejected.body.items);

    var wildcard_req = Request.init(.GET, "/large");
    wildcard_req.headers = &.{.{ .name = "accept-encoding", .value = "br;q=1, *;q=0.5" }};
    var wildcard = try app.handle(wildcard_req);
    defer wildcard.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, wildcard.status);
    try testing.expectEqualStrings("gzip", wildcard.header("content-encoding").?);

    var explicit_reject_req = Request.init(.GET, "/large");
    explicit_reject_req.headers = &.{.{ .name = "accept-encoding", .value = "*;q=1, gzip;q=0" }};
    var explicit_reject = try app.handle(explicit_reject_req);
    defer explicit_reject.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, explicit_reject.status);
    try testing.expect(explicit_reject.header("content-encoding") == null);
    try testing.expectEqualStrings("zapi " ** 200, explicit_reject.body.items);
}

test "cors middleware handles simple and preflight requests" {
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    try app.addMiddleware(corsMiddleware(.{
        .allow_origins = &.{"https://app.example"},
        .allow_methods = &.{ .GET, .POST },
        .allow_headers = &.{ "x-token", "content-type" },
        .allow_credentials = true,
        .expose_headers = &.{"x-zapi"},
        .max_age = 3600,
    }));
    try app.route(Route.get("/", customPayload, .{}));
    try app.route(Route.get("/varying", varyingLargePlainText, .{}));

    var simple_req = Request.init(.GET, "/");
    simple_req.headers = &.{.{ .name = "origin", .value = "https://app.example" }};
    var simple = try app.handle(simple_req);
    defer simple.deinit(testing.allocator);
    try testing.expectEqual(Status.accepted, simple.status);
    try testing.expectEqualStrings("https://app.example", simple.header("access-control-allow-origin").?);
    try testing.expectEqualStrings("true", simple.header("access-control-allow-credentials").?);
    try testing.expectEqualStrings("x-zapi", simple.header("access-control-expose-headers").?);
    try testing.expectEqualStrings("Origin", simple.header("vary").?);
    try testing.expectEqualStrings("accepted", simple.body.items);

    var varying_req = Request.init(.GET, "/varying");
    varying_req.headers = &.{.{ .name = "origin", .value = "https://app.example" }};
    var varying = try app.handle(varying_req);
    defer varying.deinit(testing.allocator);
    try testing.expectEqualStrings("Accept-Language, Origin", varying.header("vary").?);

    var preflight_req = Request.init(.OPTIONS, "/");
    preflight_req.headers = &.{
        .{ .name = "origin", .value = "https://app.example" },
        .{ .name = "access-control-request-method", .value = "POST" },
        .{ .name = "access-control-request-headers", .value = "X-Token, Content-Type" },
    };
    var preflight = try app.handle(preflight_req);
    defer preflight.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, preflight.status);
    try testing.expectEqualStrings("OK", preflight.body.items);
    try testing.expectEqualStrings("https://app.example", preflight.header("access-control-allow-origin").?);
    try testing.expectEqualStrings("GET, POST", preflight.header("access-control-allow-methods").?);
    try testing.expectEqualStrings("Accept, Accept-Language, Content-Language, Content-Type, x-token", preflight.header("access-control-allow-headers").?);
    try testing.expectEqualStrings("3600", preflight.header("access-control-max-age").?);

    var denied_method_req = Request.init(.OPTIONS, "/");
    denied_method_req.headers = &.{
        .{ .name = "origin", .value = "https://app.example" },
        .{ .name = "access-control-request-method", .value = "DELETE" },
    };
    var denied_method = try app.handle(denied_method_req);
    defer denied_method.deinit(testing.allocator);
    try testing.expectEqual(Status.bad_request, denied_method.status);
    try testing.expectEqualStrings("Disallowed CORS method", denied_method.body.items);
    try testing.expectEqualStrings("https://app.example", denied_method.header("access-control-allow-origin").?);
    try testing.expectEqualStrings("GET, POST", denied_method.header("access-control-allow-methods").?);
    try testing.expectEqualStrings("Accept, Accept-Language, Content-Language, Content-Type, x-token", denied_method.header("access-control-allow-headers").?);
    try testing.expectEqualStrings("3600", denied_method.header("access-control-max-age").?);

    var denied_headers_req = Request.init(.OPTIONS, "/");
    denied_headers_req.headers = &.{
        .{ .name = "origin", .value = "https://app.example" },
        .{ .name = "access-control-request-method", .value = "POST" },
        .{ .name = "access-control-request-headers", .value = "x-not-allowed" },
    };
    var denied_headers = try app.handle(denied_headers_req);
    defer denied_headers.deinit(testing.allocator);
    try testing.expectEqual(Status.bad_request, denied_headers.status);
    try testing.expectEqualStrings("Disallowed CORS headers", denied_headers.body.items);
    try testing.expectEqualStrings("https://app.example", denied_headers.header("access-control-allow-origin").?);
    try testing.expectEqualStrings("GET, POST", denied_headers.header("access-control-allow-methods").?);
    try testing.expectEqualStrings("Accept, Accept-Language, Content-Language, Content-Type, x-token", denied_headers.header("access-control-allow-headers").?);

    var safelisted_header_req = Request.init(.OPTIONS, "/");
    safelisted_header_req.headers = &.{
        .{ .name = "origin", .value = "https://app.example" },
        .{ .name = "access-control-request-method", .value = "POST" },
        .{ .name = "access-control-request-headers", .value = "Content-Language" },
    };
    var safelisted_header = try app.handle(safelisted_header_req);
    defer safelisted_header.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, safelisted_header.status);
    try testing.expectEqualStrings("Accept, Accept-Language, Content-Language, Content-Type, x-token", safelisted_header.header("access-control-allow-headers").?);

    var denied_origin_req = Request.init(.GET, "/");
    denied_origin_req.headers = &.{.{ .name = "origin", .value = "https://evil.example" }};
    var denied_origin = try app.handle(denied_origin_req);
    defer denied_origin.deinit(testing.allocator);
    try testing.expectEqual(Status.accepted, denied_origin.status);
    try testing.expect(denied_origin.header("access-control-allow-origin") == null);

    var denied_origin_preflight_req = Request.init(.OPTIONS, "/");
    denied_origin_preflight_req.headers = &.{
        .{ .name = "origin", .value = "https://evil.example" },
        .{ .name = "access-control-request-method", .value = "POST" },
    };
    var denied_origin_preflight = try app.handle(denied_origin_preflight_req);
    defer denied_origin_preflight.deinit(testing.allocator);
    try testing.expectEqual(Status.bad_request, denied_origin_preflight.status);
    try testing.expectEqualStrings("Disallowed CORS origin", denied_origin_preflight.body.items);
    try testing.expect(denied_origin_preflight.header("access-control-allow-origin") == null);
    try testing.expectEqualStrings("GET, POST", denied_origin_preflight.header("access-control-allow-methods").?);
    try testing.expectEqualStrings("3600", denied_origin_preflight.header("access-control-max-age").?);
}

test "cors middleware mirrors wildcard origins for cookie requests" {
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    try app.addMiddleware(corsMiddleware(.{
        .allow_origins = &.{"*"},
    }));
    try app.route(Route.get("/", plainText, .{}));

    var anonymous_req = Request.init(.GET, "/");
    anonymous_req.headers = &.{.{ .name = "origin", .value = "https://app.example" }};
    var anonymous = try app.handle(anonymous_req);
    defer anonymous.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, anonymous.status);
    try testing.expectEqualStrings("*", anonymous.header("access-control-allow-origin").?);
    try testing.expect(anonymous.header("vary") == null);

    var cookie_req = Request.init(.GET, "/");
    cookie_req.headers = &.{
        .{ .name = "origin", .value = "https://app.example" },
        .{ .name = "cookie", .value = "session=abc123" },
    };
    var cookie = try app.handle(cookie_req);
    defer cookie.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, cookie.status);
    try testing.expectEqualStrings("https://app.example", cookie.header("access-control-allow-origin").?);
    try testing.expectEqualStrings("Origin", cookie.header("vary").?);
}

test "cors middleware can allow all supported methods" {
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    try app.addMiddleware(corsMiddleware(.{
        .allow_origins = &.{"https://app.example"},
        .allow_all_methods = true,
    }));
    try app.route(Route.get("/", plainText, .{}));

    var trace_req = Request.init(.OPTIONS, "/");
    trace_req.headers = &.{
        .{ .name = "origin", .value = "https://app.example" },
        .{ .name = "access-control-request-method", .value = "TRACE" },
    };
    var trace = try app.handle(trace_req);
    defer trace.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, trace.status);
    try testing.expectEqualStrings("GET, POST, PUT, PATCH, DELETE, OPTIONS, HEAD, TRACE, CONNECT", trace.header("access-control-allow-methods").?);

    var connect_req = Request.init(.OPTIONS, "/");
    connect_req.headers = &.{
        .{ .name = "origin", .value = "https://app.example" },
        .{ .name = "access-control-request-method", .value = "CONNECT" },
    };
    var connect = try app.handle(connect_req);
    defer connect.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, connect.status);
    try testing.expectEqualStrings("GET, POST, PUT, PATCH, DELETE, OPTIONS, HEAD, TRACE, CONNECT", connect.header("access-control-allow-methods").?);

    var unknown_req = Request.init(.OPTIONS, "/");
    unknown_req.headers = &.{
        .{ .name = "origin", .value = "https://app.example" },
        .{ .name = "access-control-request-method", .value = "BREW" },
    };
    var unknown = try app.handle(unknown_req);
    defer unknown.deinit(testing.allocator);
    try testing.expectEqual(Status.bad_request, unknown.status);
    try testing.expectEqualStrings("Disallowed CORS method", unknown.body.items);
}

test "cors middleware supports wildcard origin patterns" {
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    try app.addMiddleware(corsMiddleware(.{
        .allow_origins = &.{},
        .allow_origin_patterns = &.{ "https://*.example.com", "https://admin-*.example.org" },
        .allow_methods = &.{ .GET, .POST },
        .allow_headers = &.{"x-token"},
    }));
    try app.route(Route.get("/", plainText, .{}));

    var simple_req = Request.init(.GET, "/");
    simple_req.headers = &.{.{ .name = "origin", .value = "https://app.example.com" }};
    var simple = try app.handle(simple_req);
    defer simple.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, simple.status);
    try testing.expectEqualStrings("https://app.example.com", simple.header("access-control-allow-origin").?);
    try testing.expectEqualStrings("Origin", simple.header("vary").?);

    var admin_req = Request.init(.OPTIONS, "/");
    admin_req.headers = &.{
        .{ .name = "origin", .value = "https://admin-eu.example.org" },
        .{ .name = "access-control-request-method", .value = "POST" },
        .{ .name = "access-control-request-headers", .value = "x-token" },
    };
    var admin = try app.handle(admin_req);
    defer admin.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, admin.status);
    try testing.expectEqualStrings("https://admin-eu.example.org", admin.header("access-control-allow-origin").?);
    try testing.expectEqualStrings("GET, POST", admin.header("access-control-allow-methods").?);
    try testing.expectEqualStrings("Accept, Accept-Language, Content-Language, Content-Type, x-token", admin.header("access-control-allow-headers").?);

    var suffix_req = Request.init(.GET, "/");
    suffix_req.headers = &.{.{ .name = "origin", .value = "https://notexample.com" }};
    var suffix = try app.handle(suffix_req);
    defer suffix.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, suffix.status);
    try testing.expect(suffix.header("access-control-allow-origin") == null);
}

test "proxy headers middleware updates downstream scheme host and root path" {
    var app = ZAPI.init(testing.allocator, .{ .title = "Proxy API", .version = "1.0.0" });
    defer app.deinit();
    try app.addMiddleware(proxyHeadersMiddleware(.{}));
    try app.addMiddleware(httpsRedirectMiddleware(.{}));
    try app.addMiddleware(trustedHostMiddleware(.{
        .allowed_hosts = &.{"public.example"},
    }));
    try app.route(Route.get("/", echoRequestScope, .{}));

    var req = Request.init(.GET, "/");
    req.scheme = "http";
    req.headers = &.{
        .{ .name = "host", .value = "internal.local" },
        .{ .name = "x-forwarded-proto", .value = "https" },
        .{ .name = "x-forwarded-host", .value = "public.example" },
        .{ .name = "x-forwarded-prefix", .value = "/api/" },
    };
    var response = try app.handle(req);
    defer response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, response.status);
    try testing.expectEqualStrings("{\"scheme\":\"https\",\"host\":\"public.example\",\"root_path\":\"/api\"}", response.body.items);

    var docs_req = Request.init(.GET, "/docs");
    docs_req.headers = &.{
        .{ .name = "x-forwarded-proto", .value = "https" },
        .{ .name = "x-forwarded-host", .value = "public.example" },
        .{ .name = "x-forwarded-prefix", .value = "/api" },
    };
    var docs = try app.handle(docs_req);
    defer docs.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, docs.status);
    try testing.expect(std.mem.indexOf(u8, docs.body.items, "url: \"/api/openapi.json\"") != null);

    var openapi_req = Request.init(.GET, "/openapi.json");
    openapi_req.headers = &.{
        .{ .name = "x-forwarded-proto", .value = "https" },
        .{ .name = "x-forwarded-host", .value = "public.example" },
        .{ .name = "x-forwarded-prefix", .value = "/api" },
    };
    var openapi = try app.handle(openapi_req);
    defer openapi.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, openapi.status);
    try expectJsonEqual(
        \\{
        \\  "openapi": "3.1.0",
        \\  "info": {
        \\    "title": "Proxy API",
        \\    "version": "1.0.0"
        \\  },
        \\  "servers": [
        \\    {"url": "/api"}
        \\  ],
        \\  "paths": {
        \\    "/": {
        \\      "get": {
        \\        "operationId": "get_root",
        \\        "responses": {
        \\          "200": {
        \\            "description": "OK",
        \\            "content": {
        \\              "application/json": {
        \\                "schema": {"$ref": "#/components/schemas/RequestScopeEcho"}
        \\              }
        \\            }
        \\          }
        \\        }
        \\      }
        \\    }
        \\  },
        \\  "components": {
        \\    "schemas": {
        \\      "RequestScopeEcho": {
        \\        "type": "object",
        \\        "properties": {
        \\          "scheme": {"type": "string"},
        \\          "host": {"type": "string"},
        \\          "root_path": {"type": "string"}
        \\        },
        \\        "required": ["scheme", "host", "root_path"],
        \\        "additionalProperties": false
        \\      }
        \\    }
        \\  }
        \\}
    ,
        openapi.body.items,
    );
}

test "request id middleware propagates request ids and optional defaults" {
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    try app.addMiddleware(requestIdMiddleware(.{}));
    try app.route(Route.get("/", plainText, .{}));

    var req = Request.init(.GET, "/");
    req.headers = &.{.{ .name = "x-request-id", .value = "req-123" }};
    var response = try app.handle(req);
    defer response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, response.status);
    try testing.expectEqualStrings("req-123", response.header("x-request-id").?);

    var missing = try app.handle(Request.init(.GET, "/"));
    defer missing.deinit(testing.allocator);
    try testing.expect(missing.header("x-request-id") == null);

    var empty_req = Request.init(.GET, "/");
    empty_req.headers = &.{.{ .name = "x-request-id", .value = "" }};
    var empty = try app.handle(empty_req);
    defer empty.deinit(testing.allocator);
    try testing.expect(empty.header("x-request-id") == null);

    var fallback_app = ZAPI.init(testing.allocator, .{});
    defer fallback_app.deinit();
    try fallback_app.addMiddleware(requestIdMiddleware(.{ .default_value = "generated-for-tests" }));
    try fallback_app.route(Route.get("/", plainText, .{}));

    var fallback = try fallback_app.handle(Request.init(.GET, "/"));
    defer fallback.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, fallback.status);
    try testing.expectEqualStrings("generated-for-tests", fallback.header("x-request-id").?);
}

test "security headers middleware sets defaults configured values and preserves existing headers" {
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    try app.addMiddleware(securityHeadersMiddleware(.{}));
    try app.route(Route.get("/", plainText, .{}));

    var response = try app.handle(Request.init(.GET, "/"));
    defer response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, response.status);
    try testing.expectEqualStrings("nosniff", response.header("x-content-type-options").?);
    try testing.expectEqualStrings("DENY", response.header("x-frame-options").?);
    try testing.expectEqualStrings("no-referrer", response.header("referrer-policy").?);
    try testing.expect(response.header("permissions-policy") == null);
    try testing.expect(response.header("content-security-policy") == null);
    try testing.expect(response.header("strict-transport-security") == null);

    var configured_app = ZAPI.init(testing.allocator, .{});
    defer configured_app.deinit();
    try configured_app.addMiddleware(securityHeadersMiddleware(.{
        .frame_options = null,
        .permissions_policy = "geolocation=()",
        .content_security_policy = "default-src 'self'",
        .strict_transport_security = "max-age=31536000",
    }));
    try configured_app.route(Route.get("/", plainText, .{}));

    var configured = try configured_app.handle(Request.init(.GET, "/"));
    defer configured.deinit(testing.allocator);
    try testing.expectEqualStrings("nosniff", configured.header("x-content-type-options").?);
    try testing.expect(configured.header("x-frame-options") == null);
    try testing.expectEqualStrings("geolocation=()", configured.header("permissions-policy").?);
    try testing.expectEqualStrings("default-src 'self'", configured.header("content-security-policy").?);
    try testing.expectEqualStrings("max-age=31536000", configured.header("strict-transport-security").?);

    var preserve_app = ZAPI.init(testing.allocator, .{});
    defer preserve_app.deinit();
    try preserve_app.addMiddleware(securityHeadersMiddleware(.{}));
    try preserve_app.addMiddleware(setFrameOptionsMiddleware);
    try preserve_app.route(Route.get("/", plainText, .{}));

    var preserved = try preserve_app.handle(Request.init(.GET, "/"));
    defer preserved.deinit(testing.allocator);
    try testing.expectEqualStrings("SAMEORIGIN", preserved.header("x-frame-options").?);
    try testing.expectEqualStrings("nosniff", preserved.header("x-content-type-options").?);
}

test "https redirect middleware redirects insecure requests" {
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    try app.addMiddleware(httpsRedirectMiddleware(.{}));
    try app.route(Route.get("/", plainText, .{}));

    var insecure_req = Request.init(.GET, "/secure?q=zig");
    insecure_req.headers = &.{.{ .name = "host", .value = "example.com:8080" }};
    var insecure = try app.handle(insecure_req);
    defer insecure.deinit(testing.allocator);
    try testing.expectEqual(Status.temporary_redirect, insecure.status);
    try testing.expectEqualStrings("https://example.com:8080/secure?q=zig", insecure.header("location").?);
    try testing.expectEqualStrings("", insecure.body.items);

    var secure_req = Request.init(.GET, "/");
    secure_req.scheme = "https";
    secure_req.headers = &.{.{ .name = "host", .value = "example.com" }};
    var secure = try app.handle(secure_req);
    defer secure.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, secure.status);
    try testing.expectEqualStrings("Hello, world", secure.body.items);

    var no_host = try app.handle(Request.init(.GET, "/"));
    defer no_host.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, no_host.status);
}

test "trusted host middleware validates host headers and redirects www" {
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    try app.addMiddleware(trustedHostMiddleware(.{
        .allowed_hosts = &.{ "example.com", "*.example.org" },
        .www_redirect = true,
    }));
    try app.route(Route.get("/", plainText, .{}));

    var allowed_req = Request.init(.GET, "/");
    allowed_req.headers = &.{.{ .name = "host", .value = "example.com:8080" }};
    var allowed = try app.handle(allowed_req);
    defer allowed.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, allowed.status);
    try testing.expectEqualStrings("Hello, world", allowed.body.items);

    var wildcard_req = Request.init(.GET, "/");
    wildcard_req.headers = &.{.{ .name = "host", .value = "api.example.org" }};
    var wildcard = try app.handle(wildcard_req);
    defer wildcard.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, wildcard.status);

    var redirect_req = Request.init(.GET, "/?q=zig");
    redirect_req.headers = &.{.{ .name = "host", .value = "www.example.com:8080" }};
    var redirect = try app.handle(redirect_req);
    defer redirect.deinit(testing.allocator);
    try testing.expectEqual(Status.permanent_redirect, redirect.status);
    try testing.expectEqualStrings("http://example.com:8080/?q=zig", redirect.header("location").?);

    var secure_redirect_req = Request.init(.GET, "/secure");
    secure_redirect_req.scheme = "https";
    secure_redirect_req.headers = &.{.{ .name = "host", .value = "www.example.com" }};
    var secure_redirect = try app.handle(secure_redirect_req);
    defer secure_redirect.deinit(testing.allocator);
    try testing.expectEqual(Status.permanent_redirect, secure_redirect.status);
    try testing.expectEqualStrings("https://example.com/secure", secure_redirect.header("location").?);

    var www_app = ZAPI.init(testing.allocator, .{});
    defer www_app.deinit();
    try www_app.addMiddleware(trustedHostMiddleware(.{
        .allowed_hosts = &.{"www.example.net"},
        .www_redirect = true,
    }));
    try www_app.route(Route.get("/", plainText, .{}));

    var add_www_req = Request.init(.GET, "/docs?q=zig");
    add_www_req.headers = &.{.{ .name = "host", .value = "example.net:8443" }};
    var add_www = try www_app.handle(add_www_req);
    defer add_www.deinit(testing.allocator);
    try testing.expectEqual(Status.permanent_redirect, add_www.status);
    try testing.expectEqualStrings("http://www.example.net:8443/docs?q=zig", add_www.header("location").?);

    var denied_req = Request.init(.GET, "/");
    denied_req.headers = &.{.{ .name = "host", .value = "evil.example.net" }};
    var denied = try app.handle(denied_req);
    defer denied.deinit(testing.allocator);
    try testing.expectEqual(Status.bad_request, denied.status);
    try testing.expectEqualStrings("Invalid host header", denied.body.items);

    var missing = try app.handle(Request.init(.GET, "/"));
    defer missing.deinit(testing.allocator);
    try testing.expectEqual(Status.bad_request, missing.status);
    try testing.expectEqualStrings("Invalid host header", missing.body.items);
}

test "exception handlers customize route middleware and fallback errors" {
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    try app.addExceptionHandler(error.Teapot, handleTeapot);
    try app.addExceptionHandler(error.MiddlewareBoom, handleMiddlewareBoom);
    try app.route(Route.get("/teapot", failingRoute, .{}));
    try app.route(Route.get("/unhandled", unhandledFailingRoute, .{}));

    var handled = try app.handle(Request.init(.GET, "/teapot"));
    defer handled.deinit(testing.allocator);
    try testing.expectEqual(Status.conflict, handled.status);
    try testing.expectEqualStrings("text/plain; charset=utf-8", handled.header("content-type").?);
    try testing.expectEqualStrings("Teapot", handled.header("x-error").?);
    try testing.expectEqualStrings("handled /teapot", handled.body.items);

    var unhandled = try app.handle(Request.init(.GET, "/unhandled"));
    defer unhandled.deinit(testing.allocator);
    try testing.expectEqual(Status.internal_server_error, unhandled.status);
    try testing.expectEqualStrings("application/json", unhandled.header("content-type").?);
    try testing.expectEqualStrings("{\"detail\":\"Internal server error\"}", unhandled.body.items);

    var middleware_app = ZAPI.init(testing.allocator, .{});
    defer middleware_app.deinit();
    try middleware_app.addExceptionHandler(error.MiddlewareBoom, handleMiddlewareBoom);
    try middleware_app.addMiddleware(failMiddleware);
    try middleware_app.route(Route.get("/", plainText, .{}));

    var middleware_response = try middleware_app.handle(Request.init(.GET, "/middleware"));
    defer middleware_response.deinit(testing.allocator);
    try testing.expectEqual(Status.forbidden, middleware_response.status);
    try testing.expectEqualStrings("middleware /middleware", middleware_response.body.items);
}

test "status handlers customize framework generated responses" {
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    try app.addStatusHandler(.not_found, handleStatusPlain);
    try app.addStatusHandler(.method_not_allowed, handleStatusPlain);
    try app.addStatusHandler(.internal_server_error, handleStatusPlain);
    try app.route(Route.get("/", plainText, .{}));
    try app.route(Route.get("/unhandled", unhandledFailingRoute, .{}));

    var missing = try app.handle(Request.init(.GET, "/missing"));
    defer missing.deinit(testing.allocator);
    try testing.expectEqual(Status.not_found, missing.status);
    try testing.expectEqualStrings("text/plain; charset=utf-8", missing.header("content-type").?);
    try testing.expectEqualStrings("404 /missing Not found", missing.body.items);

    var wrong_method = try app.handle(Request.init(.POST, "/"));
    defer wrong_method.deinit(testing.allocator);
    try testing.expectEqual(Status.method_not_allowed, wrong_method.status);
    try testing.expectEqualStrings("HEAD, GET, OPTIONS", wrong_method.header("allow").?);
    try testing.expectEqualStrings("405 / Method not allowed", wrong_method.body.items);

    var unhandled = try app.handle(Request.init(.GET, "/unhandled"));
    defer unhandled.deinit(testing.allocator);
    try testing.expectEqual(Status.internal_server_error, unhandled.status);
    try testing.expectEqualStrings("text/plain; charset=utf-8", unhandled.header("content-type").?);
    try testing.expectEqualStrings("500 /unhandled Internal server error", unhandled.body.items);
}

test "status handler registration replaces existing handler" {
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    try app.addStatusHandler(.not_found, handleStatusPlain);
    try app.addStatusHandler(.not_found, handleStatusReplacement);

    var response = try app.handle(Request.init(.GET, "/missing"));
    defer response.deinit(testing.allocator);
    try testing.expectEqual(Status.not_found, response.status);
    try testing.expectEqualStrings("status replacement", response.body.items);
}

test "exception handler registration replaces existing handler for an error" {
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    try app.addExceptionHandler(error.Teapot, handleTeapot);
    try app.addExceptionHandler(error.Teapot, handleTeapotReplacement);
    try app.route(Route.get("/teapot", failingRoute, .{}));

    var response = try app.handle(Request.init(.GET, "/teapot"));
    defer response.deinit(testing.allocator);
    try testing.expectEqual(Status.accepted, response.status);
    try testing.expectEqualStrings("replacement", response.body.items);
}

test "mounted sub applications route through prefixes middleware and url reversing" {
    var parent = ZAPI.init(testing.allocator, .{});
    defer parent.deinit();
    var child = ZAPI.init(testing.allocator, .{});
    defer child.deinit();
    var nested = ZAPI.init(testing.allocator, .{});
    defer nested.deinit();
    var tenant_child = ZAPI.init(testing.allocator, .{});
    defer tenant_child.deinit();
    var root_child = ZAPI.init(testing.allocator, .{});
    defer root_child.deinit();

    try parent.addMiddleware(addMiddlewareHeader);
    try nested.route(Route.get("/", plainText, .{}));
    try child.route(Route.get("/", plainText, .{}));
    try child.route(Route.get("/users/{id:int}", getUser, .{ .name = "mounted_user" }));
    try child.mountNamed("/nested", "nested", &nested);
    try tenant_child.route(Route.get("/users/{id:int}", mountedTenantUser, .{ .name = "user" }));
    try root_child.route(Route.get("/root-mounted", plainText, .{}));
    try root_child.route(Route.get("/users/{id:int}", getUser, .{ .name = "root_user" }));
    try parent.mountNamed("/api/", "api", &child);
    try parent.mountNamed("/{tenant}/api", "tenant_api", &tenant_child);
    try parent.mountNamed("/", "root", &root_child);

    var response = try parent.handle(Request.init(.GET, "/api/users/42?verbose=true"));
    defer response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, response.status);
    try testing.expectEqualStrings("{\"id\":42,\"email\":\"ada@example.com\"}", response.body.items);
    try testing.expectEqualStrings("yes", response.header("x-middleware").?);

    var root = try parent.handle(Request.init(.GET, "/api"));
    defer root.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, root.status);
    try testing.expectEqualStrings("Hello, world", root.body.items);
    try testing.expectEqualStrings("yes", root.header("x-middleware").?);

    var slash_redirect = try parent.handle(Request.init(.POST, "/api/users/42/?verbose=true"));
    defer slash_redirect.deinit(testing.allocator);
    try testing.expectEqual(Status.temporary_redirect, slash_redirect.status);
    try testing.expectEqualStrings("/api/users/42?verbose=true", slash_redirect.header("location").?);

    var boundary_miss = try parent.handle(Request.init(.GET, "/apix/users/42"));
    defer boundary_miss.deinit(testing.allocator);
    try testing.expectEqual(Status.not_found, boundary_miss.status);

    var tenant_response = try parent.handle(Request.init(.GET, "/acme/api/users/42"));
    defer tenant_response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, tenant_response.status);
    try testing.expectEqualStrings("{\"tenant\":\"acme\",\"id\":42,\"root_path\":\"/acme/api\"}", tenant_response.body.items);
    try testing.expectEqualStrings("yes", tenant_response.header("x-middleware").?);

    var root_mount_response = try parent.handle(Request.init(.GET, "/root-mounted"));
    defer root_mount_response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, root_mount_response.status);
    try testing.expectEqualStrings("Hello, world", root_mount_response.body.items);
    try testing.expectEqualStrings("yes", root_mount_response.header("x-middleware").?);

    const path = try parent.urlPathFor("mounted_user", .{ .id = 5 });
    defer testing.allocator.free(path);
    try testing.expectEqualStrings("/api/users/5", path);

    const namespaced_path = try parent.urlPathFor("api:mounted_user", .{ .id = 6 });
    defer testing.allocator.free(namespaced_path);
    try testing.expectEqualStrings("/api/users/6", namespaced_path);

    const mount_path = try parent.urlPathFor("api", .{ .path = "/docs" });
    defer testing.allocator.free(mount_path);
    try testing.expectEqualStrings("/api/docs", mount_path);

    const mount_relative_path = try parent.urlPathFor("api", .{ .path = "docs" });
    defer testing.allocator.free(mount_relative_path);
    try testing.expectEqualStrings("/api/docs", mount_relative_path);

    const nested_mount_path = try parent.urlPathFor("api:nested", .{ .path = "/docs" });
    defer testing.allocator.free(nested_mount_path);
    try testing.expectEqualStrings("/api/nested/docs", nested_mount_path);

    const nested_mount_relative_path = try parent.urlPathFor("api:nested", .{ .path = "docs" });
    defer testing.allocator.free(nested_mount_relative_path);
    try testing.expectEqualStrings("/api/nested/docs", nested_mount_relative_path);

    const encoded_mount_path = try parent.urlPathFor("api", .{ .path = "/docs/search page/\xe2\x9c\x93" });
    defer testing.allocator.free(encoded_mount_path);
    try testing.expectEqualStrings("/api/docs/search%20page/%E2%9C%93", encoded_mount_path);

    const tenant_namespaced_path = try parent.urlPathFor("tenant_api:user", .{ .tenant = "acme", .id = 7 });
    defer testing.allocator.free(tenant_namespaced_path);
    try testing.expectEqualStrings("/acme/api/users/7", tenant_namespaced_path);

    const tenant_mount_path = try parent.urlPathFor("tenant_api", .{ .tenant = "acme", .path = "/docs" });
    defer testing.allocator.free(tenant_mount_path);
    try testing.expectEqualStrings("/acme/api/docs", tenant_mount_path);

    const root_namespaced_path = try parent.urlPathFor("root:root_user", .{ .id = 8 });
    defer testing.allocator.free(root_namespaced_path);
    try testing.expectEqualStrings("/users/8", root_namespaced_path);

    const root_mount_path = try parent.urlPathFor("root", .{ .path = "/docs" });
    defer testing.allocator.free(root_mount_path);
    try testing.expectEqualStrings("/docs", root_mount_path);

    try testing.expectError(error.NoRoute, parent.urlPathFor("api", .{}));
    try testing.expectError(error.NoRoute, parent.urlPathFor("api:mounted_user", .{}));
    try testing.expectError(error.NoRoute, parent.urlPathFor("tenant_api:user", .{ .id = 7 }));
    try testing.expectError(error.NoRoute, parent.urlPathFor("api:mounted_user", .{ .id = 6, .extra = "unused" }));
    try testing.expectError(error.NoRoute, parent.urlPathFor("tenant_api:user", .{ .tenant = "acme", .id = 7, .extra = "unused" }));
    try testing.expectError(error.NoRoute, parent.urlPathFor("tenant_api", .{ .tenant = "acme", .path = "/docs", .extra = "unused" }));
    try testing.expectError(error.InvalidPathParam, parent.urlPathFor("api", .{ .path = "bad\\path" }));
    try testing.expectError(error.InvalidMountPath, parent.mount("", &child));
    try testing.expectError(error.InvalidMountPath, parent.mount("/{rest:path}", &child));
    try testing.expectError(error.InvalidMountName, parent.mountNamed("/bad", "", &child));
    try testing.expectError(error.InvalidMountName, parent.mountNamed("/bad", "api:users", &child));
}

test "host mounted applications route by host header" {
    var www = ZAPI.init(testing.allocator, .{});
    defer www.deinit();
    try www.route(Route.get("/", plainText, .{}));
    try www.route(Route.get("/hosted", hostText, .{}));

    var api = ZAPI.init(testing.allocator, .{});
    defer api.deinit();
    try api.route(Route.get("/users", listUsers, .{ .name = "users" }));
    try api.route(Route.get("/urls", hostedUrlEcho, .{}));

    var subdomains = ZAPI.init(testing.allocator, .{});
    defer subdomains.deinit();
    try subdomains.route(Route.get("/", hostParamEcho, .{ .name = "home" }));

    var parent = ZAPI.init(testing.allocator, .{});
    defer parent.deinit();
    try parent.host("www.example.org", &www);
    try parent.hostNamed("api.example.org:3600", "api", &api);
    try parent.hostNamed("{subdomain}.example.org", "subdomains", &subdomains);

    var api_req = Request.init(.GET, "/users");
    api_req.headers = &.{.{ .name = "host", .value = "api.example.org" }};
    var api_response = try parent.handle(api_req);
    defer api_response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, api_response.status);
    try testing.expectEqualStrings("{\"users\":[{\"id\":1,\"email\":\"ada@example.com\"}]}", api_response.body.items);

    var api_port_req = Request.init(.GET, "/users");
    api_port_req.headers = &.{.{ .name = "host", .value = "api.example.org:5600" }};
    var api_port_response = try parent.handle(api_port_req);
    defer api_port_response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, api_port_response.status);

    var api_url_req = Request.init(.GET, "/urls");
    api_url_req.scheme = "https";
    api_url_req.headers = &.{.{ .name = "host", .value = "api.example.org" }};
    var api_url_response = try parent.handle(api_url_req);
    defer api_url_response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, api_url_response.status);
    try testing.expectEqualStrings("{\"local_path\":\"/users\",\"local_url\":\"https://api.example.org/users\",\"namespaced_url\":\"https://api.example.org/users\"}", api_url_response.body.items);

    var api_missing_path_req = Request.init(.GET, "/");
    api_missing_path_req.headers = &.{.{ .name = "host", .value = "api.example.org" }};
    var api_missing_path = try parent.handle(api_missing_path_req);
    defer api_missing_path.deinit(testing.allocator);
    try testing.expectEqual(Status.not_found, api_missing_path.status);

    var www_req = Request.init(.GET, "/hosted");
    www_req.headers = &.{.{ .name = "host", .value = "WWW.EXAMPLE.ORG:443" }};
    var www_response = try parent.handle(www_req);
    defer www_response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, www_response.status);
    try testing.expectEqualStrings("hosted", www_response.body.items);

    var unknown_req = Request.init(.GET, "/hosted");
    unknown_req.headers = &.{.{ .name = "host", .value = "unknown.example.org" }};
    var unknown = try parent.handle(unknown_req);
    defer unknown.deinit(testing.allocator);
    try testing.expectEqual(Status.not_found, unknown.status);

    var subdomain_req = Request.init(.GET, "/");
    subdomain_req.headers = &.{.{ .name = "host", .value = "blog.example.org" }};
    var subdomain_response = try parent.handle(subdomain_req);
    defer subdomain_response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, subdomain_response.status);
    try testing.expectEqualStrings("{\"value\":\"blog\"}", subdomain_response.body.items);

    const api_users_url = try parent.urlForHost("api:users", .{}, "https");
    defer testing.allocator.free(api_users_url);
    try testing.expectEqualStrings("https://api.example.org:3600/users", api_users_url);

    const api_docs_url = try parent.urlForHost("api", .{ .path = "/docs" }, "https");
    defer testing.allocator.free(api_docs_url);
    try testing.expectEqualStrings("https://api.example.org:3600/docs", api_docs_url);

    const subdomain_url = try parent.urlForHost("subdomains:home", .{ .subdomain = "blog" }, "https");
    defer testing.allocator.free(subdomain_url);
    try testing.expectEqualStrings("https://blog.example.org/", subdomain_url);

    try testing.expectError(error.NoRoute, parent.urlForHost("api:missing", .{}, "https"));
    try testing.expectError(error.NoRoute, parent.urlForHost("subdomains:home", .{}, "https"));
    try testing.expectError(error.NoRoute, parent.urlForHost("subdomains:home", .{ .subdomain = "blog", .extra = "unused" }, "https"));
    try testing.expectError(error.InvalidHostPattern, parent.host("", &www));
    try testing.expectError(error.InvalidHostPattern, parent.host("bad host", &www));
    try testing.expectError(error.InvalidHostPattern, parent.host("example.org/path", &www));
    try testing.expectError(error.InvalidHostPattern, parent.host("{subdomain", &www));
    try testing.expectError(error.InvalidHostPattern, parent.host("{subdomain:path}.example.org", &www));
    try testing.expectError(error.InvalidHostPattern, parent.host("{sub-domain}.example.org", &www));
    try testing.expectError(error.InvalidHostPattern, parent.host("{1subdomain}.example.org", &www));
    try testing.expectError(error.DuplicateHostParam, parent.host("{subdomain}.{subdomain}.example.org", &www));
    try testing.expectError(error.InvalidHostName, parent.hostNamed("other.example.org", "", &www));
    try testing.expectError(error.InvalidHostName, parent.hostNamed("other.example.org", "api:users", &www));
}

test "mount and host route specs register apps directly and through router specs" {
    var api = ZAPI.init(testing.allocator, .{});
    defer api.deinit();
    try api.route(Route.get("/users", listUsers, .{ .name = "users" }));

    var hosted = ZAPI.init(testing.allocator, .{});
    defer hosted.deinit();
    try hosted.route(Route.get("/hosted", hostText, .{ .name = "hosted" }));

    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    try app.route(Route.mount("/direct", &api, .{ .name = "direct" }));
    try app.includeRouter(RouterSpec{
        .prefix = "/v1",
        .routes = &.{
            Route.get("/health", plainText, .{ .name = "health" }),
        },
        .mounts = &.{
            Route.mount("/api", &api, .{ .name = "api" }),
        },
        .hosts = &.{
            Route.host("api.example.test:8443", &hosted, .{ .name = "hosted_app" }),
        },
    });
    const nested_router = Router.init(.{
        .prefix = "/nested",
        .routes = .{
            Route.mount("/api", &api, .{ .name = "nested_api" }),
        },
    });
    const mixed_router = Router.init(.{
        .prefix = "/v2",
        .routes = .{
            Route.get("/health", plainText, .{ .name = "router_health" }),
            Route.mount("/api", &api, .{ .name = "router_api" }),
            Route.host("router.example.test:9443", &hosted, .{ .name = "router_hosted" }),
            nested_router,
        },
    });
    try app.includeRouter(mixed_router);

    var direct_response = try app.handle(Request.init(.GET, "/direct/users"));
    defer direct_response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, direct_response.status);
    try testing.expectEqualStrings("{\"users\":[{\"id\":1,\"email\":\"ada@example.com\"}]}", direct_response.body.items);

    var mounted_response = try app.handle(Request.init(.GET, "/v1/api/users"));
    defer mounted_response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, mounted_response.status);
    try testing.expectEqualStrings("{\"users\":[{\"id\":1,\"email\":\"ada@example.com\"}]}", mounted_response.body.items);

    var health_response = try app.handle(Request.init(.GET, "/v1/health"));
    defer health_response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, health_response.status);
    try testing.expectEqualStrings("Hello, world", health_response.body.items);

    var hosted_request = Request.init(.GET, "/hosted");
    hosted_request.headers = &.{.{ .name = "host", .value = "api.example.test" }};
    var hosted_response = try app.handle(hosted_request);
    defer hosted_response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, hosted_response.status);
    try testing.expectEqualStrings("hosted", hosted_response.body.items);

    var router_mounted_response = try app.handle(Request.init(.GET, "/v2/api/users"));
    defer router_mounted_response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, router_mounted_response.status);
    try testing.expectEqualStrings("{\"users\":[{\"id\":1,\"email\":\"ada@example.com\"}]}", router_mounted_response.body.items);

    var nested_mounted_response = try app.handle(Request.init(.GET, "/v2/nested/api/users"));
    defer nested_mounted_response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, nested_mounted_response.status);
    try testing.expectEqualStrings("{\"users\":[{\"id\":1,\"email\":\"ada@example.com\"}]}", nested_mounted_response.body.items);

    var router_hosted_request = Request.init(.GET, "/hosted");
    router_hosted_request.headers = &.{.{ .name = "host", .value = "router.example.test" }};
    var router_hosted_response = try app.handle(router_hosted_request);
    defer router_hosted_response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, router_hosted_response.status);
    try testing.expectEqualStrings("hosted", router_hosted_response.body.items);

    const direct_path = try app.urlPathFor("direct:users", .{});
    defer testing.allocator.free(direct_path);
    try testing.expectEqualStrings("/direct/users", direct_path);

    const mounted_path = try app.urlPathFor("api:users", .{});
    defer testing.allocator.free(mounted_path);
    try testing.expectEqualStrings("/v1/api/users", mounted_path);

    const health_path = try app.urlPathFor("health", .{});
    defer testing.allocator.free(health_path);
    try testing.expectEqualStrings("/v1/health", health_path);

    const router_mounted_path = try app.urlPathFor("router_api:users", .{});
    defer testing.allocator.free(router_mounted_path);
    try testing.expectEqualStrings("/v2/api/users", router_mounted_path);

    const nested_mounted_path = try app.urlPathFor("nested_api:users", .{});
    defer testing.allocator.free(nested_mounted_path);
    try testing.expectEqualStrings("/v2/nested/api/users", nested_mounted_path);

    const hosted_url = try app.urlForHost("hosted_app:hosted", .{}, "https");
    defer testing.allocator.free(hosted_url);
    try testing.expectEqualStrings("https://api.example.test:8443/hosted", hosted_url);

    const router_hosted_url = try app.urlForHost("router_hosted:hosted", .{}, "https");
    defer testing.allocator.free(router_hosted_url);
    try testing.expectEqualStrings("https://router.example.test:9443/hosted", router_hosted_url);
}

test "includeRoutes registers mixed Starlette style route objects at runtime" {
    var api = ZAPI.init(testing.allocator, .{});
    defer api.deinit();
    try api.route(Route.get("/users", listUsers, .{ .name = "users" }));

    var hosted = ZAPI.init(testing.allocator, .{});
    defer hosted.deinit();
    try hosted.route(Route.get("/hosted", hostText, .{ .name = "hosted" }));

    const nested = comptime Router.init(.{
        .prefix = "/nested",
        .routes = .{
            get("/item", plainText, .{ .name = "nested_item" }),
        },
    });

    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    try app.includeRoutes(.{
        .prefix = "/v2",
        .tags = &.{"v2"},
        .middlewares = &.{addMiddlewareHeader},
        .routes = .{
            get("/health", plainText, .{ .name = "health" }),
            methods("/ping", &.{ .GET, .POST }, plainText, .{ .name = "ping" }),
            nested,
            mount("/api", &api, .{ .name = "api" }),
            Route.host("include.example.test:9443", &hosted, .{ .name = "hosted_app" }),
        },
    });

    var health = try app.handle(Request.init(.GET, "/v2/health"));
    defer health.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, health.status);
    try testing.expectEqualStrings("Hello, world", health.body.items);
    try testing.expectEqualStrings("yes", health.header("x-middleware").?);

    var ping = try app.handle(Request.init(.POST, "/v2/ping"));
    defer ping.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, ping.status);
    try testing.expectEqualStrings("yes", ping.header("x-middleware").?);

    var nested_response = try app.handle(Request.init(.GET, "/v2/nested/item"));
    defer nested_response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, nested_response.status);
    try testing.expectEqualStrings("yes", nested_response.header("x-middleware").?);

    var mounted = try app.handle(Request.init(.GET, "/v2/api/users"));
    defer mounted.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, mounted.status);
    try testing.expectEqualStrings("{\"users\":[{\"id\":1,\"email\":\"ada@example.com\"}]}", mounted.body.items);

    var hosted_request = Request.init(.GET, "/hosted");
    hosted_request.headers = &.{.{ .name = "host", .value = "include.example.test" }};
    var hosted_response = try app.handle(hosted_request);
    defer hosted_response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, hosted_response.status);
    try testing.expectEqualStrings("hosted", hosted_response.body.items);

    const mounted_path = try app.urlPathFor("api:users", .{});
    defer testing.allocator.free(mounted_path);
    try testing.expectEqualStrings("/v2/api/users", mounted_path);

    const nested_path = try app.urlPathFor("nested_item", .{});
    defer testing.allocator.free(nested_path);
    try testing.expectEqualStrings("/v2/nested/item", nested_path);

    const hosted_url = try app.urlForHost("hosted_app:hosted", .{}, "https");
    defer testing.allocator.free(hosted_url);
    try testing.expectEqualStrings("https://include.example.test:9443/hosted", hosted_url);
}

test "mounted sub application docs and openapi use mount root path" {
    var parent = ZAPI.init(testing.allocator, .{});
    defer parent.deinit();
    var child = ZAPI.init(testing.allocator, .{ .title = "Child API", .version = "2.0.0" });
    defer child.deinit();
    try parent.mount("/api", &child);

    var docs = try parent.handle(Request.init(.GET, "/api/docs"));
    defer docs.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, docs.status);
    try testing.expect(std.mem.indexOf(u8, docs.body.items, "SwaggerUIBundle") != null);
    try testing.expect(std.mem.indexOf(u8, docs.body.items, "url: \"/api/openapi.json\"") != null);
    try testing.expect(std.mem.indexOf(u8, docs.body.items, "oauth2RedirectUrl: window.location.origin + \"/api/docs/oauth2-redirect\"") != null);

    var oauth2_redirect = try parent.handle(Request.init(.GET, "/api/docs/oauth2-redirect"));
    defer oauth2_redirect.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, oauth2_redirect.status);
    try testing.expect(std.mem.indexOf(u8, oauth2_redirect.body.items, "swaggerUIRedirectOauth2") != null);

    var redoc = try parent.handle(Request.init(.GET, "/api/redoc"));
    defer redoc.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, redoc.status);
    try testing.expect(std.mem.indexOf(u8, redoc.body.items, "spec-url=\"/api/openapi.json\"") != null);

    var openapi = try parent.handle(Request.init(.GET, "/api/openapi.json"));
    defer openapi.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, openapi.status);
    try expectJsonEqual(
        \\{
        \\  "openapi": "3.1.0",
        \\  "info": {
        \\    "title": "Child API",
        \\    "version": "2.0.0"
        \\  },
        \\  "servers": [
        \\    {"url": "/api"}
        \\  ],
        \\  "paths": {},
        \\  "components": {
        \\    "schemas": {}
        \\  }
        \\}
    ,
        openapi.body.items,
    );
}

test "redirects trailing slash variants when an alternate route matches" {
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    try app.route(Route.get("/users/{id}", getUser, .{}));

    var response = try app.handle(Request.init(.GET, "/users/42/?verbose=true"));
    defer response.deinit(testing.allocator);
    try testing.expectEqual(Status.temporary_redirect, response.status);
    try testing.expectEqualStrings("/users/42?verbose=true", response.header("location").?);

    var wrong_method = try app.handle(Request.init(.POST, "/users/42/?verbose=true"));
    defer wrong_method.deinit(testing.allocator);
    try testing.expectEqual(Status.temporary_redirect, wrong_method.status);
    try testing.expectEqualStrings("/users/42?verbose=true", wrong_method.header("location").?);

    var strict_app = ZAPI.init(testing.allocator, .{ .redirect_slashes = false });
    defer strict_app.deinit();
    try strict_app.route(Route.get("/users/{id}", getUser, .{}));
    try strict_app.route(Route.get("/exact", plainText, .{}));

    var strict_miss = try strict_app.handle(Request.init(.GET, "/users/42/"));
    defer strict_miss.deinit(testing.allocator);
    try testing.expectEqual(Status.not_found, strict_miss.status);
    try testing.expect(strict_miss.header("location") == null);

    var strict_wrong_method = try strict_app.handle(Request.init(.POST, "/exact"));
    defer strict_wrong_method.deinit(testing.allocator);
    try testing.expectEqual(Status.method_not_allowed, strict_wrong_method.status);
    try testing.expectEqualStrings("HEAD, GET, OPTIONS", strict_wrong_method.header("allow").?);
}

test "typed path convertors constrain matching and capture path tails" {
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    try app.route(Route.get("/users/{id:int}", getUser, .{}));
    try app.route(Route.get("/names/{username}", disableUser, .{}));
    try app.route(Route.get("/measure/{value:float}", getFloat, .{}));
    try app.route(Route.get("/widgets/{id:uuid}", getUuid, .{}));
    try app.route(Route.get("/files/{rest:path}", getPathTail, .{}));

    var user = try app.handle(Request.init(.GET, "/users/42"));
    defer user.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, user.status);
    try testing.expectEqualStrings("{\"id\":42,\"email\":\"ada@example.com\"}", user.body.items);

    var invalid_int = try app.handle(Request.init(.GET, "/users/ada"));
    defer invalid_int.deinit(testing.allocator);
    try testing.expectEqual(Status.not_found, invalid_int.status);

    var decoded_name = try app.handle(Request.init(.GET, "/names/ada%20lovelace+zig"));
    defer decoded_name.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, decoded_name.status);
    try testing.expectEqualStrings("{\"value\":\"ada lovelace+zig\"}", decoded_name.body.items);

    var malformed_name = try app.handle(Request.init(.GET, "/names/ada%ZZ"));
    defer malformed_name.deinit(testing.allocator);
    try testing.expectEqual(Status.unprocessable_entity, malformed_name.status);

    var negative_int = try app.handle(Request.init(.GET, "/users/-1"));
    defer negative_int.deinit(testing.allocator);
    try testing.expectEqual(Status.not_found, negative_int.status);

    var measured = try app.handle(Request.init(.GET, "/measure/12.5"));
    defer measured.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, measured.status);
    try testing.expectEqualStrings("{\"value\":12.5}", measured.body.items);

    var whole_float = try app.handle(Request.init(.GET, "/measure/12"));
    defer whole_float.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, whole_float.status);
    try testing.expectEqualStrings("{\"value\":12}", whole_float.body.items);

    var invalid_float = try app.handle(Request.init(.GET, "/measure/not-a-float"));
    defer invalid_float.deinit(testing.allocator);
    try testing.expectEqual(Status.not_found, invalid_float.status);

    var negative_float = try app.handle(Request.init(.GET, "/measure/-12.5"));
    defer negative_float.deinit(testing.allocator);
    try testing.expectEqual(Status.not_found, negative_float.status);

    var exponent_float = try app.handle(Request.init(.GET, "/measure/1e3"));
    defer exponent_float.deinit(testing.allocator);
    try testing.expectEqual(Status.not_found, exponent_float.status);

    var trailing_dot_float = try app.handle(Request.init(.GET, "/measure/12."));
    defer trailing_dot_float.deinit(testing.allocator);
    try testing.expectEqual(Status.not_found, trailing_dot_float.status);

    var leading_dot_float = try app.handle(Request.init(.GET, "/measure/.5"));
    defer leading_dot_float.deinit(testing.allocator);
    try testing.expectEqual(Status.not_found, leading_dot_float.status);

    var uuid = try app.handle(Request.init(.GET, "/widgets/550e8400-e29b-41d4-a716-446655440000"));
    defer uuid.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, uuid.status);
    try testing.expectEqualStrings("{\"value\":\"550e8400-e29b-41d4-a716-446655440000\"}", uuid.body.items);

    var invalid_uuid = try app.handle(Request.init(.GET, "/widgets/not-a-uuid"));
    defer invalid_uuid.deinit(testing.allocator);
    try testing.expectEqual(Status.not_found, invalid_uuid.status);

    var file = try app.handle(Request.init(.GET, "/files/css/site/main.css"));
    defer file.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, file.status);
    try testing.expectEqualStrings("{\"value\":\"css/site/main.css\"}", file.body.items);

    var empty_file_tail = try app.handle(Request.init(.GET, "/files/"));
    defer empty_file_tail.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, empty_file_tail.status);
    try testing.expectEqualStrings("{\"value\":\"\"}", empty_file_tail.body.items);

    var encoded_file = try app.handle(Request.init(.GET, "/files/css%2Fsite/site%20main.css"));
    defer encoded_file.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, encoded_file.status);
    try testing.expectEqualStrings("{\"value\":\"css/site/site main.css\"}", encoded_file.body.items);
}

test "custom path convertors constrain matching and URL reversing" {
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();

    try testing.expectError(error.InvalidRoutePath, app.route(Route.get("/posts/{slug:slug}", getSlug, .{})));
    try testing.expectError(error.InvalidPathConvertor, app.addPathConvertor("int", slugMatches));
    try testing.expectError(error.InvalidPathConvertor, app.addPathConvertor("bad-name", slugMatches));

    try app.addPathConvertor("slug", slugMatches);
    try app.route(Route.get("/posts/{slug:slug}", getSlug, .{ .name = "post_detail" }));

    var matched = try app.handle(Request.init(.GET, "/posts/hello-zig-123"));
    defer matched.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, matched.status);
    try testing.expectEqualStrings("{\"value\":\"hello-zig-123\"}", matched.body.items);

    var uppercase = try app.handle(Request.init(.GET, "/posts/Hello-Zig"));
    defer uppercase.deinit(testing.allocator);
    try testing.expectEqual(Status.not_found, uppercase.status);

    var leading_dash = try app.handle(Request.init(.GET, "/posts/-hello"));
    defer leading_dash.deinit(testing.allocator);
    try testing.expectEqual(Status.not_found, leading_dash.status);

    const reversed = try app.urlPathFor("post_detail", .{ .slug = "hello-zig-123" });
    defer testing.allocator.free(reversed);
    try testing.expectEqualStrings("/posts/hello-zig-123", reversed);

    try testing.expectError(error.InvalidPathParam, app.urlPathFor("post_detail", .{ .slug = "Hello-Zig" }));

    try app.addPathConvertor("slug", slugWithoutDigitsMatches);

    var replaced_match = try app.handle(Request.init(.GET, "/posts/hello-zig"));
    defer replaced_match.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, replaced_match.status);
    try testing.expectEqualStrings("{\"value\":\"hello-zig\"}", replaced_match.body.items);

    var replaced_reject = try app.handle(Request.init(.GET, "/posts/hello-zig-123"));
    defer replaced_reject.deinit(testing.allocator);
    try testing.expectEqual(Status.not_found, replaced_reject.status);

    try testing.expectError(error.InvalidPathParam, app.urlPathFor("post_detail", .{ .slug = "hello-zig-123" }));
}

test "custom path convertors apply to mounts and host patterns" {
    var parent = ZAPI.init(testing.allocator, .{});
    defer parent.deinit();
    var child = ZAPI.init(testing.allocator, .{});
    defer child.deinit();
    var hosted = ZAPI.init(testing.allocator, .{});
    defer hosted.deinit();

    try parent.addPathConvertor("slug", slugMatches);
    try child.addPathConvertor("slug", slugMatches);
    try hosted.addPathConvertor("slug", slugMatches);

    try child.route(Route.get("/posts/{slug:slug}", getSlug, .{ .name = "post_detail" }));
    try parent.mountNamed("/{tenant:slug}/blog", "blog", &child);

    var mounted = try parent.handle(Request.init(.GET, "/acme/blog/posts/hello-zig"));
    defer mounted.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, mounted.status);
    try testing.expectEqualStrings("{\"value\":\"hello-zig\"}", mounted.body.items);

    var invalid_mount = try parent.handle(Request.init(.GET, "/Acme/blog/posts/hello-zig"));
    defer invalid_mount.deinit(testing.allocator);
    try testing.expectEqual(Status.not_found, invalid_mount.status);

    const mounted_path = try parent.urlPathFor("blog:post_detail", .{ .tenant = "acme", .slug = "hello-zig" });
    defer testing.allocator.free(mounted_path);
    try testing.expectEqualStrings("/acme/blog/posts/hello-zig", mounted_path);

    try testing.expectError(error.InvalidPathParam, parent.urlPathFor("blog:post_detail", .{ .tenant = "Acme", .slug = "hello-zig" }));

    try hosted.route(Route.get("/posts/{slug:slug}", getSlug, .{ .name = "post_detail" }));
    try parent.hostNamed("{subdomain:slug}.example.org", "tenant", &hosted);

    var hosted_req = Request.init(.GET, "/posts/hello-zig");
    hosted_req.headers = &.{.{ .name = "host", .value = "acme.example.org" }};
    var hosted_response = try parent.handle(hosted_req);
    defer hosted_response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, hosted_response.status);
    try testing.expectEqualStrings("{\"value\":\"hello-zig\"}", hosted_response.body.items);

    var invalid_host_req = Request.init(.GET, "/posts/hello-zig");
    invalid_host_req.headers = &.{.{ .name = "host", .value = "Acme.example.org" }};
    var invalid_host = try parent.handle(invalid_host_req);
    defer invalid_host.deinit(testing.allocator);
    try testing.expectEqual(Status.not_found, invalid_host.status);

    const hosted_url = try parent.urlForHost("tenant:post_detail", .{ .subdomain = "acme", .slug = "hello-zig" }, "https");
    defer testing.allocator.free(hosted_url);
    try testing.expectEqualStrings("https://acme.example.org/posts/hello-zig", hosted_url);

    try testing.expectError(error.InvalidPathParam, parent.urlForHost("tenant:post_detail", .{ .subdomain = "Acme", .slug = "hello-zig" }, "https"));
}

test "validates uuid scalar fields in paths queries and json bodies" {
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    try app.route(Route.get("/widgets/{id:uuid}", echoUuid, .{}));
    try app.route(Route.post("/uuids", createUuid, .{}));

    var path = try app.handle(Request.init(.GET, "/widgets/550e8400-e29b-41d4-a716-446655440000"));
    defer path.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, path.status);
    try testing.expectEqualStrings("{\"id\":\"550e8400-e29b-41d4-a716-446655440000\"}", path.body.items);

    var query = try app.handle(Request.init(.GET, "/widgets/550e8400-e29b-41d4-a716-446655440000?trace_id=6ba7b810-9dad-11d1-80b4-00c04fd430c8"));
    defer query.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, query.status);
    try testing.expectEqualStrings("{\"id\":\"6ba7b810-9dad-11d1-80b4-00c04fd430c8\"}", query.body.items);

    var invalid_query = try app.handle(Request.init(.GET, "/widgets/550e8400-e29b-41d4-a716-446655440000?trace_id=not-a-uuid"));
    defer invalid_query.deinit(testing.allocator);
    try testing.expectEqual(Status.unprocessable_entity, invalid_query.status);

    var body = Request.builder(testing.allocator, .POST, "/uuids");
    defer body.deinit();
    try body.json("{\"id\":\"6ba7b811-9dad-11d1-80b4-00c04fd430c8\"}");
    var body_response = try body.send(&app);
    defer body_response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, body_response.status);
    try testing.expectEqualStrings("{\"id\":\"6ba7b811-9dad-11d1-80b4-00c04fd430c8\"}", body_response.body.items);

    var invalid_body = Request.builder(testing.allocator, .POST, "/uuids");
    defer invalid_body.deinit();
    try invalid_body.json("{\"id\":\"invalid\"}");
    var invalid_body_response = try invalid_body.send(&app);
    defer invalid_body_response.deinit(testing.allocator);
    try testing.expectEqual(Status.unprocessable_entity, invalid_body_response.status);
}

test "validates date and datetime scalar fields in queries and json bodies" {
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    try app.route(Route.get("/dates", echoDate, .{}));
    try app.route(Route.post("/dates", createDate, .{}));

    var query = try app.handle(Request.init(.GET, "/dates?date=2026-06-13&timestamp=2026-06-13T14:15:16Z"));
    defer query.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, query.status);
    try testing.expectEqualStrings("{\"date\":\"2026-06-13\",\"timestamp\":\"2026-06-13T14:15:16Z\"}", query.body.items);

    var offset_query = try app.handle(Request.init(.GET, "/dates?date=2024-02-29&timestamp=2024-02-29T23:59:58.123%2B02:30"));
    defer offset_query.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, offset_query.status);
    try testing.expectEqualStrings("{\"date\":\"2024-02-29\",\"timestamp\":\"2024-02-29T23:59:58.123+02:30\"}", offset_query.body.items);

    var invalid_date = try app.handle(Request.init(.GET, "/dates?date=2023-02-29&timestamp=2026-06-13T14:15:16Z"));
    defer invalid_date.deinit(testing.allocator);
    try testing.expectEqual(Status.unprocessable_entity, invalid_date.status);

    var invalid_time = try app.handle(Request.init(.GET, "/dates?date=2026-06-13&timestamp=2026-06-13T25:15:16Z"));
    defer invalid_time.deinit(testing.allocator);
    try testing.expectEqual(Status.unprocessable_entity, invalid_time.status);

    var body = Request.builder(testing.allocator, .POST, "/dates");
    defer body.deinit();
    try body.json("{\"date\":\"2026-06-13\",\"timestamp\":\"2026-06-13T14:15:16-03:00\"}");
    var body_response = try body.send(&app);
    defer body_response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, body_response.status);
    try testing.expectEqualStrings("{\"date\":\"2026-06-13\",\"timestamp\":\"2026-06-13T14:15:16-03:00\"}", body_response.body.items);

    var invalid_body = Request.builder(testing.allocator, .POST, "/dates");
    defer invalid_body.deinit();
    try invalid_body.json("{\"date\":\"2026-13-01\",\"timestamp\":\"2026-06-13T14:15:16Z\"}");
    var invalid_body_response = try invalid_body.send(&app);
    defer invalid_body_response.deinit(testing.allocator);
    try testing.expectEqual(Status.unprocessable_entity, invalid_body_response.status);
}

test "validates email scalar fields in queries and json bodies" {
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    try app.route(Route.get("/emails", echoEmail, .{}));
    try app.route(Route.post("/emails", createEmail, .{}));

    var query = try app.handle(Request.init(.GET, "/emails?email=ada.lovelace%2Bzig@example.org"));
    defer query.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, query.status);
    try testing.expectEqualStrings("{\"email\":\"ada.lovelace+zig@example.org\"}", query.body.items);

    var invalid_query = try app.handle(Request.init(.GET, "/emails?email=not-an-email"));
    defer invalid_query.deinit(testing.allocator);
    try testing.expectEqual(Status.unprocessable_entity, invalid_query.status);

    var body = Request.builder(testing.allocator, .POST, "/emails");
    defer body.deinit();
    try body.json("{\"email\":\"grace.hopper@example.mil\"}");
    var body_response = try body.send(&app);
    defer body_response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, body_response.status);
    try testing.expectEqualStrings("{\"email\":\"grace.hopper@example.mil\"}", body_response.body.items);

    var invalid_body = Request.builder(testing.allocator, .POST, "/emails");
    defer invalid_body.deinit();
    try invalid_body.json("{\"email\":\"bad@-example.org\"}");
    var invalid_body_response = try invalid_body.send(&app);
    defer invalid_body_response.deinit(testing.allocator);
    try testing.expectEqual(Status.unprocessable_entity, invalid_body_response.status);
}

test "validates url scalar fields in queries and json bodies" {
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    try app.route(Route.get("/urls", echoUrlScalar, .{}));
    try app.route(Route.post("/urls", createUrlScalar, .{}));

    var query = try app.handle(Request.init(.GET, "/urls?url=https%3A%2F%2Fexample.org%2Fdocs%3Fq%3Dzig"));
    defer query.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, query.status);
    try testing.expectEqualStrings("{\"url\":\"https://example.org/docs?q=zig\"}", query.body.items);

    var mailto = try app.handle(Request.init(.GET, "/urls?url=mailto%3Aada%40example.org"));
    defer mailto.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, mailto.status);
    try testing.expectEqualStrings("{\"url\":\"mailto:ada@example.org\"}", mailto.body.items);

    var relative = try app.handle(Request.init(.GET, "/urls?url=%2Frelative"));
    defer relative.deinit(testing.allocator);
    try testing.expectEqual(Status.unprocessable_entity, relative.status);

    var hostless_http = try app.handle(Request.init(.GET, "/urls?url=https%3A%2F%2F"));
    defer hostless_http.deinit(testing.allocator);
    try testing.expectEqual(Status.unprocessable_entity, hostless_http.status);

    var body = Request.builder(testing.allocator, .POST, "/urls");
    defer body.deinit();
    try body.json("{\"url\":\"https://example.com/a/b#section\"}");
    var body_response = try body.send(&app);
    defer body_response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, body_response.status);
    try testing.expectEqualStrings("{\"url\":\"https://example.com/a/b#section\"}", body_response.body.items);

    var invalid_body = Request.builder(testing.allocator, .POST, "/urls");
    defer invalid_body.deinit();
    try invalid_body.json("{\"url\":\"not a url\"}");
    var invalid_body_response = try invalid_body.send(&app);
    defer invalid_body_response.deinit(testing.allocator);
    try testing.expectEqual(Status.unprocessable_entity, invalid_body_response.status);
}

test "reverses named route URLs like Starlette url_path_for" {
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    try app.route(Route.get("/", plainText, .{}));
    try app.route(Route.get("/unnamed/{id:int}", getUser, .{}));
    try app.route(Route.get("/users/{id}", getUser, .{ .name = "user_detail" }));
    try app.route(Route.get("/search/{term}/{page}", plainText, .{ .name = "search_page" }));
    try app.route(Route.get("/items/{id:int}", getUser, .{ .name = "item_detail" }));
    try app.route(Route.get("/assets/{rest:path}", getPathTail, .{ .name = "asset" }));

    const root_path = try app.urlPathFor("get_root", .{});
    defer testing.allocator.free(root_path);
    try testing.expectEqualStrings("/", root_path);

    const default_name_path = try app.urlPathFor("get_unnamed_id", .{ .id = 5 });
    defer testing.allocator.free(default_name_path);
    try testing.expectEqualStrings("/unnamed/5", default_name_path);

    const user_path = try app.urlPathFor("user_detail", .{ .id = 42 });
    defer testing.allocator.free(user_path);
    try testing.expectEqualStrings("/users/42", user_path);

    const search_path = try app.urlPathFor("search_page", .{ .term = "zig", .page = 2 });
    defer testing.allocator.free(search_path);
    try testing.expectEqualStrings("/search/zig/2", search_path);

    const encoded_search_path = try app.urlPathFor("search_page", .{ .term = "zig lang+api", .page = 2 });
    defer testing.allocator.free(encoded_search_path);
    try testing.expectEqualStrings("/search/zig%20lang+api/2", encoded_search_path);

    const item_path = try app.urlPathFor("item_detail", .{ .id = 42 });
    defer testing.allocator.free(item_path);
    try testing.expectEqualStrings("/items/42", item_path);

    const asset_path = try app.urlPathFor("asset", .{ .rest = "css/site/main.css" });
    defer testing.allocator.free(asset_path);
    try testing.expectEqualStrings("/assets/css/site/main.css", asset_path);

    const empty_asset_path = try app.urlPathFor("asset", .{ .rest = "" });
    defer testing.allocator.free(empty_asset_path);
    try testing.expectEqualStrings("/assets/", empty_asset_path);

    const encoded_asset_path = try app.urlPathFor("asset", .{ .rest = "css/site main.css" });
    defer testing.allocator.free(encoded_asset_path);
    try testing.expectEqualStrings("/assets/css/site%20main.css", encoded_asset_path);

    var encoded_asset_response = try app.handle(Request.init(.GET, encoded_asset_path));
    defer encoded_asset_response.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, encoded_asset_response.status);
    try testing.expectEqualStrings("{\"value\":\"css/site main.css\"}", encoded_asset_response.body.items);

    try testing.expectError(error.NoRoute, app.urlPathFor("missing", .{}));
    try testing.expectError(error.NoRoute, app.urlPathFor("user_detail", .{}));
    try testing.expectError(error.NoRoute, app.urlPathFor("user_detail", .{ .id = 42, .extra = "unused" }));
    try testing.expectError(error.InvalidPathParam, app.urlPathFor("user_detail", .{ .id = @as([]const u8, "tom/christie") }));
    try testing.expectError(error.InvalidPathParam, app.urlPathFor("item_detail", .{ .id = @as([]const u8, "abc") }));
}

test "context reverses named routes and redirects with mount root path" {
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    try app.route(Route.get("/users/{id:int}", getUser, .{ .name = "user_detail" }));
    try app.route(Route.get("/links/{id:int}", echoNamedUserPath, .{}));
    try app.route(Route.get("/urls/{id:int}", echoNamedUserUrl, .{}));
    try app.route(Route.get("/request-urls/{id:int}", echoRequestNamedUserUrl, .{}));
    try app.route(Route.get("/request-url-parts", echoRequestUrlParts, .{}));
    try app.route(Route.get("/request-url-mutations", echoRequestUrlMutations, .{}));
    try app.route(Route.get("/go/{id:int}", redirectToNamedUser, .{}));

    var link = try app.handle(Request.init(.GET, "/links/7"));
    defer link.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, link.status);
    try testing.expectEqualStrings("{\"path\":\"/users/7\"}", link.body.items);

    var url_req = Request.builder(testing.allocator, .GET, "/urls/7?next=1");
    defer url_req.deinit();
    url_req.scheme("https");
    url_req.rootPath("/v1");
    try url_req.host("api.example");
    var url = try url_req.send(&app);
    defer url.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, url.status);
    try testing.expectEqualStrings("{\"url\":\"https://api.example/v1/users/7\",\"request_url\":\"https://api.example/v1/urls/7?next=1\"}", url.body.items);

    var request_url_req = Request.builder(testing.allocator, .GET, "/request-urls/7?next=1");
    defer request_url_req.deinit();
    request_url_req.scheme("https");
    request_url_req.rootPath("/v1");
    try request_url_req.host("api.example");
    var request_url = try request_url_req.send(&app);
    defer request_url.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, request_url.status);
    try testing.expectEqualStrings("{\"path\":\"/v1/users/7\",\"url\":\"https://api.example/v1/users/7\"}", request_url.body.items);

    var parts_req = Request.builder(testing.allocator, .GET, "/request-url-parts?next=1");
    defer parts_req.deinit();
    parts_req.scheme("https");
    parts_req.rootPath("/v1");
    try parts_req.host("api.example");
    var parts = try parts_req.send(&app);
    defer parts.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, parts.status);
    try testing.expectEqualStrings("{\"url\":\"https://api.example/v1/request-url-parts?next=1\",\"url_path\":\"/v1/request-url-parts?next=1\",\"base_url\":\"https://api.example/v1/\"}", parts.body.items);

    var mutation_req = Request.builder(testing.allocator, .GET, "/request-url-mutations?next=1&tab=profile&%74ag=old");
    defer mutation_req.deinit();
    mutation_req.scheme("https");
    mutation_req.rootPath("/v1");
    try mutation_req.host("api.example");
    var mutation = try mutation_req.send(&app);
    defer mutation.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, mutation.status);
    try testing.expectEqualStrings("{\"included\":\"https://api.example/v1/request-url-mutations?next=1&tab=profile&%74ag=old&tag=zig+api\",\"replaced\":\"https://api.example/v1/request-url-mutations?tab=profile&%74ag=old&next=2\",\"removed\":\"https://api.example/v1/request-url-mutations?next=1&%74ag=old\",\"path_included\":\"/v1/request-url-mutations?next=1&tab=profile&%74ag=old&tag=zig+api\",\"path_replaced\":\"/v1/request-url-mutations?tab=profile&%74ag=old&next=2\",\"path_removed\":\"/v1/request-url-mutations?next=1&%74ag=old\"}", mutation.body.items);

    var hostless_parts_req = Request.init(.GET, "/request-url-parts?next=1");
    hostless_parts_req.root_path = "/v1";
    var hostless_parts = try app.handle(hostless_parts_req);
    defer hostless_parts.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, hostless_parts.status);
    try testing.expectEqualStrings("{\"url\":\"/v1/request-url-parts?next=1\",\"url_path\":\"/v1/request-url-parts?next=1\",\"base_url\":\"/v1/\"}", hostless_parts.body.items);

    var hostless_mutation_req = Request.init(.GET, "/request-url-mutations?next=1&tab=profile");
    hostless_mutation_req.root_path = "/v1";
    var hostless_mutation = try app.handle(hostless_mutation_req);
    defer hostless_mutation.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, hostless_mutation.status);
    try testing.expectEqualStrings("{\"included\":\"/v1/request-url-mutations?next=1&tab=profile&tag=zig+api\",\"replaced\":\"/v1/request-url-mutations?tab=profile&next=2\",\"removed\":\"/v1/request-url-mutations?next=1\",\"path_included\":\"/v1/request-url-mutations?next=1&tab=profile&tag=zig+api\",\"path_replaced\":\"/v1/request-url-mutations?tab=profile&next=2\",\"path_removed\":\"/v1/request-url-mutations?next=1\"}", hostless_mutation.body.items);

    var invalid_mutation_req = Request.init(.GET, "/request-url-mutations?bad%ZZ=value");
    try testing.expectError(error.Validation, invalid_mutation_req.urlReplaceQueryParam(testing.allocator, "bad", "replacement"));
    try testing.expectError(error.Validation, invalid_mutation_req.urlRemoveQueryParam(testing.allocator, "bad"));
    try testing.expectError(error.Validation, invalid_mutation_req.urlPathReplaceQueryParam(testing.allocator, "bad", "replacement"));
    try testing.expectError(error.Validation, invalid_mutation_req.urlPathRemoveQueryParam(testing.allocator, "bad"));

    var redirect = try app.handle(Request.init(.GET, "/go/8"));
    defer redirect.deinit(testing.allocator);
    try testing.expectEqual(Status.temporary_redirect, redirect.status);
    try testing.expectEqualStrings("/users/8", redirect.header("location").?);
    try testing.expectEqual(@as(usize, 0), redirect.body.items.len);

    var parent = ZAPI.init(testing.allocator, .{});
    defer parent.deinit();
    var child = ZAPI.init(testing.allocator, .{});
    defer child.deinit();
    try child.route(Route.get("/users/{id:int}", getUser, .{ .name = "user_detail" }));
    try child.route(Route.get("/links/{id:int}", echoNamedUserPath, .{}));
    try child.route(Route.get("/urls/{id:int}", echoNamedUserUrl, .{}));
    try child.route(Route.get("/request-urls/{id:int}", echoRequestNamedUserUrl, .{}));
    try child.route(Route.get("/request-url-parts", echoRequestUrlParts, .{}));
    try child.route(Route.get("/request-url-mutations", echoRequestUrlMutations, .{}));
    try child.route(Route.get("/go/{id:int}", redirectToNamedUser, .{}));
    try parent.mount("/api", &child);

    var mounted_link = try parent.handle(Request.init(.GET, "/api/links/9"));
    defer mounted_link.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, mounted_link.status);
    try testing.expectEqualStrings("{\"path\":\"/api/users/9\"}", mounted_link.body.items);

    var mounted_url_req = Request.init(.GET, "/api/urls/9?tab=profile");
    mounted_url_req.scheme = "https";
    mounted_url_req.headers = &.{.{ .name = "host", .value = "api.example" }};
    var mounted_url = try parent.handle(mounted_url_req);
    defer mounted_url.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, mounted_url.status);
    try testing.expectEqualStrings("{\"url\":\"https://api.example/api/users/9\",\"request_url\":\"https://api.example/api/urls/9?tab=profile\"}", mounted_url.body.items);

    var mounted_request_url_req = Request.init(.GET, "/api/request-urls/9?tab=profile");
    mounted_request_url_req.scheme = "https";
    mounted_request_url_req.root_path = "/v1";
    mounted_request_url_req.headers = &.{.{ .name = "host", .value = "api.example" }};
    var mounted_request_url = try parent.handle(mounted_request_url_req);
    defer mounted_request_url.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, mounted_request_url.status);
    try testing.expectEqualStrings("{\"path\":\"/v1/api/users/9\",\"url\":\"https://api.example/v1/api/users/9\"}", mounted_request_url.body.items);

    var mounted_parts_req = Request.init(.GET, "/api/request-url-parts?tab=profile");
    mounted_parts_req.scheme = "https";
    mounted_parts_req.headers = &.{.{ .name = "host", .value = "api.example" }};
    var mounted_parts = try parent.handle(mounted_parts_req);
    defer mounted_parts.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, mounted_parts.status);
    try testing.expectEqualStrings("{\"url\":\"https://api.example/api/request-url-parts?tab=profile\",\"url_path\":\"/api/request-url-parts?tab=profile\",\"base_url\":\"https://api.example/api/\"}", mounted_parts.body.items);

    var mounted_mutation_req = Request.init(.GET, "/api/request-url-mutations?next=1&tab=profile");
    mounted_mutation_req.scheme = "https";
    mounted_mutation_req.headers = &.{.{ .name = "host", .value = "api.example" }};
    var mounted_mutation = try parent.handle(mounted_mutation_req);
    defer mounted_mutation.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, mounted_mutation.status);
    try testing.expectEqualStrings("{\"included\":\"https://api.example/api/request-url-mutations?next=1&tab=profile&tag=zig+api\",\"replaced\":\"https://api.example/api/request-url-mutations?tab=profile&next=2\",\"removed\":\"https://api.example/api/request-url-mutations?next=1\",\"path_included\":\"/api/request-url-mutations?next=1&tab=profile&tag=zig+api\",\"path_replaced\":\"/api/request-url-mutations?tab=profile&next=2\",\"path_removed\":\"/api/request-url-mutations?next=1\"}", mounted_mutation.body.items);

    var mounted_redirect = try parent.handle(Request.init(.GET, "/api/go/10"));
    defer mounted_redirect.deinit(testing.allocator);
    try testing.expectEqual(Status.temporary_redirect, mounted_redirect.status);
    try testing.expectEqualStrings("/api/users/10", mounted_redirect.header("location").?);
}

test "context reversed mounted URLs are owned by the handler allocator" {
    var child_gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = child_gpa.deinit();

    var parent = ZAPI.init(testing.allocator, .{});
    defer parent.deinit();
    var child = ZAPI.init(child_gpa.allocator(), .{});
    defer child.deinit();

    try child.route(Route.get("/users/{id:int}", getUser, .{ .name = "user_detail" }));
    try child.route(Route.get("/links/{id:int}", echoNamedUserPath, .{}));
    try parent.mount("/api", &child);

    var mounted_link = try parent.handle(Request.init(.GET, "/api/links/9"));
    defer mounted_link.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, mounted_link.status);
    try testing.expectEqualStrings("{\"path\":\"/api/users/9\"}", mounted_link.body.items);
}

test "openapi output escapes metadata strings and emits operation ids" {
    var app = ZAPI.init(testing.allocator, .{
        .title = "Quoted \"API\"",
        .version = "0.1\n0",
        .description = "ZAPI line\nbreak",
        .terms_of_service = "https://example.com/terms?quoted=\"yes\"",
        .contact = .{
            .name = "Ada \"Ops\"",
            .url = "https://example.com/contact",
            .email = "ada@example.com",
        },
        .license = .{
            .name = "MIT \"Plus\"",
            .url = "https://example.com/license",
        },
        .openapi_servers = &.{
            .{
                .url = "https://api.example.com/v1",
                .description = "Production \"API\"",
            },
            .{
                .url = "https://staging.example.com",
            },
        },
        .openapi_tags = &.{
            .{
                .name = "users \"quoted\"",
                .description = "User tag\nmetadata",
                .external_docs = .{
                    .description = "User docs",
                    .url = "https://example.com/docs/users?quoted=\"yes\"",
                },
            },
        },
        .external_docs = .{
            .description = "Full API docs",
            .url = "https://example.com/docs?quoted=\"yes\"",
        },
    });
    defer app.deinit();
    try app.route(Route.get("/quoted", escapedHello, .{
        .name = "quoted_operation",
        .summary = "Quote \"summary\"",
        .description = "Line\nbreak",
        .external_docs = .{
            .description = "Operation docs",
            .url = "https://example.com/docs/quoted?quoted=\"yes\"",
        },
        .tags = &.{"users \"quoted\""},
    }));

    var openapi = try app.handle(Request.init(.GET, "/openapi.json"));
    defer openapi.deinit(testing.allocator);

    try expectJsonEqual(
        \\{
        \\  "openapi": "3.1.0",
        \\  "info": {
        \\    "title": "Quoted \"API\"",
        \\    "description": "ZAPI line\nbreak",
        \\    "termsOfService": "https://example.com/terms?quoted=\"yes\"",
        \\    "contact": {
        \\      "name": "Ada \"Ops\"",
        \\      "url": "https://example.com/contact",
        \\      "email": "ada@example.com"
        \\    },
        \\    "license": {
        \\      "name": "MIT \"Plus\"",
        \\      "url": "https://example.com/license"
        \\    },
        \\    "version": "0.1\n0"
        \\  },
        \\  "servers": [
        \\    {
        \\      "url": "https://api.example.com/v1",
        \\      "description": "Production \"API\""
        \\    },
        \\    {
        \\      "url": "https://staging.example.com"
        \\    }
        \\  ],
        \\  "tags": [
        \\    {
        \\      "name": "users \"quoted\"",
        \\      "description": "User tag\nmetadata",
        \\      "externalDocs": {
        \\        "description": "User docs",
        \\        "url": "https://example.com/docs/users?quoted=\"yes\""
        \\      }
        \\    }
        \\  ],
        \\  "externalDocs": {
        \\    "description": "Full API docs",
        \\    "url": "https://example.com/docs?quoted=\"yes\""
        \\  },
        \\  "paths": {
        \\    "/quoted": {
        \\      "get": {
        \\        "operationId": "quoted_operation",
        \\        "summary": "Quote \"summary\"",
        \\        "description": "Line\nbreak",
        \\        "tags": ["users \"quoted\""],
        \\        "externalDocs": {
        \\          "description": "Operation docs",
        \\          "url": "https://example.com/docs/quoted?quoted=\"yes\""
        \\        },
        \\        "responses": {
        \\          "200": {
        \\            "description": "OK",
        \\            "content": {
        \\              "application/json": {
        \\                "schema": {"$ref": "#/components/schemas/EscapedMessage"}
        \\              }
        \\            }
        \\          }
        \\        }
        \\      }
        \\    }
        \\  },
        \\  "components": {
        \\    "schemas": {
        \\      "EscapedMessage": {
        \\        "type": "object",
        \\        "properties": {
        \\          "message": {"type": "string"}
        \\        },
        \\        "required": ["message"],
        \\        "additionalProperties": false
        \\      }
        \\    }
        \\  }
        \\}
    ,
        openapi.body.items,
    );
}

test "openapi can hide routes and mark operations deprecated" {
    var app = ZAPI.init(testing.allocator, .{ .title = "Schema Control API", .version = "1.0.0" });
    defer app.deinit();
    try app.route(Route.post("/internal", hiddenInternal, .{
        .include_in_schema = false,
    }));
    try app.route(Route.get("/old", deprecatedMessage, .{
        .name = "old_message",
        .summary = "Old message",
        .deprecated = true,
    }));

    var hidden_req = Request.init(.POST, "/internal");
    hidden_req.headers = &.{.{ .name = "authorization", .value = "Bearer internal-token" }};
    hidden_req.body = "{\"secret\":\"swordfish\"}";
    var hidden = try app.handle(hidden_req);
    defer hidden.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, hidden.status);
    try testing.expectEqualStrings("{\"token\":\"internal-token\",\"secret\":\"swordfish\"}", hidden.body.items);

    var openapi = try app.handle(Request.init(.GET, "/openapi.json"));
    defer openapi.deinit(testing.allocator);

    try expectJsonEqual(
        \\{
        \\  "openapi": "3.1.0",
        \\  "info": {
        \\    "title": "Schema Control API",
        \\    "version": "1.0.0"
        \\  },
        \\  "paths": {
        \\    "/old": {
        \\      "get": {
        \\        "operationId": "old_message",
        \\        "summary": "Old message",
        \\        "deprecated": true,
        \\        "responses": {
        \\          "200": {
        \\            "description": "OK",
        \\            "content": {
        \\              "application/json": {
        \\                "schema": {"$ref": "#/components/schemas/DeprecatedMessage"}
        \\              }
        \\            }
        \\          }
        \\        }
        \\      }
        \\    }
        \\  },
        \\  "components": {
        \\    "schemas": {
        \\      "DeprecatedMessage": {
        \\        "type": "object",
        \\        "properties": {
        \\          "message": {"type": "string"}
        \\        },
        \\        "required": ["message"],
        \\        "additionalProperties": false
        \\      }
        \\    }
        \\  }
        \\}
    ,
        openapi.body.items,
    );
}

test "openapi operation id can differ from route name" {
    var app = ZAPI.init(testing.allocator, .{ .title = "Operation ID API", .version = "1.0.0" });
    defer app.deinit();
    try app.route(Route.get("/users/{id:int}", getUser, .{
        .name = "user_detail",
        .operation_id = "getPublicUser",
        .summary = "Get public user",
        .tags = &.{"users"},
    }));

    const path = try app.urlPathFor("user_detail", .{ .id = 42 });
    defer testing.allocator.free(path);
    try testing.expectEqualStrings("/users/42", path);

    var openapi = try app.handle(Request.init(.GET, "/openapi.json"));
    defer openapi.deinit(testing.allocator);

    try expectJsonEqual(
        \\{
        \\  "openapi": "3.1.0",
        \\  "info": {
        \\    "title": "Operation ID API",
        \\    "version": "1.0.0"
        \\  },
        \\  "paths": {
        \\    "/users/{id}": {
        \\      "get": {
        \\        "operationId": "getPublicUser",
        \\        "summary": "Get public user",
        \\        "tags": ["users"],
        \\        "parameters": [
        \\          {"name": "id", "in": "path", "required": true, "schema": {"type": "integer"}},
        \\          {"name": "verbose", "in": "query", "required": false, "schema": {"anyOf": [{"type": "boolean"}, {"type": "null"}], "default": null}}
        \\        ],
        \\        "responses": {
        \\          "200": {
        \\            "description": "OK",
        \\            "content": {
        \\              "application/json": {
        \\                "schema": {"$ref": "#/components/schemas/TestUser"}
        \\              }
        \\            }
        \\          },
        \\          "422": {
        \\            "description": "Validation Error",
        \\            "content": {
        \\              "application/json": {
        \\                "schema": {"$ref": "#/components/schemas/ProblemDetail"}
        \\              }
        \\            }
        \\          }
        \\        }
        \\      }
        \\    }
        \\  },
        \\  "components": {
        \\    "schemas": {
        \\      "ProblemDetail": {
        \\        "type": "object",
        \\        "properties": {
        \\          "detail": {"type": "string"}
        \\        },
        \\        "required": ["detail"],
        \\        "additionalProperties": false
        \\      },
        \\      "TestUser": {
        \\        "type": "object",
        \\        "properties": {
        \\          "id": {"type": "integer"},
        \\          "email": {"type": "string"}
        \\        },
        \\        "required": ["id", "email"],
        \\        "additionalProperties": false
        \\      }
        \\    }
        \\  }
        \\}
    ,
        openapi.body.items,
    );
}

test "openapi emits extension status codes" {
    var app = ZAPI.init(testing.allocator, .{ .title = "Custom Status API", .version = "1.0.0" });
    defer app.deinit();
    try app.route(Route.get("/custom-status", customExtensionStatus, .{
        .status = Status.fromCode(299),
        .name = "custom_status",
    }));

    var openapi = try app.handle(Request.init(.GET, "/openapi.json"));
    defer openapi.deinit(testing.allocator);

    try expectJsonEqual(
        \\{
        \\  "openapi": "3.1.0",
        \\  "info": {
        \\    "title": "Custom Status API",
        \\    "version": "1.0.0"
        \\  },
        \\  "paths": {
        \\    "/custom-status": {
        \\      "get": {
        \\        "operationId": "custom_status",
        \\        "responses": {
        \\          "299": {
        \\            "description": "Unknown Status",
        \\            "content": {
        \\              "text/plain; charset=utf-8": {
        \\                "schema": {"type": "string"}
        \\              }
        \\            }
        \\          }
        \\        }
        \\      }
        \\    }
        \\  },
        \\  "components": {
        \\    "schemas": {}
        \\  }
        \\}
    ,
        openapi.body.items,
    );
}

test "openapi omits connect routes because OpenAPI path items do not define connect" {
    var app = ZAPI.init(testing.allocator, .{ .title = "Connect API", .version = "1.0.0" });
    defer app.deinit();
    try app.route(Route.connect("/tunnel", echoRequestMethod, .{}));
    try app.route(Route.get("/mixed", echoRequestMethod, .{ .name = "get_mixed" }));
    try app.route(Route.connect("/mixed", echoRequestMethod, .{}));

    var openapi = try app.handle(Request.init(.GET, "/openapi.json"));
    defer openapi.deinit(testing.allocator);

    try expectJsonEqual(
        \\{
        \\  "openapi": "3.1.0",
        \\  "info": {
        \\    "title": "Connect API",
        \\    "version": "1.0.0"
        \\  },
        \\  "paths": {
        \\    "/mixed": {
        \\      "get": {
        \\        "operationId": "get_mixed",
        \\        "responses": {
        \\          "200": {
        \\            "description": "OK",
        \\            "content": {
        \\              "application/json": {
        \\                "schema": {"$ref": "#/components/schemas/MethodEcho"}
        \\              }
        \\            }
        \\          }
        \\        }
        \\      }
        \\    }
        \\  },
        \\  "components": {
        \\    "schemas": {
        \\      "MethodEcho": {
        \\        "type": "object",
        \\        "properties": {
        \\          "method": {"type": "string"}
        \\        },
        \\        "required": ["method"],
        \\        "additionalProperties": false
        \\      }
        \\    }
        \\  }
        \\}
    ,
        openapi.body.items,
    );
}

test "serves openapi and docs by default" {
    var app = ZAPI.init(testing.allocator, .{ .title = "Hello Zapi", .version = "0.1.0" });
    defer app.deinit();
    try app.route(Route.post("/users", createUser, .{ .status = .created, .summary = "Create user", .tags = &.{"users"} }));

    var openapi = try app.handle(Request.init(.GET, "/openapi.json"));
    defer openapi.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, openapi.status);
    try expectJsonEqual(
        \\{
        \\  "openapi": "3.1.0",
        \\  "info": {
        \\    "title": "Hello Zapi",
        \\    "version": "0.1.0"
        \\  },
        \\  "paths": {
        \\    "/users": {
        \\      "post": {
        \\        "operationId": "post_users",
        \\        "summary": "Create user",
        \\        "tags": ["users"],
        \\        "requestBody": {
        \\          "required": true,
        \\          "content": {
        \\            "application/json": {
        \\              "schema": {"$ref": "#/components/schemas/CreateUser"}
        \\            }
        \\          }
        \\        },
        \\        "responses": {
        \\          "201": {
        \\            "description": "Created",
        \\            "content": {
        \\              "application/json": {
        \\                "schema": {"$ref": "#/components/schemas/TestUser"}
        \\              }
        \\            }
        \\          },
        \\          "422": {
        \\            "description": "Validation Error",
        \\            "content": {
        \\              "application/json": {
        \\                "schema": {"$ref": "#/components/schemas/ProblemDetail"}
        \\              }
        \\            }
        \\          }
        \\        }
        \\      }
        \\    }
        \\  },
        \\  "components": {
        \\    "schemas": {
        \\      "ProblemDetail": {
        \\        "type": "object",
        \\        "properties": {
        \\          "detail": {"type": "string"}
        \\        },
        \\        "required": ["detail"],
        \\        "additionalProperties": false
        \\      },
        \\      "CreateUser": {
        \\        "type": "object",
        \\        "properties": {
        \\          "email": {"type": "string"}
        \\        },
        \\        "required": ["email"],
        \\        "additionalProperties": false
        \\      },
        \\      "TestUser": {
        \\        "type": "object",
        \\        "properties": {
        \\          "id": {"type": "integer"},
        \\          "email": {"type": "string"}
        \\        },
        \\        "required": ["id", "email"],
        \\        "additionalProperties": false
        \\      }
        \\    }
        \\  }
        \\}
    ,
        openapi.body.items,
    );

    var openapi_head = try app.handle(Request.init(.HEAD, "/openapi.json"));
    defer openapi_head.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, openapi_head.status);
    try testing.expectEqualStrings("application/json", openapi_head.header("content-type").?);
    try testing.expectEqualStrings(openapi.header("content-length").?, openapi_head.header("content-length").?);
    try testing.expectEqual(@as(usize, 0), openapi_head.body.items.len);

    var docs = try app.handle(Request.init(.GET, "/docs"));
    defer docs.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, docs.status);
    try testing.expect(std.mem.indexOf(u8, docs.body.items, "SwaggerUIBundle") != null);
    try testing.expect(std.mem.indexOf(u8, docs.body.items, "url: \"/openapi.json\"") != null);
    try testing.expect(std.mem.indexOf(u8, docs.body.items, "oauth2RedirectUrl: window.location.origin + \"/docs/oauth2-redirect\"") != null);

    var docs_head = try app.handle(Request.init(.HEAD, "/docs"));
    defer docs_head.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, docs_head.status);
    try testing.expectEqualStrings("text/html; charset=utf-8", docs_head.header("content-type").?);
    try testing.expectEqualStrings(docs.header("content-length").?, docs_head.header("content-length").?);
    try testing.expectEqual(@as(usize, 0), docs_head.body.items.len);

    var oauth2_redirect = try app.handle(Request.init(.GET, "/docs/oauth2-redirect"));
    defer oauth2_redirect.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, oauth2_redirect.status);
    try testing.expectEqualStrings("text/html; charset=utf-8", oauth2_redirect.header("content-type").?);
    try testing.expect(std.mem.indexOf(u8, oauth2_redirect.body.items, "swaggerUIRedirectOauth2") != null);
    try testing.expect(std.mem.indexOf(u8, oauth2_redirect.body.items, "OAuth2 state mismatch") != null);

    var oauth2_redirect_head = try app.handle(Request.init(.HEAD, "/docs/oauth2-redirect"));
    defer oauth2_redirect_head.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, oauth2_redirect_head.status);
    try testing.expectEqualStrings("text/html; charset=utf-8", oauth2_redirect_head.header("content-type").?);
    try testing.expectEqualStrings(oauth2_redirect.header("content-length").?, oauth2_redirect_head.header("content-length").?);
    try testing.expectEqual(@as(usize, 0), oauth2_redirect_head.body.items.len);

    var redoc = try app.handle(Request.init(.GET, "/redoc"));
    defer redoc.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, redoc.status);
    try testing.expect(std.mem.indexOf(u8, redoc.body.items, "<redoc spec-url=\"/openapi.json\"") != null);

    var redoc_head = try app.handle(Request.init(.HEAD, "/redoc"));
    defer redoc_head.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, redoc_head.status);
    try testing.expectEqualStrings("text/html; charset=utf-8", redoc_head.header("content-type").?);
    try testing.expectEqualStrings(redoc.header("content-length").?, redoc_head.header("content-length").?);
    try testing.expectEqual(@as(usize, 0), redoc_head.body.items.len);
}

test "docs use configured openapi url" {
    var app = ZAPI.init(testing.allocator, .{
        .openapi_url = "/schema.json?format=\"openapi\"",
        .docs_url = "/documentation",
        .oauth2_redirect_url = "/documentation/oauth2-redirect",
        .redoc_url = "/reference",
    });
    defer app.deinit();
    try app.route(Route.get("/", hello, .{}));

    var docs = try app.handle(Request.init(.GET, "/documentation"));
    defer docs.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, docs.status);
    try testing.expect(std.mem.indexOf(u8, docs.body.items, "url: \"/schema.json?format=\\\"openapi\\\"\"") != null);
    try testing.expect(std.mem.indexOf(u8, docs.body.items, "oauth2RedirectUrl: window.location.origin + \"/documentation/oauth2-redirect\"") != null);

    var oauth2_redirect = try app.handle(Request.init(.GET, "/documentation/oauth2-redirect"));
    defer oauth2_redirect.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, oauth2_redirect.status);
    try testing.expect(std.mem.indexOf(u8, oauth2_redirect.body.items, "Swagger UI OAuth2 Redirect") != null);

    var redoc = try app.handle(Request.init(.GET, "/reference"));
    defer redoc.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, redoc.status);
    try testing.expect(std.mem.indexOf(u8, redoc.body.items, "spec-url=\"/schema.json?format=&quot;openapi&quot;\"") != null);
}

test "swagger oauth2 redirect can be disabled with docs" {
    var disabled_redirect = ZAPI.init(testing.allocator, .{ .oauth2_redirect_url = null });
    defer disabled_redirect.deinit();

    var docs = try disabled_redirect.handle(Request.init(.GET, "/docs"));
    defer docs.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, docs.status);
    try testing.expect(std.mem.indexOf(u8, docs.body.items, "oauth2RedirectUrl") == null);

    var missing_redirect = try disabled_redirect.handle(Request.init(.GET, "/docs/oauth2-redirect"));
    defer missing_redirect.deinit(testing.allocator);
    try testing.expectEqual(Status.not_found, missing_redirect.status);

    var disabled_docs = ZAPI.init(testing.allocator, .{ .docs_url = null });
    defer disabled_docs.deinit();
    var stray_redirect = try disabled_docs.handle(Request.init(.GET, "/docs/oauth2-redirect"));
    defer stray_redirect.deinit(testing.allocator);
    try testing.expectEqual(Status.not_found, stray_redirect.status);
}

test "std.http adapter handles real parsed requests and writes responses" {
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    try app.route(Route.post("/users", createUser, .{ .status = .created }));

    const raw_request =
        "POST /users HTTP/1.1\r\n" ++
        "host: example.test\r\n" ++
        "content-type: application/json\r\n" ++
        "content-length: 27\r\n" ++
        "\r\n" ++
        "{\"email\":\"ada@example.com\"}";

    var input = std.Io.Reader.fixed(raw_request);
    var output = std.Io.Writer.Allocating.init(testing.allocator);
    defer output.deinit();

    var server = std.http.Server.init(&input, &output.writer);
    var http_request = try server.receiveHead();
    try app.handleHttp(&http_request);

    try testing.expect(std.mem.indexOf(u8, output.written(), "HTTP/1.1 201 Created\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, output.written(), "content-type: application/json\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, output.written(), "content-length: 34\r\n") != null);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, output.written(), "content-length:"));
    try testing.expect(std.mem.endsWith(u8, output.written(), "{\"id\":1,\"email\":\"ada@example.com\"}"));
}

test "std.http adapter owns framing and preserves head content length" {
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    try app.route(Route.get("/", plainText, .{}));
    try app.route(Route.get("/manual", conflictingContentLength, .{}));

    var get_input = std.Io.Reader.fixed("GET /manual HTTP/1.1\r\nhost: example.test\r\n\r\n");
    var get_output = std.Io.Writer.Allocating.init(testing.allocator);
    defer get_output.deinit();
    var get_server = std.http.Server.init(&get_input, &get_output.writer);
    var get_request = try get_server.receiveHead();
    try app.handleHttp(&get_request);

    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, get_output.written(), "content-length:"));
    try testing.expect(std.mem.indexOf(u8, get_output.written(), "content-length: 12\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, get_output.written(), "content-length: 999\r\n") == null);
    try testing.expect(std.mem.endsWith(u8, get_output.written(), "Hello, world"));

    var head_input = std.Io.Reader.fixed("HEAD / HTTP/1.1\r\nhost: example.test\r\n\r\n");
    var head_output = std.Io.Writer.Allocating.init(testing.allocator);
    defer head_output.deinit();
    var head_server = std.http.Server.init(&head_input, &head_output.writer);
    var head_request = try head_server.receiveHead();
    try app.handleHttp(&head_request);

    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, head_output.written(), "content-length:"));
    try testing.expect(std.mem.indexOf(u8, head_output.written(), "content-length: 12\r\n") != null);
    try testing.expect(std.mem.endsWith(u8, head_output.written(), "\r\n\r\n"));
}

test "response headers reject invalid wire bytes" {
    var response = Response.init(.ok);
    defer response.deinit(testing.allocator);
    try testing.expectError(error.InvalidHeader, response.appendHeader(testing.allocator, "bad:name", "value"));
    try testing.expectError(error.InvalidHeader, response.appendHeader(testing.allocator, "x-safe", "ok\r\nx-injected: yes"));

    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    try app.route(Route.get("/", invalidResponseHeader, .{}));
    var rejected = try app.handle(Request.init(.GET, "/"));
    defer rejected.deinit(testing.allocator);
    try testing.expectEqual(Status.internal_server_error, rejected.status);
}

test "std.http adapter preserves query strings and request headers" {
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    try app.route(Route.get("/headers", echoHeaders, .{}));

    const raw_request =
        "GET /headers?ignored=true HTTP/1.1\r\n" ++
        "host: example.test\r\n" ++
        "x-token: secret\r\n" ++
        "x-debug: true\r\n" ++
        "x-retries: 2\r\n" ++
        "\r\n";

    var input = std.Io.Reader.fixed(raw_request);
    var output = std.Io.Writer.Allocating.init(testing.allocator);
    defer output.deinit();

    var server = std.http.Server.init(&input, &output.writer);
    var http_request = try server.receiveHead();
    try app.handleHttp(&http_request);

    try testing.expect(std.mem.indexOf(u8, output.written(), "HTTP/1.1 200 OK\r\n") != null);
    try testing.expect(std.mem.endsWith(u8, output.written(), "{\"token\":\"secret\",\"debug\":true,\"retries\":2}"));
}

test "std.http adapter preserves cookie headers" {
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    try app.route(Route.get("/cookies", echoCookies, .{}));

    const raw_request =
        "GET /cookies HTTP/1.1\r\n" ++
        "host: example.test\r\n" ++
        "cookie: session_id=abc123; preview=true; visits=7\r\n" ++
        "\r\n";

    var input = std.Io.Reader.fixed(raw_request);
    var output = std.Io.Writer.Allocating.init(testing.allocator);
    defer output.deinit();

    var server = std.http.Server.init(&input, &output.writer);
    var http_request = try server.receiveHead();
    try app.handleHttp(&http_request);

    try testing.expect(std.mem.indexOf(u8, output.written(), "HTTP/1.1 200 OK\r\n") != null);
    try testing.expect(std.mem.endsWith(u8, output.written(), "{\"session_id\":\"abc123\",\"preview\":true,\"visits\":7}"));
}

test "std.http adapter writes set-cookie response headers" {
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    try app.route(Route.get("/set-cookie", setCookieResponse, .{}));

    const raw_request =
        "GET /set-cookie HTTP/1.1\r\n" ++
        "host: example.test\r\n" ++
        "\r\n";

    var input = std.Io.Reader.fixed(raw_request);
    var output = std.Io.Writer.Allocating.init(testing.allocator);
    defer output.deinit();

    var server = std.http.Server.init(&input, &output.writer);
    var http_request = try server.receiveHead();
    try app.handleHttp(&http_request);

    try testing.expect(std.mem.indexOf(u8, output.written(), "HTTP/1.1 200 OK\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, output.written(), "set-cookie: session=abc123; Max-Age=3600; Path=/; Secure; HttpOnly; SameSite=lax\r\n") != null);
    try testing.expect(std.mem.endsWith(u8, output.written(), "ok"));
}

test "std.http adapter preserves urlencoded form bodies" {
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    try app.route(Route.post("/login", login, .{}));

    const body = "username=ada&password=secret&remember=true&attempts=2";
    const raw_request =
        "POST /login HTTP/1.1\r\n" ++
        "host: example.test\r\n" ++
        "content-type: application/x-www-form-urlencoded\r\n" ++
        "content-length: 53\r\n" ++
        "\r\n" ++
        body;

    var input = std.Io.Reader.fixed(raw_request);
    var output = std.Io.Writer.Allocating.init(testing.allocator);
    defer output.deinit();

    var server = std.http.Server.init(&input, &output.writer);
    var http_request = try server.receiveHead();
    try app.handleHttp(&http_request);

    try testing.expect(std.mem.indexOf(u8, output.written(), "HTTP/1.1 200 OK\r\n") != null);
    try testing.expect(std.mem.endsWith(u8, output.written(), "{\"username\":\"ada\",\"remember\":true,\"attempts\":2}"));
}

test "std.http adapter enforces configured request body size limit" {
    var app = ZAPI.init(testing.allocator, .{ .max_request_body_size = 8 });
    defer app.deinit();
    try app.route(Route.post("/users", createUser, .{}));

    const raw_request =
        "POST /users HTTP/1.1\r\n" ++
        "host: example.test\r\n" ++
        "content-type: application/json\r\n" ++
        "content-length: 27\r\n" ++
        "\r\n" ++
        "{\"email\":\"ada@example.com\"}";

    var input = std.Io.Reader.fixed(raw_request);
    var output = std.Io.Writer.Allocating.init(testing.allocator);
    defer output.deinit();

    var server = std.http.Server.init(&input, &output.writer);
    var http_request = try server.receiveHead();
    try app.handleHttp(&http_request);

    try testing.expect(std.mem.indexOf(u8, output.written(), "HTTP/1.1 413 Payload Too Large\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, output.written(), "content-type: application/json\r\n") != null);
    try testing.expect(std.mem.endsWith(u8, output.written(), "{\"detail\":\"Request body too large\"}"));
}

test "std.http adapter uses status handlers for request body size limit" {
    var app = ZAPI.init(testing.allocator, .{ .max_request_body_size = 8 });
    defer app.deinit();
    try app.addStatusHandler(.payload_too_large, handleStatusPlain);
    try app.route(Route.post("/users", createUser, .{}));

    const raw_request =
        "POST /users HTTP/1.1\r\n" ++
        "host: example.test\r\n" ++
        "content-type: application/json\r\n" ++
        "content-length: 27\r\n" ++
        "\r\n" ++
        "{\"email\":\"ada@example.com\"}";

    var input = std.Io.Reader.fixed(raw_request);
    var output = std.Io.Writer.Allocating.init(testing.allocator);
    defer output.deinit();

    var server = std.http.Server.init(&input, &output.writer);
    var http_request = try server.receiveHead();
    try app.handleHttp(&http_request);

    try testing.expect(std.mem.indexOf(u8, output.written(), "HTTP/1.1 413 Payload Too Large\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, output.written(), "content-type: text/plain; charset=utf-8\r\n") != null);
    try testing.expect(std.mem.endsWith(u8, output.written(), "413 /users Request body too large"));
}

test "std.http adapter preserves chunked request bodies" {
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    try app.route(Route.post("/body", bodySize, .{}));

    const raw_request =
        "POST /body HTTP/1.1\r\n" ++
        "host: example.test\r\n" ++
        "transfer-encoding: chunked\r\n" ++
        "\r\n" ++
        "3\r\n" ++
        "foo\r\n" ++
        "3\r\n" ++
        "bar\r\n" ++
        "0\r\n" ++
        "\r\n";

    var input = std.Io.Reader.fixed(raw_request);
    var output = std.Io.Writer.Allocating.init(testing.allocator);
    defer output.deinit();

    var server = std.http.Server.init(&input, &output.writer);
    var http_request = try server.receiveHead();
    try app.handleHttp(&http_request);

    try testing.expect(std.mem.indexOf(u8, output.written(), "HTTP/1.1 200 OK\r\n") != null);
    try testing.expect(std.mem.endsWith(u8, output.written(), "{\"size\":6}"));
}

test "std.http streaming adapter exposes incremental request body reader" {
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    try app.route(Route.post("/stream", streamReaderBody, .{}));

    const raw_request =
        "POST /stream HTTP/1.1\r\n" ++
        "host: example.test\r\n" ++
        "transfer-encoding: chunked\r\n" ++
        "\r\n" ++
        "3\r\n" ++
        "foo\r\n" ++
        "4\r\n" ++
        "bar!\r\n" ++
        "0\r\n" ++
        "\r\n";

    var input = std.Io.Reader.fixed(raw_request);
    var output = std.Io.Writer.Allocating.init(testing.allocator);
    defer output.deinit();

    var server = std.http.Server.init(&input, &output.writer);
    var http_request = try server.receiveHead();
    try app.handleHttpStreaming(&http_request);

    try testing.expect(std.mem.indexOf(u8, output.written(), "HTTP/1.1 200 OK\r\n") != null);
    try testing.expect(std.mem.endsWith(u8, output.written(), "{\"chunks\":[\"foo\",\"bar\",\"!\"],\"joined\":\"foobar!\"}"));
}

test "std.http adapter enforces configured chunked request body size limit" {
    var app = ZAPI.init(testing.allocator, .{ .max_request_body_size = 5 });
    defer app.deinit();
    try app.route(Route.post("/body", bodySize, .{}));

    const raw_request =
        "POST /body HTTP/1.1\r\n" ++
        "host: example.test\r\n" ++
        "transfer-encoding: chunked\r\n" ++
        "\r\n" ++
        "3\r\n" ++
        "foo\r\n" ++
        "3\r\n" ++
        "bar\r\n" ++
        "0\r\n" ++
        "\r\n";

    var input = std.Io.Reader.fixed(raw_request);
    var output = std.Io.Writer.Allocating.init(testing.allocator);
    defer output.deinit();

    var server = std.http.Server.init(&input, &output.writer);
    var http_request = try server.receiveHead();
    try app.handleHttp(&http_request);

    try testing.expect(std.mem.indexOf(u8, output.written(), "HTTP/1.1 413 Payload Too Large\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, output.written(), "content-type: application/json\r\n") != null);
    try testing.expect(std.mem.endsWith(u8, output.written(), "{\"detail\":\"Request body too large\"}"));
}

test "std.http streaming adapter enforces configured request body size limit while reading" {
    var app = ZAPI.init(testing.allocator, .{ .max_request_body_size = 5 });
    defer app.deinit();
    try app.route(Route.post("/stream", streamReaderBody, .{}));

    const raw_request =
        "POST /stream HTTP/1.1\r\n" ++
        "host: example.test\r\n" ++
        "transfer-encoding: chunked\r\n" ++
        "\r\n" ++
        "3\r\n" ++
        "foo\r\n" ++
        "3\r\n" ++
        "bar\r\n" ++
        "0\r\n" ++
        "\r\n";

    var input = std.Io.Reader.fixed(raw_request);
    var output = std.Io.Writer.Allocating.init(testing.allocator);
    defer output.deinit();

    var server = std.http.Server.init(&input, &output.writer);
    var http_request = try server.receiveHead();
    try app.handleHttpStreaming(&http_request);

    try testing.expect(std.mem.indexOf(u8, output.written(), "HTTP/1.1 413 Payload Too Large\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, output.written(), "content-type: application/json\r\n") != null);
    try testing.expect(std.mem.endsWith(u8, output.written(), "{\"detail\":\"Request body too large\"}"));
}

test "std.http adapter preserves multipart form uploads" {
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    try app.route(Route.post("/profile", uploadProfile, .{}));

    const body =
        "--zapi-boundary\r\n" ++
        "Content-Disposition: form-data; name=\"username\"\r\n" ++
        "\r\n" ++
        "ada\r\n" ++
        "--zapi-boundary\r\n" ++
        "Content-Disposition: form-data; name=\"avatar\"; filename=\"avatar.txt\"\r\n" ++
        "Content-Type: text/plain\r\n" ++
        "\r\n" ++
        "hello file\r\n" ++
        "--zapi-boundary--\r\n";

    const raw_request = try std.fmt.allocPrint(
        testing.allocator,
        "POST /profile HTTP/1.1\r\n" ++
            "host: example.test\r\n" ++
            "content-type: multipart/form-data; boundary=zapi-boundary\r\n" ++
            "content-length: {d}\r\n" ++
            "\r\n" ++
            "{s}",
        .{ body.len, body },
    );
    defer testing.allocator.free(raw_request);

    var input = std.Io.Reader.fixed(raw_request);
    var output = std.Io.Writer.Allocating.init(testing.allocator);
    defer output.deinit();

    var server = std.http.Server.init(&input, &output.writer);
    var http_request = try server.receiveHead();
    try app.handleHttp(&http_request);

    try testing.expect(std.mem.indexOf(u8, output.written(), "HTTP/1.1 200 OK\r\n") != null);
    try testing.expect(std.mem.endsWith(u8, output.written(), "{\"username\":\"ada\",\"filename\":\"avatar.txt\",\"content_type\":\"text/plain\",\"size\":10}"));
}

test "std.http adapter runs middleware chain" {
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    try app.addMiddleware(addMiddlewareHeader);
    try app.route(Route.get("/", plainText, .{}));

    const raw_request =
        "GET / HTTP/1.1\r\n" ++
        "host: example.test\r\n" ++
        "\r\n";

    var input = std.Io.Reader.fixed(raw_request);
    var output = std.Io.Writer.Allocating.init(testing.allocator);
    defer output.deinit();

    var server = std.http.Server.init(&input, &output.writer);
    var http_request = try server.receiveHead();
    try app.handleHttp(&http_request);

    try testing.expect(std.mem.indexOf(u8, output.written(), "HTTP/1.1 200 OK\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, output.written(), "x-middleware: yes\r\n") != null);
    try testing.expect(std.mem.endsWith(u8, output.written(), "Hello, world"));
}

test "std.http adapter runs background tasks after responding" {
    var state: BackgroundState = .{};
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    app.setState(&state);
    try app.route(Route.get("/background", backgroundPayload, .{}));
    try app.route(Route.get("/background-list", backgroundTasksPayload, .{}));

    const raw_request =
        "GET /background HTTP/1.1\r\n" ++
        "host: example.test\r\n" ++
        "\r\n";

    var input = std.Io.Reader.fixed(raw_request);
    var output = std.Io.Writer.Allocating.init(testing.allocator);
    defer output.deinit();

    var server = std.http.Server.init(&input, &output.writer);
    var http_request = try server.receiveHead();
    try app.handleHttp(&http_request);

    try testing.expect(std.mem.indexOf(u8, output.written(), "HTTP/1.1 200 OK\r\n") != null);
    try testing.expect(std.mem.endsWith(u8, output.written(), "queued"));
    try testing.expectEqual(@as(usize, 1), state.count);

    const raw_list_request =
        "GET /background-list HTTP/1.1\r\n" ++
        "host: example.test\r\n" ++
        "\r\n";

    var list_input = std.Io.Reader.fixed(raw_list_request);
    var list_output = std.Io.Writer.Allocating.init(testing.allocator);
    defer list_output.deinit();

    var list_server = std.http.Server.init(&list_input, &list_output.writer);
    var list_http_request = try list_server.receiveHead();
    try app.handleHttp(&list_http_request);

    try testing.expect(std.mem.indexOf(u8, list_output.written(), "HTTP/1.1 200 OK\r\n") != null);
    try testing.expect(std.mem.endsWith(u8, list_output.written(), "queued-list"));
    try testing.expectEqual(@as(usize, 3), state.count);
}

test "serveListener provides request-scoped io without mutating app options" {
    const io = testing.io;

    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    try app.route(Route.get("/", ioAvailable, .{}));

    const listen_address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try listen_address.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);

    var server_future = try io.concurrent(serveBoundOnce, .{ &app, io, &listener });

    var stream = try listener.socket.address.connect(io, .{ .mode = .stream, .protocol = .tcp });
    defer stream.close(io);

    var read_buffer: [4096]u8 = undefined;
    var write_buffer: [4096]u8 = undefined;
    var connection_reader = stream.reader(io, &read_buffer);
    var connection_writer = stream.writer(io, &write_buffer);

    try connection_writer.interface.writeAll(
        "GET / HTTP/1.1\r\n" ++
            "host: localhost\r\n" ++
            "connection: close\r\n" ++
            "\r\n",
    );
    try connection_writer.interface.flush();
    try stream.shutdown(io, .send);

    var response = std.Io.Writer.Allocating.init(testing.allocator);
    defer response.deinit();

    var chunk: [1024]u8 = undefined;
    while (true) {
        const n = try connection_reader.interface.readSliceShort(&chunk);
        if (n == 0) break;
        try response.writer.writeAll(chunk[0..n]);
    }

    try server_future.await(io);

    try testing.expect(std.mem.indexOf(u8, response.written(), "HTTP/1.1 200 OK\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, response.written(), "content-type: application/json\r\n") != null);
    try testing.expect(std.mem.endsWith(u8, response.written(), "{\"available\":true}"));
    try testing.expectEqual(null, app.options.io);
}

test "serveListener rejects an empty concurrency limit" {
    const io = testing.io;
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();

    const listen_address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try listen_address.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);

    try testing.expectError(error.InvalidConcurrencyLimit, app.serveListener(io, &listener, .{
        .max_connections = 0,
        .concurrent_connections = true,
        .max_concurrent_connections = 0,
    }));
}

test "serveListener can stream request bodies without adapter buffering" {
    const io = testing.io;

    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    try app.route(Route.post("/stream", streamReaderBody, .{}));

    const listen_address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try listen_address.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);

    var server_future = try io.concurrent(serveBoundStreamingOnce, .{ &app, io, &listener });

    var stream = try listener.socket.address.connect(io, .{ .mode = .stream, .protocol = .tcp });
    defer stream.close(io);

    var read_buffer: [4096]u8 = undefined;
    var write_buffer: [4096]u8 = undefined;
    var connection_reader = stream.reader(io, &read_buffer);
    var connection_writer = stream.writer(io, &write_buffer);

    try connection_writer.interface.writeAll(
        "POST /stream HTTP/1.1\r\n" ++
            "host: localhost\r\n" ++
            "transfer-encoding: chunked\r\n" ++
            "connection: close\r\n" ++
            "\r\n" ++
            "3\r\n" ++
            "foo\r\n" ++
            "4\r\n" ++
            "bar!\r\n" ++
            "0\r\n" ++
            "\r\n",
    );
    try connection_writer.interface.flush();
    try stream.shutdown(io, .send);

    var response = std.Io.Writer.Allocating.init(testing.allocator);
    defer response.deinit();

    var chunk: [1024]u8 = undefined;
    while (true) {
        const n = try connection_reader.interface.readSliceShort(&chunk);
        if (n == 0) break;
        try response.writer.writeAll(chunk[0..n]);
    }

    try server_future.await(io);

    try testing.expect(std.mem.indexOf(u8, response.written(), "HTTP/1.1 200 OK\r\n") != null);
    try testing.expect(std.mem.endsWith(u8, response.written(), "{\"chunks\":[\"foo\",\"bar\",\"!\"],\"joined\":\"foobar!\"}"));
}

test "serveListener can handle tcp connections concurrently" {
    const io = testing.io;

    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    try app.route(Route.get("/", plainText, .{}));

    const listen_address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try listen_address.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);

    var server_future = try io.concurrent(serveBoundConcurrentTwo, .{ &app, io, &listener });

    var stream1 = try listener.socket.address.connect(io, .{ .mode = .stream, .protocol = .tcp });
    defer stream1.close(io);
    var stream2 = try listener.socket.address.connect(io, .{ .mode = .stream, .protocol = .tcp });
    defer stream2.close(io);

    var read_buffer1: [4096]u8 = undefined;
    var write_buffer1: [4096]u8 = undefined;
    var reader1 = stream1.reader(io, &read_buffer1);
    var writer1 = stream1.writer(io, &write_buffer1);

    try writer1.interface.writeAll(
        "GET / HTTP/1.1\r\n" ++
            "host: localhost\r\n" ++
            "connection: close\r\n" ++
            "\r\n",
    );
    try writer1.interface.flush();
    try stream1.shutdown(io, .send);

    var read_buffer2: [4096]u8 = undefined;
    var write_buffer2: [4096]u8 = undefined;
    var reader2 = stream2.reader(io, &read_buffer2);
    var writer2 = stream2.writer(io, &write_buffer2);

    try writer2.interface.writeAll(
        "GET / HTTP/1.1\r\n" ++
            "host: localhost\r\n" ++
            "connection: close\r\n" ++
            "\r\n",
    );
    try writer2.interface.flush();
    try stream2.shutdown(io, .send);

    var response1 = std.Io.Writer.Allocating.init(testing.allocator);
    defer response1.deinit();
    var chunk1: [1024]u8 = undefined;
    while (true) {
        const n = try reader1.interface.readSliceShort(&chunk1);
        if (n == 0) break;
        try response1.writer.writeAll(chunk1[0..n]);
    }

    var response2 = std.Io.Writer.Allocating.init(testing.allocator);
    defer response2.deinit();
    var chunk2: [1024]u8 = undefined;
    while (true) {
        const n = try reader2.interface.readSliceShort(&chunk2);
        if (n == 0) break;
        try response2.writer.writeAll(chunk2[0..n]);
    }

    try server_future.await(io);

    try testing.expect(std.mem.indexOf(u8, response1.written(), "HTTP/1.1 200 OK\r\n") != null);
    try testing.expect(std.mem.endsWith(u8, response1.written(), "Hello, world"));
    try testing.expect(std.mem.indexOf(u8, response2.written(), "HTTP/1.1 200 OK\r\n") != null);
    try testing.expect(std.mem.endsWith(u8, response2.written(), "Hello, world"));
}

test "serveListener stops after graceful shutdown signal is requested" {
    const io = testing.io;

    var shutdown_signal: ShutdownSignal = .{};
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    app.setState(&shutdown_signal);
    try app.route(Route.get("/shutdown", requestShutdown, .{}));

    const listen_address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try listen_address.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);

    var server_future = try io.concurrent(serveUntilShutdown, .{ &app, io, &listener, &shutdown_signal });

    var stream = try listener.socket.address.connect(io, .{ .mode = .stream, .protocol = .tcp });
    defer stream.close(io);

    var read_buffer: [4096]u8 = undefined;
    var write_buffer: [4096]u8 = undefined;
    var connection_reader = stream.reader(io, &read_buffer);
    var connection_writer = stream.writer(io, &write_buffer);

    try connection_writer.interface.writeAll(
        "GET /shutdown HTTP/1.1\r\n" ++
            "host: localhost\r\n" ++
            "connection: close\r\n" ++
            "\r\n",
    );
    try connection_writer.interface.flush();
    try stream.shutdown(io, .send);

    var response = std.Io.Writer.Allocating.init(testing.allocator);
    defer response.deinit();

    var chunk: [1024]u8 = undefined;
    while (true) {
        const n = try connection_reader.interface.readSliceShort(&chunk);
        if (n == 0) break;
        try response.writer.writeAll(chunk[0..n]);
    }

    try server_future.await(io);

    try testing.expect(shutdown_signal.isRequested());
    try testing.expect(std.mem.indexOf(u8, response.written(), "HTTP/1.1 200 OK\r\n") != null);
    try testing.expect(std.mem.endsWith(u8, response.written(), "stopping"));
}

test "serve can bind and return when max connections is zero" {
    const io = testing.io;

    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();

    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    try app.serve(io, address, .{ .max_connections = 0 });
}
