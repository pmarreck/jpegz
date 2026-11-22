//! JPEG-LS bit reader (T.87 §A.1.3 / §B.1.1.2).
//!
//! Different from the T.81 `bitstream.BitReader`:
//!
//!   T.81 byte-stuffing rule: 0xFF in data is followed by 0x00; the
//!     decoder reads the 0x00 and ignores it, treating the 0xFF as
//!     literal payload. Otherwise 0xFF + non-zero = marker.
//!
//!   T.87 BIT-stuffing rule (§A.1.3): every time the encoder writes
//!     a byte equal to 0xFF, it inserts a single 0 bit BEFORE the
//!     next real data bit. Marker detection (§B.1.1.2): a 0xFF in
//!     data followed by a byte whose top bit is 1 (i.e. ≥ 0x80) is
//!     a marker — the inserted 0 bit isn't there.
//!
//! Reader rules:
//!   - Buffer bytes into a 64-bit MSB-aligned word.
//!   - After consuming an 0xFF byte:
//!       * If next byte's top bit is 1 → marker; set `marker_seen`
//!         and stop refilling.
//!       * Otherwise → discard the next byte's top bit (the
//!         inserted 0) and append only its bottom 7 bits.

const std = @import("std");

pub const BitReader = struct {
    data: []const u8,
    pos: usize,
    /// 64-bit MSB-aligned bit accumulator.
    buf: u64,
    /// Bits valid in `buf` (top `valid` bits — buf >> (64 - valid)).
    valid: u7,
    /// True while the last consumed byte was 0xFF (next byte triggers
    /// either a marker or a bit-stuffed escape).
    last_byte_was_ff: bool,
    marker_seen: bool,
    /// The marker byte itself (e.g. 0xD9 for EOI). Valid only when
    /// `marker_seen == true`.
    marker_byte: u8,
    /// A read needed more bits than the data held before a marker
    /// (`marker_seen`) or the end of the buffer (`exhausted`); the
    /// shortfall was supplied as zero bits.
    starved: bool = false,
    exhausted: bool = false,
    /// `starved` for the current restart interval only: cleared at each
    /// restart. A starved read may have consumed a marker's FF as data,
    /// so the segment end cannot be located from the read position.
    segment_starved: bool = false,
    /// Data offset a decoder fault refers to when it is not the read
    /// position, e.g. a restart marker that does not match.
    fault_pos: ?usize = null,

    pub fn init(data: []const u8) BitReader {
        return .{
            .data = data,
            .pos = 0,
            .buf = 0,
            .valid = 0,
            .last_byte_was_ff = false,
            .marker_seen = false,
            .marker_byte = 0,
        };
    }

    /// Refill `buf` until at least `min_bits` bits are valid OR we
    /// hit end-of-stream / a marker. The MSB-aligned layout means
    /// `buf` always has its newest bits at the TOP.
    inline fn refill(self: *BitReader, min_bits: u7) void {
        while (self.valid < min_bits and !self.marker_seen) {
            if (self.pos >= self.data.len) return;
            const byte = self.data[self.pos];
            if (self.last_byte_was_ff) {
                if (byte & 0x80 != 0) {
                    // Marker — the inserted 0 isn't here. Don't
                    // consume; let the caller seek past it later.
                    self.marker_seen = true;
                    self.marker_byte = byte;
                    return;
                }
                // Bit-stuffed escape: top bit is the inserted 0;
                // append only the lower 7 bits.
                self.pos += 1;
                // Align "byte's bottom 7 bits" to the top of where
                // the next bits go.
                self.buf |= @as(u64, byte & 0x7F) << @intCast(64 - 7 - @as(u7, self.valid));
                self.valid += 7;
                self.last_byte_was_ff = false; // bottom 7 of 0x7F can't form 0xFF
            } else {
                self.pos += 1;
                self.buf |= @as(u64, byte) << @intCast(64 - 8 - @as(u7, self.valid));
                self.valid += 8;
                self.last_byte_was_ff = (byte == 0xFF);
            }
        }
    }

    /// End a restart interval: drop the unread bits, consume the marker
    /// `expected` (RSTm, after any FF fill bytes) and continue with a fresh
    /// bit buffer just past it. Refill never consumes a marker's second
    /// byte, so the marker starts at or after `pos - 1`; within entropy data
    /// an FF is always followed by a byte below 0x80 (bit stuffing), so the
    /// first FF followed by a byte of 0x80 or more is the marker.
    /// Errors: `RestartMissing` when no marker follows (or it is not an
    /// RSTm), `RestartUnexpected` for an RSTm with the wrong m. Either sets
    /// `fault_pos` to the marker's FF (or the end of the data).
    pub fn skipToRestart(self: *BitReader, expected: u8) error{ RestartMissing, RestartUnexpected }!void {
        var i: usize = if (self.pos > 0) self.pos - 1 else 0;
        while (true) : (i += 1) {
            if (i + 1 >= self.data.len) {
                self.fault_pos = self.data.len;
                return error.RestartMissing;
            }
            if (self.data[i] == 0xFF and self.data[i + 1] >= 0x80) break;
        }
        var j = i + 1;
        while (j < self.data.len and self.data[j] == 0xFF) j += 1;
        self.fault_pos = i;
        if (j >= self.data.len or self.data[j] < 0xD0 or self.data[j] > 0xD7) return error.RestartMissing;
        if (self.data[j] != expected) return error.RestartUnexpected;
        self.fault_pos = null;
        self.pos = j + 1;
        self.buf = 0;
        self.valid = 0;
        self.last_byte_was_ff = false;
        self.marker_seen = false;
        self.segment_starved = false;
        self.marker_byte = 0;
    }

    /// What lies between the last bit read and the next marker (T.87 A.1:
    /// "An incomplete byte, just before a marker, is padded with zero-valued
    /// bits"; optional FF fill may precede the marker, D.4/C.1).
    pub const SegmentEnd = union(enum) {
        ok,
        /// Nonzero padding bits in the byte at `offset`.
        padding: struct { offset: usize, bits: u4 },
        /// Whole bytes from `offset` up to the marker.
        leftover: usize,
    };

    /// A segment whose reads ran past its data reports `.ok`: the
    /// truncation finding covers it.
    pub fn segmentEnd(self: *const BitReader) SegmentEnd {
        if (self.segment_starved) return .ok;
        var unread: usize = self.valid;
        var p = self.pos;
        while (p > 0) {
            const width: usize = if (p >= 2 and self.data[p - 2] == 0xFF) 7 else 8;
            if (unread < width) break;
            unread -= width;
            p -= 1;
        }
        // Byte p - 1 still holds `unread` low bits; bytes from p are unread.
        if (unread > 0) {
            const mask: u8 = @intCast((@as(u16, 1) << @intCast(unread)) - 1);
            if (self.data[p - 1] & mask != 0) return .{ .padding = .{ .offset = p - 1, .bits = @intCast(unread) } };
        }
        var m = p;
        while (m + 1 < self.data.len and !(self.data[m] == 0xFF and self.data[m + 1] >= 0x80)) m += 1;
        // m is the first FF of any fill run: a data FF is always followed
        // by a byte below 0x80, so fill bytes never count as leftover.
        if (m + 1 >= self.data.len) m = self.data.len;
        if (m == p) return .ok;
        // After a final FF data byte the next byte carries the stuffed 0 bit;
        // with no data left it is all padding and must be zero.
        if (m == p + 1 and p >= 1 and self.data[p - 1] == 0xFF) {
            return if (self.data[p] == 0) .ok else .{ .padding = .{ .offset = p, .bits = 7 } };
        }
        return .{ .leftover = p };
    }

    /// Offset of the byte holding the most recently consumed bit (0 before
    /// any read). Bytes after an FF contribute 7 bits (T.87 A.1.3).
    pub fn bytePosition(self: *const BitReader) usize {
        var unread: usize = self.valid;
        var p = self.pos;
        while (p > 0) {
            const width: usize = if (p >= 2 and self.data[p - 2] == 0xFF) 7 else 8;
            if (unread < width) break;
            unread -= width;
            p -= 1;
        }
        return if (p > 0) p - 1 else 0;
    }

    /// Where a fault detected now should point: `fault_pos` when set,
    /// otherwise the byte holding the last bit read.
    pub fn faultOffset(self: *const BitReader) usize {
        return self.fault_pos orelse self.bytePosition();
    }

    /// Read `n` bits MSB-first. n ∈ [0, 32]. Refills as needed; if
    /// the stream is exhausted (or hit a marker), returns zero-padded
    /// bits — same convention as the rest of the library's bit
    /// readers ("supply zero data until decoding is complete").
    pub fn readBits(self: *BitReader, n: u6) u32 {
        std.debug.assert(n <= 32);
        if (n == 0) return 0;
        self.refill(@intCast(n));
        if (self.valid < n) {
            self.starved = true;
            self.segment_starved = true;
            if (!self.marker_seen) self.exhausted = true;
        }
        // Take top n bits.
        const shift: u6 = @intCast(64 - @as(u7, n));
        const result: u32 = @intCast(self.buf >> shift);
        // Consume them: shift buf left by n.
        self.buf = self.buf << @intCast(n);
        if (self.valid >= n) self.valid -= @intCast(n) else self.valid = 0;
        return result;
    }

    /// Peek `n` bits without consuming. Used for variable-length
    /// codes where the number of bits needed is determined by the
    /// content.
    pub fn peekBits(self: *BitReader, n: u6) u32 {
        std.debug.assert(n <= 32);
        if (n == 0) return 0;
        self.refill(@intCast(n));
        const shift: u6 = @intCast(64 - @as(u7, n));
        return @intCast(self.buf >> shift);
    }

    /// Consume `n` previously-peeked bits.
    pub fn consume(self: *BitReader, n: u6) void {
        self.buf = self.buf << @intCast(n);
        if (self.valid >= n) self.valid -= @intCast(n) else self.valid = 0;
    }

    /// Read a JPEG-LS unary code: count leading 0-bits, terminator
    /// is a 1-bit (consumed). The standard unary code for `n` is
    /// `n` zeros followed by a 1 (T.87 §A.5.3). `limit` caps the
    /// count to guard against pathological all-zero streams.
    pub fn readUnary(self: *BitReader, limit: u8) u32 {
        var count: u32 = 0;
        while (count < limit) : (count += 1) {
            const bit = self.readBits(1);
            if (bit == 1) return count;
        }
        return count;
    }
};

// ── Inline tests ─────────────────────────────────────────────────

test "BitReader: read MSB-first across byte boundary" {
    // Bytes 0b10110100 0b11010001 → 16 bits MSB-first.
    const data = [_]u8{ 0xB4, 0xD1 };
    var br = BitReader.init(&data);
    try std.testing.expectEqual(@as(u32, 0b1), br.readBits(1));
    try std.testing.expectEqual(@as(u32, 0b011010), br.readBits(6));
    try std.testing.expectEqual(@as(u32, 0b011), br.readBits(3));
    try std.testing.expectEqual(@as(u32, 0b010001), br.readBits(6));
}

test "BitReader: bit-stuffed 0xFF discards next top bit" {
    // 0xFF then 0x7E. 0xFF is 8 bits of all-1s, then the encoder
    // inserted a 0; the 0x7E byte's top bit (0) is the stuffed bit,
    // bottom 7 bits = 0x7E & 0x7F = 0x7E = 0b1111110 are real data.
    const data = [_]u8{ 0xFF, 0x7E };
    var br = BitReader.init(&data);
    try std.testing.expectEqual(@as(u32, 0xFF), br.readBits(8));
    // Next 7 bits = 0x7E = 0b1111110.
    try std.testing.expectEqual(@as(u32, 0b1111110), br.readBits(7));
}

test "BitReader: 0xFF followed by top-bit-set byte signals marker" {
    // 0xD0 (some entropy bits), then 0xFF 0xD9 (EOI marker).
    const data = [_]u8{ 0xD0, 0xFF, 0xD9 };
    var br = BitReader.init(&data);
    // 8 bits of 0xD0 readable.
    try std.testing.expectEqual(@as(u32, 0xD0), br.readBits(8));
    // 0xFF can be consumed as data.
    try std.testing.expectEqual(@as(u32, 0xFF), br.readBits(8));
    // Now the next refill should detect the marker.
    _ = br.readBits(1);
    try std.testing.expect(br.marker_seen);
    try std.testing.expectEqual(@as(u8, 0xD9), br.marker_byte);
}

test "BitReader: readUnary terminates at 1-bit (JPEG-LS convention)" {
    // 0b0001_0000 → 3 zeros then a 1 = unary code for 3.
    const data = [_]u8{0b0001_0000};
    var br = BitReader.init(&data);
    try std.testing.expectEqual(@as(u32, 3), br.readUnary(16));
}

test "BitReader: readUnary respects limit on degenerate all-zeros stream" {
    // Long run of 0s past EOF (zero-padded). Without a 1-terminator
    // readUnary must bail at `limit`.
    const data = [_]u8{ 0x00, 0x00 };
    var br = BitReader.init(&data);
    try std.testing.expectEqual(@as(u32, 16), br.readUnary(16));
}

test "BitReader: exhausted stream returns zero-padded" {
    const data = [_]u8{0xFF};  // single byte
    var br = BitReader.init(&data);
    try std.testing.expectEqual(@as(u32, 0xFF), br.readBits(8));
    // No more data; readBits should return 0 padding.
    try std.testing.expectEqual(@as(u32, 0), br.readBits(8));
}

test "BitReader.segmentEnd: zero padding, fill, leftover bytes and nonzero padding" {
    const Case = struct { data: []const u8, reads: []const u6, peek: u6 = 0, want: BitReader.SegmentEnd };
    const cases = [_]Case{
        // Zero padding in the final byte, then the marker.
        .{ .data = &.{ 0xA0, 0xFF, 0xD9 }, .reads = &.{4}, .want = .ok },
        // Nonzero padding: the low nibble of byte 0.
        .{ .data = &.{ 0xA1, 0xFF, 0xD9 }, .reads = &.{4}, .want = .{ .padding = .{ .offset = 0, .bits = 4 } } },
        // FF fill before the marker is marker syntax.
        .{ .data = &.{ 0xAB, 0xFF, 0xFF, 0xFF, 0xD9 }, .reads = &.{8}, .want = .ok },
        // A whole byte after the last coded bit.
        .{ .data = &.{ 0xAB, 0x12, 0xFF, 0xD9 }, .reads = &.{8}, .want = .{ .leftover = 1 } },
        // A final FF data byte: the next byte holds the stuffed 0 and 7
        // padding bits, which must be zero.
        .{ .data = &.{ 0xAB, 0xFF, 0x00, 0xFF, 0xD9 }, .reads = &.{ 8, 8 }, .want = .ok },
        .{ .data = &.{ 0xAB, 0xFF, 0x01, 0xFF, 0xD9 }, .reads = &.{ 8, 8 }, .want = .{ .padding = .{ .offset = 2, .bits = 7 } } },
        // Two bytes after a final FF data byte are leftover, not padding.
        .{ .data = &.{ 0xAB, 0xFF, 0x00, 0x00, 0xFF, 0xD9 }, .reads = &.{ 8, 8 }, .want = .{ .leftover = 2 } },
        // Peek ahead into the marker's FF, then walk back over it.
        .{ .data = &.{ 0xAB, 0xCD, 0xFF, 0xD9 }, .reads = &.{ 8, 4 }, .peek = 16, .want = .{ .padding = .{ .offset = 1, .bits = 4 } } },
        // The walk back crosses a stuffed byte (7 data bits) before the
        // byte holding the unread padding bits.
        .{ .data = &.{ 0xAB, 0xFF, 0x40, 0xFF, 0xD9 }, .reads = &.{ 8, 4 }, .peek = 24, .want = .{ .padding = .{ .offset = 1, .bits = 4 } } },
        // No marker: bytes after a final FF data byte, to the end of input.
        .{ .data = &.{ 0xAB, 0xFF, 0x00, 0x00 }, .reads = &.{ 8, 8 }, .want = .{ .leftover = 2 } },
        // Starved: reads ran past the end of the input.
        .{ .data = &.{0xAB}, .reads = &.{ 8, 8 }, .want = .ok },
        // Starved at a marker.
        .{ .data = &.{ 0xAB, 0xFF, 0xD9 }, .reads = &.{ 8, 16 }, .want = .ok },
    };
    for (cases) |c| {
        var br = BitReader.init(c.data);
        for (c.reads) |n| _ = br.readBits(n);
        _ = br.peekBits(c.peek);
        try std.testing.expectEqualDeep(c.want, br.segmentEnd());
    }
    // A restart clears the per-interval flag: the next interval is checked.
    {
        var br = BitReader.init(&.{ 0xAB, 0xFF, 0xD0, 0xCD, 0x12, 0xFF, 0xD1 });
        _ = br.readBits(24);
        try std.testing.expect(br.segment_starved);
        try std.testing.expectEqual(BitReader.SegmentEnd.ok, br.segmentEnd());
        try br.skipToRestart(0xD0);
        try std.testing.expect(br.starved and !br.segment_starved);
        _ = br.readBits(8);
        try std.testing.expectEqualDeep(BitReader.SegmentEnd{ .leftover = 4 }, br.segmentEnd());
    }
}
