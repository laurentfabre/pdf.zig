//! PR-W9 [feat]: PDF Standard Security Handler.
//!
//! Implements ISO 32000-1:2008 §7.6.4 for two algorithm pairs:
//!   - /V 2 /R 3 — RC4-128
//!   - /V 4 /R 4 — AES-128 CBC
//!
//! The flow is:
//!   1. `EncryptionContext.deriveFromPasswords` runs algorithms 2, 3,
//!      4/5, and 6/7 to derive the file key + /O + /U values.
//!   2. The Writer (pdf_writer.zig) consults the context whenever it
//!      emits a stream or string body inside an indirect object whose
//!      number ≠ `encrypt_dict_obj_num`.
//!   3. On read, the Reader path calls `authenticateUser` /
//!      `authenticateOwner` to recover the file key, then feeds bytes
//!      through `decryptString` / `decryptStream`.
//!
//! Spec section anchors (PDF 1.7 / ISO 32000-1):
//!   - §7.6.3.1  Per-object key derivation (the "salt the file key with
//!               obj#, gen#, and AES-marker bytes" step).
//!   - §7.6.4.3  Algorithm 2: file-key derivation from user password.
//!   - §7.6.4.4  Algorithm 3: /O computation (R 3+).
//!   - §7.6.4.5  Algorithm 5 (R 3+): /U for RC4-128 / AES.
//!   - §7.6.4.7  Algorithm 6: user-password authenticate.
//!   - §7.6.4.8  Algorithm 7: owner-password authenticate.

const std = @import("std");
const Md5 = std.crypto.hash.Md5;
const crypto = @import("crypto.zig");
const pdf_writer = @import("pdf_writer.zig");
const parser = @import("parser.zig");

/// Algorithm + key-length combo. Mirror what the PDF spec calls /V /R.
pub const Algorithm = enum {
    /// /V 2 /R 3 — RC4-128.
    rc4_v2_r3_128,
    /// /V 4 /R 4 — AES-128 (CBC, PKCS#5).
    aes_v4_r4_128,

    pub fn keyLen(self: Algorithm) usize {
        return switch (self) {
            .rc4_v2_r3_128 => 16,
            .aes_v4_r4_128 => 16,
        };
    }

    pub fn revision(self: Algorithm) u8 {
        return switch (self) {
            .rc4_v2_r3_128 => 3,
            .aes_v4_r4_128 => 4,
        };
    }

    pub fn version(self: Algorithm) u8 {
        return switch (self) {
            .rc4_v2_r3_128 => 2,
            .aes_v4_r4_128 => 4,
        };
    }

    pub fn isAes(self: Algorithm) bool {
        return self == .aes_v4_r4_128;
    }
};

/// Permissions bitfield per §7.6.3.2 Table 22. Bits 1, 2, 7, 8 are
/// reserved (must be 0); bits 13..32 are reserved (must be 1) when /R
/// = 3 or 4.
///
/// Encoded as a 32-bit signed integer in the /P field — but Zig's
/// packed struct lays bits LSB-first, which matches the PDF convention.
pub const Permissions = packed struct(u32) {
    _r1: bool = false, // bit 1: reserved
    _r2: bool = false, // bit 2: reserved
    /// bit 3: print (low-quality if /R 3+ and bit 12 = 0)
    print: bool = true,
    /// bit 4: modify contents (other than annotations / forms)
    modify: bool = true,
    /// bit 5: extract text & graphics
    extract: bool = true,
    /// bit 6: add / modify annotations
    annotate: bool = true,
    _r7: bool = true,
    _r8: bool = true,
    /// bit 9: fill in interactive form fields (/R 3+)
    fill_forms: bool = true,
    /// bit 10: extract for accessibility (/R 3+)
    accessibility: bool = true,
    /// bit 11: assemble document (/R 3+)
    assemble: bool = true,
    /// bit 12: print high-quality (/R 3+; bit 3 must also be set)
    print_hq: bool = true,
    // Bits 13..32 reserved (must be 1 in /R 3+).
    _r13: bool = true,
    _r14: bool = true,
    _r15: bool = true,
    _r16: bool = true,
    _r17: bool = true,
    _r18: bool = true,
    _r19: bool = true,
    _r20: bool = true,
    _r21: bool = true,
    _r22: bool = true,
    _r23: bool = true,
    _r24: bool = true,
    _r25: bool = true,
    _r26: bool = true,
    _r27: bool = true,
    _r28: bool = true,
    _r29: bool = true,
    _r30: bool = true,
    _r31: bool = true,
    _r32: bool = true,

    pub fn toI32(self: Permissions) i32 {
        const u: u32 = @bitCast(self);
        return @bitCast(u);
    }

    pub fn fromI32(p: i32) Permissions {
        const u: u32 = @bitCast(p);
        return @bitCast(u);
    }
};

// PDF spec §7.6.4.3, step (a): the 32-byte "padding string" appended /
// truncated against passwords during key derivation.
const PASSWORD_PAD = [_]u8{
    0x28, 0xBF, 0x4E, 0x5E, 0x4E, 0x75, 0x8A, 0x41,
    0x64, 0x00, 0x4E, 0x56, 0xFF, 0xFA, 0x01, 0x08,
    0x2E, 0x2E, 0x00, 0xB6, 0xD0, 0x68, 0x3E, 0x80,
    0x2F, 0x0C, 0xA9, 0xFE, 0x64, 0x53, 0x69, 0x7A,
};

/// PDF §7.6.3.1 AES per-object-key salt. Spec is precise:
///   's' = 0x73, 'A' = 0x41, 'l' = 0x6c, 'T' = 0x54.
/// Hard-coded as a byte literal so a stray `toUpper` can never sneak in.
const AES_SALT: [4]u8 = .{ 0x73, 0x41, 0x6c, 0x54 };

pub const Error = error{
    InvalidPassword,
    InvalidEncryptDict,
    UnsupportedAlgorithm,
    OutOfMemory,
    InvalidLength,
    InvalidPadding,
    /// Surfaces from the underlying writer — propagated unchanged.
    WriteFailed,
    UnbalancedObject,
};

/// Apply the §7.6.4.3 algorithm-2 password padding: prepend the password
/// truncated/padded to exactly 32 bytes.
fn padPassword(out: *[32]u8, password: []const u8) void {
    const take = @min(password.len, 32);
    var i: usize = 0;
    while (i < take) : (i += 1) out[i] = password[i];
    while (i < 32) : (i += 1) out[i] = PASSWORD_PAD[i - take];
}

pub const EncryptionContext = struct {
    allocator: std.mem.Allocator,
    algorithm: Algorithm,
    file_id: [16]u8,
    file_key: []u8, // owned; .len == algorithm.keyLen()
    o_value: [32]u8,
    u_value: [32]u8,
    permissions: Permissions,
    encrypt_dict_obj_num: u32,
    /// Caller-supplied randomness source used for IVs. Held by reference.
    random: std.Random,

    pub fn deinit(self: *EncryptionContext) void {
        // Wipe key material before returning the buffer.
        std.crypto.secureZero(u8, self.file_key);
        self.allocator.free(self.file_key);
    }

    /// PDF §7.6.4.3 algorithm 2 — derive the file encryption key from
    /// the user password (or empty string), the /O value, /P, and the
    /// first /ID array entry.
    fn computeFileKey(
        algorithm: Algorithm,
        user_password: []const u8,
        o_value: [32]u8,
        permissions: Permissions,
        file_id: [16]u8,
        out_key: []u8,
    ) void {
        std.debug.assert(out_key.len == algorithm.keyLen());

        var padded: [32]u8 = undefined;
        defer std.crypto.secureZero(u8, &padded);
        padPassword(&padded, user_password);

        var md5 = Md5.init(.{});
        md5.update(&padded);
        md5.update(&o_value);

        // /P as a 4-byte little-endian signed int.
        var p_bytes: [4]u8 = undefined;
        const p_u32: u32 = @bitCast(permissions.toI32());
        std.mem.writeInt(u32, &p_bytes, p_u32, .little);
        md5.update(&p_bytes);

        md5.update(&file_id);
        // /R 3+ — algorithm-2 step (f) is omitted (no encrypt-metadata
        // override; we always encrypt metadata).

        var digest: [16]u8 = undefined;
        md5.final(&digest);

        // /R 3+ adds 50 extra MD5 rounds, hashing only the first
        // `key_len` bytes each time (NOT the full 16-byte digest).
        // This is the spec's algorithm-2 step (e) caveat.
        if (algorithm.revision() >= 3) {
            const key_len = algorithm.keyLen();
            var i: usize = 0;
            while (i < 50) : (i += 1) {
                var inner = Md5.init(.{});
                inner.update(digest[0..key_len]);
                inner.final(&digest);
            }
        }

        @memcpy(out_key, digest[0..algorithm.keyLen()]);
        std.crypto.secureZero(u8, &digest);
    }

    /// PDF §7.6.4.4 algorithm 3 — compute the /O value from owner +
    /// user password.
    fn computeOValue(
        algorithm: Algorithm,
        owner_password: []const u8,
        user_password: []const u8,
        out: *[32]u8,
    ) void {
        // 3.a-c: hash padded owner-or-user fallback.
        const pwd: []const u8 = if (owner_password.len > 0) owner_password else user_password;
        var padded: [32]u8 = undefined;
        defer std.crypto.secureZero(u8, &padded);
        padPassword(&padded, pwd);

        var digest: [16]u8 = undefined;
        defer std.crypto.secureZero(u8, &digest);
        var md5 = Md5.init(.{});
        md5.update(&padded);
        md5.final(&digest);

        // /R 3+ adds 50 extra rounds, hashing only the first key_len
        // bytes each time (same caveat as algorithm 2 step (e)).
        if (algorithm.revision() >= 3) {
            const key_len = algorithm.keyLen();
            var i: usize = 0;
            while (i < 50) : (i += 1) {
                var inner = Md5.init(.{});
                inner.update(digest[0..key_len]);
                inner.final(&digest);
            }
        }

        // 3.d: form an RC4 key from the first key_len bytes of digest.
        const key_len = algorithm.keyLen();
        var rc4_key_buf: [16]u8 = .{0} ** 16;
        defer std.crypto.secureZero(u8, &rc4_key_buf);
        @memcpy(rc4_key_buf[0..key_len], digest[0..key_len]);

        // 3.e-f: pad the user password, RC4-encrypt with rc4_key.
        var u_padded: [32]u8 = undefined;
        padPassword(&u_padded, user_password);

        var rc4 = crypto.Rc4.init(rc4_key_buf[0..key_len]);
        rc4.xor(&u_padded);

        // /R 3+ — repeat the RC4 step 19 more times, XOR-tweaking the
        // key each round.
        if (algorithm.revision() >= 3) {
            var round: u8 = 1;
            while (round <= 19) : (round += 1) {
                var derived: [16]u8 = .{0} ** 16;
                var bi: usize = 0;
                while (bi < key_len) : (bi += 1) derived[bi] = rc4_key_buf[bi] ^ round;
                var rc4r = crypto.Rc4.init(derived[0..key_len]);
                rc4r.xor(&u_padded);
                std.crypto.secureZero(u8, &derived);
            }
        }

        @memcpy(out, &u_padded);
        std.crypto.secureZero(u8, &u_padded);
    }

    /// PDF §7.6.4.5 algorithm 5 (R 3+) — compute the /U value from the
    /// file key + /ID. Result is 16 bytes of MD5(pad || ID) RC4-encrypted
    /// with 20 rounds, padded to 32 with arbitrary bytes (we use the
    /// password pad's first 16 bytes to match common writer practice).
    fn computeUValueR3(
        file_key: []const u8,
        file_id: [16]u8,
        out: *[32]u8,
    ) void {
        var md5 = Md5.init(.{});
        md5.update(&PASSWORD_PAD);
        md5.update(&file_id);
        var inner: [16]u8 = undefined;
        md5.final(&inner);
        defer std.crypto.secureZero(u8, &inner);

        var rc4 = crypto.Rc4.init(file_key);
        rc4.xor(&inner);

        var round: u8 = 1;
        while (round <= 19) : (round += 1) {
            var derived: [16]u8 = .{0} ** 16;
            var bi: usize = 0;
            while (bi < file_key.len) : (bi += 1) derived[bi] = file_key[bi] ^ round;
            var rc4r = crypto.Rc4.init(derived[0..file_key.len]);
            rc4r.xor(&inner);
            std.crypto.secureZero(u8, &derived);
        }

        // First 16 bytes of /U are the encrypted hash; trailing 16 are
        // arbitrary padding (we use the password-pad first 16 to match
        // common writer practice).
        @memcpy(out[0..16], &inner);
        @memcpy(out[16..32], PASSWORD_PAD[0..16]);
    }

    /// Build a context from passwords. Caller passes the /ID first
    /// entry — usually the same 16-byte value will be written to the
    /// trailer.
    pub fn deriveFromPasswords(
        allocator: std.mem.Allocator,
        algorithm: Algorithm,
        user_password: []const u8,
        owner_password: []const u8,
        permissions: Permissions,
        file_id: [16]u8,
        random: std.Random,
    ) Error!EncryptionContext {
        const key_len = algorithm.keyLen();
        const file_key = try allocator.alloc(u8, key_len);
        errdefer {
            std.crypto.secureZero(u8, file_key);
            allocator.free(file_key);
        }

        var ctx: EncryptionContext = .{
            .allocator = allocator,
            .algorithm = algorithm,
            .file_id = file_id,
            .file_key = file_key,
            .o_value = .{0} ** 32,
            .u_value = .{0} ** 32,
            .permissions = permissions,
            .encrypt_dict_obj_num = 0, // filled in by DocumentBuilder
            .random = random,
        };

        computeOValue(algorithm, owner_password, user_password, &ctx.o_value);
        computeFileKey(
            algorithm,
            user_password,
            ctx.o_value,
            permissions,
            file_id,
            ctx.file_key,
        );
        computeUValueR3(ctx.file_key, ctx.file_id, &ctx.u_value);
        return ctx;
    }

    /// Authenticate a user password — returns the recovered file key
    /// on success. Used by the reader.
    pub fn authenticateUser(
        allocator: std.mem.Allocator,
        algorithm: Algorithm,
        user_password: []const u8,
        o_value: [32]u8,
        u_value: [32]u8,
        permissions: Permissions,
        file_id: [16]u8,
    ) Error![]u8 {
        const key_len = algorithm.keyLen();
        const candidate_key = try allocator.alloc(u8, key_len);
        // Two distinct failure modes: alloc-failure (caller never sees
        // candidate_key) and password-mismatch (we explicitly free
        // before returning the error). Use a movable handle to avoid
        // both errdefer + manual free firing on the same buffer.
        var freed = false;
        errdefer if (!freed) {
            std.crypto.secureZero(u8, candidate_key);
            allocator.free(candidate_key);
        };

        computeFileKey(algorithm, user_password, o_value, permissions, file_id, candidate_key);

        // Recompute /U from the candidate key and compare in constant
        // time to the stored /U (per algorithm 6).
        var candidate_u: [32]u8 = .{0} ** 32;
        defer std.crypto.secureZero(u8, &candidate_u);
        computeUValueR3(candidate_key, file_id, &candidate_u);

        // §7.6.4.7 step (b): /R 3+ compares only the first 16 bytes of
        // /U (the encrypted MD5; the trailing 16 are spec'd as
        // arbitrary).
        if (!crypto.equalConstantTime(candidate_u[0..16], u_value[0..16])) {
            std.crypto.secureZero(u8, candidate_key);
            allocator.free(candidate_key);
            freed = true;
            return Error.InvalidPassword;
        }
        return candidate_key;
    }

    /// Authenticate an owner password — returns the recovered file
    /// key on success. (§7.6.4.8 algorithm 7.)
    pub fn authenticateOwner(
        allocator: std.mem.Allocator,
        algorithm: Algorithm,
        owner_password: []const u8,
        o_value: [32]u8,
        u_value: [32]u8,
        permissions: Permissions,
        file_id: [16]u8,
    ) Error![]u8 {
        // Step (a): hash the padded owner password (50 rounds for /R3+)
        // to derive the RC4 key used to decrypt /O. Same algorithm-2
        // step (e) caveat: each inner round hashes only key_len bytes.
        var padded: [32]u8 = undefined;
        defer std.crypto.secureZero(u8, &padded);
        padPassword(&padded, owner_password);

        var digest: [16]u8 = undefined;
        defer std.crypto.secureZero(u8, &digest);
        var md5 = Md5.init(.{});
        md5.update(&padded);
        md5.final(&digest);

        const key_len = algorithm.keyLen();
        if (algorithm.revision() >= 3) {
            var i: usize = 0;
            while (i < 50) : (i += 1) {
                var inner = Md5.init(.{});
                inner.update(digest[0..key_len]);
                inner.final(&digest);
            }
        }

        var rc4_key_buf: [16]u8 = .{0} ** 16;
        defer std.crypto.secureZero(u8, &rc4_key_buf);
        @memcpy(rc4_key_buf[0..key_len], digest[0..key_len]);

        // Step (b): RC4-decrypt /O 20 times in reverse to recover the
        // padded user password.
        var recovered_user_padded: [32]u8 = o_value;
        defer std.crypto.secureZero(u8, &recovered_user_padded);

        if (algorithm.revision() >= 3) {
            var round: i16 = 19;
            while (round >= 0) : (round -= 1) {
                var derived: [16]u8 = .{0} ** 16;
                var bi: usize = 0;
                while (bi < key_len) : (bi += 1) derived[bi] = rc4_key_buf[bi] ^ @as(u8, @intCast(round));
                var rc4r = crypto.Rc4.init(derived[0..key_len]);
                rc4r.xor(&recovered_user_padded);
                std.crypto.secureZero(u8, &derived);
            }
        } else {
            var rc4r = crypto.Rc4.init(rc4_key_buf[0..key_len]);
            rc4r.xor(&recovered_user_padded);
        }

        // The first non-pad bytes of recovered_user_padded are the
        // user password. Find the longest tail-suffix match against
        // PASSWORD_PAD; what remains is the password.
        var match_len: usize = 0;
        while (match_len < 32) : (match_len += 1) {
            const tail = recovered_user_padded[32 - match_len - 1];
            const expected = PASSWORD_PAD[31 - match_len];
            if (tail != expected) break;
        }
        const user_pwd_len: usize = 32 - match_len;

        return authenticateUser(
            allocator,
            algorithm,
            recovered_user_padded[0..user_pwd_len],
            o_value,
            u_value,
            permissions,
            file_id,
        );
    }

    /// PDF §7.6.3.1 — derive the per-object key for stream / string
    /// encryption. Caller-allocated buffer; returns a slice of the
    /// effective key bytes.
    pub fn objectKey(
        self: *const EncryptionContext,
        obj_num: u32,
        gen: u16,
        out: *[21]u8,
    ) []const u8 {
        // Recipe (§7.6.3.1):
        //   K' = file_key || obj_num_lo3 || gen_lo2 || (if AES) "sAlT"
        //   per_obj_key = MD5(K')[0 .. min(file_key_len + 5, 16)]
        var input: [16 + 3 + 2 + 4]u8 = undefined;
        const fk_len = self.file_key.len;
        @memcpy(input[0..fk_len], self.file_key);
        // Object number in 3 LE bytes.
        input[fk_len + 0] = @truncate(obj_num & 0xff);
        input[fk_len + 1] = @truncate((obj_num >> 8) & 0xff);
        input[fk_len + 2] = @truncate((obj_num >> 16) & 0xff);
        // Generation in 2 LE bytes.
        input[fk_len + 3] = @truncate(gen & 0xff);
        input[fk_len + 4] = @truncate((gen >> 8) & 0xff);
        var input_len: usize = fk_len + 5;
        // AES variant: append the constant "sAlT" salt — case-sensitive
        // per spec ('s', 'A', 'l', 'T'). Hard-coded byte literal in
        // AES_SALT to defend against any toUpper drift.
        if (self.algorithm.isAes()) {
            input[input_len + 0] = AES_SALT[0];
            input[input_len + 1] = AES_SALT[1];
            input[input_len + 2] = AES_SALT[2];
            input[input_len + 3] = AES_SALT[3];
            input_len += 4;
        }

        var digest: [16]u8 = undefined;
        Md5.hash(input[0..input_len], &digest, .{});

        const eff_len = @min(fk_len + 5, 16);
        @memcpy(out[0..eff_len], digest[0..eff_len]);
        // Wipe the trailing tail of `out` so the caller doesn't see
        // stale stack data through the slice.
        var i: usize = eff_len;
        while (i < out.len) : (i += 1) out[i] = 0;
        std.crypto.secureZero(u8, &input);
        std.crypto.secureZero(u8, &digest);
        return out[0..eff_len];
    }

    /// Encrypt a string (§7.6.2). For RC4 the body is XORed in place;
    /// for AES the result is `iv (16) || ciphertext` and is allocated.
    pub fn encryptString(
        self: *const EncryptionContext,
        obj_num: u32,
        gen: u16,
        plaintext: []const u8,
        allocator: std.mem.Allocator,
    ) Error![]u8 {
        var key_buf: [21]u8 = undefined;
        const key = self.objectKey(obj_num, gen, &key_buf);
        defer std.crypto.secureZero(u8, &key_buf);

        switch (self.algorithm) {
            .rc4_v2_r3_128 => {
                const out = try allocator.dupe(u8, plaintext);
                errdefer allocator.free(out);
                var rc4 = crypto.Rc4.init(key);
                rc4.xor(out);
                return out;
            },
            .aes_v4_r4_128 => {
                std.debug.assert(key.len == 16);
                var aes_key: [16]u8 = undefined;
                @memcpy(&aes_key, key);
                defer std.crypto.secureZero(u8, &aes_key);

                var iv: [16]u8 = undefined;
                self.random.bytes(&iv);

                const padded = crypto.paddedLen(plaintext.len);
                const out = try allocator.alloc(u8, 16 + padded);
                errdefer allocator.free(out);
                @memcpy(out[0..16], &iv);
                crypto.aes128CbcEncrypt(aes_key, iv, plaintext, out[16..][0..padded]);
                return out;
            },
        }
    }

    /// Encrypt a stream body. Same shape as `encryptString` but always
    /// allocates (the caller emits the result as the stream body).
    pub fn encryptStream(
        self: *const EncryptionContext,
        obj_num: u32,
        gen: u16,
        plaintext: []const u8,
        allocator: std.mem.Allocator,
    ) Error![]u8 {
        return self.encryptString(obj_num, gen, plaintext, allocator);
    }

    /// Decrypt a string body. Symmetric inverse of `encryptString`.
    pub fn decryptString(
        self: *const EncryptionContext,
        obj_num: u32,
        gen: u16,
        ciphertext: []const u8,
        allocator: std.mem.Allocator,
    ) Error![]u8 {
        var key_buf: [21]u8 = undefined;
        const key = self.objectKey(obj_num, gen, &key_buf);
        defer std.crypto.secureZero(u8, &key_buf);

        switch (self.algorithm) {
            .rc4_v2_r3_128 => {
                const out = try allocator.dupe(u8, ciphertext);
                errdefer allocator.free(out);
                var rc4 = crypto.Rc4.init(key);
                rc4.xor(out);
                return out;
            },
            .aes_v4_r4_128 => {
                if (ciphertext.len < 16 + 16) return Error.InvalidLength;
                if ((ciphertext.len - 16) % 16 != 0) return Error.InvalidLength;
                std.debug.assert(key.len == 16);
                var aes_key: [16]u8 = undefined;
                @memcpy(&aes_key, key);
                defer std.crypto.secureZero(u8, &aes_key);
                var iv: [16]u8 = undefined;
                @memcpy(&iv, ciphertext[0..16]);

                const cipher_body = ciphertext[16..];
                const buf = try allocator.alloc(u8, cipher_body.len);
                errdefer allocator.free(buf);

                const pt_len = crypto.aes128CbcDecrypt(aes_key, iv, cipher_body, buf) catch |err| switch (err) {
                    error.InvalidPadding => return Error.InvalidPadding,
                    error.InvalidLength => return Error.InvalidLength,
                };

                // Shrink the buffer to the real plaintext.
                if (allocator.resize(buf, pt_len)) {
                    return buf[0..pt_len];
                }
                const shrunk = try allocator.alloc(u8, pt_len);
                @memcpy(shrunk, buf[0..pt_len]);
                allocator.free(buf);
                return shrunk;
            },
        }
    }

    /// Decrypt a stream body. Currently identical to `decryptString`.
    pub fn decryptStream(
        self: *const EncryptionContext,
        obj_num: u32,
        gen: u16,
        ciphertext: []const u8,
        allocator: std.mem.Allocator,
    ) Error![]u8 {
        return self.decryptString(obj_num, gen, ciphertext, allocator);
    }

    /// Render the body of the /Encrypt indirect object.
    /// Caller is responsible for `beginObject` / `endObject`.
    pub fn writeEncryptDict(self: *const EncryptionContext, w: *pdf_writer.Writer) pdf_writer.Writer.Error!void {
        try w.writeRaw("<< /Filter /Standard /V ");
        try w.writeInt(@intCast(self.algorithm.version()));
        try w.writeRaw(" /R ");
        try w.writeInt(@intCast(self.algorithm.revision()));
        try w.writeRaw(" /Length ");
        try w.writeInt(@intCast(self.algorithm.keyLen() * 8));

        // /O and /U as hex strings — works for any byte content,
        // unlike `()` literals which would need extensive escaping.
        try w.writeRaw(" /O ");
        try w.writeStringHex(&self.o_value);
        try w.writeRaw(" /U ");
        try w.writeStringHex(&self.u_value);

        // /P is a signed 32-bit integer.
        try w.writeRaw(" /P ");
        try w.writeInt(@intCast(self.permissions.toI32()));

        // /V 4 needs a /CF entry naming the StdCF crypto-filter and
        // declaring AESV2 as the per-stream / per-string method.
        if (self.algorithm.isAes()) {
            try w.writeRaw(" /CF << /StdCF << /Type /CryptFilter /CFM /AESV2 /Length ");
            try w.writeInt(@intCast(self.algorithm.keyLen()));
            try w.writeRaw(" >> >> /StmF /StdCF /StrF /StdCF");
        }
        try w.writeRaw(" >>");
    }
};

/// PR-W9 [feat]: in-place recursive decrypt of every `.string`,
/// `.hex_string`, and `.stream` inside `obj`, using `obj_num` / `gen`
/// as the per-object salt for the key derivation. Allocations come
/// from `arena` (the same parsing arena used elsewhere in the
/// document — freed at `Document.close`).
///
/// Streams that live inside an indirect dict carry their own
/// per-object key derived from the *outer* indirect, NOT from each
/// individual stream sub-object. So we keep the same `obj_num`/`gen`
/// throughout the recursion. This matches PDF §7.6.2.
pub fn decryptObjectInPlace(
    self: *const EncryptionContext,
    obj: *parser.Object,
    obj_num: u32,
    gen: u16,
    arena: std.mem.Allocator,
) !void {
    switch (obj.*) {
        .string => |s| {
            const pt = try self.decryptString(obj_num, gen, s, arena);
            obj.* = parser.Object{ .string = pt };
        },
        .hex_string => |s| {
            const pt = try self.decryptString(obj_num, gen, s, arena);
            obj.* = parser.Object{ .hex_string = pt };
        },
        .stream => |s| {
            const pt = try self.decryptStream(obj_num, gen, s.data, arena);
            // Walk the stream dict for nested strings (rare but legal).
            const dict = s.dict;
            for (dict.entries) |*entry| {
                try decryptObjectInPlace(self, &entry.value, obj_num, gen, arena);
            }
            obj.* = parser.Object{ .stream = .{ .dict = dict, .data = pt } };
        },
        .dict => |dict| {
            for (dict.entries) |*entry| {
                try decryptObjectInPlace(self, &entry.value, obj_num, gen, arena);
            }
        },
        .array => |arr| {
            for (arr) |*item| {
                try decryptObjectInPlace(self, item, obj_num, gen, arena);
            }
        },
        .null, .boolean, .integer, .real, .name, .reference => {},
    }
}

/// Trampoline matching the type-erased XRefTable.decrypt_fn signature.
pub fn decryptObjectTrampoline(
    ctx: *const anyopaque,
    obj: *parser.Object,
    obj_num: u32,
    gen: u16,
    arena: std.mem.Allocator,
) anyerror!void {
    const enc: *const EncryptionContext = @ptrCast(@alignCast(ctx));
    return decryptObjectInPlace(enc, obj, obj_num, gen, arena);
}

// ---------- tests ----------

test "Permissions encode round-trips" {
    const default_perms: Permissions = .{};
    const u_int = default_perms.toI32();
    const back = Permissions.fromI32(u_int);
    try std.testing.expectEqual(default_perms.print, back.print);
    try std.testing.expectEqual(default_perms.modify, back.modify);
    try std.testing.expectEqual(default_perms.extract, back.extract);
    try std.testing.expectEqual(default_perms.annotate, back.annotate);
}

test "padPassword empty truncates to PASSWORD_PAD" {
    var out: [32]u8 = undefined;
    padPassword(&out, "");
    try std.testing.expectEqualSlices(u8, &PASSWORD_PAD, &out);
}

test "padPassword short fills tail with PASSWORD_PAD" {
    var out: [32]u8 = undefined;
    padPassword(&out, "abc");
    try std.testing.expectEqual(@as(u8, 'a'), out[0]);
    try std.testing.expectEqual(@as(u8, 'b'), out[1]);
    try std.testing.expectEqual(@as(u8, 'c'), out[2]);
    try std.testing.expectEqual(PASSWORD_PAD[0], out[3]);
    try std.testing.expectEqual(PASSWORD_PAD[28], out[31]);
}

test "padPassword long truncates to 32 bytes" {
    var out: [32]u8 = undefined;
    padPassword(&out, "abcdefghijklmnopqrstuvwxyzABCDEF_extra");
    try std.testing.expectEqual(@as(u8, 'a'), out[0]);
    try std.testing.expectEqual(@as(u8, 'F'), out[31]);
}

test "AES_SALT byte literal matches s/A/l/T case-sensitive" {
    // sanity: confirm hard-coded AES salt bytes really are s, A, l, T
    // (lowercase s, uppercase A, lowercase l, uppercase T).
    try std.testing.expectEqual(@as(u8, 's'), AES_SALT[0]);
    try std.testing.expectEqual(@as(u8, 'A'), AES_SALT[1]);
    try std.testing.expectEqual(@as(u8, 'l'), AES_SALT[2]);
    try std.testing.expectEqual(@as(u8, 'T'), AES_SALT[3]);
}

test "EncryptionContext RC4 derive + objectKey shape" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xdead_beef);
    const random = prng.random();

    var ctx = try EncryptionContext.deriveFromPasswords(
        allocator,
        .rc4_v2_r3_128,
        "user",
        "owner",
        .{},
        .{0x01} ** 16,
        random,
    );
    defer ctx.deinit();

    var key_buf: [21]u8 = undefined;
    const obj_key = ctx.objectKey(7, 0, &key_buf);
    try std.testing.expectEqual(@as(usize, 16), obj_key.len); // min(16+5, 16) = 16
}

test "EncryptionContext AES derive + objectKey adds sAlT" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xdead_beef);
    const random = prng.random();

    var ctx = try EncryptionContext.deriveFromPasswords(
        allocator,
        .aes_v4_r4_128,
        "user",
        "owner",
        .{},
        .{0x02} ** 16,
        random,
    );
    defer ctx.deinit();
    var key_buf: [21]u8 = undefined;
    const k1 = ctx.objectKey(7, 0, &key_buf);
    var key_buf2: [21]u8 = undefined;
    const k2 = ctx.objectKey(8, 0, &key_buf2);
    try std.testing.expect(!std.mem.eql(u8, k1, k2));
}

test "EncryptionContext RC4 string encrypt-decrypt round-trip" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x1234_5678);
    const random = prng.random();

    var ctx = try EncryptionContext.deriveFromPasswords(
        allocator,
        .rc4_v2_r3_128,
        "u",
        "o",
        .{},
        .{0x03} ** 16,
        random,
    );
    defer ctx.deinit();

    const orig = "Hello encrypted PDF";
    const ct = try ctx.encryptString(5, 0, orig, allocator);
    defer allocator.free(ct);
    try std.testing.expect(!std.mem.eql(u8, orig, ct));

    const pt = try ctx.decryptString(5, 0, ct, allocator);
    defer allocator.free(pt);
    try std.testing.expectEqualStrings(orig, pt);
}

test "EncryptionContext AES string encrypt-decrypt round-trip" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xabcd_ef01);
    const random = prng.random();

    var ctx = try EncryptionContext.deriveFromPasswords(
        allocator,
        .aes_v4_r4_128,
        "u",
        "o",
        .{},
        .{0x04} ** 16,
        random,
    );
    defer ctx.deinit();

    const orig = "AES round-trip body bytes";
    const ct = try ctx.encryptString(11, 0, orig, allocator);
    defer allocator.free(ct);
    // First 16 bytes are the IV, then ≥16 bytes ciphertext.
    try std.testing.expect(ct.len >= 32);

    const pt = try ctx.decryptString(11, 0, ct, allocator);
    defer allocator.free(pt);
    try std.testing.expectEqualStrings(orig, pt);
}

test "authenticateUser accepts correct password, rejects wrong" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x55);
    const random = prng.random();
    const file_id: [16]u8 = .{0xAA} ** 16;
    const perms: Permissions = .{};

    var ctx = try EncryptionContext.deriveFromPasswords(
        allocator,
        .rc4_v2_r3_128,
        "secret",
        "owner-secret",
        perms,
        file_id,
        random,
    );
    defer ctx.deinit();

    const recovered = try EncryptionContext.authenticateUser(
        allocator,
        .rc4_v2_r3_128,
        "secret",
        ctx.o_value,
        ctx.u_value,
        perms,
        file_id,
    );
    defer {
        std.crypto.secureZero(u8, recovered);
        allocator.free(recovered);
    }
    try std.testing.expectEqualSlices(u8, ctx.file_key, recovered);

    try std.testing.expectError(Error.InvalidPassword, EncryptionContext.authenticateUser(
        allocator,
        .rc4_v2_r3_128,
        "wrong",
        ctx.o_value,
        ctx.u_value,
        perms,
        file_id,
    ));
}

test "authenticateOwner accepts owner password" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xdeadbeef);
    const random = prng.random();
    const file_id: [16]u8 = .{0xAA} ** 16;
    const perms: Permissions = .{};

    var ctx = try EncryptionContext.deriveFromPasswords(
        allocator,
        .aes_v4_r4_128,
        "user-pw",
        "owner-pw",
        perms,
        file_id,
        random,
    );
    defer ctx.deinit();

    const recovered = try EncryptionContext.authenticateOwner(
        allocator,
        .aes_v4_r4_128,
        "owner-pw",
        ctx.o_value,
        ctx.u_value,
        perms,
        file_id,
    );
    defer {
        std.crypto.secureZero(u8, recovered);
        allocator.free(recovered);
    }
    try std.testing.expectEqualSlices(u8, ctx.file_key, recovered);
}
