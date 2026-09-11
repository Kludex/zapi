//! Sessions middleware.

const applications = @import("../applications.zig");
const options_mod = @import("options.zig");

/// Configuration for sessions middleware.
pub const Options = options_mod.SessionOptions;
/// Creates sessions middleware with comptime configuration.
pub const middleware = applications.sessionMiddleware;
