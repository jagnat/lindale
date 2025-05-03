const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
	const target = b.standardTargetOptions(.{});

	const optimize = b.standardOptimizeOption(.{});

	// const exe = b.addExecutable(.{
		// .name = "lindale",
		// .root_source_file = b.path("src/main.zig"),
		// .target = target,
		// .optimize = optimize,
	// });

	const lib = b.addSharedLibrary(.{
		.name = "lindale",
		.root_source_file = b.path("src/main.zig"),
		.target = target,
		.optimize = optimize,
	});

	lib.linkLibC();

	b.installArtifact(lib);

	// const run_cmd = b.addRunArtifact(exe);

	// run_cmd.step.dependOn(b.getInstallStep());

	// This allows the user to pass arguments to the application in the build
	// command itself, like this: `zig build run -- arg1 arg2 etc`
	// if (b.args) |args| {
		// run_cmd.addArgs(args);
	// }

	// const run_step = b.step("run", "Run the app");
	// run_step.dependOn(&run_cmd.step);
}
