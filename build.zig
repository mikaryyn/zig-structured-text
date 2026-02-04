const std = @import("std");

pub fn build(b: *std.Build) void {
    const mod = b.addModule("structured_text", .{
        .root_source_file = b.path("src/root.zig"),
        .target = b.standardTargetOptions(.{}),
    });

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);
    b.step("test", "Run tests").dependOn(&run_mod_tests.step);
}
