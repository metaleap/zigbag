const std = @import("std");

const Builder = @import("std").build.Builder;

pub fn build(bld: *Builder) void {
    const mode = bld.standardReleaseOptions();

    const prog_atem = bld.addExecutable("zatem", "cmd/atem/main.zig");
    if (std.os.getenv("USER")) |username|
        if (std.mem.eql(u8, username, "_"))
            prog_atem.setOutputDir("/home/_/b/");
    prog_atem.setBuildMode(mode);
    prog_atem.addPackagePath("atem", "src/atem.zig");
    prog_atem.install();

    const run_cmd = prog_atem.run();
    run_cmd.step.dependOn(bld.getInstallStep());
    const run_step = bld.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
