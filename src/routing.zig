//! Route pattern validation, matching, and reverse URL rendering.
//! This module owns path and host syntax. It does not dispatch endpoint handlers.

const std = @import("std");
const http = @import("http.zig");
const scalar = @import("scalar.zig");

const HeaderField = http.HeaderField;
const Uuid = scalar.Uuid;

pub const PathConvertor = struct {
    name: []const u8,
    matches: *const fn ([]const u8) bool,
};

pub const BuiltinPathConverter = enum { string, integer, float, uuid, path };

pub const PathConverter = union(enum) {
    builtin: BuiltinPathConverter,
    custom: []const u8,
};

pub const RouteParam = struct {
    name: []const u8,
    converter: PathConverter,
};

const method_count = std.meta.fields(http.Method).len;

/// A route endpoint stored in a `RouteTree`.
pub const RouteTarget = struct {
    index: usize,
    method: ?http.Method = null,
};

/// The matching route indexes grouped by HTTP method.
pub const RouteMatches = struct {
    first_any: ?usize = null,
    first_by_method: [method_count]?usize = [_]?usize{null} ** method_count,

    fn record(self: *RouteMatches, target: RouteTarget) void {
        if (self.first_any == null or target.index < self.first_any.?) self.first_any = target.index;
        const method = target.method orelse return;
        const current = &self.first_by_method[@intFromEnum(method)];
        if (current.* == null or target.index < current.*.?) current.* = target.index;
    }

    /// Returns the first registered route for `method`.
    pub fn firstForMethod(self: RouteMatches, method: http.Method) ?usize {
        return self.first_by_method[@intFromEnum(method)];
    }

    /// Writes matched methods in route registration order.
    pub fn methodsInRegistrationOrder(self: RouteMatches, output: *[method_count]http.Method) []const http.Method {
        var used = [_]bool{false} ** method_count;
        var len: usize = 0;
        while (true) {
            var next_method: ?http.Method = null;
            var next_index: ?usize = null;
            var index: usize = 0;
            while (index < method_count) : (index += 1) {
                if (used[index]) continue;
                const route_index = self.first_by_method[index] orelse continue;
                if (next_index == null or route_index < next_index.?) {
                    next_method = @enumFromInt(index);
                    next_index = route_index;
                }
            }
            const method = next_method orelse break;
            output[len] = method;
            len += 1;
            used[@intFromEnum(method)] = true;
        }
        return output[0..len];
    }
};

const RouteTreeEdge = struct {
    pattern: []const u8,
    child: usize,
    catch_all: bool,
};

const RouteTreeNode = struct {
    static_children: std.StringHashMapUnmanaged(usize) = .empty,
    pattern_children: std.ArrayList(RouteTreeEdge) = .empty,
    targets: std.ArrayList(RouteTarget) = .empty,

    fn deinit(self: *RouteTreeNode, gpa: std.mem.Allocator) void {
        self.static_children.deinit(gpa);
        self.pattern_children.deinit(gpa);
        self.targets.deinit(gpa);
    }
};

const AddedEdge = union(enum) {
    static: struct { parent: usize, segment: []const u8 },
    pattern: struct { parent: usize },
};

/// A segment radix tree compiled from registered route patterns.
/// Edge labels borrow the registered route paths and remain valid until `deinit`.
pub const RouteTree = struct {
    nodes: std.ArrayList(RouteTreeNode) = .empty,

    /// Releases the tree index without freeing borrowed route paths.
    pub fn deinit(self: *RouteTree, gpa: std.mem.Allocator) void {
        for (self.nodes.items) |*node| node.deinit(gpa);
        self.nodes.deinit(gpa);
    }

    /// Adds one route target while preserving registration order in its index.
    pub fn add(self: *RouteTree, gpa: std.mem.Allocator, path: []const u8, target: RouteTarget) std.mem.Allocator.Error!void {
        const original_node_count = self.nodes.items.len;
        var added_edge: ?AddedEdge = null;
        errdefer self.rollbackAdd(gpa, original_node_count, added_edge);

        if (self.nodes.items.len == 0) try self.nodes.append(gpa, .{});
        var node_index: usize = 0;

        if (std.mem.eql(u8, path, "/")) {
            try self.nodes.items[0].targets.append(gpa, target);
            return;
        }

        const normalized = std.mem.trimStart(u8, path, "/");
        var position: usize = 0;
        while (true) {
            const segment_end = std.mem.indexOfScalarPos(u8, normalized, position, '/') orelse normalized.len;
            const segment = normalized[position..segment_end];
            const dynamic = std.mem.indexOfScalar(u8, segment, '{') != null;

            if (dynamic) {
                if (findPatternChild(self.nodes.items[node_index].pattern_children.items, segment)) |child| {
                    node_index = child;
                } else {
                    const child = self.nodes.items.len;
                    try self.nodes.append(gpa, .{});
                    self.nodes.items[node_index].pattern_children.append(gpa, .{
                        .pattern = segment,
                        .child = child,
                        .catch_all = terminalPathParamSegment(segment) != null,
                    }) catch |err| {
                        self.nodes.items[child].deinit(gpa);
                        self.nodes.shrinkRetainingCapacity(child);
                        return err;
                    };
                    if (added_edge == null) added_edge = .{ .pattern = .{ .parent = node_index } };
                    node_index = child;
                }
            } else if (self.nodes.items[node_index].static_children.get(segment)) |child| {
                node_index = child;
            } else {
                const child = self.nodes.items.len;
                try self.nodes.append(gpa, .{});
                self.nodes.items[node_index].static_children.put(gpa, segment, child) catch |err| {
                    self.nodes.items[child].deinit(gpa);
                    self.nodes.shrinkRetainingCapacity(child);
                    return err;
                };
                if (added_edge == null) added_edge = .{ .static = .{ .parent = node_index, .segment = segment } };
                node_index = child;
            }

            if (segment_end == normalized.len) break;
            position = segment_end + 1;
        }

        try self.nodes.items[node_index].targets.append(gpa, target);
    }

    /// Finds matching route indexes without allocating or copying path parameters.
    pub fn matches(self: *const RouteTree, path: []const u8, custom_convertors: []const PathConvertor) RouteMatches {
        var result: RouteMatches = .{};
        if (self.nodes.items.len == 0) return result;
        if (std.mem.eql(u8, path, "/")) {
            recordTargets(self.nodes.items[0].targets.items, &result);
            return result;
        }

        const normalized = std.mem.trimStart(u8, path, "/");
        self.matchNode(0, normalized, 0, custom_convertors, &result);
        return result;
    }

    fn rollbackAdd(self: *RouteTree, gpa: std.mem.Allocator, original_node_count: usize, added_edge: ?AddedEdge) void {
        if (added_edge) |edge| switch (edge) {
            .static => |item| _ = self.nodes.items[item.parent].static_children.remove(item.segment),
            .pattern => |item| _ = self.nodes.items[item.parent].pattern_children.pop(),
        };
        for (self.nodes.items[original_node_count..]) |*node| node.deinit(gpa);
        self.nodes.shrinkRetainingCapacity(original_node_count);
    }

    fn matchNode(
        self: *const RouteTree,
        node_index: usize,
        path: []const u8,
        position: usize,
        custom_convertors: []const PathConvertor,
        result: *RouteMatches,
    ) void {
        const segment_end = std.mem.indexOfScalarPos(u8, path, position, '/') orelse path.len;
        const segment = path[position..segment_end];
        const next_position = if (segment_end < path.len) segment_end + 1 else null;
        const node = &self.nodes.items[node_index];

        if (node.static_children.get(segment)) |child| {
            if (next_position) |next| {
                self.matchNode(child, path, next, custom_convertors, result);
            } else {
                recordTargets(self.nodes.items[child].targets.items, result);
            }
        }

        for (node.pattern_children.items) |edge| {
            if (edge.catch_all) {
                const param = parseRouteParam(edge.pattern).?;
                if (pathSegmentMatches(param.converter, path[position..], custom_convertors)) {
                    recordTargets(self.nodes.items[edge.child].targets.items, result);
                }
                continue;
            }
            if (!pathPatternSegmentMatches(edge.pattern, segment, custom_convertors)) continue;
            if (next_position) |next| {
                self.matchNode(edge.child, path, next, custom_convertors, result);
            } else {
                recordTargets(self.nodes.items[edge.child].targets.items, result);
            }
        }
    }
};

fn recordTargets(targets: []const RouteTarget, result: *RouteMatches) void {
    for (targets) |target| result.record(target);
}

fn findPatternChild(edges: []const RouteTreeEdge, pattern: []const u8) ?usize {
    for (edges) |edge| {
        if (pathPatternsEquivalent(edge.pattern, pattern)) return edge.child;
    }
    return null;
}

fn pathPatternsEquivalent(a: []const u8, b: []const u8) bool {
    var a_index: usize = 0;
    var b_index: usize = 0;
    while (a_index < a.len and b_index < b.len) {
        if (a[a_index] != '{' or b[b_index] != '{') {
            if (a[a_index] != b[b_index]) return false;
            a_index += 1;
            b_index += 1;
            continue;
        }

        const a_end = std.mem.indexOfScalarPos(u8, a, a_index + 1, '}') orelse return false;
        const b_end = std.mem.indexOfScalarPos(u8, b, b_index + 1, '}') orelse return false;
        const a_param = parseRouteParam(a[a_index .. a_end + 1]) orelse return false;
        const b_param = parseRouteParam(b[b_index .. b_end + 1]) orelse return false;
        if (!pathConvertersEqual(a_param.converter, b_param.converter)) return false;
        a_index = a_end + 1;
        b_index = b_end + 1;
    }
    return a_index == a.len and b_index == b.len;
}

fn pathConvertersEqual(a: PathConverter, b: PathConverter) bool {
    return switch (a) {
        .builtin => |a_builtin| switch (b) {
            .builtin => |b_builtin| a_builtin == b_builtin,
            .custom => false,
        },
        .custom => |a_name| switch (b) {
            .builtin => false,
            .custom => |b_name| std.mem.eql(u8, a_name, b_name),
        },
    };
}

fn pathPatternSegmentMatches(pattern_segment: []const u8, path_segment: []const u8, custom_convertors: []const PathConvertor) bool {
    var pattern_index: usize = 0;
    var path_index: usize = 0;

    while (pattern_index < pattern_segment.len) {
        if (pattern_segment[pattern_index] != '{') {
            if (path_index >= path_segment.len or pattern_segment[pattern_index] != path_segment[path_index]) return false;
            pattern_index += 1;
            path_index += 1;
            continue;
        }

        const end = std.mem.indexOfScalarPos(u8, pattern_segment, pattern_index + 1, '}') orelse return false;
        const param = parseRouteParam(pattern_segment[pattern_index .. end + 1]) orelse return false;
        if (pathConverterIsPath(param.converter)) return false;
        const next_static_start = end + 1;
        const value_end = if (nextStaticInSegment(pattern_segment[next_static_start..])) |next_static|
            std.mem.indexOfPos(u8, path_segment, path_index, next_static.value) orelse return false
        else
            path_segment.len;

        if (!pathSegmentMatches(param.converter, path_segment[path_index..value_end], custom_convertors)) return false;
        pattern_index = end + 1;
        path_index = value_end;
    }

    return path_index == path_segment.len;
}

pub fn matchPath(pattern: []const u8, path: []const u8, params: *std.StringHashMap([]const u8), custom_convertors: []const PathConvertor) !bool {
    if (std.mem.eql(u8, pattern, "/") or std.mem.eql(u8, path, "/")) {
        return std.mem.eql(u8, pattern, path);
    }

    var pattern_it = std.mem.splitScalar(u8, std.mem.trimStart(u8, pattern, "/"), '/');
    var path_it = std.mem.splitScalar(u8, std.mem.trimStart(u8, path, "/"), '/');

    while (true) {
        const pattern_part = pattern_it.next();
        const path_part = path_it.next();
        if (pattern_part == null or path_part == null) return pattern_part == null and path_part == null;

        const p = pattern_part.?;
        const segment = path_part.?;
        if (terminalPathParamSegment(p)) |param| {
            const start = @intFromPtr(segment.ptr) - @intFromPtr(path.ptr);
            const value = path[start..];
            if (!pathSegmentMatches(param.converter, value, custom_convertors)) return false;
            try params.put(param.name, value);
            return pattern_it.next() == null;
        }

        if (!try matchPathSegment(p, segment, params, custom_convertors)) return false;
    }
}

pub fn parseRouteParam(segment: []const u8) ?RouteParam {
    if (segment.len < 2 or segment[0] != '{' or segment[segment.len - 1] != '}') return null;

    const contents = segment[1 .. segment.len - 1];
    if (contents.len == 0) return null;

    if (std.mem.indexOfScalar(u8, contents, ':')) |colon| {
        const name = contents[0..colon];
        const converter_name = contents[colon + 1 ..];
        if (name.len == 0 or converter_name.len == 0) return null;
        if (!validPathParamName(name)) return null;
        return .{
            .name = name,
            .converter = parsePathConverter(converter_name),
        };
    }

    if (!validPathParamName(contents)) return null;
    return .{ .name = contents, .converter = .{ .builtin = .string } };
}

pub fn validPathParamName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (!std.ascii.isAlphabetic(name[0]) and name[0] != '_') return false;
    for (name[1..]) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '_') return false;
    }
    return true;
}

pub fn validPathConvertorName(name: []const u8) bool {
    return validPathParamName(name);
}

pub fn parsePathConverter(name: []const u8) PathConverter {
    if (parseBuiltinPathConverter(name)) |builtin| return .{ .builtin = builtin };
    return .{ .custom = name };
}

pub fn parseBuiltinPathConverter(name: []const u8) ?BuiltinPathConverter {
    if (std.mem.eql(u8, name, "str")) return .string;
    if (std.mem.eql(u8, name, "string")) return .string;
    if (std.mem.eql(u8, name, "int")) return .integer;
    if (std.mem.eql(u8, name, "float")) return .float;
    if (std.mem.eql(u8, name, "uuid")) return .uuid;
    if (std.mem.eql(u8, name, "path")) return .path;
    return null;
}

pub fn pathConverterRegistered(converter: PathConverter, custom_convertors: []const PathConvertor) bool {
    return switch (converter) {
        .builtin => true,
        .custom => |name| findPathConvertor(custom_convertors, name) != null,
    };
}

pub fn pathConverterIsPath(converter: PathConverter) bool {
    return switch (converter) {
        .builtin => |builtin| builtin == .path,
        .custom => false,
    };
}

pub fn findPathConvertor(custom_convertors: []const PathConvertor, name: []const u8) ?PathConvertor {
    for (custom_convertors) |convertor| {
        if (std.mem.eql(u8, convertor.name, name)) return convertor;
    }
    return null;
}

pub fn validateRoutePath(allocator: std.mem.Allocator, path: []const u8, custom_convertors: []const PathConvertor) !void {
    if (path.len == 0 or path[0] != '/') return error.InvalidRoutePath;

    var names = std.StringHashMap(void).init(allocator);
    defer names.deinit();

    var i: usize = 0;
    while (i < path.len) {
        if (path[i] == '{') {
            const end = std.mem.indexOfScalarPos(u8, path, i + 1, '}') orelse return error.InvalidRoutePath;
            const param = parseRouteParam(path[i .. end + 1]) orelse return error.InvalidRoutePath;
            if (!pathConverterRegistered(param.converter, custom_convertors)) return error.InvalidRoutePath;
            if (pathConverterIsPath(param.converter) and !pathParamIsTerminalSegment(path, i, end)) return error.InvalidRoutePath;
            const entry = try names.getOrPut(param.name);
            if (entry.found_existing) return error.DuplicatePathParam;
            i = end + 1;
        } else if (path[i] == '}') {
            return error.InvalidRoutePath;
        } else {
            i += 1;
        }
    }
}

pub fn validateMountPath(allocator: std.mem.Allocator, path: []const u8, custom_convertors: []const PathConvertor) !void {
    validateRoutePath(allocator, path, custom_convertors) catch return error.InvalidMountPath;

    var i: usize = 0;
    while (i < path.len) {
        if (path[i] == '{') {
            const end = std.mem.indexOfScalarPos(u8, path, i + 1, '}') orelse return error.InvalidMountPath;
            const param = parseRouteParam(path[i .. end + 1]) orelse return error.InvalidMountPath;
            if (pathConverterIsPath(param.converter)) return error.InvalidMountPath;
            i = end + 1;
        } else {
            i += 1;
        }
    }
}

pub fn pathParamIsTerminalSegment(path: []const u8, start: usize, end: usize) bool {
    const segment_start = start == 0 or path[start - 1] == '/';
    const segment_end = end + 1 == path.len;
    return segment_start and segment_end;
}

pub fn pathSegmentMatches(converter: PathConverter, value: []const u8, custom_convertors: []const PathConvertor) bool {
    if (value.len == 0) return pathConverterIsPath(converter);

    return switch (converter) {
        .builtin => |builtin| switch (builtin) {
            .string => std.mem.indexOfScalar(u8, value, '/') == null,
            .integer => blk: {
                if (std.mem.indexOfScalar(u8, value, '/') != null) break :blk false;
                for (value) |ch| {
                    if (!std.ascii.isDigit(ch)) break :blk false;
                }
                break :blk true;
            },
            .float => blk: {
                if (std.mem.indexOfScalar(u8, value, '/') != null) break :blk false;
                if (!isPathFloat(value)) break :blk false;
                _ = std.fmt.parseFloat(f64, value) catch break :blk false;
                break :blk true;
            },
            .uuid => blk: {
                _ = Uuid.parse(value) catch break :blk false;
                break :blk true;
            },
            .path => true,
        },
        .custom => |name| blk: {
            if (std.mem.indexOfScalar(u8, value, '/') != null) break :blk false;
            const convertor = findPathConvertor(custom_convertors, name) orelse break :blk false;
            break :blk convertor.matches(value);
        },
    };
}

pub fn terminalPathParamSegment(pattern_segment: []const u8) ?RouteParam {
    const param = parseRouteParam(pattern_segment) orelse return null;
    if (!pathConverterIsPath(param.converter)) return null;
    return param;
}

pub fn matchPathSegment(pattern_segment: []const u8, path_segment: []const u8, params: *std.StringHashMap([]const u8), custom_convertors: []const PathConvertor) !bool {
    var pattern_index: usize = 0;
    var path_index: usize = 0;

    while (pattern_index < pattern_segment.len) {
        if (pattern_segment[pattern_index] != '{') {
            if (path_index >= path_segment.len or pattern_segment[pattern_index] != path_segment[path_index]) return false;
            pattern_index += 1;
            path_index += 1;
            continue;
        }

        const end = std.mem.indexOfScalarPos(u8, pattern_segment, pattern_index + 1, '}') orelse return false;
        const param = parseRouteParam(pattern_segment[pattern_index .. end + 1]) orelse return false;
        if (pathConverterIsPath(param.converter)) return false;
        const next_static_start = end + 1;
        const value_end = if (nextStaticInSegment(pattern_segment[next_static_start..])) |next_static|
            std.mem.indexOfPos(u8, path_segment, path_index, next_static.value) orelse return false
        else
            path_segment.len;

        const value = path_segment[path_index..value_end];
        if (!pathSegmentMatches(param.converter, value, custom_convertors)) return false;
        try params.put(param.name, value);
        pattern_index = end + 1;
        path_index = value_end;
    }

    return path_index == path_segment.len;
}

pub fn isPathFloat(value: []const u8) bool {
    if (value.len == 0) return false;

    var seen_dot = false;
    var digit_count: usize = 0;
    var digits_after_dot: usize = 0;

    for (value) |ch| {
        if (std.ascii.isDigit(ch)) {
            digit_count += 1;
            if (seen_dot) digits_after_dot += 1;
            continue;
        }
        if (ch == '.' and !seen_dot) {
            if (digit_count == 0) return false;
            seen_dot = true;
            continue;
        }
        return false;
    }

    if (digit_count == 0) return false;
    if (seen_dot and digits_after_dot == 0) return false;
    return true;
}

pub const NextStatic = struct {
    start: usize,
    value: []const u8,
};

pub fn nextStaticInSegment(pattern_tail: []const u8) ?NextStatic {
    var i: usize = 0;
    while (i < pattern_tail.len) {
        if (pattern_tail[i] == '{') {
            if (std.mem.indexOfScalarPos(u8, pattern_tail, i + 1, '}')) |end| {
                i = end + 1;
                continue;
            }
            return null;
        }

        const start = i;
        while (i < pattern_tail.len and pattern_tail[i] != '{') : (i += 1) {}
        return .{ .start = start, .value = pattern_tail[start..i] };
    }
    return null;
}

pub fn joinPaths(allocator: std.mem.Allocator, prefix: []const u8, path: []const u8) ![]u8 {
    if (prefix.len == 0) return allocator.dupe(u8, path);
    if (path.len == 0 or std.mem.eql(u8, path, "/")) return allocator.dupe(u8, prefix);

    const trimmed_prefix = std.mem.trimEnd(u8, prefix, "/");
    const trimmed_path = std.mem.trimStart(u8, path, "/");
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ trimmed_prefix, trimmed_path });
}

pub fn joinRequestPath(allocator: std.mem.Allocator, root_path: []const u8, path: []const u8) ![]u8 {
    if (root_path.len == 0) return allocator.dupe(u8, path);
    if (path.len == 0 or std.mem.eql(u8, path, "/")) {
        if (root_path[root_path.len - 1] == '/') return allocator.dupe(u8, root_path);
        return std.fmt.allocPrint(allocator, "{s}/", .{root_path});
    }
    return joinPaths(allocator, root_path, path);
}

pub fn joinMountRoutePath(allocator: std.mem.Allocator, mount_path: []const u8, child_path: []const u8) ![]u8 {
    if (std.mem.eql(u8, child_path, "/")) return joinRequestPath(allocator, mount_path, child_path);
    return joinPaths(allocator, mount_path, child_path);
}

pub const MaybeOwnedSlice = struct {
    value: []const u8,
    owned: bool = false,
};

pub fn mountRootPath(allocator: std.mem.Allocator, root_path: []const u8, mount_prefix: []const u8) !MaybeOwnedSlice {
    if (root_path.len == 0) return .{ .value = mount_prefix };
    return .{
        .value = try joinPaths(allocator, root_path, mount_prefix),
        .owned = true,
    };
}

pub fn docsOpenApiUrl(allocator: std.mem.Allocator, root_path: []const u8, openapi_url: []const u8) !MaybeOwnedSlice {
    if (root_path.len == 0 or !std.mem.startsWith(u8, openapi_url, "/")) {
        return .{ .value = openapi_url };
    }

    return .{
        .value = try joinPaths(allocator, root_path, openapi_url),
        .owned = true,
    };
}

pub fn normalizeMountPrefix(prefix: []const u8) []const u8 {
    const trimmed = std.mem.trimEnd(u8, prefix, "/");
    return if (trimmed.len == 0) "/" else trimmed;
}

pub fn normalizeHostMatchPattern(pattern: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, pattern, " \t");
    if (trimmed.len == 0) return null;
    if (std.mem.indexOfAny(u8, trimmed, "/ \t\r\n") != null) return null;
    return hostPatternMatchName(trimmed);
}

pub fn normalizeHostUrlPattern(pattern: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, pattern, " \t");
    if (trimmed.len == 0) return null;
    if (std.mem.indexOfAny(u8, trimmed, "/ \t\r\n") != null) return null;
    _ = hostPatternMatchName(trimmed) orelse return null;
    return trimmed;
}

pub fn hostPatternMatchName(pattern: []const u8) ?[]const u8 {
    if (pattern.len == 0) return null;
    if (pattern[0] == '[') {
        const end = std.mem.indexOfScalar(u8, pattern, ']') orelse return null;
        return pattern[0 .. end + 1];
    }

    var in_param = false;
    for (pattern, 0..) |ch, i| {
        if (ch == '{') {
            if (in_param) return null;
            in_param = true;
            continue;
        }
        if (ch == '}') {
            if (!in_param) return null;
            in_param = false;
            continue;
        }
        if (ch == ':' and !in_param) {
            return if (i == 0) null else pattern[0..i];
        }
    }

    if (in_param) return null;
    return pattern;
}

pub fn validateHostPattern(allocator: std.mem.Allocator, pattern: []const u8, custom_convertors: []const PathConvertor) !void {
    var names = std.StringHashMap(void).init(allocator);
    defer names.deinit();

    var i: usize = 0;
    while (i < pattern.len) {
        if (pattern[i] == '{') {
            const end = std.mem.indexOfScalarPos(u8, pattern, i + 1, '}') orelse return error.InvalidHostPattern;
            const param = parseRouteParam(pattern[i .. end + 1]) orelse return error.InvalidHostPattern;
            if (!pathConverterRegistered(param.converter, custom_convertors)) return error.InvalidHostPattern;
            if (pathConverterIsPath(param.converter)) return error.InvalidHostPattern;
            const entry = try names.getOrPut(param.name);
            if (entry.found_existing) return error.DuplicateHostParam;
            i = end + 1;
        } else if (pattern[i] == '}') {
            return error.InvalidHostPattern;
        } else {
            i += 1;
        }
    }
}

pub fn requestHostName(host_header: []const u8) ?[]const u8 {
    const value = std.mem.trim(u8, host_header, " \t");
    if (value.len == 0) return null;
    if (value[0] == '[') {
        const end = std.mem.indexOfScalar(u8, value, ']') orelse return null;
        return value[0 .. end + 1];
    }
    const colon = std.mem.indexOfScalar(u8, value, ':') orelse value.len;
    if (colon == 0) return null;
    return value[0..colon];
}

pub fn validRouteNamespace(value: []const u8) bool {
    if (value.len == 0) return false;
    return std.mem.indexOfAny(u8, value, ":/ \t\r\n") == null;
}

pub fn namespacedRouteName(name: []const u8, namespace: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, name, namespace)) return null;
    if (name.len <= namespace.len or name[namespace.len] != ':') return null;
    const child_name = name[namespace.len + 1 ..];
    return if (child_name.len == 0) null else child_name;
}

pub fn matchHost(allocator: std.mem.Allocator, pattern: []const u8, host: []const u8, params: *std.ArrayList(HeaderField), custom_convertors: []const PathConvertor) !bool {
    var pattern_index: usize = 0;
    var host_index: usize = 0;

    while (pattern_index < pattern.len) {
        if (pattern[pattern_index] != '{') {
            if (host_index >= host.len or std.ascii.toLower(pattern[pattern_index]) != std.ascii.toLower(host[host_index])) return false;
            pattern_index += 1;
            host_index += 1;
            continue;
        }

        const end = std.mem.indexOfScalarPos(u8, pattern, pattern_index + 1, '}') orelse return false;
        const param = parseRouteParam(pattern[pattern_index .. end + 1]) orelse return false;
        if (pathConverterIsPath(param.converter)) return false;
        const next_static_start = end + 1;
        const value_end = if (nextStaticInSegment(pattern[next_static_start..])) |next_static|
            indexOfIgnoreCasePos(host, host_index, next_static.value) orelse return false
        else
            host.len;

        const value = host[host_index..value_end];
        if (!pathSegmentMatches(param.converter, value, custom_convertors)) return false;
        try params.append(allocator, .{
            .name = param.name,
            .value = value,
        });
        pattern_index = end + 1;
        host_index = value_end;
    }

    return host_index == host.len;
}

pub fn indexOfIgnoreCasePos(haystack: []const u8, start: usize, needle: []const u8) ?usize {
    if (needle.len == 0) return start;
    if (start > haystack.len or needle.len > haystack.len - start) return null;
    var index = start;
    while (index <= haystack.len - needle.len) : (index += 1) {
        var matched = true;
        for (needle, 0..) |ch, offset| {
            if (std.ascii.toLower(ch) != std.ascii.toLower(haystack[index + offset])) {
                matched = false;
                break;
            }
        }
        if (matched) return index;
    }
    return null;
}

pub fn ParamUsage(comptime Params: type) type {
    return switch (@typeInfo(Params)) {
        .@"struct" => |info| [info.fields.len]bool,
        else => @compileError("urlPathFor params must be a struct literal, e.g. .{ .id = 1 }"),
    };
}

pub fn initParamUsage(comptime Params: type) ParamUsage(Params) {
    const fields = @typeInfo(Params).@"struct".fields;
    return [_]bool{false} ** fields.len;
}

pub fn markParamUsed(used: anytype, comptime index: usize) void {
    if (comptime @TypeOf(used) != @TypeOf(null)) {
        used.*[index] = true;
    }
}

pub fn ensureNoUnusedUrlParams(params: anytype, used: ParamUsage(@TypeOf(params))) !void {
    const Params = @TypeOf(params);
    inline for (@typeInfo(Params).@"struct".fields, 0..) |_, index| {
        if (!used[index]) return error.NoRoute;
    }
}

pub const MountMatch = struct {
    path: []const u8,
    root_prefix: []const u8,
};

pub fn matchMount(allocator: std.mem.Allocator, pattern: []const u8, path: []const u8, params: *std.ArrayList(HeaderField), custom_convertors: []const PathConvertor) !?MountMatch {
    if (path.len == 0 or path[0] != '/') return null;
    if (std.mem.eql(u8, pattern, "/")) {
        return .{
            .path = path,
            .root_prefix = "",
        };
    }

    var captured = std.StringHashMap([]const u8).init(allocator);
    defer captured.deinit();

    var pattern_index: usize = 1;
    var path_index: usize = 1;
    var consumed_end: usize = 0;

    while (pattern_index < pattern.len) {
        if (path_index > path.len or path_index == path.len) return null;

        const pattern_end = std.mem.indexOfScalarPos(u8, pattern, pattern_index, '/') orelse pattern.len;
        const path_end = std.mem.indexOfScalarPos(u8, path, path_index, '/') orelse path.len;
        const pattern_segment = pattern[pattern_index..pattern_end];
        const path_segment = path[path_index..path_end];

        if (!try matchPathSegment(pattern_segment, path_segment, &captured, custom_convertors)) return null;

        consumed_end = path_end;
        pattern_index = if (pattern_end < pattern.len) pattern_end + 1 else pattern_end;
        path_index = if (path_end < path.len) path_end + 1 else path_end;
    }

    var it = captured.iterator();
    while (it.next()) |entry| {
        try params.append(allocator, .{
            .name = entry.key_ptr.*,
            .value = entry.value_ptr.*,
        });
    }

    return .{
        .path = if (consumed_end == path.len) "/" else path[consumed_end..],
        .root_prefix = path[0..consumed_end],
    };
}

pub fn renderPath(allocator: std.mem.Allocator, pattern: []const u8, params: anytype) anyerror![]u8 {
    return renderPattern(allocator, pattern, params, .path, null, &.{});
}

pub fn renderPathTracked(allocator: std.mem.Allocator, pattern: []const u8, params: anytype, used: anytype, custom_convertors: []const PathConvertor) anyerror![]u8 {
    return renderPattern(allocator, pattern, params, .path, used, custom_convertors);
}

pub fn renderHostPattern(allocator: std.mem.Allocator, pattern: []const u8, params: anytype) anyerror![]u8 {
    return renderPattern(allocator, pattern, params, .host, null, &.{});
}

pub fn renderHostPatternTracked(allocator: std.mem.Allocator, pattern: []const u8, params: anytype, used: anytype, custom_convertors: []const PathConvertor) anyerror![]u8 {
    return renderPattern(allocator, pattern, params, .host, used, custom_convertors);
}

pub const RenderTarget = enum { path, host };

pub fn renderPattern(allocator: std.mem.Allocator, pattern: []const u8, params: anytype, comptime target: RenderTarget, used: anytype, custom_convertors: []const PathConvertor) anyerror![]u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    errdefer out.deinit();

    var i: usize = 0;
    while (i < pattern.len) {
        if (pattern[i] == '{') {
            const end = std.mem.indexOfScalarPos(u8, pattern, i + 1, '}') orelse return error.InvalidRoutePath;
            const param = parseRouteParam(pattern[i .. end + 1]) orelse return error.InvalidRoutePath;
            try writeParamValue(allocator, &out.writer, param, params, target, used, custom_convertors);
            i = end + 1;
        } else {
            try out.writer.writeByte(pattern[i]);
            i += 1;
        }
    }

    return out.toOwnedSlice();
}

pub fn renderMountPath(allocator: std.mem.Allocator, prefix: []const u8, params: anytype) anyerror![]u8 {
    return renderMountPathWithUsage(allocator, prefix, params, null, &.{});
}

pub fn renderMountPathTracked(allocator: std.mem.Allocator, prefix: []const u8, params: anytype, used: anytype, custom_convertors: []const PathConvertor) anyerror![]u8 {
    return renderMountPathWithUsage(allocator, prefix, params, used, custom_convertors);
}

pub fn renderMountPathWithUsage(allocator: std.mem.Allocator, prefix: []const u8, params: anytype, used: anytype, custom_convertors: []const PathConvertor) anyerror![]u8 {
    const rendered_prefix = try renderPattern(allocator, prefix, params, .path, used, custom_convertors);
    defer allocator.free(rendered_prefix);

    const Params = @TypeOf(params);
    switch (@typeInfo(Params)) {
        .@"struct" => |info| {
            inline for (info.fields, 0..) |field, field_index| {
                if (std.mem.eql(u8, field.name, "path")) {
                    markParamUsed(used, field_index);
                    var value = std.Io.Writer.Allocating.init(allocator);
                    defer value.deinit();
                    try writeUrlScalar(&value.writer, @field(params, field.name));
                    const raw_path = value.written();
                    if (raw_path.len == 0) return error.InvalidPathParam;
                    if (std.mem.indexOfAny(u8, raw_path, "\r\n\\") != null) return error.InvalidPathParam;

                    const tail = if (std.mem.startsWith(u8, raw_path, "/")) raw_path[1..] else raw_path;
                    var encoded = std.Io.Writer.Allocating.init(allocator);
                    defer encoded.deinit();
                    try encoded.writer.writeByte('/');
                    try writePercentEncodedPath(&encoded.writer, tail, true);
                    return joinPaths(allocator, rendered_prefix, encoded.written());
                }
            }
            return error.NoRoute;
        },
        else => @compileError("urlPathFor mount params must be a struct literal, e.g. .{ .path = \"/app.css\" }"),
    }
}

pub fn writeParamValue(allocator: std.mem.Allocator, writer: *std.Io.Writer, route_param: RouteParam, params: anytype, comptime target: RenderTarget, used: anytype, custom_convertors: []const PathConvertor) anyerror!void {
    const Params = @TypeOf(params);
    switch (@typeInfo(Params)) {
        .@"struct" => |info| {
            inline for (info.fields, 0..) |field, field_index| {
                if (std.mem.eql(u8, field.name, route_param.name)) {
                    markParamUsed(used, field_index);
                    var value = std.Io.Writer.Allocating.init(allocator);
                    defer value.deinit();
                    try writeUrlScalar(&value.writer, @field(params, field.name));
                    if (!pathSegmentMatches(route_param.converter, value.written(), custom_convertors)) return error.InvalidPathParam;
                    switch (target) {
                        .path => try writePercentEncodedPath(writer, value.written(), pathConverterIsPath(route_param.converter)),
                        .host => {
                            if (std.mem.indexOfAny(u8, value.written(), "%/?#@: \t\r\n") != null) return error.InvalidPathParam;
                            try writer.writeAll(value.written());
                        },
                    }
                    return;
                }
            }
            return error.MissingPathParam;
        },
        else => @compileError("urlPathFor params must be a struct literal, e.g. .{ .id = 1 }"),
    }
}

pub fn writeUrlScalar(writer: *std.Io.Writer, value: anytype) !void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .int, .comptime_int => try writer.print("{}", .{value}),
        .float, .comptime_float => try writer.print("{d}", .{value}),
        .bool => try writer.writeAll(if (value) "true" else "false"),
        .@"enum" => try writer.writeAll(@tagName(value)),
        .pointer => |ptr| {
            if (ptr.size == .slice and ptr.child == u8) {
                try writer.writeAll(value);
                return;
            }
            if (ptr.size == .one and @typeInfo(ptr.child) == .array and @typeInfo(ptr.child).array.child == u8) {
                const slice = value.*;
                try writer.writeAll(&slice);
                return;
            }
            @compileError("unsupported urlPathFor parameter pointer type: " ++ @typeName(T));
        },
        .array => |arr| {
            if (arr.child == u8) {
                try writer.writeAll(&value);
                return;
            }
            @compileError("unsupported urlPathFor parameter array type: " ++ @typeName(T));
        },
        else => @compileError("unsupported urlPathFor parameter type: " ++ @typeName(T)),
    }
}

pub fn renderPathFields(
    allocator: std.mem.Allocator,
    pattern: []const u8,
    params: []const HeaderField,
    used: []bool,
    custom_convertors: []const PathConvertor,
) ![]u8 {
    return renderPatternFields(allocator, pattern, params, used, .path, custom_convertors);
}

pub fn renderHostFields(
    allocator: std.mem.Allocator,
    pattern: []const u8,
    params: []const HeaderField,
    used: []bool,
    custom_convertors: []const PathConvertor,
) ![]u8 {
    return renderPatternFields(allocator, pattern, params, used, .host, custom_convertors);
}

pub fn renderMountFields(
    allocator: std.mem.Allocator,
    prefix: []const u8,
    params: []const HeaderField,
    used: []bool,
    custom_convertors: []const PathConvertor,
) ![]u8 {
    const rendered_prefix = try renderPatternFields(allocator, prefix, params, used, .path, custom_convertors);
    defer allocator.free(rendered_prefix);

    for (params, 0..) |param, index| {
        if (!std.mem.eql(u8, param.name, "path")) continue;
        used[index] = true;
        if (param.value.len == 0 or std.mem.indexOfAny(u8, param.value, "\r\n\\") != null) {
            return error.InvalidPathParam;
        }

        const tail = if (std.mem.startsWith(u8, param.value, "/")) param.value[1..] else param.value;
        var encoded = std.Io.Writer.Allocating.init(allocator);
        defer encoded.deinit();
        try encoded.writer.writeByte('/');
        try writePercentEncodedPath(&encoded.writer, tail, true);
        return joinPaths(allocator, rendered_prefix, encoded.written());
    }
    return error.NoRoute;
}

fn renderPatternFields(
    allocator: std.mem.Allocator,
    pattern: []const u8,
    params: []const HeaderField,
    used: []bool,
    target: RenderTarget,
    custom_convertors: []const PathConvertor,
) ![]u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    errdefer out.deinit();

    var index: usize = 0;
    while (index < pattern.len) {
        if (pattern[index] != '{') {
            try out.writer.writeByte(pattern[index]);
            index += 1;
            continue;
        }

        const end = std.mem.indexOfScalarPos(u8, pattern, index + 1, '}') orelse return error.InvalidRoutePath;
        const route_param = parseRouteParam(pattern[index .. end + 1]) orelse return error.InvalidRoutePath;
        var found = false;
        for (params, 0..) |param, param_index| {
            if (!std.mem.eql(u8, param.name, route_param.name)) continue;
            if (!pathSegmentMatches(route_param.converter, param.value, custom_convertors)) return error.InvalidPathParam;
            used[param_index] = true;
            switch (target) {
                .path => try writePercentEncodedPath(&out.writer, param.value, pathConverterIsPath(route_param.converter)),
                .host => {
                    if (std.mem.indexOfAny(u8, param.value, "%/?#@: \t\r\n") != null) return error.InvalidPathParam;
                    try out.writer.writeAll(param.value);
                },
            }
            found = true;
            break;
        }
        if (!found) return error.MissingPathParam;
        index = end + 1;
    }
    return out.toOwnedSlice();
}

pub fn writePercentEncodedPath(writer: *std.Io.Writer, value: []const u8, allow_slash: bool) !void {
    const hex = "0123456789ABCDEF";
    for (value) |ch| {
        if (pathCharSafe(ch, allow_slash)) {
            try writer.writeByte(ch);
        } else {
            try writer.writeByte('%');
            try writer.writeByte(hex[ch >> 4]);
            try writer.writeByte(hex[ch & 0x0f]);
        }
    }
}

pub fn pathCharSafe(ch: u8, allow_slash: bool) bool {
    if (std.ascii.isAlphanumeric(ch)) return true;
    return switch (ch) {
        '-',
        '.',
        '_',
        '~',
        ':',
        '@',
        '!',
        '$',
        '&',
        '\'',
        '(',
        ')',
        '*',
        '+',
        ',',
        ';',
        '=',
        => true,
        '/' => allow_slash,
        else => false,
    };
}

fn checkRouteTreeAllocationFailure(gpa: std.mem.Allocator) !void {
    var tree: RouteTree = .{};
    defer tree.deinit(gpa);

    try tree.add(gpa, "/users/{id:int}", .{ .index = 0, .method = .GET });
    try tree.add(gpa, "/users/me", .{ .index = 1, .method = .GET });
    try tree.add(gpa, "/assets/{path:path}", .{ .index = 2, .method = .GET });
}

test "route tree preserves route order across static and parameter branches" {
    var tree: RouteTree = .{};
    defer tree.deinit(std.testing.allocator);

    try tree.add(std.testing.allocator, "/users/{name}", .{ .index = 0, .method = .GET });
    try tree.add(std.testing.allocator, "/users/me", .{ .index = 1, .method = .GET });
    try tree.add(std.testing.allocator, "/users/{id:int}", .{ .index = 2, .method = .POST });

    const static_match = tree.matches("/users/me", &.{});
    try std.testing.expectEqual(@as(?usize, 0), static_match.firstForMethod(.GET));
    try std.testing.expectEqual(@as(?usize, null), static_match.firstForMethod(.POST));

    const integer_match = tree.matches("/users/42", &.{});
    try std.testing.expectEqual(@as(?usize, 0), integer_match.firstForMethod(.GET));
    try std.testing.expectEqual(@as(?usize, 2), integer_match.firstForMethod(.POST));
}

test "route tree matches roots trailing slashes embedded params and path captures" {
    const patterns = [_][]const u8{
        "/",
        "/users/{id:int}",
        "/files/file-{name}.json",
        "/assets/{path:path}",
        "/trailing/",
    };
    const paths = [_][]const u8{
        "/",
        "/users/42",
        "/users/nope",
        "/files/file-report.json",
        "/assets/css/app.css",
        "/assets/",
        "/trailing/",
        "/trailing",
    };

    var tree: RouteTree = .{};
    defer tree.deinit(std.testing.allocator);
    for (patterns, 0..) |pattern, index| {
        try tree.add(std.testing.allocator, pattern, .{ .index = index });
    }

    for (paths) |path| {
        var expected: ?usize = null;
        for (patterns, 0..) |pattern, index| {
            var params = std.StringHashMap([]const u8).init(std.testing.allocator);
            defer params.deinit();
            if (try matchPath(pattern, path, &params, &.{})) {
                expected = index;
                break;
            }
        }
        try std.testing.expectEqual(expected, tree.matches(path, &.{}).first_any);
    }
}

test "route tree cleans up every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkRouteTreeAllocationFailure, .{});
}

fn fuzzRouteTree(_: void, smith: *std.testing.Smith) !void {
    var path_buffer: [256]u8 = undefined;
    const len = smith.sliceWeightedBytes(&path_buffer, &.{
        .rangeAtMost(u8, 0x20, 0x7e, 4),
        .value(u8, '/', 6),
        .rangeAtMost(u8, '0', '9', 3),
    });
    if (len == 0) return;
    path_buffer[0] = '/';
    const path = path_buffer[0..len];

    const patterns = [_][]const u8{
        "/",
        "/users/{id:int}",
        "/users/{name}",
        "/files/file-{name}.json",
        "/assets/{path:path}",
        "/v1/{id:uuid}/events",
    };
    var tree: RouteTree = .{};
    defer tree.deinit(std.testing.allocator);
    for (patterns, 0..) |pattern, index| {
        try tree.add(std.testing.allocator, pattern, .{ .index = index });
    }

    var expected: ?usize = null;
    for (patterns, 0..) |pattern, index| {
        var params = std.StringHashMap([]const u8).init(std.testing.allocator);
        defer params.deinit();
        if (try matchPath(pattern, path, &params, &.{})) {
            expected = index;
            break;
        }
    }
    try std.testing.expectEqual(expected, tree.matches(path, &.{}).first_any);
}

test "route tree agrees with path matching for arbitrary paths" {
    try std.testing.fuzz({}, fuzzRouteTree, .{});
}
