//! pdf.zig binary entry point. Delegates to cli_pdfzig.run().
//!
//! Exit codes are defined by cli_pdfzig.ExitCode (0 ok, 1 arg, 2 io,
//! 3 not_a_pdf, 4 encrypted, 5 oom, 130/143 interrupted, 141 sigpipe).

const std = @import("std");
const cli = @import("cli_pdfzig.zig");

pub fn main(init: std.process.Init) !u8 {
    const allocator = init.gpa;
    const io = init.io;

    // argv (skipping argv[0]) — `toSlice` allocates into the auto-cleaning
    // process arena, so no manual cleanup is needed.
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    const args = if (argv.len > 1) argv[1..] else &[_][:0]const u8{};

    // cli.run expects []const []const u8; convert from [:0]const u8.
    var args_list: std.ArrayList([]const u8) = .empty;
    defer args_list.deinit(allocator);
    try args_list.ensureTotalCapacity(allocator, args.len);
    for (args) |a| args_list.appendAssumeCapacity(a);

    const code = cli.run(allocator, io, args_list.items) catch |err| {
        var buf: [256]u8 = undefined;
        var bw = std.Io.File.stderr().writer(io, &buf);
        const w = &bw.interface;
        defer w.flush() catch {};
        w.print("pdf.zig: fatal: {s}\n", .{@errorName(err)}) catch {};
        return @intFromEnum(cli.ExitCode.io_error);
    };

    return @intFromEnum(code);
}
