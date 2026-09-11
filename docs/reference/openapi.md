---
icon: lucide/file-json
---

# OpenAPI

`zapi` generates OpenAPI 3.1 from the same route definitions that handle requests.

Runtime `CONNECT` routes are omitted from the schema because OpenAPI path items do not define a `connect` operation.

```zig
zapi.Route.post("/users", createUser, .{
    .status = .created,
    .summary = "Create user",
    .description = "Create a user account.",
    .tags = &.{"users"},
})
```

The route status becomes the main success response. Handler input wrappers become request parameters or request bodies. Handler return types become JSON Schema response components. `1xx`, `204 No Content`, and `304 Not Modified` statuses do not emit response content, even when the handler return type has a schema.

Use `zapi.Json(T)` when a response helper should serialize a typed value and document `T` as the JSON response schema. Use `zapi.RawJson` for already-serialized JSON when the operation should advertise `application/json` without a schema.

App options such as `title`, `version`, `description`, `terms_of_service`, `contact`, `license`, `openapi_servers`, `openapi_tags`, and `external_docs` populate the top-level OpenAPI document.

## Operation Metadata

Route options can set:

- `summary`
- `description`
- `operation_id`
- `tags`
- `status`
- `deprecated`
- `include_in_schema`
- `external_docs`
- `parameter_docs`
- `response_description`
- `responses`

## Extra Responses

Document error responses with response docs.

```zig
zapi.Route.post("/users", createUser, .{
    .responses = &.{
        zapi.responseDoc(.conflict, ErrorMessage, .{
            .description = "Email already exists.",
        }),
    },
})
```

## Docs Routes

By default, every app serves:

- `/openapi.json`
- `/docs`
- `/docs/oauth2-redirect`
- `/redoc`

Swagger UI uses `/docs/oauth2-redirect` for OAuth2 authorization flows. Set `oauth2_redirect_url = null` to omit that helper route, or set it to a custom path when `docs_url` is customized.

Mounted apps use their mount path when generating docs URLs and the OAuth2 redirect URL.
