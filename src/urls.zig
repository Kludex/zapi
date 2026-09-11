//! URL resolution used by redirects and test clients.
//! Returned strings are owned by the caller.

const std = @import("std");

pub const RedirectTarget = struct {
    path: []u8,
    scheme: ?[]const u8 = null,
    host: ?[]const u8 = null,
};

pub fn redirectTarget(allocator: std.mem.Allocator, request: anytype, location: []const u8) !RedirectTarget {
    if (std.mem.startsWith(u8, location, "http://") or std.mem.startsWith(u8, location, "https://")) {
        const scheme_end = std.mem.indexOf(u8, location, "://").?;
        const after_scheme = scheme_end + 3;
        const path_start = std.mem.indexOfAnyPos(u8, location, after_scheme, "/?") orelse location.len;
        const scheme = location[0..scheme_end];
        const host = location[after_scheme..path_start];
        if (host.len == 0) return error.InvalidUrl;

        const path = if (path_start == location.len)
            try allocator.dupe(u8, "/")
        else if (location[path_start] == '?')
            try std.fmt.allocPrint(allocator, "/{s}", .{location[path_start..]})
        else
            try normalizeRedirectTarget(allocator, location[path_start..]);
        return .{ .path = path, .scheme = scheme, .host = host };
    }

    if (std.mem.startsWith(u8, location, "//")) {
        const after_authority = 2;
        const path_start = std.mem.indexOfAnyPos(u8, location, after_authority, "/?") orelse location.len;
        const host = location[after_authority..path_start];
        if (host.len == 0) return error.InvalidUrl;

        const path = if (path_start == location.len)
            try allocator.dupe(u8, "/")
        else if (location[path_start] == '?')
            try std.fmt.allocPrint(allocator, "/{s}", .{location[path_start..]})
        else
            try normalizeRedirectTarget(allocator, location[path_start..]);
        return .{ .path = path, .host = host };
    }

    if (std.mem.startsWith(u8, location, "/")) return .{ .path = try normalizeRedirectTarget(allocator, location) };
    if (std.mem.startsWith(u8, location, "?")) return .{ .path = try std.fmt.allocPrint(allocator, "{s}{s}", .{ request.path, location }) };

    const slash = std.mem.lastIndexOfScalar(u8, request.path, '/') orelse {
        const target = try std.fmt.allocPrint(allocator, "/{s}", .{location});
        defer allocator.free(target);
        return .{ .path = try normalizeRedirectTarget(allocator, target) };
    };
    const target = try std.fmt.allocPrint(allocator, "{s}{s}", .{ request.path[0 .. slash + 1], location });
    defer allocator.free(target);
    return .{ .path = try normalizeRedirectTarget(allocator, target) };
}

pub fn normalizeRedirectTarget(allocator: std.mem.Allocator, target: []const u8) ![]u8 {
    const query_start = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
    const path = target[0..query_start];
    const query = target[query_start..];

    var segments: std.ArrayList([]const u8) = .empty;
    defer segments.deinit(allocator);

    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, ".")) continue;
        if (std.mem.eql(u8, segment, "..")) {
            if (segments.items.len > 0) _ = segments.pop();
            continue;
        }
        try segments.append(allocator, segment);
    }

    const trailing_slash = path.len > 1 and path[path.len - 1] == '/';
    var out = std.Io.Writer.Allocating.init(allocator);
    errdefer out.deinit();

    try out.writer.writeByte('/');
    for (segments.items, 0..) |segment, index| {
        if (index != 0) try out.writer.writeByte('/');
        try out.writer.writeAll(segment);
    }
    if (trailing_slash and segments.items.len > 0) try out.writer.writeByte('/');
    try out.writer.writeAll(query);
    return out.toOwnedSlice();
}

pub fn redirectNextUrl(allocator: std.mem.Allocator, base_url: []const u8, location: []const u8) ![]u8 {
    var base = BaseRequest{ .path = base_url };
    if (parseAbsolute(base_url)) |absolute| {
        base.scheme = absolute.scheme;
        base.host = absolute.host;
        base.path = absolute.path;
        base.query = absolute.query;
    }

    const target = try redirectTarget(allocator, base, location);
    defer allocator.free(target.path);

    const host = target.host orelse base.host orelse return allocator.dupe(u8, target.path);
    const scheme = target.scheme orelse base.scheme;
    return std.fmt.allocPrint(allocator, "{s}://{s}{s}", .{ scheme, host, target.path });
}

const BaseRequest = struct {
    scheme: []const u8 = "http",
    host: ?[]const u8 = null,
    path: []const u8,
    query: []const u8 = "",
};

const AbsoluteTarget = struct {
    scheme: []const u8,
    host: []const u8,
    path: []const u8,
    query: []const u8,
};

fn parseAbsolute(url: []const u8) ?AbsoluteTarget {
    const scheme_end = std.mem.indexOf(u8, url, "://") orelse return null;
    if (scheme_end == 0) return null;
    const after_scheme = scheme_end + 3;
    const path_start = std.mem.indexOfAnyPos(u8, url, after_scheme, "/?#") orelse url.len;
    const host = url[after_scheme..path_start];
    if (host.len == 0) return null;

    var path: []const u8 = "/";
    var query: []const u8 = "";
    if (path_start < url.len and url[path_start] == '/') {
        const path_end = std.mem.indexOfAnyPos(u8, url, path_start, "?#") orelse url.len;
        path = url[path_start..path_end];
        if (path_end < url.len and url[path_end] == '?') {
            const query_end = std.mem.indexOfScalarPos(u8, url, path_end + 1, '#') orelse url.len;
            query = url[path_end + 1 .. query_end];
        }
    } else if (path_start < url.len and url[path_start] == '?') {
        const query_end = std.mem.indexOfScalarPos(u8, url, path_start + 1, '#') orelse url.len;
        query = url[path_start + 1 .. query_end];
    }
    return .{ .scheme = url[0..scheme_end], .host = host, .path = path, .query = query };
}
