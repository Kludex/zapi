//! Cookie parsing and Set-Cookie serialization.
//! Parsed values are copied into caller-owned collections.

const std = @import("std");
const datastructures = @import("datastructures.zig");
const http = @import("http.zig");
const http_dates = @import("http_dates.zig");
const sessions = @import("sessions.zig");

const CookieOptions = sessions.CookieOptions;
const CookieParams = datastructures.CookieParams;
const HeaderField = http.HeaderField;

pub const ParsedSetCookie = struct {
    name: []const u8,
    value: []const u8,
    pair_end: usize,
};

pub fn parseSetCookiePair(header_value: []const u8) ?ParsedSetCookie {
    const pair_end = std.mem.indexOfScalar(u8, header_value, ';') orelse header_value.len;
    const pair = std.mem.trim(u8, header_value[0..pair_end], " \t");
    const eq_idx = std.mem.indexOfScalar(u8, pair, '=') orelse return null;
    const name = std.mem.trim(u8, pair[0..eq_idx], " \t");
    const value = std.mem.trim(u8, pair[eq_idx + 1 ..], " \t");
    if (name.len == 0) return null;
    return .{
        .name = name,
        .value = value,
        .pair_end = pair_end,
    };
}

pub fn parseSetCookieInto(header_value: []const u8, params: *CookieParams) !void {
    const parsed = parseSetCookiePair(header_value) orelse return;
    if (setCookieDeletes(header_value[parsed.pair_end..])) {
        params.remove(parsed.name);
        return;
    }
    try params.put(parsed.name, parsed.value);
}

pub fn setCookieAttribute(attributes: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, attributes, ';');
    while (it.next()) |raw_attribute| {
        const attribute = std.mem.trim(u8, raw_attribute, " \t");
        if (attribute.len == 0) continue;
        const eq_idx = std.mem.indexOfScalar(u8, attribute, '=') orelse continue;
        const attribute_name = std.mem.trim(u8, attribute[0..eq_idx], " \t");
        if (!std.ascii.eqlIgnoreCase(attribute_name, name)) continue;
        return std.mem.trim(u8, attribute[eq_idx + 1 ..], " \t");
    }
    return null;
}

pub fn setCookieAttributePresent(attributes: []const u8, name: []const u8) bool {
    var it = std.mem.splitScalar(u8, attributes, ';');
    while (it.next()) |raw_attribute| {
        const attribute = std.mem.trim(u8, raw_attribute, " \t");
        if (attribute.len == 0) continue;
        const attribute_name = if (std.mem.indexOfScalar(u8, attribute, '=')) |eq_idx|
            std.mem.trim(u8, attribute[0..eq_idx], " \t")
        else
            attribute;
        if (std.ascii.eqlIgnoreCase(attribute_name, name)) return true;
    }
    return false;
}

pub fn setCookieDeletes(attributes: []const u8) bool {
    if (setCookieAttribute(attributes, "max-age")) |raw_max_age| {
        const value = std.fmt.parseInt(i64, raw_max_age, 10) catch return false;
        return value <= 0;
    }

    if (setCookieAttribute(attributes, "expires")) |raw_expires| {
        return cookieExpiresInPast(raw_expires);
    }

    return false;
}

pub fn cookieExpiresInPast(raw_expires: []const u8) bool {
    const expires = std.mem.trim(u8, raw_expires, " \t");
    if (http_dates.parse(expires)) |seconds| {
        return seconds <= 0;
    }

    if (expires.len == 29) {
        const year = std.fmt.parseInt(i64, expires[12..16], 10) catch return false;
        if (year < std.time.epoch.epoch_year) return true;
    }

    return false;
}

pub fn optionalEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

pub fn normalizeCookieDomain(domain: []const u8) []const u8 {
    var trimmed = std.mem.trim(u8, domain, " \t");
    while (trimmed.len > 0 and trimmed[0] == '.') trimmed = trimmed[1..];
    return cookieHostName(trimmed);
}

pub fn cookieHostName(host: []const u8) []const u8 {
    const value = std.mem.trim(u8, host, " \t");
    if (value.len == 0) return value;
    if (value[0] == '[') {
        const end = std.mem.indexOfScalar(u8, value, ']') orelse return value;
        return value[0 .. end + 1];
    }
    const colon = std.mem.indexOfScalar(u8, value, ':') orelse value.len;
    return value[0..colon];
}

pub fn defaultCookiePath(request_path: []const u8) []const u8 {
    if (request_path.len == 0 or request_path[0] != '/') return "/";
    const last_slash = std.mem.lastIndexOfScalar(u8, request_path, '/') orelse return "/";
    if (last_slash == 0) return "/";
    return request_path[0..last_slash];
}

pub fn cookieEntryMatches(entry: anytype, host: ?[]const u8, path: []const u8, scheme: []const u8) bool {
    if (entry.secure and !std.ascii.eqlIgnoreCase(scheme, "https")) return false;

    if (entry.domain) |domain| {
        const request_host = host orelse return false;
        const normalized_host = cookieHostName(request_host);
        if (entry.host_only) {
            if (!std.ascii.eqlIgnoreCase(normalized_host, domain)) return false;
        } else if (!cookieDomainMatchesRequestHost(normalized_host, domain)) {
            return false;
        }
    }

    if (entry.path) |cookie_path| {
        if (!cookiePathMatches(path, cookie_path)) return false;
    }

    return true;
}

pub fn cookieDomainMatches(host: []const u8, domain: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(host, domain)) return true;
    if (host.len <= domain.len) return false;
    if (host[host.len - domain.len - 1] != '.') return false;
    return std.ascii.endsWithIgnoreCase(host, domain);
}

pub fn cookieDomainMatchesRequestHost(host: []const u8, domain: []const u8) bool {
    if (cookieDomainMatches(host, domain)) return true;
    if (std.mem.indexOfScalar(u8, host, '.') != null) return false;
    if (!std.ascii.endsWithIgnoreCase(domain, ".local")) return false;
    if (domain.len != host.len + ".local".len) return false;
    return std.ascii.eqlIgnoreCase(domain[0..host.len], host);
}

pub fn cookiePathMatches(request_path: []const u8, cookie_path: []const u8) bool {
    if (cookie_path.len == 0 or std.mem.eql(u8, cookie_path, "/")) return true;
    if (!std.mem.startsWith(u8, request_path, cookie_path)) return false;
    if (request_path.len == cookie_path.len) return true;
    if (cookie_path[cookie_path.len - 1] == '/') return true;
    return request_path[cookie_path.len] == '/';
}

pub fn makeSetCookieHeader(allocator: std.mem.Allocator, name: []const u8, value: []const u8, options: CookieOptions) !HeaderField {
    try validateCookieToken(name);
    try validateCookieValue(value);

    var out = std.Io.Writer.Allocating.init(allocator);
    errdefer out.deinit();

    try out.writer.writeAll(name);
    try out.writer.writeAll("=");
    try out.writer.writeAll(value);

    if (options.max_age) |max_age| try out.writer.print("; Max-Age={d}", .{max_age});
    if (options.expires) |expires| {
        try validateCookieAttributeValue(expires);
        try out.writer.writeAll("; Expires=");
        try out.writer.writeAll(expires);
    }
    if (options.path) |path| {
        try validateCookieAttributeValue(path);
        try out.writer.writeAll("; Path=");
        try out.writer.writeAll(path);
    }
    if (options.domain) |domain| {
        try validateCookieAttributeValue(domain);
        try out.writer.writeAll("; Domain=");
        try out.writer.writeAll(domain);
    }
    if (options.secure) try out.writer.writeAll("; Secure");
    if (options.http_only) try out.writer.writeAll("; HttpOnly");
    if (options.same_site) |same_site| {
        try out.writer.writeAll("; SameSite=");
        try out.writer.writeAll(same_site.text());
    }
    if (options.partitioned) try out.writer.writeAll("; Partitioned");

    const owned_name = try allocator.dupe(u8, "set-cookie");
    errdefer allocator.free(owned_name);
    const owned_value = try out.toOwnedSlice();
    return .{
        .name = owned_name,
        .value = owned_value,
    };
}

pub fn makeDeleteCookieHeader(allocator: std.mem.Allocator, name: []const u8, options: CookieOptions) !HeaderField {
    var delete_options = options;
    delete_options.max_age = 0;
    delete_options.expires = "Thu, 01 Jan 1970 00:00:00 GMT";
    return makeSetCookieHeader(allocator, name, "", delete_options);
}

pub fn validateCookieToken(value: []const u8) !void {
    if (value.len == 0) return error.InvalidCookie;
    for (value) |ch| {
        switch (ch) {
            0x21, 0x23...0x27, 0x2a...0x2b, 0x2d...0x2e, 0x30...0x39, 0x41...0x5a, 0x5e...0x7a, 0x7c, 0x7e => {},
            else => return error.InvalidCookie,
        }
    }
}

pub fn validateCookieValue(value: []const u8) !void {
    for (value) |ch| {
        switch (ch) {
            0x21, 0x23...0x2b, 0x2d...0x3a, 0x3c...0x5b, 0x5d...0x7e => {},
            else => return error.InvalidCookie,
        }
    }
}

pub fn validateCookieAttributeValue(value: []const u8) !void {
    if (std.mem.indexOfAny(u8, value, "\r\n;") != null) return error.InvalidCookie;
}
