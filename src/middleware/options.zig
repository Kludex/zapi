//! Configuration values for built-in middleware.
//! Middleware execution is owned by the application dispatcher.

const http = @import("../http.zig");
const sessions = @import("../sessions.zig");

const HeaderField = http.HeaderField;
const Method = http.Method;
const SameSite = sessions.SameSite;
const Status = http.Status;

pub const CorsOptions = struct {
    allow_origins: []const []const u8 = &.{"*"},
    allow_origin_patterns: []const []const u8 = &.{},
    allow_methods: []const Method = &.{.GET},
    allow_all_methods: bool = false,
    allow_headers: []const []const u8 = &.{},
    allow_credentials: bool = false,
    expose_headers: []const []const u8 = &.{},
    max_age: ?u32 = 600,
};

pub const cors_all_methods: []const Method = &.{ .GET, .POST, .PUT, .PATCH, .DELETE, .OPTIONS, .HEAD, .TRACE, .CONNECT };
pub const cors_safelisted_headers: []const []const u8 = &.{ "Accept", "Accept-Language", "Content-Language", "Content-Type" };

pub const GzipOptions = struct {
    minimum_size: usize = 500,
};

pub const RequestBodyLimitOptions = struct {
    max_size: usize,
    status: Status = .payload_too_large,
    detail: []const u8 = "Request body too large",
};

pub const MethodOverrideOptions = struct {
    header_name: []const u8 = "x-http-method-override",
    allowed_original_methods: []const Method = &.{.POST},
    allowed_override_methods: []const Method = &.{ .PUT, .PATCH, .DELETE },
};

pub const ProxyHeadersOptions = struct {
    forwarded_proto_header: []const u8 = "x-forwarded-proto",
    forwarded_host_header: []const u8 = "x-forwarded-host",
    forwarded_prefix_header: []const u8 = "x-forwarded-prefix",
};

pub const RequestIdOptions = struct {
    header_name: []const u8 = "x-request-id",
    default_value: ?[]const u8 = null,
};

pub const ResponseHeadersOptions = struct {
    headers: []const HeaderField = &.{},
    append_headers: []const HeaderField = &.{},
    preserve_existing: bool = false,
};

pub const SecurityHeadersOptions = struct {
    content_type_options: ?[]const u8 = "nosniff",
    frame_options: ?[]const u8 = "DENY",
    referrer_policy: ?[]const u8 = "no-referrer",
    permissions_policy: ?[]const u8 = null,
    content_security_policy: ?[]const u8 = null,
    strict_transport_security: ?[]const u8 = null,
};

pub const SessionOptions = struct {
    secret_key: []const u8,
    session_cookie: []const u8 = "session",
    max_age: ?i64 = 14 * 24 * 60 * 60,
    path: ?[]const u8 = "/",
    domain: ?[]const u8 = null,
    https_only: bool = false,
    http_only: bool = true,
    same_site: ?SameSite = .lax,
};

pub const TrustedHostOptions = struct {
    allowed_hosts: []const []const u8 = &.{"*"},
    www_redirect: bool = true,
};

pub const HttpsRedirectOptions = struct {
    status: Status = .temporary_redirect,
};
