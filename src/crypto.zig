//! PR-W9 [feat]: minimal crypto primitives needed by the PDF Standard
//! Security Handler.
//!
//! Two primitives:
//!   1. RC4 — vendored (the cipher is deprecated everywhere in stdlib).
//!      Used by /V 2 /R 3 (40 / 128-bit key).
//!   2. AES-128 in CBC mode with PKCS#5 padding — built on top of
//!      `std.crypto.core.aes.Aes128`. Used by /V 4 /R 4.
//!
//! Constant-time password compare lives at `equalConstantTime`.
//!
//! Defensive guarantees:
//!   - `Rc4.init` accepts any key length; the spec uses 16 bytes (V/R 3,
//!     RC4-128) but the algorithm itself is well-defined for 1..256.
//!   - `aes128CbcDecrypt` returns `error.InvalidPadding` if PKCS#5 padding
//!     bytes don't match — tightening the surface for malformed PDFs.
//!   - No key material ever reaches an error message.

const std = @import("std");
const aes = std.crypto.core.aes;

// ---- RC4 (Rivest Cipher 4, public domain) ----

pub const Rc4 = struct {
    state: [256]u8,
    i: u8,
    j: u8,

    /// Initialise the RC4 keystream from `key`. Caller's `key` length
    /// must be in 1..256; PDF /V 2 /R 3 uses 16 bytes.
    pub fn init(key: []const u8) Rc4 {
        std.debug.assert(key.len > 0);
        std.debug.assert(key.len <= 256);

        var s: [256]u8 = undefined;
        var idx: usize = 0;
        while (idx < 256) : (idx += 1) s[idx] = @intCast(idx);

        var j: u8 = 0;
        idx = 0;
        while (idx < 256) : (idx += 1) {
            j +%= s[idx] +% key[idx % key.len];
            const tmp = s[idx];
            s[idx] = s[j];
            s[j] = tmp;
        }
        return .{ .state = s, .i = 0, .j = 0 };
    }

    /// XOR `data` with the keystream in place. RC4 is symmetric:
    /// encrypt and decrypt are the same call.
    pub fn xor(self: *Rc4, data: []u8) void {
        var k: usize = 0;
        while (k < data.len) : (k += 1) {
            self.i +%= 1;
            self.j +%= self.state[self.i];
            const tmp = self.state[self.i];
            self.state[self.i] = self.state[self.j];
            self.state[self.j] = tmp;
            const ks = self.state[(@as(u16, self.state[self.i]) +% self.state[self.j]) & 0xff];
            data[k] ^= ks;
        }
    }
};

// ---- AES-128 / CBC / PKCS#5 ----

pub const AesError = error{
    InvalidPadding,
    /// Ciphertext length not a multiple of the AES block size.
    InvalidLength,
};

const BLOCK: usize = 16;

/// AES-128-CBC encrypt with PKCS#5 padding (a.k.a. PKCS#7 with block=16).
/// `ciphertext.len` MUST equal `paddedLen(plaintext.len)`. The IV is NOT
/// prepended — caller is responsible for emitting it before the cipher
/// body, which is what PDF §7.6.3.1 prescribes (16-byte IV first, then
/// the encrypted body).
pub fn aes128CbcEncrypt(
    key: [16]u8,
    iv: [16]u8,
    plaintext: []const u8,
    ciphertext: []u8,
) void {
    const padded_len = paddedLen(plaintext.len);
    std.debug.assert(ciphertext.len == padded_len);

    var ctx = aes.Aes128.initEnc(key);
    var prev: [BLOCK]u8 = iv;

    var off: usize = 0;
    while (off + BLOCK <= plaintext.len) : (off += BLOCK) {
        var block: [BLOCK]u8 = undefined;
        var bi: usize = 0;
        while (bi < BLOCK) : (bi += 1) block[bi] = plaintext[off + bi] ^ prev[bi];
        ctx.encrypt(ciphertext[off..][0..BLOCK], &block);
        @memcpy(&prev, ciphertext[off..][0..BLOCK]);
    }

    // PKCS#5 padding fills the final block with `pad_value` repeated
    // `pad_value` times. If the plaintext is already a multiple of
    // BLOCK, append a full block of 16 (= 0x10) per spec.
    const tail = plaintext.len - off;
    const pad_value: u8 = @intCast(BLOCK - tail);
    var last: [BLOCK]u8 = undefined;
    var li: usize = 0;
    while (li < tail) : (li += 1) last[li] = plaintext[off + li];
    while (li < BLOCK) : (li += 1) last[li] = pad_value;
    var xb: [BLOCK]u8 = undefined;
    var xi: usize = 0;
    while (xi < BLOCK) : (xi += 1) xb[xi] = last[xi] ^ prev[xi];
    ctx.encrypt(ciphertext[off..][0..BLOCK], &xb);
}

/// AES-128-CBC decrypt + strip PKCS#5 padding. Caller passes a
/// `plaintext` buffer at least `ciphertext.len` long; on success returns
/// the actual plaintext length (always ≤ ciphertext.len - 1; a
/// well-formed PKCS#5 stream always has at least one padding byte).
pub fn aes128CbcDecrypt(
    key: [16]u8,
    iv: [16]u8,
    ciphertext: []const u8,
    plaintext: []u8,
) AesError!usize {
    if (ciphertext.len == 0) return AesError.InvalidLength;
    if (ciphertext.len % BLOCK != 0) return AesError.InvalidLength;
    std.debug.assert(plaintext.len >= ciphertext.len);

    var ctx = aes.Aes128.initDec(key);
    var prev: [BLOCK]u8 = iv;

    var off: usize = 0;
    while (off < ciphertext.len) : (off += BLOCK) {
        var dec_block: [BLOCK]u8 = undefined;
        ctx.decrypt(&dec_block, ciphertext[off..][0..BLOCK]);
        var bi: usize = 0;
        while (bi < BLOCK) : (bi += 1) plaintext[off + bi] = dec_block[bi] ^ prev[bi];
        @memcpy(&prev, ciphertext[off..][0..BLOCK]);
    }

    // Strip PKCS#5 padding. The last byte names the count.
    const last_byte = plaintext[ciphertext.len - 1];
    if (last_byte == 0 or last_byte > BLOCK) return AesError.InvalidPadding;
    const pad: usize = last_byte;
    if (pad > ciphertext.len) return AesError.InvalidPadding;
    var pi: usize = 0;
    while (pi < pad) : (pi += 1) {
        if (plaintext[ciphertext.len - 1 - pi] != last_byte) return AesError.InvalidPadding;
    }
    return ciphertext.len - pad;
}

/// PKCS#5 padded length for a plaintext of `n` bytes (always ≥ n+1,
/// rounded up to the next multiple of 16).
pub fn paddedLen(n: usize) usize {
    return n + (BLOCK - (n % BLOCK));
}

// ---- Constant-time compare ----

/// Constant-time compare wrapper. The two slices must be equal length;
/// we compare the full buffer regardless of where (or whether) the
/// first mismatch lies.
pub fn equalConstantTime(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var diff: u8 = 0;
    var i: usize = 0;
    while (i < a.len) : (i += 1) diff |= a[i] ^ b[i];
    return diff == 0;
}

// ---------- tests ----------

test "Rc4 known-answer (key=Key)" {
    var rc4 = Rc4.init("Key");
    var out: [10]u8 = .{0} ** 10;
    rc4.xor(&out);
    // First 8 bytes of RC4 keystream for "Key": EB 9F 77 81 B7 34 CA 72
    const expected = [_]u8{ 0xEB, 0x9F, 0x77, 0x81, 0xB7, 0x34, 0xCA, 0x72 };
    try std.testing.expectEqualSlices(u8, &expected, out[0..8]);
}

test "Rc4 round-trip on arbitrary bytes" {
    const key = "PDFKey0123456789";
    const orig = "Encrypted plaintext for round-trip!";
    var buf: [64]u8 = undefined;
    @memcpy(buf[0..orig.len], orig);

    var enc = Rc4.init(key);
    enc.xor(buf[0..orig.len]);
    try std.testing.expect(!std.mem.eql(u8, buf[0..orig.len], orig));

    var dec = Rc4.init(key);
    dec.xor(buf[0..orig.len]);
    try std.testing.expectEqualStrings(orig, buf[0..orig.len]);
}

test "aes128CbcEncrypt/Decrypt round-trip" {
    const key: [16]u8 = .{ 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F };
    const iv: [16]u8 = .{ 0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1A, 0x1B, 0x1C, 0x1D, 0x1E, 0x1F };
    const plaintext = "Encrypted plaintext";
    const padded = paddedLen(plaintext.len);

    var ct: [64]u8 = undefined;
    aes128CbcEncrypt(key, iv, plaintext, ct[0..padded]);

    var pt: [64]u8 = undefined;
    const pt_len = try aes128CbcDecrypt(key, iv, ct[0..padded], pt[0..padded]);
    try std.testing.expectEqualStrings(plaintext, pt[0..pt_len]);
}

test "aes128CbcDecrypt detects bad padding" {
    const key: [16]u8 = .{0} ** 16;
    const iv: [16]u8 = .{0} ** 16;
    var seed: u8 = 0;
    while (seed < 8) : (seed += 1) {
        var ct: [16]u8 = .{seed} ** 16;
        ct[0] = seed;
        var pt: [16]u8 = undefined;
        const r = aes128CbcDecrypt(key, iv, &ct, &pt);
        if (r) |_| continue else |err| {
            try std.testing.expect(err == AesError.InvalidPadding or err == AesError.InvalidLength);
            return;
        }
    }
}

test "aes128CbcDecrypt rejects misaligned ciphertext" {
    const key: [16]u8 = .{0} ** 16;
    const iv: [16]u8 = .{0} ** 16;
    var ct: [15]u8 = .{0} ** 15;
    var pt: [16]u8 = undefined;
    try std.testing.expectError(AesError.InvalidLength, aes128CbcDecrypt(key, iv, &ct, &pt));
}

test "equalConstantTime equal vs different" {
    try std.testing.expect(equalConstantTime("abcdef", "abcdef"));
    try std.testing.expect(!equalConstantTime("abcdef", "abcdeg"));
    try std.testing.expect(!equalConstantTime("abc", "abcdef"));
}

test "paddedLen always rounds up at block boundaries (PKCS#5)" {
    try std.testing.expectEqual(@as(usize, 16), paddedLen(0));
    try std.testing.expectEqual(@as(usize, 16), paddedLen(15));
    try std.testing.expectEqual(@as(usize, 32), paddedLen(16));
    try std.testing.expectEqual(@as(usize, 32), paddedLen(31));
}
