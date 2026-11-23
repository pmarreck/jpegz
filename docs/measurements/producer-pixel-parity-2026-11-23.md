# Producer pixel parity (2026-11-23)

`jpegz.decode` compared sample by sample with libjpeg-turbo 3.2.1 (the
build-time oracle, `internal.wrapperDecode`) on files written by the
producers themselves, at commit 3daedfd.

| Set | Writer | Files | Identical | Differ | Errors |
|---|---|---|---|---|---|
| Arithmetic producer sweep: sequential and progressive, 8- and 12-bit, sampling and restart variants | libjpeg-turbo 3.2.1 and IJG libjpeg 10 | 2,016 | 2,016 | 0 | 0 |
| Extreme-contrast arithmetic set (full-scale DC and AC steps) | libjpeg-turbo 3.2.1 and IJG libjpeg 10 | 288 | 288 | 0 | 0 |
| Huffman probes: baseline, progressive, 12-bit, 4:2:2, 4:4:0 and lossless, with and without restarts | libjpeg-turbo 3.2.1 | 40 | 40 | 0 | 0 |

Six lossless probes that `cjpeg` refused to write (empty outputs) are
excluded. The same files all validate as valid. The checker is a local
batch tool (`zig build pixel-diff`, built from an untracked scratch
source); this note records the result, not the tool.
