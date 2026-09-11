---
icon: lucide/route
---

# zapi

`zapi` is an experimental web framework for Zig 0.16.

It is built around a small idea:

Define your API once, as normal Zig functions and route values. Then use that same definition for routing, validation, OpenAPI 3.1, Swagger UI, ReDoc, and tests.

```zig
const router = zapi.Router.init(.{
    .routes = .{
        zapi.Route.get("/", hello, .{ .summary = "Hello world" }),
        zapi.Route.post("/users", createUser, .{
            .status = .created,
            .summary = "Create user",
            .tags = &.{"users"},
        }),
    },
});

try app.includeRouter(router);
```

There are no decorators in Zig, so `zapi` uses Starlette-style route objects instead. The result is explicit, composable, and friendly to compile-time inspection.

## What You Get

- Route lists and nested routers.
- Typed path, query, header, cookie, JSON body, and form inputs.
- JSON, text, HTML, bytes, file, redirect, empty, and problem responses.
- OpenAPI 3.1 generated from endpoint signatures.
- Swagger UI at `/docs` and ReDoc at `/redoc` by default.
- In-process testing with `App.handle`, `App.handleOrRaise`, `Request.builder`, and `TestClient`.
- Middleware for CORS, trusted hosts, HTTPS redirects, proxy headers, request IDs, security headers, GZip, method override, request body limits, sessions, and static response headers.
- Mounted applications, host routing, static files, buffered and adapter-backed request body streaming, lifespan hooks, background tasks, and exception handlers.

## Install

Add `zapi` as a package dependency, then import the module in your executable.

```zig
const zapi = @import("zapi");
```

For this repository, run the example directly:

```sh
zig build run-example
```

## Start Here

Read [First Steps](tutorial/first-steps.md) to build a tiny API with two endpoints, automatic validation, and OpenAPI docs.
