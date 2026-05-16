//! charls wrapper stub — used when `-Dwith-charls=false`.
//!
//! charls is a C++ library. When cross-targeting Linux musl static
//! (the path Garnix uses for CI on x86_64-linux), the C++ stdlib
//! pkgsStatic.charls was built against (libstdc++) doesn't match
//! Zig's bundled libc++, producing a sea of undefined references at
//! link time. Until either (a) we rebuild charls against libc++ or
//! (b) the B2.2 cleanroom replaces charls as the JPEG-LS path,
//! Linux CI builds with `-Dwith-charls=false` and routes through
//! this stub.
//!
//! Surface mirrors `charls_wrapper_impl.zig`'s public API so the
//! dispatcher in `src/jpegz.zig` is unchanged: returns
//! `error.NotImplemented` so the dispatcher falls through to the
//! wrapper fallback (which itself returns `NotImplemented` for
//! JPEG-LS, surfacing as a clean error to the caller).

const std = @import("std");
const Allocator = std.mem.Allocator;
// See charls_wrapper_impl.zig comment — `jpegz` import wired in build.zig.
const jpegz_mod = @import("jpegz");
const errors = jpegz_mod;
const types = jpegz_mod;

pub fn decode(allocator: Allocator, data: []const u8) errors.DecodeError!types.Image {
    _ = allocator;
    _ = data;
    return error.NotImplemented;
}
