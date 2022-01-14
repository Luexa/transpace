const Builder = @import("std").build.Builder;

pub fn build(b: *Builder) void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();
    b.enable_wasmtime = true;
    b.enable_wine = true;
    b.enable_qemu = true;

    const exe = b.addExecutable("transpace", "src/main.zig");
    exe.addPackagePath("zlaap", "deps/zlaap/zlaap.zig");
    exe.setTarget(target);
    exe.setBuildMode(mode);
    exe.strip = b.option(bool, "strip", "Strip debug info from the executable") orelse false;
    exe.install();

    const tests = b.addTest("src/main.zig");
    tests.setTarget(target);
    tests.setBuildMode(mode);
    tests.setFilter(b.option([]const u8, "test-filter", "Filter which tests to run"));

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Build and run the application");
    run_step.dependOn(&run_cmd.step);
    const test_step = b.step("test", "Run all tests for the application");
    test_step.dependOn(&tests.step);
}
