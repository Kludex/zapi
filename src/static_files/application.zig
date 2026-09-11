//! Static file application and range-aware file serving.
//! Paths resolve beneath the configured directory and reject symlinks by default.

const std = @import("std");
const builtin = @import("builtin");
const applications = @import("../applications.zig");
const core = @import("core.zig");
const header_utils = @import("../headers.zig");

const Context = applications.Context;
const HeaderField = applications.HeaderField;
const Method = applications.Method;
const Request = applications.Request;
const Response = applications.Response;
const ResponsePayload = applications.ResponsePayload;
const Route = applications.Route;
const Status = applications.Status;
const StatusHandlerContext = applications.StatusHandlerContext;
const ZAPI = applications.ZAPI;
const testing = std.testing;
const ownedRedirectLocationHeader = header_utils.ownedRedirectLocation;
const StaticPath = core.StaticPath;
const ByteRangeDecision = core.ByteRangeDecision;
const responseFileContentType = core.responseFileContentType;
const responseFileHeaders = core.responseFileHeaders;
const statFileSize = core.statFileSize;
const fileResponseEtag = core.fileResponseEtag;
const freeOwnedHeaders = core.freeOwnedHeaders;
const requestNotModified = core.requestNotModified;
const requestByteRange = core.requestByteRange;
const applyByteRange = core.applyByteRange;
const multipartByteRangesLength = core.multipartByteRangesLength;
const multipartByteRangesBodyAlloc = core.multipartByteRangesBodyAlloc;
const httpDateAlloc = core.httpDateAlloc;
const timestampSeconds = core.timestampSeconds;
const staticFileTargetPath = core.staticFileTargetPath;
const staticContentType = core.staticContentType;
const multipart_range_boundary = core.multipart_range_boundary;

pub const StaticFilesOptions = struct {
    dir: std.Io.Dir = .cwd(),
    html: bool = false,
    follow_symlinks: bool = false,
    max_size: std.Io.Limit = .limited(16 * 1024 * 1024),
    io: ?std.Io = null,
};

const StaticFilesState = struct {
    dir: std.Io.Dir,
    html: bool,
    follow_symlinks: bool,
    max_size: std.Io.Limit,
};

pub const StaticFiles = struct {
    app: ZAPI,
    state: *StaticFilesState,

    pub fn init(allocator: std.mem.Allocator, options: StaticFilesOptions) !StaticFiles {
        const state = try allocator.create(StaticFilesState);
        errdefer allocator.destroy(state);
        state.* = .{
            .dir = options.dir,
            .html = options.html,
            .follow_symlinks = options.follow_symlinks,
            .max_size = options.max_size,
        };

        var app = ZAPI.init(allocator, .{
            .openapi_url = null,
            .docs_url = null,
            .oauth2_redirect_url = null,
            .redoc_url = null,
            .io = options.io,
        });
        errdefer app.deinit();
        app.setState(state);
        try app.addStatusHandler(.method_not_allowed, staticMethodNotAllowed);
        try app.route(Route.methods("/", &.{ .GET, .HEAD }, staticFileRoot, .{}));
        try app.route(Route.methods("/{path:path}", &.{ .GET, .HEAD }, staticFilePath, .{}));

        return .{
            .app = app,
            .state = state,
        };
    }

    pub fn deinit(self: *StaticFiles) void {
        const allocator = self.app.allocator;
        self.app.deinit();
        allocator.destroy(self.state);
    }
};

fn staticFileRoot(ctx: *Context) !ResponsePayload {
    return serveStaticFile(ctx, "");
}

fn staticFilePath(ctx: *Context) !ResponsePayload {
    return serveStaticFile(ctx, ctx.pathValue("path") orelse "");
}

fn serveStaticFile(ctx: *Context, raw_path: []const u8) !ResponsePayload {
    const state = ctx.state(StaticFilesState);
    const io = ctx.io orelse return error.MissingIo;
    const target = staticFileTargetPath(ctx.allocator, raw_path, state.html) catch return staticNotFound(ctx, state, io);
    defer if (target.owned) ctx.allocator.free(target.value);

    return serveStaticFileTarget(ctx, state, io, target.value, null) catch |err| switch (err) {
        error.IsDir => {
            if (try staticHtmlDirectoryHasIndex(ctx, state, io, raw_path)) {
                return staticDirectoryRedirect(ctx);
            }
            return staticNotFound(ctx, state, io);
        },
        error.AccessDenied, error.PermissionDenied => return staticUnauthorized(),
        error.FileNotFound, error.NotDir, error.SymLinkLoop => return staticNotFound(ctx, state, io),
        else => return err,
    };
}

fn serveStaticFileTarget(ctx: *Context, state: *StaticFilesState, io: std.Io, path: []const u8, status_override: ?Status) !ResponsePayload {
    var file = try state.dir.openFile(io, path, .{
        .allow_directory = false,
        .follow_symlinks = state.follow_symlinks,
        .resolve_beneath = true,
    });
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.kind != .file) return error.IsDir;
    const full_len = try statFileSize(stat);
    const last_modified_seconds = timestampSeconds(stat.mtime);
    const last_modified = try httpDateAlloc(ctx.allocator, last_modified_seconds);
    defer ctx.allocator.free(last_modified);

    const etag = try fileResponseEtag(ctx.allocator, stat);
    defer ctx.allocator.free(etag);

    const conditional = status_override == null;
    const not_modified = conditional and requestNotModified(ctx.request, etag, last_modified_seconds);
    var range_decision = if (conditional and !not_modified) try requestByteRange(ctx.allocator, ctx.request, etag, last_modified_seconds, full_len) else ByteRangeDecision.none;
    defer range_decision.deinit(ctx.allocator);
    switch (range_decision) {
        .malformed => |message| return .{
            .status = .bad_request,
            .content_type = "text/plain; charset=utf-8",
            .body = message,
        },
        else => {},
    }
    const status: ?Status = if (not_modified) .not_modified else switch (range_decision) {
        .none => status_override,
        .partial => .partial_content,
        .multiple => .partial_content,
        .unsatisfiable => .requested_range_not_satisfiable,
        .malformed => unreachable,
    };

    const file_content_type = staticContentType(path);
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
        var file_reader = file.reader(io, &.{});
        var file_body = try file_reader.interface.allocRemaining(ctx.allocator, state.max_size);
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

    const headers = try responseFileHeaders(ctx.allocator, &.{}, body_len, full_len, etag, last_modified, null, .attachment, status orelse .ok, range_decision);
    errdefer freeOwnedHeaders(ctx.allocator, headers);

    return .{
        .status = status,
        .content_type = response_content_type,
        .headers = headers,
        .owned_headers = true,
        .body = body,
        .owned_body = owned_body,
    };
}

fn staticNotFound(ctx: *Context, state: *StaticFilesState, io: std.Io) !ResponsePayload {
    if (state.html) {
        if (serveStaticFileTarget(ctx, state, io, "404.html", .not_found)) |payload| {
            return payload;
        } else |err| switch (err) {
            error.FileNotFound, error.IsDir, error.NotDir, error.AccessDenied, error.PermissionDenied => {},
            else => return err,
        }
    }

    return .{
        .status = .not_found,
        .content_type = "text/plain; charset=utf-8",
        .body = "Not Found",
    };
}

fn staticMethodNotAllowed(ctx: *StatusHandlerContext) !Response {
    var response = Response.init(.method_not_allowed);
    try response.setHeader(ctx.app.allocator, "content-type", "text/plain; charset=utf-8");
    try response.body.appendSlice(ctx.app.allocator, "Method Not Allowed");
    return response;
}

fn staticUnauthorized() ResponsePayload {
    return .{
        .status = .unauthorized,
        .content_type = "text/plain; charset=utf-8",
        .body = "Unauthorized",
    };
}

fn staticHtmlDirectoryHasIndex(ctx: *Context, state: *StaticFilesState, io: std.Io, raw_path: []const u8) !bool {
    if (!state.html or raw_path.len == 0 or std.mem.endsWith(u8, raw_path, "/")) return false;

    const index_path = try std.fmt.allocPrint(ctx.allocator, "{s}/index.html", .{raw_path});
    defer ctx.allocator.free(index_path);
    _ = state.dir.statFile(io, index_path, .{}) catch |err| switch (err) {
        error.FileNotFound, error.IsDir, error.NotDir, error.AccessDenied, error.PermissionDenied => return false,
        else => return err,
    };
    return true;
}

fn staticDirectoryRedirect(ctx: *Context) !ResponsePayload {
    var location = std.Io.Writer.Allocating.init(ctx.allocator);
    defer location.deinit();

    if (ctx.request.root_path.len > 0) try location.writer.writeAll(ctx.request.root_path);
    try location.writer.writeAll(ctx.request.path);
    try location.writer.writeAll("/");
    if (ctx.request.query.len > 0) {
        try location.writer.writeAll("?");
        try location.writer.writeAll(ctx.request.query);
    }

    const headers = try ctx.allocator.alloc(HeaderField, 1);
    errdefer ctx.allocator.free(headers);
    headers[0] = try ownedRedirectLocationHeader(ctx.allocator, location.written());

    return .{
        .status = .temporary_redirect,
        .content_type = "",
        .headers = headers,
        .owned_headers = true,
    };
}

test "static files serve mounted assets and html indexes" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "assets");
    try tmp.dir.createDirPath(testing.io, "empty");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "assets/site.css", .data = "body { color: black; }" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "assets/data.json", .data = "{}" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "assets/icon.SVG", .data = "<svg></svg>" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "assets/photo.jpeg", .data = "jpeg" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "assets/preview.webp", .data = "webp" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "assets/favicon.ico", .data = "ico" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "assets/module.wasm", .data = "wasm" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "assets/report.pdf", .data = "%PDF" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "index.html", .data = "<h1>Home</h1>" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "assets/index.html", .data = "<h1>Assets</h1>" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "404.html", .data = "<h1>Missing</h1>" });

    var static_files = try StaticFiles.init(testing.allocator, .{
        .dir = tmp.dir,
        .html = true,
    });
    defer static_files.deinit();

    var metadata_static_files = try StaticFiles.init(testing.allocator, .{
        .dir = tmp.dir,
        .max_size = .limited(0),
    });
    defer metadata_static_files.deinit();

    var parent = ZAPI.init(testing.allocator, .{ .io = testing.io });
    defer parent.deinit();
    try parent.mount("/static", &static_files.app);
    try parent.mount("/metadata-static", &metadata_static_files.app);

    var css = try parent.handle(Request.init(.GET, "/static/assets/site.css"));
    defer css.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, css.status);
    try testing.expectEqualStrings("text/css; charset=utf-8", css.header("content-type").?);
    try testing.expectEqualStrings("22", css.header("content-length").?);
    const css_etag = css.header("etag").?;
    try testing.expectEqualStrings("bytes", css.header("accept-ranges").?);
    const css_last_modified = css.header("last-modified").?;
    try testing.expect(std.mem.endsWith(u8, css_last_modified, " GMT"));
    try testing.expectEqualStrings("body { color: black; }", css.body.items);

    var css_head = try parent.handle(Request.init(.HEAD, "/static/assets/site.css"));
    defer css_head.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, css_head.status);
    try testing.expectEqualStrings("text/css; charset=utf-8", css_head.header("content-type").?);
    try testing.expectEqualStrings("22", css_head.header("content-length").?);
    try testing.expectEqualStrings(css_etag, css_head.header("etag").?);
    try testing.expectEqualStrings(css_last_modified, css_head.header("last-modified").?);
    try testing.expectEqual(@as(usize, 0), css_head.body.items.len);

    var metadata_head = try parent.handle(Request.init(.HEAD, "/metadata-static/assets/site.css"));
    defer metadata_head.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, metadata_head.status);
    try testing.expectEqualStrings("text/css; charset=utf-8", metadata_head.header("content-type").?);
    try testing.expectEqualStrings("22", metadata_head.header("content-length").?);
    try testing.expect(metadata_head.header("etag") != null);
    try testing.expect(metadata_head.header("last-modified") != null);
    try testing.expectEqual(@as(usize, 0), metadata_head.body.items.len);

    var wrong_method = try parent.handle(Request.init(.POST, "/static/assets/site.css"));
    defer wrong_method.deinit(testing.allocator);
    try testing.expectEqual(Status.method_not_allowed, wrong_method.status);
    try testing.expectEqualStrings("HEAD, GET, OPTIONS", wrong_method.header("allow").?);

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "assets/private.txt", .data = "secret" });
    try tmp.dir.setFilePermissions(testing.io, "assets/private.txt", @enumFromInt(0o000), .{});
    defer tmp.dir.setFilePermissions(testing.io, "assets/private.txt", @enumFromInt(0o666), .{}) catch {};
    var private = try parent.handle(Request.init(.GET, "/static/assets/private.txt"));
    defer private.deinit(testing.allocator);
    try testing.expectEqual(Status.unauthorized, private.status);
    try testing.expectEqualStrings("text/plain; charset=utf-8", private.header("content-type").?);
    try testing.expectEqualStrings("Unauthorized", private.body.items);

    const asset_content_types = &.{
        .{ .path = "/static/assets/data.json", .content_type = "application/json" },
        .{ .path = "/static/assets/icon.SVG", .content_type = "image/svg+xml" },
        .{ .path = "/static/assets/photo.jpeg", .content_type = "image/jpeg" },
        .{ .path = "/static/assets/preview.webp", .content_type = "image/webp" },
        .{ .path = "/static/assets/favicon.ico", .content_type = "image/x-icon" },
        .{ .path = "/static/assets/module.wasm", .content_type = "application/wasm" },
        .{ .path = "/static/assets/report.pdf", .content_type = "application/pdf" },
    };
    inline for (asset_content_types) |case| {
        var asset = try parent.handle(Request.init(.GET, case.path));
        defer asset.deinit(testing.allocator);
        try testing.expectEqual(Status.ok, asset.status);
        try testing.expectEqualStrings(case.content_type, asset.header("content-type").?);
    }

    var conditional_req = Request.init(.GET, "/static/assets/site.css");
    conditional_req.headers = &.{.{ .name = "if-none-match", .value = css_etag }};
    var conditional = try parent.handle(conditional_req);
    defer conditional.deinit(testing.allocator);
    try testing.expectEqual(Status.not_modified, conditional.status);
    try testing.expectEqualStrings(css_etag, conditional.header("etag").?);
    try testing.expectEqualStrings(css_last_modified, conditional.header("last-modified").?);
    try testing.expect(conditional.header("content-type") == null);
    try testing.expect(conditional.header("content-length") == null);
    try testing.expectEqual(@as(usize, 0), conditional.body.items.len);

    var modified_since_req = Request.init(.GET, "/static/assets/site.css");
    modified_since_req.headers = &.{.{ .name = "if-modified-since", .value = css_last_modified }};
    var modified_since = try parent.handle(modified_since_req);
    defer modified_since.deinit(testing.allocator);
    try testing.expectEqual(Status.not_modified, modified_since.status);
    try testing.expectEqualStrings(css_etag, modified_since.header("etag").?);
    try testing.expectEqualStrings(css_last_modified, modified_since.header("last-modified").?);
    try testing.expect(modified_since.header("content-type") == null);
    try testing.expect(modified_since.header("content-length") == null);
    try testing.expectEqual(@as(usize, 0), modified_since.body.items.len);

    var range_req = Request.init(.GET, "/static/assets/site.css");
    range_req.headers = &.{.{ .name = "range", .value = "bytes=0-3" }};
    var range_response = try parent.handle(range_req);
    defer range_response.deinit(testing.allocator);
    try testing.expectEqual(Status.partial_content, range_response.status);
    try testing.expectEqualStrings("bytes 0-3/22", range_response.header("content-range").?);
    try testing.expectEqualStrings("4", range_response.header("content-length").?);
    try testing.expectEqualStrings("body", range_response.body.items);

    const expected_static_multipart =
        "--zapi-boundary\r\n" ++
        "Content-Type: text/css; charset=utf-8\r\n" ++
        "Content-Range: bytes 0-3/22\r\n" ++
        "\r\n" ++
        "body\r\n" ++
        "--zapi-boundary\r\n" ++
        "Content-Type: text/css; charset=utf-8\r\n" ++
        "Content-Range: bytes 14-18/22\r\n" ++
        "\r\n" ++
        "black\r\n" ++
        "--zapi-boundary--";

    var multipart_static_req = Request.init(.GET, "/static/assets/site.css");
    multipart_static_req.headers = &.{.{ .name = "range", .value = "bytes=0-3,14-18" }};
    var multipart_static = try parent.handle(multipart_static_req);
    defer multipart_static.deinit(testing.allocator);
    try testing.expectEqual(Status.partial_content, multipart_static.status);
    try testing.expectEqualStrings("multipart/byteranges; boundary=zapi-boundary", multipart_static.header("content-type").?);
    try testing.expect(multipart_static.header("content-range") == null);
    try testing.expectEqualStrings("206", multipart_static.header("content-length").?);
    try testing.expectEqualStrings(expected_static_multipart, multipart_static.body.items);

    var malformed_range_req = Request.init(.GET, "/static/assets/site.css");
    malformed_range_req.headers = &.{.{ .name = "range", .value = "items=0-3" }};
    var malformed_range = try parent.handle(malformed_range_req);
    defer malformed_range.deinit(testing.allocator);
    try testing.expectEqual(Status.bad_request, malformed_range.status);
    try testing.expectEqualStrings("text/plain; charset=utf-8", malformed_range.header("content-type").?);
    try testing.expectEqualStrings("Only support bytes range", malformed_range.body.items);

    var root_index = try parent.handle(Request.init(.GET, "/static"));
    defer root_index.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, root_index.status);
    try testing.expectEqualStrings("text/html; charset=utf-8", root_index.header("content-type").?);
    try testing.expectEqualStrings("13", root_index.header("content-length").?);
    try testing.expectEqualStrings("<h1>Home</h1>", root_index.body.items);

    var nested_index = try parent.handle(Request.init(.GET, "/static/assets/"));
    defer nested_index.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, nested_index.status);
    try testing.expectEqualStrings("15", nested_index.header("content-length").?);
    try testing.expectEqualStrings("<h1>Assets</h1>", nested_index.body.items);

    var nested_redirect = try parent.handle(Request.init(.GET, "/static/assets?tab=main"));
    defer nested_redirect.deinit(testing.allocator);
    try testing.expectEqual(Status.temporary_redirect, nested_redirect.status);
    try testing.expectEqualStrings("/static/assets/?tab=main", nested_redirect.header("location").?);
    try testing.expectEqualStrings("0", nested_redirect.header("content-length").?);
    try testing.expectEqual(@as(usize, 0), nested_redirect.body.items.len);

    var missing_index = try parent.handle(Request.init(.GET, "/static/empty"));
    defer missing_index.deinit(testing.allocator);
    try testing.expectEqual(Status.not_found, missing_index.status);
    try testing.expectEqualStrings("text/html; charset=utf-8", missing_index.header("content-type").?);
    try testing.expectEqualStrings("16", missing_index.header("content-length").?);
    try testing.expectEqualStrings("<h1>Missing</h1>", missing_index.body.items);

    var custom_missing = try parent.handle(Request.init(.GET, "/static/missing-page"));
    defer custom_missing.deinit(testing.allocator);
    try testing.expectEqual(Status.not_found, custom_missing.status);
    try testing.expectEqualStrings("text/html; charset=utf-8", custom_missing.header("content-type").?);
    try testing.expectEqualStrings("<h1>Missing</h1>", custom_missing.body.items);
}

test "static files reject symlinks by default" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "secret.txt", .data = "secret" });
    try tmp.dir.symLink(testing.io, "secret.txt", "public.txt", .{});

    var static_files = try StaticFiles.init(testing.allocator, .{
        .dir = tmp.dir,
        .io = testing.io,
    });
    defer static_files.deinit();

    var response = try static_files.app.handle(Request.init(.GET, "/public.txt"));
    defer response.deinit(testing.allocator);
    try testing.expectEqual(Status.not_found, response.status);
}

test "static files reject traversal malformed and missing paths" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "app.js", .data = "console.log('zapi');" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "space file.txt", .data = "space" });

    var static_files = try StaticFiles.init(testing.allocator, .{
        .dir = tmp.dir,
        .io = testing.io,
    });
    defer static_files.deinit();

    var ok = try static_files.app.handle(Request.init(.GET, "/app.js"));
    defer ok.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, ok.status);
    try testing.expectEqualStrings("text/javascript; charset=utf-8", ok.header("content-type").?);
    try testing.expectEqualStrings("20", ok.header("content-length").?);
    try testing.expectEqualStrings("console.log('zapi');", ok.body.items);

    var encoded_space = try static_files.app.handle(Request.init(.GET, "/space%20file.txt"));
    defer encoded_space.deinit(testing.allocator);
    try testing.expectEqual(Status.ok, encoded_space.status);
    try testing.expectEqualStrings("space", encoded_space.body.items);

    const rejected_paths = [_][]const u8{
        "/missing.js",
        "/../secret.txt",
        "/%2e%2e/secret.txt",
        "/app%00.js",
        "/bad%ZZ.js",
        "/assets//site.css",
        "/./app.js",
        "/assets\\site.css",
    };

    for (rejected_paths) |path| {
        var response = try static_files.app.handle(Request.init(.GET, path));
        defer response.deinit(testing.allocator);
        try testing.expectEqual(Status.not_found, response.status);
        try testing.expectEqualStrings("Not Found", response.body.items);
    }
}

test {
    _ = core;
}
