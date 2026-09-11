//! WebSocket values shared by the server adapter and test client.
//! Test responses own their decoded frames and raw transport buffer.

const std = @import("std");
const cookies = @import("cookies.zig");
const datastructures = @import("datastructures.zig");
const http = @import("http.zig");

const CookieParams = datastructures.CookieParams;
const HeaderField = http.HeaderField;
const Status = http.Status;
const parseSetCookieInto = cookies.parseSetCookieInto;

pub const WebSocketTestMessage = struct {
    opcode: std.http.Server.WebSocket.Opcode,
    data: []u8,
};

pub const WebSocketTestFrame = struct {
    opcode: std.http.Server.WebSocket.Opcode = .text,
    data: []const u8,
};

pub const WebSocketTestResponse = struct {
    status: Status,
    headers: std.ArrayList(HeaderField),
    message: ?WebSocketTestMessage = null,
    messages: std.ArrayList(WebSocketTestMessage) = .empty,
    raw_response: []u8,

    pub fn deinit(self: *WebSocketTestResponse, allocator: std.mem.Allocator) void {
        for (self.headers.items) |header_item| {
            allocator.free(header_item.name);
            allocator.free(header_item.value);
        }
        self.headers.deinit(allocator);
        if (self.message) |message| allocator.free(message.data);
        for (self.messages.items) |message| allocator.free(message.data);
        self.messages.deinit(allocator);
        allocator.free(self.raw_response);
    }

    pub fn header(self: WebSocketTestResponse, name: []const u8) ?[]const u8 {
        for (self.headers.items) |item| {
            if (std.ascii.eqlIgnoreCase(item.name, name)) return item.value;
        }
        return null;
    }

    pub fn hasHeader(self: WebSocketTestResponse, name: []const u8) bool {
        return self.header(name) != null;
    }

    pub fn headerValues(self: WebSocketTestResponse, allocator: std.mem.Allocator, name: []const u8) ![]const []const u8 {
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

    pub fn reason(self: WebSocketTestResponse) []const u8 {
        return self.status.reason();
    }

    pub fn statusCode(self: WebSocketTestResponse) u16 {
        return self.status.code();
    }

    pub fn expectStatus(self: WebSocketTestResponse, expected: Status) !void {
        if (self.status != expected) return error.UnexpectedStatus;
    }

    pub fn text(self: WebSocketTestResponse) ?[]const u8 {
        const first = self.message orelse return null;
        if (first.opcode != .text) return null;
        return first.data;
    }

    pub fn binary(self: WebSocketTestResponse) ?[]const u8 {
        const first = self.message orelse return null;
        if (first.opcode != .binary) return null;
        return first.data;
    }

    pub fn json(self: WebSocketTestResponse, comptime T: type, allocator: std.mem.Allocator) !std.json.Parsed(T) {
        const body = self.text() orelse return error.InvalidMessage;
        return std.json.parseFromSlice(T, allocator, body, .{});
    }

    pub fn textMessages(self: WebSocketTestResponse, allocator: std.mem.Allocator) ![]const []const u8 {
        return self.messageDataByOpcode(allocator, .text);
    }

    pub fn binaryMessages(self: WebSocketTestResponse, allocator: std.mem.Allocator) ![]const []const u8 {
        return self.messageDataByOpcode(allocator, .binary);
    }

    fn messageDataByOpcode(self: WebSocketTestResponse, allocator: std.mem.Allocator, opcode: std.http.Server.WebSocket.Opcode) ![]const []const u8 {
        var count: usize = 0;
        for (self.messages.items) |item| {
            if (item.opcode == opcode) count += 1;
        }

        const values = try allocator.alloc([]const u8, count);
        var index: usize = 0;
        for (self.messages.items) |item| {
            if (item.opcode != opcode) continue;
            values[index] = item.data;
            index += 1;
        }
        return values;
    }
};
