# Fresh test execution time (2026-11-22)

jpegz at d857cfa. Measured with `build-budget --project jpegz -- nix develop -c zig build test --summary all`, which reports each test binary's run step apart from its compile step. Run 1 followed a source change (some compiles fresh); run 2 repeated it with every compile cached, so its run steps are pure test execution. Times are the build runner's per-step durations, rounded as it prints them.

| Test binary | Tests | Run 1 | Run 2 |
|---|---|---|---|
| finding_provenance | 2 | 16ms | 10ms |
| smoke | 11 | 10ms | 7ms |
| jpegz_inline | 55 | 9ms | 12ms |
| decode_bitstream | 9 | 16ms | 21ms |
| decode_huffman | 23 | 13ms | 11ms |
| decode_idct | 11 | 22ms | 27ms |
| core_last_error | 4 | 12ms | 11ms |
| decode_arith_coder | 9 | 13ms | 14ms |
| decode_jpegls_bitstream | 7 | 17ms | 17ms |
| decode | 125 | 397ms | 354ms |
| validate | 73 | 13s | 9s |
| facade_validation | 49 | 2s | 1s |
| i18n | 7 | 16ms | 20ms |
| decode_jp2 | 8 | 74ms | 66ms |
| coverage_stats | 7 | 9ms | 25ms |

Sum of run steps: 15.62 s (run 1), 10.60 s (run 2). Wall time of run 2, including Nix evaluation, the dev shell and the build graph, was 12.93 s.

Against the one-second target and five-second budget, fresh execution misses both. The `validate` binary is 85% of run 2. `facade_validation` is next, at about 1 s.

## Where the `validate` time goes

`zig build test -Dtest-filter=TEXT` (added with this note) builds each test binary with only the matching tests. Running the `validate` test binary directly and timestamping each test's completion line (`ts -i`) attributes the time:

| Test | Time |
|---|---|
| sampling finding scope and complete component guards classify every frame count | 8.02 s |
| validate is total over every single-byte mutation of a real JPEG | 0.35 s |
| every other test (71) | under 0.07 s each |

That test validates a SOF for each of 8 markers × 256 component counts, 2,048 validations. With sampling byte 0xEE in every component, the validator emits finding 66 for every invalid H and V: 510 findings for a 255-component frame. `perf` showed two costs:

1. **Stack capture:** `std.testing.allocator` captures 10 stack frames per allocation, and that unwinding was over half the binary's samples. The test now uses a leak-checked `DebugAllocator` with `stack_trace_frames = 0`, which still fails on any leak and still runs every case. Its time fell from 8.0 s to 5 s, and the binary's from 9–13 s to 6 s.
2. **Finding volume:** formatting and storing the 510 findings, including report-array growth past page size. This is real validator cost, about 2.4 ms per such validation. Whether 66 should aggregate per frame is a question for validate (asked 2026-11-22). Until it is answered, the exhaustive sweep stays as is.

After the change, run-step execution is about 7.5 s. The remaining excess over five seconds is that sweep (5 s) and `facade_validation` (1–2 s).
