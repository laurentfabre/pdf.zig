//! pdf.zig binary entry point. Delegates to cli_pdfzig.run().
//!
//! Exit codes are defined by cli_pdfzig.ExitCode (0 ok, 1 arg, 2 io,
//! 3 not_a_pdf, 4 encrypted, 5 oom, 130/143 interrupted, 141 sigpipe).

const std = @import("std");
const cli = @import("cli_pdfzig.zig");

pub fn main() !u8 {
    // Production allocator: smp_allocator is fast, low-overhead, and does not
    // do leak detection. Process exit reclaims everything; chasing upstream
    // leaks is a separate workstream from the streaming layer's correctness.
    const allocator = std.heap.smp_allocator;

    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    const args = if (argv.len > 1) argv[1..] else &[_][]const u8{};

    const code = cli.run(allocator, args) catch |err| {
        var buf: [256]u8 = undefined;
        var bw = std.fs.File.stderr().writer(&buf);
        const w = &bw.interface;
        defer w.flush() catch {};
        w.print("pdf.zig: fatal: {s}\n", .{@errorName(err)}) catch {};
        return @intFromEnum(cli.ExitCode.io_error);
    };

    return @intFromEnum(code);
}
