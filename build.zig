const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});
    const root = b.addModule("gol", .{
        .optimize = optimize,
        .target = target,
        .root_source_file = b.path("src/main.zig"),
    });

    const exe = b.addExecutable(.{
        .name = "gol",
        .root_module = root,
    });

    const dvui_dep = b.dependency("dvui", .{ .target = target, .optimize = optimize, .backend = .sdl3 });
    exe.root_module.addImport("dvui", dvui_dep.module("dvui_sdl3"));

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run = b.step("run", "run app");
    run.dependOn(&run_cmd.step);
}
