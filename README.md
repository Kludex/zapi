# zapi

`zapi` is an experimental web framework for Zig 0.16.

You define endpoints as normal Zig functions. You register them with Starlette-style route values. `zapi` uses the same definitions for validation, OpenAPI 3.1, Swagger UI, ReDoc, and tests.

> [!WARNING]
> `zapi` is under active development. Expect breaking API changes before the first stable release.

## Install

Add `zapi` to `build.zig.zon`:

```sh
zig fetch --save git+https://github.com/Kludex/zapi
```

Expose the package module to your executable:

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zapi = b.dependency("zapi", .{
        .target = target,
        .optimize = optimize,
    });

    const app = b.addExecutable(.{
        .name = "app",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zapi", .module = zapi.module("zapi") },
            },
        }),
    });

    b.installArtifact(app);

    const run = b.step("run", "Run the application");
    run.dependOn(&b.addRunArtifact(app).step);
}
```

## Create an application

Create `src/main.zig`:

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
    return .{
        .id = 1,
        .email = body.value.email,
    };
}

pub fn main(init: std.process.Init) !void {
    var app = zapi.ZAPI.init(init.gpa, .{
        .title = "Users API",
        .version = "1.0.0",
    });
    defer app.deinit();

    try app.includeRoutes(.{
        .routes = .{
            zapi.get("/", hello, .{
                .summary = "Hello world",
            }),
            zapi.post("/users", createUser, .{
                .status = .created,
                .summary = "Create user",
                .tags = &.{"users"},
            }),
        },
    });

    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 8000);
    try app.serve(init.io, address, .{});
}
```

Run it:

```sh
zig build run
```

Open the generated documentation:

- Swagger UI: <http://127.0.0.1:8000/docs>
- ReDoc: <http://127.0.0.1:8000/redoc>
- OpenAPI JSON: <http://127.0.0.1:8000/openapi.json>

The `POST /users` endpoint accepts a JSON body. `zapi` validates it against `CreateUser` and documents both the request and response schemas.

## What you get

- Typed `Path`, `Query`, `Header`, `Cookie`, `Body`, and `Form` inputs.
- JSON, text, HTML, templates, streams, files, redirects, and problem responses.
- Nested routers, mounted applications, host routing, and WebSockets.
- OpenAPI 3.1 generated from endpoint signatures.
- Swagger UI and ReDoc routes by default.
- Bearer, Basic, API key, and OAuth2 helpers.
- CORS, GZip, sessions, trusted hosts, proxy headers, and other middleware.
- Static files with conditional and range requests.
- In-process HTTP and WebSocket testing.
- A Zig 0.16 `std.http` server adapter.

## Routing

Routes are data. You can compose them with `Router.init`, `includeRoutes`, mounts, and hosts.

Path parameters support `str`, `int`, `float`, `uuid`, and terminal `path` convertors. You can also register custom convertors.

Registered paths are compiled into a segment radix tree. Static segments use hash lookup. Parameter branches preserve registration order. Path parameters are allocated only after a route is selected.

## Responses

Return a plain Zig value to encode it as JSON:

```zig
fn health(ctx: *zapi.Context) !struct { ok: bool } {
    _ = ctx;
    return .{ .ok = true };
}
```

Use an explicit helper when you need another response type:

- `Text`
- `Html`
- `Template`
- `EventStream`
- `StreamingResponse`
- `Bytes`
- `File`
- `Json(T)`
- `RawJson`
- `Redirect`
- `ResponsePayload`
- `Empty`

## Test an application

Tests call the application directly. They do not need a network listener.

```zig
const std = @import("std");
const zapi = @import("zapi");

test "hello" {
    const Handler = struct {
        fn hello(ctx: *zapi.Context) !struct { message: []const u8 } {
            _ = ctx;
            return .{ .message = "Hello from Zig" };
        }
    };

    var app = zapi.ZAPI.init(std.testing.allocator, .{});
    defer app.deinit();

    try app.route(zapi.get("/", Handler.hello, .{}));

    var response = try app.handle(zapi.Request.init(.GET, "/"));
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqual(zapi.Status.ok, response.status);
    try std.testing.expectEqualStrings(
        "{\"message\":\"Hello from Zig\"}",
        response.body.items,
    );
}
```

Use `Request.builder` for owned headers, cookies, query parameters, forms, and request bodies. Use `TestClient` when several requests should share defaults, cookies, redirects, or lifespan state.

## Documentation

- [First steps](docs/tutorial/first-steps.md)
- [Request data](docs/tutorial/request-data.md)
- [Testing](docs/tutorial/testing.md)
- [Application reference](docs/reference/application.md)
- [OpenAPI reference](docs/reference/openapi.md)
- [Middleware reference](docs/reference/middleware.md)
- [Roadmap](docs/reference/roadmap.md)

Preview the documentation site with [Zensical](https://zensical.org/):

```sh
zensical serve
```

## Development

```sh
./scripts/check
./scripts/test
zig build run-example
```

The test suite runs in Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall modes.
