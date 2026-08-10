# JPEG-family strict validation facade evidence

Recorded 2026-08-05 EDT for the Mecha Validate v1 gate.

## Exact leaf pins

- `jp2z@d3754cfcfe3980daecb90de12d82ef4bdf100ce6`
- `libjxlz@5e8f9d68152ae8a70cb823061f4b6c733eb09166`

The facade calls only jp2z's public pure-Zig `deepValidate(..., true)` and
libjxlz's strict `validation.validate`. Every leaf finding keeps its source,
raw code, translated jpegz code when known, offsets, offset exactness, and
four-way verdict. Unknown future codes become indeterminate.

## Classifier evidence

`zig build test-facade -Doptimize=ReleaseSafe` passes seven suites:

- every libjxlz result code 0 through 8, plus an unknown future code;
- every public jp2z finding code, plus an unknown future code;
- labeled JXL valid, unsupported, and indeterminate controls;
- known-good JP2;
- JPEG XL sniper, bolter, and shotgun signature mutations, 3/3 corrupt;
- JPEG 2000 sniper, bolter, and shotgun signature mutations, 3/3 corrupt;
- exact libjxlz source identity and host-relative offset preservation.

The mutation labels describe independent damage strengths. Each case is
asserted separately, so one strong mutation cannot hide a weak mutation miss.

## Production closure proof

`checks.x86_64-linux.validator-closure` builds and runs a production-shaped
musl ELF that invokes both validators. It then checks undefined symbols,
dynamic entries, and the complete Nix runtime closure. The gate rejects
OpenJPEG, libjpeg, CharLS, upstream libjxl/djxl, and their characteristic
symbols. Brotli is allowed because libjxlz uses it as generic compression for
JPEG XL container metadata.

The proof ELF is fully static on x86_64 Linux. The ordinary jpegz decode target
still uses its documented OpenJPEG path; the closure claim applies only to the
selected strict validation target.

## Family-wide routing and the archive split (2026-08-10)

`jpegz.sniff` / `jpegz.validateAny` route the whole family from one call, and
`jpegz_validate_any` exposes it to C. Twelve facade suites now pass: the seven
above plus family-wide sniffing as a labeled classifier (6 family members and 8
foreign or degenerate inputs), the JP2-vs-JXL signature-box separation, routing
per format, unrecognized input staying indeterminate, and a destroyed JP2
signature no longer being diagnosed in T.81 vocabulary.

Exposing the facade through the C ABI forced an archive split. A Zig static
library bundles the system static archives its module graph links; LLD cannot
use those nested members and only warns, which Zig escalates to a hard error as
soon as anything makes the linker scan that deep. Reaching the JPEG XL leg was
enough. jpegz therefore ships `libjpegz-validate.a` (validation only, Brotli as
its sole C dependency) alongside the full `libjpegz.a`.

The `jpegz` CLI links the validation archive, so it now carries the same
closure guarantee as the proof ELF. Measured on the native binary: `opj_` 0,
`jpeg_` 0, `charls` 0, `djxl` 0; dynamic dependencies are Brotli, libc, and
libm only. Its 68 `JxlDecoder*` symbols are libjxlz's own pure-Zig code, and
its `decode.jpegls.*` symbols are jpegz's own cleanroom T.87 walker.

`tests/cli/smoke.c` links the FULL archive, exercising both ABI halves against
one library — the gate that would catch the two archives' symbol sets
diverging. It also pins both strict struct layouts with `static_assert`, since
each struct is declared twice (Zig `extern struct` and C) with nothing
otherwise comparing them; a field added on one side only would be silent memory
corruption rather than a compile error.
