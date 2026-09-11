---
icon: lucide/layers
---

# Middleware

Middleware can run at the app level or on a route.

```zig
try app.middleware(zapi.requestIdMiddleware(.{}));
try app.middleware(zapi.securityHeadersMiddleware(.{}));
```

Route middleware is declared next to the route.

```zig
zapi.Route.get("/private", private, .{
    .middlewares = &.{
        zapi.requestIdMiddleware(.{}),
    },
})
```

## Built-In Helpers

`zapi` includes middleware helpers for:

- CORS
- trusted hosts
- HTTPS redirects
- proxy headers
- request IDs
- security headers
- GZip
- method override
- request body limits
- signed cookie sessions
- static response headers
- merged `Vary` headers

GZip honors `Accept-Encoding` q-values, so `gzip;q=0` prevents compression even when `*` is also present.

CORS accepts exact origins with `allow_origins`, simple wildcard origin patterns with `allow_origin_patterns`, a typed method list with `allow_methods`, or every supported method with `allow_all_methods = true`.
Safelisted request headers are always allowed in CORS preflights; `allow_headers` adds custom headers.
Rejected CORS preflights include the allowed preflight headers that could be determined.
Wildcard CORS origins are sent as `*` for anonymous requests, but cookie-bearing requests mirror the request `Origin` and add `Vary: Origin`, matching Starlette's credentialed-request behavior.

Trusted host middleware rejects requests without an allowed `Host`. With `www_redirect = true`, it redirects `www.example.com` to `example.com` when the bare host is allowed, and redirects `example.com` to `www.example.com` when only the `www` host is allowed. Redirects preserve the request port.

## State

Middleware can attach typed request-scoped values for handlers to read later.

```zig
const TraceState = struct {
    trace_id: []const u8,
};

fn traceMiddleware(ctx: *zapi.MiddlewareContext, request: zapi.Request) !zapi.Response {
    var state = TraceState{
        .trace_id = request.header("x-trace-id") orelse "generated",
    };
    var forwarded = request;
    forwarded.setState(&state);
    return ctx.next(forwarded);
}
```

Handlers read required request state with `ctx.requestState(T)`, or optional request state with `ctx.maybeRequestState(T)`.

```zig
fn endpoint(ctx: *zapi.Context) !struct { trace_id: ?[]const u8 } {
    const state = ctx.maybeRequestState(TraceState) orelse {
        return .{ .trace_id = null };
    };
    return .{ .trace_id = state.trace_id };
}
```

App state is available with `ctx.state(T)` inside handlers and `app.state(T)` outside them.
Use `ctx.maybeState(T)` or `app.maybeState(T)` when the app state may not be installed.
