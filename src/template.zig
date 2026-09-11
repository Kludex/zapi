//! Small HTML template response values and rendering.
//! This is intentionally not a general-purpose template language.

const std = @import("std");
const http = @import("http.zig");

const HeaderField = http.HeaderField;
const Status = http.Status;

/// One named template value.
pub const TemplateValue = struct {
    name: []const u8,
    value: []const u8,
    escape: bool = true,
};

/// Creates an HTML-escaped template value.
pub fn template(name: []const u8, value: []const u8) TemplateValue {
    return .{ .name = name, .value = value };
}

/// Creates a trusted, unescaped HTML template value.
pub fn templateHtml(name: []const u8, value: []const u8) TemplateValue {
    return .{ .name = name, .value = value, .escape = false };
}

/// A template response rendered before the handler arguments are released.
pub const Template = struct {
    path: []const u8,
    dir: std.Io.Dir = .cwd(),
    /// Borrowed values that must outlive the handler call.
    context: []const TemplateValue = &.{},
    status: ?Status = null,
    content_type: []const u8 = "text/html; charset=utf-8",
    headers: []const HeaderField = &.{},
    max_size: std.Io.Limit = .limited(16 * 1024 * 1024),
};

/// Renders a template source into a writer.
pub fn render(writer: *std.Io.Writer, source: []const u8, context: []const TemplateValue) !void {
    var index: usize = 0;
    while (index < source.len) {
        const open = std.mem.indexOfPos(u8, source, index, "{{") orelse {
            try writer.writeAll(source[index..]);
            return;
        };

        try writer.writeAll(source[index..open]);

        const raw = open + 2 < source.len and source[open + 2] == '{';
        const name_start = open + if (raw) @as(usize, 3) else 2;
        const close_marker = if (raw) "}}}" else "}}";
        const close = std.mem.indexOfPos(u8, source, name_start, close_marker) orelse return error.InvalidTemplate;
        const raw_name = source[name_start..close];
        const name = std.mem.trim(u8, raw_name, " \t\r\n");
        if (name.len == 0) return error.InvalidTemplate;

        const value = valueFor(context, name) orelse return error.UnknownTemplateValue;
        if (raw or !value.escape) {
            try writer.writeAll(value.value);
        } else {
            try writeHtmlText(writer, value.value);
        }

        index = close + close_marker.len;
    }
}

fn valueFor(context: []const TemplateValue, name: []const u8) ?TemplateValue {
    for (context) |value| {
        if (std.mem.eql(u8, value.name, name)) return value;
    }
    return null;
}

fn writeHtmlText(writer: *std.Io.Writer, value: []const u8) !void {
    for (value) |ch| {
        switch (ch) {
            '&' => try writer.writeAll("&amp;"),
            '<' => try writer.writeAll("&lt;"),
            '>' => try writer.writeAll("&gt;"),
            else => try writer.writeByte(ch),
        }
    }
}
