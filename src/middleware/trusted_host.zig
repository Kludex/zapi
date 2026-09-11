//! Trusted host middleware.

const applications = @import("../applications.zig");
const options_mod = @import("options.zig");

/// Configuration for trusted host middleware.
pub const Options = options_mod.TrustedHostOptions;
/// Creates trusted host middleware with comptime configuration.
pub const middleware = applications.trustedHostMiddleware;
