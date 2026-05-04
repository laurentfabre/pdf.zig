//! PR-W7 [refactor]: pure-data encoding tables, factored out of
//! `src/encoding.zig` so both the reader (`encoding.zig`) and the
//! writer-side font embedder (`font_embedder.zig`) can `@import` them
//! without dragging the parser/decompress dependency chain along.
//!
//! This file is **data only**. No logic moved; if a comparison against
//! the pre-W7 `encoding.zig` shows any value drift, that is a bug.

const std = @import("std");

pub const win_ansi_encoding = blk: {
    var table: [256]u21 = undefined;

    // ASCII range
    for (0..128) |i| {
        table[i] = @intCast(i);
    }

    // Windows-1252 extensions
    table[128] = 0x20AC; // Euro sign
    table[129] = 0;
    table[130] = 0x201A; // Single low-9 quotation mark
    table[131] = 0x0192; // Latin small letter f with hook
    table[132] = 0x201E; // Double low-9 quotation mark
    table[133] = 0x2026; // Horizontal ellipsis
    table[134] = 0x2020; // Dagger
    table[135] = 0x2021; // Double dagger
    table[136] = 0x02C6; // Modifier letter circumflex accent
    table[137] = 0x2030; // Per mille sign
    table[138] = 0x0160; // Latin capital letter S with caron
    table[139] = 0x2039; // Single left-pointing angle quotation mark
    table[140] = 0x0152; // Latin capital ligature OE
    table[141] = 0;
    table[142] = 0x017D; // Latin capital letter Z with caron
    table[143] = 0;
    table[144] = 0;
    table[145] = 0x2018; // Left single quotation mark
    table[146] = 0x2019; // Right single quotation mark
    table[147] = 0x201C; // Left double quotation mark
    table[148] = 0x201D; // Right double quotation mark
    table[149] = 0x2022; // Bullet
    table[150] = 0x2013; // En dash
    table[151] = 0x2014; // Em dash
    table[152] = 0x02DC; // Small tilde
    table[153] = 0x2122; // Trade mark sign
    table[154] = 0x0161; // Latin small letter s with caron
    table[155] = 0x203A; // Single right-pointing angle quotation mark
    table[156] = 0x0153; // Latin small ligature oe
    table[157] = 0;
    table[158] = 0x017E; // Latin small letter z with caron
    table[159] = 0x0178; // Latin capital letter Y with diaeresis

    // Latin-1 Supplement (160-255)
    for (160..256) |i| {
        table[i] = @intCast(i);
    }

    break :blk table;
};

pub const mac_roman_encoding = blk: {
    var table: [256]u21 = undefined;

    // ASCII range
    for (0..128) |i| {
        table[i] = @intCast(i);
    }

    // Mac Roman extensions (128-255)
    const mac_ext = [_]u21{
        0x00C4, 0x00C5, 0x00C7, 0x00C9, 0x00D1, 0x00D6, 0x00DC, 0x00E1,
        0x00E0, 0x00E2, 0x00E4, 0x00E3, 0x00E5, 0x00E7, 0x00E9, 0x00E8,
        0x00EA, 0x00EB, 0x00ED, 0x00EC, 0x00EE, 0x00EF, 0x00F1, 0x00F3,
        0x00F2, 0x00F4, 0x00F6, 0x00F5, 0x00FA, 0x00F9, 0x00FB, 0x00FC,
        0x2020, 0x00B0, 0x00A2, 0x00A3, 0x00A7, 0x2022, 0x00B6, 0x00DF,
        0x00AE, 0x00A9, 0x2122, 0x00B4, 0x00A8, 0x2260, 0x00C6, 0x00D8,
        0x221E, 0x00B1, 0x2264, 0x2265, 0x00A5, 0x00B5, 0x2202, 0x2211,
        0x220F, 0x03C0, 0x222B, 0x00AA, 0x00BA, 0x03A9, 0x00E6, 0x00F8,
        0x00BF, 0x00A1, 0x00AC, 0x221A, 0x0192, 0x2248, 0x2206, 0x00AB,
        0x00BB, 0x2026, 0x00A0, 0x00C0, 0x00C3, 0x00D5, 0x0152, 0x0153,
        0x2013, 0x2014, 0x201C, 0x201D, 0x2018, 0x2019, 0x00F7, 0x25CA,
        0x00FF, 0x0178, 0x2044, 0x20AC, 0x2039, 0x203A, 0xFB01, 0xFB02,
        0x2021, 0x00B7, 0x201A, 0x201E, 0x2030, 0x00C2, 0x00CA, 0x00C1,
        0x00CB, 0x00C8, 0x00CD, 0x00CE, 0x00CF, 0x00CC, 0x00D3, 0x00D4,
        0xF8FF, 0x00D2, 0x00DA, 0x00DB, 0x00D9, 0x0131, 0x02C6, 0x02DC,
        0x00AF, 0x02D8, 0x02D9, 0x02DA, 0x00B8, 0x02DD, 0x02DB, 0x02C7,
    };

    for (0..128) |i| {
        table[128 + i] = mac_ext[i];
    }

    break :blk table;
};

pub const standard_encoding = blk: {
    var table: [256]u21 = undefined;

    // Initialize all to 0
    for (&table) |*t| {
        t.* = 0;
    }

    // ASCII letters and digits
    for ('A'..('Z' + 1)) |i| {
        table[i] = @intCast(i);
    }
    for ('a'..('z' + 1)) |i| {
        table[i] = @intCast(i);
    }
    for ('0'..('9' + 1)) |i| {
        table[i] = @intCast(i);
    }

    // Common punctuation
    table[' '] = ' ';
    table['!'] = '!';
    table['"'] = '"';
    table['#'] = '#';
    table['$'] = '$';
    table['%'] = '%';
    table['&'] = '&';
    table['\''] = 0x2019; // quoteright
    table['('] = '(';
    table[')'] = ')';
    table['*'] = '*';
    table['+'] = '+';
    table[','] = ',';
    table['-'] = '-';
    table['.'] = '.';
    table['/'] = '/';
    table[':'] = ':';
    table[';'] = ';';
    table['<'] = '<';
    table['='] = '=';
    table['>'] = '>';
    table['?'] = '?';
    table['@'] = '@';
    table['['] = '[';
    table['\\'] = '\\';
    table[']'] = ']';
    table['^'] = '^';
    table['_'] = '_';
    table['`'] = 0x2018; // quoteleft
    table['{'] = '{';
    table['|'] = '|';
    table['}'] = '}';
    table['~'] = '~';

    break :blk table;
};

pub const pdf_doc_encoding = blk: {
    var table: [256]u21 = undefined;

    // Start with WinAnsi
    table = win_ansi_encoding;

    // PDFDocEncoding differs in a few places
    table[0x18] = 0x02D8; // breve
    table[0x19] = 0x02C7; // caron
    table[0x1A] = 0x02C6; // circumflex
    table[0x1B] = 0x02D9; // dotaccent
    table[0x1C] = 0x02DD; // hungarumlaut
    table[0x1D] = 0x02DB; // ogonek
    table[0x1E] = 0x02DA; // ring
    table[0x1F] = 0x02DC; // tilde

    break :blk table;
};

test "win_ansi_encoding ASCII identity for printable range" {
    try std.testing.expectEqual(@as(u21, 'A'), win_ansi_encoding['A']);
    try std.testing.expectEqual(@as(u21, ' '), win_ansi_encoding[' ']);
    try std.testing.expectEqual(@as(u21, 0x20AC), win_ansi_encoding[0x80]);
}

test "pdf_doc_encoding diverges from win_ansi at 0x18..0x1F" {
    try std.testing.expectEqual(@as(u21, 0x02D8), pdf_doc_encoding[0x18]);
    try std.testing.expectEqual(@as(u21, 0x02DC), pdf_doc_encoding[0x1F]);
    // Outside the 8-byte modifier range PDFDoc matches WinAnsi.
    try std.testing.expectEqual(win_ansi_encoding[0x40], pdf_doc_encoding[0x40]);
}
