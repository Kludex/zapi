//! Gzip middleware.

const applications = @import("../applications.zig");
const options_mod = @import("options.zig");

/// Configuration for gzip middleware.
pub const Options = options_mod.GzipOptions;
/// Creates gzip middleware with comptime configuration.
pub const middleware = applications.gzipMiddleware;
