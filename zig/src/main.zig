const std = @import("std");

const vst3 = @import("vst3.zig");
const lindaleVst = @import("lindale_vst.zig");

pub fn main() !void {
	// Prints to stderr (it's a shortcut based on `std.io.getStdErr()`)
	std.debug.print("All your {s} are belong to us.\n", .{"cake"});
	std.debug.print("Test {any}\n", .{vst3.IID.FUnknown});

	// stdout is for the actual output of your application, for example if you
	// are implementing gzip, then only the compressed bytes should be sent to
	// stdout, not any debugging messages.
	const stdout_file = std.io.getStdOut().writer();
	var bw = std.io.bufferedWriter(stdout_file);
	const stdout = bw.writer();

	try stdout.print("well La    Di   Da..\n", .{});

	try bw.flush(); // Don't forget to flush!

	// _ = lindaleVst.GetPluginFactory();
}


comptime {
    std.testing.refAllDeclsRecursive(@import("vst3.zig"));
}