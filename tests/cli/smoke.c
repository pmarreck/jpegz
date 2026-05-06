/* C FFI smoke test for jpegz. Decodes the embedded baseline 2x2
 * fixture via jpegz_decode and asserts the basic shape — proves that
 * external C consumers (validate, tiffz, image tools) can link
 * against the published static library and call its public API.
 *
 * The fixture bytes are inlined so the test is self-contained; no
 * runtime file I/O. Same fixture content as
 * tests/unit/fixtures/baseline_2x2_rgb.jpg.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "jpegz_core.h"

/* baseline_2x2_rgb.jpg, hand-converted from the binary file via xxd. */
static const unsigned char baseline_2x2_rgb[] = {
#embed "../unit/fixtures/baseline_2x2_rgb.jpg"
};
static const size_t baseline_2x2_rgb_len = sizeof(baseline_2x2_rgb);

#define ASSERT(cond, msg) do { \
    if (!(cond)) { \
        fprintf(stderr, "FAIL: %s (line %d): %s\n", \
            msg, __LINE__, jpegz_last_error_message()); \
        return 1; \
    } \
} while (0)

int main(void) {
    /* Version is non-empty. */
    const char *v = jpegz_version();
    ASSERT(v != NULL && v[0] != '\0', "jpegz_version() returns non-empty");

    /* Decode the embedded baseline JPEG. */
    jpegz_image_t img = {0};
    int rc = jpegz_decode(baseline_2x2_rgb, baseline_2x2_rgb_len, &img);
    ASSERT(rc == JPEGZ_OK, "jpegz_decode returned OK");
    ASSERT(img.width == 2, "width == 2");
    ASSERT(img.height == 2, "height == 2");
    ASSERT(img.channels == 3, "channels == 3");
    ASSERT(img.bits_per_sample == 8, "bits_per_sample == 8");
    ASSERT(img.layout == JPEGZ_LAYOUT_RGB, "layout == RGB");
    ASSERT(img.source_color_space == JPEGZ_CS_YCBCR, "source_color_space == YCBCR");
    ASSERT(img.pixels != NULL, "pixels != NULL");
    ASSERT(img.pixels_len == 12, "pixels_len == 12");
    /* (1,1) pixel was input white; quality=90 keeps it >= 240 in all channels. */
    const unsigned char *px11 = &img.pixels[1 * 6 + 1 * 3];
    ASSERT(px11[0] >= 240, "pixel(1,1).R >= 240");
    ASSERT(px11[1] >= 240, "pixel(1,1).G >= 240");
    ASSERT(px11[2] >= 240, "pixel(1,1).B >= 240");
    jpegz_image_free(&img);

    /* Decode rejects empty input with TRUNCATED_STREAM. */
    jpegz_image_t empty_out = {0};
    rc = jpegz_decode((const unsigned char *)"", 0, &empty_out);
    ASSERT(rc == JPEGZ_ERR_TRUNCATED_STREAM, "empty input -> TRUNCATED_STREAM");

    /* Validate the same fixture: PASS, baseline_huffman, 2x2. */
    jpegz_validation_report_t rpt = {0};
    rc = jpegz_validate(baseline_2x2_rgb, baseline_2x2_rgb_len, &rpt);
    ASSERT(rc == JPEGZ_OK, "validate returns OK");
    /* PASS or INFO are both valid (cjpeg-emitted JFIF marker triggers
     * an INFO finding; the file is still well-formed). */
    ASSERT(rpt.overall == JPEGZ_SEVERITY_PASS || rpt.overall == JPEGZ_SEVERITY_INFO,
           "validate overall is PASS or INFO");
    ASSERT(rpt.variant == JPEGZ_VARIANT_BASELINE_HUFFMAN, "variant == baseline_huffman");
    ASSERT(rpt.width == 2, "validate width == 2");
    ASSERT(rpt.height == 2, "validate height == 2");
    /* findings_len may now be > 0 if JFIF/EXIF/etc. were detected;
     * just assert no FAIL findings. */
    int has_fail_finding = 0;
    for (size_t i = 0; i < rpt.findings_len; ++i) {
        if (rpt.findings[i].severity == JPEGZ_SEVERITY_FAIL) has_fail_finding = 1;
    }
    ASSERT(!has_fail_finding, "no FAIL findings on a clean JPEG");
    jpegz_validation_report_free(&rpt);

    /* Validate empty input: FAIL, missing_soi finding. */
    jpegz_validation_report_t rpt_empty = {0};
    rc = jpegz_validate((const unsigned char *)"", 0, &rpt_empty);
    ASSERT(rc == JPEGZ_OK, "validate(empty) returns OK (FAIL is in report)");
    ASSERT(rpt_empty.overall == JPEGZ_SEVERITY_FAIL, "empty -> overall FAIL");
    ASSERT(rpt_empty.findings_len > 0, "empty -> at least one finding");
    int found_missing_soi = 0;
    for (size_t i = 0; i < rpt_empty.findings_len; ++i) {
        if (rpt_empty.findings[i].code == JPEGZ_FINDING_MISSING_SOI) found_missing_soi = 1;
    }
    ASSERT(found_missing_soi, "empty -> MISSING_SOI finding present");
    jpegz_validation_report_free(&rpt_empty);

    printf("PASS: jpegz C FFI smoke (8 assertions across 4 calls)\n");
    return 0;
}
