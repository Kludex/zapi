//! Response headers middleware.

const applications = @import("../applications.zig");
const options_mod = @import("options.zig");

/// Configuration for response headers middleware.
pub const Options = options_mod.ResponseHeadersOptions;
/// Creates response headers middleware with comptime configuration.
pub const middleware = applications.responseHeadersMiddleware;
