//! Validated scalar values used by request parsing and OpenAPI schemas.
//! Values are stored inline and do not allocate after parsing.

const std = @import("std");

/// A canonical textual UUID.
pub const Uuid = struct {
    value: [36]u8,

    /// Validates and copies a UUID.
    pub fn parse(raw: []const u8) !Uuid {
        if (!isUuid(raw)) return error.Validation;
        var value: [36]u8 = undefined;
        @memcpy(value[0..], raw);
        return .{ .value = value };
    }

    /// Returns the UUID text owned by this value.
    pub fn text(self: *const Uuid) []const u8 {
        return self.value[0..];
    }

    /// Parses a UUID through `std.json`.
    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !Uuid {
        const raw = try std.json.innerParse([]const u8, allocator, source, options);
        return parse(raw) catch return error.UnexpectedToken;
    }

    /// Serializes a UUID through `std.json`.
    pub fn jsonStringify(self: Uuid, jws: anytype) !void {
        try jws.write(self.value[0..]);
    }
};

/// An RFC 3339 full-date value.
pub const Date = struct {
    value: [10]u8,

    /// Validates and copies a date.
    pub fn parse(raw: []const u8) !Date {
        if (!isDate(raw)) return error.Validation;
        var value: [10]u8 = undefined;
        @memcpy(value[0..], raw);
        return .{ .value = value };
    }

    /// Returns the date text owned by this value.
    pub fn text(self: *const Date) []const u8 {
        return self.value[0..];
    }

    /// Parses a date through `std.json`.
    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !Date {
        const raw = try std.json.innerParse([]const u8, allocator, source, options);
        return parse(raw) catch return error.UnexpectedToken;
    }

    /// Serializes a date through `std.json`.
    pub fn jsonStringify(self: Date, jws: anytype) !void {
        try jws.write(self.value[0..]);
    }
};

/// An RFC 3339 date-time value up to 64 bytes.
pub const DateTime = struct {
    value: [64]u8,
    len: usize,

    /// Validates and copies a date-time.
    pub fn parse(raw: []const u8) !DateTime {
        if (!isDateTime(raw)) return error.Validation;
        var value: [64]u8 = undefined;
        @memcpy(value[0..raw.len], raw);
        return .{ .value = value, .len = raw.len };
    }

    /// Returns the date-time text owned by this value.
    pub fn text(self: *const DateTime) []const u8 {
        return self.value[0..self.len];
    }

    /// Parses a date-time through `std.json`.
    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !DateTime {
        const raw = try std.json.innerParse([]const u8, allocator, source, options);
        return parse(raw) catch return error.UnexpectedToken;
    }

    /// Serializes a date-time through `std.json`.
    pub fn jsonStringify(self: DateTime, jws: anytype) !void {
        try jws.write(self.value[0..self.len]);
    }
};

/// A validated email address up to 320 bytes.
pub const Email = struct {
    value: [320]u8,
    len: usize,

    /// Validates and copies an email address.
    pub fn parse(raw: []const u8) !Email {
        if (!isEmail(raw)) return error.Validation;
        var value: [320]u8 = undefined;
        @memcpy(value[0..raw.len], raw);
        return .{ .value = value, .len = raw.len };
    }

    /// Returns the email text owned by this value.
    pub fn text(self: *const Email) []const u8 {
        return self.value[0..self.len];
    }

    /// Parses an email address through `std.json`.
    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !Email {
        const raw = try std.json.innerParse([]const u8, allocator, source, options);
        return parse(raw) catch return error.UnexpectedToken;
    }

    /// Serializes an email address through `std.json`.
    pub fn jsonStringify(self: Email, jws: anytype) !void {
        try jws.write(self.value[0..self.len]);
    }
};

/// A validated URI up to 2048 bytes.
pub const Url = struct {
    value: [2048]u8,
    len: usize,

    /// Validates and copies a URI.
    pub fn parse(raw: []const u8) !Url {
        if (!isUrl(raw)) return error.Validation;
        var value: [2048]u8 = undefined;
        @memcpy(value[0..raw.len], raw);
        return .{ .value = value, .len = raw.len };
    }

    /// Returns the URI text owned by this value.
    pub fn text(self: *const Url) []const u8 {
        return self.value[0..self.len];
    }

    /// Parses a URI through `std.json`.
    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !Url {
        const raw = try std.json.innerParse([]const u8, allocator, source, options);
        return parse(raw) catch return error.UnexpectedToken;
    }

    /// Serializes a URI through `std.json`.
    pub fn jsonStringify(self: Url, jws: anytype) !void {
        try jws.write(self.value[0..self.len]);
    }
};

fn isUuid(value: []const u8) bool {
    if (value.len != 36) return false;
    for (value, 0..) |ch, i| {
        switch (i) {
            8, 13, 18, 23 => if (ch != '-') return false,
            else => if (!std.ascii.isHex(ch)) return false,
        }
    }
    return true;
}

fn isDate(value: []const u8) bool {
    if (value.len != 10) return false;
    if (value[4] != '-' or value[7] != '-') return false;
    const year = parseFixedDigits(value[0..4]) orelse return false;
    const month = parseFixedDigits(value[5..7]) orelse return false;
    const day = parseFixedDigits(value[8..10]) orelse return false;
    return validDateParts(year, month, day);
}

fn isDateTime(value: []const u8) bool {
    if (value.len < 20 or value.len > 64) return false;
    if (!isDate(value[0..10])) return false;
    if (value[10] != 'T' and value[10] != 't') return false;
    if (value[13] != ':' or value[16] != ':') return false;

    const hour = parseFixedDigits(value[11..13]) orelse return false;
    const minute = parseFixedDigits(value[14..16]) orelse return false;
    const second = parseFixedDigits(value[17..19]) orelse return false;
    if (hour > 23 or minute > 59 or second > 59) return false;

    var index: usize = 19;
    if (index < value.len and value[index] == '.') {
        index += 1;
        const fraction_start = index;
        while (index < value.len and std.ascii.isDigit(value[index])) : (index += 1) {}
        if (index == fraction_start) return false;
    }
    if (index >= value.len) return false;

    if (value[index] == 'Z' or value[index] == 'z') return index + 1 == value.len;
    if (value[index] != '+' and value[index] != '-') return false;
    if (index + 6 != value.len) return false;
    if (value[index + 3] != ':') return false;

    const offset_hour = parseFixedDigits(value[index + 1 .. index + 3]) orelse return false;
    const offset_minute = parseFixedDigits(value[index + 4 .. index + 6]) orelse return false;
    return offset_hour <= 23 and offset_minute <= 59;
}

fn parseFixedDigits(value: []const u8) ?u16 {
    var result: u16 = 0;
    for (value) |ch| {
        if (!std.ascii.isDigit(ch)) return null;
        result = result * 10 + @as(u16, ch - '0');
    }
    return result;
}

fn validDateParts(year: u16, month: u16, day: u16) bool {
    if (year == 0 or month < 1 or month > 12 or day < 1) return false;
    return day <= daysInMonth(year, month);
}

fn daysInMonth(year: u16, month: u16) u16 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (isLeapYear(year)) 29 else 28,
        else => 0,
    };
}

fn isLeapYear(year: u16) bool {
    return year % 4 == 0 and (year % 100 != 0 or year % 400 == 0);
}

fn isEmail(value: []const u8) bool {
    if (value.len < 3 or value.len > 320) return false;
    if (std.mem.indexOfAny(u8, value, " \t\r\n") != null) return false;

    const at = std.mem.indexOfScalar(u8, value, '@') orelse return false;
    if (at == 0 or at + 1 >= value.len) return false;
    if (std.mem.indexOfScalarPos(u8, value, at + 1, '@') != null) return false;

    const local = value[0..at];
    const domain = value[at + 1 ..];
    if (local.len > 64 or domain.len > 255) return false;
    if (local[0] == '.' or local[local.len - 1] == '.') return false;
    if (std.mem.indexOf(u8, local, "..") != null) return false;
    for (local) |ch| {
        if (ch < 0x21 or ch > 0x7e or ch == '"' or ch == '(' or ch == ')' or ch == ',' or ch == ':' or ch == ';' or
            ch == '<' or ch == '>' or ch == '[' or ch == ']' or ch == '\\') return false;
    }

    return validEmailDomain(domain);
}

fn validEmailDomain(domain: []const u8) bool {
    if (domain.len == 0 or domain[0] == '.' or domain[domain.len - 1] == '.') return false;
    if (std.mem.indexOfScalar(u8, domain, '.') == null) return false;

    var it = std.mem.splitScalar(u8, domain, '.');
    while (it.next()) |label| {
        if (label.len == 0 or label.len > 63) return false;
        if (label[0] == '-' or label[label.len - 1] == '-') return false;
        for (label) |ch| {
            if (!std.ascii.isAlphanumeric(ch) and ch != '-') return false;
        }
    }
    return true;
}

fn isUrl(value: []const u8) bool {
    if (value.len == 0 or value.len > 2048) return false;
    for (value) |ch| {
        if (ch <= 0x20 or ch == 0x7f) return false;
    }

    const uri = std.Uri.parse(value) catch return false;
    if (uri.scheme.len == 0) return false;
    if (std.ascii.eqlIgnoreCase(uri.scheme, "http") or std.ascii.eqlIgnoreCase(uri.scheme, "https")) {
        const host = uri.host orelse return false;
        if (host.isEmpty()) return false;
    }
    return true;
}
