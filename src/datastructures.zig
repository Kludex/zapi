//! Small request and form values shared across zapi modules.
//! These values own allocations only when their constructors say so.

const std = @import("std");
const http = @import("http.zig");

const HeaderField = http.HeaderField;

/// One uploaded file supplied directly to a request builder.
pub const UploadFile = struct {
    filename: []const u8,
    content_type: []const u8 = "application/octet-stream",
    content: []const u8,
};

/// One named uploaded file in multipart form data.
pub const MultipartFileField = struct {
    name: []const u8,
    filename: []const u8,
    content_type: []const u8 = "application/octet-stream",
    content: []const u8,
};

/// A remote host and port associated with a request.
pub const ClientAddress = struct {
    host: []const u8,
    port: u16,
};

pub const FormValue = union(enum) {
    text: []const u8,
    file: UploadFile,
};

pub const FormField = struct {
    name: []const u8,
    value: FormValue,
};

const FormFieldValues = struct {
    items: std.ArrayList(FormValue) = .empty,
    owned_text: std.ArrayList(bool) = .empty,
};

pub const FormData = struct {
    allocator: std.mem.Allocator,
    values: std.StringHashMap(FormFieldValues),
    ordered_items: std.ArrayList(FormField) = .empty,
    owned: bool = true,

    pub fn init(allocator: std.mem.Allocator) FormData {
        return .{
            .allocator = allocator,
            .values = std.StringHashMap(FormFieldValues).init(allocator),
        };
    }

    pub fn initBorrowed(allocator: std.mem.Allocator) FormData {
        return .{
            .allocator = allocator,
            .values = std.StringHashMap(FormFieldValues).init(allocator),
            .owned = false,
        };
    }

    pub fn deinit(self: *FormData) void {
        var it = self.values.iterator();
        while (it.next()) |entry| {
            if (self.owned) {
                self.allocator.free(entry.key_ptr.*);
                for (entry.value_ptr.items.items, 0..) |value, i| {
                    if (entry.value_ptr.owned_text.items[i]) {
                        switch (value) {
                            .text => |text| self.allocator.free(text),
                            .file => {},
                        }
                    }
                }
            }
            entry.value_ptr.items.deinit(self.allocator);
            entry.value_ptr.owned_text.deinit(self.allocator);
        }
        self.values.deinit();
        if (self.owned) {
            for (self.ordered_items.items) |item| {
                self.allocator.free(item.name);
            }
        }
        self.ordered_items.deinit(self.allocator);
    }

    pub fn append(self: *FormData, key: []const u8, value: FormValue, owned_text: bool) !void {
        const ordered_name = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(ordered_name);

        const entry = try self.values.getOrPut(key);
        var inserted = false;
        errdefer if (inserted) {
            entry.value_ptr.items.deinit(self.allocator);
            entry.value_ptr.owned_text.deinit(self.allocator);
            self.allocator.free(entry.key_ptr.*);
            _ = self.values.remove(key);
        };

        if (!entry.found_existing) {
            entry.key_ptr.* = try self.allocator.dupe(u8, key);
            entry.value_ptr.* = .{};
            inserted = true;
        }
        try entry.value_ptr.items.append(self.allocator, value);
        errdefer _ = entry.value_ptr.items.pop();
        try entry.value_ptr.owned_text.append(self.allocator, owned_text);
        errdefer _ = entry.value_ptr.owned_text.pop();
        try self.ordered_items.append(self.allocator, .{ .name = ordered_name, .value = value });
    }

    pub fn get(self: *FormData, key: []const u8) ?FormValue {
        const values = self.getAll(key) orelse return null;
        if (values.len == 0) return null;
        return values[values.len - 1];
    }

    pub fn getAll(self: *FormData, key: []const u8) ?[]const FormValue {
        const values = self.values.getPtr(key) orelse return null;
        return values.items.items;
    }

    pub fn multiItems(self: *FormData) []const FormField {
        return self.ordered_items.items;
    }

    pub fn items(self: *FormData) []const FormField {
        return self.multiItems();
    }

    pub fn getText(self: *FormData, key: []const u8) ?[]const u8 {
        const value = self.get(key) orelse return null;
        return switch (value) {
            .text => |text| text,
            .file => null,
        };
    }

    pub fn getFile(self: *FormData, key: []const u8) ?UploadFile {
        const value = self.get(key) orelse return null;
        return switch (value) {
            .text => null,
            .file => |file| file,
        };
    }

    pub fn getAllText(self: *FormData, allocator: std.mem.Allocator, key: []const u8) !?[]const []const u8 {
        const values = self.getAll(key) orelse return null;
        var count: usize = 0;
        for (values) |value| {
            if (value == .text) count += 1;
        }

        const text_values = try allocator.alloc([]const u8, count);
        var index: usize = 0;
        for (values) |value| {
            switch (value) {
                .text => |text| {
                    text_values[index] = text;
                    index += 1;
                },
                .file => {},
            }
        }
        return text_values;
    }

    pub fn getAllFiles(self: *FormData, allocator: std.mem.Allocator, key: []const u8) !?[]const UploadFile {
        const values = self.getAll(key) orelse return null;
        var count: usize = 0;
        for (values) |value| {
            if (value == .file) count += 1;
        }

        const files = try allocator.alloc(UploadFile, count);
        var index: usize = 0;
        for (values) |value| {
            switch (value) {
                .text => {},
                .file => |file| {
                    files[index] = file;
                    index += 1;
                },
            }
        }
        return files;
    }

    pub fn contains(self: *FormData, key: []const u8) bool {
        return self.values.contains(key);
    }

    pub fn len(self: *FormData) usize {
        return self.values.count();
    }

    pub fn isEmpty(self: *FormData) bool {
        return self.len() == 0;
    }
};

const QueryParamValues = struct {
    items: std.ArrayList([]const u8) = .empty,
};

pub const QueryParams = struct {
    allocator: std.mem.Allocator,
    values: std.StringHashMap(QueryParamValues),
    ordered_items: std.ArrayList(HeaderField) = .empty,
    owned: bool = true,

    pub fn init(allocator: std.mem.Allocator) QueryParams {
        return .{
            .allocator = allocator,
            .values = std.StringHashMap(QueryParamValues).init(allocator),
        };
    }

    pub fn initBorrowed(allocator: std.mem.Allocator) QueryParams {
        return .{
            .allocator = allocator,
            .values = std.StringHashMap(QueryParamValues).init(allocator),
            .owned = false,
        };
    }

    pub fn deinit(self: *QueryParams) void {
        var it = self.values.iterator();
        while (it.next()) |entry| {
            if (self.owned) {
                self.allocator.free(entry.key_ptr.*);
                for (entry.value_ptr.items.items) |value| {
                    self.allocator.free(value);
                }
            }
            entry.value_ptr.items.deinit(self.allocator);
        }
        self.values.deinit();
        if (self.owned) {
            for (self.ordered_items.items) |item| {
                self.allocator.free(item.name);
            }
        }
        self.ordered_items.deinit(self.allocator);
    }

    pub fn append(self: *QueryParams, key: []const u8, value: []const u8) !void {
        const ordered_name = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(ordered_name);

        const entry = try self.values.getOrPut(key);
        var inserted = false;
        errdefer if (inserted) {
            entry.value_ptr.items.deinit(self.allocator);
            self.allocator.free(entry.key_ptr.*);
            _ = self.values.remove(key);
        };

        if (!entry.found_existing) {
            entry.key_ptr.* = try self.allocator.dupe(u8, key);
            entry.value_ptr.* = .{};
            inserted = true;
        }
        try entry.value_ptr.items.append(self.allocator, value);
        errdefer _ = entry.value_ptr.items.pop();
        try self.ordered_items.append(self.allocator, .{ .name = ordered_name, .value = value });
    }

    pub fn get(self: *QueryParams, key: []const u8) ?[]const u8 {
        const values = self.getAll(key) orelse return null;
        if (values.len == 0) return null;
        return values[values.len - 1];
    }

    pub fn getAll(self: *QueryParams, key: []const u8) ?[]const []const u8 {
        const values = self.values.getPtr(key) orelse return null;
        return values.items.items;
    }

    pub fn multiItems(self: *QueryParams) []const HeaderField {
        return self.ordered_items.items;
    }

    pub fn items(self: *QueryParams) []const HeaderField {
        return self.multiItems();
    }

    pub fn contains(self: *QueryParams, key: []const u8) bool {
        return self.values.contains(key);
    }

    pub fn len(self: *QueryParams) usize {
        return self.values.count();
    }

    pub fn isEmpty(self: *QueryParams) bool {
        return self.len() == 0;
    }
};

pub const CookieParams = struct {
    allocator: std.mem.Allocator,
    values: std.StringHashMap([]const u8),

    pub fn init(allocator: std.mem.Allocator) CookieParams {
        return .{
            .allocator = allocator,
            .values = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *CookieParams) void {
        var it = self.values.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.values.deinit();
    }

    pub fn put(self: *CookieParams, name: []const u8, value: []const u8) !void {
        const owned_value = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(owned_value);

        const entry = try self.values.getOrPut(name);
        if (entry.found_existing) {
            self.allocator.free(entry.value_ptr.*);
        } else {
            entry.key_ptr.* = try self.allocator.dupe(u8, name);
        }
        entry.value_ptr.* = owned_value;
    }

    pub fn remove(self: *CookieParams, name: []const u8) void {
        const entry = self.values.fetchRemove(name) orelse return;
        self.allocator.free(entry.key);
        self.allocator.free(entry.value);
    }

    pub fn get(self: *CookieParams, name: []const u8) ?[]const u8 {
        return self.values.get(name);
    }

    pub fn contains(self: *CookieParams, name: []const u8) bool {
        return self.values.contains(name);
    }

    pub fn items(self: *CookieParams, allocator: std.mem.Allocator) ![]const HeaderField {
        const values = try allocator.alloc(HeaderField, self.values.count());
        errdefer allocator.free(values);

        var it = self.values.iterator();
        var index: usize = 0;
        while (it.next()) |entry| {
            values[index] = .{
                .name = entry.key_ptr.*,
                .value = entry.value_ptr.*,
            };
            index += 1;
        }
        return values;
    }

    pub fn len(self: *CookieParams) usize {
        return self.values.count();
    }

    pub fn isEmpty(self: *CookieParams) bool {
        return self.len() == 0;
    }
};
