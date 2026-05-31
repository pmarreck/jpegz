//! Shared JPEG marker-segment primitives.
//!
//! Single source of truth for the handful of byte-level helpers that
//! are genuinely decoder-independent (same on-disk encoding regardless
//! of SOF profile). Keeps baseline / progressive / lossless / JPEG-LS
//! from each carrying their own byte-identical copy.
//!
//! Scope is deliberately narrow: ONLY primitives that are provably
//! identical across decoders live here. `parseSof` / `parseDqt` /
//! `parseDht` / `parseSos` are NOT here — they have diverged per
//! decoder (error-reporting style, lossless's DC-only Huffman tables,
//! per-profile FrameInfo/ScanInfo shapes) and unifying them is a
//! separate, deliberate refactor, not a mechanical dedupe.

/// Read a 2-byte big-endian JPEG segment length (T.81 §B.1.1.4: the
/// `Lf`/`Lp`/… field that includes its own 2 bytes). Returns 0 when
/// the read would run past the buffer, so callers can treat 0 as
/// "truncated / no valid length here".
pub fn parseSegmentLength(data: []const u8, pos: usize) usize {
    if (pos + 1 >= data.len) return 0;
    return (@as(usize, data[pos]) << 8) | data[pos + 1];
}
