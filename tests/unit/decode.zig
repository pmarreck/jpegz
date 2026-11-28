//! M1.3 — baseline + progressive wrap (libjpeg-turbo).
//!
//! TDD-red marker: these tests fail today because `jpegz.decode` returns
//! `error.NotImplemented`. They go green when the libjpeg-turbo wrapper
//! lands in `src/ffi/libjpeg_wrapper.zig`.

const std = @import("std");
const jpegz = @import("jpegz");


// The tests live in these files; importing them here keeps this file the
// build's test root.
test {
    _ = @import("decode_basics.zig");
    _ = @import("decode_early_parity.zig");
    _ = @import("decode_jpegls_faults.zig");
    _ = @import("decode_jpegls_maxval.zig");
    _ = @import("decode_arith_12bit.zig");
    _ = @import("decode_lossless.zig");
    _ = @import("decode_lenient_findings.zig");
    _ = @import("decode_public_findings.zig");
    _ = @import("decode_public_options_misc.zig");
    _ = @import("decode_jpegls_dnl_mapping.zig");
}
