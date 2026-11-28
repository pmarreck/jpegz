const std = @import("std");
const jpegz = @import("jpegz");


// The tests live in these files; importing them here keeps this file the
// build's test root.
test {
    _ = @import("facade_validation_jp2_sof3.zig");
    _ = @import("facade_validation_jfif_classic.zig");
    _ = @import("facade_validation_jxl_mapping.zig");
    _ = @import("facade_validation_identity_decode.zig");
}
