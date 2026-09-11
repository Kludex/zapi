//! Security headers middleware.

const applications = @import("../applications.zig");
const options_mod = @import("options.zig");

/// Configuration for security headers middleware.
pub const Options = options_mod.SecurityHeadersOptions;
/// Creates security headers middleware with comptime configuration.
pub const middleware = applications.securityHeadersMiddleware;
