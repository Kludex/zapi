//! Owned HTTP header utilities shared by responses and adapters.
//! Header names and values are validated before ownership is transferred.

const std = @import("std");
const http = @import("http.zig");

const HeaderField = http.HeaderField;

/// Duplicates and validates one header field.
pub fn owned(allocator: std.mem.Allocator, name: []const u8, value: []const u8) !HeaderField {
    try http.validateHeader(name, value);
    const owned_name = try allocator.dupe(u8, name);
    errdefer allocator.free(owned_name);
    const owned_value = try allocator.dupe(u8, value);
    return .{ .name = owned_name, .value = owned_value };
}

/// Creates an owned Location header with unsafe bytes percent-encoded.
pub fn ownedRedirectLocation(allocator: std.mem.Allocator, location: []const u8) !HeaderField {
    const owned_name = try allocator.dupe(u8, "location");
    errdefer allocator.free(owned_name);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    const hex = "0123456789ABCDEF";
    for (location) |ch| {
        if (redirectLocationByteSafe(ch)) {
            try out.append(allocator, ch);
        } else {
            try out.append(allocator, '%');
            try out.append(allocator, hex[ch >> 4]);
            try out.append(allocator, hex[ch & 0x0f]);
        }
    }
    return .{ .name = owned_name, .value = try out.toOwnedSlice(allocator) };
}

/// Frees initialized entries and their containing slice.
pub fn freeItemsAndSlice(allocator: std.mem.Allocator, values: []HeaderField, initialized: usize) void {
    for (values[0..initialized]) |header| {
        allocator.free(header.name);
        allocator.free(header.value);
    }
    allocator.free(values);
}

/// Appends a validated, owned header field.
pub fn appendOwned(
    allocator: std.mem.Allocator,
    values: *std.ArrayList(HeaderField),
    name: []const u8,
    value: []const u8,
) !void {
    const header = try owned(allocator, name, value);
    errdefer {
        allocator.free(header.name);
        allocator.free(header.value);
    }
    try values.append(allocator, header);
}

fn redirectLocationByteSafe(ch: u8) bool {
    if (std.ascii.isAlphanumeric(ch)) return true;
    return switch (ch) {
        '-', '.', '_', '~', ':', '/', '%', '#', '?', '=', '@', '[', ']', '!', '$', '&', '\'', '(', ')', '*', '+', ',', ';' => true,
        else => false,
    };
}

/// Frees all owned header fields while retaining list capacity.
pub fn clearOwned(allocator: std.mem.Allocator, values: *std.ArrayList(HeaderField)) void {
    for (values.items) |header| {
        allocator.free(header.name);
        allocator.free(header.value);
    }
    values.clearRetainingCapacity();
}
