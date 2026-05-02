//! UUIDv7 (time-ordered) generator per RFC 9562 §5.7.
//!
//! Layout (big-endian, 128 bits):
//!   - bits   0..47   unix_ts_ms     (48-bit Unix timestamp, milliseconds)
//!   - bits  48..51   ver = 0b0111   (4-bit version = 7)
//!   - bits  52..63   rand_a         (12 bits of entropy)
//!   - bits  64..65   var = 0b10     (2-bit RFC 9562 variant)
//!   - bits  66..127  rand_b         (62 bits of entropy)
//!
//! The streaming layer mints exactly one doc_id per CLI invocation, so the
//! ms-monotonicity counters described in RFC 9562 §6.2 are unnecessary —
//! 74 bits of entropy from std.crypto.random are sufficient.

const std = @import("std");

pub const Bytes = [16]u8;
pub const String = [36]u8;

pub fn v7Bytes(io: std.Io) Bytes {
    var ts: std.posix.timespec = undefined;
    _ = std.posix.system.clock_gettime(.REALTIME, &ts);
    const ts_ms: u64 = @intCast(@as(i64, @intCast(ts.sec)) * 1000 +
        @divTrunc(@as(i64, @intCast(ts.nsec)), std.time.ns_per_ms));
    var bytes: Bytes = undefined;

    std.mem.writeInt(u64, bytes[0..8], ts_ms << 16, .big);
    io.random(bytes[6..16]);

    bytes[6] = (bytes[6] & 0x0F) | 0x70;
    bytes[8] = (bytes[8] & 0x3F) | 0x80;

    return bytes;
}

pub fn v7(io: std.Io) String {
    return format(v7Bytes(io));
}

pub fn format(bytes: Bytes) String {
    const hex = "0123456789abcdef";
    var out: String = undefined;
    var src: usize = 0;
    var dst: usize = 0;

    inline for ([_]usize{ 4, 2, 2, 2, 6 }, 0..) |group_bytes, group_idx| {
        if (group_idx > 0) {
            out[dst] = '-';
            dst += 1;
        }
        var i: usize = 0;
        while (i < group_bytes) : (i += 1) {
            const b = bytes[src];
            out[dst] = hex[b >> 4];
            out[dst + 1] = hex[b & 0x0F];
            src += 1;
            dst += 2;
        }
    }

    return out;
}

// ---- tests ----

fn testIo() !struct { threaded: std.Io.Threaded, io: std.Io } {
    var t: std.Io.Threaded = .init(std.testing.allocator, .{});
    return .{ .threaded = t, .io = t.io() };
}

test "v7 string format" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const s = v7(io);
    try std.testing.expectEqual(@as(usize, 36), s.len);
    try std.testing.expectEqual(@as(u8, '-'), s[8]);
    try std.testing.expectEqual(@as(u8, '-'), s[13]);
    try std.testing.expectEqual(@as(u8, '-'), s[18]);
    try std.testing.expectEqual(@as(u8, '-'), s[23]);
    // Version nibble at position 14 must be '7'.
    try std.testing.expectEqual(@as(u8, '7'), s[14]);
    // Variant nibble at position 19 must be one of 8, 9, a, b.
    const variant_nibble = s[19];
    try std.testing.expect(
        variant_nibble == '8' or variant_nibble == '9' or
            variant_nibble == 'a' or variant_nibble == 'b',
    );
}

test "v7 bytes version + variant bits" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const b = v7Bytes(io);
    try std.testing.expectEqual(@as(u8, 0x70), b[6] & 0xF0);
    try std.testing.expectEqual(@as(u8, 0x80), b[8] & 0xC0);
}

test "v7 is time-ordered across milliseconds" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const a = v7Bytes(io);
    try io.sleep(.{ .nanoseconds = 2 * std.time.ns_per_ms }, .awake);
    const c = v7Bytes(io);
    // Compare the 48-bit timestamp prefix only.
    const ts_a = std.mem.readInt(u64, a[0..8], .big) >> 16;
    const ts_c = std.mem.readInt(u64, c[0..8], .big) >> 16;
    try std.testing.expect(ts_c >= ts_a);
}

test "v7 strings are unique across calls" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const a = v7(io);
    const b = v7(io);
    try std.testing.expect(!std.mem.eql(u8, &a, &b));
}
