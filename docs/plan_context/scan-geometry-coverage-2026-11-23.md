# Scan geometry coverage (2026-11-23)

PLAN item: "Complete scan consumption, MCU counts, sampling edges,
noninterleaved scans, restart cadence and predictor-reset coverage across
supported modes." The table maps each check to its malformed-input tests,
in `tests/unit/` unless noted, and to its valid controls.

| Check | Malformed inputs (tests) | Valid controls |
|---|---|---|
| Scan consumption (surplus or missing entropy, padding) | sequential: "sequential entropy bounds classify legal endings and malformed runs", "whole bytes after valid padding ..."; progressive: "progressive boundaries account for EOB runs padding and refinement bits"; lossless: "lossless entropy boundaries classify complete samples and restart intervals"; arithmetic: "arithmetic restart and scan ends are typed ..." (both processes); JPEG-LS: "JPEG-LS interval and scan ends ..." | producer matrices (docs/measurements/producer-pixel-parity-2026-11-23.md) |
| MCU counts from dimensions and sampling | the same boundary tests (missing blocks are insufficient_data, surplus is FAIL 8 or 74); "multi-component sampling factors and interleaved MCU size are typed"; "SOF3 two-component sampling validates complete MCU groups ..." | 8 sizes x 6 samplings x every mode |
| Partial edge MCUs | progressive boundary cases at widths 17, 40 and 65; "JPEG-LS subsampled frame whose height needs a padded last MCU ..." | 1x1, 7x5, 17x9, 33x31 and 100x75 in every mode and sampling |
| Noninterleaved scans | "validate rejects multi-scan sequential frames that break component coverage"; "sequential scans after complete coverage fail before EOI only"; JPEG-LS ILV 0 tests | multi-scan sequential (`0; 1; 2;`) from both producers; all progressive AC scans; ILV 0 conformance streams |
| Restart cadence and marker order | 56/57 at the marker on every path: "Huffman insufficient_data and restart-boundary ...", "progressive restart findings ...", "lossless data faults ...", the arithmetic restart tests, "JPEG-LS restart faults ..."; lenient resync: "lenient ... resync follows libjpeg ..." | restart 1B, 3B and one row in every DCT mode; one row in lossless |
| Predictor reset at restarts | "lossless predictors reset for an entire restart row then resume below it"; "arithmetic restart intervals resume at each RSTn ..."; DC prediction: any missed reset breaks pixel parity of the restart matrices | as above, at pixel parity with libjpeg-turbo |

Gaps:
- No producer writes lossless arithmetic (SOF11); libjpeg-turbo refuses
  it. That mode rests on the hand-built tests alone.
- Hierarchical (SOF5 to SOF7, SOF13 to SOF15) is out of scope:
  unsupported and reported as such.
