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

## Sequential SOS parameters and zero quantizers (2026-10-28)

A persisted regression initially failed: a hand-packed valid 8x8 grayscale
SOF0 stream with only SOS Ss changed to 1 is reported as passing. Its legal
control passes cleanroom/libjpeg pixel comparison. The native check reports
259/260 tests passed, with 76 C ABI assertions and 84 CLI checks passing.
The failing derivation is `di44k9mmlp3ic0fwhknwjh2mmi7rppsl-jpegz-tests-0.0.1.drv`.

[T.81 B.2.3 and Table B.3](https://www.w3.org/Graphics/JPEG/itu-t81.pdf#page=42)
require sequential DCT Ss=0, Se=63 and Ah=Al=0. The new test varies each
field byte through 0..255 for SOF0/SOF1 while the other fields stay legal, and
includes valid progressive, lossless and arithmetic controls. The first red
run stops at the Ss=1 witness; it does not establish results for every later
case. The shared public 170-byte fixture's SHA-256 remains
`4d2181d706292465831abd1e3460e22a5518ac91a4bc2ae96d1e54f17f8068f2`,
and its reported offsets 157..159 are the corresponding three field bytes.

The registry coordinator approved append-only 64 `sequential_scan_invalid`
on October 28 at 20:47 EDT, initially for SOF0/SOF1. The contract requires
FAIL/corrupt, the exact original-input field byte and details naming the
field, observed value and required value. Ah/Al share a byte, with the
relevant nibble identified in each detail. Existing 59 keeps its progressive
meaning. These malformed sequential parameters have not been admitted to the
known-encoder-defect exception. The implementation now reports each bad field
with this approved code. Native and C ABI controls verify the wire identity,
verdict, exact original and host offsets, and observed/required details.
The C controls exposed a missing host-offset copy in the classic strict
adapter; copying the original-input offset fixes that independent regression.

The coordinator also reconciled the historical October 14 pin question:
the provider hold was released October 15 and the inspected evidence contains
no additional hidden owner decision. Sampling remains held. Private original
replays and JP2 exactness remain provider dependencies; the JPEG-LS default
campaign and client-terminal questions remain explicit owner questions.

### APP0 and quantization controls

All 1,280 independent byte changes across the five-byte JFIF identifier
remain accepted JPEGs, with exact identifier recognition and cleanroom/libjpeg
pixel parity. [JFIF 1.02](https://www.w3.org/Graphics/JPEG/jfif3.pdf) permits
distinct application-defined APP0 data. Altering the identifier therefore
does not by itself establish malformed generic JPEG syntax.

The public 170-byte fixture has 64 nonzero quantizer entries and no entry
equal to 255, so its XOR-255 sweep generated no zero quantizer. Separate
8-bit and 16-bit regressions did reproduce missing FAIL 52 at a zero entry
(byte 7 of a hand-packed stream). Legal 1/255 and 1/256/65535 controls pass
independent pixel comparison; the 16-bit fixture uses a 12-bit SOF1 process.
The new bounded table walk reports zero words at exact field starts and
retains words with one zero byte. Its intermediate native run passed 262/263
tests, with only the pending sequential-SOS regression failing. The final run
also passes all 192 incomplete-table boundary cases.

### Complete local verification

The complete `./test` entry point and all eleven declared output/check targets
passed on October 28 at 21:07 EDT. The final native derivation
`0mwwhhc9sa89kc2qqslw6s3a0dhg26j4-jpegz-tests-0.0.1.drv` passes 265 Zig tests,
101 C ABI assertions and 84 CLI checks. This includes every sequential field
byte in SOF0/SOF1, all APP0 identifier controls and both quantizer widths.
All four cross-link checks, the validation closure, source-input controls,
coverage-statistics artifact and three no-C consumer controls also pass.

A new JP2 classifier-set regression initially failed because the facade
accepted identifiers belonging only to other codec families. The facade now
checks membership in the pinned JP2 provider's enum before translating it.
The test covers raw values 0..511 across all severity and container states,
including the new classic-JPEG code 64. Approved JP2 codes and the existing
261/252 corruption rules retain their behavior; unknown JP2 codes remain
inconclusive.

The bounded verification job finished successfully in about 215 seconds.
Its phase-timing output was unavailable after context truncation; that total
must not be presented as isolated test execution. The native derivation's
combined compilation/test phase took 116 seconds and the no-C consumer phase
took 50 seconds. Fresh execution remains a separate measurement task.
Published `d7f627a28f6b4dd96e348450c7f9ced1a3abfd10` passes all eleven
exact-commit CI targets, October 29 01:09:03Z..01:09:22Z (19 seconds, prepared
artifact reuse). Its fetched archive hash is
`jpegz-0.1.0-staw4K1vFAASj4ArDhJN7TC6sTjsc_Nh5ZWfxUtIJz4g`.
The coordinator and consumers received the immutable registry receipt.
The coordinator acknowledged and reconciled the code-64 shipment at
21:15 EDT; that acknowledgment does not establish consumer adoption.
Reserved markers and JFIF density/version/thumbnail semantics remain open;
these controls do not settle every label in the original 170-byte sweep.

### Remaining sweep labels and JFIF edition boundaries

The public fixture and XOR-255 operator give these interpretations of the
83 previously surviving offsets. This is a clause-based partition, not a
fresh runtime detection-rate measurement.

| Offsets | Count | Interpretation |
| --- | ---: | --- |
| 3 | 1 | APP0 becomes reserved marker FF1F; marker semantics are unrecognized. |
| 6..10 | 5 | Changed APP0 identifier; generic application data is permitted. |
| 11..12 | 2 | Versions become 254.01 or 1.254; historical/future-version treatment requires a declared edition policy. |
| 13 | 1 | Units becomes 255; invalid in 1.02, but this fixture declares 1.01 and its historical rule remains unverified. |
| 14..17 | 4 | Densities become 65281 or 254, both nonzero. |
| 18..19 | 2 | One thumbnail dimension becomes 255, the other stays zero; no thumbnail payload is required. |
| 25..88 | 64 | Quantizers remain nonzero; changed pixels are permitted. |
| 100 | 1 | SOF sampling factors 1/1 become 14/14; the earlier component-ID label was incorrect, and the 6b038ec replay reports unsupported. |
| 157..159 | 3 | Invalid sequential SOS fields; approved finding 64 now owns these. |

[T.871 10.1](https://www.itu.int/rec/dologin_pub.asp?id=T-REC-T.871-201105-I%21%21PDF-E&lang=f&type=items#page=12)
requires nonzero densities and Lp=16+3*HthumbnailA*VthumbnailA. It permits
either base-thumbnail dimension to be zero; 10.1 explicitly says that means
no thumbnail. Its version requirement is specifically 1.02. The earlier
1992 text and historical 1.01 files must remain distinct from a claim of
conformance to this formalized edition. The 2011 scope also limits sample
precision to eight bits; do not silently use that newer profile restriction
to reject otherwise supported historical JPEG processes.

[T.81 Table B.1](https://www.w3.org/Graphics/JPEG/itu-t81.pdf#page=36)
reserves FF02..FFBF. A successful decoder that skips such a segment does not
establish its unknown semantics. Extension/reserved-marker treatment needs
an explicit coverage result, preserving independently demonstrated corruption.
Reserved-marker treatment reuses existing finding 5; it requests no wire value.

The persisted declared-JFIF units classifier fails at units=3: expected
FAIL, observed INFO. Native derivation
`wj1r9v6wrkhcg9rbq189bbg0jyw7nxjl-jpegz-tests-0.0.1.drv` reports 266/267
tests passed, with C ABI 101/101 and CLI 84/84. Legal density and all 512
zero-product thumbnail controls pass. The coordinator received a request
for candidate 65 `jfif_metadata_invalid`, initially for units only.

At 21:16 EDT the coordinator approved 65 with rejection restricted to a
recognized complete JFIF 1.02 header. The initial red test's first witness
used 1.01, whose historical units rule was not established by the supplied
primary sources. Its expected rejection was therefore an unsupported
cross-edition assumption, not proof of that file's invalidity. Correct the
test to obtain an actual 1.02 red witness before implementing the approved
check; keep valid 1.01 controls. Any 1.01 rejection needs historical normative
or implementation evidence. Density, thumbnail, future-version and precision
rules are outside this allocation's initial rejection scope.

Reserved-marker regressions independently failed in native derivation
`8fg5vy0clcz2i354m568dqwbagiv1mm5-jpegz-tests-0.0.1.drv`: FF02 produced
valid instead of indeterminate, and FF00 outside entropy produced valid
instead of corrupt. The run had 266/269 passing Zig tests; its third failure
was the original unevidenced 1.01-units expectation. Corrected 1.02 and
native/C ABI/CLI tests were then run before implementation.

The corrected 1.02 regression also fails with the original implementation:
`17y16jxcdw4fyac9aha5h3xdfnkhdhjj-jpegz-tests-0.0.1.drv` reports 266/270
Zig tests passing, including failures for invalid units, complete-header
recognition, reserved markers and FF00. The C ABI's first invalid 1.02 units
case fails its verdict assertion. All twelve new CLI assertions fail while
the previous 84 pass. The approved enum/name alone already exists in this
red run; no validation behavior had changed.

The minimal implementation checks only complete, available 1.02 headers
and identifies the units field as a metadata/profile violation. The version
gate has classifier controls across all 256 values of either version byte;
these verify the rejection scope without claiming other versions valid.
Reserved FF02..FFBF now produce a located warning with existing code 5 and
an indeterminate strict verdict. FF00 outside entropy produces exact FAIL 5.
Opaque APP/comment controls remain valid, and unknown-marker uncertainty
does not hide actual corruption or erase the known zero-padding cause.
Complete `./test` and all eleven declared output/check targets passed at
21:26 EDT. Native derivation
`rl5fhsyhw9fjhwf0hwksdlh1qh5gd7vy-jpegz-tests-0.0.1.drv` covers 271 Zig tests,
119 C ABI assertions and 96 CLI checks. All 190 reserved-byte values,
17 assigned application/comment controls, 256 units values, 512 version-gate
cases and incomplete header boundaries pass. Legal density and zero-product
thumbnail controls match libjpeg pixels under the evidenced 1.02 version;
valid 1.01 unit controls also retain pixel parity.

Preparation took 182 seconds and the complete entry point then took 17 seconds
using those prepared results. Native compilation/test execution remains a
mixed 118-second phase; no-C consumer compilation/controls took 51 seconds.
This is correctness and artifact-reuse evidence, not a fresh execution-budget
measurement. Published `6b038ecc32b8a5301afd7218d711f98a592a771a` passes all
eleven exact-commit CI targets, October 29 01:28:52Z..01:29:10Z (18 seconds,
prepared artifact reuse). The fetched archive hash is
`jpegz-0.1.0-staw4D6jFADBqXPnHiAVYB0oQiNT2O13YQBVGKUKdbNU`.
The coordinator and consumers received the edition-scoped registry receipt.
The coordinator acknowledged code-65 delivery at 21:34 EDT and retained
the historical-edition correction; consumer adoption remains unverified.
Historical 1.01 units, future-version semantics and wider JFIF constraints
remain open.

### Public 170-case CLI replay

A complete replay against the production CLI from `6b038ec` ran in a qualified
read-only sandbox, with one independent XOR-255 per byte. The pristine hash
matches the public fixture above; the binary SHA-256 is
`5cf5a12ae8deb816aa2e9b9428d67343540f4ee1dc3905c9316f84fba93254d0`.
All 170 unique offsets completed in two seconds, with a five-second per-case
timeout and 2 GiB virtual-memory bound. No crash, timeout, I/O or harness
outcome occurred. Results are 88 corrupt, 78 valid, three indeterminate and
one unsupported. These operational counts are not proven-malformed detection
rates or a controlled comparison with the old Validate binary.

Among the 83 historical survivors, 78 are currently reported valid, three
corrupt, one indeterminate and one unsupported. The replay corrected the
static label for offset 100: it is sampling byte 0x11, changed to 0xEE, not
the component ID. Existing code reports unsupported for those 14/14 factors;
the normative header range needs its own bounded regression and registry
review, without reviving held non-luma-dominant sampling research.

The replay also exposed twelve classic strict findings beyond the input at
mutated segment-length bytes (4, 5, 22, 23, 91, 92, 104, 105, 128, 129, 152,
153). They retain corruption but present declared segment extents as byte
and host offsets, for example 65300 for a 170-byte input. Add a persisted
regression before normalizing these locations; preserve the reported extent
in detail and do not turn bounds into an exactness claim.

The first harness launch could not see its RAM-resident script inside the
private sandbox `/tmp` and executed no mutants. Supplying the script through
stdin fixed that harness issue; only the completed 170-case run is counted.

The persisted classic-location classifier failed in native derivation
`gxcv8gm90makczq71wccph12a65gxk7j-jpegz-tests-0.0.1.drv`, 271/272 Zig tests
passing, with C ABI 119/119 and CLI 96/96. It varies either APP0 length byte
through all 256 values and requires bounded original/host locations, nonexact
EOF cursors and raw declared extents retained in details. Additional C ABI
and CLI witnesses are now running before implementation.

The extended red run
`3ws5myrnmrkxkd11mb3blghv459wjljj-jpegz-tests-0.0.1.drv` reproduced the
same location fault through C ABI and CLI JSON. A separate new sampling test
did not execute: calling `validateAny` from the core-only validation target
introduced unresolved Brotli symbols. Changing that test to the core report
API preserves its purpose without adding dependencies; it still needs an
actual semantic red witness. The coordinator has the candidate-66 registry
request and the explicit held-work boundary. No sampling implementation or
enum assignment has been made.

Classic strict location normalization is now implemented: positions beyond
the supplied buffer become null original/host locations, with the raw
reported extent appended to detail. EOF remains a nonexact cursor, and
existing exact header locations retain their flags. The corrected native
run is awaiting resource admission; queue wait is not execution time.

At 21:42 EDT the coordinator approved append-only 66 `sof_sampling_invalid`
with an initial scope restricted to single-component SOF0/SOF1. It requires
FAIL/corrupt, exact original/host packed-factor byte, and the component,
offending nibble, observed value and allowed 1..4 range in detail. The scalar
validator check is explicitly outside the held non-luma-dominant panic
research. The approval does not authorize decoder edits, pin changes, other
processes or additional components. An actual semantic red witness remains
required before implementation; the corrected run is still queued.

The corrected run was admitted at 21:46:27 EDT after approximately 402
seconds of resource-queue wait. Native derivation
`fy6v51hyaahs4i6ifvgjg7k09v32qnbg-jpegz-tests-0.0.1.drv` now supplies the
actual sampling semantic red witness: the first factor byte 0x00 produces
a report considered valid instead of a failure. That is independent of the
earlier link error. The approved single-component range check can now be
implemented; this witness does not establish results for later classifier
values until the complete run passes.

That red run completed with 272/273 Zig tests passing, C ABI 124/124 and CLI
99/99. The new location controls pass; the sole semantic failure is sampling.
The implementation now checks only the authorized single-component processes.
Its first expanded native run passed 167 C assertions and 104 CLI checks,
but a type-inference error prevented the expanded core scope classifier from
compiling. This is incomplete verification, not a green suite. The typed
fixture arrays are corrected; full preparation and `./test` are running.
The expanded tests include all 256 frame counts across eight processes,
declared-length/physical-truncation boundaries and an explicit nonexact EOF
cursor control.

Complete preparation and `./test` passed at 21:56 EDT. Final native derivation
`k8qqbp6p8xdaklhdm3bmh3k11028qixj-jpegz-tests-0.0.1.drv` covers 274 Zig tests,
168 C ABI assertions and 104 CLI checks. All 256 factor bytes in each initial
process, all 16 legal pixel pairs per process, 2048 process/component-count
scope cases, declared and physical header boundaries and the retained EOF
cursor pass. All four cross links, validation closure, source controls,
coverage-statistics artifact and no-C consumer controls pass as well.

Preparation took 196 seconds and the complete entry point then took 17 seconds
using those prepared results. Native compilation/execution is a mixed
127-second phase. The earlier semantic red run's 402-second admission wait
remains separately recorded; no execution-budget or fresh-runtime claim is
made from these mixed or cached timings. The same 170 public mutations are
being replayed against the prepared production artifact before publication.

The repeated public replay completed all 170 unique offsets in two seconds,
with no unexpected process or harness outcome. The prepared CLI SHA-256 is
`85cc79e1bdba9e535a609075412231f316cebc787422de62e22d15481517ca3b`.
Results are 89 corrupt, 78 valid and three indeterminate. Relative to the
recorded `6b038ec` cohort, the only verdict change is offset 100, unsupported
to corrupt with exact finding 66. All twelve former beyond-input locations
are now null original/host positions, with their raw extents preserved in
details; no finding in the replay exceeds the supplied buffer. This comparison
uses identical public inputs and the same mutation operator, but still does
not turn the operational rejection count into a malformed detection rate.

Published `faf0c92721b2dfdc7647fd3574a3ce850c2cb95b` passes all eleven
exact-commit CI targets, October 29 02:01:31Z..02:01:50Z (19 seconds with
prepared artifact reuse). The actual fetched archive hash is
`jpegz-0.1.0-staw4IvRFACRGqCwMagk-HDwDD-mFaEZsXJ4u3DXaeH2`.
The coordinator and consumers received the immutable code-66 receipt with
the initial scope and unchanged research hold explicit. Adoption remains
unverified; the historical 1.01 question remains separate.

At 22:06 EDT the coordinator reconciled code-66 delivery and independently
verified the official IJG 6a archive hash and historical source members.
That satisfies the previously allowed compatibility-evidence route for a
separate units-only extension of code 65 to complete recognized JFIF 1.01.
It is still implementation evidence, not the original normative document;
the unchecked encoder copy does not prove older encoders never emitted other
values. A fresh persisted 1.01 red witness, exhaustive units, generic/other
version exclusions, truncation/location checks, full suite and exact CI are
required before shipment. Future versions and wider metadata constraints are
outside this extension.

The fresh approved 1.01 red run
`1vw188yrbnxbxplnz9dcid1f2b9pckkh-jpegz-tests-0.0.1.drv` passes 272/274
Zig tests, with failures at 1.01 units and the expanded version gate. The
C ABI fails the first invalid 1.01 verdict; four new CLI assertions fail
while the previous 104 pass. The implementation now admits only major 1
with minor 1 or 2 to the units rule and names the actual version in detail.
Both versions have complete/available header controls and generic-APP0
exclusions. Full preparation and `./test` are in progress.

The complete suite passed at 22:20 EDT: 274 Zig tests, 182 C ABI assertions,
110 CLI checks and all eleven declared targets. Preparation took 197 seconds,
followed by 21 seconds for the entry point using prepared artifacts. Native
compilation/execution is a mixed 122-second phase. On resumption October 29,
the working tree still evaluates to the verified native derivation
`aq0hq31x53ymmd6wb6dp6s6jwxhlrmxz-jpegz-tests-0.0.1.drv`.

The identical 170-case public replay completed in two seconds with no
unexpected process outcome and no beyond-input locations. Its binary SHA-256
is `ae01f8180544afd1812621431f007ce044a12a610e4a36ce2581c2070b8b56cf`.
Relative to `faf0c92`, only offset 13 changes verdict: valid to corrupt with
exact finding 65 for JFIF 1.01 units=255. Counts are 90 corrupt, 77 valid and
three indeterminate; these remain operational outcomes, not a malformed
detection rate. Future-version rows 11 and 12 remain for the separate
approved code-67 capability notice.

The next version-adjudication unit has a separate coordinator question for
candidate 67 `jfif_version_unchecked`. The proposed initial scope is complete
recognized headers with major greater than 1, or major 1/minor greater than 2,
reported as WARN/indeterminate rather than proven corruption. Older version
behavior is excluded without claiming complete conformance. No value or
implementation is assigned yet, and no future-version behavior is included
in the current historical-units extension.

At 22:21 EDT the coordinator approved and reserved code 67 for this bounded
future-version capability notice. The implementation must follow the
historical units shipment as a separate red-first unit. It requires exact
major/minor byte locations, WARN/indeterminate, both finding orders for mixed
causes, and corruption precedence while preserving any known-padding cause.
Major zero and 1.00 remain explicit coverage gaps, outside the initial rule.
Base-header availability establishes only bounded recognition; it does not
prove a future format must share that layout. No code-67 behavior is included
in the current units change.

On October 29 Validate acknowledged the October 28 shipments through
`faf0c92` and recorded their contracts for adoption through its provider
chain. The private SOF1 replay is queued and requires recovery of the
original work-order identities. No private replay or consumer qualification
has been established; only structural findings will be returned.

### Historical JFIF 1.01 implementation evidence

The official [IJG release 6a archive](https://www.ijg.org/files/jpegsrc.v6a.tar.gz)
has fetched SHA-256
`0e963fdd29d5049f61f3dc137bdc9437473a0ad505dbcfc8925f0fcad46c5929`;
its README identifies the release as February 7, 1996. Inspection used archive
members through stdout, without executing or installing historical code.
`jpeg-6a/jcmarker.c`'s `emit_jfif_app0` emits version 1.01 and documents the
three units meanings 0/1/2, matching `jpeg-6a/jpeglib.h`'s public API comments.
The writer explicitly selects 1.01 because it uses no 1.02 features.

This supports a shared-header compatibility argument; it is historical
implementation evidence, not the original 1.01 normative text. The writer
copies the unsigned units byte without range validation. Neither that
permissiveness nor successful reader recovery proves every value legal.
The coordinator has the evidence for independent review against the earlier
allocation condition. No 1.01 rejection has been added, and any accepted
extension will follow the current location/code-66 unit separately.
