//! Https redirect middleware.

const applications = @import("../applications.zig");
const options_mod = @import("options.zig");

/// Configuration for https redirect middleware.
pub const Options = options_mod.HttpsRedirectOptions;
/// Creates https redirect middleware with comptime configuration.
pub const middleware = applications.httpsRedirectMiddleware;
