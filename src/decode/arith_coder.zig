//! Q-coder — binary arithmetic decoder for JPEG (T.81 Annex D / §F.1.4).
//!
//! Two layers in this module:
//!
//!   1. `QCoder` — pure binary arithmetic decoder. Operates on a
//!      single-byte "context" cell holding {state_index, MPS}. Reads
//!      raw bytes from a JPEG entropy stream with 0xFF marker-escape
//!      handling. **Codec-agnostic enough that the same state machine
//!      could host a JPEG 2000 MQ-coder adapter later** (B3); only
//!      the renormalization details and statistics-table semantics
//!      differ between the two.
//!
//!   2. JPEG-specific binarization (T.81 §F.1.4.4.1) — DC differential
//!      and AC coefficient decoders. Land in a follow-on commit
//!      (GREEN1b); this commit ships just the Q-coder kernel + table.
//!
//! Reference: T.81 §D.2 (decoder pseudocode), Table D.2 (state
//! transition table), libjpeg-turbo's `jdarith.c` + `jaricom.c`. The
//! `qe_table` below is **ported byte-for-byte** from libjpeg's
//! `jpeg_aritab` — the table IS the JPEG committee's deterministic
//! spec; matching libjpeg exactly is the testable byte-equality
//! ground truth.

const std = @import("std");

/// Errors a Q-coder consumer can surface upstream.
pub const Error = error{
    TruncatedStream,
    InvalidMarker,
};

/// One entry in T.81 Table D.2. libjpeg packs these four fields into
/// a single JLONG via the V() macro; Zig comptime gives us a clean
/// struct layout at zero cost.
pub const QeEntry = struct {
    /// LPS subinterval probability estimate Qe (T.81 §D.2). 16-bit
    /// value in the range that keeps `A - Qe` representable in u16.
    qe: u16,
    /// Next state index after coding an LPS.
    next_lps: u7,
    /// Next state index after coding an MPS.
    next_mps: u7,
    /// If true, swap MPS↔LPS at this state when an LPS is coded.
    switch_mps: bool,
};

/// Probability estimation state machine — T.81 Table D.2, identical
/// to libjpeg's `jaricom.c` `jpeg_aritab[113+1]`. Indices 0..112 are
/// the 113 states from the spec. Index 113 is libjpeg's extra
/// "fixed probability ~0.5" entry per T.851 §10.3 Table 5; we keep it
/// for parity even though JPEG never references it directly.
pub const QE_TABLE = [114]QeEntry{
    .{ .qe = 0x5a1d, .next_lps = 1,   .next_mps = 1,   .switch_mps = true  },
    .{ .qe = 0x2586, .next_lps = 14,  .next_mps = 2,   .switch_mps = false },
    .{ .qe = 0x1114, .next_lps = 16,  .next_mps = 3,   .switch_mps = false },
    .{ .qe = 0x080b, .next_lps = 18,  .next_mps = 4,   .switch_mps = false },
    .{ .qe = 0x03d8, .next_lps = 20,  .next_mps = 5,   .switch_mps = false },
    .{ .qe = 0x01da, .next_lps = 23,  .next_mps = 6,   .switch_mps = false },
    .{ .qe = 0x00e5, .next_lps = 25,  .next_mps = 7,   .switch_mps = false },
    .{ .qe = 0x006f, .next_lps = 28,  .next_mps = 8,   .switch_mps = false },
    .{ .qe = 0x0036, .next_lps = 30,  .next_mps = 9,   .switch_mps = false },
    .{ .qe = 0x001a, .next_lps = 33,  .next_mps = 10,  .switch_mps = false },
    .{ .qe = 0x000d, .next_lps = 35,  .next_mps = 11,  .switch_mps = false },
    .{ .qe = 0x0006, .next_lps = 9,   .next_mps = 12,  .switch_mps = false },
    .{ .qe = 0x0003, .next_lps = 10,  .next_mps = 13,  .switch_mps = false },
    .{ .qe = 0x0001, .next_lps = 12,  .next_mps = 13,  .switch_mps = false },
    .{ .qe = 0x5a7f, .next_lps = 15,  .next_mps = 15,  .switch_mps = true  },
    .{ .qe = 0x3f25, .next_lps = 36,  .next_mps = 16,  .switch_mps = false },
    .{ .qe = 0x2cf2, .next_lps = 38,  .next_mps = 17,  .switch_mps = false },
    .{ .qe = 0x207c, .next_lps = 39,  .next_mps = 18,  .switch_mps = false },
    .{ .qe = 0x17b9, .next_lps = 40,  .next_mps = 19,  .switch_mps = false },
    .{ .qe = 0x1182, .next_lps = 42,  .next_mps = 20,  .switch_mps = false },
    .{ .qe = 0x0cef, .next_lps = 43,  .next_mps = 21,  .switch_mps = false },
    .{ .qe = 0x09a1, .next_lps = 45,  .next_mps = 22,  .switch_mps = false },
    .{ .qe = 0x072f, .next_lps = 46,  .next_mps = 23,  .switch_mps = false },
    .{ .qe = 0x055c, .next_lps = 48,  .next_mps = 24,  .switch_mps = false },
    .{ .qe = 0x0406, .next_lps = 49,  .next_mps = 25,  .switch_mps = false },
    .{ .qe = 0x0303, .next_lps = 51,  .next_mps = 26,  .switch_mps = false },
    .{ .qe = 0x0240, .next_lps = 52,  .next_mps = 27,  .switch_mps = false },
    .{ .qe = 0x01b1, .next_lps = 54,  .next_mps = 28,  .switch_mps = false },
    .{ .qe = 0x0144, .next_lps = 56,  .next_mps = 29,  .switch_mps = false },
    .{ .qe = 0x00f5, .next_lps = 57,  .next_mps = 30,  .switch_mps = false },
    .{ .qe = 0x00b7, .next_lps = 59,  .next_mps = 31,  .switch_mps = false },
    .{ .qe = 0x008a, .next_lps = 60,  .next_mps = 32,  .switch_mps = false },
    .{ .qe = 0x0068, .next_lps = 62,  .next_mps = 33,  .switch_mps = false },
    .{ .qe = 0x004e, .next_lps = 63,  .next_mps = 34,  .switch_mps = false },
    .{ .qe = 0x003b, .next_lps = 32,  .next_mps = 35,  .switch_mps = false },
    .{ .qe = 0x002c, .next_lps = 33,  .next_mps = 9,   .switch_mps = false },
    .{ .qe = 0x5ae1, .next_lps = 37,  .next_mps = 37,  .switch_mps = true  },
    .{ .qe = 0x484c, .next_lps = 64,  .next_mps = 38,  .switch_mps = false },
    .{ .qe = 0x3a0d, .next_lps = 65,  .next_mps = 39,  .switch_mps = false },
    .{ .qe = 0x2ef1, .next_lps = 67,  .next_mps = 40,  .switch_mps = false },
    .{ .qe = 0x261f, .next_lps = 68,  .next_mps = 41,  .switch_mps = false },
    .{ .qe = 0x1f33, .next_lps = 69,  .next_mps = 42,  .switch_mps = false },
    .{ .qe = 0x19a8, .next_lps = 70,  .next_mps = 43,  .switch_mps = false },
    .{ .qe = 0x1518, .next_lps = 72,  .next_mps = 44,  .switch_mps = false },
    .{ .qe = 0x1177, .next_lps = 73,  .next_mps = 45,  .switch_mps = false },
    .{ .qe = 0x0e74, .next_lps = 74,  .next_mps = 46,  .switch_mps = false },
    .{ .qe = 0x0bfb, .next_lps = 75,  .next_mps = 47,  .switch_mps = false },
    .{ .qe = 0x09f8, .next_lps = 77,  .next_mps = 48,  .switch_mps = false },
    .{ .qe = 0x0861, .next_lps = 78,  .next_mps = 49,  .switch_mps = false },
    .{ .qe = 0x0706, .next_lps = 79,  .next_mps = 50,  .switch_mps = false },
    .{ .qe = 0x05cd, .next_lps = 48,  .next_mps = 51,  .switch_mps = false },
    .{ .qe = 0x04de, .next_lps = 50,  .next_mps = 52,  .switch_mps = false },
    .{ .qe = 0x040f, .next_lps = 50,  .next_mps = 53,  .switch_mps = false },
    .{ .qe = 0x0363, .next_lps = 51,  .next_mps = 54,  .switch_mps = false },
    .{ .qe = 0x02d4, .next_lps = 52,  .next_mps = 55,  .switch_mps = false },
    .{ .qe = 0x025c, .next_lps = 53,  .next_mps = 56,  .switch_mps = false },
    .{ .qe = 0x01f8, .next_lps = 54,  .next_mps = 57,  .switch_mps = false },
    .{ .qe = 0x01a4, .next_lps = 55,  .next_mps = 58,  .switch_mps = false },
    .{ .qe = 0x0160, .next_lps = 56,  .next_mps = 59,  .switch_mps = false },
    .{ .qe = 0x0125, .next_lps = 57,  .next_mps = 60,  .switch_mps = false },
    .{ .qe = 0x00f6, .next_lps = 58,  .next_mps = 61,  .switch_mps = false },
    .{ .qe = 0x00cb, .next_lps = 59,  .next_mps = 62,  .switch_mps = false },
    .{ .qe = 0x00ab, .next_lps = 61,  .next_mps = 63,  .switch_mps = false },
    .{ .qe = 0x008f, .next_lps = 61,  .next_mps = 32,  .switch_mps = false },
    .{ .qe = 0x5b12, .next_lps = 65,  .next_mps = 65,  .switch_mps = true  },
    .{ .qe = 0x4d04, .next_lps = 80,  .next_mps = 66,  .switch_mps = false },
    .{ .qe = 0x412c, .next_lps = 81,  .next_mps = 67,  .switch_mps = false },
    .{ .qe = 0x37d8, .next_lps = 82,  .next_mps = 68,  .switch_mps = false },
    .{ .qe = 0x2fe8, .next_lps = 83,  .next_mps = 69,  .switch_mps = false },
    .{ .qe = 0x293c, .next_lps = 84,  .next_mps = 70,  .switch_mps = false },
    .{ .qe = 0x2379, .next_lps = 86,  .next_mps = 71,  .switch_mps = false },
    .{ .qe = 0x1edf, .next_lps = 87,  .next_mps = 72,  .switch_mps = false },
    .{ .qe = 0x1aa9, .next_lps = 87,  .next_mps = 73,  .switch_mps = false },
    .{ .qe = 0x174e, .next_lps = 72,  .next_mps = 74,  .switch_mps = false },
    .{ .qe = 0x1424, .next_lps = 72,  .next_mps = 75,  .switch_mps = false },
    .{ .qe = 0x119c, .next_lps = 74,  .next_mps = 76,  .switch_mps = false },
    .{ .qe = 0x0f6b, .next_lps = 74,  .next_mps = 77,  .switch_mps = false },
    .{ .qe = 0x0d51, .next_lps = 75,  .next_mps = 78,  .switch_mps = false },
    .{ .qe = 0x0bb6, .next_lps = 77,  .next_mps = 79,  .switch_mps = false },
    .{ .qe = 0x0a40, .next_lps = 77,  .next_mps = 48,  .switch_mps = false },
    .{ .qe = 0x5832, .next_lps = 80,  .next_mps = 81,  .switch_mps = true  },
    .{ .qe = 0x4d1c, .next_lps = 88,  .next_mps = 82,  .switch_mps = false },
    .{ .qe = 0x438e, .next_lps = 89,  .next_mps = 83,  .switch_mps = false },
    .{ .qe = 0x3bdd, .next_lps = 90,  .next_mps = 84,  .switch_mps = false },
    .{ .qe = 0x34ee, .next_lps = 91,  .next_mps = 85,  .switch_mps = false },
    .{ .qe = 0x2eae, .next_lps = 92,  .next_mps = 86,  .switch_mps = false },
    .{ .qe = 0x299a, .next_lps = 93,  .next_mps = 87,  .switch_mps = false },
    .{ .qe = 0x2516, .next_lps = 86,  .next_mps = 71,  .switch_mps = false },
    .{ .qe = 0x5570, .next_lps = 88,  .next_mps = 89,  .switch_mps = true  },
    .{ .qe = 0x4ca9, .next_lps = 95,  .next_mps = 90,  .switch_mps = false },
    .{ .qe = 0x44d9, .next_lps = 96,  .next_mps = 91,  .switch_mps = false },
    .{ .qe = 0x3e22, .next_lps = 97,  .next_mps = 92,  .switch_mps = false },
    .{ .qe = 0x3824, .next_lps = 99,  .next_mps = 93,  .switch_mps = false },
    .{ .qe = 0x32b4, .next_lps = 99,  .next_mps = 94,  .switch_mps = false },
    .{ .qe = 0x2e17, .next_lps = 93,  .next_mps = 86,  .switch_mps = false },
    .{ .qe = 0x56a8, .next_lps = 95,  .next_mps = 96,  .switch_mps = true  },
    .{ .qe = 0x4f46, .next_lps = 101, .next_mps = 97,  .switch_mps = false },
    .{ .qe = 0x47e5, .next_lps = 102, .next_mps = 98,  .switch_mps = false },
    .{ .qe = 0x41cf, .next_lps = 103, .next_mps = 99,  .switch_mps = false },
    .{ .qe = 0x3c3d, .next_lps = 104, .next_mps = 100, .switch_mps = false },
    .{ .qe = 0x375e, .next_lps = 99,  .next_mps = 93,  .switch_mps = false },
    .{ .qe = 0x5231, .next_lps = 105, .next_mps = 102, .switch_mps = false },
    .{ .qe = 0x4c0f, .next_lps = 106, .next_mps = 103, .switch_mps = false },
    .{ .qe = 0x4639, .next_lps = 107, .next_mps = 104, .switch_mps = false },
    .{ .qe = 0x415e, .next_lps = 103, .next_mps = 99,  .switch_mps = false },
    .{ .qe = 0x5627, .next_lps = 105, .next_mps = 106, .switch_mps = true  },
    .{ .qe = 0x50e7, .next_lps = 108, .next_mps = 107, .switch_mps = false },
    .{ .qe = 0x4b85, .next_lps = 109, .next_mps = 103, .switch_mps = false },
    .{ .qe = 0x5597, .next_lps = 110, .next_mps = 109, .switch_mps = false },
    .{ .qe = 0x504f, .next_lps = 111, .next_mps = 107, .switch_mps = false },
    .{ .qe = 0x5a10, .next_lps = 110, .next_mps = 111, .switch_mps = true  },
    .{ .qe = 0x5522, .next_lps = 112, .next_mps = 109, .switch_mps = false },
    .{ .qe = 0x59eb, .next_lps = 112, .next_mps = 111, .switch_mps = true  },
    // Index 113 — fixed-probability ~0.5 (T.851 §10.3 Table 5).
    // libjpeg keeps it; we mirror for parity. JPEG itself never
    // references this slot.
    .{ .qe = 0x5a1d, .next_lps = 113 & 0x7F, .next_mps = 113 & 0x7F, .switch_mps = false },
};

/// Single-byte context cell — bit 7 holds the current MPS value,
/// bits 6..0 are the index into `QE_TABLE`. Same layout as libjpeg's
/// `unsigned char *st` pattern; storing as `u8` lets us use the same
/// XOR tricks (`sv ^= 0x80` to swap MPS) at zero cost.
pub const Context = u8;

/// Initial context: state 0, MPS = 0. JPEG arithmetic spec requires
/// every context to be initialized this way at scan start AND at
/// every RST marker.
pub const INITIAL_CONTEXT: Context = 0;

/// Q-coder state machine — pure binary arithmetic decoder.
///
/// Operates on a byte-stuffed JPEG entropy stream (0xFF NN where NN
/// != 0 is a marker; 0xFF 0x00 is a literal 0xFF byte). Marker
/// detection sets `marker_byte` and `marker_seen` for the upstream
/// consumer; subsequent decode calls return 0 bits (per T.81 §F.1.4
/// arith convention — "supply zero data until decoding is complete").
pub const QCoder = struct {
    /// Entropy stream backing store.
    data: []const u8,
    pos: usize,
    /// Range register (T.81 §D.2.2). Renormalized into [0x8000, 0xFFFF].
    a: u16,
    /// Code register (T.81 §D.2.2). Holds the look-ahead bits.
    c: u32,
    /// Bit shift counter — signed because it dips below zero during
    /// the initial 2-byte load (T.81 §D.2.6).
    ct: i32,
    /// Set to the marker byte if a non-stuffed 0xFF was consumed;
    /// upstream walks back to the marker to dispatch.
    marker_byte: u8,
    marker_seen: bool,

    pub fn init(data: []const u8) QCoder {
        // T.81 §D.2.6 prescribes initial A and C states. We follow
        // libjpeg's two-pass pattern: enter the decode loop with
        // A = 0, ct = -16. The first two byte fetches load C, then
        // ct crosses zero and A is re-set to 0x8000. This is exactly
        // what `arith_decode` does on first call.
        return .{
            .data = data,
            .pos = 0,
            .a = 0,
            .c = 0,
            .ct = -16,
            .marker_byte = 0,
            .marker_seen = false,
        };
    }

    /// T.81 §D.2.6 byte fetch with 0xFF marker handling. Returns the
    /// byte to insert into the code register. On a marker, sets
    /// `marker_byte`/`marker_seen` and returns 0 (the "supply zero
    /// data until decoding is complete" convention).
    inline fn getByte(self: *QCoder) u8 {
        if (self.marker_seen) return 0;
        if (self.pos >= self.data.len) return 0;
        const b = self.data[self.pos];
        self.pos += 1;
        if (b != 0xFF) return b;
        // 0xFF — could be 0xFF 0x00 (literal 0xFF) or a marker.
        // libjpeg loops to "swallow extra 0xFF bytes" before checking.
        var next: u8 = 0;
        while (self.pos < self.data.len) {
            next = self.data[self.pos];
            self.pos += 1;
            if (next != 0xFF) break;
        }
        if (next == 0) return 0xFF; // 0xFF 0x00 escape — literal 0xFF.
        // Real marker — record and supply 0 from here on.
        self.marker_byte = next;
        self.marker_seen = true;
        return 0;
    }

    /// Decode one binary symbol per T.81 §D.2.4 / §D.2.5. Updates
    /// the context cell at `ctx_ptr` (state index + MPS) per the
    /// `qe_table` transitions. Returns the decoded bit (0 or 1).
    pub fn decode(self: *QCoder, ctx_ptr: *Context) u1 {
        // Renormalize and pull in new bytes per T.81 §D.2.6 — same
        // structure as libjpeg's `while (e->a < 0x8000)` loop.
        while (self.a < 0x8000) {
            self.ct -= 1;
            if (self.ct < 0) {
                const byte = self.getByte();
                // Insert the byte into the bottom of the code register.
                self.c = (self.c << 8) | @as(u32, byte);
                self.ct += 8;
                // First two byte-loads — A is still 0; after the
                // second, ct just hit 0 and we re-init A to 0x8000.
                if (self.ct < 0) {
                    self.ct += 0; // no-op, here for symmetry with libjpeg
                } else if (self.ct == 0 and self.a == 0) {
                    // After loop completes the next `self.a <<= 1`
                    // below will produce a == 0, which would loop
                    // forever. libjpeg sets a = 0x8000 here so that
                    // the next shift yields 0x10000 (treated as
                    // 0 mod 65536, but the loop exits because the
                    // pre-shift comparison is `>= 0x8000`).
                    self.a = 0x8000;
                }
            }
            self.a = @truncate(@as(u32, self.a) << 1);
        }

        // Decode procedure per T.81 §D.2.4.
        const sv: Context = ctx_ptr.*;
        const state_index: usize = @as(usize, sv & 0x7F);
        const entry = QE_TABLE[state_index];
        const qe: u32 = entry.qe;
        const mps_bit: u1 = @intCast((sv >> 7) & 1);

        // Conditional subtraction (T.81 Fig. D.4).
        const a_after_mps: u32 = @as(u32, self.a) - qe;
        self.a = @truncate(a_after_mps);
        const temp: u32 = a_after_mps << @as(u5, @intCast(self.ct));
        // Note: libjpeg's reference does `temp <<= e->ct` with int,
        // but `ct` after loop exit is 0..7 — fits u5.

        var decoded: u1 = mps_bit;
        if (self.c >= temp) {
            // LPS region — possibly with MPS/LPS conditional exchange.
            self.c -= temp;
            if (self.a < qe) {
                // Conditional exchange: MPS occurred even though we
                // entered the LPS branch. State transitions per
                // estimate_after_MPS.
                self.a = @truncate(qe);
                ctx_ptr.* = (sv & 0x80) | @as(u8, entry.next_mps);
                decoded = mps_bit;
            } else {
                // True LPS.
                self.a = @truncate(qe);
                if (entry.switch_mps) {
                    ctx_ptr.* = ((sv & 0x80) ^ 0x80) | @as(u8, entry.next_lps);
                } else {
                    ctx_ptr.* = (sv & 0x80) | @as(u8, entry.next_lps);
                }
                decoded = @as(u1, ~mps_bit) & 1;
            }
        } else if (self.a < 0x8000) {
            // MPS region with conditional exchange (a after subtraction
            // dipped below 0x8000, so renormalization is needed).
            if (self.a < qe) {
                // Conditional exchange: LPS occurred.
                if (entry.switch_mps) {
                    ctx_ptr.* = ((sv & 0x80) ^ 0x80) | @as(u8, entry.next_lps);
                } else {
                    ctx_ptr.* = (sv & 0x80) | @as(u8, entry.next_lps);
                }
                decoded = @as(u1, ~mps_bit) & 1;
            } else {
                ctx_ptr.* = (sv & 0x80) | @as(u8, entry.next_mps);
                decoded = mps_bit;
            }
        }
        // If `self.c < temp` AND `self.a >= 0x8000`, no state change
        // needed; result is MPS at the current state.
        return decoded;
    }
};

// ─────── JPEG-specific binarization (T.81 §F.1.4.4.1) ───────────
//
// **WIP — Not yet implemented.** This file ships the Q-coder kernel
// only as a B1 checkpoint commit. The DC/AC binarization (per T.81
// Fig. F.19–F.24, mirroring libjpeg-turbo `jdarith.c`'s
// `decode_mcu_DC_first` / `decode_mcu_AC_first`) lands in a separate
// follow-on commit. See `docs/superpowers/specs/2026-05-13-arithmetic-
// coded-jpeg-design.md` for full design and
// `docs/superpowers/specs/B1_BINARIZATION_NOTES.md` (added at next
// session start) for the spec-reading subtleties around the unary
// magnitude-category encoding.

// ── Inline tests ────────────────────────────────────────────────

test "QE_TABLE: spec-known anchors" {
    // Index 0: Qe = 0x5a1d (the most-frequently-used probability)
    try std.testing.expectEqual(@as(u16, 0x5a1d), QE_TABLE[0].qe);
    try std.testing.expectEqual(@as(u7, 1), QE_TABLE[0].next_lps);
    try std.testing.expectEqual(@as(u7, 1), QE_TABLE[0].next_mps);
    try std.testing.expectEqual(true, QE_TABLE[0].switch_mps);
    // Index 112: last "real" state — Qe = 0x59eb, switch_mps set.
    try std.testing.expectEqual(@as(u16, 0x59eb), QE_TABLE[112].qe);
    try std.testing.expectEqual(true, QE_TABLE[112].switch_mps);
}

test "QCoder init: no allocations, neutral state" {
    const qc = QCoder.init(&[_]u8{});
    try std.testing.expectEqual(@as(u16, 0), qc.a);
    try std.testing.expectEqual(@as(u32, 0), qc.c);
    try std.testing.expectEqual(@as(i32, -16), qc.ct);
    try std.testing.expectEqual(false, qc.marker_seen);
}

test "QCoder.getByte: 0xFF 0x00 escape returns literal 0xFF" {
    const stream = [_]u8{ 0xFF, 0x00, 0x42 };
    var qc = QCoder.init(&stream);
    try std.testing.expectEqual(@as(u8, 0xFF), qc.getByte());
    try std.testing.expectEqual(@as(u8, 0x42), qc.getByte());
    try std.testing.expectEqual(false, qc.marker_seen);
}

test "QCoder.getByte: 0xFF NN where NN != 0 sets marker state" {
    const stream = [_]u8{ 0x01, 0xFF, 0xD0, 0x02 };
    var qc = QCoder.init(&stream);
    try std.testing.expectEqual(@as(u8, 0x01), qc.getByte());
    try std.testing.expectEqual(@as(u8, 0), qc.getByte()); // marker → zero
    try std.testing.expectEqual(true, qc.marker_seen);
    try std.testing.expectEqual(@as(u8, 0xD0), qc.marker_byte);
    // Subsequent calls keep returning 0.
    try std.testing.expectEqual(@as(u8, 0), qc.getByte());
}
