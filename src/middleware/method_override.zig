//! Method override middleware.

const applications = @import("../applications.zig");
const options_mod = @import("options.zig");

/// Configuration for method override middleware.
pub const Options = options_mod.MethodOverrideOptions;
/// Creates method override middleware with comptime configuration.
pub const middleware = applications.methodOverrideMiddleware;
