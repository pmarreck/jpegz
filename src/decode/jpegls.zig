//! JPEG-LS (T.87) cleanroom decoder — entry point + marker walker.
//!
//! v1 scope per `docs/superpowers/specs/2026-05-16-jpegls-cleanroom-design.md`:
//! NEAR=0 lossless, 8 and 16-bit precision, 1- and 3-component,
//! sample-interleaved (mode 2) and none-interleaved (mode 0).
//!
//! This file (§1c) lays the marker walker and `decode()` skeleton.
//! The actual scan body — regular mode + run mode entropy decode —
//! lands in §2. Until then `decode()` returns `error.NotImplemented`
//! after parsing the headers, and the public dispatcher in
//! `src/jpegz.zig` falls through to the charls wrapper.

const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const errors = @import("../core/errors.zig");
const types = @import("../core/types.zig");
const codec = @import("jpegls_codec.zig");
const bitstream = @import("jpegls_bitstream");
const findings_mod = @import("findings.zig");

const Error = errors.DecodeError;

/// Entropy faults a scan decoder can hit. `decodeWithOptions` turns each
/// into a FAIL finding (validate rulings 2026-11-21) via the exhaustive
/// `faultFinding` and returns `BackendError`; decoding stops there.
const ScanFault = error{ GolombCodeInvalid, RunModeInvalid, RestartMissing, RestartUnexpected };
const ScanError = Error || ScanFault;

fn faultFinding(fault: ScanFault) struct { code: errors.FindingCode, detail: []const u8 } {
    return switch (fault) {
        error.GolombCodeInvalid => .{ .code = .jpegls_golomb_code_invalid, .detail = "Golomb code with a unary prefix longer than LIMIT - qbpp - 1 (T.87 A.5.3)" },
        error.RunModeInvalid => .{ .code = .jpegls_invalid_run_mode, .detail = "run segment extends past the end of the line (T.87 A.7)" },
        error.RestartMissing => .{ .code = .restart_marker_missing, .detail = "no RSTm marker at a restart-interval boundary" },
        error.RestartUnexpected => .{ .code = .restart_marker_unexpected, .detail = "RSTm out of the modulo-8 sequence at a restart-interval boundary" },
    };
}

/// The fault half of a scan error, or null for an ordinary decode error.
fn asFault(err: ScanError) ?ScanFault {
    return switch (err) {
        error.GolombCodeInvalid, error.RunModeInvalid, error.RestartMissing, error.RestartUnexpected => |fault| fault,
        else => null,
    };
}

/// What a scan decoder leaves for its caller: where a fault points, and
/// whether reads ran past the entropy data (zero bits supplied).
const ScanReport = struct {
    fault_at: usize = 0,
    starved: bool = false,
    exhausted: bool = false,
    /// Offset of the marker's FF and the marker byte, when reads stopped at one.
    marker_at: ?usize = null,
    marker_byte: u8 = 0,
    /// Where interval and scan-end findings go, and the offset of the
    /// scan's entropy data in the input.
    sink: ?*findings_mod.FindingsSink = null,
    base: usize = 0,

    /// T.87 A.1 at the end of a restart interval or scan: report nonzero
    /// padding (123, FAIL) and whole leftover bytes (8, emitted as the T.81
    /// path emits it; validate rulings 2026-11-22). A segment whose reads
    /// ran out of data ends `.ok` here and is reported as truncation.
    fn checkEnd(self: *const ScanReport, br: *const bitstream.BitReader, comptime where: enum { interval, scan_end }) Error!void {
        const s = self.sink orelse return;
        switch (br.segmentEnd()) {
            .ok => {},
            .padding => |pad| {
                var buf: [64]u8 = undefined;
                const detail = std.fmt.bufPrint(&buf, "{d} padding bit(s) not zero (T.87 A.1)", .{pad.bits}) catch buf[0..0];
                s.emitExact(.fail, .jpegls_padding_not_zeros, @intCast(self.base + pad.offset), detail) catch return error.OutOfMemory;
            },
            .leftover => |at| s.emitExact(.warn, .extraneous_bytes_before_marker, @intCast(self.base + at),
                if (where == .interval) "jpegls_interval" else "jpegls_scan_end") catch return error.OutOfMemory,
        }
    }

    fn capture(self: *ScanReport, br: *const bitstream.BitReader) void {
        self.fault_at = br.faultOffset();
        self.starved = br.starved;
        self.exhausted = br.exhausted;
        if (br.marker_seen) {
            self.marker_at = br.pos - 1;
            self.marker_byte = br.marker_byte;
        }
    }
};

/// Which T.87 C.2.4.1.1 (Table C.1) constraint an LSE ID 1 breaks, if any,
/// for frame precision `P` and the scan's NEAR. Zero fields are defaults.
const LseConstraint = enum { maxval, thresholds, reset };

fn lseViolation(preset: PresetParams, P: u8, near: u32) ?LseConstraint {
    const bit_max: u32 = (@as(u32, 1) << @intCast(P)) - 1;
    if (preset.MAXVAL != 0 and (preset.MAXVAL < 1 or preset.MAXVAL > bit_max)) return .maxval;
    const maxval: u32 = if (preset.MAXVAL != 0) preset.MAXVAL else bit_max;
    var defaults: codec.ScanState = undefined;
    defaults.reset(P, near);
    defaults.MAXVAL = maxval;
    defaults.setDefaultThresholds();
    if (preset.T1 != 0 and (preset.T1 < near + 1 or preset.T1 > maxval)) return .thresholds;
    const t1 = if (preset.T1 != 0) preset.T1 else defaults.T1;
    if (preset.T2 != 0 and (preset.T2 < t1 or preset.T2 > maxval)) return .thresholds;
    const t2 = if (preset.T2 != 0) preset.T2 else defaults.T2;
    if (preset.T3 != 0 and (preset.T3 < t2 or preset.T3 > maxval)) return .thresholds;
    if (preset.RESET != 0 and (preset.RESET < 3 or preset.RESET > @max(255, maxval))) return .reset;
    return null;
}

/// Offset of the marker that ends the entropy data starting at `start`:
/// the first FF followed by a byte of 0x80 or more that is not an RSTm
/// (T.87 A.1.3 bit stuffing keeps every other FF below 0x80).
/// T.87 C.2.2: Y = 0 may be defined "in a DNL marker immediately following
/// the first scan". Walk from `start` to the first SOS, skip its entropy
/// data (T.87 bit stuffing, RSTm and FF fill), and return NL from a DNL
/// there (Ld = 4, NL > 0), or null.
pub fn dnlLines(data: []const u8, start: usize) ?u16 {
    var pos = start;
    while (true) {
        while (pos < data.len and data[pos] != 0xFF) pos += 1;
        while (pos + 1 < data.len and data[pos + 1] == 0xFF) pos += 1;
        if (pos + 1 >= data.len) return null;
        const marker = data[pos + 1];
        pos += 2;
        switch (marker) {
            0x01, 0xD0...0xD7 => continue,
            0x00, 0xD8, 0xD9, 0xF7 => return null,
            else => {},
        }
        if (pos + 1 >= data.len) return null;
        const len = parseSegmentLength(data, pos);
        if (len < 2) return null;
        pos += len;
        if (marker == M_SOS) break;
    }
    const at = endOfScan(data, pos) orelse return null;
    if (data[at + 1] != 0xDC or at + 5 >= data.len) return null;
    if (parseSegmentLength(data, at + 2) != 4) return null;
    const lines = (@as(u16, data[at + 4]) << 8) | data[at + 5];
    return if (lines == 0) null else lines;
}

fn endOfScan(data: []const u8, start: usize) ?usize {
    var i = start;
    while (i + 1 < data.len) : (i += 1) {
        if (data[i] != 0xFF) continue;
        const next = data[i + 1];
        if (next < 0x80 or next == 0xFF) continue;
        if (next >= 0xD0 and next <= 0xD7) {
            i += 1;
            continue;
        }
        return i;
    }
    return null;
}

/// Interleave the ILV 0 component planes into one raster image. The
/// planes stay owned by the caller.
fn interleavePlanes(allocator: Allocator, frame: *const FrameInfo, planes: *const [4]?types.Image) Error!types.Image {
    const nc: usize = frame.num_components;
    const bytes: usize = if (frame.P <= 8) 1 else 2;
    const samples: usize = @as(usize, frame.width) * frame.height;
    const pixels = try allocator.alloc(u8, samples * nc * bytes);
    errdefer allocator.free(pixels);
    for (0..nc) |c| {
        const plane = planes[c].?.pixels;
        for (0..samples) |i| {
            @memcpy(pixels[(i * nc + c) * bytes ..][0..bytes], plane[i * bytes ..][0..bytes]);
        }
    }
    return .{
        .pixels = pixels,
        .width = frame.width,
        .height = frame.height,
        .channels = @intCast(nc),
        .bits_per_sample = frame.P,
        .source_color_space = .rgb,
        .layout = .rgb,
    };
}

/// Decode one scan, reporting its faults and any read past the entropy data
/// to `sink` at offsets in `data` (the scan's entropy data starts at `start`).
fn decodeScanReported(
    allocator: Allocator,
    data: []const u8,
    start: usize,
    frame: *const FrameInfo,
    scan: *const ScanInfo,
    preset: *const PresetParams,
    sink: ?*findings_mod.FindingsSink,
) Error!types.Image {
    var report: ScanReport = .{ .sink = sink, .base = start };
    const entropy = data[start..];
    const result: ScanError!types.Image = if (frame.num_components == 1 or scan.ILV == 0)
        // ILV is irrelevant for single-component scans (T.87 A.2): the
        // line, sample and none layouts are the same bitstream. An ILV 0
        // scan of a multi-component frame codes one component the same way.
        decodeScanMono(allocator, entropy, frame, scan, preset, &report)
    else if (frame.num_components == 3 and scan.ILV == 2)
        decodeScanRgb(allocator, entropy, frame, scan, preset, &report)
    else if (frame.num_components >= 2 and scan.ILV == 1)
        decodeScanLine(allocator, entropy, frame, scan, preset, &report)
    else
        error.NotImplemented;
    var image = result catch |err| {
        const fault = asFault(err) orelse return @errorCast(err);
        if (sink) |s| {
            // Zero bits supplied past the entropy data make invalid codes;
            // the cause then is the data ending early, not the code.
            if (report.starved) {
                try reportStarvation(s, &report, start, data.len);
            } else {
                const finding = faultFinding(fault);
                s.emitExact(.fail, finding.code, @intCast(start + report.fault_at), finding.detail) catch return error.OutOfMemory;
            }
        }
        return error.BackendError;
    };
    errdefer image.deinit(allocator);
    // Reads past the entropy data got zero bits, as T.81 decoders recover.
    if (report.starved) if (sink) |s| try reportStarvation(s, &report, start, data.len);
    return image;
}

/// Report reads that ran past the entropy data: at the end of the input
/// (`truncated_stream`), or at a marker (`insufficient_data`, or 57 for an
/// RSTm inside an interval), with the parity validate asked for.
fn reportStarvation(s: *findings_mod.FindingsSink, report: *const ScanReport, start: usize, data_len: usize) Error!void {
    {
        if (report.exhausted) {
            // data_len is not a byte of the input, so this offset is not exact.
            s.emit(.fail, .truncated_stream, @intCast(data_len), "JPEG-LS entropy data ended before every line was decoded") catch return error.OutOfMemory;
        } else if (report.marker_at) |at| {
            const rst = report.marker_byte >= 0xD0 and report.marker_byte <= 0xD7;
            s.emitExact(.fail, if (rst) .restart_marker_unexpected else .insufficient_data, @intCast(start + at),
                if (rst) "RSTm inside a restart interval: entropy data ended early" else "marker reached before every line was decoded") catch return error.OutOfMemory;
        }
    }
}
const native_endian = builtin.cpu.arch.endian();

// T.87 marker bytes (those that differ from T.81 are noted).
const M_SOI: u8 = 0xD8;
const M_SOF55: u8 = 0xF7; // T.87 §C.2.2 — the only SOF used by JPEG-LS
const M_LSE: u8 = 0xF8; // T.87 Table C.1, §C.2.4 — JPEG-LS preset parameters (LSE)
const M_SOS: u8 = 0xDA;
const M_EOI: u8 = 0xD9;
const M_DRI: u8 = 0xDD; // optional, T.81-compatible
const M_COM: u8 = 0xFE;
const M_DNL: u8 = 0xDC; // Define Number of Lines (rare)

/// Frame info parsed from SOF55.
pub const FrameInfo = struct {
    /// Precision in bits per sample (1..16, typically 8/12/16).
    P: u8,
    /// u32: an LSE ID 4 (T.87 C.2.4.1.4) can give sizes above 65535.
    height: u32,
    width: u32,
    /// Number of components (1 or 3 in v1 scope).
    num_components: u8,
    components: [4]ComponentInfo,
};

pub const ComponentInfo = struct {
    id: u8,
    h_factor: u4,
    v_factor: u4,
    /// `Tqi` byte from SOF55 — reserved, must be 0.
    qt_index: u8,
};

/// Scan-specific parameters from SOS.
pub const ScanInfo = struct {
    num_components: u8,
    comp_indices: [4]usize,
    /// Near-lossless tolerance from SOS (T.87 §C.2.3 byte). 0 = lossless.
    NEAR: u8,
    /// Interleave mode (0 = none/planar, 1 = line, 2 = sample). v1
    /// supports 0 and 2 once §2 ships.
    ILV: u8,
    /// Lines per restart interval (DRI); 0 = none. Set by the caller of
    /// `parseSos` from the most recent DRI.
    restart_interval: u32 = 0,
    /// Some component selects a mapping table (Tdi != 0, T.87 C.2.3 and
    /// C.2.4.1.2): its decoded values are table indices, not samples.
    mapping_table: bool = false,
    /// Which MAXVAL drives RANGE, qbpp, bpp and LIMIT (see `Derivation`).
    derivation: Derivation = .spec,
    /// Point transform Pt (SOS Al, T.87 4.3.2): output samples are Rx << Pt.
    pt: u4 = 0,
    /// Offset of the SOS Al:Ah byte, for finding 128.
    al_at: usize = 0,
    /// Where line-interleaved components of unequal plane size go (see
    /// `DecodeOptions.planes`); null refuses them.
    planes_out: ?*[4]?types.Image = null,
    /// Mapping table selector Tmi per scan component, and its byte offset
    /// (T.87 C.2.3); 0 selects no table.
    tmi: [4]u8 = .{ 0, 0, 0, 0 },
    tmi_at: [4]usize = .{ 0, 0, 0, 0 },
};

/// A mapping table assembled from an LSE ID 2 and its ID 3 continuations
/// (T.87 C.2.4.1.2-3): `wt` bytes per entry, entries in ascending Rx.
const MappingTable = struct {
    lse_at: usize,
    wt: u8,
    bytes: std.ArrayList(u8),
};

/// The most recent mapping-table segment, for the continuation rule.
const MappingTail = struct { tid: u8, wt: u8, end: usize };

/// `spec`: T.87 A.2.1, from the MAXVAL in force. `charls`: CharLS 3.0's
/// coding of an LSE ID 1 MAXVAL below 2^P - 1, from 2^P - 1 regardless
/// (the LSE MAXVAL still sets the default thresholds). Only
/// `decodeScanChecked` selects `charls`, to classify such scans.
pub const Derivation = enum { spec, charls };

/// At a restart-interval boundary: consume RSTm and reset the coding state
/// as at the start of the scan (contexts, run index). Callers zero their
/// line buffers, so the first line after the marker sees zero neighbors,
/// as CharLS's decoder does.
fn restartAt(state: *codec.ScanState, br: *bitstream.BitReader, P: u8, scan: *const ScanInfo, preset: PresetParams, rst_index: *u3) ScanError!void {
    try br.skipToRestart(0xD0 + @as(u8, rst_index.*));
    rst_index.* +%= 1;
    initScanState(state, P, scan.NEAR, preset, scan.derivation);
}

/// True at the first line of every restart interval after the first.
fn restartDue(scan: *const ScanInfo, y: u32) bool {
    return scan.restart_interval != 0 and y != 0 and y % scan.restart_interval == 0;
}

/// Caller-supplied knobs. Mirrors `baseline.DecodeOptions` shape so the
/// dispatcher can pass through a `FindingsSink` uniformly. The only
/// emit site in v1 JPEG-LS is the marker walker's extraneous-bytes
/// tolerance; entropy decode itself never early-returns on
/// `marker_seen` (the codec consumes a fixed pixel count and gets
/// zero-padded bits past the end, T.87 §A.5.3).
pub const DecodeOptions = struct {
    findings_sink: ?*findings_mod.FindingsSink = null,
    /// Apply mapping tables to the output (T.87 clause 7). Validation
    /// passes false: the table indices are what the scan codes, and the
    /// checks do not depend on how entries map to samples.
    map_samples: bool = true,
    /// Receives each component plane at its own size when the frame's
    /// components have unequal sizes (subsampling, T.81 A.1.1); the
    /// returned image is then empty. Without it such frames are
    /// NotImplemented: one raster cannot hold them. The caller frees the
    /// planes.
    planes: ?*[4]?types.Image = null,
};

/// Every component plane at its own size: subsampled frames decode into
/// planes, others are de-interleaved. The caller frees each plane.
pub fn decodePlanes(allocator: Allocator, data: []const u8) Error![4]?types.Image {
    var planes: [4]?types.Image = .{ null, null, null, null };
    errdefer for (&planes) |*plane| if (plane.*) |*image| image.deinit(allocator);
    var image = try decodeWithOptions(allocator, data, .{ .planes = &planes });
    defer image.deinit(allocator);
    for (planes) |plane| if (plane != null) return planes;
    const nc: usize = image.channels;
    const bps: usize = if (image.bits_per_sample <= 8) 1 else 2;
    const samples: usize = @as(usize, image.width) * image.height;
    for (0..nc) |c| {
        const pixels = try allocator.alloc(u8, samples * bps);
        for (0..samples) |i| @memcpy(pixels[i * bps ..][0..bps], image.pixels[(i * nc + c) * bps ..][0..bps]);
        planes[c] = .{
            .pixels = pixels,
            .width = image.width,
            .height = image.height,
            .channels = 1,
            .bits_per_sample = image.bits_per_sample,
            .source_color_space = .grayscale,
            .layout = .grayscale,
        };
    }
    return planes;
}

const PlaneDims = struct { w: u32, h: u32 };

fn maxFactors(frame: *const FrameInfo) struct { h: u32, v: u32 } {
    var h: u32 = 1;
    var v: u32 = 1;
    for (frame.components[0..frame.num_components]) |c| {
        h = @max(h, c.h_factor);
        v = @max(v, c.v_factor);
    }
    return .{ .h = h, .v = v };
}

/// Plane size of frame component `c` (T.87 C.2.2 with T.81 A.1.1):
/// ceil(X * Hi / Hmax) by ceil(Y * Vi / Vmax).
fn planeDims(frame: *const FrameInfo, c: usize) PlaneDims {
    const max = maxFactors(frame);
    const comp = frame.components[c];
    return .{
        .w = @intCast(std.math.divCeil(u64, @as(u64, frame.width) * comp.h_factor, max.h) catch unreachable),
        .h = @intCast(std.math.divCeil(u64, @as(u64, frame.height) * comp.v_factor, max.v) catch unreachable),
    };
}

fn subsampled(frame: *const FrameInfo) bool {
    for (frame.components[1..frame.num_components]) |c| {
        if (c.h_factor != frame.components[0].h_factor or c.v_factor != frame.components[0].v_factor) return true;
    }
    return false;
}

fn emptyImage(allocator: Allocator, P: u8) Error!types.Image {
    return .{
        .pixels = try allocator.alloc(u8, 0),
        .width = 0,
        .height = 0,
        .channels = 0,
        .bits_per_sample = P,
        .source_color_space = .grayscale,
        .layout = .grayscale,
    };
}

/// Default-options entry — null sink, silent tolerance.
pub fn decode(allocator: Allocator, data: []const u8) Error!types.Image {
    return decodeWithOptions(allocator, data, .{});
}

/// Same as `decode` but accepts a `DecodeOptions`. Currently the only
/// honored knob is `findings_sink`: when non-null, the cleanroom emits
/// a `Finding(.warn, .extraneous_bytes_before_marker)` for each gap of
/// non-0xFF bytes the marker walker silently skips.
pub fn decodeWithOptions(
    allocator: Allocator,
    data: []const u8,
    options: DecodeOptions,
) Error!types.Image {
    if (data.len < 4) return error.TruncatedStream;
    if (data[0] != 0xFF or data[1] != M_SOI) return error.InvalidMarker;

    var pos: usize = 2;
    var frame: ?FrameInfo = null;
    // LSE preset-parameter overrides — applied during scan init in §2.
    var preset: PresetParams = .{};
    // Lines per restart interval from DRI; 0 = no restart markers.
    var restart_interval: u32 = 0;
    // Offset of the last LSE marker, for finding 121.
    var lse_at: ?usize = null;
    // Frame dimensions from an LSE ID 4, applied at the first scan.
    var oversize: ?Oversize = null;
    // ILV 0 component planes, decoded one scan at a time.
    var planes: [4]?types.Image = .{ null, null, null, null };
    var planes_done: usize = 0;
    defer for (&planes) |*plane| if (plane.*) |*image| image.deinit(allocator);
    // Mapping tables by TID (T.87 C.2.4.1.2-3).
    var tables: [256]?MappingTable = @splat(null);
    defer for (&tables) |*slot| if (slot.*) |*table| table.bytes.deinit(allocator);
    var mapping_tail: ?MappingTail = null;

    while (pos + 1 < data.len) {
        const skip_start = pos;
        while (pos < data.len and data[pos] != 0xFF) pos += 1;
        if (pos > skip_start) {
            if (options.findings_sink) |sink| {
                var buf: [96]u8 = undefined;
                const next_marker: u8 = if (pos + 1 < data.len) data[pos + 1] else 0;
                const detail = std.fmt.bufPrint(&buf,
                    "Corrupt JPEG data: {d} extraneous bytes before marker 0x{x:0>2}",
                    .{ pos - skip_start, next_marker }) catch buf[0..0];
                sink.emit(.warn, .extraneous_bytes_before_marker,
                    @intCast(skip_start), detail) catch return error.OutOfMemory;
            }
        }
        if (pos + 1 >= data.len) return error.TruncatedStream;
        while (pos + 1 < data.len and data[pos + 1] == 0xFF) pos += 1;
        if (pos + 1 >= data.len) return error.TruncatedStream;
        const marker = data[pos + 1];
        pos += 2;
        switch (marker) {
            M_EOI => return error.TruncatedStream, // EOI before SOS — malformed
            // T.81 SOFn markers — this isn't a JPEG-LS bitstream.
            // Bail out so the dispatcher tries the next path.
            0xC0...0xC3, 0xC5...0xCB, 0xCD...0xCF => return error.NotImplemented,
            M_SOF55 => {
                frame = try parseSof55(data, pos);
                if (frame.?.P < 2 or frame.?.P > 16) return error.UnsupportedPrecision;
                if (frame.?.num_components != 1 and frame.?.num_components != 3)
                    return error.NotImplemented;
                // Sampling factors divide plane sizes (T.81 A.1.1).
                for (frame.?.components[0..frame.?.num_components]) |c| {
                    if (c.h_factor == 0 or c.v_factor == 0) return error.InvalidMarker;
                }
                // Subsampled components (T.87 conformance t8sse0/3) have
                // their own plane sizes, which one raster cannot hold.
                if (subsampled(&frame.?) and options.planes == null) return error.NotImplemented;
                pos += parseSegmentLength(data, pos);
            },
            M_LSE => {
                if (pos + 2 < data.len and data[pos + 2] == 4) {
                    oversize = try parseOversize(data, pos);
                    pos += parseSegmentLength(data, pos);
                    continue;
                }
                if (pos + 2 < data.len and (data[pos + 2] == 2 or data[pos + 2] == 3)) {
                    try parseMapping(allocator, data, pos, &tables, &mapping_tail, options.findings_sink);
                    pos += parseSegmentLength(data, pos);
                    continue;
                }
                if (pos + 2 < data.len and data[pos + 2] == 1) lse_at = pos - 2;
                try parseLse(data, pos, &preset);
                pos += parseSegmentLength(data, pos);
            },
            M_DRI => {
                // T.87 C.2.5: Ri in 2, 3 or 4 bytes (Lr = 4, 5 or 6), lines
                // per restart interval; 0 disables restarts.
                const seg_len = parseSegmentLength(data, pos);
                if (seg_len < 4 or seg_len > 6 or pos + seg_len > data.len) return error.InvalidMarker;
                restart_interval = 0;
                for (data[pos + 2 .. pos + seg_len]) |byte| restart_interval = (restart_interval << 8) | byte;
                pos += seg_len;
            },
            M_DNL => {
                // Define Number of Lines (T.87 §B.2.5). Rarely used.
                pos += parseSegmentLength(data, pos);
            },
            M_SOS => {
                if (frame == null) return error.InvalidMarker;
                // CharLS's rule for LSE ID 4: it fills a dimension the SOF left
                // at 0, and a nonzero SOF value beside a nonzero LSE value
                // contradicts it.
                if (oversize) |o| {
                    if (o.height != 0) {
                        if (frame.?.height != 0) return error.InvalidMarker;
                        frame.?.height = o.height;
                    }
                    if (o.width != 0) {
                        if (frame.?.width != 0) return error.InvalidMarker;
                        frame.?.width = o.width;
                    }
                    oversize = null;
                }
                if (frame.?.width == 0) return error.InvalidMarker;
                // T.87 C.2.2: a Y = 0 that no LSE ID 4 filled comes from a
                // DNL immediately following the first scan.
                if (frame.?.height == 0) frame.?.height = dnlLines(data, pos - 2) orelse return error.InvalidMarker;
                var scan = try parseSos(data, pos, &frame.?);
                scan.restart_interval = restart_interval;
                pos += parseSegmentLength(data, pos);
                if (scan.ILV > 2) return error.NotImplemented;
                if (lse_at) |at| if (lseViolation(preset, frame.?.P, scan.NEAR)) |which| {
                    if (options.findings_sink) |sink| sink.emitExact(.fail, .jpegls_context_table_invalid, @intCast(at), @tagName(which)) catch return error.OutOfMemory;
                    return error.BackendError;
                };
                if (scan.mapping_table) try checkMapping(&scan, &tables, preset, frame.?.P, options.findings_sink);
                if (subsampled(&frame.?)) {
                    // T.87 C.2.3: sample interleave only for components of
                    // equal size; otherwise the scan has no specified decode
                    // (FAIL 129, validate ruling 2026-11-22).
                    if (scan.ILV == 2) {
                        if (options.findings_sink) |sink| {
                            var buf: [160]u8 = undefined;
                            var len: usize = (std.fmt.bufPrint(&buf, "ILV 2 across components of unequal size (T.87 C.2.3); Hi x Vi:", .{}) catch unreachable).len;
                            for (scan.comp_indices[0..scan.num_components]) |fc| {
                                const c = frame.?.components[fc];
                                len += (std.fmt.bufPrint(buf[len..], " {d}x{d}", .{ c.h_factor, c.v_factor }) catch break).len;
                            }
                            // The ILV byte precedes Al:Ah in the SOS.
                            sink.emitExact(.fail, .jpegls_sample_interleave_subsampled, @intCast(scan.al_at - 1), buf[0..len]) catch return error.OutOfMemory;
                        }
                        return error.BackendError;
                    }
                    // Only line interleave is modeled for unequal planes:
                    // ILV 0, restarts, the point transform, mapping tables
                    // and the dual MAXVAL decode are not.
                    if (scan.ILV != 1 or scan.restart_interval != 0 or scan.pt != 0 or scan.mapping_table or
                        customMaxval(preset, frame.?.P)) return error.NotImplemented;
                    scan.planes_out = options.planes;
                }
                if (frame.?.num_components > 1 and scan.ILV == 0) {
                    // T.87 A.2: ILV 0 codes each component in its own scan.
                    if (scan.num_components != 1) return error.InvalidMarker;
                    const ci = scan.comp_indices[0];
                    if (planes[ci] != null) return error.InvalidMarker;
                    planes[ci] = try decodeScanChecked(allocator, data, pos, &frame.?, &scan, &preset, lse_at, options.findings_sink);
                    try applyPointTransform(&planes[ci].?, &frame.?, &scan, options.findings_sink);
                    if (options.map_samples) try applyMapping(&planes[ci].?, &scan, &tables);
                    planes_done += 1;
                    if (planes_done == frame.?.num_components) return interleavePlanes(allocator, &frame.?, &planes);
                    pos = endOfScan(data, pos) orelse return error.TruncatedStream;
                    continue;
                }
                var image = try decodeScanChecked(allocator, data, pos, &frame.?, &scan, &preset, lse_at, options.findings_sink);
                errdefer image.deinit(allocator);
                try applyPointTransform(&image, &frame.?, &scan, options.findings_sink);
                if (options.map_samples) try applyMapping(&image, &scan, &tables);
                return image;
            },
            // Standalone markers we can skip safely (RST, TEM, SOI/EOI
            // shouldn't appear here; treat as no-op).
            0x01, 0xD0...0xD7, M_SOI => continue,
            // Length-prefixed (APPn, COM, etc.) — skip payload.
            else => pos += parseSegmentLength(data, pos),
        }
    }
    return error.TruncatedStream;
}

/// Preset coding parameters from LSE subtype 4. Defaults are the
/// T.87 §C.2.4.1.1 baselines, applied lazily by `ScanState.reset`
/// when none are explicitly set.
pub const PresetParams = struct {
    /// 0 means "use the spec default for the bpp" — handled inside
    /// ScanState. Otherwise the encoder-supplied override.
    MAXVAL: u32 = 0,
    T1: u32 = 0,
    T2: u32 = 0,
    T3: u32 = 0,
    RESET: u32 = 0,
};

const parseSegmentLength = @import("segment.zig").parseSegmentLength;

/// SOF55 layout (T.87 §C.2.2):
///   FF F7 [Lf:2] [P:1] [Y:2] [X:2] [Nf:1] { [Ci:1] [Hi:1:Vi:1] [Tqi:1] }*Nf
fn parseSof55(data: []const u8, pos: usize) Error!FrameInfo {
    const seg_len = parseSegmentLength(data, pos);
    if (seg_len < 8 or pos + seg_len > data.len) return error.TruncatedStream;
    var fi: FrameInfo = undefined;
    fi.P = data[pos + 2];
    fi.height = (@as(u16, data[pos + 3]) << 8) | data[pos + 4];
    fi.width = (@as(u16, data[pos + 5]) << 8) | data[pos + 6];
    fi.num_components = data[pos + 7];
    if (fi.num_components == 0 or fi.num_components > 4) return error.InvalidMarker;
    if (seg_len < 8 + @as(usize, fi.num_components) * 3) return error.TruncatedStream;
    var i: usize = 0;
    while (i < fi.num_components) : (i += 1) {
        const off = pos + 8 + i * 3;
        fi.components[i] = .{
            .id = data[off],
            .h_factor = @intCast(data[off + 1] >> 4),
            .v_factor = @intCast(data[off + 1] & 0x0F),
            .qt_index = data[off + 2],
        };
    }
    return fi;
}

/// LSE layout (T.87 §C.2.4). First byte after the length is the
/// subtype `ID`. Only ID 1 (preset coding parameters) is applied. IDs 2
/// and 3 (mapping table specification and continuation) and ID 4
/// (oversize image dimensions) are not handled yet; see
/// docs/plan_context/t81-t87-gap-inventory-2026-11-21.md.
/// Scan state for frame precision `P`, with any LSE ID 1 threshold and
/// RESET overrides; a zero field keeps its default (T.87 C.2.4.1.1). A
/// custom MAXVAL is refused before this point (see `customMaxval`).
/// T.87 A.2.1 derives RANGE, qbpp, bpp and LIMIT from the MAXVAL in
/// force, so an LSE ID 1 MAXVAL below 2^P - 1 changes the coding. CharLS
/// 3.0 codes such scans from 2^P - 1 instead, and a spec decode of its
/// output silently yields other samples. Validate's ruling (2026-11-22):
/// decode both ways and classify by which decodes finish with no finding.
///   both:        the A.2.1 image, plus INFO 127 `also_charls` (samples
///                may differ between decoders);
///   A.2.1 only:  the A.2.1 image;
///   CharLS only: INFO 127 `only_charls` and NotImplemented (unsupported),
///                until a known-defect admission;
///   neither:     the A.2.1 decode's findings and outcome.
fn decodeScanChecked(
    allocator: Allocator,
    data: []const u8,
    start: usize,
    frame: *const FrameInfo,
    scan: *const ScanInfo,
    preset: *const PresetParams,
    lse_at: ?usize,
    sink: ?*findings_mod.FindingsSink,
) Error!types.Image {
    if (!customMaxval(preset.*, frame.P)) return decodeScanReported(allocator, data, start, frame, scan, preset, sink);

    var spec_sink = findings_mod.FindingsSink.init(allocator);
    defer spec_sink.deinit();
    var spec_scan = scan.*;
    spec_scan.derivation = .spec;
    var spec_err: ?Error = null;
    var spec_image: ?types.Image = decodeScanReported(allocator, data, start, frame, &spec_scan, preset, &spec_sink) catch |err| switch (err) {
        error.OutOfMemory, error.NotImplemented => return err,
        else => blk: {
            spec_err = err;
            break :blk null;
        },
    };
    errdefer if (spec_image) |*image| image.deinit(allocator);

    var charls_sink = findings_mod.FindingsSink.init(allocator);
    defer charls_sink.deinit();
    var charls_scan = scan.*;
    charls_scan.derivation = .charls;
    const charls_clean = if (decodeScanReported(allocator, data, start, frame, &charls_scan, preset, &charls_sink)) |image| blk: {
        var owned = image;
        owned.deinit(allocator);
        break :blk charls_sink.items().len == 0;
    } else |err| switch (err) {
        error.OutOfMemory => return err,
        else => false,
    };
    const spec_clean = spec_image != null and spec_sink.items().len == 0;

    if (spec_clean) {
        if (charls_clean) try emitDerivation(sink, lse_at, "also_charls: the scan also decodes cleanly under CharLS 3.0's RANGE-from-P coding; decoders may give different samples");
        return spec_image.?;
    }
    if (charls_clean) {
        try emitDerivation(sink, lse_at, "only_charls: the scan decodes only under CharLS 3.0's RANGE-from-P coding of an LSE MAXVAL below 2^P - 1 (T.87 A.2.1 derives RANGE from MAXVAL)");
        if (spec_image) |*image| image.deinit(allocator);
        spec_image = null;
        return error.NotImplemented;
    }
    if (sink) |s| for (spec_sink.items()) |f| {
        if (f.offset_is_exact)
            s.emitExact(f.severity, f.code, f.offset.?, f.detail) catch return error.OutOfMemory
        else
            s.emit(f.severity, f.code, f.offset, f.detail) catch return error.OutOfMemory;
    };
    if (spec_image) |image| return image;
    return spec_err.?;
}

/// T.87 4.3.2: the decoder output is Rx * 2^Pt. A sample whose shifted
/// value exceeds 2^P - 1 has no P-bit representation: it saturates to
/// 2^P - 1 and the scan gets one FAIL 128 (validate ruling 2026-11-22) at
/// the SOS Al byte, naming the first such sample and the count.
fn applyPointTransform(image: *types.Image, frame: *const FrameInfo, scan: *const ScanInfo, sink: ?*findings_mod.FindingsSink) Error!void {
    if (scan.pt == 0) return;
    const max: u32 = (@as(u32, 1) << @intCast(frame.P)) - 1;
    const channels: usize = image.channels;
    const wide = frame.P > 8;
    const samples = @as(usize, image.width) * image.height * channels;
    var count: usize = 0;
    var first: usize = 0;
    var first_rx: u32 = 0;
    for (0..samples) |i| {
        // A mapped component takes no point transform (125 covers the
        // pair); 128 is for unmapped components (validate ruling).
        if (channelTmi(scan, channels, i % channels) != 0) continue;
        const rx: u32 = if (wide) std.mem.readInt(u16, image.pixels[2 * i ..][0..2], native_endian) else image.pixels[i];
        var v = rx << scan.pt;
        if (v > max) {
            if (count == 0) {
                first = i;
                first_rx = rx;
            }
            count += 1;
            v = max;
        }
        if (wide) std.mem.writeInt(u16, image.pixels[2 * i ..][0..2], @intCast(v), native_endian) else image.pixels[i] = @intCast(v);
    }
    if (count == 0) return;
    const s = sink orelse return;
    const pixel = first / channels;
    // One plane per scan for ILV 0; otherwise channels follow frame order.
    const comp = if (channels == 1) scan.comp_indices[0] else first % channels;
    var buf: [192]u8 = undefined;
    const detail = std.fmt.bufPrint(&buf, "component {d}, line {d}, column {d}: Rx {d} << Pt {d} exceeds 2^P - 1 = {d}; {d} sample(s) saturated (T.87 4.3.2)", .{
        frame.components[comp].id, pixel / image.width, pixel % image.width, first_rx, scan.pt, max, count,
    }) catch buf[0..0];
    s.emit(.fail, .jpegls_point_transform_overflow, scan.al_at, detail) catch return error.OutOfMemory;
}

/// The Tmi that applies to image channel `channel`: an ILV 0 plane is the
/// scan's one component; otherwise channels follow frame component order.
fn channelTmi(scan: *const ScanInfo, channels: usize, channel: usize) u8 {
    if (channels == 1) return scan.tmi[0];
    for (0..scan.num_components) |i| if (scan.comp_indices[i] == channel) return scan.tmi[i];
    return 0;
}

/// T.87 C.2.4.1.2-3: parse an LSE ID 2 (table specification) or ID 3
/// (continuation). Segment-local violations are FAIL 126 whether or not a
/// scan uses the table (validate ruling 2026-11-22).
fn parseMapping(
    allocator: Allocator,
    data: []const u8,
    pos: usize,
    tables: *[256]?MappingTable,
    tail: *?MappingTail,
    sink: ?*findings_mod.FindingsSink,
) Error!void {
    const seg_len = parseSegmentLength(data, pos);
    if (pos + seg_len > data.len) return error.TruncatedStream;
    const marker_at = pos - 2;
    if (seg_len < 5) return mappingFault(sink, pos, "length: Ll < 5 leaves no TID, Wt and entries (T.87 Table C.4)");
    const id = data[pos + 2];
    const tid = data[pos + 3];
    const wt = data[pos + 4];
    if (tid == 0) return mappingFault(sink, pos + 3, "tid_range: TID 0 (T.87 Table C.4: 1 to 255)");
    if (wt == 0) return mappingFault(sink, pos + 4, "wt_range: Wt 0 (T.87 Table C.4: 1 to 255)");
    const body = data[pos + 5 .. pos + seg_len];
    if (body.len == 0 or body.len % wt != 0) {
        var buf: [96]u8 = undefined;
        const detail = std.fmt.bufPrint(&buf, "length: Ll {d} is not 5 + Wt {d} * (entries) (T.87 Table C.4)", .{ seg_len, wt }) catch buf[0..0];
        return mappingFault(sink, pos, detail);
    }
    if (id == 3) {
        // C.2.4.1.3: a continuation follows an ID 2 or ID 3 segment with
        // the same TID and Wt; only FF fill may come between.
        const prev = tail.* orelse return mappingFault(sink, marker_at, "continuation: LSE ID 3 without a preceding mapping table segment (T.87 C.2.4.1.3)");
        const adjacent = prev.end <= marker_at and for (data[prev.end..marker_at]) |byte| {
            if (byte != 0xFF) break false;
        } else true;
        if (!adjacent or prev.tid != tid or prev.wt != wt)
            return mappingFault(sink, marker_at, "continuation: LSE ID 3 does not follow a mapping table segment with the same TID and Wt (T.87 C.2.4.1.3)");
        try tables[tid].?.bytes.appendSlice(allocator, body);
    } else {
        // C.2.4.1: a later specification for a TID replaces the earlier one.
        if (tables[tid]) |*old| old.bytes.deinit(allocator);
        tables[tid] = .{ .lse_at = marker_at, .wt = wt, .bytes = .empty };
        try tables[tid].?.bytes.appendSlice(allocator, body);
    }
    tail.* = .{ .tid = tid, .wt = wt, .end = pos + seg_len };
}

fn mappingFault(sink: ?*findings_mod.FindingsSink, offset: usize, detail: []const u8) Error {
    if (sink) |s| s.emitExact(.fail, .jpegls_mapping_table_invalid, @intCast(offset), detail) catch return error.OutOfMemory;
    return error.BackendError;
}

/// T.87 C.2.3 at a scan that selects mapping tables: Tmi with a nonzero
/// Pt is WARN 125; a Tmi naming no table is FAIL 124; a table whose entry
/// count is not MAXVAL + 1 for the MAXVAL in force is FAIL 126 `entries`
/// at its LSE marker (validate rulings 2026-11-22).
fn checkMapping(scan: *const ScanInfo, tables: *const [256]?MappingTable, preset: PresetParams, P: u8, sink: ?*findings_mod.FindingsSink) Error!void {
    const maxval: u32 = if (preset.MAXVAL != 0) preset.MAXVAL else (@as(u32, 1) << @intCast(P)) - 1;
    var buf: [128]u8 = undefined;
    for (0..scan.num_components) |i| {
        const tmi = scan.tmi[i];
        if (tmi == 0) continue;
        if (scan.pt != 0) if (sink) |s| {
            const detail = std.fmt.bufPrint(&buf, "Tmi {d} with point transform Pt {d}; all Tmi shall be 0 (T.87 C.2.3)", .{ tmi, scan.pt }) catch buf[0..0];
            s.emitExact(.warn, .jpegls_mapping_with_point_transform, @intCast(scan.tmi_at[i]), detail) catch return error.OutOfMemory;
        };
        const table = tables[tmi] orelse {
            if (sink) |s| {
                const detail = std.fmt.bufPrint(&buf, "TID {d} for scan component {d} is not specified (T.87 C.2.3)", .{ tmi, i }) catch buf[0..0];
                s.emitExact(.fail, .jpegls_mapping_table_undefined, @intCast(scan.tmi_at[i]), detail) catch return error.OutOfMemory;
            }
            return error.BackendError;
        };
        const entries = table.bytes.items.len / table.wt;
        if (entries != maxval + 1) {
            if (sink) |s| {
                const detail = std.fmt.bufPrint(&buf, "entries: TID {d} has {d} entries, not MAXVAL + 1 = {d}, at the scan at offset {d} (T.87 C.2.4.1.2)", .{ tmi, entries, maxval + 1, scan.tmi_at[i] }) catch buf[0..0];
                s.emitExact(.fail, .jpegls_mapping_table_invalid, @intCast(table.lse_at), detail) catch return error.OutOfMemory;
            }
            return error.BackendError;
        }
    }
}

/// T.87 clause 7: map each decoded sample through its component's table.
/// T.87 defines no interpretation for entries wider than one byte, so
/// those return NotImplemented here; validation never maps.
fn applyMapping(image: *types.Image, scan: *const ScanInfo, tables: *const [256]?MappingTable) Error!void {
    if (!scan.mapping_table) return;
    const channels: usize = image.channels;
    const wide = image.bits_per_sample > 8;
    for (0..channels) |ch| {
        const tmi = channelTmi(scan, channels, ch);
        if (tmi == 0) continue;
        const table = tables[tmi].?;
        if (table.wt != 1) return error.NotImplemented;
        var i = ch;
        while (i < @as(usize, image.width) * image.height * channels) : (i += channels) {
            if (wide) {
                const rx = std.mem.readInt(u16, image.pixels[2 * i ..][0..2], native_endian);
                std.mem.writeInt(u16, image.pixels[2 * i ..][0..2], table.bytes.items[rx], native_endian);
            } else {
                const rx: usize = image.pixels[i];
                image.pixels[i] = table.bytes.items[rx];
            }
        }
    }
}

fn emitDerivation(sink: ?*findings_mod.FindingsSink, lse_at: ?usize, detail: []const u8) Error!void {
    const s = sink orelse return;
    if (lse_at) |at|
        s.emitExact(.info, .jpegls_maxval_derivation, @intCast(at), detail) catch return error.OutOfMemory
    else
        s.emit(.info, .jpegls_maxval_derivation, null, detail) catch return error.OutOfMemory;
}

fn initScanState(state: *codec.ScanState, P: u8, near: u32, preset: PresetParams, derivation: Derivation) void {
    const bit_max: u32 = (@as(u32, 1) << @intCast(P)) - 1;
    const maxval: u32 = if (preset.MAXVAL != 0) preset.MAXVAL else bit_max;
    state.resetMaxval(if (derivation == .spec) maxval else bit_max, near);
    if (state.MAXVAL != maxval) {
        // CharLS derivation: the default thresholds still follow the LSE
        // MAXVAL; only RANGE, qbpp, bpp, LIMIT and the clamp use 2^P - 1.
        state.MAXVAL = maxval;
        state.setDefaultThresholds();
        state.MAXVAL = bit_max;
    }
    if (preset.T1 != 0) state.T1 = preset.T1;
    if (preset.T2 != 0) state.T2 = preset.T2;
    if (preset.T3 != 0) state.T3 = preset.T3;
    if (preset.RESET != 0) state.RESET = preset.RESET;
}

/// An LSE ID 1 MAXVAL other than 2^P - 1: T.87 A.2.1 then derives
/// RANGE, qbpp, bpp and LIMIT from it, which CharLS 3.0 does not.
fn customMaxval(preset: PresetParams, P: u8) bool {
    return preset.MAXVAL != 0 and preset.MAXVAL != (@as(u32, 1) << @intCast(P)) - 1;
}

/// Image dimensions from an LSE ID 4 (T.87 C.2.4.1.4); 0 leaves the SOF
/// value in place.
pub const Oversize = struct { height: u32, width: u32 };

/// Parse an LSE ID 4 at `pos` (its length field): Wxy in 2..4, then Ye
/// and Xe in Wxy bytes each.
fn parseOversize(data: []const u8, pos: usize) Error!Oversize {
    const seg_len = parseSegmentLength(data, pos);
    if (seg_len < 4 or pos + seg_len > data.len) return error.TruncatedStream;
    const wxy: usize = data[pos + 3];
    if (wxy < 2 or wxy > 4 or seg_len != 4 + 2 * wxy) return error.InvalidMarker;
    var ye: u32 = 0;
    var xe: u32 = 0;
    for (data[pos + 4 .. pos + 4 + wxy]) |byte| ye = (ye << 8) | byte;
    for (data[pos + 4 + wxy .. pos + 4 + 2 * wxy]) |byte| xe = (xe << 8) | byte;
    return .{ .height = ye, .width = xe };
}

/// The last well-formed LSE ID 4 before the first scan, for a marker walk
/// that needs the frame size without decoding (the validator).
pub fn oversizeDimensions(data: []const u8) ?Oversize {
    var pos: usize = 2;
    var found: ?Oversize = null;
    while (pos + 3 < data.len) {
        if (data[pos] != 0xFF or data[pos + 1] == 0xFF) {
            pos += 1;
            continue;
        }
        const marker = data[pos + 1];
        if (marker == M_SOS or marker == M_EOI) break;
        if (marker == 0x01 or (marker >= 0xD0 and marker <= 0xD8)) {
            pos += 2;
            continue;
        }
        const len = parseSegmentLength(data, pos + 2);
        if (len < 2) break;
        if (marker == M_LSE and len >= 3 and pos + 4 < data.len and data[pos + 4] == 4) {
            found = parseOversize(data, pos + 2) catch null;
        }
        pos += 2 + len;
    }
    return found;
}

fn parseLse(data: []const u8, pos: usize, out: *PresetParams) Error!void {
    const seg_len = parseSegmentLength(data, pos);
    if (seg_len < 3 or pos + seg_len > data.len) return error.TruncatedStream;
    const id = data[pos + 2];
    if (id != 1) return; // mapping tables — silently skip
    if (seg_len < 13) return error.InvalidMarker;
    out.MAXVAL = (@as(u32, data[pos + 3]) << 8) | data[pos + 4];
    out.T1 = (@as(u32, data[pos + 5]) << 8) | data[pos + 6];
    out.T2 = (@as(u32, data[pos + 7]) << 8) | data[pos + 8];
    out.T3 = (@as(u32, data[pos + 9]) << 8) | data[pos + 10];
    out.RESET = (@as(u32, data[pos + 11]) << 8) | data[pos + 12];
}

/// SOS layout (T.87 §C.2.3):
///   FF DA [Ls:2] [Ns:1] { [Csi:1] [Tdi:1] }*Ns [NEAR:1] [ILV:1] [Al:Ah:1]
fn parseSos(data: []const u8, pos: usize, frame: *FrameInfo) Error!ScanInfo {
    const seg_len = parseSegmentLength(data, pos);
    if (seg_len < 6 or pos + seg_len > data.len) return error.TruncatedStream;
    var info: ScanInfo = undefined;
    info.restart_interval = 0;
    info.mapping_table = false;
    info.derivation = .spec;
    info.tmi = .{ 0, 0, 0, 0 };
    info.planes_out = null;
    info.tmi_at = .{ 0, 0, 0, 0 };
    info.num_components = data[pos + 2];
    if (info.num_components == 0 or info.num_components > 4) return error.InvalidMarker;
    var i: usize = 0;
    while (i < info.num_components) : (i += 1) {
        const off = pos + 3 + i * 2;
        const cs = data[off];
        // The second byte is Tmi, the mapping table selector (0 = none).
        info.tmi[i] = data[off + 1];
        info.tmi_at[i] = off + 1;
        if (data[off + 1] != 0) info.mapping_table = true;
        // Locate the matching frame component by ID.
        var found: bool = false;
        var j: usize = 0;
        while (j < frame.num_components) : (j += 1) {
            if (frame.components[j].id == cs) {
                info.comp_indices[i] = j;
                found = true;
                break;
            }
        }
        if (!found) return error.InvalidMarker;
    }
    const tail = pos + 3 + info.num_components * 2;
    if (tail + 2 >= pos + seg_len) return error.InvalidMarker;
    info.NEAR = data[tail];
    info.ILV = data[tail + 1];
    // Al is the point transform Pt (T.87 C.2.3); Ah is ignored.
    info.pt = @truncate(data[tail + 2]);
    info.al_at = tail + 2;
    return info;
}

// ── Inline tests ─────────────────────────────────────────────────

test "parseSof55: minimal grayscale 8-bit header" {
    // Construct a minimal SOF55 in-place: 0xFF 0xF7 0x00 0x0B (Lf=11)
    // P=8 Y=0x0004 X=0x0004 Nf=1 Ci=1 Hi:Vi=0x11 Tqi=0
    const data = [_]u8{
        0xFF, 0xF7, 0x00, 0x0B, // marker + length
        8, 0x00, 0x04, 0x00, 0x04, 1, // P, Y, X, Nf
        1, 0x11, 0, // C1, H:V, Tq
    };
    // parseSof55 expects pos pointing to the length byte (just after FFF7).
    const fi = try parseSof55(&data, 2);
    try std.testing.expectEqual(@as(u8, 8), fi.P);
    try std.testing.expectEqual(@as(u16, 4), fi.width);
    try std.testing.expectEqual(@as(u16, 4), fi.height);
    try std.testing.expectEqual(@as(u8, 1), fi.num_components);
    try std.testing.expectEqual(@as(u8, 1), fi.components[0].id);
    try std.testing.expectEqual(@as(u4, 1), fi.components[0].h_factor);
    try std.testing.expectEqual(@as(u4, 1), fi.components[0].v_factor);
}

test "parseLse: subtype 1 preset coding parameters" {
    // LSE: 0xFF 0xF8 [length=13] id=1 [MAXVAL] [T1] [T2] [T3] [RESET]
    const data = [_]u8{
        0xFF, 0xF8, 0x00, 0x0D, // marker + length=13
        1, // id = 1 (preset)
        0x00, 0xFF, // MAXVAL = 255
        0x00, 0x03, // T1 = 3
        0x00, 0x07, // T2 = 7
        0x00, 0x15, // T3 = 21
        0x00, 0x40, // RESET = 64
    };
    var preset: PresetParams = .{};
    try parseLse(&data, 2, &preset);
    try std.testing.expectEqual(@as(u32, 255), preset.MAXVAL);
    try std.testing.expectEqual(@as(u32, 3), preset.T1);
    try std.testing.expectEqual(@as(u32, 7), preset.T2);
    try std.testing.expectEqual(@as(u32, 21), preset.T3);
    try std.testing.expectEqual(@as(u32, 64), preset.RESET);
}

test "parseLse: ID 2 (mapping table specification) leaves the preset alone" {
    const data = [_]u8{
        0xFF, 0xF8, 0x00, 0x05, // marker + length=5
        2, // id = 2 (mapping table specification)
        0x42, 0x42, // arbitrary payload
    };
    var preset: PresetParams = .{};
    try parseLse(&data, 2, &preset);
    // No overrides applied.
    try std.testing.expectEqual(@as(u32, 0), preset.MAXVAL);
}

// (§1c stub test was here — superseded by the B2 fixture test in
// tests/unit/decode.zig now that §2 actually decodes the scan body.)

// ─────────────────────────────────────────────────────────────────
// Scan body — 1-component, 8 or 16-bit precision (Sessions 2 + 4).
// ─────────────────────────────────────────────────────────────────

/// Decode a 1-component JPEG-LS scan (8 or 16-bit precision).
/// Entropy-decodes every sample via regular or run mode and emits a
/// raster-order pixel buffer. T.87 §A; mirrors charls'
/// `jls_codec::do_line` / `do_run_mode` for the single-component path.
///
/// Output convention matches the rest of jpegz: P ≤ 8 → `[]u8`,
/// otherwise `[]u8` aliasing host-endian `[]u16` (caller reinterprets
/// via `image.pixelsU16()`).
fn decodeScanMono(
    allocator: Allocator,
    data: []const u8,
    frame: *const FrameInfo,
    scan: *const ScanInfo,
    preset: *const PresetParams,
    report: *ScanReport,
) ScanError!types.Image {
    const W: u32 = frame.width;
    const H: u32 = frame.height;
    const P: u8 = frame.P;
    const bytes_per_sample: usize = if (P <= 8) 1 else 2;

    var state: codec.ScanState = undefined;
    initScanState(&state, P, scan.NEAR, preset.*, scan.derivation);

    var br = bitstream.BitReader.init(data);
    defer report.capture(&br);
    const pixels = try allocator.alloc(u8, @as(usize, W) * @as(usize, H) * bytes_per_sample);
    errdefer allocator.free(pixels);

    // Two scan-lines buffered so we can access Rb/Rc/Rd from the
    // previous line. T.87 §A.1.2 boundary rule: samples outside the
    // image are 0; at start-of-line, Ra ← Rb.
    const cur_line = try allocator.alloc(i32, @as(usize, W) + 2);
    defer allocator.free(cur_line);
    const prev_line = try allocator.alloc(i32, @as(usize, W) + 2);
    defer allocator.free(prev_line);
    @memset(prev_line, 0);

    var rst_index: u3 = 0;
    var y: u32 = 0;
    while (y < H) : (y += 1) {
        if (restartDue(scan, y)) {
            try report.checkEnd(&br, .interval);
            try restartAt(&state, &br, P, scan, preset.*, &rst_index);
            @memset(prev_line, 0);
        }
        @memset(cur_line, 0);
        // T.87 §A.1.2: at start of line, Ra is set to the prior
        // line's value at column 0. We store at index 1 (index 0
        // is the left-of-image sentinel, kept 0).
        cur_line[0] = prev_line[1];

        var x: u32 = 0;
        while (x < W) {
            // Neighbors in our 1-indexed line buffer:
            //   Ra = cur_line[x]      (just-decoded; at x=0 = Rb)
            //   Rb = prev_line[x+1]
            //   Rc = prev_line[x]
            //   Rd = prev_line[x+2]   (replicates Rb at right edge)
            const ra: i32 = cur_line[x];
            const rb: i32 = prev_line[x + 1];
            const rc: i32 = prev_line[x];
            const rd: i32 = if (x + 1 < W) prev_line[x + 2] else rb;

            const t1: i32 = @intCast(state.T1);
            const t2: i32 = @intCast(state.T2);
            const t3: i32 = @intCast(state.T3);
            const near_i: i32 = @intCast(state.NEAR);
            const q1 = codec.quantize(rd - rb, t1, t2, t3, near_i);
            const q2 = codec.quantize(rb - rc, t1, t2, t3, near_i);
            const q3 = codec.quantize(rc - ra, t1, t2, t3, near_i);

            const ctx = codec.computeContextIndex(q1, q2, q3);
            if (ctx.q == 0) {
                const consumed = try decodeRun(&state, &br, 0, ra, cur_line, prev_line, x, W);
                x += consumed;
            } else {
                const c_correction: i32 = @as(i32, state.contexts[0][ctx.q].C);
                var px = codec.predictMed(ra, rb, rc);
                px += codec.applySign(c_correction, ctx.sign);
                if (px < 0) px = 0 else if (px > @as(i32, @intCast(state.MAXVAL))) px = @intCast(state.MAXVAL);

                const k = codec.computeK(
                    state.contexts[0][ctx.q].N,
                    state.contexts[0][ctx.q].A,
                );
                const merrval = try codec.decodeGolombRice(&br, k, state.LIMIT, state.qbpp);
                var errval = codec.mapMErrvalToErrval(merrval);
                // T.87 A.5.2: the k = 0 error correction applies only when NEAR = 0.
                if (k == 0 and state.NEAR == 0) {
                    const b = state.contexts[0][ctx.q].B;
                    const n_i: i32 = @intCast(state.contexts[0][ctx.q].N);
                    if (2 * b + n_i - 1 < 0) errval = ~errval;
                }
                codec.updateState(&state, 0, ctx.q, errval);
                const signed_err = codec.applySign(errval, ctx.sign);
                const sample = codec.computeReconstructed(px, signed_err, state.MAXVAL, state.NEAR, state.RANGE);
                cur_line[x + 1] = sample;
                x += 1;
            }
        }
        // Drain cur_line → pixels (run mode wrote to cur_line; finalize).
        var xc: u32 = 0;
        while (xc < W) : (xc += 1) {
            const sample: i32 = cur_line[xc + 1];
            const out_idx: usize = (@as(usize, y) * @as(usize, W) + @as(usize, xc)) * bytes_per_sample;
            if (P <= 8) {
                pixels[out_idx] = @intCast(sample);
            } else {
                // Host-endian u16 — same convention as the lossless /
                // SOF2 12-bit cleanroom paths (`pixelsU16()` aliases).
                const v: u16 = @intCast(sample);
                std.mem.writeInt(u16, pixels[out_idx..][0..2], v, native_endian);
            }
        }
        @memcpy(prev_line, cur_line);
    }

    try report.checkEnd(&br, .scan_end);
    return types.Image{
        .pixels = pixels,
        .width = W,
        .height = H,
        .channels = 1,
        .bits_per_sample = P,
        .source_color_space = .grayscale,
        .layout = .grayscale,
    };
}

/// Run mode for a single component's pixel strip. T.87 §A.7; mirrors
/// charls' `decode_run_pixels` + `decode_run_interruption_pixel`.
///
/// `ci` selects the per-component **run_index** only. The regular-mode
/// and run-interruption *contexts* (`contexts_[]`,
/// `context_run_mode_[0..1]`) are SHARED across components in
/// line-interleaved mode (charls `scan.h::decode_lines`: only
/// `run_index` is loaded/saved per component; `contexts_` and
/// `context_run_mode_` are scan-wide). ILV=0 (planar) and ILV=2
/// (sample-interleaved) also pass `ci = 0` here.
///
/// Returns the number of pixels consumed (run length + 1 if a run-
/// interruption sample followed; or just run length at EOL).
fn decodeRun(
    state: *codec.ScanState,
    br: *bitstream.BitReader,
    ci: usize,
    ra: i32,
    cur_line: []i32,
    prev_line: []const i32,
    start_x: u32,
    W: u32,
) ScanError!u32 {
    const pixel_count: u32 = W - start_x;
    var index: u32 = 0;
    // Run-length: emit 1 << J[run_index] pixels per 1-bit, cap at
    // pixel_count; bump run_index up to 31 each time we emit a full
    // step. Stop on a 0 bit OR when we reach end-of-line.
    while (br.readBits(1) == 1) {
        const step: u32 = @as(u32, 1) << @intCast(codec.J_TABLE[state.run_index[ci]]);
        const count: u32 = @min(step, pixel_count - index);
        index += count;
        if (count == step and state.run_index[ci] < 31) state.run_index[ci] += 1;
        if (index == pixel_count) break;
    }
    if (index != pixel_count) {
        // Incomplete run — read residual bits.
        const j = codec.J_TABLE[state.run_index[ci]];
        if (j > 0) {
            const residual: u32 = br.readBits(@intCast(j));
            index += residual;
        }
    }
    if (index > pixel_count) return error.RunModeInvalid;

    // Fill run with Ra.
    var i: u32 = 0;
    while (i < index) : (i += 1) {
        cur_line[start_x + 1 + i] = ra;
    }

    if (start_x + index == W) return index; // EOL — no interruption

    // Run interruption sample at (start_x + index). T.87 §A.7.4 /
    // charls `decode_run_interruption_pixel`:
    //   - |Ra - Rb| <= NEAR → RItype 1 (flat region), predict from Ra.
    //   - otherwise         → RItype 0 (edge), predict from Rb with
    //                          sign(Rb - Ra) applied to the error.
    const rb_v: i32 = prev_line[start_x + index + 1];
    const ri_type: u8 = if (@abs(ra - rb_v) <= @as(i32, @intCast(state.NEAR))) 1 else 0;
    // Run-interruption context is shared across components (see fn doc).
    const rc = &state.run_contexts[0][ri_type];
    const k = codec.runModeGetK(rc, ri_type);
    const e_mapped = try codec.decodeGolombRice(
        br, k,
        @as(u8, @intCast(@as(i32, state.LIMIT) - codec.J_TABLE[state.run_index[ci]] - 1)),
        state.qbpp,
    );
    const errval = codec.runModeComputeError(rc, e_mapped, k, ri_type);
    codec.runModeUpdate(rc, errval, e_mapped, ri_type, state.RESET);

    const sample: i32 = if (ri_type == 0) blk: {
        // Edge case: predict from Rb, sign-flip error by sign(Rb - Ra).
        const s: i32 = if (rb_v > ra) 1 else if (rb_v < ra) -1 else 0;
        break :blk codec.computeReconstructed(rb_v, errval * s, state.MAXVAL, state.NEAR, state.RANGE);
    } else codec.computeReconstructed(ra, errval, state.MAXVAL, state.NEAR, state.RANGE);
    cur_line[start_x + index + 1] = sample;

    if (state.run_index[ci] > 0) state.run_index[ci] -= 1;
    return index + 1;
}

// ─────────────────────────────────────────────────────────────────
// Scan body — N-component line-interleaved (ILV=1), 8 or 16-bit.
// ─────────────────────────────────────────────────────────────────

/// Decode `W` pixels of one component's strip into `cur_line` (which
/// is `(W+2)`-wide, with index 0 reserved for the left sentinel and
/// indices 1..W holding the actual decoded samples). Uses the
/// per-component context state in `state.contexts[ci]` /
/// `state.run_index[ci]` / `state.run_contexts[ci]`.
///
/// This is the shared inner loop of `decodeScanMono` (ci = 0) and
/// `decodeScanLine` (ci = scan-component index, ILV=1). Algorithm
/// per T.87 §A.4–A.7; mirrors charls' `do_line<sample_type>`.
fn decodeLineForComponent(
    state: *codec.ScanState,
    br: *bitstream.BitReader,
    ci: usize,
    cur_line: []i32,
    prev_line: []const i32,
    W: u32,
) ScanError!void {
    // T.87 §A.1.2: at start of line, Ra ← Rb. Store at index 1 (index
    // 0 is the left-of-image sentinel, kept 0).
    cur_line[0] = prev_line[1];

    var x: u32 = 0;
    while (x < W) {
        const ra: i32 = cur_line[x];
        const rb: i32 = prev_line[x + 1];
        const rc: i32 = prev_line[x];
        const rd: i32 = if (x + 1 < W) prev_line[x + 2] else rb;

        const t1: i32 = @intCast(state.T1);
        const t2: i32 = @intCast(state.T2);
        const t3: i32 = @intCast(state.T3);
        const near_i: i32 = @intCast(state.NEAR);
        const q1 = codec.quantize(rd - rb, t1, t2, t3, near_i);
        const q2 = codec.quantize(rb - rc, t1, t2, t3, near_i);
        const q3 = codec.quantize(rc - ra, t1, t2, t3, near_i);
        const ctx = codec.computeContextIndex(q1, q2, q3);

        if (ctx.q == 0) {
            const consumed = try decodeRun(state, br, ci, ra, cur_line, prev_line, x, W);
            x += consumed;
        } else {
            // Regular-mode contexts are shared across components in
            // ILV=1 — only `run_index` is per-component (per charls
            // reference impl). Index `[0]` is the single canonical
            // table; `ci` is intentionally not used here.
            const c_correction: i32 = @as(i32, state.contexts[0][ctx.q].C);
            var px = codec.predictMed(ra, rb, rc);
            px += codec.applySign(c_correction, ctx.sign);
            if (px < 0) px = 0 else if (px > @as(i32, @intCast(state.MAXVAL))) px = @intCast(state.MAXVAL);

            const k = codec.computeK(
                state.contexts[0][ctx.q].N,
                state.contexts[0][ctx.q].A,
            );
            const merrval = try codec.decodeGolombRice(br, k, state.LIMIT, state.qbpp);
            var errval = codec.mapMErrvalToErrval(merrval);
            // T.87 A.5.2: the k = 0 error correction applies only when NEAR = 0.
            if (k == 0 and state.NEAR == 0) {
                const b = state.contexts[0][ctx.q].B;
                const n_i: i32 = @intCast(state.contexts[0][ctx.q].N);
                if (2 * b + n_i - 1 < 0) errval = ~errval;
            }
            codec.updateState(state, 0, ctx.q, errval);
            const signed_err = codec.applySign(errval, ctx.sign);
            const sample = codec.computeReconstructed(px, signed_err, state.MAXVAL, state.NEAR, state.RANGE);
            cur_line[x + 1] = sample;
            x += 1;
        }
    }
}

/// Decode a multi-component line-interleaved (ILV=1) JPEG-LS scan,
/// 8 or 16-bit precision. T.87 §A.2 line-interleaved decode: per scan
/// line, run a separate single-component pass for each component in
/// scan order, each using its own context state
/// (`state.contexts[c]`, `state.run_index[c]`, `state.run_contexts[c]`).
/// Output is pixel-interleaved in raster order to match the
/// `decodeScanRgb` (ILV=2) and library convention.
///
/// `scan.num_components` must be ≥ 2; ILV=1 with 1 component
/// degenerates to ILV=0 by the standard, and the dispatcher routes
/// that through `decodeScanMono`.
fn decodeScanLine(
    allocator: Allocator,
    data: []const u8,
    frame: *const FrameInfo,
    scan: *const ScanInfo,
    preset: *const PresetParams,
    report: *ScanReport,
) ScanError!types.Image {
    const P: u8 = frame.P;
    const nc: usize = scan.num_components;
    const bps: usize = if (P <= 8) 1 else 2;

    var state: codec.ScanState = undefined;
    initScanState(&state, P, scan.NEAR, preset.*, scan.derivation);

    var br = bitstream.BitReader.init(data);
    defer report.capture(&br);

    // T.87 B.2 and B.4: an MCU is V1 lines of the first scan component,
    // then V2 lines of the next, and so on, each component at its own plane
    // size (T.81 A.1.1). Lines past a plane's height only complete the last
    // MCU and are dropped.
    var dims: [4]PlaneDims = undefined;
    var vf: [4]u32 = undefined;
    for (0..nc) |c| {
        const fc = scan.comp_indices[c];
        dims[c] = planeDims(frame, fc);
        vf[c] = frame.components[fc].v_factor;
    }
    const mcu_rows: u32 = @intCast(std.math.divCeil(u64, frame.height, maxFactors(frame).v) catch unreachable);

    var planes: [4][]u8 = .{ &.{}, &.{}, &.{}, &.{} };
    var owned: usize = 0;
    defer for (planes[0..owned]) |plane| if (plane.len > 0) allocator.free(plane);
    var cur_lines: [4][]i32 = .{ &.{}, &.{}, &.{}, &.{} };
    var prev_lines: [4][]i32 = .{ &.{}, &.{}, &.{}, &.{} };
    defer {
        for (cur_lines) |buf| if (buf.len > 0) allocator.free(buf);
        for (prev_lines) |buf| if (buf.len > 0) allocator.free(buf);
    }
    for (0..nc) |c| {
        planes[c] = try allocator.alloc(u8, @as(usize, dims[c].w) * dims[c].h * bps);
        owned = c + 1;
        cur_lines[c] = try allocator.alloc(i32, @as(usize, dims[c].w) + 2);
        prev_lines[c] = try allocator.alloc(i32, @as(usize, dims[c].w) + 2);
        @memset(prev_lines[c], 0);
    }

    var rst_index: u3 = 0;
    var m: u32 = 0;
    while (m < mcu_rows) : (m += 1) {
        if (restartDue(scan, m)) {
            try report.checkEnd(&br, .interval);
            try restartAt(&state, &br, P, scan, preset.*, &rst_index);
            for (prev_lines[0..nc]) |line| @memset(line, 0);
        }
        for (0..nc) |c| {
            var v: u32 = 0;
            while (v < vf[c]) : (v += 1) {
                @memset(cur_lines[c], 0);
                try decodeLineForComponent(&state, &br, c, cur_lines[c], prev_lines[c], dims[c].w);
                const line = m * vf[c] + v;
                if (line < dims[c].h) {
                    const row = planes[c][@as(usize, line) * dims[c].w * bps ..][0 .. @as(usize, dims[c].w) * bps];
                    for (0..dims[c].w) |x| {
                        const sample = cur_lines[c][x + 1];
                        if (bps == 1) row[x] = @intCast(sample) else std.mem.writeInt(u16, row[2 * x ..][0..2], @intCast(sample), native_endian);
                    }
                }
                @memcpy(prev_lines[c], cur_lines[c]);
            }
        }
    }
    try report.checkEnd(&br, .scan_end);

    const equal = for (dims[0..nc]) |d| {
        if (d.w != frame.width or d.h != frame.height) break false;
    } else true;
    if (!equal) {
        // Unequal planes have no single raster; only `planes` callers get them.
        const out = scan.planes_out orelse return error.NotImplemented;
        for (0..nc) |c| {
            const fc = scan.comp_indices[c];
            out[fc] = .{
                .pixels = planes[c],
                .width = dims[c].w,
                .height = dims[c].h,
                .channels = 1,
                .bits_per_sample = P,
                .source_color_space = .grayscale,
                .layout = .grayscale,
            };
        }
        owned = 0;
        return emptyImage(allocator, P);
    }
    const samples: usize = @as(usize, frame.width) * frame.height;
    const pixels = try allocator.alloc(u8, samples * nc * bps);
    for (0..nc) |c| {
        for (0..samples) |i| @memcpy(pixels[(i * nc + c) * bps ..][0..bps], planes[c][i * bps ..][0..bps]);
    }
    return types.Image{
        .pixels = pixels,
        .width = frame.width,
        .height = frame.height,
        .channels = @intCast(nc),
        .bits_per_sample = P,
        .source_color_space = .rgb,
        .layout = .rgb,
    };
}

// ─────────────────────────────────────────────────────────────────
// Scan body — 3-component sample-interleaved, 8 or 16-bit precision.
// ─────────────────────────────────────────────────────────────────

/// Decode a 3-component sample-interleaved (ILV=2) JPEG-LS scan,
/// 8 or 16-bit precision. Mirrors charls' `do_line<triplet<sample_type>>`.
/// Contexts are SHARED across components in sample-interleaved mode
/// (T.87 §A.3.5 + charls' single `contexts_[]` array per codec
/// instance); the run-interruption sample always uses
/// `context_run_mode_[0]` (edge) for all three components — the run
/// only initiates over identical triplets, so its termination implies
/// an edge.
fn decodeScanRgb(
    allocator: Allocator,
    data: []const u8,
    frame: *const FrameInfo,
    scan: *const ScanInfo,
    preset: *const PresetParams,
    report: *ScanReport,
) ScanError!types.Image {
    const W: u32 = frame.width;
    const H: u32 = frame.height;
    const P: u8 = frame.P;
    const bytes_per_sample: usize = if (P <= 8) 1 else 2;

    var state: codec.ScanState = undefined;
    initScanState(&state, P, scan.NEAR, preset.*, scan.derivation);

    var br = bitstream.BitReader.init(data);
    defer report.capture(&br);
    const pixels = try allocator.alloc(u8, @as(usize, W) * @as(usize, H) * 3 * bytes_per_sample);
    errdefer allocator.free(pixels);

    // (W+2) triplets per line × 3 components = (W+2)*3 i32 entries.
    //   indices 0..2    = left sentinel (col -1)
    //   indices 3..5    = pixel x=0
    //   ...
    //   indices 3*W..3*W+2 = pixel x=W-1
    //   indices 3*(W+1)..3*(W+1)+2 = right sentinel (unused; Rd replicates Rb at x=W-1)
    const line_len: usize = (@as(usize, W) + 2) * 3;
    const cur_line = try allocator.alloc(i32, line_len);
    defer allocator.free(cur_line);
    const prev_line = try allocator.alloc(i32, line_len);
    defer allocator.free(prev_line);
    @memset(prev_line, 0);

    var rst_index: u3 = 0;
    var y: u32 = 0;
    while (y < H) : (y += 1) {
        if (restartDue(scan, y)) {
            try report.checkEnd(&br, .interval);
            try restartAt(&state, &br, P, scan, preset.*, &rst_index);
            @memset(prev_line, 0);
        }
        @memset(cur_line, 0);
        // T.87 §A.1.2: at start of line, Ra(comp) ← Rb(comp). The left
        // sentinel (col -1) of cur_line takes prev_line's col 0 values.
        cur_line[0] = prev_line[3];
        cur_line[1] = prev_line[4];
        cur_line[2] = prev_line[5];

        var x: u32 = 0;
        while (x < W) {
            // Gather per-component neighbors and quantized contexts.
            const t1_i: i32 = @intCast(state.T1);
            const t2_i: i32 = @intCast(state.T2);
            const t3_i: i32 = @intCast(state.T3);
            const near_i: i32 = @intCast(state.NEAR);

            var ra: [3]i32 = undefined;
            var rb: [3]i32 = undefined;
            var rc: [3]i32 = undefined;
            var rd: [3]i32 = undefined;
            var ctx: [3]codec.ContextLookup = undefined;
            var all_zero_q: bool = true;

            const cur_idx: usize = (@as(usize, x) + 1) * 3;
            const left_idx: usize = @as(usize, x) * 3;
            const right_idx: usize = (@as(usize, x) + 2) * 3;

            var ci: usize = 0;
            while (ci < 3) : (ci += 1) {
                ra[ci] = cur_line[left_idx + ci];
                rb[ci] = prev_line[cur_idx + ci];
                rc[ci] = prev_line[left_idx + ci];
                rd[ci] = if (x + 1 < W) prev_line[right_idx + ci] else rb[ci];
                const q1 = codec.quantize(rd[ci] - rb[ci], t1_i, t2_i, t3_i, near_i);
                const q2 = codec.quantize(rb[ci] - rc[ci], t1_i, t2_i, t3_i, near_i);
                const q3 = codec.quantize(rc[ci] - ra[ci], t1_i, t2_i, t3_i, near_i);
                ctx[ci] = codec.computeContextIndex(q1, q2, q3);
                if (ctx[ci].q != 0) all_zero_q = false;
            }

            if (all_zero_q) {
                const consumed = try decodeRunRgb(&state, &br, ra, cur_line, prev_line, x, W);
                x += consumed;
            } else {
                ci = 0;
                while (ci < 3) : (ci += 1) {
                    const cstate = &state.contexts[0][ctx[ci].q];
                    var px = codec.predictMed(ra[ci], rb[ci], rc[ci]);
                    px += codec.applySign(@as(i32, cstate.C), ctx[ci].sign);
                    if (px < 0) px = 0 else if (px > @as(i32, @intCast(state.MAXVAL))) px = @intCast(state.MAXVAL);

                    const k = codec.computeK(cstate.N, cstate.A);
                    const merrval = try codec.decodeGolombRice(&br, k, state.LIMIT, state.qbpp);
                    var errval = codec.mapMErrvalToErrval(merrval);
                    // T.87 A.5.2: the k = 0 error correction applies only when NEAR = 0.
                    if (k == 0 and state.NEAR == 0) {
                        const b = cstate.B;
                        const n_i: i32 = @intCast(cstate.N);
                        if (2 * b + n_i - 1 < 0) errval = ~errval;
                    }
                    codec.updateState(&state, 0, ctx[ci].q, errval);
                    const signed_err = codec.applySign(errval, ctx[ci].sign);
                    const sample = codec.computeReconstructed(px, signed_err, state.MAXVAL, state.NEAR, state.RANGE);
                    cur_line[cur_idx + ci] = sample;
                }
                x += 1;
            }
        }
        // Drain decoded line → RGB-interleaved raster pixels.
        var xc: u32 = 0;
        while (xc < W) : (xc += 1) {
            const cidx: usize = (@as(usize, xc) + 1) * 3;
            const oidx: usize = (@as(usize, y) * @as(usize, W) + @as(usize, xc)) * 3 * bytes_per_sample;
            if (P <= 8) {
                pixels[oidx]     = @intCast(cur_line[cidx]);
                pixels[oidx + 1] = @intCast(cur_line[cidx + 1]);
                pixels[oidx + 2] = @intCast(cur_line[cidx + 2]);
            } else {
                const v0: u16 = @intCast(cur_line[cidx]);
                const v1: u16 = @intCast(cur_line[cidx + 1]);
                const v2: u16 = @intCast(cur_line[cidx + 2]);
                std.mem.writeInt(u16, pixels[oidx..][0..2], v0, native_endian);
                std.mem.writeInt(u16, pixels[oidx + 2 ..][0..2], v1, native_endian);
                std.mem.writeInt(u16, pixels[oidx + 4 ..][0..2], v2, native_endian);
            }
        }
        @memcpy(prev_line, cur_line);
    }

    try report.checkEnd(&br, .scan_end);
    return types.Image{
        .pixels = pixels,
        .width = W,
        .height = H,
        .channels = 3,
        .bits_per_sample = P,
        .source_color_space = .rgb,
        .layout = .rgb,
    };
}

/// Triplet run mode. The run-length code itself is byte-identical to
/// the mono path (one J-table-indexed state); the interruption sample
/// decodes three errors via `context_run_mode_[0]` and reconstructs
/// each component via `Rb + Errval * sign(Rb - Ra)` per charls'
/// `decode_run_interruption_pixel(triplet)`.
fn decodeRunRgb(
    state: *codec.ScanState,
    br: *bitstream.BitReader,
    ra: [3]i32,
    cur_line: []i32,
    prev_line: []const i32,
    start_x: u32,
    W: u32,
) ScanError!u32 {
    const pixel_count: u32 = W - start_x;
    var index: u32 = 0;
    while (br.readBits(1) == 1) {
        const step: u32 = @as(u32, 1) << @intCast(codec.J_TABLE[state.run_index[0]]);
        const count: u32 = @min(step, pixel_count - index);
        index += count;
        if (count == step and state.run_index[0] < 31) state.run_index[0] += 1;
        if (index == pixel_count) break;
    }
    if (index != pixel_count) {
        const j = codec.J_TABLE[state.run_index[0]];
        if (j > 0) {
            const residual: u32 = br.readBits(@intCast(j));
            index += residual;
        }
    }
    if (index > pixel_count) return error.RunModeInvalid;

    // Fill run with Ra triplet.
    var i: u32 = 0;
    while (i < index) : (i += 1) {
        const cidx: usize = (@as(usize, start_x) + 1 + @as(usize, i)) * 3;
        cur_line[cidx]     = ra[0];
        cur_line[cidx + 1] = ra[1];
        cur_line[cidx + 2] = ra[2];
    }

    if (start_x + index == W) return index;

    // Run interruption sample. Per charls' triplet path, all three
    // components use context_run_mode_[0] (RItype = 0, edge case)
    // since the run was over identical triplets.
    const cur_idx: usize = (@as(usize, start_x) + @as(usize, index) + 1) * 3;
    const rb: [3]i32 = .{
        prev_line[cur_idx],
        prev_line[cur_idx + 1],
        prev_line[cur_idx + 2],
    };
    const rc = &state.run_contexts[0][0];
    var ci: usize = 0;
    while (ci < 3) : (ci += 1) {
        const k = codec.runModeGetK(rc, 0);
        const e_mapped = try codec.decodeGolombRice(
            br, k,
            @as(u8, @intCast(@as(i32, state.LIMIT) - codec.J_TABLE[state.run_index[0]] - 1)),
            state.qbpp,
        );
        const errval = codec.runModeComputeError(rc, e_mapped, k, 0);
        codec.runModeUpdate(rc, errval, e_mapped, 0, state.RESET);
        // charls' `sign(n) = (n >> 31) | 1` collapses to +1 / -1 (never 0)
        // unlike a standard signum. When `rb == ra` the encoder used +1
        // here, so the round-trip relies on the same convention.
        const sgn: i32 = if (rb[ci] - ra[ci] < 0) -1 else 1;
        const sample = codec.computeReconstructed(rb[ci], errval * sgn, state.MAXVAL, state.NEAR, state.RANGE);
        cur_line[cur_idx + ci] = sample;
    }

    if (state.run_index[0] > 0) state.run_index[0] -= 1;
    return index + 1;
}

// Force-import the codec module so its inline tests run if this is the
// test root (not necessary for the jpegls module's own tests; harmless).
comptime {
    _ = codec;
}


test "decodeRun: a run residual past the end of the line is RunModeInvalid (finding 120)" {
    // RUNindex 12 gives J = 3: a 0 bit ends the run, then 3 residual bits.
    // Residual 7 on a 4-sample line overruns it. Bits: 0 111 0000.
    var state: codec.ScanState = undefined;
    initScanState(&state, 8, 0, .{}, .spec);
    state.run_index[0] = 12;
    try std.testing.expectEqual(@as(u8, 3), codec.J_TABLE[12]);
    var br = bitstream.BitReader.init(&.{ 0x70, 0x00, 0x00, 0x00 });
    var cur = [_]i32{0} ** 6;
    const prev = [_]i32{0} ** 6;
    try std.testing.expectError(error.RunModeInvalid, decodeRun(&state, &br, 0, 0, &cur, &prev, 0, 4));
}

test "every ScanFault is recognized and maps to its finding code" {
    const want = .{
        .{ error.GolombCodeInvalid, errors.FindingCode.jpegls_golomb_code_invalid },
        .{ error.RunModeInvalid, errors.FindingCode.jpegls_invalid_run_mode },
        .{ error.RestartMissing, errors.FindingCode.restart_marker_missing },
        .{ error.RestartUnexpected, errors.FindingCode.restart_marker_unexpected },
    };
    try std.testing.expectEqual(@typeInfo(ScanFault).error_set.?.len, want.len);
    inline for (want) |pair| {
        const fault: ScanFault = pair[0];
        try std.testing.expectEqual(@as(?ScanFault, fault), asFault(fault));
        try std.testing.expectEqual(pair[1], faultFinding(fault).code);
    }
    try std.testing.expectEqual(@as(?ScanFault, null), asFault(error.TruncatedStream));
}

test "resetMaxval follows T.87 A.2.1 for the MAXVAL in force" {
    var state: codec.ScanState = undefined;
    // MAXVAL 127: bpp 7, RANGE 128, qbpp 7, LIMIT 2*(7+8) = 30.
    state.resetMaxval(127, 0);
    try std.testing.expectEqual(@as(u8, 7), state.bpp);
    try std.testing.expectEqual(@as(u32, 128), state.RANGE);
    try std.testing.expectEqual(@as(u8, 7), state.qbpp);
    try std.testing.expectEqual(@as(u8, 30), state.LIMIT);
    // MAXVAL 128 needs 8 bits: bpp = ceil(log2(MAXVAL + 1)).
    state.resetMaxval(128, 0);
    try std.testing.expectEqual(@as(u8, 8), state.bpp);
    // MAXVAL 2, NEAR 1: RANGE = (2 + 2) / 3 + 1 = 2, so qbpp = 1 (no floor
    // of 2); bpp keeps its floor of 2.
    state.resetMaxval(2, 1);
    try std.testing.expectEqual(@as(u32, 2), state.RANGE);
    try std.testing.expectEqual(@as(u8, 1), state.qbpp);
    try std.testing.expectEqual(@as(u8, 2), state.bpp);
}

test "initScanState: the CharLS derivation codes from 2^P - 1, thresholds from the LSE MAXVAL" {
    var spec: codec.ScanState = undefined;
    var charls: codec.ScanState = undefined;
    const preset: PresetParams = .{ .MAXVAL = 100 };
    initScanState(&spec, 8, 0, preset, .spec);
    initScanState(&charls, 8, 0, preset, .charls);
    try std.testing.expectEqual(@as(u32, 100), spec.MAXVAL);
    try std.testing.expectEqual(@as(u32, 101), spec.RANGE);
    try std.testing.expectEqual(@as(u32, 255), charls.MAXVAL);
    try std.testing.expectEqual(@as(u32, 256), charls.RANGE);
    try std.testing.expectEqual(@as(u8, 8), charls.qbpp);
    // C.2.4.1.1.1 for MAXVAL 100 < 128: FACTOR 256 / 101 = 2, so T1 =
    // max(2, 3/2) = 2, T2 = max(3, 7/2) = 3, T3 = max(4, 21/2) = 10.
    for ([_]*const codec.ScanState{ &spec, &charls }) |s| {
        try std.testing.expectEqual(@as(u32, 2), s.T1);
        try std.testing.expectEqual(@as(u32, 3), s.T2);
        try std.testing.expectEqual(@as(u32, 10), s.T3);
    }
}
