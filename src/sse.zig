//! Buffered Server-Sent Events encoding.
//! This module does not provide transport-level streaming.

const std = @import("std");
const http = @import("http.zig");

const HeaderField = http.HeaderField;
const Status = http.Status;

/// One Server-Sent Event.
pub const ServerSentEvent = struct {
    data: ?[]const u8 = null,
    event: ?[]const u8 = null,
    id: ?[]const u8 = null,
    retry: ?u64 = null,
    comment: ?[]const u8 = null,
};

/// Creates a data-only Server-Sent Event.
pub fn serverSentEvent(data: []const u8) ServerSentEvent {
    return .{ .data = data };
}

/// A buffered Server-Sent Events response.
pub const EventStream = struct {
    /// Borrowed events that must outlive the handler call.
    events: []const ServerSentEvent,
    status: ?Status = null,
    headers: []const HeaderField = &.{},
};

/// Writes one event in the Server-Sent Events wire format.
pub fn writeEvent(writer: *std.Io.Writer, event: ServerSentEvent) !void {
    var wrote_field = false;
    if (event.comment) |comment| {
        try writeLines(writer, "", comment);
        wrote_field = true;
    }
    if (event.event) |name| {
        try writeLines(writer, "event", name);
        wrote_field = true;
    }
    if (event.id) |id| {
        try writeLines(writer, "id", id);
        wrote_field = true;
    }
    if (event.retry) |retry| {
        try writer.print("retry: {d}\n", .{retry});
        wrote_field = true;
    }
    if (event.data) |data| {
        try writeLines(writer, "data", data);
        wrote_field = true;
    }
    if (!wrote_field) try writeLines(writer, "data", "");
    try writer.writeByte('\n');
}

fn writeLines(writer: *std.Io.Writer, field: []const u8, value: []const u8) !void {
    var start: usize = 0;
    while (start <= value.len) {
        const newline = std.mem.indexOfScalarPos(u8, value, start, '\n') orelse value.len;
        var line = value[start..newline];
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        if (field.len == 0) {
            try writer.writeAll(":");
            if (line.len > 0) {
                try writer.writeByte(' ');
                try writer.writeAll(line);
            }
            try writer.writeByte('\n');
        } else {
            try writer.print("{s}: ", .{field});
            try writer.writeAll(line);
            try writer.writeByte('\n');
        }
        if (newline == value.len) break;
        start = newline + 1;
    }
}
