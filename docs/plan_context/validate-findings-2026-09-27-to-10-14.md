# Validate findings queue, 2026-09-27 to 2026-10-14

Durable record of Validate's JPEG work orders and false-positive reports from
that period, kept here so the inbox envelopes can be retired. The
original files stay private to Validate; only synthetic shapes are recorded.

Verdict policy for all of these: a proven violation of a normative clause is a
FAIL, and reader tolerance never lowers it. Validate's KNOWN_DEFECT registry
decides admission by finding code, so jpegz emits a typed finding with an exact
offset and its own severity, and does not add KNOWN_DEFECT to its ABI. Authority
is Validate's TERMINOLOGY.md and the shared memory "Validate verdicts - FAIL is
unexplained damage, KNOWN_DEFECT is an admitted producer defect, WARN is no
proven violation, limits are reach".

## Distinct finding labels (2026-10-10)

Resolved for sequential Huffman DCT on 2026-10-20: 57 for a restart after the
final MCU, 3 for EOI at an interval boundary, 62 `entropy_padding_not_ones`
(registry-approved 2026-10-20) and 55 for split-scan coverage violations, each
at an exact absolute offset. The 296-byte repro below reports 62 at 293.

`src/core/validator.zig` maps InvalidMarker, BackendError and TruncatedStream to
`huffman_table_corrupt`. So three different faults all reach users as "JPEG
corrupt Huffman table" even when the tables are fine:

- **Restart marker after the final MCU** (T.81 B.2.1: "a restart marker shall
  follow each entropy-coded segment except the last one"; E.1.3, Figure E.3).
  `baseline.zig` already raises `rst_after_final_mcu`, and
  `tests/unit/validate.zig` covers the shape. Requested code
  `restart_marker_unexpected`, FAIL, with the marker offset. Minimal shapes:
  8x8 gray, DRI=1. Entropy `0f ff d0` + EOI is malformed; `0f` + EOI is legal.
  Corpus witness: `validate_gui/ground_truth_examples/audit_20260715/jpeg_missing_eoi_reader_accepted.jpg`
  (shared, not private). It has 4:2:0, DRI=1 and 19,764 MCUs but 19,764 RSTs.
  The extra FF D3 is at byte 1432198 and EOI is at 1432200. Removing those two
  bytes makes it pass.
- **Truncation at an interval boundary**: a separate truncation code.
- **Non-1 entropy padding** (T.81 F.1.2.3): see below.

New numeric codes go through the append-only registry coordinator.

## Zero-bit entropy padding (2026-09-30, corrected 2026-09-30 and 2026-10-10)

Severity stays FAIL. Validate withdrew its WARN proposal. It wants its own code
(for example `entropy_padding_not_ones`) with the exact byte offset, instead of
`huffman_table_corrupt` with a null offset. Keep the existing FAIL for 8 or more
leftover bits (`bitstream.zig` `finishHuffmanSegment`), and apply the same check
on the RST path.

The encoder is "Intel(R) JPEG Library, version [1.51.12.44]". Validate's census
found three presumed-valid originals (one JPEG and two PDFs with DCT images, one
of them with 72 restart segments) whose only defect was fewer than 8 zero pad
bits. Setting those bits to 1 makes each pass with identical pixels.

Synthetic repro: the 296-byte ImageMagick JPEG
`magick -size 16x16 gradient:red-blue -sampling-factor 2x2 -quality 50 -strip`,
with the last entropy byte (offset 293, just before FFD9) changed from 0x4F to
0x40:

```
ffd8ffe000104a46494600010100000100010000ffdb004300100b0c0e0c0a100e0d0e1211101318281a181616183123251d283a333d3c3933383740485c4e404457453738506d51575f626768673e4d71797064785c656763ffdb0043011112121815182f1a1a2f634238426363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363ffc00011080010001003012200021101031101ffc400160001010100000000000000000000000000000405ffc4001510010100000000000000000000000000000013ffc40014010100000000000000000000000000000005ffc400161100030000000000000000000000000000001561ffda000c03010002110311003f00c0a954552a5144196940ffd9
```

Fixture plan: an 8x8 baseline gray JPEG with its last k pad bits cleared, for
k = 1..7, plus the same with DRI and zero-padded RST segments. Malformed
counterparts are an extra 0x55 byte before EOI and a dropped final entropy byte.

## Valid non-interleaved sequential JPEG falsely rejected (2026-10-10)

Fixed in fa75e3c (2026-10-20): the fixture below and three more split-scan
shapes decode byte for byte like libjpeg-turbo.

The input is a 16x16 RGB PPM with pixel (x, y) = ((x*16)%256, (y*16)%256,
((x+y)*8)%256). It is encoded with libjpeg-turbo 3.1.4.1 `cjpeg -scans seq.scans`,
where seq.scans holds `0;`, `1;` and `2;` on separate lines. That gives three
single-component sequential scans (T.81 B.2.3 allows Ns = 1). Result sha256 is
`a8f9d58addafc715e3b0c85c04a42b2ca0154c4c7b1f0aa6f1e78532ac89b4d6`. Validate's
generator is `scripts/generate-jpeg-eoi-fixtures`
(`src/core/fixtures/jpeg/eoi_sequential_3scan_16x16.jpg`).

jpegz says "corrupt Huffman table", while djpeg decodes the file cleanly. The
file conforms, so this is a genuine false FAIL. Validate's hypothesis is table
selection or reset between single-component scans, or MCU = 1 data-unit
geometry. Asked for: a red legal-input test, a malformed counterpart (for
example a scan selecting an undefined table) and a fix.

## SOF1 with component ids 0/1/2 and table pairs 0/1/2 (2026-09-30 item 4)

A 3-component SOF1 with component ids 0/1/2, each using its own DC/AC pair 0, 1
or 2, all defined in one 626-byte DHT. Kraft sums are 0.996-0.99997 and the max
symbol is 0xFA. `djpeg -strict` decodes all three private streams. Accept table
ids 0-3 and any component id. The exact failing check is unconfirmed; the
suspects are table id 2 and component id 0.

## Full-stream Huffman false reject (2026-09-27)

A 160x109 4:2:0 EXIF thumbnail from the Intel JPEG Library. Count vectors for
lengths 1..16, which all pass synthetic controls:

| Tc/Th | total | Kraft/65536 | counts |
|---|---|---|---|
| 00 | 12 | 65408 | 0,1,5,1,1,1,1,1,1,0,0,0,0,0,0,0 |
| 10 | 162 | 65535 | 0,2,1,3,3,2,4,3,5,5,4,4,0,0,1,125 |
| 01 | 12 | 65504 | 0,3,1,1,1,1,1,1,1,1,1,0,0,0,0,0 |
| 11 | 162 | 65535 | 0,2,1,2,4,4,3,4,7,5,4,4,0,1,2,119 |

Validate later traced the likely cause to zero-bit padding from the same
encoder. Confirm that once the padding code exists.

## Other September 30 items

- Item 2 (the non-luma-dominant sampling panic in `color.zig` `ycbcrRowToRgb`)
  is held for owner review. Do not resume it without new direction.
- Item 3 (the partial-allocation leak) was fixed 2026-09-30 02:57 EDT.
- Item 5 (JP2 facade offsets): set `offset_is_exact` where the leaf knows the
  byte, fill `host_offset`, and never report beyond `data.len`. Validate's
  example is `truncated_stream` reported at 690 on a 269-byte `tiny.jp2` with
  byte 259 flipped.

## Coordinator items

- Finding 261 = `cblk_contribution_ends_ff`, approved append-only (jp2z
  cf42bca). It is strict FAIL / lenient WARN. 252 `entropy_under_read` stays
  conditional: no-PTERM is a heuristic WARN, and PTERM needs actual
  termination-violation evidence. Add it behind a failing mapping/ABI test.
- The provider-flag evidence request of 2026-10-13 was overtaken by the owner's
  release of the JPEG provider hold on 2026-10-15. The sampling research stays
  held.
