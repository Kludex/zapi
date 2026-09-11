//! Proxy headers middleware.

const applications = @import("../applications.zig");
const options_mod = @import("options.zig");

/// Configuration for proxy headers middleware.
pub const Options = options_mod.ProxyHeadersOptions;
/// Creates proxy headers middleware with comptime configuration.
pub const middleware = applications.proxyHeadersMiddleware;
