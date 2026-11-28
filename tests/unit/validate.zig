//! M1.5 — `jpegz.validate` tests. Walks the bitstream, accumulates
//! Findings, returns a structured ValidationReport. Never fails-fast
//! on structural errors (per the design doc — validate-mode wants the
//! complete picture, not the first failure).

const std = @import("std");
const jpegz = @import("jpegz");


// The tests live in these files; importing them here keeps this file the
// build's test root.
test {
    _ = @import("validate_progressive_entropy.zig");
    _ = @import("validate_entropy_bounds.zig");
    _ = @import("validate_metadata_tables.zig");
    _ = @import("validate_headers_params.zig");
    _ = @import("validate_data_faults.zig");
    _ = @import("validate_walker_rules.zig");
    _ = @import("validate_jp2_totality.zig");
    _ = @import("validate_known_defects.zig");
    _ = @import("validate_dnl_hierarchy.zig");
    _ = @import("validate_oom.zig");
    _ = @import("validate_totality.zig");
    _ = @import("validate_lossless_range.zig");
    _ = @import("validate_idct_range.zig");
}
