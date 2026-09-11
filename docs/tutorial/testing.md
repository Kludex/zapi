---
icon: lucide/test-tube
---

# Testing

`zapi` apps can be tested in process. Build a request, pass it to the app, and inspect the response.

```zig
test "hello" {
    var app = zapi.ZAPI.init(std.testing.allocator, .{});
    defer app.deinit();

    try app.includeRouter(zapi.Router.init(.{
        .routes = .{
            zapi.Route.get("/", hello, .{}),
        },
    }));

    var response = try app.handle(zapi.Request.init(.GET, "/"));
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqual(zapi.Status.ok, response.status);

    var data = try response.json(struct { message: []const u8 }, std.testing.allocator);
    defer data.deinit();

    try std.testing.expectEqualStrings("Hello from Zig", data.value.message);
}
```

Use `response.text()`, `response.bytes()`, or `response.content()` when a test needs the raw response body. Use `response.json(T, allocator)` when the body should be parsed and checked as typed data.
Use `response.contentType()` or `response.hasContentType()` when a test should check the media type without caring about parameters such as `charset`.

Use `response.isSuccess()`, `response.isRedirect()`, `response.isClientError()`, `response.isServerError()`, or `response.isError()` when an assertion only cares about the status code range.
Use `response.reason()` when a test should assert the response reason phrase.
Use `response.expectStatus(.ok)` or `response.expectSuccess()` when a test should fail with `error.UnexpectedStatus`.
Use `response.raiseForStatus()` when only 4xx and 5xx responses should fail, leaving redirects as valid responses.

## Request Builder

Use `Request.builder` when a test needs owned headers, cookies, request bodies, request scope, or redirect following.

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
    .tag = [_][]const u8{ "zig api", "web framework" },
    .limit = 20,
});
try request.setQueryParam("locale", "en-US");
try request.removeQueryParam("debug");
try request.jsonValue(CreateUser{ .email = "ada@example.com" });

var response = try request.send(&app);
defer response.deinit(std.testing.allocator);
```

Use `request.sendOrRaise(&app)` when a test should receive unhandled handler errors instead of the generated `500` response.

Responses sent through `TestClient` include the effective request URL. Use `response.statusCode()` when a test needs the numeric HTTP status. Use `response.requestUrl()` when a test needs to assert the final URL after redirects. For no-follow redirect tests, use `response.location()` for the raw `Location` header and `response.nextUrl(allocator)` for the resolved URL the client would request next.

Use `sendFollowRedirects` when a test should follow redirect responses like a client. Use `sendFollowRedirectsOrRaise` when unhandled handler errors during the redirect chain should be returned to the test. Cookies set by redirects are sent to later requests in the chain. Relative redirects resolve `.` and `..` path segments, absolute redirects update the request scheme and host, scheme-relative redirects inherit the current scheme while updating the host, and redirect history entries keep their own request URLs. Cross-host redirects stay in process and route back into the same app with the redirected `Host`, like Starlette's test client. `301`, `302`, and `303` switch non-HEAD write requests to `GET` and drop the body plus body headers such as `Content-Type`; `307` and `308` preserve the method, body, and body headers.

Use `response.cookie(allocator, name)` when one parsed response cookie matters, and free the returned value when present. Use `response.cookies(allocator)` when a test needs the full parsed response cookie set.

## TestClient

Use `TestClient` when a group of requests should share defaults.

```zig
var client = zapi.TestClient.init(std.testing.allocator, &app, .{
    .base_url = "https://api.example.test/api",
    .headers = &.{.{ .name = "x-token", .value = "secret" }},
});
defer client.deinit();

try client.setHeader("x-token", "rotated-secret");
try std.testing.expect(client.hasHeader("X-Token"));
try std.testing.expectEqualStrings("rotated-secret", client.headerValue("x-token").?);
try client.accept("application/json");
try client.userAgent("zapi-test");
try client.queryParam("locale", "en-US");
try std.testing.expect(client.hasQueryParam("locale"));
try std.testing.expectEqualStrings("en-US", client.queryParamValue("locale").?);
try client.cookie("theme", "dark");
try client.bearerAuth("secret");
try client.apiKeyQuery("api_key", "secret");
try client.apiKeyCookie("session", "secret");

var cookies = try client.cookies(std.testing.allocator);
defer cookies.deinit();

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

var updated = try client.putQuery("/users/42", .{
    .notify = true,
});
defer updated.deinit(std.testing.allocator);

var submitted = try client.patchFormValue("/users/42", .{
    .email = "ada@example.com",
});
defer submitted.deinit(std.testing.allocator);

var deleted = try client.deleteFormValue("/users/42", .{
    .email = "ada@example.com",
});
defer deleted.deinit(std.testing.allocator);

var redirect_request = client.request(.GET, "/old-path");
defer redirect_request.deinit();

var redirect = try client.sendNoRedirects(&redirect_request);
defer redirect.deinit(std.testing.allocator);

var direct_redirect = try client.getNoRedirects("/old-path");
defer direct_redirect.deinit(std.testing.allocator);

var direct_followed = try client.getFollowRedirects("/old-path", .{
    .max_redirects = 5,
});
defer direct_followed.deinit(std.testing.allocator);
```

Use `client.get`, `post`, `put`, `patch`, `delete`, `options`, `head`, `trace`, and `connect` for standard method requests. Add typed query parameters with `getQuery`, `postQuery`, `putQuery`, `patchQuery`, `deleteQuery`, `optionsQuery`, `headQuery`, `traceQuery`, and `connectQuery`. Query helpers percent-encode UTF-8 values before sending them to the app. Use `request.queryParamValue(allocator, name)`, `request.queryParams(allocator)`, and `request.hasQueryParam(allocator, name)` to inspect a request builder's pending query string. Use `client.queryParamValue(name)`, `client.queryParamValues(allocator, name)`, and `client.hasQueryParam(name)` to inspect client defaults; free the slice returned by `queryParamValues`.

Use `client.websocketText(path, message)` for a one-message WebSocket exchange through the real std.http adapter. Use `client.websocketJson(path, json)` when the message is already encoded JSON, or `client.websocketJsonValue(path, value)` to serialize a Zig value before sending it. Use `client.websocketExchange(path, frames)` when the handler should receive several scripted text or binary frames. These helpers use the same base URL, default query params, default headers, and cookie jar as HTTP requests, and return an owned `WebSocketTestResponse` with the handshake status, response headers, first server frame, all parsed server frames in `messages`, and helpers such as `statusCode()`, `reason()`, `expectStatus()`, `hasHeader()`, `headerValues(allocator)`, `text()`, `binary()`, `json(T, allocator)`, `textMessages(allocator)`, and `binaryMessages(allocator)`. Free the parsed JSON result and the slices returned by `headerValues`, `textMessages`, and `binaryMessages`; the message bytes stay owned by the response.
Use JSON body helpers with `post`, `put`, `patch`, `delete`, `options`, or `trace` prefixes, such as `postJsonValue`, `deleteJson`, or `traceJsonValue`.
Use form and multipart helpers with `post`, `put`, `patch`, `delete`, `options`, or `trace` prefixes, such as `postFormValue`, `deleteFormFields`, or `traceMultipart`.
Use `queryParam`, `setQueryParam`, `removeQueryParam`, and `clearQueryParams` for query values shared by every request from the client. Request query values come after client defaults, so single-value parsers treat the request value as the override.
Use `bearerAuth`, `basicAuth`, `apiKeyHeader`, `apiKeyQuery`, and `apiKeyCookie` on the client when several requests share the same auth. A request builder can still override a client auth header or add request-specific query params for one request.
Use method-specific `NoRedirects` helpers, such as `getNoRedirects`, when one request should not follow redirects. Use method-specific `FollowRedirects` helpers, such as `getFollowRedirects`, when one request should follow redirects or set `max_redirects` regardless of the client default. Use `sendWithOptions`, `sendFollowRedirects`, or `sendNoRedirects` when the request is already a `Request.builder`.

By default, `TestClient` uses `http://testserver` as the request base. Set `base_url` for a different host or root path. When `base_url` contains a path, zapi uses it as `root_path`, so `request.url`, `request.urlPath`, `request.baseUrl`, and `ctx.urlFor` include that external prefix while routes still match the app-relative path. Request targets can be app-relative or include the configured root path prefix; the prefix is removed before routing. Absolute request URLs update the request scheme and `Host` before routing. Scheme-relative targets such as `//api.example.test/path` inherit the current request scheme and update `Host`. Followed absolute and scheme-relative redirects use the same rules. Redirects generated with `ctx.redirectTo` can include that external prefix in `Location`; the client removes it before routing the next request. Set `host = null` when a test should send no `Host` header.

`TestClient` sends `user-agent: testclient`, `accept: */*`, `accept-encoding: gzip, deflate, zstd`, and `connection: keep-alive` by default. Set a client header or a request header to override any of them.

Cookies set by responses are persisted with their `Domain`, `Path`, and `Secure` scope, so later requests only send them to matching hosts, paths, and schemes. `Max-Age` and epoch `Expires` deletion headers remove cookies from the jar regardless of the cookie value sent with them. A response cannot set a cookie for an unrelated domain. Like Starlette's test client, single-label hosts such as `testserver` also accept cookies scoped to their effective `.local` domain, such as `testserver.local`. When several matching cookies share a name, less-specific paths are sent before more-specific paths, so zapi handlers using last-value cookie parsing see the path-specific value.

By default, `TestClient` raises unhandled server errors. Set `raise_server_exceptions = false` when the test should inspect the generated `500` response. Use `sendWithOptions` with `.raise_server_exceptions = true` or `false` when one request should override the client default, including during redirect chains.
