//! ZPDF Benchmark Suite
//!
//! Measures extraction performance on a target PDF.
//! Run with: zig build bench -- path/to/test.pdf
//!
//! The MuPDF cross-comparison was dropped during the Zig 0.16 migration —
//! `std.process.Child` was rewritten and the previous `spawnAndWait` flow
//! is gone. The CI bench loop only uses the ZPDF self-bench numbers, so
//! the mutool branch is no longer load-bearing.

const std = @import("std");
const zpdf = @import("root.zig");

const WARMUP_RUNS = 2;
const BENCH_RUNS = 5;

pub fn main(init: std.process.Init) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    const args = if (argv.len > 1) argv[1..] else &[_][:0]const u8{};

    if (args.len < 1) {
        std.debug.print(
            \\ZPDF Benchmark Suite
            \\
            \\Usage: zig build bench -- <pdf_file>
            \\
        , .{});
        return;
    }

    const pdf_path = args[0];

    std.debug.print(
        \\╔══════════════════════════════════════════════════════════════╗
        \\║                    ZPDF Benchmark Suite                      ║
        \\╚══════════════════════════════════════════════════════════════╝
        \\
        \\File: {s}
        \\
    , .{pdf_path});

    const file = std.Io.Dir.cwd().openFile(init.io, pdf_path, .{}) catch |err| {
        std.debug.print("Error opening file: {}\n", .{err});
        return;
    };
    const file_size = (try file.stat(init.io)).size;
    file.close(init.io);

    std.debug.print("Size: {d:.2} MB\n\n", .{@as(f64, @floatFromInt(file_size)) / (1024 * 1024)});

    std.debug.print("── ZPDF Performance ───────────────────────────────────────────\n", .{});

    // Warm-up runs (untimed) so the OS page cache + JIT decisions stabilise.
    for (0..WARMUP_RUNS) |_| {
        const doc = zpdf.Document.open(allocator, init.io, pdf_path) catch return;
        var counter = CharCounter{};
        for (0..doc.pages.items.len) |pn| doc.extractText(pn, &counter) catch continue;
        doc.close();
    }

    var times: [BENCH_RUNS]i128 = undefined;
    var page_count: usize = 0;

    for (&times) |*t| {
        const start_ns = std.Io.Timestamp.now(init.io, .real).nanoseconds;

        const doc = zpdf.Document.open(allocator, init.io, pdf_path) catch |err| {
            std.debug.print("ZPDF error: {}\n", .{err});
            return;
        };
        page_count = doc.pages.items.len;

        var counter = CharCounter{};
        for (0..doc.pages.items.len) |pn| {
            doc.extractText(pn, &counter) catch continue;
        }

        doc.close();

        const end_ns = std.Io.Timestamp.now(init.io, .real).nanoseconds;
        t.* = end_ns - start_ns;
    }

    const stats = calcStats(&times);
    std.debug.print("Time:      {d:>8.2} ms (±{d:.2})\n", .{ stats.mean / 1e6, stats.stddev / 1e6 });
    std.debug.print("Pages:     {}\n", .{page_count});
    std.debug.print("Throughput:{d:>8.2} MB/s\n", .{
        @as(f64, @floatFromInt(file_size)) / (stats.mean / 1e9) / (1024 * 1024),
    });
}

const Stats = struct { mean: f64, stddev: f64 };

fn calcStats(times: []const i128) Stats {
    var sum: f64 = 0;
    for (times) |t| sum += @floatFromInt(t);
    const mean = sum / @as(f64, @floatFromInt(times.len));
    var variance: f64 = 0;
    for (times) |t| {
        const diff = @as(f64, @floatFromInt(t)) - mean;
        variance += diff * diff;
    }
    return .{ .mean = mean, .stddev = @sqrt(variance / @as(f64, @floatFromInt(times.len))) };
}

const CharCounter = struct {
    count: usize = 0,
    pub fn writeAll(self: *CharCounter, data: []const u8) !void {
        self.count += data.len;
    }
    pub fn writeByte(self: *CharCounter, _: u8) !void {
        self.count += 1;
    }
};
