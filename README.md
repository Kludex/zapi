# zapi

`zapi` is an experimental Zig 0.16 web framework.

It takes two ideas seriously:

- Define routes as data, like Starlette.
- Generate OpenAPI and docs from endpoint signatures, like FastAPI.

There are no decorators in Zig. Instead, endpoints are normal functions and routes are a list of `Route` objects.

The package entry point is `src/root.zig`. The source layout follows Starlette's domains. Applications, request values, responses, routing, authentication, middleware, WebSockets, and static files have separate modules. `src/root.zig` keeps the public API flat.

## Hello World

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

    var app = zapi.ZAPI.init(gpa.allocator(), .{
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

Run the example:

```sh
zig build run-example
```

The documentation site source lives in `docs/` and is configured with `zensical.toml`.
Preview it with Zensical when the CLI is installed:

```sh
zensical serve
```

The app creates `/openapi.json`, Swagger UI at `/docs`, Swagger UI's OAuth2 redirect helper at `/docs/oauth2-redirect`, and ReDoc at `/redoc` by default. Each endpoint supports `GET` and `HEAD`.

## Routes

Routes are values.

```zig
const users = zapi.Router.init(.{
    .prefix = "/users",
    .tags = &.{"users"},
    .routes = .{
        zapi.Route.get("/", listUsers, .{
            .summary = "List users",
        }),
        zapi.Route.get("/{id:int}", getUser, .{
            .summary = "Get user",
            .name = "get_user",
        }),
    },
});

try app.includeRouter(users);
```

Routers can contain other routers.

```zig
const api = comptime zapi.Router.init(.{
    .prefix = "/api",
    .tags = &.{"api"},
    .routes = .{
        users,
        zapi.Route.get("/status", status, .{
            .summary = "API status",
        }),
    },
});
```

Nested router tags are composed with route tags for OpenAPI.

The path convertors are `str`, `int`, `float`, `uuid`, and `path`. Like Starlette, `float` route segments match non-negative decimal text such as `12` or `12.5`; signs, exponents, and incomplete decimals do not match the route. A terminal `path` convertor can match an empty tail, so `/files/{rest:path}` matches `/files/`.

Register app-level custom convertors before adding routes that use them.

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
try app.route(zapi.Route.get("/posts/{slug:slug}", getPost, .{
    .name = "post_detail",
}));
```

Custom convertors constrain routing and reverse URL generation. Register the convertor on the app that owns the route, mount prefix, or host pattern using it. Handler parsing still comes from the typed `Path(T)` fields.

Route registration validates path patterns and rejects duplicate path parameter names. Parameter names use the Starlette identifier shape: start with a letter or `_`, then use only letters, digits, or `_`.

Parameters can appear inside a path segment, such as `/users/{username}:disable` or `/items/v{id:int}`.

Captured path parameters are percent-decoded before validation.

Handlers can accept `zapi.Request` directly. Matched route parameters are available with `request.pathValue("name")` for the raw value, `request.pathParam(allocator, "name")` for one percent-decoded copy, or `request.pathParams(allocator)` for all decoded parameters as a `QueryParams` collection. Inside a context handler, use `ctx.pathValue`, `ctx.pathParam`, and `ctx.pathParams()`. The collection keeps host and mount captures before route captures, and route captures follow the route pattern order.

Use `zapi.methods` when one handler should answer several HTTP methods.
`zapi` also has top-level convenience constructors for `get`, `post`, `put`, `patch`, `delete`, `methods`, `websocket`, and `mount`. The same constructors, plus `options`, `head`, `trace`, `connect`, and `host`, are available under `zapi.Route` when you prefer the explicit namespace or need those less common route kinds.

```zig
const health = zapi.Router.init(.{
    .routes = .{
        zapi.methods("/health", &.{ .GET, .HEAD }, healthCheck, .{
            .summary = "Health check",
        }),
    },
});

try app.route(zapi.methods("/status", &.{ .GET, .HEAD }, healthCheck, .{}));
```

Use `zapi.websocket` for WebSocket endpoints served through the std.http adapter. WebSocket routes can live in the same router route list as HTTP routes, support path params and URL reversing, and are omitted from OpenAPI.

```zig
fn chat(ctx: *zapi.WebSocketContext) !void {
    const message = try ctx.readSmallMessage();
    const room = ctx.pathValue("room") orelse "default";
    try ctx.sendText(room);
    try ctx.sendText(message.data);
}

const realtime = zapi.Router.init(.{
    .routes = .{
        zapi.websocket("/ws/{room}", chat, .{ .name = "chat" }),
    },
});
```

Mounts and hosts use the same route-list style.

```zig
const services = zapi.Router.init(.{
    .routes = .{
        zapi.get("/health", healthCheck, .{}),
        zapi.mount("/api", &api_app, .{ .name = "api" }),
        zapi.Route.host("api.example.org", &api_app, .{ .name = "api_host" }),
    },
});

try app.includeRouter(services);
```

Use `includeRoutes` when you want to register one Starlette-style list without first naming a router value.

```zig
try app.includeRoutes(.{
    .prefix = "/v1",
    .middlewares = &.{authMiddleware},
    .routes = .{
        zapi.get("/health", healthCheck, .{}),
        zapi.methods("/status", &.{ .GET, .HEAD }, healthCheck, .{}),
        zapi.mount("/api", &api_app, .{ .name = "api" }),
        zapi.Route.host("api.example.org", &api_app, .{ .name = "api_host" }),
    },
});
```

Sub-application pointers are runtime values, so the router value stores route-list literals by value and applies prefixes, tags, and middleware when it is included.

Registered paths are compiled into a segment radix tree. Static segments use direct hash lookup, while typed parameter branches preserve route registration order. Matching allocates path parameters only after it selects an endpoint.

Inside a handler, use `ctx.urlPathFor` to build a path for a named route. Use `ctx.urlFor` when the current request should provide an absolute URL with its scheme, host, and external root path. Use `ctx.redirectTo` when the response should redirect there.

Routes without `.name` get a stable method-and-final-path name, such as `get_users_id`. Router prefixes are included.

Route names must reverse to one path. Reusing a name for several methods on the same path is fine.

Generated route paths percent-encode path parameter values.

Reverse URL lookup fails when required params are missing or extra params are supplied.

Trailing-slash redirects are enabled by default. Set `redirect_slashes = false` on `ZAPI.init` for strict path matching.

`GET` routes automatically handle `HEAD` when no explicit `HEAD` route exists. Routes also answer `OPTIONS` automatically with a deduplicated `Allow` header unless an explicit `OPTIONS` route is registered. `405 Method Not Allowed` responses include the same `Allow` header.

```zig
fn goToUser(ctx: *zapi.Context, path: zapi.Path(struct { id: u64 })) !zapi.ResponsePayload {
    return try ctx.redirectTo("get_user", .{ .id = path.value.id });
}
```

Mount an app on a host when the same process should serve different apps for different `Host` headers.

```zig
try app.host("api.example.org", &api_app);
try app.host("www.example.org", &site_app);
```

Named host mounts can build absolute URLs.

```zig
try app.hostNamed("api.example.org", "api", &api_app);
const url = try app.urlForHost("api:get_user", .{ .id = 42 }, "https");
```

Host patterns can include parameters like `{subdomain}.example.org`; handlers read them with `Path(T)`.

Like Starlette, host routing ignores the port in incoming `Host` headers when matching, but a port configured in `hostNamed`, such as `api.example.org:3600`, is preserved by `urlForHost`.

Handlers inside hosted apps can reverse their local route names with `ctx.urlFor`, and can also use the host namespace such as `api:get_user` when they need the outer route name.

Named mounts namespace reverse URL lookup.

```zig
try api_app.mountNamed("/nested", "nested", &nested_app);
try app.mountNamed("/api", "api", &api_app);
const docs = try app.urlPathFor("api", .{ .path = "/docs" });
const user = try app.urlPathFor("api:get_user", .{ .id = 42 });
const nested_docs = try app.urlPathFor("api:nested", .{ .path = "/docs" });
```

Mount reverse paths preserve `/` separators and percent-encode unsafe bytes, so `.{ .path = "/docs/search page" }` renders as `/api/docs/search%20page`.

Handlers inside mounted apps can still reverse URLs through the outer app, so sibling and top-level route names work with the current request's external root path.

Mount prefixes can include path parameters. Child handlers read them with `Path(T)`.

```zig
try app.mountNamed("/{tenant}/api", "tenant_api", &tenant_app);
const user = try app.urlPathFor("tenant_api:get_user", .{ .tenant = "acme", .id = 42 });
```

Use `mount("/", &app)` when a child app should handle the remaining root path.

## Request Data

Use typed wrappers in handler parameters.

```zig
fn getUser(
    ctx: *zapi.Context,
    path: zapi.Path(struct { id: u64 }),
    query: zapi.Query(struct { verbose: ?bool = null }),
) !User {
    _ = ctx;
    _ = query;
    return .{ .id = path.value.id, .email = "ada@example.com" };
}
```

Available wrappers:

- `Path(T)`
- `Query(T)`
- `Header(T)`
- `Cookie(T)`
- `Body(T)`
- `Form(T)`

Validation errors return `422 Unprocessable Entity`.

For raw access, use `ctx.request.header`, `ctx.request.hasHeader`, `ctx.request.headerValues`, `ctx.request.cookie`, `ctx.request.cookies`, `ctx.request.queryParam`, `ctx.request.queryParams`, `ctx.request.contentType`, `ctx.request.hasContentType`, `ctx.request.accepts`, `ctx.request.preferredAccepted`, `ctx.request.ifNoneMatch`, `ctx.request.ifModifiedSince`, `ctx.request.isNotModified`, `ctx.request.url`, `ctx.request.urlPath`, `ctx.request.baseUrl`, `ctx.request.urlPathFor`, `ctx.request.urlFor`, `ctx.request.urlIncludeQueryParam`, `ctx.request.urlReplaceQueryParam`, `ctx.request.urlRemoveQueryParam`, `ctx.request.urlPathIncludeQueryParam`, `ctx.request.urlPathReplaceQueryParam`, `ctx.request.urlPathRemoveQueryParam`, `ctx.request.text`, `ctx.request.bytes`, `ctx.request.content`, `ctx.request.json`, `ctx.request.formParams`, `ctx.request.formData`, and `ctx.pathParam`. `accepts` and `preferredAccepted` understand q-values, wildcards, and JSON-style suffix ranges such as `application/*+json`. Decoded query and path values are allocator-owned; free `headerValues`, `url`, `urlPath`, `baseUrl`, reversed URL/path slices, and query-mutated URL or path slices and call `deinit` on `cookies`, `queryParams`, `json`, `formParams`, and `formData` results.
Parsed query, cookie, and form containers support `get`, `contains`, `len`, and `isEmpty`; multi-value query and form containers also support `getAll`. Query and form containers expose `items()` and `multiItems()` when parse-order pairs matter. Cookie containers expose `items(allocator)` for a snapshot of parsed cookie pairs; free the returned slice, while the names and values stay owned by the container. For typed form lists, use `getAllText` or `getAllFiles` and free the returned slice.

Enum fields validate against their tag names and are documented as OpenAPI enum strings.

Boolean fields accept `true`, `1`, `on`, `yes`, `false`, `0`, `off`, and `no`, case-insensitively.

Use `zapi.Uuid`, `zapi.Date`, `zapi.DateTime`, `zapi.Email`, and `zapi.Url` for formatted scalar fields in path, query, header, cookie, form, and JSON body data. They validate the text and emit `format: uuid`, `format: date`, `format: date-time`, `format: email`, or `format: uri` in OpenAPI.

Default values on typed request fields are applied at runtime and emitted as OpenAPI schema defaults.

Use `parameter_docs` to document typed parameters. For query, header, and cookie fields, `alias` also changes the public request name. Add `description`, `deprecated`, and `example_json` to enrich the generated docs without changing the handler signature.

```zig
try app.route(zapi.Route.get("/search", search, .{
    .parameter_docs = &.{
        .{
            .name = "page_size",
            .location = .query,
            .alias = "page-size",
            .description = "Maximum number of users to return",
            .example_json = "25",
        },
        .{
            .name = "api_key",
            .location = .header,
            .alias = "x-api-key",
            .description = "API key issued to the client",
            .example_json = "\"secret\"",
        },
    },
}));
```

Typed JSON bodies accept `application/json` and `application/*+json` content types. Use `Body(?T)` for an optional JSON body. Empty bodies and explicit JSON `null` become `null`, and OpenAPI marks the request body as not required.

Use `Body([]const T)` for JSON arrays. Returning `[]const T` from a handler documents the response as an OpenAPI array.

Use `std.json.ArrayHashMap(T)` for JSON objects with arbitrary string keys.

```zig
fn scores(
    ctx: *zapi.Context,
    body: zapi.Body(std.json.ArrayHashMap(u32)),
) !std.json.ArrayHashMap(u32) {
    _ = ctx;
    return body.value;
}
```

Repeated query parameters and repeated header values can be parsed into slices.

```zig
fn search(
    ctx: *zapi.Context,
    query: zapi.Query(struct { tag: []const []const u8 }),
) !struct { tags: []const []const u8 } {
    _ = ctx;
    return .{ .tags = query.value.tag };
}
```

Repeated URL-encoded form fields can also be parsed into slice fields.

```zig
fn savePreferences(
    ctx: *zapi.Context,
    form: zapi.Form(struct {
        username: []const u8,
        tag: []const []const u8,
        level: []const u32,
    }),
) !struct { username: []const u8, tags: []const []const u8, levels: []const u32 } {
    _ = ctx;
    return .{
        .username = form.value.username,
        .tags = form.value.tag,
        .levels = form.value.level,
    };
}
```

Repeated multipart file fields can be parsed into `[]const zapi.UploadFile`.

## Responses

Plain structs are encoded as JSON.

```zig
fn health(ctx: *zapi.Context) !struct { ok: bool } {
    _ = ctx;
    return .{ .ok = true };
}
```

For explicit responses, return one of the response helpers:

- `zapi.Text`
- `zapi.Html`
- `zapi.Template`
- `zapi.EventStream`
- `zapi.StreamingResponse`
- `zapi.Bytes`
- `zapi.File`
- `zapi.Json(T)`
- `zapi.RawJson`
- `zapi.Redirect`
- `zapi.ResponsePayload`
- `zapi.Empty`

Use `Json(T)` when zapi should serialize a typed value and document its schema. Use `RawJson` when the handler already has serialized JSON and the OpenAPI response should advertise `application/json` without claiming a schema.

Use `Template` when you want to render an HTML file with small, explicit context values. `{{ name }}` is HTML-escaped by default. Use `{{{ name }}}` or `zapi.templateHtml` only for trusted HTML.

Response helper slices are borrowed. Store slice literals at module scope, as shown below, or allocate them with `ctx.allocator`. A handler must not return a slice backed by its stack.

```zig
const homepage_context = [_]zapi.TemplateValue{
    zapi.template("title", "Hello <Zig>"),
    zapi.templateHtml("body", "<strong>trusted</strong>"),
};

fn homepage(ctx: *zapi.Context) !zapi.Template {
    _ = ctx;
    return .{
        .path = "templates/home.html",
        .context = &homepage_context,
    };
}
```

Template responses read from `dir`, which defaults to the current directory, and require the app to have an `io` handle.

Use `EventStream` for buffered server-sent event responses. It writes `text/event-stream`, supports comments, event names, IDs, retry delays, and multi-line data. This is a response helper, not transport-level streaming. Its event slice follows the response helper borrowing rule above.

```zig
const events_data = [_]zapi.ServerSentEvent{
    .{ .comment = "connected" },
    .{
        .event = "message",
        .id = "42",
        .retry = 1500,
        .data = "hello\nworld",
    },
    zapi.serverSentEvent("done"),
};

fn events(ctx: *zapi.Context) !zapi.EventStream {
    _ = ctx;
    return .{ .events = &events_data };
}
```

Use `StreamingResponse` when the std.http adapter should write chunks directly with `Transfer-Encoding: chunked`. `ZAPI.handle` collects the same stream into `response.body` for tests. The optional `context` pointer must outlive the response writer.

```zig
fn writeStream(context: ?*anyopaque, writer: *std.Io.Writer) !void {
    _ = context;
    try writer.writeAll("hello ");
    try writer.flush();
    try writer.writeAll("stream");
}

fn stream(ctx: *zapi.Context) !zapi.StreamingResponse {
    _ = ctx;
    return .{
        .content_type = "text/plain; charset=utf-8",
        .write = writeStream,
    };
}
```

Use `response.setHeader` when one value should replace an existing header. Use `response.appendHeader` when repeated headers are intentional, such as multiple `Set-Cookie` values. Use `response.removeHeader` to remove all values for a header name, or `response.clearHeaders` to remove every header.

Use `response.hasHeader` in tests when only header presence matters. Use `response.headerValues` when a repeated response header matters.

Use `response.contentType()` or `response.hasContentType()` in tests when only the media type matters and response parameters such as `charset` should be ignored.

`zapi.Status` includes the standard named HTTP status codes and exposes `code()` and `reason()`. Use `Status.fromCode(299)` for extension status codes.
Use `status.isSuccess`, `status.isRedirect`, `status.isClientError`, `status.isServerError`, and `status.isError` for status range checks. `Response` exposes the same helpers for direct test assertions, plus `response.reason()` for the response reason phrase. Use `response.expectStatus` or `response.expectSuccess` when a test should fail with `error.UnexpectedStatus`. Use `response.raiseForStatus()` when only 4xx and 5xx responses should fail, leaving redirects as valid responses.

`Redirect` responses quote unsafe `Location` bytes, so spaces and non-ASCII path text are sent as percent-encoded URLs.

Use `response.setCookie` and `response.deleteCookie` to build valid `Set-Cookie` headers without formatting them by hand. `CookieOptions` supports `Path`, `Domain`, `Max-Age`, `Expires`, `Secure`, `HttpOnly`, `SameSite`, and `Partitioned`. Like Starlette, `SameSite` defaults to `lax`; set `.same_site = null` when a cookie should omit the attribute.

Use `response.cookie(allocator, name)` in tests when one parsed response cookie matters, and free the returned value when present. Use `response.cookies` when you want the full parsed response cookie set. Deletion `Set-Cookie` headers remove matching parsed values.

`ResponsePayload` has the same header, header-presence, repeated-header, and cookie helpers, plus `addBackgroundTask`, for handlers that return a custom payload. Use `BackgroundTasks` when a handler should collect several tasks before returning a response. Explicit `Content-Type` headers on response helpers are preserved; otherwise zapi sets the helper's generated content type. `File` responses can also include `background_tasks`; set `owned_background_tasks = true` when the handler allocated the task slice with the request allocator.

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

Use `makeConditional` to add `ETag` or `Last-Modified` validators and return `304 Not Modified` for matching `GET` or `HEAD` requests. For custom decisions, use `request.ifNoneMatch`, `request.ifModifiedSince`, or `request.isNotModified`.

```zig
fn cached(ctx: *zapi.Context) !zapi.ResponsePayload {
    var response = zapi.ResponsePayload{
        .content_type = "text/plain; charset=utf-8",
        .body = "cache me",
    };
    try response.makeConditional(ctx.allocator, ctx.request, .{
        .etag = "\"v1\"",
        .last_modified_seconds = 1_700_000_000,
    });
    return response;
}
```

`1xx`, `204 No Content`, and `304 Not Modified` responses keep explicit non-body headers and send no generated body headers or body.

Buffered responses include `Content-Length` automatically, except `1xx`, `204`, and `304`.

File responses include `Content-Length`, `ETag`, `Last-Modified`, single and multipart range requests, conditional requests, and background tasks. They buffer at most 16 MiB by default; set `max_size` explicitly when a larger response is intentional. `HEAD`, `304`, and unsatisfiable range responses use file metadata without reading the body. Malformed `Range` headers return plain-text `400 Bad Request`, while valid but unsatisfiable ranges return `416 Range Not Satisfiable`. `Content-Type` is inferred from `filename` when present, then from `path`, and can be overridden with `content_type`. Custom `ETag` and `Last-Modified` headers are used as the validators for conditional and range requests. `filename` adds a `Content-Disposition` header, and `content_disposition = .@"inline"` switches it from attachment to inline. Explicit `Content-Disposition` and `Accept-Ranges` headers are preserved instead of being replaced by generated defaults.

For file responses, give the app an `std.Io` handle:

```zig
var app = zapi.ZAPI.init(allocator, .{
    .io = env.io,
});

fn download(ctx: *zapi.Context) !zapi.File {
    _ = ctx;
    return .{
        .path = "report.csv",
        .filename = "report.csv",
        .content_disposition = .attachment,
    };
}
```

Return structured JSON errors from handlers with `ctx.problem`.

```zig
fn getUser(ctx: *zapi.Context) !zapi.ResponsePayload {
    return try ctx.problem(.not_found, "User not found");
}
```

For common errors, use `ctx.badRequest`, `ctx.unauthorized`, `ctx.unauthorizedWithChallenge`, `ctx.forbidden`, `ctx.notFound`, `ctx.conflict`, `ctx.payloadTooLarge`, `ctx.unprocessableEntity`, and `ctx.tooManyRequests`.

Use `ctx.problemWithHeaders` when the error response needs explicit headers.

```zig
fn limited(ctx: *zapi.Context) !zapi.ResponsePayload {
    return try ctx.problemWithHeaders(.too_many_requests, "Slow down", &.{
        .{ .name = "retry-after", .value = "30" },
    });
}
```

For common JSON error responses, use `ctx.badRequest`, `ctx.unauthorized`, `ctx.unauthorizedWithChallenge`, `ctx.forbidden`, `ctx.notFound`, `ctx.conflict`, and `ctx.unprocessableEntity`.

Register status handlers to customize framework-generated responses such as `404` and `405`.

```zig
try app.addStatusHandler(.not_found, notFoundPage);
```

## Static Files

Mount a static files app when a directory should be served under a prefix.

```zig
var static_files = try zapi.StaticFiles.init(allocator, .{
    .dir = assets_dir,
    .html = true,
});
defer static_files.deinit();

try app.mount("/static", &static_files.app);
```

Static paths are percent-decoded and validated before reading from disk. Symlinks are rejected by default, and supported platforms constrain resolution beneath the configured directory. Set `follow_symlinks = true` only when the static tree intentionally contains symlinks.

Static files answer `GET`, `HEAD`, and automatic `OPTIONS`; other methods receive plain-text `405 Method Not Allowed`. Missing paths receive plain-text `404 Not Found`, while permission failures receive `401 Unauthorized`. `html = true` enables `index.html` for `/` and trailing-slash paths, redirects directory paths to a trailing slash when an index exists, and serves `404.html` for missing paths when present.

Static file responses include `Content-Length`, `ETag`, `Last-Modified`, single and multipart range requests, conditional requests, metadata-only `HEAD` responses, plain-text `400` responses for malformed ranges, and common asset content types such as CSS, JavaScript, JSON, text, SVG, PNG, JPEG, GIF, WebP, ICO, WASM, and PDF.

## OpenAPI

OpenAPI 3.1 is generated from the same route definitions.

`CONNECT` routes are supported by the runtime and test client, but they are omitted from OpenAPI output because OpenAPI path items do not define a `connect` operation.

```zig
var openapi = try app.handle(zapi.Request.init(.GET, "/openapi.json"));
defer openapi.deinit(allocator);
```

Swagger UI uses `/docs/oauth2-redirect` for OAuth2 authorization flows. Set `oauth2_redirect_url = null` to omit that helper route, or set it to a custom path when `docs_url` is customized.

Application metadata is emitted in the OpenAPI `info` object.

```zig
var app = zapi.ZAPI.init(allocator, .{
    .title = "Accounts API",
    .version = "1.0.0",
    .description = "Account operations.",
    .contact = .{ .email = "api@example.com" },
    .license = .{ .name = "MIT" },
    .openapi_servers = &.{
        .{ .url = "https://api.example.com", .description = "Production" },
    },
    .openapi_tags = &.{
        .{
            .name = "users",
            .description = "User operations.",
        },
    },
    .external_docs = .{
        .description = "API guide",
        .url = "https://docs.example.com",
    },
});
```

The schema includes:

- Request bodies for JSON, URL-encoded forms, and multipart forms.
- Response schemas, explicit main response descriptions, response media types, documented response headers, and extra response status codes.
- Extra response docs can use the same response helper types as handlers.
- Nullable response bodies are emitted as nullable schemas without changing the non-null component.
- Parameters for path, query, header, and cookie inputs, with optional route-level parameter docs and aliases.
- Automatic `422` validation error responses for typed request data.
- Multiple HTTP methods grouped under the same path.
- Automatic operation IDs. Named routes use their route name; unnamed routes get a stable method-and-path ID. Set `operation_id` when OpenAPI should use a different value than URL reversing.
- Route-level schema controls: `include_in_schema = false` for internal routes, `deprecated = true` for old operations, and `external_docs` for operation docs.
- Request and response examples.
- Security schemes for bearer, basic, API key, and OAuth2 auth.
- Mounted apps emit an OpenAPI `servers` entry for their mount root.

## Auth

Auth is also typed.

```zig
const OAuth2 = zapi.OAuth2PasswordBearer(.{
    .token_url = "/token",
    .scopes = &[_]zapi.OAuth2Scope{
        .{ .name = "users:read", .description = "Read users" },
    },
});

fn me(ctx: *zapi.Context, auth: OAuth2) !struct { token: []const u8 } {
    _ = ctx;
    return .{ .token = auth.token };
}
```

The OpenAPI output includes OAuth2 flow metadata and operation security requirements.

Available auth helpers:

- `BearerAuth`
- `BasicAuth`
- `ApiKeyHeader("x-api-key")`
- `ApiKeyQuery("api_key")`
- `ApiKeyCookie("session")`
- `OAuth2PasswordBearer(.{ .token_url = "/token" })`
- `OAuth2AuthorizationCodeBearer(.{ .authorization_url = "/authorize", .token_url = "/token" })`
- `OAuth2ClientCredentialsBearer(.{ .token_url = "/machine-token" })`
- `OAuth2ImplicitBearer(.{ .authorization_url = "/authorize" })`

## Middleware

Middleware receives a request and decides whether to continue.

```zig
try app.middleware(zapi.requestIdMiddleware(.{}));
try app.addMiddleware(zapi.httpsRedirectMiddleware(.{}));
try app.addMiddleware(zapi.trustedHostMiddleware(.{
    .allowed_hosts = &.{"example.com", "*.example.org"},
}));
try app.addMiddleware(zapi.corsMiddleware(.{
    .allow_origins = &.{"https://app.example"},
    .allow_origin_patterns = &.{"https://*.example.com"},
    .allow_methods = &.{ .GET, .POST },
}));
try app.addMiddleware(zapi.proxyHeadersMiddleware(.{}));
try app.addMiddleware(zapi.requestIdMiddleware(.{}));
try app.addMiddleware(zapi.responseHeadersMiddleware(.{
    .headers = &.{.{ .name = "cache-control", .value = "no-store" }},
}));
try app.addMiddleware(zapi.securityHeadersMiddleware(.{}));
try app.addMiddleware(zapi.gzipMiddleware(.{
    .minimum_size = 500,
}));
try app.addMiddleware(zapi.methodOverrideMiddleware(.{}));
try app.addMiddleware(zapi.requestBodyLimitMiddleware(.{
    .max_size = 1024 * 1024,
}));
try app.addMiddleware(zapi.sessionMiddleware(.{
    .secret_key = "change-me",
}));
```

`app.middleware` and `app.addMiddleware` are aliases; use whichever reads better in your app.

Routes can also have their own middleware.

```zig
try app.route(zapi.Route.get("/admin", admin, .{
    .middlewares = &.{adminMiddleware},
}));
```

Routers can apply middleware to every route they contain.

```zig
const admin = zapi.Router.init(.{
    .prefix = "/admin",
    .middlewares = &.{adminMiddleware},
    .routes = .{
        zapi.Route.get("/", dashboard, .{}),
        zapi.Route.get("/users", users, .{}),
    },
});

try app.includeRouter(admin);
```

Built-in helpers:

- CORS
- Trusted host validation
- HTTPS redirect
- Proxy headers
- Request ID propagation
- Static response headers
- Security headers
- GZip compression
- Method override with `X-HTTP-Method-Override`
- Request body size limits
- Signed cookie sessions

CORS and GZip update `Vary` without discarding values already set by the handler.
GZip honors `Accept-Encoding` q-values, so `gzip;q=0` prevents compression even when `*` is also present.
For CORS, use `allow_all_methods = true` when a preflight should accept every method supported by zapi.
Use `allow_origin_patterns` for simple wildcard origin matching, such as `https://*.example.com`.
Safelisted request headers are always allowed in CORS preflights; configured `allow_headers` adds to that list.
Rejected CORS preflights still include the allowed preflight headers that could be determined.
Wildcard CORS origins are sent as `*` for anonymous requests, but cookie-bearing requests mirror the request `Origin` and add `Vary: Origin`, matching Starlette's credentialed-request behavior.

Trusted host middleware rejects requests without an allowed `Host`. With `www_redirect = true`, it redirects `www.example.com` to `example.com` when the bare host is allowed, and redirects `example.com` to `www.example.com` when only the `www` host is allowed. Redirects preserve the request port.

Method override lets a `POST` request route as `PUT`, `PATCH`, or `DELETE` when it includes `X-HTTP-Method-Override`.

Proxy headers apply `X-Forwarded-Proto`, `X-Forwarded-Host`, and `X-Forwarded-Prefix` before later middleware and handlers run.

Only enable proxy headers when a trusted reverse proxy strips client-supplied forwarded headers. The middleware trusts these headers and cannot identify the network peer by itself.

Request ID middleware copies `X-Request-ID` from the request to the response, or uses a configured fallback value.

Response headers middleware sets or appends static headers on every response. Use `preserve_existing = true` when handler-set headers should win.

Request body limit middleware can be used globally, on a router, or on a single route.

Session middleware stores string values in a signed cookie. The data is protected against tampering, but it is not encrypted. `max_age` controls the browser cookie lifetime; the current signature format does not provide server-side replay expiration.

```zig
fn login(ctx: *zapi.Context) !zapi.Text {
    try ctx.session().put("user", "ada");
    return .{ .text = "ok" };
}

fn me(ctx: *zapi.Context) !struct { user: ?[]const u8 } {
    return .{ .user = ctx.session().get("user") };
}
```

Middleware can attach typed state to a copied request, and handlers can read it with `ctx.requestState`.
Use `ctx.maybeRequestState(T)` when the state is optional.

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

fn endpoint(ctx: *zapi.Context) !struct { trace_id: []const u8 } {
    const state = ctx.requestState(TraceState);
    return .{ .trace_id = state.trace_id };
}
```

Application state is available with `ctx.state(T)` inside handlers or `app.state(T)` outside them.
Use `ctx.maybeState(T)` or `app.maybeState(T)` when the app state may not be installed.

## Testing

Use `app.handle` for in-process tests.

```zig
test "hello" {
    var app = zapi.ZAPI.init(std.testing.allocator, .{});
    defer app.deinit();

    try app.route(zapi.Route.get("/", hello, .{}));

    var response = try app.handle(zapi.Request.init(.GET, "/"));
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqual(zapi.Status.ok, response.status);

    var data = try response.json(struct { message: []const u8 }, std.testing.allocator);
    defer data.deinit();
    try std.testing.expectEqualStrings("Hello from Zig", data.value.message);
}
```

This is the same testing shape as Starlette's test client: build a request, pass it to the app, assert the response. `app.handle` also applies app-level request limits, so tests see the same `413` behavior as the HTTP adapter.

Use `Request.builder` when a test needs owned headers, cookies, or a body.

```zig
var request = zapi.Request.builder(std.testing.allocator, .POST, "/users");
defer request.deinit();

try request.header("x-token", "secret");
try request.setHeader("x-token", "rotated-secret");
try std.testing.expect(request.hasHeader("X-Token"));
try std.testing.expectEqualStrings("rotated-secret", request.headerValue("x-token").?);
request.removeHeader("x-debug");
request.clearHeaders();
try request.header("x-token", "secret");
try request.accept("application/json");
try request.contentType("application/json; charset=utf-8");
try request.userAgent("zapi-test");
try request.cookie("session", "abc123");
try request.queryValue(.{
    .tag = [_][]const u8{ "zig api", "web+framework" },
    .limit = 20,
});
try request.setQueryParam("locale", "en-US");
try request.removeQueryParam("debug");
request.client(.{ .host = "203.0.113.10", .port = 4242 });
request.scheme("https");
request.rootPath("/api");
try request.host("api.example.test");
try request.jsonValue(CreateUser{ .email = "ada@example.com" });
try request.bearerAuth("secret");

var response = try request.send(&app);
defer response.deinit(std.testing.allocator);

if (response.requestUrl()) |url| {
    try std.testing.expectEqualStrings("https://api.example.test/api/users", url);
}

var data = try response.json(User, std.testing.allocator);
defer data.deinit();

const session = try response.cookie(std.testing.allocator, "session");
defer if (session) |value| std.testing.allocator.free(value);

var cookies = try response.cookies(std.testing.allocator);
defer cookies.deinit();
```

Use `request.sendOrRaise(&app)` when the test should receive unhandled handler errors instead of the generated `500` response.

Use `response.statusCode()` when a test needs the numeric HTTP status. Use `response.text()`, `response.bytes()`, or `response.content()` for direct body assertions. For redirect tests, use `response.location()` for the raw `Location` header and `response.nextUrl(allocator)` to resolve it against the response request URL.

For auth tests, use `bearerAuth`, `basicAuth`, `apiKeyHeader`, `apiKeyQuery`, and `apiKeyCookie`.

Use `queryParam`, `queryValue`, `setQueryParam`, `removeQueryParam`, and `clearQueryParams` to build query strings for one request. Use `request.queryParamValue(allocator, name)`, `request.queryParams(allocator)`, and `request.hasQueryParam(allocator, name)` to inspect a request builder's pending query string. Free values returned by `queryParamValue`, and call `deinit` on `queryParams`.

For URL-encoded form tests, use `formField` or `formValue`.

```zig
var form = zapi.Request.builder(std.testing.allocator, .POST, "/login");
defer form.deinit();

try form.formValue(.{
    .username = "ada lovelace",
    .password = "secret",
    .remember = true,
});
```

For multipart tests, use `multipartField` and `multipartFile`.

```zig
var upload = zapi.Request.builder(std.testing.allocator, .POST, "/upload");
defer upload.deinit();

try upload.multipartField("username", "ada");
try upload.multipartFile("avatar", "avatar.txt", "text/plain", "hello");
```

Handlers can iterate a buffered request body in chunks with `Request.stream`.

```zig
var stream = ctx.request.stream(.{ .chunk_size = 8192 });
while (stream.next()) |chunk| {
    // process chunk
    _ = chunk;
}
```

When serving through the std.http adapter, disable adapter buffering for endpoints that should consume the request body incrementally.

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

try app.serve(io, address, .{ .buffer_request_body = false });
```

Use `sendFollowRedirects` when the test should behave like a client following redirect responses. Use `sendFollowRedirectsOrRaise` when unhandled handler errors during the redirect chain should be returned to the test. Cookies set by redirect responses are sent to later requests in the redirect chain, relative redirect paths resolve `.` and `..` segments before the next request, absolute redirects update the request scheme and host, and scheme-relative redirects inherit the current scheme while updating the host. Like Starlette's in-process test client, cross-host redirects are routed back into the same app with the redirected `Host`. `301`, `302`, and `303` switch non-HEAD write requests to `GET` and drop the body plus body headers such as `Content-Type`; `307` and `308` preserve the method, body, and body headers.

```zig
var request = zapi.Request.builder(std.testing.allocator, .GET, "/old-path");
defer request.deinit();

var response = try request.sendFollowRedirects(&app, .{ .max_redirects = 5 });
defer response.deinit(std.testing.allocator);

try std.testing.expectEqual(zapi.Status.ok, response.status);
try std.testing.expectEqual(zapi.Status.temporary_redirect, response.history.items[0].status);
```

Use `TestClient` when a group of requests should share default headers and cookies.

```zig
var client = zapi.TestClient.init(std.testing.allocator, &app, .{
    .base_url = "https://api.example.test/api",
    .client = .{ .host = "203.0.113.10", .port = 4242 },
    .headers = &.{.{ .name = "x-token", .value = "secret" }},
});
defer client.deinit();

try client.setHeader("x-token", "rotated-secret");
try std.testing.expect(client.hasHeader("X-Token"));
try std.testing.expectEqualStrings("rotated-secret", client.headerValue("x-token").?);
client.removeHeader("x-debug");
client.clearHeaders();
try client.accept("application/json");
try client.userAgent("zapi-test");
try client.queryParam("locale", "en-US");
try std.testing.expect(client.hasQueryParam("locale"));
try std.testing.expectEqualStrings("en-US", client.queryParamValue("locale").?);
try client.setQueryParam("api-version", "2026-06-13");
client.removeQueryParam("debug");
try client.bearerAuth("secret");
try client.basicAuth("ada", "secret");
try client.apiKeyHeader("x-api-key", "secret");
try client.apiKeyQuery("api_key", "secret");
try client.cookie("theme", "dark");
try client.apiKeyCookie("session", "secret");
const theme = client.cookieValue("theme");
_ = theme;
var client_cookies = try client.cookies(std.testing.allocator);
defer client_cookies.deinit();
try client.deleteCookie("preview");
client.clearQueryParams();
client.clearCookies();

var duplicate = client.request(.GET, "/header-list");
defer duplicate.deinit();
try duplicate.header("x-token", "foo");
try duplicate.header("x-token", "bar");
var duplicate_response = try client.send(&duplicate);
defer duplicate_response.deinit(std.testing.allocator);

var created = try client.postJsonValue("/users", CreateUser{
    .email = "ada@example.com",
});
defer created.deinit(std.testing.allocator);

var search = try client.getQuery("/search", .{
    .tag = [_][]const u8{ "zig api", "web+framework" },
    .limit = 20,
});
defer search.deinit(std.testing.allocator);

var filtered_update = try client.putQuery("/users/42", .{
    .notify = true,
});
defer filtered_update.deinit(std.testing.allocator);

var login = try client.postForm("/login", "username=ada&password=secret");
defer login.deinit(std.testing.allocator);

var login_value = try client.postFormValue("/login", .{
    .username = "ada lovelace",
    .password = "secret",
    .remember = true,
});
defer login_value.deinit(std.testing.allocator);

var updated_login = try client.putFormValue("/login", .{
    .username = "ada lovelace",
    .password = "secret",
    .remember = false,
});
defer updated_login.deinit(std.testing.allocator);

var deleted_login = try client.deleteFormValue("/login", .{
    .username = "ada lovelace",
    .password = "secret",
});
defer deleted_login.deinit(std.testing.allocator);

var avatar = try client.postMultipart(
    "/profile",
    &.{.{ .name = "username", .value = "ada" }},
    &.{.{ .name = "avatar", .filename = "avatar.txt", .content_type = "text/plain", .content = "hello" }},
);
defer avatar.deinit(std.testing.allocator);

var patched_avatar = try client.patchMultipart(
    "/profile",
    &.{.{ .name = "username", .value = "ada" }},
    &.{.{ .name = "avatar", .filename = "avatar.txt", .content_type = "text/plain", .content = "updated" }},
);
defer patched_avatar.deinit(std.testing.allocator);

var deleted_avatar = try client.deleteMultipart(
    "/profile",
    &.{.{ .name = "username", .value = "ada" }},
    &.{.{ .name = "avatar", .filename = "avatar.txt", .content_type = "text/plain", .content = "deleted" }},
);
defer deleted_avatar.deinit(std.testing.allocator);

var me = try client.get("https://api.example.test/api/me");
defer me.deinit(std.testing.allocator);

var redirect_request = client.request(.GET, "/old-path");
defer redirect_request.deinit();

var redirect = try client.sendWithOptions(&redirect_request, .{
    .follow_redirects = false,
});
defer redirect.deinit(std.testing.allocator);

var direct_redirect = try client.getNoRedirects("/old-path");
defer direct_redirect.deinit(std.testing.allocator);

var direct_followed = try client.getFollowRedirects("/old-path", .{
    .max_redirects = 5,
});
defer direct_followed.deinit(std.testing.allocator);
```

`TestClient` has helpers for `GET`, `POST`, `PUT`, `PATCH`, `DELETE`, `OPTIONS`, `HEAD`, `TRACE`, and `CONNECT`, plus `getQuery`, `postQuery`, `putQuery`, `patchQuery`, `deleteQuery`, `optionsQuery`, `headQuery`, `traceQuery`, `connectQuery`, `postJson`, `putJson`, `patchJson`, `deleteJson`, `optionsJson`, `traceJson`, `postJsonValue`, `putJsonValue`, `patchJsonValue`, `deleteJsonValue`, `optionsJsonValue`, `traceJsonValue`, form helpers with `post`, `put`, `patch`, `delete`, `options`, or `trace` prefixes, multipart helpers with `post`, `put`, `patch`, `delete`, `options`, or `trace` prefixes, and redirect-control helpers with `NoRedirects` or `FollowRedirects` suffixes for each method. Query helpers percent-encode UTF-8 values before sending them to the app.

Use `client.websocketText(path, message)` for a one-message WebSocket exchange through the real std.http adapter. Use `client.websocketJson(path, json)` when the message is already encoded JSON, or `client.websocketJsonValue(path, value)` to serialize a Zig value before sending it. Use `client.websocketExchange(path, frames)` when the handler should receive several scripted text or binary frames. These helpers use the same base URL, default query params, default headers, and cookie jar as HTTP requests, and return an owned `WebSocketTestResponse` with the handshake status, response headers, first server frame, all parsed server frames in `messages`, and helpers such as `statusCode()`, `reason()`, `expectStatus()`, `hasHeader()`, `headerValues(allocator)`, `text()`, `binary()`, `json(T, allocator)`, `textMessages(allocator)`, and `binaryMessages(allocator)`. Free the parsed JSON result and the slices returned by `headerValues`, `textMessages`, and `binaryMessages`; the message bytes stay owned by the response.

Headers set on a `Request.builder` request override default headers set on the client for that request only.
Default query params are sent before request-specific query params, so single-value parsers see the request value when both use the same name, while repeated-value parsers can still see both values.
For shared auth in a group of requests, use `bearerAuth`, `basicAuth`, `apiKeyHeader`, `apiKeyQuery`, or `apiKeyCookie` on the client.
Like Starlette's test client, `TestClient` sends `user-agent: testclient`, `accept: */*`, `accept-encoding: gzip, deflate, zstd`, and `connection: keep-alive` unless the client or request sets another value.

By default, `TestClient` uses the Starlette-style request base `http://testserver`. `TestClientOptions` can set `base_url` for a different request base and `client` for `request.client`. When `base_url` contains a path, zapi uses it as `root_path`, so handlers see it in `request.url`, `request.urlPath`, and `request.baseUrl`, while routes still match the app-relative path. You can also set `scheme`, `host`, `root_path`, and redirect behavior separately; set `host = null` when a test should send no `Host` header. Request targets can be app-relative paths or include the configured root path prefix; the prefix is removed before routing. Absolute URLs set the request scheme and `Host` header before routing and also strip the configured root path prefix when present. Scheme-relative targets such as `//api.example.test/path` inherit the current request scheme and update `Host`. Followed absolute and scheme-relative redirects do the same, including redirects to a different host. Redirects generated with `ctx.redirectTo` can include the external root path in `Location`; the client removes that prefix before routing the next request.

Use `getNoRedirects`, `postNoRedirects`, or another method-specific `NoRedirects` helper when one request should not follow redirects. Use `getFollowRedirects`, `postFollowRedirects`, or another method-specific `FollowRedirects` helper when one request should follow redirects or set `max_redirects` regardless of the client default. Use `sendWithOptions`, `sendFollowRedirects`, or `sendNoRedirects` when the request is already a `Request.builder`.

Response cookies update the client jar using `Domain`, `Path`, `Secure`, `Max-Age`, and epoch `Expires` deletion semantics. Deletion headers remove matching cookies regardless of the cookie value sent with them. Like Starlette's test client, single-label hosts such as `testserver` also accept cookies scoped to their effective `.local` domain, such as `testserver.local`. When several matching cookies share a name, less-specific paths are sent before more-specific paths, so zapi handlers using last-value cookie parsing see the path-specific value.

By default, `TestClient` raises unhandled server errors instead of turning them into `500` responses. Set `raise_server_exceptions = false` when the test should inspect the generated error response. Use `sendWithOptions` with `.raise_server_exceptions = true` or `false` when one request should override the client default, including during redirect chains.

Use `TestClient.start` when the test should run app startup and shutdown handlers.

```zig
var client = try zapi.TestClient.start(std.testing.allocator, &app, .{});
defer client.deinit();
```

## Serving

For a blocking TCP server, pass Zig 0.16's `std.Io` from `main`.

```zig
pub fn main(env: std.process.Init) !void {
    var app = zapi.ZAPI.init(env.gpa, .{
        .title = "My API",
        .version = "0.1.0",
    });
    defer app.deinit();

    try app.includeRouter(router);

    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 8000);
    try app.serve(env.io, address, .{});
}
```

`serveListener` also supports opt-in concurrent connection handling and graceful shutdown signals.

## Current Features

- Starlette-style route lists with `Router.init`, including nested routers, mounts, and hosts.
- `GET`, `POST`, `PUT`, `PATCH`, `DELETE`, `OPTIONS`, `HEAD`, `TRACE`, runtime `CONNECT`, and multi-method route helpers.
- WebSocket routes through the std.http adapter.
- Built-in and app-level custom path convertors.
- Typed request extraction for path, query, header, cookie, form, and body data.
- Validated `Uuid`, `Date`, `DateTime`, `Email`, and `Url` scalar fields with OpenAPI formats.
- Enum validation for typed request data and OpenAPI enum schemas.
- Optional JSON request bodies with nullable OpenAPI schemas.
- Direct JSON array request and response schemas.
- JSON object maps with `std.json.ArrayHashMap(T)` and OpenAPI `additionalProperties` schemas.
- JSON body content-type validation with `application/*+json` support.
- Repeated query and header parameter parsing into typed slices.
- Lenient browser-compatible incoming `Cookie` header parsing, including unnamed chunks and duplicate names where the last value wins.
- Repeated URL-encoded form fields into typed slices.
- Buffered multipart forms with `UploadFile` and repeated file fields into typed slices.
- Buffered request body streaming with `Request.stream`.
- Validation failures as `422`, documented automatically in OpenAPI.
- `404`, `405`, `Allow`, automatic `HEAD` and `OPTIONS`, and configurable method-independent trailing-slash redirects.
- OpenAPI 3.1, Swagger UI, and ReDoc routes by default.
- Application-level OpenAPI metadata for description, terms, contact, license, servers, tags, and external docs.
- JSON Schema component generation.
- Automatic OpenAPI operation IDs.
- Route-level OpenAPI hiding and deprecation markers.
- OpenAPI request/response examples, main response descriptions, and extra responses.
- Bearer, Basic, API key, and OAuth2 auth metadata.
- Named routes and URL path reversing from both apps and handler contexts.
- Direct `Request` handler parameters plus request-aware path-param, content negotiation, cache validator, URL, URL path, base URL, root path, and query-string helpers.
- JSON, text, HTML, template, buffered event stream, transport streaming, bytes, file, redirect, empty, problem, problem-with-headers, and custom payload responses.
- Conditional `304 Not Modified` helpers for custom payloads.
- Cookie helpers, background task accumulators, lifespan hooks, exception handlers, and status handlers.
- Starlette-style app, router, and route middleware with CORS, trusted-host, HTTPS redirect, proxy headers, request IDs, static response headers, security headers, GZip, request body limits, signed cookie sessions, and merged `Vary` headers.
- Header-based method override middleware for tunneled `PUT`, `PATCH`, and `DELETE` requests.
- Request-scoped state for middleware-to-handler data.
- Mounted sub-applications with path and host routing, mount-aware redirects, docs, and OpenAPI servers.
- Static file serving with optional HTML index lookup, cache validators, and single or multipart `206` responses.
- `std.http.Server.Request` adapter with buffered and opt-in streaming request bodies, `Content-Length`, chunked responses, WebSockets, and blocking `std.Io` serving.
- Configurable request body size limits.
- In-process tests through `ZAPI.handle`, `ZAPI.handleOrRaise`, `Response.statusCode`, `Response.text`, `Response.bytes`, `Response.reason`, `Response.requestUrl`, `Response.location`, `Response.nextUrl`, typed `Response.json`, parsed `Response.cookie` and `Response.cookies`, redirect `Response.history`, owned `Request.builder` helpers, typed query serialization, typed JSON body serialization, typed URL-encoded form serialization, encoded form fields, request scope helpers, WebSocket text and JSON exchanges with handshake and message helpers, and a persistent `TestClient` with base URLs, absolute request URLs, configurable client addresses, mutable default headers, query params, and cookies, domain/path-scoped response cookies, persisted cookie inspection and snapshots, request scope defaults, redirect following, client-level and per-request server-exception controls, and lifespan support.

## Not Yet

- A larger async/non-blocking serving story beyond the current blocking `std.Io` adapter.
- A complete Starlette compatibility test port.
