---
icon: lucide/map
---

# Roadmap

`zapi` is useful today for small APIs and framework design experiments, but it is still experimental.

## Implemented

- Starlette-style route objects, routers, and mixed runtime route lists with `Router.init` and `includeRoutes`.
- Built-in and app-level custom path convertors.
- Typed request validation for common inputs.
- Lenient browser-compatible incoming cookie parsing, with Starlette-derived edge-case coverage.
- OpenAPI 3.1, Swagger UI, and ReDoc generated out of the box.
- Runtime `CONNECT` routes, omitted from OpenAPI because the specification has no `connect` path-item operation.
- Mounted applications and host routing, including `Route.mount` and `Route.host` registration specs in mixed route lists.
- Static files.
- Template rendering helpers and template responses.
- Buffered server-sent event response helpers.
- Middleware helpers.
- Background task accumulators, lifespan hooks, exception handlers, and status handlers.
- Buffered request body streaming with `Request.stream` and adapter-backed incremental body streaming with `Request.streamReader`.
- Transport-level streaming responses with `StreamingResponse` through the std.http adapter.
- WebSocket routes through the std.http adapter.
- In-process testing with response URL tracking, redirect target helpers, redirect history, method-level redirect controls, typed JSON parsing, typed query/form/JSON request helpers, scripted WebSocket exchanges with text, binary, and JSON message helpers, domain/path-scoped cookies, and server-exception controls.
- A `std.http.Server.Request` adapter with buffered and opt-in streaming bodies.
- A structured `std.Io` server with bounded connections, request scopes, deadlines, counters, and graceful shutdown.

## Not Yet

- TLS and HTTP/2 transport adapters.
- A complete Starlette compatibility test port.

These are the main remaining high-level gaps before the framework can claim broader Starlette-style compatibility.
