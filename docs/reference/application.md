---
icon: lucide/app-window
---

# Application

Create an app with `App.init`.

```zig
var app = zapi.App.init(allocator, .{
    .title = "My API",
    .version = "1.0.0",
});
defer app.deinit();
```

Useful options include:

- `title`
- `version`
- `description`
- `terms_of_service`
- `contact`
- `license`
- `openapi_servers`
- `openapi_tags`
- `external_docs`
- `openapi_url`
- `docs_url`
- `oauth2_redirect_url`
- `redoc_url`
- `max_request_body_size`
- `redirect_slashes`
- `io`

Set `openapi_url`, `docs_url`, `oauth2_redirect_url`, or `redoc_url` to `null` to disable those built-in routes.

`serve` and `serveListener` use buffered request bodies by default. Set `buffer_request_body = false` when handlers should consume the std.http adapter body through `Request.streamReader`.

## Routing

Include routers with `includeRouter`.

```zig
try app.includeRouter(router);
```

Use top-level route constructors such as `zapi.get`, `zapi.post`, `zapi.websocket`, and `zapi.mount` when building Starlette-style route lists. The same constructors, plus `options`, `head`, `trace`, `connect`, and `host`, are also available under `zapi.Route`. Use `zapi.methods` or `zapi.Route.methods` when one handler should answer several HTTP methods.

```zig
try app.route(zapi.methods("/health", &.{ .GET, .HEAD }, healthCheck, .{}));
```

Register custom path convertors with `addPathConvertor` before adding routes, mount prefixes, or host patterns that use them. Convertors are app-local, constrain matching and reverse URL generation, and leave handler parsing to typed `Path(T)` fields.

WebSocket routes run through the std.http adapter, use `WebSocketContext`, support path params and URL reversing, and are omitted from OpenAPI.

`GET` routes automatically handle `HEAD` when no explicit `HEAD` route exists. Routes also answer `OPTIONS` automatically with a deduplicated `Allow` header unless an explicit `OPTIONS` route is registered. `405 Method Not Allowed` responses include the same `Allow` header.

`Redirect` responses quote unsafe `Location` bytes, so spaces and non-ASCII path text are sent as percent-encoded URLs.

`Template` responses require an app `io` handle. They load the configured path from `dir`, render `{{ name }}` with HTML escaping, and render `{{{ name }}}` or values created with `templateHtml` as trusted HTML.

`EventStream` responses are buffered server-sent event responses. They emit `text/event-stream`, split multi-line data into repeated `data:` lines, and support comments, event names, IDs, and retry delays.

`StreamingResponse` responses write through a callback. `App.handle` collects them for in-process tests, while the std.http adapter sends them with `Transfer-Encoding: chunked`. The optional `context` pointer must outlive the response writer.

`File` responses require an app `io` handle. They infer `Content-Type` from `filename` when present, then from `path`, and use an explicit `content_type` when one is set. Single and multipart range requests and background tasks are supported. `HEAD`, `304`, and unsatisfiable range responses use file metadata without reading the body. Malformed `Range` headers return plain-text `400 Bad Request`; valid but unsatisfiable ranges return `416 Range Not Satisfiable`. Explicit `Content-Disposition` and `Accept-Ranges` headers are preserved instead of being replaced by generated defaults.

`BackgroundTasks` collects several background tasks before transferring them into `ResponsePayload.background_tasks` or `File.background_tasks`.

```zig
var tasks = zapi.BackgroundTasks.init(ctx.allocator);
errdefer tasks.deinit();
try tasks.addTask(sendEmail, ctx.state(AppState));

return zapi.ResponsePayload{
    .body = "queued",
    .background_tasks = try tasks.toOwnedSlice(),
    .owned_background_tasks = true,
};
```

Cookie helpers default `SameSite` to `lax`, like Starlette. Set `.same_site = null` when a cookie should omit the attribute.

Mount sub-applications with `mount`.

```zig
try app.mount("/api", &api_app);
```

Or use a mount route spec when you want the registration to sit next to other route values.

```zig
try app.route(zapi.Route.mount("/api", &api_app, .{ .name = "api" }));
```

Use `mountNamed` when the mount should namespace URL reversing.

```zig
try api_app.mountNamed("/nested", "nested", &nested_app);
try app.mountNamed("/api", "api", &api_app);
const docs = try app.urlPathFor("api", .{ .path = "/docs" });
const user = try app.urlPathFor("api:get_user", .{ .id = 42 });
const nested_docs = try app.urlPathFor("api:nested", .{ .path = "/docs" });
```

Mount reverse paths preserve `/` separators and percent-encode unsafe bytes, so `.{ .path = "/docs/search page" }` renders as `/api/docs/search%20page`.

Handlers inside mounted apps can reverse URLs through the outer app. This keeps top-level, sibling, and namespaced route names available from a mounted handler, and `ctx.urlFor` adds the request's external root path when the app runs behind a prefix.

Route to applications by host with `host`.

```zig
try app.host("api.example.org", &api_app);
```

Host route specs use the same runtime registration style.

```zig
try app.route(zapi.Route.host("api.example.org", &api_app, .{ .name = "api" }));
```

Use `hostNamed` when host routing should support absolute URL reversing.

```zig
try app.hostNamed("api.example.org", "api", &api_app);
const user = try app.urlForHost("api:get_user", .{ .id = 42 }, "https");
```

Like Starlette, host routing ignores the port in incoming `Host` headers when matching, but a port configured in `hostNamed`, such as `api.example.org:3600`, is preserved by `urlForHost`.

Handlers inside hosted apps can reverse local route names with `ctx.urlFor`, and can also use the host namespace such as `api:get_user` when they need the outer route name.

Use `Router.init` when a Starlette-style route list should mix endpoints, route groups, WebSockets, mounts, and hosts.

```zig
const api_routes = zapi.Router.init(.{
    .prefix = "/v1",
    .middlewares = &.{authMiddleware},
    .routes = .{
        zapi.Route.get("/health", healthCheck, .{}),
        zapi.Route.methods("/status", &.{ .GET, .HEAD }, healthCheck, .{}),
        zapi.Route.mount("/api", &api_app, .{ .name = "api" }),
        zapi.Route.host("api.example.org", &api_app, .{ .name = "api_host" }),
    },
});

try app.includeRouter(api_routes);
```

Use `includeRoutes` for the same shape when you do not need to name the router value first. `app.route(Route.mount(...))`, `app.route(Route.host(...))`, and the lower-level `RouterSpec.mounts` and `RouterSpec.hosts` fields remain available for direct registration.

Mount `StaticFiles` when a directory should serve assets. Static paths are percent-decoded and validated before reads. Static responses infer common asset content types, support validators and single or multipart byte ranges, answer `HEAD` from metadata, answer `GET` with file bodies, answer automatic `OPTIONS`, return plain-text `400` for malformed ranges, return plain-text `404` and `405` errors, return `401 Unauthorized` for permission failures, and can optionally serve HTML indexes.

Add app-level middleware with `middleware` or `addMiddleware`.

```zig
try app.middleware(zapi.requestIdMiddleware(.{}));
try app.addMiddleware(zapi.securityHeadersMiddleware(.{}));
```

## URL Reversing

Name routes to generate URLs later.

```zig
const users = zapi.Router.init(.{
    .routes = .{
        zapi.Route.get("/users/{id:int}", getUser, .{ .name = "get_user" }),
    },
});

const path = try app.urlPathFor("get_user", .{ .id = 1 });
defer allocator.free(path);
```
