# Historic encoder bugs: jpegz cases, 2026-11-05

This is the jpegz answer to validate's owner-requested research
(validate `docs/plan_context/historic_encoder_flubs.md`). For each case
assigned to jpegz:
1. confirm the cited source;
2. check what jpegz detects today;
3. build an exemplar from the documented description;
4. propose an exact registry signature with near-match controls.

Nothing here changes jpegz behavior. The registry is validate's. Under the
owner's 2026-11-05 rule, a documented upstream producer bug counts as writer
evidence.

**How the evidence was gathered:**
- **jpegz:** build `f8a1e57`, `jpegz --json`.
- **Reader:** libjpeg-turbo 3.1.4 `djpeg`. Exit 0 means it decoded silently,
  exit 1 means a fatal error, and exit 2 means it decoded with a warning.
- **Exemplars:** kept in the agent scratchpad and identified by SHA-256 below.
  They are not committed. They become fixtures when a registry entry is
  implemented.

## Sources (all confirmed verbatim from primary sources)

| Case | Source read |
|---|---|
| A1 | libpng v1.6.43 `png.c` lines 2269-2283: the "mntr (display) profile with a mediaWhitePointTag that does not match the D50 PCS illuminant" comment, and both `PNG_ICC_CHECKSUM` entries (3144 bytes, `1998/02/09 06:49:00`, Adler-32 `0xf784f3fb` / CRC-32 `0x182ea552` perceptual, `0x0398f3fc` / `0xf29e526d` media-relative). |
| A2 | FFmpeg commit `b19313218c`, "mjpegenc: Fix JFIF version", 2011-06-14T15:16:51Z. It replaces `put_bits(p, 16, 0x0201); /* v 1.02 */` with `0x0102`. |
| A3 | libjpeg-turbo ChangeLog 1.3.90 (1.4 beta1), item 3: "many motion JPEG video frames are encoded without the default Huffman tables". Also `src/jdhuff.c`: "Motion JPEG frames typically do not include the Huffman tables if they are the default tables". |
| A16 | ExifTool Version 12.99 (Oct. 18, 2024): "Patched to recognize C2PA APP11 JUMBF header with incorrect byte order written by buggy Microsoft software". |
| A29 | libjpeg-turbo ChangeLog 1.2.0, item 6: "erroneous CMYK/YCCK JPEGs whose K component is assigned a component ID of 1 instead of 4. Although these files are in violation of the spec, other JPEG implementations handle them correctly." |
| A30 | libjpeg-turbo `src/jdmarker.c`: "Major version must be 1 ... (We used to treat this as an error, but now it's a nonfatal warning, because some bozo at Hijaak couldn't read the spec.)" |
| A31 | ExifTool Version 8.98 (July 28, 2012): "IPTC string-type tags which are incorrectly null terminated (eg. written by Picasa 2.0)". |
| B7 | Oracle Java 8 `jpeg_metadata.html`: "RGBA images are converted to YCbCrA, subsampled in the chrominance channels by half both vertically and horizontally, and written without any special marker segments. The component ids in the frame and scan headers are set to 1, 2, 3, and 4." |

## Results

The "jpegz today" column gives the finding number and code jpegz reports now.

| Case | Exemplar (SHA-256) and route | djpeg | jpegz today | Proposed registry signature | Near-match controls (keep current class) |
|---|---|---|---|---|---|
| A2 FFmpeg/Libav JFIF 2.01 | `51a2b86d…16aabbf`: `baseline_2x2_rgb.jpg` with the version bytes set to `02 01` (a 2-byte change, exact) | exit 2, "Warning: unknown JFIF revision number 2.01" | WARN 67 `jfif_version_unchecked`, valid | KNOWN_DEFECT: a complete JFIF APP0 (`JFIF\0`, 14+ bytes) whose version bytes are exactly `02 01` | `02 00`, `02 02`, `01 03` and `03 01` stay WARN 67; `02 01` in an incomplete APP0 or a JFXX segment raises no finding |
| A30 HiJaak JFIF major ≠ 1 | none: the value is undocumented (partial) | same warning path | WARN 67 for any major > 1 | none beyond A2: without an exact byte value there is no discriminating signature, so WARN 67 covers it | n/a |
| A3 MJPEG without DHT | `3fc8a91b…c42285f0b8`: libjpeg-turbo `cjpeg -quality 75`, then every DHT segment removed. The encoder's DC and AC luma tables were confirmed to be the K.3 standard tables. Control with its DHT: `9c1f036c…c71d89912` | exit 0, silent; pixels identical to the control | FAIL 51 `huffman_table_corrupt`, detail `InvalidMarker`, no offset. **Detection gap:** the generic bucket does not say that no DHT exists | KNOWN_DEFECT: a sequential Huffman frame (SOF0/SOF1) with no DHT segment anywhere, whose scans decode completely with the T.81 Annex K.3 tables. jpegz would need a typed finding and a decode attempt with K.3 tables to confirm the second condition | Only some tables missing; a progressive file without DHT; a no-DHT stream that fails with K.3 tables: all stay FAIL |
| A29 CMYK/YCCK with K ID 1 | `872be376…dd74b3bfb`: `baseline_4x4_cmyk.jpg` with the 4th component ID set to 1 in the SOF and the SOS | exit 0; pixels identical to the original | FAIL 55 `sos_component_mismatch` at the SOS selector, "SOS repeats a component selector Cs". **Detection gap:** the duplicate Ci in the SOF has no typed finding of its own | KNOWN_DEFECT: a 4-component SOF with IDs exactly (1, 2, 3, 1) and an interleaved SOS selecting (1, 2, 3, 1) in that order, resolved by position | Duplicates elsewhere, such as (1, 1, 3, 4) or (1, 2, 1, 4); a 3-component duplicate; SOS selectors in another order: all stay FAIL |
| A16 Microsoft C2PA little-endian JUMBF | `63b58173…cebce573`: APP11 `JP`, En 1, Z 1, then LBox little-endian and TBox `bmuj`, inserted after SOI. Big-endian control: `4890f6dc…e5e4704` | exit 0 | valid, no finding. **Not detected:** APP11 is opaque to jpegz | KNOWN_DEFECT: an APP11 segment whose payload starts `JP`, En, Z, followed by a little-endian LBox with TBox bytes `bmuj` | A big-endian `jumb` header raises no finding; `bmuj` outside a `JP` APP11 raises no finding. Best owned by a JUMBF/C2PA parser (validate's), not the T.81 codec |
| A31 Picasa 2.0 IPTC NUL | `58adae10…fe2047e436`: APP13 `Photoshop 3.0`, 8BIM 0x0404 IPTC, dataset 2:25 Keywords `test\0` (partial: which datasets Picasa wrote is not stated). Control without the NUL: `108b67de…e14639bb5a` | exit 0 | valid, INFO `photoshop_irb_present` only. **Not detected:** IPTC is opaque to jpegz | KNOWN_DEFECT: an IPTC record-2 string dataset whose final value byte is 0x00 | The same dataset without the NUL raises no finding. Best owned by a shared IPTC checker, since TIFF IPTC carries the same bytes |
| A1 HP/Microsoft sRGB v2 | none committed: the profile is HP's copyrighted bytes, identified by checksum rather than built | n/a | INFO `icc_profile_present` only; ICC is not parsed | KNOWN_DEFECT at most: an assembled ICC profile of 3144 bytes matching either libpng checksum pair | Any other sRGB profile. Belongs in a shared ICC check across PNG, JPEG, TIFF and WebP |
| B7 Java ImageIO RGBA | `fa342e83…ec1f80392`: synthesized from Oracle's description with a libjpeg-turbo program (4 components, IDs 1-4, sampling 2x2/1x1/1x1/2x2, no APP markers). JDK 8u504's ImageIO now refuses RGBA ("Invalid argument to native writeImage") | exit 0; decoded as CMYK, the "pink JPEG" | valid, no finding | **No class proposed** (owner ruling first). Analysis: not a T.81 violation; the defect is only visible through a color-model check | n/a |
| B8 Adobe inverted CMYK | existing fixtures `baseline_4x4_cmyk.jpg` and `cmyk_16x16_ycck_subsampled.jpg` | exit 0 | valid | do not flag (de facto convention, standardized by T.872) | n/a |
| B9 JFIF and Exif both present | existing fixture `baseline_4x4_with_exif.jpg` | exit 0 | valid, INFO for both | do not flag (informational at most) | n/a |

## Detection gaps found

1. **A3:** a stream with no DHT reports only the generic decoder bucket. A
   typed reason would let a registry match it. Example: "no DHT segment;
   Huffman table Tc/Th undefined".
2. **A29:** a duplicate component ID inside the SOF has no finding of its own.
   Today it is caught only at the SOS, and only when the SOS repeats the
   selector.

Both are detection additions, so neither weakens an existing check. Either can
be a narrower reason on an existing code, as in row 51b. A new code number
needs a registry decision first.
