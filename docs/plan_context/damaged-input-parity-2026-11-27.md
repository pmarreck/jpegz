# Damaged-input parity and scan skipping (2026-11-27)

## Pixel differences on damaged input

A sweep of seeded single-byte mutants compared jpegz.decode with
libjpeg-turbo (the build-time oracle). After the crash fixes in c86fe21,
91 files that jpegz validates as clean still decoded differently:

| Group | Files | Status |
|---|---|---|
| Lossless (SOF3) | 32 | Fixed in 7ceac1f: reconstruction is modulo 2^16 (T.81 H.1.2), as in libjpeg-turbo's UNDIFFERENCE. |
| Arithmetic sequential (SOF9), 8-bit | 29 | Open. Two kinds: SOF dimensions far larger than the data (the decoders diverge after the arithmetic data runs out), and large legal DQT entries (IDCT range, below). |
| Progressive Huffman (SOF2), 12-bit | 21 | Open. Entropy mutations that still decode; likely the IDCT range question below. |
| Arithmetic progressive (SOF10) | 4 | Open. |
| Baseline (SOF0) / extended (SOF1) | 3 | Open. |

Disabling libjpeg-turbo's SIMD (`JSIMD_FORCENONE=1`) changes only 2 of
the 59 remaining files, so SIMD is not the main cause.

## IDCT range: owner decision needed

A legal file (a quantizer of 244 times a legal coefficient of 1023) can
push the IDCT far outside the sample range. The candidates disagree:

- jpegz's 8-bit IDCT computes in i32 and wraps (an output of 6 where 255
  is expected). The arithmetic SOF9 path also drops the overflow flag
  that baseline reports as FAIL dct_coefficient_overflow, so these files
  validate as clean.
- libjpeg-turbo's C islow computes in `long` (64-bit on Linux and macOS,
  32-bit on Windows), truncates its workspace to `int`, and range-limits
  through a table indexed `& RANGE_MASK`, which wraps when values are far
  out of range. jpegz's 12-bit path follows that table since fa289eb.
- libjpeg-turbo's SIMD islow saturates its 16-bit intermediates.

Options put to the owner:
1. Exact 64-bit math plus a clamp to 0..2^P-1 (the spec's model; output
   is the same on every platform, and in-range output is unchanged).
2. Emulate libjpeg-turbo's C path as built on LP64 platforms.
3. Leave as is.

Owner ruling (2026-11-28): option 1. "We need to do the most correct
thing. We don't copy faulty oracle behavior." jpegz computes the IDCT
without wraparound and clamps the result. Where libjpeg-turbo wraps,
jpegz does not follow it.

## Skipping invalid scans during validation

Owner direction (2026-11-27): "If it is possible to record an error and
try to parse past it, I think we should. The more information about a
file, the better."

Today a walker FAIL on a scan header blocks the codec check, and the
decoders stop at such a scan, so faults later in the file go unreported.
The plan:

- The walker marks the FAILs it records for a progressive scan header as
  non-blocking and passes those scans' offsets to the codec check.
- In that recovery decode, the decoder skips the listed scans without
  judging them again.
- It also skips later AC refinement scans that refine coefficients a
  skipped scan sets, because their bit consumption depends on that
  history. Each is noted as INFO "not judged". DC refinement and first
  scans are decoded and judged.
- Plain decode keeps libjpeg-turbo's behavior: a bad scan header is an
  error.

Sequential, lossless and arithmetic sequential paths follow once the
progressive path is in.

## Re-measurement after the IDCT ruling (2026-11-28)

The earlier 15,425-file corpus did not survive a reboot. The new sweep
covers every fixture plus 5,000 seeded single-byte mutants (seed
4242). It compares jpegz.decode with libjpeg-turbo for the 1,815 files
jpegz validates as clean. libjpeg-turbo refuses 126 of them (JPEG-LS
and other variants it does not decode).

After 54d12d3 (exact IDCT plus clamp), 40 files differed:

| Cause | Files | Resolution |
|---|---|---|
| Exact IDCT leaves the sample range | 34 | Intended (owner ruling): jpegz clamps where libjpeg-turbo wraps. |
| AC refinement run past Se | 3 | Was undetected damage; now FAIL entropy_decode_invalid (3b06625). |
| Chroma two samples wide or narrower | 1 | jpegz used the fancy filter where libjpeg-turbo replicates (338ef0c). |
| Undefined Adobe ColorTransform byte | 2 | jpegz read it as "no transform"; libjpeg-turbo reads any nonzero byte as the encoder's transform (61710c8). |

Out-of-range classification is independent of jpegz's decode: it takes
libjpeg-turbo's own coefficients, dequantizes them with the file's DQT
and runs a double-precision T.81 IDCT. The 34 remaining differences are
exactly the files where some block leaves the range by more than
islow's fixed-point error.

Result: 1,652 of the 1,689 comparable files match libjpeg-turbo exactly,
and every remaining difference is intended.

The refinement fix moves 3 files out of the comparison: they are no
longer valid, and strict decode now fails on them.

## Scan skipping beyond progressive frames (analysis, 2026-11-28)

The progressive path shipped in eb03fb8 and 58822f1. For the others:

- Lossless validation (lossless_validate.zig) and the SOF9 arithmetic
  decoder each accept exactly one scan covering every component.
  Skipping that scan leaves nothing to decode, so they gain nothing.
- Only multi-scan (non-interleaved) sequential Huffman frames can gain.
  The baseline decoder hands the first scan to decodeScanT, which loops
  over the later ones, so both places need the skip. A skipped scan
  must count its components as coded, or the decoder would report "EOI
  before every component was scanned" as a consequence. When its
  components cannot be located (bad Ns, Cs or length), coverage is
  unknown and the coverage checks must stand down.
- Assumption (reversible): any FAIL on a sequential scan's header lists
  the scan, as on the progressive path. That includes
  sequential_scan_invalid (Ss, Se, Ah, Al), even though the baseline
  decoder ignores those fields. Decoding past them instead would turn a
  progressive file whose SOF2 byte was damaged into SOF0 into an
  avalanche of consequence faults. In the 5,000-mutant sweep, the 11
  files with only that FAIL have intact entropy, so they would gain
  nothing anyway.
