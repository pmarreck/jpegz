# JPEG XL decode fixtures

These are lossless 9x7 JPEG XL codestreams for `jpegz.jpegxl.decode`. Each
sample is `(37x + 101y + 53c + 7xy) mod 2^bits`, where `c` is the channel
index and alpha comes last. So the formula itself is the oracle, independent
of any decoder.

How they were made, 2026-11-06:

1. `luajit tools/gen-pnm-formula.lua OUT 9 7 CHANNELS MAXVAL` writes the
   formula image: PGM for 1 channel, PPM for 3, and PAM for 2 or 4.
2. libjxl 0.12.0 from nixpkgs: `cjxl -d 0 -e 7 --quiet IN OUT.jxl`.
3. Cross-check: `djxl --quiet OUT.jxl BACK` reproduces every source byte for
   byte (`cmp`), including the 12-bit file at maxval 4095.

| Fixture | Channels | Bits | SHA-256 |
|---|---|---|---|
| `jxl_lossless_9x7_gray8.jxl` | gray | 8 | `40e8fcfbdceb7cfb9ee0d4cfff06f794e49849f0c7f6c22f67f8bf61e35e3234` |
| `jxl_lossless_9x7_graya8.jxl` | gray + alpha | 8 | `81a03e82d65408595f772955b698712923893542df5df5c424900fa7de342a69` |
| `jxl_lossless_9x7_rgb8.jxl` | RGB | 8 | `43e9b582567619bd8e7c51d736d46f2d1a61bec10bc5066912a2eded4483349a` |
| `jxl_lossless_9x7_rgba8.jxl` | RGB + alpha | 8 | `56f22c9dbcfa0c4acca83819187faa8121b524ea468d4fe143f2887893fc24d1` |
| `jxl_lossless_9x7_gray12.jxl` | gray | 12 | `1406bac80e3788e21c76d8c1ed90686c1288069c02eb242d4ad0d7ca901bb0e3` |
| `jxl_lossless_9x7_rgb16.jxl` | RGB | 16 | `aaaca4cf823c3753b6d8f21abddec9699349e40780bf42dc03cd7de39f3e2417` |
