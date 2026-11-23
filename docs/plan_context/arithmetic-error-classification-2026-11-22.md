# Arithmetic-coded JPEG decode error classification (validate ruling 2026-11-22)

Context: jpegz 5f8c2f6 fixed the arithmetic decoders' restart resume offset.
That exposed that SOF9/SOF10 decode errors are untyped, and that the
validator's generic mapping reports every one as FAIL 51
`huffman_table_corrupt`. Validate's ruling, following the 2026-11-21 JPEG-LS
rulings (same code as the T.81 Huffman path for the same situation):

1. **Restart faults:** an RSTm that is missing, out of order or unexpected
   where DRI applies is FAIL 56 `restart_marker_missing` or 57
   `restart_marker_unexpected`, typed at the marker.
2. **Entropy data ends early:** `insufficient_data` at the marker, 57 for an
   RSTm, and `truncated_stream` when the file ends there.
3. **Invalid DAC values:** values outside T.81 B.2.4.3 (Tc, Tb, DC L > U or
   U > 15, AC Kx outside 1..63) are FAIL 53 `arithmetic_table_corrupt` at
   the offending DAC byte.
4. **Decoded values with no specified decode:** the code the Huffman path
   gives the same condition, e.g. 58 `dct_coefficient_overflow`.

**Mapping rules:**
- No arithmetic decode error maps to `huffman_table_corrupt`.
- The mapping is an exhaustive switch, as for JPEG-LS (`mapJpeglsDecodeError`
  in src/core/validator.zig).
- An error with no Huffman analogue goes to validate with a proposed code
  before it ships.
- A failure that cannot be localized to a byte reports at the start of its
  restart interval, or at the SOS without DRI, labeled as the interval.

**Before shipping:** send the corpus report and controlled reds to validate.

## Follow-up ruling (validate, 2026-11-22)

**A. Unread bytes before a marker:** FAIL 8 `extraneous_bytes_before_marker`,
exactly at the first byte the decoder never fetched. Detail is
`arithmetic_interval` or `arithmetic_scan_end`.
- **Basis:** the T.81 D.1.8 flush emits only bytes the decoder fetches.
- **Not unread:** 0xFF fill bytes, and bytes already taken by pre-fetch.
- **Before shipping:** run every reachable arithmetic producer
  (libjpeg-turbo across restart intervals and image sizes, jpegtran
  `-arithmetic`, IJG libjpeg 9 if available, corpus SOF9/SOF10 files). Any
  producer that leaves unread bytes goes back to validate for a re-grade
  instead of shipping FAIL.

**B. Early end of entropy data:** no separate finding.
- **Why:** D.1.8 lets encoders drop trailing zero bytes, and D.2.6 supplies
  zeros past a marker.
- **Where damage surfaces:** short intervals desynchronize and show up as
  56, 57 or 8 at the next boundary.
- **Missing marker:** a file that ends without its marker keeps
  `truncated_stream`.
- **Detection limit (document in SPEC):** a short final interval whose
  zero-filled decode completes cleanly cannot be detected.

## Decoded-fault ruling (validate, 2026-11-22)

1. **58 `dct_coefficient_overflow`** covers every magnitude category past
   T.81's bound for precision P.
   - **DCT:** a DC difference category above P+3, or an AC category above
     P+2. That is 11 and 10 at 8 bits, and 15 and 14 at 12 bits (F.1.2.1,
     F.1.2.2). Progressive scans use the same unshifted bound.
   - **Lossless:** a difference category above 16 (H.1.2.2).
   - **Scope:** applies to the Huffman path as well, for parity.
   - **Offset:** the restart interval start (or SOS without DRI), labeled
     as the interval and not exact.
   - **Before shipping:** a producer and corpus check; any producer past
     the bound goes back for a re-grade.
2. **New FAIL 74 `entropy_decode_invalid`:** the entropy-coded decision or
   code sequence has no valid T.81 decode at that point. First use: a zero
   run past Se.
   - **Offset:** the interval start, labeled as the interval.
   - **Requested:** a list of Huffman-path cases now mapped to 51 that are
     data faults rather than table faults (for example a run past Se with a
     valid table, or a code that matches no table entry), with corpus
     counts. Validate rules separately on moving them to 74; they stay at
     51 until then.

## SOS Td/Ta ruling (validate, 2026-11-22): new code 75 `sos_table_selector_invalid`

A selector is a scan-header field that works the same under every process,
so 53 (DAC content) and 59/64 (process-specific Ss, Se, Ah, Al) do not fit.
- **Scope:** a Td or Ta outside T.81 Table B.3, on the Huffman and arithmetic
  paths alike.
- **Location:** exact at the Td/Ta byte; the detail names the component, the
  selector (`td` or `ta`) and the value.
- **FAIL:** a value above 3 (that destination cannot exist).
- **WARN:** 2 or 3 in a baseline frame when that table is defined (a
  baseline limit, most likely the writer).
- **Missing table:** a selector naming an undefined table keeps the
  missing-table code, which outranks 75.
- **Not covered:** lossless Ta (Table B.3 gives 0); report counts if seen.
- **Before shipping:** a producer check.
- **Huffman:** these cases move off 51 now; leave them out of the 51 list.

## Huffman-path ruling (validate, 2026-11-22, registry rulings F)

### Data faults: accepted

| # | Fault | Code | Location |
|---|---|---|---|
| 1 | Code matches no entry of a valid table | 74 | the code's first byte, exact |
| 2 | AC zero run past Se | 74 | exact |
| 3 | EOB run past the scan's remaining blocks | 74 | the EOBRUN code, exact (see below) |
| 4 | Refinement symbol with size other than 1 | 74 | exact |
| 5 | Whole bytes after valid padding | FAIL 8 | as on the other paths |
| 6 | Lossless scan data running into a marker | `insufficient_data` | at the marker |
| 7 | RSTm after the final unit of a progressive scan | 57 | at the RSTm |
| 8 | File ends with no marker after a progressive scan | `truncated_stream` | at the end of the file |

- **Item 1:** T.81 allows incomplete code tables, so a code with no entry
  is a data fault, not a table fault.
- **Item 3:** report exact at the EOBRUN code when the decoder tracks its
  position. Otherwise report at the scan end, labeled as the scan end.
- **Item 4:** G.1.2.3 allows only size 1 here.
- **Item 5:** this reclassifies audit row 51b.

### Item 9 and your question: neither option as proposed

- **58 at decode:** report it exact at the code. Huffman knows the bit
  position; the interval rule was for arithmetic only, because the Q-coder
  can't localize. So Huffman 58 fires on the decoded value.
- **The DHT symbol check needs producer evidence first.** A DHT carrying
  symbol values past the precision bound but never decoding them may be a
  writer pattern. For example, a writer could ship a generic 12-bit table
  in an 8-bit file. Grading that 51 FAIL could false-fail real files.
  - Please count DHT symbol values past the bound over your producer set
    and the corpus, and send the counts with the producers that wrote
    them.
  - If none are found, it is damage: FAIL 51, exact at the symbol byte.
  - If a producer does it, it is a writer pattern and we grade it then.

### Table and header faults

- **DHT counts overrunning the segment:** stay 51. The walker catches them
  exact at the count byte.
- **Bad Tc/Th and invalid code sets:** stay 51.
- **SOS Ns of 0 or above 4 in a later scan:** use the code the walker gives
  the same field in a first scan, for parity.
- **A scan naming an undefined AC table:** use the code the sequential path
  gives an undefined table, at the Td/Ta byte.

Recorded in validate's finding_code_registry.md (rulings F). Ship items
1-9 with your usual corpus report and reds. Validate maps them at the next
repin.


## DHT symbol bound (validate, 2026-11-23, registry rulings G)

- **Producer counts:**
  - jpegz: 2,141 files and 394 DHT tables;
  - validate: 5,391 local files and 19,897 tables, plus its corpus (17
    files, 62 tables).
- **Result:** no value past the bound anywhere except the deliberately
  corrupt `baseline_4x4_bogus_dht.jpg`. A first rule that also counted
  size-0 symbols with runs of 1 to 14 in progressive tables was wrong:
  those are EOBRUN symbols (G.1.2.2).
- **Ruling:** FAIL 51 `huffman_table_corrupt`, exact at the symbol byte,
  with the table (Tc, Th) and the value in the detail. The decoded-value 58
  stays for tables the walker misses.
- **Implementation note:** the walk reports the table before the codec
  check, so the decode-through no longer runs for such a file. Tests reach
  the decoders' 58 through the decode API's sink and
  `internal.losslessValidateWithFindings`.
- **Ns, an assumption to confirm:** the ruling said to use the code a first
  scan gets for the same field. A first progressive scan with Ns of 5 also
  ended in a bare 51 (Ns of 0 got an incidental `progressive_scan_invalid`
  from the misread tail). So every non-sequential T.81 scan now gets
  sequential's `sos_component_mismatch` at Ns.
