//! Built-in HTTP middleware.
//! Each middleware module exports `Options` and `middleware`.

const applications = @import("../applications.zig");
pub const options = @import("options.zig");
pub const cors = @import("cors.zig");
pub const gzip = @import("gzip.zig");
pub const https_redirect = @import("https_redirect.zig");
pub const method_override = @import("method_override.zig");
pub const proxy_headers = @import("proxy_headers.zig");
pub const request_body_limit = @import("request_body_limit.zig");
pub const request_id = @import("request_id.zig");
pub const response_headers = @import("response_headers.zig");
pub const security_headers = @import("security_headers.zig");
pub const sessions = @import("sessions.zig");
pub const trusted_host = @import("trusted_host.zig");

pub const MiddlewareFn = applications.MiddlewareFn;
pub const MiddlewareContext = applications.MiddlewareContext;

pub const CorsOptions = cors.Options;
pub const GzipOptions = gzip.Options;
pub const HttpsRedirectOptions = https_redirect.Options;
pub const MethodOverrideOptions = method_override.Options;
pub const ProxyHeadersOptions = proxy_headers.Options;
pub const RequestBodyLimitOptions = request_body_limit.Options;
pub const RequestIdOptions = request_id.Options;
pub const ResponseHeadersOptions = response_headers.Options;
pub const SecurityHeadersOptions = security_headers.Options;
pub const SessionOptions = sessions.Options;
pub const TrustedHostOptions = trusted_host.Options;

test {
    _ = options;
    _ = cors;
    _ = gzip;
    _ = https_redirect;
    _ = method_override;
    _ = proxy_headers;
    _ = request_body_limit;
    _ = request_id;
    _ = response_headers;
    _ = security_headers;
    _ = sessions;
    _ = trusted_host;
}
