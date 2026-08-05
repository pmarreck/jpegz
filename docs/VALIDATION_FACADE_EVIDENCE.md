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
