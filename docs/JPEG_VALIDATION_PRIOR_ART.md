# JPEG validation prior art

Checked September 6, 2026, following Peter's request. This is an established
digital-preservation and forensic-recovery use case. No claim of novelty or
superiority is established by jpegz's present tests.

## Closest research and implementation

Van der Meer, van den Bos, Jonker, and Dassen published
[Problem solved: a reliable, deterministic method for JPEG fragmentation point detection](https://cs.ou.nl/members/hugo/papers/dfrws-eu24.pdf)
at DFRWS EU 2024. It checks Huffman decoding, coefficient-array run bounds,
progressive refinement, and marker context. Those overlap directly with jpegz's
current work. The authors report over 99.4% detection within 4096 bytes in their
worst tested fragmentation scenario. Their damage model replaces a suffix with
random data; this is not an isolated-byte mutation rate or a guarantee for all
invalid JPEGs. These are published results, not measurements reproduced here.

The [accompanying implementation](https://github.com/parsingdata/jpeg-fragments)
is Apache-2.0 Java code. Its README describes a corpus exceeding 230,000 images
and a shipped curated subset exceeding 4,000 test files, covering baseline and
progressive variations. Audit implementation assumptions against T.81 and check
individual image provenance/licensing before importing fixtures. We have not
run this implementation against our corpus at the initial September 6 search.
The [September 11 targeted comparison](measurements/jpeg-probe-2026-09-11.md)
now reproduces two false accepts and one false reject on explicit fixtures.

Source inspection of
[revision 8b6ec79](https://github.com/parsingdata/jpeg-fragments/blob/8b6ec7928cf2ea0aa1269a720bcf2faa9a8f9713/src/main/java/io/parsingdata/jpegfragments/validator/jpeg/JpegProgressive.java)
predicts false rejection of valid progressive files with omitted AC bands or
unfinished refinement. Its scan loop requires every coefficient to reach
`Al=0` before completion. September 11 runtime tests reproduced this limitation
on a legal early-completion fixture, with an independent libjpeg pixel control. The
[libjpeg-turbo progression checks](https://github.com/libjpeg-turbo/libjpeg-turbo/blob/main/src/jcmaster.c)
explicitly permit omitted AC data and unfinished precision, corroborating the
standard's distinction. Treat jpeg-fragments as a comparison candidate, not
an unquestioned validity oracle.

## Existing tools and observed limitations

- [jpeginfo](https://github.com/tjko/jpeginfo) explicitly checks JPEG integrity.
  Its [source](https://raw.githubusercontent.com/tjko/jpeginfo/master/jpeginfo.c)
  uses libjpeg decoding and warning/error handling. It is a useful comparison
  candidate; successful decoding alone does not prove every spec constraint.
- [JHOVE JPEG-hul](https://jhove.openpreservation.org/modules/jpeg/) documents
  marker/segment well-formedness and profile validity. Its definition of valid
  also requires a recognized wrapper/profile. Do not equate that with bare
  T.81 codestream validity or assume entropy checks from its product name.
- Yvonne Tunnat's [2016 JHOVE versus Bad Peggy experiment](https://openpreservation.org/blogs/jpegvalidation/)
  tested concrete damaged files and documented disagreements, including JPEGs
  with premature entropy termination that JHOVE missed. It establishes prior
  work on this use case; it does not measure current releases. Bad Peggy used
  Java Image IO's decoder warnings/errors in that experiment.

## Consequences for this project

- Compare checks and verdicts on the same labeled inputs; do not compare our
  single-byte score directly with random-suffix recovery results.
- Turn disagreements into minimized fixtures, with the standard as the final
  contract. Decoder recovery, profile requirements, and implementation-specific
  restrictions can otherwise look like contradictory validity judgments.
- Keep demonstrated detection, spec-derived untested candidates, and legal
  changes separate. Preserve valid but inefficient encodings and legal
  progressive scan orderings; no trusted original means no proof of intent.
- Track survivor classification and known-good specificity alongside mutation
  sensitivity. Novelty and completeness remain unproven.

## Actionable comparison, September 9

Peter asks whether these works can improve our checks and whether we can exceed
their detection. At this assessment no head-to-head advantage had been measured;
the September 11 report above supplies subsequent bounded evidence.

The paper's section 7.2 reports run overflow as the first failure in about 73%
of baseline cases. That supports prioritizing entropy accounting; it is not the
standalone sensitivity of that check. Its difficult Huffman-table and restart
subsets suggest stratifying results by encoding features instead of reporting
one pooled score. See the paper linked above.

In the pinned `JpegProgressive.java`, DC-first validation skips the amplitude
bits without reconstructing the predictor. Restart alignment also skips the
remaining bits without checking their values. These inspected routines suggest
targeted comparisons for coefficient bounds and zero padding. Other checks may
reject the same fixtures later; whole-program differences require reproduction.
Our progressive history work should also preserve legal early completion.

The 2016 preservation experiment supplies a useful regression pattern: truncate
entropy, then append EOI. Marker presence must not substitute for complete scan
consumption. Reproduce the pattern with authored fixtures rather than assuming
the historical tool results describe current releases.

Proposed acceptance experiment, not yet implemented:

- Pin every tool and configuration; run identical inputs through jpegz,
  jpeg-fragments, jpeginfo, and JHOVE/Bad Peggy where their supported scope overlaps.
- Separate proven-invalid fixtures, proven-valid controls (including legal
  mutations), and unresolved cases. Decoder agreement alone cannot assign truth.
- Compare targeted violations, single-bit/byte mutations, truncations with and
  without EOI, and random-suffix replacements as separate workloads.
- Report paired wins/losses, false alarms, unsupported/indeterminate results,
  failure offsets, CPU/wall time and peak memory. An offset identifies where
  inconsistency became provable, not necessarily the byte originally changed.
- Freeze a held-out corpus before tuning. Group uncertainty estimates by source
  image so many mutations of one image do not masquerade as independent images.
- Claim a bounded win only for reproduced additional invalid cases without new
  false rejects on the corresponding controls. Claim broader superiority only
  after the held-out comparison, with corpus, workload and uncertainty disclosed.

Coefficient-value constraints and scan history are candidates for detecting
invalidity. Visual discontinuities, thumbnail disagreement and unusual image
statistics cannot by themselves prove a JPEG invalid. A mutation that produces
another valid codestream requires independent trusted reference information to
establish that it changed from the intended original.
