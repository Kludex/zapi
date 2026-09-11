---
icon: lucide/sparkles
---

# First Steps

Create an app, write normal Zig functions, then register them as route objects.

```zig
const std = @import("std");
const zapi = @import("zapi");

const User = struct {
    id: u64,
    email: []const u8,
};

const CreateUser = struct {
    email: []const u8,
};

fn hello(ctx: *zapi.Context) !struct { message: []const u8 } {
    _ = ctx;
    return .{ .message = "Hello from Zig" };
}

fn createUser(ctx: *zapi.Context, body: zapi.Body(CreateUser)) !User {
    _ = ctx;
    return .{ .id = 1, .email = body.value.email };
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();

    var app = zapi.App.init(gpa.allocator(), .{
        .title = "Hello Zapi",
        .version = "0.1.0",
    });
    defer app.deinit();

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

    var response = try app.handle(zapi.Request.init(.GET, "/openapi.json"));
    defer response.deinit(gpa.allocator());

    std.debug.print("{s}\n", .{response.body.items});
}
```

Run it:

```sh
zig build run-example
```

The app automatically serves:

- `/openapi.json` for the generated OpenAPI 3.1 schema.
- `/docs` for Swagger UI.
- `/redoc` for ReDoc.

## Routes Are Data

Routes are values, so a router can contain routes and other routers.

```zig
const users = comptime zapi.Router.init(.{
    .prefix = "/users",
    .tags = &.{"users"},
    .routes = .{
        zapi.Route.get("/", listUsers, .{ .summary = "List users" }),
        zapi.Route.get("/{id:int}", getUser, .{
            .summary = "Get user",
            .name = "get_user",
        }),
    },
});

const api = comptime zapi.Router.init(.{
    .prefix = "/api",
    .routes = .{
        users,
        zapi.get("/status", status, .{ .summary = "API status" }),
    },
});

try app.includeRouter(api);
```

This is close to Starlette's route-list style, but with Zig types available at compile time for validation and schema generation.

Mounts and hosts are route values too, so a sub-application can sit next to endpoint routes.

```zig
const services = zapi.Router.init(.{
    .prefix = "/v1",
    .routes = .{
        zapi.get("/health", healthCheck, .{}),
        zapi.mount("/api", &api_app, .{ .name = "api" }),
    },
});

try app.includeRouter(services);
```

Use `Route.websocket` for WebSocket endpoints served through the std.http adapter. WebSocket routes can live in the same router route list as HTTP routes, support path params and URL reversing, and are omitted from OpenAPI.

```zig
fn chat(ctx: *zapi.WebSocketContext) !void {
    const message = try ctx.readSmallMessage();
    try ctx.sendText(message.data);
}

const realtime = zapi.Router.init(.{
    .routes = .{
        zapi.Route.websocket("/ws/{room}", chat, .{ .name = "chat" }),
    },
});
```

## Response Helpers

Handlers can return plain structs for JSON, or explicit response helpers such as `zapi.Text`, `zapi.Html`, `zapi.Template`, `zapi.EventStream`, `zapi.StreamingResponse`, `zapi.File`, `zapi.Redirect`, and `zapi.ResponsePayload`.

`zapi.File` infers the response media type from its download `filename` when present, then from its filesystem `path`; set `content_type` only when the handler needs an override. `HEAD` requests use file metadata without reading the body, and `background_tasks` run after the response is sent.

Use `zapi.Template` for small HTML templates loaded from disk. `{{ name }}` escapes HTML by default; `{{{ name }}}` and `zapi.templateHtml` are for trusted HTML. Template responses require an app `io` handle.

Use `zapi.EventStream` for buffered server-sent event responses. It writes `text/event-stream` and supports comments, event names, IDs, retry delays, and multi-line data.

Use `zapi.StreamingResponse` when the std.http adapter should write chunks directly with `Transfer-Encoding: chunked`. `App.handle` collects the same stream into `response.body` for tests. The optional `context` pointer must outlive the response writer.

Use `zapi.Status` for standard named HTTP status codes, or `Status.fromCode(299)` for extension status codes. It also exposes `code()` and `reason()` for assertions and adapters.

Use `setHeader`, `appendHeader`, `removeHeader`, and `clearHeaders` on explicit responses when a handler needs to control headers directly. Use `hasHeader` when only header presence matters. Explicit `Content-Type` headers are preserved; otherwise zapi sets the helper's generated content type. `ResponsePayload` also has cookie helpers and background tasks for custom handler responses. Use `BackgroundTasks` to collect several tasks before transferring them into a payload.

```zig
fn queued(ctx: *zapi.Context) !zapi.ResponsePayload {
    var tasks = zapi.BackgroundTasks.init(ctx.allocator);
    errdefer tasks.deinit();
    try tasks.addTask(sendEmail, ctx.state(AppState));

    return .{
        .content_type = "text/plain; charset=utf-8",
        .body = "queued",
        .background_tasks = try tasks.toOwnedSlice(),
        .owned_background_tasks = true,
    };
}
```

`1xx`, `204 No Content`, and `304 Not Modified` responses keep explicit non-body headers and send no generated body headers or body.

Use `ctx.problem` for structured JSON error responses, or the shortcut helpers such as `ctx.notFound`, `ctx.payloadTooLarge`, `ctx.unprocessableEntity`, and `ctx.tooManyRequests` for common error statuses.
