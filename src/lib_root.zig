//! Root source file for the **static library artifact only** (`libjpegz.a`).
//!
//! Its sole job is to force-link the C ABI's `export fn`s so they survive
//! dead-code elimination and land in the archive that `include/jpegz_core.h`
//! declares.
//!
//! Why this file exists as a separate root: that force-link used to be a
//! top-level `comptime` block inside `src/jpegz.zig`, i.e. inside the
//! *importable module root*. Because a `comptime` block is analyzed
//! unconditionally, every Zig consumer of the `jpegz` module — even one that
//! only calls `validate()` — was dragged through the exported
//! `jpegz_jp2_decode` → `jpeg2000.decodeWithOptions` →
//! `openjpeg_wrapper.decode` → `@cImport(<openjpeg.h>)` chain and could not
//! compile without openjpeg headers in scope.
//!
//! Keeping the force-link here, in a root that ONLY the library artifact uses,
//! means the C ABI stays fully exported for C consumers while Zig consumers
//! pay only for the paths they actually call.
//!
//! Do not add anything else to this file, and do not import it from library
//! code — `src/jpegz.zig` remains the public module root.

comptime {
    _ = @import("jpegz").c_abi_force_link;
    // The validation exports live in their own file so that a second archive
    // can ship them WITHOUT libjpeg / openjpeg / CharLS (see
    // `src/validation_lib_root.zig` and `src/ffi/c_common.zig`). The full
    // library must still export both halves, so force-link both here.
    _ = @import("jpegz").c_abi_validate_force_link;
}
