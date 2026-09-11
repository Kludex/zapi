//! Request body limit middleware.

const applications = @import("../applications.zig");
const options_mod = @import("options.zig");

/// Configuration for request body limit middleware.
pub const Options = options_mod.RequestBodyLimitOptions;
/// Creates request body limit middleware with comptime configuration.
pub const middleware = applications.requestBodyLimitMiddleware;
