//! Static file serving and range handling.

pub const application = @import("application.zig");
pub const core = @import("core.zig");

pub const StaticFilesOptions = application.StaticFilesOptions;
pub const StaticFiles = application.StaticFiles;

test {
    _ = application;
    _ = core;
}
