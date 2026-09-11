# JPEG detection experiments, September 11, 2026

## Bounded comparison with jpeg-fragments

We reproduced two false accepts and one false reject in
[jpeg-fragments at 8b6ec792](https://github.com/parsingdata/jpeg-fragments/tree/8b6ec7928cf2ea0aa1269a720bcf2faa9a8f9713).
These are targeted fixtures, not a population detection rate or speed comparison.
The independent reviewer ran the experiment; the main agent inspected the
adapters, recompiled them and repeated all nine upstream cases.

| Input | Contract | jpeg-fragments | jpegz after |
|---|---|---|---|
| P8 AC category 10 | Valid | Accept | Valid |
| P8 AC category 11 | Invalid | Accept | Corrupt |
| P12 AC category 14 | Valid | Accept | Valid |
| P12 AC category 15 | Invalid | Accept | Corrupt |
| Original progressive, 520 bytes | Valid | Accept | Valid |
| First 441 bytes plus EOI | Valid early completion | Reject: SOSBlock | Valid |
| First 441 bytes without EOI | Invalid | Reject: SOSBlock | Corrupt |
| Original minus EOI, 518 bytes | Invalid | Reject: JpegFooter | Corrupt |
| Original baseline, 690 bytes | Valid | Accept | Valid |

The AC fixtures have one 8x8 component, unit quantization, DC zero and a full
AC band. Literal payloads are A007/A003 for P8 categories10/11 and A0007F/A0003F
for P12 categories14/15. T.81 Tables F.2/F.7 and G.1.2.2 establish the AC limits.
The complete 32-case classifier lives in `tests/unit/validate.zig`; accepted
cases compare pixels with libjpeg-turbo. The early-completion fixture ends before
SOS at offset441 and appends FFD9. Its separate pixel-oracle control passes.
The facade's ten-case EOI regression checks the strict verdicts in the table.

Reproduction adapters are retained in [prior-art/PriorArtProbe.java](prior-art/PriorArtProbe.java)
and [prior-art/AcBoundaryProbe.java](prior-art/AcBoundaryProbe.java). They are
optional experiment drivers, not production dependencies or part of `./test`.
The second refuses to overwrite existing fixture files.

Upstream was unmodified, sparsely checked out without its image corpus, and
compiled with Maven 3.9.16 and OpenJDK 21.0.12+8 using the POM's Java11 target.
Dependencies were metal-core9.0.0 and metal-formats9.0.0; corpus tests were not
run. The adapters use upstream's `InMemoryByteStream` test helper and a fresh
`JpegValidator` per case. Exceptions are printed separately from verdicts.

Rebuild recipe after a sparse checkout of that exact revision (run from its
root; substitute absolute paths for the three variables):

```bash
probe_repo=/path/to/jpegz
probe_work=/path/to/new/private/scratch
probe_binary=/path/to/verified/jpegz
mvn -B -q -Dmaven.repo.local="$probe_work/m2" -Dmaven.test.skip=true compile dependency:build-classpath -Dmdep.outputFile="$probe_work/classpath"
probe_cp="target/classes:$(<"$probe_work/classpath")"
javac --release 11 -cp "$probe_cp" -d "$probe_work/classes" src/test/java/io/parsingdata/jpegfragments/validator/InMemoryByteStream.java "$probe_repo/docs/measurements/prior-art/PriorArtProbe.java" "$probe_repo/docs/measurements/prior-art/AcBoundaryProbe.java"
java -cp "$probe_work/classes:$probe_cp" PriorArtProbe "$probe_repo/tests/unit/fixtures/progressive_8x8_rgb.jpg" "$probe_repo/tests/unit/fixtures/baseline_2x2_rgb.jpg"
java -cp "$probe_work/classes:$probe_cp" AcBoundaryProbe "$probe_binary" "$probe_work/ac-fixtures"
```

## Seeded mutation comparison

`corruption-probe` used seed0x1234, 50 rounds per mode, jobs4, safe restoration,
30-second timeout, shotgun window64 and `--exit-map 3=warning`. That mapping
places jpegz's unsupported/indeterminate exit3 in the probe's excluded bucket;
it does not count as corruption detection. All 200 cases completed; two were
inconclusive on both builds, with zero crashes, timeouts or execution errors.

| Mode | Before rejected/conclusive | After rejected/conclusive |
|---|---|---|
| Sniper: one bit | 32/50 | 32/50 |
| Bolter: byte XOR FF | 34/49 | 34/49 |
| Shotgun: 64 bytes | 49/49 | 49/49 |
| Truncation | 49/50 | 50/50 |

The paired comparison identifies exactly one accepted-to-rejected transition,
truncation round46 at new length441, and no rejected-to-accepted transitions.
All three specificity controls (baseline, progressive and lossless fixtures)
passed both builds. This measures one tiny image and seed, with whole-file
mutations; it is not an entropy-interior sweep or the paper's suffix experiment.
The other accepted mutations have not been adjudicated as valid or invalid.

The source is `tests/unit/fixtures/progressive_8x8_rgb.jpg`, 520 bytes,
SHA256 `b65f5f7e6b0b3dc9e0e88855a4591c713f20f38cb5ef9dac0c73c16cb10deda6`.
Its hash was unchanged after the experiments. The CLI binaries were immutable
Nix ReleaseFast outputs:

- Before: SHA256 `b372f4108a7312846b247eb035b711827d7dd4035795f075f53dcca65ed4bcc5`,
  `/nix/store/jkn8n0nfdgjsmhwsbjz4ryqp9ggrfrf7-jpegz-0.0.1/bin/jpegz`.
- After: SHA256 `2df72288f3dc056eea16c0cc2faec935e2c0d12822ef4152b9bb94c5d65a0bb3`,
  `/nix/store/4dcgm6nvy8rh1x0lk74d0lfcmq1wg0fp-jpegz-0.0.1/bin/jpegz`.

The before store source's two changed production files match HEAD1597660;
the dependency manifest matches the current one. This is checked provenance,
not a reconstruction of every historical build input. The after binary includes
both category changes and the EOI verdict change. The paired fixture regression
specifically isolates the missing-EOI behavior. No speed improvement is claimed.

Persistent reports/events live in corruption_probe's default history under
the source SHA above, runs `20260911T204545Z-b61d03eb` and
`20260911T204547Z-e730f537`. `corruption-probe compare BEFORE_DIR AFTER_DIR`
reported compatible settings, 200 paired cases and one change. The installed
probe repository was observed at591e8d1; the report records mutation algorithm v1
and its RNG identity. Temporary copies and upstream build are under
`/tmp/jpegz-probe-20260911-xczSg3` and `/tmp/jpegz-prior-art-AMlZsdrE`.

## Test-evidence correction

The first EOI unit test failed on `NotImplemented`: it incorrectly called pixel
decoders in the deliberately decoder-free facade test target. That failure did
not establish the regression. Pixel controls were moved to the oracle-enabled
unit target, the production fix was removed, and the rerun explicitly failed
with `len441 expected corrupt, found valid`. That run passed the separate
libjpeg early-completion control. Only this corrected red counts as TDD evidence.
