//! Signed session values and cookie configuration.
//! Cryptographic encoding belongs to session middleware, not this module.

const std = @import("std");

pub const SameSite = enum {
    lax,
    strict,
    none,

    pub fn text(self: SameSite) []const u8 {
        return switch (self) {
            .lax => "lax",
            .strict => "strict",
            .none => "none",
        };
    }
};

pub const CookieOptions = struct {
    path: ?[]const u8 = "/",
    domain: ?[]const u8 = null,
    max_age: ?i64 = null,
    expires: ?[]const u8 = null,
    secure: bool = false,
    http_only: bool = false,
    same_site: ?SameSite = .lax,
    partitioned: bool = false,
};

pub const Session = struct {
    allocator: std.mem.Allocator,
    values: std.StringHashMap([]const u8),
    changed: bool = false,

    pub fn init(allocator: std.mem.Allocator) Session {
        return .{
            .allocator = allocator,
            .values = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *Session) void {
        var it = self.values.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.values.deinit();
    }

    pub fn get(self: *Session, key: []const u8) ?[]const u8 {
        return self.values.get(key);
    }

    pub fn put(self: *Session, key: []const u8, value: []const u8) !void {
        try self.putChanged(key, value, true);
    }

    pub fn remove(self: *Session, key: []const u8) void {
        if (self.values.fetchRemove(key)) |entry| {
            self.allocator.free(entry.key);
            self.allocator.free(entry.value);
            self.changed = true;
        }
    }

    pub fn clear(self: *Session) void {
        var it = self.values.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.values.clearRetainingCapacity();
        self.changed = true;
    }

    pub fn isEmpty(self: *Session) bool {
        return self.values.count() == 0;
    }

    pub fn putLoaded(self: *Session, key: []const u8, value: []const u8) !void {
        try self.putChanged(key, value, false);
    }

    fn putChanged(self: *Session, key: []const u8, value: []const u8, changed: bool) !void {
        const owned_value = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(owned_value);

        const entry = try self.values.getOrPut(key);
        if (entry.found_existing) {
            self.allocator.free(entry.value_ptr.*);
        } else {
            entry.key_ptr.* = try self.allocator.dupe(u8, key);
        }
        entry.value_ptr.* = owned_value;
        if (changed) self.changed = true;
    }
};
