//! Root source file for the **validation-only static library**
//! (`libjpegz-validate.a`).
//!
//! Same job as `src/lib_root.zig`, but it force-links ONLY the validation half
//! of the C ABI (`ffi/c_api_validate.zig`). What it leaves out is the point:
//! nothing reachable from here touches `openjpeg_wrapper`, `libjpeg_wrapper`
//! or `charls_wrapper`, so the archive links no external JPEG-family decoder
//! and bundles no nested system `.a` members.
//!
//! Two consequences, both load-bearing:
//!
//!   1. It links. A Zig static library bundles the system static archives its
//!      module graph links, and LLD cannot use those nested members — it warns,
//!      and Zig escalates the warning to an error as soon as anything makes
//!      the linker scan that deep. Reaching the JPEG XL leg through the full
//!      ABI was enough to trigger exactly that.
//!   2. The `jpegz` CLI, which links this archive, inherits the same closure
//!      guarantee the Nix `validator-closure` check already enforces for
//!      `tools/facade_validator_probe.zig`.
//!
//! Consumers that need decode link `libjpegz.a` instead; it exports this
//! surface too, so the header is one header and the symbols do not diverge.
//!
//! Do not add anything else to this file.

comptime {
    _ = @import("jpegz").c_abi_validate_force_link;
}
