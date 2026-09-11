//! Structured HTTP server lifecycle and connection concurrency.
//!
//! The server owns acceptance, cancellation, connection bounds, and graceful
//! shutdown. The application owns routing and request dispatch.

const std = @import("std");
const applications = @import("applications.zig");

const ZAPI = applications.ZAPI;

/// Server lifecycle state.
pub const State = enum(u8) {
    /// The server has not started.
    initialized,
    /// The listener is accepting connections.
    running,
    /// New connections are stopped while active connections drain.
    draining,
    /// All server work has stopped.
    stopped,
    /// The server returned an unexpected runtime error.
    failed,
};

/// Resource and shutdown limits for `Server`.
pub const Options = struct {
    /// Socket options used by `run` when it creates a listener.
    listen: std.Io.net.IpAddress.ListenOptions = .{ .reuse_address = true },
    /// Optional total number of connections accepted before draining.
    max_connections: ?usize = null,
    /// Maximum number of active connection tasks.
    max_concurrent_connections: usize = 256,
    /// Maximum lifetime of one accepted connection, including keep-alive requests.
    connection_timeout: ?std.Io.Duration = .fromSeconds(120),
    /// Maximum time allowed to receive each request head.
    header_timeout: ?std.Io.Duration = .fromSeconds(10),
    /// Maximum requests served over one keep-alive connection.
    max_requests_per_connection: usize = 1000,
    /// Maximum time spent reading, handling, and writing one request.
    request_timeout: ?std.Io.Duration = .fromSeconds(30),
    /// Time allowed for active connections to drain after acceptance stops.
    graceful_shutdown_timeout: ?std.Io.Duration = .fromSeconds(30),
    /// Whether the HTTP adapter buffers request bodies before dispatch.
    buffer_request_body: bool = true,
};

/// A snapshot of server counters.
pub const Stats = struct {
    /// Total connections accepted by this server.
    accepted_connections: usize,
    /// Connections currently being handled.
    active_connections: usize,
    /// Connections canceled after reaching `connection_timeout`.
    timed_out_connections: usize,
    /// Request heads canceled after reaching `header_timeout`.
    timed_out_headers: usize,
    /// Requests canceled after reaching `request_timeout`.
    timed_out_requests: usize,
    /// Connections closed after an application or protocol error.
    failed_connections: usize,
    /// Whether graceful shutdown expired and canceled active connections.
    forced_shutdown: bool,
};

/// A single-use structured server runtime.
///
/// The `Server` value must outlive `run` or `runListener`. `requestShutdown` is
/// thread-safe and wakes a blocked accept operation.
pub const Server = struct {
    app: *ZAPI,
    io: std.Io,
    options: Options,
    shutdown_event: std.Io.Event = .unset,
    lifecycle: std.atomic.Value(State) = .init(.initialized),
    accepted_connections: std.atomic.Value(usize) = .init(0),
    active_connections: std.atomic.Value(usize) = .init(0),
    timed_out_connections: std.atomic.Value(usize) = .init(0),
    timed_out_headers: std.atomic.Value(usize) = .init(0),
    timed_out_requests: std.atomic.Value(usize) = .init(0),
    failed_connections: std.atomic.Value(usize) = .init(0),
    forced_shutdown: std.atomic.Value(bool) = .init(false),

    /// Initializes a server for one application and I/O implementation.
    pub fn init(app: *ZAPI, io: std.Io, options: Options) Server {
        return .{
            .app = app,
            .io = io,
            .options = options,
        };
    }

    /// Returns the current lifecycle state.
    pub fn state(self: *const Server) State {
        return self.lifecycle.load(.acquire);
    }

    /// Returns a consistent-enough atomic snapshot of runtime counters.
    pub fn stats(self: *const Server) Stats {
        return .{
            .accepted_connections = self.accepted_connections.load(.acquire),
            .active_connections = self.active_connections.load(.acquire),
            .timed_out_connections = self.timed_out_connections.load(.acquire),
            .timed_out_headers = self.timed_out_headers.load(.acquire),
            .timed_out_requests = self.timed_out_requests.load(.acquire),
            .failed_connections = self.failed_connections.load(.acquire),
            .forced_shutdown = self.forced_shutdown.load(.acquire),
        };
    }

    /// Stops accepting new connections and begins graceful draining.
    pub fn requestShutdown(self: *Server) void {
        while (true) {
            const current = self.lifecycle.load(.acquire);
            switch (current) {
                .initialized, .running => {
                    if (self.lifecycle.cmpxchgWeak(current, .draining, .acq_rel, .acquire) == null) break;
                },
                .draining, .stopped, .failed => break,
            }
        }
        self.shutdown_event.set(self.io);
    }

    /// Creates a listener, serves connections, and closes the listener before returning.
    pub fn run(self: *Server, address: std.Io.net.IpAddress) !void {
        try self.begin();
        var listener = address.listen(self.io, self.options.listen) catch |err| {
            self.lifecycle.store(.failed, .release);
            return err;
        };
        defer listener.deinit(self.io);
        return self.runStarted(&listener);
    }

    /// Serves with a caller-owned listener.
    pub fn runListener(self: *Server, listener: *std.Io.net.Server) !void {
        try self.begin();
        return self.runStarted(listener);
    }

    fn begin(self: *Server) !void {
        if (self.options.max_concurrent_connections == 0) return error.InvalidConcurrencyLimit;
        if (self.options.max_requests_per_connection == 0) return error.InvalidRequestLimit;
        if (self.lifecycle.cmpxchgStrong(.initialized, .running, .acq_rel, .acquire)) |current| {
            return switch (current) {
                .draining, .stopped => error.ServerStopped,
                .running, .failed => error.ServerAlreadyStarted,
                .initialized => unreachable,
            };
        }
    }

    fn runStarted(self: *Server, listener: *std.Io.net.Server) !void {
        self.app.startup() catch |err| {
            self.lifecycle.store(.failed, .release);
            return err;
        };
        errdefer self.lifecycle.store(.failed, .release);
        errdefer self.app.shutdown() catch {};

        var connection_group: std.Io.Group = .init;
        defer connection_group.cancel(self.io);
        var permits = std.Io.Semaphore{ .permits = self.options.max_concurrent_connections };

        self.acceptConnections(listener, &connection_group, &permits) catch |err| switch (err) {
            error.Canceled => {
                self.lifecycle.store(.failed, .release);
                return error.Canceled;
            },
            else => {
                self.lifecycle.store(.failed, .release);
                return err;
            },
        };

        self.lifecycle.store(.draining, .release);
        try self.drainConnections(&connection_group);
        self.app.shutdown() catch |err| {
            self.lifecycle.store(.failed, .release);
            return err;
        };
        self.lifecycle.store(.stopped, .release);
    }

    fn acceptConnections(
        self: *Server,
        listener: *std.Io.net.Server,
        connection_group: *std.Io.Group,
        permits: *std.Io.Semaphore,
    ) !void {
        while (!self.shutdown_event.isSet()) {
            if (self.options.max_connections) |maximum| {
                if (self.accepted_connections.load(.acquire) >= maximum) return;
            }

            if (!try self.acquirePermit(permits)) return;
            const stream = (try self.acceptOrShutdown(listener)) orelse {
                permits.post(self.io);
                return;
            };

            _ = self.accepted_connections.fetchAdd(1, .acq_rel);
            _ = self.active_connections.fetchAdd(1, .acq_rel);
            connection_group.concurrent(self.io, serveConnection, .{ self, stream, permits }) catch |err| {
                _ = self.active_connections.fetchSub(1, .acq_rel);
                permits.post(self.io);
                stream.close(self.io);
                return err;
            };
        }
    }

    fn acquirePermit(self: *Server, permits: *std.Io.Semaphore) !bool {
        const Result = union(enum) {
            permit: std.Io.Cancelable!void,
            shutdown: std.Io.Cancelable!void,
        };
        var result_buffer: [2]Result = undefined;
        var select = std.Io.Select(Result).init(self.io, &result_buffer);
        defer while (select.cancel()) |pending| switch (pending) {
            .permit => |result| if (result) |_| permits.post(self.io) else |_| {},
            .shutdown => {},
        };

        select.async(.permit, waitForPermit, .{ permits, self.io });
        select.async(.shutdown, waitForShutdown, .{ &self.shutdown_event, self.io });

        return switch (try select.await()) {
            .permit => |result| permit: {
                try result;
                break :permit true;
            },
            .shutdown => |result| shutdown: {
                try result;
                break :shutdown false;
            },
        };
    }

    fn acceptOrShutdown(self: *Server, listener: *std.Io.net.Server) !?std.Io.net.Stream {
        const Result = union(enum) {
            stream: std.Io.net.Server.AcceptError!std.Io.net.Stream,
            shutdown: std.Io.Cancelable!void,
        };
        var result_buffer: [2]Result = undefined;
        var select = std.Io.Select(Result).init(self.io, &result_buffer);
        defer while (select.cancel()) |pending| switch (pending) {
            .stream => |result| if (result) |stream| stream.close(self.io) else |_| {},
            .shutdown => {},
        };

        select.async(.stream, acceptConnection, .{ listener, self.io });
        select.async(.shutdown, waitForShutdown, .{ &self.shutdown_event, self.io });

        return switch (try select.await()) {
            .stream => |result| try result,
            .shutdown => |result| shutdown: {
                try result;
                break :shutdown null;
            },
        };
    }

    fn drainConnections(self: *Server, connection_group: *std.Io.Group) !void {
        const timeout = self.options.graceful_shutdown_timeout orelse return connection_group.await(self.io);
        const Result = union(enum) {
            drained: void,
            timeout: std.Io.Cancelable!void,
        };
        var result_buffer: [2]Result = undefined;
        var select = std.Io.Select(Result).init(self.io, &result_buffer);
        defer select.cancelDiscard();

        select.async(.drained, awaitConnections, .{ connection_group, self.io });
        select.async(.timeout, waitForTimeout, .{ timeout, self.io });

        switch (try select.await()) {
            .drained => {},
            .timeout => |result| {
                try result;
                self.forced_shutdown.store(true, .release);
            },
        }
    }

    fn serveConnection(self: *Server, stream: std.Io.net.Stream, permits: *std.Io.Semaphore) std.Io.Cancelable!void {
        defer {
            _ = self.active_connections.fetchSub(1, .acq_rel);
            permits.post(self.io);
            stream.close(self.io);
        }

        const timeout = self.options.connection_timeout orelse {
            self.app.handleStreamWithOptions(self.io, stream, .{
                .buffer_request_body = self.options.buffer_request_body,
                .max_requests = self.options.max_requests_per_connection,
                .header_timeout = self.options.header_timeout,
                .request_timeout = self.options.request_timeout,
            }) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                error.HeaderTimeout => {
                    _ = self.timed_out_headers.fetchAdd(1, .acq_rel);
                    return;
                },
                error.RequestTimeout => {
                    _ = self.timed_out_requests.fetchAdd(1, .acq_rel);
                    return;
                },
                else => {
                    _ = self.failed_connections.fetchAdd(1, .acq_rel);
                    return;
                },
            };
            return;
        };

        const Result = union(enum) {
            handled: void,
            timeout: std.Io.Cancelable!void,
        };
        var result_buffer: [2]Result = undefined;
        var select = std.Io.Select(Result).init(self.io, &result_buffer);
        defer select.cancelDiscard();

        select.async(.handled, handleConnection, .{
            self,
            stream,
            self.options.buffer_request_body,
            self.options.max_requests_per_connection,
            self.options.request_timeout,
        });
        select.async(.timeout, waitForTimeout, .{ timeout, self.io });

        switch (try select.await()) {
            .handled => {},
            .timeout => |result| {
                try result;
                _ = self.timed_out_connections.fetchAdd(1, .acq_rel);
            },
        }
    }
};

fn acceptConnection(listener: *std.Io.net.Server, io: std.Io) std.Io.net.Server.AcceptError!std.Io.net.Stream {
    return listener.accept(io);
}

fn waitForPermit(permits: *std.Io.Semaphore, io: std.Io) std.Io.Cancelable!void {
    return permits.wait(io);
}

fn waitForShutdown(event: *std.Io.Event, io: std.Io) std.Io.Cancelable!void {
    return event.wait(io);
}

fn waitForTimeout(timeout: std.Io.Duration, io: std.Io) std.Io.Cancelable!void {
    return std.Io.sleep(io, timeout, .awake);
}

fn awaitConnections(group: *std.Io.Group, io: std.Io) void {
    group.await(io) catch {};
}

fn handleConnection(
    server: *Server,
    stream: std.Io.net.Stream,
    buffer_request_body: bool,
    max_requests: usize,
    request_timeout: ?std.Io.Duration,
) void {
    server.app.handleStreamWithOptions(server.io, stream, .{
        .buffer_request_body = buffer_request_body,
        .max_requests = max_requests,
        .header_timeout = server.options.header_timeout,
        .request_timeout = request_timeout,
    }) catch |err| switch (err) {
        error.Canceled => {},
        error.HeaderTimeout => _ = server.timed_out_headers.fetchAdd(1, .acq_rel),
        error.RequestTimeout => _ = server.timed_out_requests.fetchAdd(1, .acq_rel),
        else => _ = server.failed_connections.fetchAdd(1, .acq_rel),
    };
}

const testing = std.testing;

fn waitUntilRunning(server: *const Server, io: std.Io) !void {
    while (server.state() == .initialized) try std.Io.sleep(io, .fromMilliseconds(1), .awake);
}

fn slowRequest(ctx: *applications.Context) !struct { completed: bool } {
    try std.Io.sleep(try ctx.ioHandle(), .fromSeconds(1), .awake);
    return .{ .completed = true };
}

const ConnectionGate = struct {
    release: std.Io.Event = .unset,
};

fn gatedRequest(ctx: *applications.Context) !struct { completed: bool } {
    const gate = ctx.state(ConnectionGate);
    try gate.release.wait(try ctx.ioHandle());
    return .{ .completed = true };
}

fn writeCloseRequest(stream: std.Io.net.Stream, io: std.Io) !void {
    var write_buffer: [512]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);
    try writer.interface.writeAll(
        "GET / HTTP/1.1\r\n" ++
            "host: localhost\r\n" ++
            "connection: close\r\n" ++
            "\r\n",
    );
    try writer.interface.flush();
    try stream.shutdown(io, .send);
}

test "requestShutdown wakes a blocked accept operation" {
    const io = testing.io;
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();

    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try address.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);

    var server = Server.init(&app, io, .{});
    var future = try io.concurrent(Server.runListener, .{ &server, &listener });
    try waitUntilRunning(&server, io);
    server.requestShutdown();
    try future.await(io);

    try testing.expectEqual(State.stopped, server.state());
    try testing.expectEqual(@as(usize, 0), server.stats().accepted_connections);
}

test "connection permits bound accepted work" {
    const io = testing.io;
    var gate: ConnectionGate = .{};
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    app.setState(&gate);
    try app.route(applications.Route.get("/", gatedRequest, .{}));

    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try address.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);

    var server = Server.init(&app, io, .{
        .max_connections = 2,
        .max_concurrent_connections = 1,
    });
    var future = try io.concurrent(Server.runListener, .{ &server, &listener });
    try waitUntilRunning(&server, io);

    var first = try listener.socket.address.connect(io, .{ .mode = .stream, .protocol = .tcp });
    defer first.close(io);
    try writeCloseRequest(first, io);
    while (server.stats().active_connections == 0) try std.Io.sleep(io, .fromMilliseconds(1), .awake);

    var second = try listener.socket.address.connect(io, .{ .mode = .stream, .protocol = .tcp });
    defer second.close(io);
    try writeCloseRequest(second, io);
    try std.Io.sleep(io, .fromMilliseconds(10), .awake);
    try testing.expectEqual(@as(usize, 1), server.stats().accepted_connections);

    gate.release.set(io);
    try future.await(io);

    try testing.expectEqual(State.stopped, server.state());
    try testing.expectEqual(@as(usize, 2), server.stats().accepted_connections);
    try testing.expectEqual(@as(usize, 0), server.stats().active_connections);
}

test "connection timeout cancels an idle connection" {
    const io = testing.io;
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();

    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try address.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);

    var server = Server.init(&app, io, .{
        .max_connections = 1,
        .connection_timeout = .fromMilliseconds(10),
        .header_timeout = null,
    });
    var future = try io.concurrent(Server.runListener, .{ &server, &listener });
    try waitUntilRunning(&server, io);

    var stream = try listener.socket.address.connect(io, .{ .mode = .stream, .protocol = .tcp });
    defer stream.close(io);
    try future.await(io);

    const snapshot = server.stats();
    try testing.expectEqual(State.stopped, server.state());
    try testing.expectEqual(@as(usize, 1), snapshot.accepted_connections);
    try testing.expectEqual(@as(usize, 0), snapshot.active_connections);
    try testing.expectEqual(@as(usize, 1), snapshot.timed_out_connections);
}

test "header timeout cancels an idle request" {
    const io = testing.io;
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();

    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try address.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);

    var server = Server.init(&app, io, .{
        .max_connections = 1,
        .connection_timeout = null,
        .header_timeout = .fromMilliseconds(10),
    });
    var future = try io.concurrent(Server.runListener, .{ &server, &listener });
    try waitUntilRunning(&server, io);

    var stream = try listener.socket.address.connect(io, .{ .mode = .stream, .protocol = .tcp });
    defer stream.close(io);
    try future.await(io);

    try testing.expectEqual(State.stopped, server.state());
    try testing.expectEqual(@as(usize, 1), server.stats().timed_out_headers);
    try testing.expectEqual(@as(usize, 0), server.stats().failed_connections);
}

test "request timeout cancels request handling" {
    const io = testing.io;
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();
    try app.route(applications.Route.get("/slow", slowRequest, .{}));

    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try address.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);

    var server = Server.init(&app, io, .{
        .max_connections = 1,
        .request_timeout = .fromMilliseconds(10),
    });
    var future = try io.concurrent(Server.runListener, .{ &server, &listener });
    try waitUntilRunning(&server, io);

    var stream = try listener.socket.address.connect(io, .{ .mode = .stream, .protocol = .tcp });
    defer stream.close(io);
    var write_buffer: [512]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);
    try writer.interface.writeAll(
        "GET /slow HTTP/1.1\r\n" ++
            "host: localhost\r\n" ++
            "connection: close\r\n" ++
            "\r\n",
    );
    try writer.interface.flush();
    try future.await(io);

    try testing.expectEqual(State.stopped, server.state());
    try testing.expectEqual(@as(usize, 1), server.stats().timed_out_requests);
    try testing.expectEqual(@as(usize, 0), server.stats().failed_connections);
}

test "graceful shutdown deadline cancels active connections" {
    const io = testing.io;
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();

    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try address.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);

    var server = Server.init(&app, io, .{
        .max_concurrent_connections = 1,
        .graceful_shutdown_timeout = .fromMilliseconds(10),
    });
    var future = try io.concurrent(Server.runListener, .{ &server, &listener });
    try waitUntilRunning(&server, io);

    var stream = try listener.socket.address.connect(io, .{ .mode = .stream, .protocol = .tcp });
    defer stream.close(io);
    while (server.stats().accepted_connections == 0) try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    server.requestShutdown();
    try future.await(io);

    try testing.expectEqual(State.stopped, server.state());
    try testing.expectEqual(@as(usize, 0), server.stats().active_connections);
    try testing.expect(server.stats().forced_shutdown);
}

test "runListener rejects an empty concurrency limit" {
    const io = testing.io;
    var app = ZAPI.init(testing.allocator, .{});
    defer app.deinit();

    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try address.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);

    var server = Server.init(&app, io, .{ .max_concurrent_connections = 0 });
    try testing.expectError(error.InvalidConcurrencyLimit, server.runListener(&listener));
    try testing.expectEqual(State.initialized, server.state());

    var request_limited_server = Server.init(&app, io, .{ .max_requests_per_connection = 0 });
    try testing.expectError(error.InvalidRequestLimit, request_limited_server.runListener(&listener));
    try testing.expectEqual(State.initialized, request_limited_server.state());
}
