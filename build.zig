const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zapi_mod = b.addModule("zapi", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{
        .name = "zapi",
        .root_module = zapi_mod,
        .linkage = .static,
    });
    b.installArtifact(lib);

    const lib_tests = b.addTest(.{
        .root_module = zapi_mod,
    });

    const test_step = b.step("test", "Run zapi tests");
    test_step.dependOn(&b.addRunArtifact(lib_tests).step);

    const example = b.addExecutable(.{
        .name = "hello",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/hello.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zapi", .module = zapi_mod },
            },
        }),
    });

    const run_example = b.addRunArtifact(example);
    const run_step = b.step("run-example", "Run the hello example");
    run_step.dependOn(&run_example.step);
}
