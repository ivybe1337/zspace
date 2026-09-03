const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const root_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const exe = b.addExecutable(.{
        .name = "zspace",
        .root_module = root_mod,
    });

    if (target.result.os.tag == .macos) {
        root_mod.linkFramework("Cocoa", .{});
        root_mod.linkFramework("Metal", .{});
        root_mod.linkFramework("QuartzCore", .{});
        root_mod.linkFramework("CoreGraphics", .{});
    }

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run ZSpace");
    run_step.dependOn(&run_cmd.step);

    const test_exe = b.addTest(.{
        .root_module = root_mod,
    });
    const run_test = b.addRunArtifact(test_exe);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_test.step);
}
