//! Static-file path validation, ranges, validators, and response metadata.
//! Filesystem dispatch belongs to the parent static-file application.

const std = @import("std");
const header_utils = @import("../headers.zig");
const http = @import("../http.zig");
const http_dates = @import("../http_dates.zig");

/// The browser disposition for a downloaded file.
pub const ContentDisposition = enum {
    attachment,
    @"inline",

    pub fn text(self: ContentDisposition) []const u8 {
        return switch (self) {
            .attachment => "attachment",
            .@"inline" => "inline",
        };
    }
};

const HeaderField = http.HeaderField;
const Status = http.Status;
const appendOwnedHeader = header_utils.appendOwned;
const freeHeaderItemsAndSlice = header_utils.freeItemsAndSlice;

pub const StaticPath = struct {
    value: []const u8,
    owned: bool = false,
};

pub const ByteRange = struct {
    start: usize,
    end: usize,

    pub fn len(self: ByteRange) usize {
        return self.end - self.start + 1;
    }
};

pub const ByteRangeDecision = union(enum) {
    none,
    partial: ByteRange,
    multiple: []const ByteRange,
    unsatisfiable,
    malformed: []const u8,

    pub fn deinit(self: ByteRangeDecision, allocator: std.mem.Allocator) void {
        switch (self) {
            .multiple => |ranges| allocator.free(ranges),
            else => {},
        }
    }
};

pub const multipart_range_boundary = "zapi-boundary";

pub fn responseFileContentType(file_content_type: []const u8, range_decision: ByteRangeDecision) []const u8 {
    return switch (range_decision) {
        .multiple => multipartByteRangesContentType(),
        else => file_content_type,
    };
}

pub fn multipartByteRangesContentType() []const u8 {
    return "multipart/byteranges; boundary=" ++ multipart_range_boundary;
}

fn headerValue(values: []const HeaderField, name: []const u8) ?[]const u8 {
    for (values) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) return header.value;
    }
    return null;
}

pub fn responseFileHeaders(allocator: std.mem.Allocator, source_headers: []const HeaderField, body_len: usize, full_len: usize, etag: []const u8, last_modified: []const u8, filename: ?[]const u8, content_disposition: ContentDisposition, status: Status, range_decision: ByteRangeDecision) ![]HeaderField {
    if (filename) |value| {
        if (std.mem.indexOfAny(u8, value, "\r\n") != null) return error.InvalidHeader;
    }

    const not_modified = status == .not_modified;
    const range_response = status == .partial_content or status == .requested_range_not_satisfiable;
    const content_range_header = switch (range_decision) {
        .partial, .unsatisfiable => true,
        else => false,
    };
    const generated_accept_ranges = headerValue(source_headers, "accept-ranges") == null;
    const generated_content_disposition = filename != null and !not_modified and headerValue(source_headers, "content-disposition") == null;

    var skipped: usize = 0;
    for (source_headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "content-length")) {
            skipped += 1;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(header.name, "etag")) {
            skipped += 1;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(header.name, "last-modified")) {
            skipped += 1;
            continue;
        }
        if (generated_accept_ranges and std.ascii.eqlIgnoreCase(header.name, "accept-ranges")) {
            skipped += 1;
            continue;
        }
        if (range_response and std.ascii.eqlIgnoreCase(header.name, "content-range")) {
            skipped += 1;
            continue;
        }
        if ((generated_content_disposition or not_modified) and std.ascii.eqlIgnoreCase(header.name, "content-disposition")) {
            skipped += 1;
            continue;
        }
    }

    const extra_count: usize = 2 +
        (if (generated_accept_ranges) @as(usize, 1) else 0) +
        (if (!not_modified) @as(usize, 1) else 0) +
        (if (content_range_header) @as(usize, 1) else 0) +
        (if (generated_content_disposition) @as(usize, 1) else 0);
    var headers = try allocator.alloc(HeaderField, source_headers.len - skipped + extra_count);

    var i: usize = 0;
    errdefer freeOwnedHeaders(allocator, headers[0..i]);

    for (source_headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "content-length")) continue;
        if (std.ascii.eqlIgnoreCase(header.name, "etag")) continue;
        if (std.ascii.eqlIgnoreCase(header.name, "last-modified")) continue;
        if (generated_accept_ranges and std.ascii.eqlIgnoreCase(header.name, "accept-ranges")) continue;
        if (range_response and std.ascii.eqlIgnoreCase(header.name, "content-range")) continue;
        if ((generated_content_disposition or not_modified) and std.ascii.eqlIgnoreCase(header.name, "content-disposition")) continue;
        const owned_name = try allocator.dupe(u8, header.name);
        const owned_value = allocator.dupe(u8, header.value) catch |err| {
            allocator.free(owned_name);
            return err;
        };
        headers[i] = .{
            .name = owned_name,
            .value = owned_value,
        };
        i += 1;
    }

    if (!not_modified) {
        const content_length_name = try allocator.dupe(u8, "content-length");
        const content_length_value = std.fmt.allocPrint(allocator, "{d}", .{body_len}) catch |err| {
            allocator.free(content_length_name);
            return err;
        };
        headers[i] = .{
            .name = content_length_name,
            .value = content_length_value,
        };
        i += 1;
    }

    const etag_name = try allocator.dupe(u8, "etag");
    const etag_value = allocator.dupe(u8, etag) catch |err| {
        allocator.free(etag_name);
        return err;
    };
    headers[i] = .{
        .name = etag_name,
        .value = etag_value,
    };
    i += 1;

    if (generated_accept_ranges) {
        const accept_ranges_name = try allocator.dupe(u8, "accept-ranges");
        const accept_ranges_value = allocator.dupe(u8, "bytes") catch |err| {
            allocator.free(accept_ranges_name);
            return err;
        };
        headers[i] = .{
            .name = accept_ranges_name,
            .value = accept_ranges_value,
        };
        i += 1;
    }

    switch (range_decision) {
        .none => {},
        .malformed => unreachable,
        .multiple => {},
        .partial => |range| {
            const content_range_name = try allocator.dupe(u8, "content-range");
            const content_range_value = std.fmt.allocPrint(allocator, "bytes {d}-{d}/{d}", .{ range.start, range.end, full_len }) catch |err| {
                allocator.free(content_range_name);
                return err;
            };
            headers[i] = .{
                .name = content_range_name,
                .value = content_range_value,
            };
            i += 1;
        },
        .unsatisfiable => {
            const content_range_name = try allocator.dupe(u8, "content-range");
            const content_range_value = std.fmt.allocPrint(allocator, "bytes */{d}", .{full_len}) catch |err| {
                allocator.free(content_range_name);
                return err;
            };
            headers[i] = .{
                .name = content_range_name,
                .value = content_range_value,
            };
            i += 1;
        },
    }

    const last_modified_name = try allocator.dupe(u8, "last-modified");
    const last_modified_value = allocator.dupe(u8, last_modified) catch |err| {
        allocator.free(last_modified_name);
        return err;
    };
    headers[i] = .{
        .name = last_modified_name,
        .value = last_modified_value,
    };
    i += 1;

    if (filename) |value| if (generated_content_disposition) {
        const disposition_name = try allocator.dupe(u8, "content-disposition");
        const disposition_value = fileContentDispositionAlloc(allocator, value, content_disposition) catch |err| {
            allocator.free(disposition_name);
            return err;
        };
        headers[i] = .{
            .name = disposition_name,
            .value = disposition_value,
        };
    };

    return headers;
}

pub fn fileContentDispositionAlloc(allocator: std.mem.Allocator, filename: []const u8, disposition: ContentDisposition) ![]u8 {
    if (quotedFilenameSafe(filename)) {
        return std.fmt.allocPrint(allocator, "{s}; filename=\"{s}\"", .{ disposition.text(), filename });
    }

    const encoded = try percentEncodeFilenameAlloc(allocator, filename);
    defer allocator.free(encoded);
    return std.fmt.allocPrint(allocator, "{s}; filename*=utf-8''{s}", .{ disposition.text(), encoded });
}

pub fn quotedFilenameSafe(filename: []const u8) bool {
    if (filename.len == 0) return true;
    for (filename) |byte| {
        if (byte < 0x20 or byte >= 0x7f) return false;
        if (byte == '"' or byte == '\\') return false;
    }
    return true;
}

pub fn percentEncodeFilenameAlloc(allocator: std.mem.Allocator, filename: []const u8) ![]u8 {
    var writer = std.Io.Writer.Allocating.init(allocator);
    errdefer writer.deinit();
    const hex = "0123456789ABCDEF";
    for (filename) |byte| {
        if (filenameAttrChar(byte)) {
            try writer.writer.writeByte(byte);
        } else {
            try writer.writer.writeByte('%');
            try writer.writer.writeByte(hex[byte >> 4]);
            try writer.writer.writeByte(hex[byte & 0x0f]);
        }
    }
    return writer.toOwnedSlice();
}

pub fn filenameAttrChar(byte: u8) bool {
    return switch (byte) {
        'a'...'z', 'A'...'Z', '0'...'9', '!', '#', '$', '&', '+', '-', '.', '^', '_', '`', '|', '~' => true,
        else => false,
    };
}

pub fn statFileSize(stat: std.Io.Dir.Stat) !usize {
    return std.math.cast(usize, stat.size) orelse error.FileTooBig;
}

pub fn fileResponseEtag(allocator: std.mem.Allocator, stat: std.Io.Dir.Stat) ![]u8 {
    return std.fmt.allocPrint(allocator, "\"{d}-{d}\"", .{ stat.mtime.nanoseconds, stat.size });
}

pub fn requestEtagMatches(request: anytype, etag: []const u8) bool {
    const header = request.header("if-none-match") orelse return false;
    var it = std.mem.splitScalar(u8, header, ',');
    while (it.next()) |raw_value| {
        const value = std.mem.trim(u8, raw_value, " \t");
        if (std.mem.eql(u8, value, "*")) return true;
        if (etagWeakEquals(value, etag)) return true;
    }
    return false;
}

pub fn etagWeakEquals(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, weakEtagValue(a), weakEtagValue(b));
}

pub fn weakEtagValue(value: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, value, " \t");
    if (trimmed.len >= 2 and (trimmed[0] == 'W' or trimmed[0] == 'w') and trimmed[1] == '/') {
        return std.mem.trim(u8, trimmed[2..], " \t");
    }
    return trimmed;
}

pub fn requestNotModified(request: anytype, etag: []const u8, last_modified_seconds: i64) bool {
    return requestValidatorsNotModified(request, etag, last_modified_seconds);
}

pub fn requestValidatorsNotModified(request: anytype, etag: ?[]const u8, last_modified_seconds: ?i64) bool {
    if (request.header("if-none-match") != null) {
        const value = etag orelse return false;
        return requestEtagMatches(request, value);
    }

    return requestModifiedSince(request, last_modified_seconds orelse return false);
}

pub fn requestModifiedSince(request: anytype, last_modified_seconds: i64) bool {
    const header = request.header("if-modified-since") orelse return false;
    const modified_since_seconds = parseHttpDate(header) orelse return false;
    return modified_since_seconds >= last_modified_seconds;
}

pub fn requestByteRange(allocator: std.mem.Allocator, request: anytype, etag: []const u8, last_modified_seconds: i64, full_len: usize) !ByteRangeDecision {
    const header = request.header("range") orelse return .none;
    if (request.header("if-range")) |if_range| {
        const trimmed = std.mem.trim(u8, if_range, " \t");
        if (std.mem.startsWith(u8, trimmed, "\"")) {
            if (!std.mem.eql(u8, trimmed, etag)) return .none;
        } else if (parseHttpDate(trimmed)) |seconds| {
            if (seconds < last_modified_seconds) return .none;
        } else {
            return .none;
        }
    }

    return parseByteRange(allocator, header, full_len);
}

pub fn parseByteRange(allocator: std.mem.Allocator, header: []const u8, full_len: usize) !ByteRangeDecision {
    const value = std.mem.trim(u8, header, " \t");
    const equals = std.mem.indexOfScalar(u8, value, '=') orelse return .{ .malformed = "Malformed range header." };
    const units = std.mem.trim(u8, value[0..equals], " \t");
    if (!std.ascii.eqlIgnoreCase(units, "bytes")) return .{ .malformed = "Only support bytes range" };

    const spec = std.mem.trim(u8, value[equals + 1 ..], " \t");
    var ranges: std.ArrayList(ByteRange) = .empty;
    defer ranges.deinit(allocator);

    var it = std.mem.splitScalar(u8, spec, ',');
    while (it.next()) |raw_part| {
        const part = std.mem.trim(u8, raw_part, " \t");
        if (part.len == 0 or std.mem.eql(u8, part, "-")) continue;
        const dash = std.mem.indexOfScalar(u8, part, '-') orelse continue;
        const start_text = std.mem.trim(u8, part[0..dash], " \t");
        const end_text = std.mem.trim(u8, part[dash + 1 ..], " \t");
        if (start_text.len == 0 and end_text.len == 0) continue;

        const range = parseByteRangePart(start_text, end_text, full_len) catch continue;
        try ranges.append(allocator, range);
    }

    if (ranges.items.len == 0) return .{ .malformed = "Range header: range must be requested" };
    if (full_len == 0) return .unsatisfiable;

    for (ranges.items) |range| {
        if (range.start >= full_len) return .unsatisfiable;
        if (range.start > range.end) return .{ .malformed = "Range header: start must be less than end" };
    }

    normalizeByteRanges(ranges.items);
    const merged_len = mergeByteRanges(ranges.items);
    if (merged_len == 1) return .{ .partial = ranges.items[0] };

    const owned_ranges = try allocator.dupe(ByteRange, ranges.items[0..merged_len]);
    return .{ .multiple = owned_ranges };
}

pub fn parseByteRangePart(start_text: []const u8, end_text: []const u8, full_len: usize) !ByteRange {
    if (start_text.len == 0) {
        const suffix_len = try std.fmt.parseInt(usize, end_text, 10);
        if (full_len == 0) return .{ .start = 0, .end = 0 };
        if (suffix_len == 0) return .{ .start = full_len, .end = full_len };
        const start = if (suffix_len >= full_len) 0 else full_len - suffix_len;
        return .{ .start = start, .end = full_len - 1 };
    }

    const start = try std.fmt.parseInt(usize, start_text, 10);
    if (full_len == 0) {
        const parsed_end = if (end_text.len == 0) start else try std.fmt.parseInt(usize, end_text, 10);
        return .{ .start = start, .end = parsed_end };
    }
    const parsed_end = if (end_text.len == 0) full_len - 1 else try std.fmt.parseInt(usize, end_text, 10);
    const end = if (parsed_end >= full_len) full_len - 1 else parsed_end;
    return .{ .start = start, .end = end };
}

pub fn byteRangeLessThan(_: void, a: ByteRange, b: ByteRange) bool {
    if (a.start == b.start) return a.end < b.end;
    return a.start < b.start;
}

pub fn normalizeByteRanges(ranges: []ByteRange) void {
    std.mem.sort(ByteRange, ranges, {}, byteRangeLessThan);
}

pub fn mergeByteRanges(ranges: []ByteRange) usize {
    var write: usize = 1;
    for (ranges[1..]) |range| {
        const previous = &ranges[write - 1];
        if (range.start <= previous.end + 1) {
            previous.end = @max(previous.end, range.end);
            continue;
        }
        ranges[write] = range;
        write += 1;
    }
    return write;
}

pub fn applyByteRange(allocator: std.mem.Allocator, body: []u8, decision: ByteRangeDecision) ![]u8 {
    switch (decision) {
        .none => return body,
        .malformed => unreachable,
        .multiple => unreachable,
        .unsatisfiable => {
            allocator.free(body);
            return allocator.dupe(u8, "");
        },
        .partial => |range| {
            const range_body = try allocator.dupe(u8, body[range.start .. range.end + 1]);
            allocator.free(body);
            return range_body;
        },
    }
}

pub fn multipartByteRangesLength(ranges: []const ByteRange, boundary: []const u8, content_type: []const u8, full_len: usize) usize {
    var len: usize = 0;
    for (ranges) |range| {
        len += std.fmt.count(
            "--{s}\r\nContent-Type: {s}\r\nContent-Range: bytes {d}-{d}/{d}\r\n\r\n",
            .{ boundary, content_type, range.start, range.end, full_len },
        );
        len += range.len();
        len += "\r\n".len;
    }
    len += std.fmt.count("--{s}--", .{boundary});
    return len;
}

pub fn multipartByteRangesBodyAlloc(allocator: std.mem.Allocator, body: []const u8, ranges: []const ByteRange, boundary: []const u8, content_type: []const u8, full_len: usize) ![]u8 {
    var writer = std.Io.Writer.Allocating.init(allocator);
    errdefer writer.deinit();

    for (ranges) |range| {
        try writer.writer.print(
            "--{s}\r\nContent-Type: {s}\r\nContent-Range: bytes {d}-{d}/{d}\r\n\r\n",
            .{ boundary, content_type, range.start, range.end, full_len },
        );
        try writer.writer.writeAll(body[range.start .. range.end + 1]);
        try writer.writer.writeAll("\r\n");
    }
    try writer.writer.print("--{s}--", .{boundary});
    return writer.toOwnedSlice();
}

pub const timestampSeconds = http_dates.timestampSeconds;
pub const httpDateAlloc = http_dates.format;
pub const parseHttpDate = http_dates.parse;

pub fn freeOwnedHeaders(allocator: std.mem.Allocator, headers: []const HeaderField) void {
    for (headers) |header| {
        allocator.free(header.name);
        allocator.free(header.value);
    }
    allocator.free(headers);
}

fn percentDecodePath(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var index: usize = 0;
    while (index < input.len) {
        if (input[index] != '%') {
            try out.append(allocator, input[index]);
            index += 1;
            continue;
        }
        if (index + 2 >= input.len) return error.Validation;
        const byte = std.fmt.parseInt(u8, input[index + 1 .. index + 3], 16) catch return error.Validation;
        try out.append(allocator, byte);
        index += 3;
    }
    return out.toOwnedSlice(allocator);
}

pub fn staticFileTargetPath(allocator: std.mem.Allocator, raw_path: []const u8, html: bool) !StaticPath {
    if (raw_path.len == 0) {
        if (!html) return error.InvalidStaticPath;
        return .{ .value = "index.html" };
    }

    const decoded_path = percentDecodePath(allocator, raw_path) catch return error.InvalidStaticPath;
    errdefer allocator.free(decoded_path);

    if (std.fs.path.isAbsolute(decoded_path)) return error.InvalidStaticPath;
    if (std.mem.indexOfScalar(u8, decoded_path, 0) != null) return error.InvalidStaticPath;
    if (std.mem.indexOfScalar(u8, decoded_path, '\\') != null) return error.InvalidStaticPath;

    const lookup_path = if (std.mem.endsWith(u8, decoded_path, "/")) blk: {
        if (!html) return error.InvalidStaticPath;
        break :blk decoded_path[0 .. decoded_path.len - 1];
    } else decoded_path;
    try validateStaticPathSegments(lookup_path);

    if (std.mem.endsWith(u8, decoded_path, "/")) {
        defer allocator.free(decoded_path);
        return .{
            .value = try std.fmt.allocPrint(allocator, "{s}/index.html", .{lookup_path}),
            .owned = true,
        };
    }

    return .{ .value = decoded_path, .owned = true };
}

pub fn validateStaticPathSegments(path: []const u8) !void {
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |segment| {
        if (segment.len == 0) return error.InvalidStaticPath;
        if (std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return error.InvalidStaticPath;
    }
}

pub fn staticContentType(path: []const u8) []const u8 {
    const ext = std.fs.path.extension(path);
    if (std.ascii.eqlIgnoreCase(ext, ".html") or std.ascii.eqlIgnoreCase(ext, ".htm")) return "text/html; charset=utf-8";
    if (std.ascii.eqlIgnoreCase(ext, ".css")) return "text/css; charset=utf-8";
    if (std.ascii.eqlIgnoreCase(ext, ".js") or std.ascii.eqlIgnoreCase(ext, ".mjs")) return "text/javascript; charset=utf-8";
    if (std.ascii.eqlIgnoreCase(ext, ".json")) return "application/json";
    if (std.ascii.eqlIgnoreCase(ext, ".txt")) return "text/plain; charset=utf-8";
    if (std.ascii.eqlIgnoreCase(ext, ".png")) return "image/png";
    if (std.ascii.eqlIgnoreCase(ext, ".jpg") or std.ascii.eqlIgnoreCase(ext, ".jpeg")) return "image/jpeg";
    if (std.ascii.eqlIgnoreCase(ext, ".gif")) return "image/gif";
    if (std.ascii.eqlIgnoreCase(ext, ".svg")) return "image/svg+xml";
    if (std.ascii.eqlIgnoreCase(ext, ".webp")) return "image/webp";
    if (std.ascii.eqlIgnoreCase(ext, ".ico")) return "image/x-icon";
    if (std.ascii.eqlIgnoreCase(ext, ".wasm")) return "application/wasm";
    if (std.ascii.eqlIgnoreCase(ext, ".pdf")) return "application/pdf";
    return "application/octet-stream";
}
