---
icon: lucide/workflow
---

# Async Runtime Plan

Use structured connection concurrency today:

```zig
const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 8000);
try app.serve(env.io, address, .{
    .concurrent_connections = true,
    .max_concurrent_connections = 256,
});
```

`zapi` uses Zig 0.16's `std.Io` model. Handler functions remain synchronous-looking. An I/O operation can suspend through the request-scoped `std.Io` implementation without a custom future type or an `async` and `await` API.

Inside a handler, use `ctx.ioHandle()` when you need the request-scoped I/O implementation:

```zig
fn endpoint(ctx: *zapi.Context) !struct { ready: bool } {
    const io = try ctx.ioHandle();
    _ = io;
    return .{ .ready = true };
}
```

## Phase 1: Structured connections

Status: in progress.

- Pass `std.Io` through each request instead of mutating application options while serving.
- Run concurrent connections in an `std.Io.Group`.
- Bound active connection tasks with `max_concurrent_connections`.
- Cancel and await every connection task before the server returns.
- Keep sequential serving available for deterministic tests and constrained environments.

## Phase 2: Server lifecycle

Introduce a `Server` value that owns listener lifetime, connection tasks, and shutdown state.

- Replace accept-loop polling with cancellation that wakes a blocked accept operation.
- Separate stopping new connections from draining active connections.
- Add graceful-shutdown and forced-shutdown deadlines.
- Report startup, serving, draining, stopped, and failed states explicitly.
- Keep `ZAPI` immutable while requests are active.

## Phase 3: Deadlines and cancellation

Make cancellation part of the request contract.

- Add header, body, handler, idle, and write deadlines.
- Propagate client disconnects and server shutdown into request work.
- Give each request a structured task group for child operations.
- Cancel unfinished child tasks before request-owned memory is released.
- Define which background tasks drain and which are canceled during shutdown.

## Phase 4: Streaming and backpressure

Make request and response streaming bounded by default.

- Preserve pull-based request body reads.
- Bound queued response data.
- Stop producers when the client disconnects or stops reading.
- Flush streaming responses explicitly through `std.Io.Writer`.
- Add slow-reader, slow-writer, partial-body, and cancellation tests.

## Phase 5: Runtime and transport adapters

Keep application code independent from one event loop implementation.

- Support the standard threaded `std.Io` implementation first.
- Validate alternative `std.Io` implementations without changing handler APIs.
- Keep HTTP protocol parsing separate from scheduling.
- Add TLS and newer HTTP protocols through transport adapters instead of application-level branches.

## Completion criteria

The async model is ready for production evaluation when:

- Request handling performs no shared application mutation.
- Concurrency and memory growth have explicit bounds.
- Cancellation reaches blocked accepts, reads, writes, and child tasks.
- Graceful shutdown has deterministic tests with active and idle connections.
- Streaming applies backpressure under slow clients.
- Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall tests pass.
- Long-running soak tests show stable memory and task counts.
- Benchmarks publish throughput, latency percentiles, errors, and configuration.
