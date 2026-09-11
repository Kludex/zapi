//! Request id middleware.

const applications = @import("../applications.zig");
const options_mod = @import("options.zig");

/// Configuration for request id middleware.
pub const Options = options_mod.RequestIdOptions;
/// Creates request id middleware with comptime configuration.
pub const middleware = applications.requestIdMiddleware;
