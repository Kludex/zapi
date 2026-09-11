//! Request body streaming and typed endpoint parameter wrappers.
//! The application request object is assembled by the transport and borrows its input buffers.

const std = @import("std");
const http = @import("http.zig");
const routing = @import("routing.zig");

const HeaderField = http.HeaderField;

/// A type-erased reverse-routing interface used by requests.
pub const URLResolver = struct {
    context: *anyopaque,
    resolve_fn: *const fn (*anyopaque, std.mem.Allocator, []const u8, []const HeaderField) anyerror![]u8,

    /// Resolves a route name with scalar parameters.
    pub fn pathFor(self: URLResolver, allocator: std.mem.Allocator, name: []const u8, params: anytype) ![]u8 {
        const fields = @typeInfo(@TypeOf(params)).@"struct".fields;
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        var values: [fields.len]HeaderField = undefined;
        inline for (fields, 0..) |field, index| {
            var value = std.Io.Writer.Allocating.init(arena.allocator());
            try routing.writeUrlScalar(&value.writer, @field(params, field.name));
            values[index] = .{
                .name = field.name,
                .value = try value.toOwnedSlice(),
            };
        }
        return self.resolve_fn(self.context, allocator, name, &values);
    }
};

pub const BodyStreamOptions = struct {
    chunk_size: usize = 16 * 1024,
};

pub const BodyStream = struct {
    body: []const u8,
    chunk_size: usize,
    index: usize = 0,

    pub fn next(self: *BodyStream) ?[]const u8 {
        if (self.index >= self.body.len) return null;
        const remaining = self.body.len - self.index;
        const chunk_len = if (self.chunk_size == 0) remaining else @min(self.chunk_size, remaining);
        const end = self.index + chunk_len;
        const chunk = self.body[self.index..end];
        self.index = end;
        return chunk;
    }

    pub fn reset(self: *BodyStream) void {
        self.index = 0;
    }
};

pub const RequestBodyReader = struct {
    reader: *std.Io.Reader,
    max_size: ?usize = null,
    bytes_read: usize = 0,

    pub fn read(self: *RequestBodyReader, buffer: []u8) !usize {
        const n = try self.reader.readSliceShort(buffer);
        if (self.max_size) |max_size| {
            if (n > max_size or self.bytes_read > max_size - n) return error.RequestBodyTooLarge;
        }
        self.bytes_read += n;
        return n;
    }

    pub fn discardRemaining(self: *RequestBodyReader) !void {
        var buffer: [8192]u8 = undefined;
        while (true) {
            const n = try self.read(&buffer);
            if (n == 0) return;
        }
    }
};

/// The source of a typed endpoint parameter.
pub const WrapperKind = enum { body, form, path, query, header, cookie };

pub fn Body(comptime T: type) type {
    return struct {
        const Self = @This();
        pub const zapi_wrapper = WrapperKind.body;
        pub const zapi_inner = T;

        value: T,
        parsed: ?std.json.Parsed(T) = null,

        pub fn deinit(self: *Self) void {
            if (self.parsed) |*parsed| parsed.deinit();
        }
    };
}

pub fn Form(comptime T: type) type {
    return struct {
        const Self = @This();
        pub const zapi_wrapper = WrapperKind.form;
        pub const zapi_inner = T;

        value: T,
        arena: ?std.heap.ArenaAllocator = null,

        pub fn deinit(self: *Self) void {
            if (self.arena) |*arena| arena.deinit();
        }
    };
}

pub fn Path(comptime T: type) type {
    return struct {
        const Self = @This();
        pub const zapi_wrapper = WrapperKind.path;
        pub const zapi_inner = T;

        value: T,
        arena: ?std.heap.ArenaAllocator = null,

        pub fn deinit(self: *Self) void {
            if (self.arena) |*arena| arena.deinit();
        }
    };
}

pub fn Query(comptime T: type) type {
    return struct {
        const Self = @This();
        pub const zapi_wrapper = WrapperKind.query;
        pub const zapi_inner = T;

        value: T,
        arena: ?std.heap.ArenaAllocator = null,

        pub fn deinit(self: *Self) void {
            if (self.arena) |*arena| arena.deinit();
        }
    };
}

pub fn Header(comptime T: type) type {
    return struct {
        const Self = @This();
        pub const zapi_wrapper = WrapperKind.header;
        pub const zapi_inner = T;

        value: T,
        arena: ?std.heap.ArenaAllocator = null,

        pub fn deinit(self: *Self) void {
            if (self.arena) |*arena| arena.deinit();
        }
    };
}

pub fn Cookie(comptime T: type) type {
    return struct {
        const Self = @This();
        pub const zapi_wrapper = WrapperKind.cookie;
        pub const zapi_inner = T;

        value: T,
        arena: ?std.heap.ArenaAllocator = null,

        pub fn deinit(self: *Self) void {
            if (self.arena) |*arena| arena.deinit();
        }
    };
}
