# Validate findings queue, 2026-09-27 to 2026-10-14

Durable record of Validate's JPEG work orders and false-positive reports from
that period, kept here so the inbox envelopes can be retired. The
original files stay private to Validate; only synthetic shapes are recorded.

The October 28 clarification supersedes this queue's earlier verdict policy:
jpegz owns identifying known JPEG encoder defects and reports KNOWN_DEFECT
through its API and a distinct CLI exit code. WARN describes their treatment,
not their classification. validate consumes that classification and applies
its application policy. Ordinary warnings remain distinct, and corruption or
incomplete validation must not be hidden by a known defect. The October 23 and
27 rulings permit WARN treatment unless the defect produces corrupt or
unopenable output or existing readers reject it. Successful decoding alone
does not admit a known defect.

## Distinct finding labels (2026-10-10)

### SOS header findings (2026-10-28)

The common marker walker checks repeated T.81 selectors before entropy
decoding and reports 55 `sos_component_mismatch` at the repeated Cs byte.
Sequential Huffman scans also report 55 at invalid Ns, and 4
`bad_marker_length` at the Ls field when its size is inconsistent. Both
locations are exact. The selector walk reserves the three trailing parameters
so an excessive Ns cannot manufacture extra component findings from them.
JPEG-LS duplicate-selector policy is unchanged.

The normative basis is [T.81 B.2.3 and Table B.3](https://www.w3.org/Graphics/JPEG/itu-t81.pdf#page=41).
Tests cover baseline, extended sequential, progressive and lossless headers,
the valid four-component CMYK boundary, short/long lengths, zero/excessive Ns,
and the complete failure set for an excessive count in a short header.

Registry decision 2026-10-20 12:38 EDT: 62 `entropy_padding_not_ones`
approved (append-only, FAIL, exact entropy pad-byte offset); reuse 57
`restart_marker_unexpected`, 3 `truncated_stream` and 55
`sos_component_mismatch`. Conditions: legal all-one and byte-aligned endings
remain accepted; paired end-of-scan and restart controls identify mixed pad
bits as 62; live entropy and marker fill are not padding. Applicability is
Huffman-only, with progressive and lossless covered and arithmetic excluded.
Preserve multi-scan acceptance, verify generated C declarations and consumer
mapping, and send consumers the tested commit. All-zero padding was subsequently
assigned 63 with WARN treatment by the October rulings.

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

Historical September request, superseded by the October rulings above:
severity stays FAIL. Validate withdrew its WARN proposal. It wants its own code
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

### Scans after complete sequential coverage (2026-10-28)

Sequential Huffman decoding now inspects the remaining marker chain through
the first EOI. A further SOS receives exact FAIL 55 at its first selector;
the validator retains that typed finding without adding generic 51. This
applies to strict and lenient decoding. Opaque APP payloads may contain marker
bytes, so the inspection skips complete length-delimited payloads.

The inspection defers its finding until EOI. Missing-EOI decode outcomes stay
unchanged, including existing acceptance of incomplete metadata tails after
full component coverage. Data after the first EOI remains trailing data.
Tests cover interleaved and three-scan inputs, metadata containing fake SOS
and EOI bytes, exact offsets, both decoder modes, and valid pixel controls
against libjpeg-turbo. This does not claim arithmetic or hierarchical support.

The failing native regression accepted an extra scan before the fix; its
missing-EOI characterization already passed. After the fix, the complete
local test entry point passed native/CLI/C ABI tests, the production build,
all four cross-link checks, the dependency closure and isolated consumer
negative controls. Cross compilation and closure preparation dominated the
roughly 16-minute full run; native preparation had already passed separately.

## SOF1 with component ids 0/1/2 and table pairs 0/1/2 (2026-09-30 item 4)

A 3-component SOF1 with component ids 0/1/2, each using its own DC/AC pair 0, 1
or 2, all defined in one 626-byte DHT. Kraft sums are 0.996-0.99997 and the max
symbol is 0xFA. `djpeg -strict` decodes all three private streams. Accept table
ids 0-3 and any component id. The exact failing check is unconfirmed; the
suspects are table id 2 and component id 0.

Synthetic controls passed on 2026-10-28 without a decoder change. They preserve
the entropy from the libjpeg-generated 8-bit baseline fixture, switch to SOF1,
remove its JFIF claim, and combine six Huffman specifications into one DHT
with Lh=626. The third component receives its own copy of the chroma pair.
Component IDs and corresponding selectors move together across all 256 cyclic
triplets, including 0/1/2 and the 255/0/1 wrap boundary.

A separate classifier covers every Td/Ta byte: the 16 legal pairs move their
matching definitions too, preserving the encoded codebooks, while the 240
out-of-range selectors fail. Eight controls select undefined DC or AC tables
within the legal 0..3 range and also fail. Every valid case decodes in the
cleanroom path and matches both its libjpeg-turbo oracle and the original
pixels. These controls establish support for the reported header shape, not
the validity of the private originals. A private replay remains open.

The complete local test entry point passed native/CLI/C ABI checks, production,
all four cross-link checks, the dependency closure and consumer negative
controls. The regression uses the JPEG-specific validation API so this test
binary does not acquire unrelated JPEG XL/Brotli linkage.

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

### JP2 strict-facade location bounds (2026-10-28)

A public regression reproduces the location problem without the private
original: XOR byte 215 of `tests/unit/fixtures/jp2_8x8_rgb.jp2` with 1. The
238-byte input produces leaf finding 3 at position 242. The first persisted
regression failed on that overshoot; a strengthened regression also failed
because the same report's in-buffer anchor at 147 had no host offset.

The strict adapter now retains positions through EOF and copies them to the
standalone host offset. A position beyond the input becomes null byte and
host offsets, and its raw numeric position is preserved in the owned detail
string. The typed truncation finding, FAIL severity and corrupt verdict stay
intact. The regression requires the 147 anchor to survive, preventing a fix
that discards every location. A set of 168 one-bit packet-region mutations
checks location bounds with container and geometry headers held fixed; a
clean control remains valid. This is a location regression, not a measurement
of corruption-detection sensitivity.

The complete local test entry point passed native/CLI/C ABI checks, production,
all four cross-link checks, the dependency closure and consumer controls.
A separate production-CLI check confirmed exit 1, null byte/host offsets,
nonexact status and position 242 retained in JSON detail. Nix sandboxing was
confirmed enabled. No finding IDs, provider pins or classification policy
changed.

The pinned jp2z Finding exposes a numeric offset without exactness metadata.
Its cursor/anchor/declared-end contract is pending a provider response; bounds
alone must not turn on `offset_is_exact`. The older severity-only JP2 adapter
also remains to audit. This change does not claim either part is complete.

## Coordinator items

- Finding 261 = `cblk_contribution_ends_ff`, approved append-only (jp2z
  cf42bca). It is strict FAIL / lenient WARN. 252 `entropy_under_read` stays
  conditional: no-PTERM is a heuristic WARN, and PTERM needs actual
  termination-violation evidence. Add it behind a failing mapping/ABI test.
- The provider-flag evidence request of 2026-10-13 was overtaken by the owner's
  release of the JPEG provider hold on 2026-10-15. The sampling research stays
  held.

### JP2 finding 261 and conditional severity (2026-10-28)

The facade now mirrors approved finding 261 as `cblk_contribution_ends_ff`,
with its numeric identity and name available in Zig and the generated C
header/API. No registry allocation or provider pin change was needed.
The first red tests found an indeterminate mapping and an unknown C name.

The contribution ending is a proven format violation. Lenient WARN treatment
must therefore retain a corrupt classified verdict. A draft expectation had
equated WARN with valid; review against the accepted intent exposed that
mistake before publication. Corrected tests failed with expected corrupt but
actual valid, and the mapper now preserves severity independently of validity.
All declared severity tiers are checked. Finding 252 keeps its conditional
behavior: the no-PTERM heuristic warning alone is not proof of corruption;
leaf-reported failures remain corrupt. Unknown future codes remain
indeterminate. This does not complete the broader JP2 warning-class audit.

The complete local test entry point passed native tests, 76 C ABI assertions,
84 CLI checks, production, all four cross-link checks, the dependency closure
and consumer controls. The registry is append-only and earlier values retain
their identities. Held sampling research remains held.

## Feedback latency observation (2026-10-28)

The local gates for 4fb4c19 reported build-phase spans of 114 seconds for
native tests, 117 for the package, 143/207/131/152 for the four cross-link
checks, and 124 for the closure proof. These include compilation; test
execution was not timed separately, so they do not establish an execution
budget result. Exact-commit CI completed in 988 seconds. Each derivation
currently takes the whole source tree, so source-input scope and cache reuse
need investigation before changing the pipeline. Preserve every required
suite and verify source completeness before narrowing any inputs.

The no-C consumer check formerly invoked the compiler from the master test
runner's development shell. It now runs in `checks.<system>.no-c-consumer`,
with Zig as its only declared native build input and no codec libraries in
scope. The required-C negative control and disabled-JP2 positive control stay
paired with the validation-only consumer. All three passed in the Nix sandbox;
the combined compilation/check phase took 45 seconds. The complete entry point
and exact-commit manifest both reach this check. Private scratch alone would
not establish the preventive filesystem boundary supplied by the derivation.

## Coverage tooling refresh (2026-10-28)

Both lock files now use nixpkgs `58deea654ec5dd0644f31c840a07c29fa0592528`.
The optional coverage flake pins published corruption-reader
`1ec8cbe4f246bd60156bff3cdc5865f99d64ec4b` (0.9.0), reaching
performance-profiling `01ae85bdd434b019b1c5512a39f2766665eab9de` and
printable-binary `cdefa95e4590fa016967e0e6ccb3b96c19c44c7e`.
Nix generated the source hashes. The JP2/JXL codec pins and Zig dependency
closure hash remain unchanged.

`packages.<system>.coverage-stats` exposes the statistics executable already
built by the native test graph. Its installed copy passes the driver suite.
Default preparation uses `nix build` with no output link and ignores stale
`zig-out` statistics binaries. Tests classify regular files and usable
symlinks as executable artifacts, and reject directories, nonexecutable files,
missing files and failed builds before requesting any mutation. The six
bootstrap cases failed against the old path before implementation.

The original four-fixture smoke request stopped before mutation because the
pristine JPEG-LS fixture returns `indeterminate`. Existing strict-facade tests
require that result; this refresh does not relabel it valid. The default-fixture
mismatch remains open. A separate explicit three-fixture campaign completed
with the fresh Nix-built CLI, statistics helper and reader:

| Parameter | Value |
| --- | --- |
| Fixtures | `baseline_2x2_rgb.jpg`, `jp2_8x8_rgb.jp2`, `jxl_delta_palette_valid.jxl` |
| Profiles | sniper, bolter, shotgun, nuke |
| Rounds per fixture/profile | 5 |
| Master | `0x6a7065677a` |
| Limits | One job, five seconds per validation, 2 GiB address space per process |
| Applied/judged | 60/60 |
| Corrupt/accepted/known defect/indeterminate | 31/18/0/11 |
| No-op/unsupported/inconsistent/I/O/timeout/crash/harness error | All zero |
| Pooled corrupt/judged, Wilson 95% | 51.7%, [39.3%, 63.8%] |

The smoke campaign ran through the shared Linux isolation runner after its
filesystem-denial and private-state contract passed with the same frozen
script bytes. Inputs were read-only public fixtures; mutations and reports
lived in private namespace scratch. The 11 indeterminate cases remain in the
judged denominator. These are observed outcomes, not independently established
malformed labels or a before/after detection claim. JPEG-LS has no mutation
result in this campaign.

The final complete `./test` passed native tests, 76 C ABI assertions, 84 CLI
checks, the installed statistics driver suite, the production build, all four
cross-link checks, closure validation and all three no-C consumer controls.
Its wrapper recorded 129 seconds of production preparation followed by 132
seconds in the complete entry point, while a parallel explicit Nix batch
prepared the other required targets. These are mixed preparation/evaluation/
waiting spans, not isolated test execution times. The slowest reported final
cross-build phase was 197 seconds. All ten manifest targets were realized
locally. Published tooling commit `45f339ff39b187829326e9f6be2b62360f102cbb`
then passed all ten exact-commit CI targets in 1,029 seconds.

## Stable build sources (2026-10-28)

`nix/source.nix` supplies a fixed `source` name to every source-bearing build
and check, including dependency collection. It excludes root Markdown records,
`docs/`, `.mechatron-prime/`, `.git` and `.dirtree-state`. Legal notices stay
included. All other inputs remain included by default, including nested
Markdown fixtures, optional scratch tools, future components and `flake.nix`.
The CLI cache-hook test reads that last file, so excluding all Nix metadata
would remove a required input.

The source-input check evaluates test-owned trees in a private Nix store
inside the Nix sandbox. Its classifier compares the complete retained file
set. Metamorphic controls compare source and derivation identities after
relocation, documentation edits and CI-record edits, and require changed
identities for future-file additions and eleven code, fixture, build, tool,
header and legal-notice edits. The future-file control requires the retained
bytes too, so an empty directory cannot satisfy it. Relative source symlinks
and a directory ending in `.md` remain usable. All 18 controls pass.

Before filtering, the complete-file-set, two relocation, documentation and
metadata controls failed; all required-input changes already passed. A second
regression made unexpected stderr fail the check and exposed read-only private
store cleanup that the old EXIT trap had silently ignored. Cleanup now restores
permissions only within the test-owned store, checks deletion and preserves
the test's failure status. The passing gate produces no unexpected stderr.

The final complete suite passed against the filtered tree, including native
codec tests, 76 C ABI assertions, 84 CLI checks, installed statistics controls,
the production build, all four cross-link gates, closure validation and the
three no-C consumer controls. All eleven manifest targets were realized.
Preparation took 226 seconds, including compilation and test execution; the
complete entry point then took 21 seconds with prepared Nix results. These
durations do not isolate fresh test execution.

Published `dedea6411d465bfbf1de7b09d2716cbfeba9bb44` passed all eleven
exact-commit CI targets in 17 seconds (2026-10-29 00:18:35Z to 00:18:52Z).
An independent evaluation of its GitHub archive produced exactly the same ten
check derivation paths as the local preparation; the eleventh target exposes
the native check's statistics artifact. The preceding tooling commit took
1,029 seconds in CI. This establishes reuse of the prepared artifacts across
the two source locations. It measures cached CI verification, with fresh
runtime timing still open.
