//! Background tasks attached to an HTTP response.
//! Tasks borrow their opaque context and run after the response is sent.

const std = @import("std");

/// A background task callback.
pub const BackgroundTaskFn = *const fn (?*anyopaque) anyerror!void;

/// One callback and its borrowed context.
pub const BackgroundTask = struct {
    run: BackgroundTaskFn,
    context: ?*anyopaque = null,
};

/// An owned collection of background tasks.
pub const BackgroundTasks = struct {
    allocator: std.mem.Allocator,
    tasks: std.ArrayList(BackgroundTask) = .empty,

    /// Creates an empty task collection.
    pub fn init(allocator: std.mem.Allocator) BackgroundTasks {
        return .{ .allocator = allocator };
    }

    /// Releases the task collection without running it.
    pub fn deinit(self: *BackgroundTasks) void {
        self.tasks.deinit(self.allocator);
    }

    /// Adds a callback and borrowed context.
    pub fn addTask(self: *BackgroundTasks, run: BackgroundTaskFn, context: ?*anyopaque) !void {
        try self.tasks.append(self.allocator, .{
            .run = run,
            .context = context,
        });
    }

    /// Adds an existing task.
    pub fn append(self: *BackgroundTasks, task: BackgroundTask) !void {
        try self.tasks.append(self.allocator, task);
    }

    /// Returns the number of queued tasks.
    pub fn len(self: BackgroundTasks) usize {
        return self.tasks.items.len;
    }

    /// Returns whether no tasks are queued.
    pub fn isEmpty(self: BackgroundTasks) bool {
        return self.tasks.items.len == 0;
    }

    /// Returns tasks borrowed until the collection is mutated or deinitialized.
    pub fn items(self: BackgroundTasks) []const BackgroundTask {
        return self.tasks.items;
    }

    /// Transfers ownership of the task slice to the caller.
    pub fn toOwnedSlice(self: *BackgroundTasks) ![]const BackgroundTask {
        const owned = try self.tasks.toOwnedSlice(self.allocator);
        self.tasks = .empty;
        return owned;
    }
};
