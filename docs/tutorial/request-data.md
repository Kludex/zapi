---
icon: lucide/braces
---

# Request Data

Use wrapper types in handler parameters to tell `zapi` where data comes from.

```zig
const Search = struct {
    q: []const u8,
    limit: ?u32 = null,
};

fn search(
    ctx: *zapi.Context,
    query: zapi.Query(Search),
) !struct { q: []const u8, limit: u32 } {
    _ = ctx;
    return .{
        .q = query.value.q,
        .limit = query.value.limit orelse 20,
    };
}
```

The same input type is used for validation and OpenAPI.

## Inputs

- `zapi.Path(T)` reads path parameters.
- `zapi.Query(T)` reads query parameters.
- `zapi.Header(T)` reads headers.
- `zapi.Cookie(T)` reads cookies.
- `zapi.Body(T)` reads JSON bodies.
- `zapi.Form(T)` reads URL-encoded forms.
- Handlers can accept `zapi.Request` directly when they need the request scope without a `Context`.
- `ctx.request.pathValue("name")` returns a raw matched path parameter, and `ctx.request.pathParam(ctx.allocator, "name")` returns a percent-decoded copy.
- `ctx.request.pathParams(ctx.allocator)` returns all matched path parameters as an owned `QueryParams` collection. In context handlers, `ctx.pathParams()` uses the context allocator for you. `multiItems()` keeps host and mount captures before route captures, and route captures follow the route pattern order.
- `ctx.request.contentType()`, `hasContentType`, `accepts`, and `preferredAccepted` help with content-type checks and `Accept` negotiation. `Accept` matching understands q-values, wildcards, and JSON-style suffix ranges such as `application/*+json`.
- `ctx.request.ifNoneMatch`, `ifModifiedSince`, and `isNotModified` expose cache validator checks for custom conditional responses.
- `ctx.request.text()`, `bytes()`, and `content()` return the buffered raw body.
- `ctx.request.stream(.{})` iterates the buffered body in chunks.
- `ctx.request.url`, `urlPath`, and `baseUrl` build allocator-owned request URL strings with the current root path, query string, scheme, and `Host` header.
- `ctx.request.urlPathFor` and `urlFor` reverse named routes with the same outer-router and root-path behavior as `ctx.urlPathFor` and `ctx.urlFor`.
- `ctx.request.urlIncludeQueryParam`, `urlReplaceQueryParam`, and `urlRemoveQueryParam` return allocator-owned URLs with one query parameter appended, replaced, or removed.
- `ctx.request.urlPathIncludeQueryParam`, `urlPathReplaceQueryParam`, and `urlPathRemoveQueryParam` do the same for root-aware URL paths without scheme or host.

Incoming `Cookie` headers are parsed like Starlette: zapi accepts browser-compatible oddities such as unnamed chunks, spaces in names, equals signs in values, quoted values, repeated headers, and duplicate names. When a cookie name repeats, the last value wins.

## Parsed Containers

When you need direct access instead of a typed wrapper, parse the data from the request.

```zig
var query = try ctx.request.queryParams(ctx.allocator);
defer query.deinit();

if (!query.isEmpty() and query.contains("tag")) {
    const tags = query.getAll("tag") orelse &.{};
    const ordered = query.items();
    _ = tags;
    _ = ordered;
}
```

`QueryParams.items()` and `FormData.items()` return borrowed parse-order pairs. `CookieParams.items(allocator)` returns an allocated slice of borrowed cookie pairs; free the slice after use.

Use `multiItems()` when the original order matters.

```zig
for (query.multiItems()) |item| {
    _ = item.name;
    _ = item.value;
}
```

Parsed query, cookie, and form containers support `get`, `contains`, `len`, and `isEmpty`. Query and form containers also support `getAll` for repeated fields and `multiItems()` for borrowed parse-order pairs. For typed form lists, use `getAllText` or `getAllFiles` and free the returned slice.

## Body Streams

When a handler wants to process the body directly, use `Request.text`, `Request.bytes`, `Request.content`, or `Request.stream`.

```zig
fn upload(ctx: *zapi.Context) !struct { size: usize } {
    var stream = ctx.request.stream(.{ .chunk_size = 8192 });
    var size: usize = 0;

    while (stream.next()) |chunk| {
        size += chunk.len;
    }

    return .{ .size = size };
}
```

The current stream is backed by the request body already held by the app. It gives handlers a Starlette-like iteration shape without requiring JSON or form parsing.

When the std.http adapter is serving a route that should process the body incrementally, disable adapter buffering and read from `Request.streamReader`.

```zig
fn ingest(ctx: *zapi.Context) !struct { size: usize } {
    var reader = ctx.request.streamReader() orelse return error.Validation;
    var buffer: [8192]u8 = undefined;
    var size: usize = 0;

    while (true) {
        const n = try reader.read(&buffer);
        if (n == 0) break;
        size += n;
    }

    return .{ .size = size };
}

var server = zapi.Server.init(&app, io, .{ .buffer_request_body = false });
try server.run(address);
```

Buffered request helpers such as `Request.json`, `Request.formData`, and typed `Body(T)` parameters are designed for the default buffered adapter mode. Use `streamReader` for endpoints that want to consume the adapter body directly.

## Path Convertors

Use convertors in the path pattern:

```zig
zapi.Route.get("/users/{id:int}", getUser, .{})
```

The built-in convertors are `str`, `int`, `float`, `uuid`, and `path`. Like Starlette, `float` route segments match non-negative decimal text such as `12` or `12.5`; signs, exponents, and incomplete decimals do not match the route. A terminal `path` convertor can match an empty tail, so `/files/{rest:path}` matches `/files/`.

Register custom convertors before adding routes that use them:

```zig
fn slugMatches(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |ch| {
        if (std.ascii.isLower(ch) or std.ascii.isDigit(ch) or ch == '-') continue;
        return false;
    }
    return true;
}

try app.addPathConvertor("slug", slugMatches);
try app.route(zapi.Route.get("/posts/{slug:slug}", getPost, .{}));
```

Custom convertors constrain both incoming route matching and `urlPathFor`/`urlFor` reversing. Register the convertor on the app that owns the route, mount prefix, or host pattern using it. Typed `Path(T)` fields still parse the captured text for handlers.

Parameter names use the Starlette identifier shape: start with a letter or `_`, then use only letters, digits, or `_`.

## Parameter Docs

Add documentation without changing the handler type.

```zig
zapi.Route.get("/users/{id:int}", getUser, .{
    .summary = "Get user",
    .parameter_docs = &.{
        .{
            .name = "id",
            .in = .path,
            .description = "The user id.",
            .example_json = "1",
        },
    },
})
```

`alias` can also rename public query, header, and cookie fields while keeping Zig field names idiomatic.
