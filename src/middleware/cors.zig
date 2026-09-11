//! Cors middleware.

const applications = @import("../applications.zig");
const options_mod = @import("options.zig");

/// Configuration for cors middleware.
pub const Options = options_mod.CorsOptions;
/// Creates cors middleware with comptime configuration.
pub const middleware = applications.corsMiddleware;
