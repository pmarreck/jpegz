# Historic encoder bug exemplars

These are synthetic exemplars of documented producer bugs, built on
2026-11-05 for validate's KNOWN_DEFECT registry. Sources, reader
results and proposed signatures are in
`docs/plan_context/historic-encoder-bugs-2026-11-05.md`. The owner accepts a
documented upstream producer bug as writer evidence. Each exemplar becomes a
test fixture when its registry entry is implemented. Until then, validate
references them by SHA-256.

| Fixture | SHA-256 | How it was made |
|---|---|---|
| `historic_a2_ffmpeg_jfif_0201.jpg` | `51a2b86d78e6670982897d6c378a0a939ab230aab579034b0a5c66e0d16aabbf` | `baseline_2x2_rgb.jpg` with JFIF version bytes (offsets 11-12) set to `02 01`, as FFmpeg mjpegenc wrote before `b19313218c` |
| `historic_a3_mjpeg_no_dht.jpg` | `3fc8a91bed2bb35fc041542e392d81e133066d3dbd9082429624da42c285f0b8` | `historic_a3_control_with_dht.jpg` with all four DHT segments removed, as MJPEG encoders omit the Annex K.3 tables |
| `historic_a3_control_with_dht.jpg` | `9c1f036c9a781d8a15362a4fa8bddee632016e5232d00c2eb4b5fc8071d89912` | libjpeg-turbo 3.1.4 `cjpeg -quality 75` from `djpeg baseline_16x16_rgb_420.jpg` output; its DHT tables are the K.3 standard tables |
| `historic_a29_cmyk_k_id1.jpg` | `872be376e05b8df089351cf90af108dcc0955078439d00d9cccac2bdd74b3bfb` | `baseline_4x4_cmyk.jpg` with the 4th component's ID set from 4 to 1 in the SOF and in the SOS selector |
| `historic_a16_c2pa_jumbf_le.jpg` | `63b581737b26e5fdc83cd75c43d14c236a16b25d2beea71b9d3c970cfebce573` | `baseline_2x2_rgb.jpg` with an APP11 after SOI: `JP`, En 1, Z 1, then the JUMBF superbox LBox little-endian and TBox `bmuj`, followed by a 17-byte `jumd` box |
| `historic_a16_control_jumbf_be.jpg` | `4890f6dc37732a1d70adf2d8a30b5bfb4395b1ea3f57be3f3d0c8ec90e5e4704` | the same APP11 with a big-endian LBox and TBox `jumb` |
| `historic_a31_iptc_nul.jpg` | `58adae1015c64d18c1cc9864c8f9ed91b7b39986a0523db7b36139fe2047e436` | `baseline_2x2_rgb.jpg` with an APP13 `Photoshop 3.0` 8BIM 0x0404 resource holding IPTC 1:90 and 2:25 Keywords `test\0` (length 5) |
| `historic_a31_control.jpg` | `108b67de0c4e1dfadad09eee4841359161da9239b3ce88814cd752e14639bb5a` | the same, with Keywords `test` (length 4) |
| `historic_b7_ycca_no_markers.jpg` | `fa342e838dea8a05d84bafa2cf10011ec59b69d2bf0064512014eeed11f80392` | a 16x16 four-component YCbCrA image written by a short libjpeg-turbo program, as Oracle documents Java ImageIO's RGBA output: component IDs 1-4, sampling 2x2/1x1/1x1/2x2, `write_JFIF_header` and `write_Adobe_marker` off. JDK 8u504's own writer now refuses RGBA |

A1 (the HP/Microsoft sRGB v2 ICC profile) has no fixture, because the profile
bytes are HP's. It is identified by length and checksum instead.
