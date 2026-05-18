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

/* Streaming-rows test helpers — hoisted to file scope because C23
 * doesn't allow nested functions (GCC extension only). */
typedef struct {
    uint8_t buf[12];      /* 2 * 2 * 3 channels for the baseline fixture */
    uint32_t rows_seen;
    int32_t last_y;
    int in_order;
} stream_collector_t;

static int stream_collect_cb(void *ctx, const uint8_t *row, size_t row_len, uint32_t y) {
    stream_collector_t *c = (stream_collector_t *)ctx;
    if ((int32_t)y <= c->last_y) c->in_order = 0;
    c->last_y = (int32_t)y;
    memcpy(c->buf + (size_t)y * row_len, row, row_len);
    c->rows_seen++;
    return 0;
}

static int stream_abort_cb(void *ctx, const uint8_t *row, size_t row_len, uint32_t y) {
    (void)ctx; (void)row; (void)row_len; (void)y;
    return 42;  /* caller-defined non-zero — preserved in last_error_message */
}

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

    /* M2.1d threading-control surface: jpegz_decode_ex with NULL options
     * is equivalent to jpegz_decode (default threads=1). */
    jpegz_image_t img_ex_null = {0};
    rc = jpegz_decode_ex(baseline_2x2_rgb, baseline_2x2_rgb_len, NULL, &img_ex_null);
    ASSERT(rc == JPEGZ_OK, "jpegz_decode_ex(NULL options) returns OK");
    ASSERT(img_ex_null.width == 2 && img_ex_null.height == 2,
           "jpegz_decode_ex(NULL) shape matches");
    jpegz_image_free(&img_ex_null);

    /* jpegz_decode_ex with explicit options: threads=4 currently no-op
     * but contract is "any value still decodes correctly". Reserved
     * bytes must be zero-initialized — the {0} struct initializer
     * handles that by setting `reserved` to all zeros. */
    jpegz_decode_options_t opts4 = {0};
    opts4.threads = 4;
    jpegz_image_t img_t4 = {0};
    rc = jpegz_decode_ex(baseline_2x2_rgb, baseline_2x2_rgb_len, &opts4, &img_t4);
    ASSERT(rc == JPEGZ_OK, "jpegz_decode_ex(threads=4) returns OK");
    ASSERT(img_t4.pixels_len == 12, "jpegz_decode_ex(threads=4) pixels_len == 12");
    jpegz_image_free(&img_t4);

    /* threads=0 is the explicit caller-opt-in to library-side
     * auto-detection. Today no-op but must produce same output. */
    jpegz_decode_options_t opts_auto = {0};
    opts_auto.threads = 0;
    jpegz_image_t img_auto = {0};
    rc = jpegz_decode_ex(baseline_2x2_rgb, baseline_2x2_rgb_len, &opts_auto, &img_auto);
    ASSERT(rc == JPEGZ_OK, "jpegz_decode_ex(threads=0 auto) returns OK");
    jpegz_image_free(&img_auto);

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

    /* Streaming-rows C ABI: rows delivered in raster order. */
    {
        /* Reference decode for byte-equality assertion. */
        jpegz_image_t ref = {0};
        rc = jpegz_decode(baseline_2x2_rgb, baseline_2x2_rgb_len, &ref);
        ASSERT(rc == JPEGZ_OK, "ref decode OK");

        stream_collector_t col = { .last_y = -1, .in_order = 1 };
        jpegz_image_metadata_t meta = {0};
        rc = jpegz_decode_streaming_rows(
            baseline_2x2_rgb, baseline_2x2_rgb_len, stream_collect_cb, &col, &meta);
        ASSERT(rc == JPEGZ_OK, "streaming returns OK");
        ASSERT(meta.width == 2 && meta.height == 2, "streaming meta dims");
        ASSERT(meta.channels == 3, "streaming meta channels");
        ASSERT(col.rows_seen == 2, "streaming saw 2 rows");
        ASSERT(col.in_order, "streaming rows in raster order");
        ASSERT(memcmp(col.buf, ref.pixels, 12) == 0, "streaming bytes == decode bytes");
        jpegz_image_free(&ref);

        /* Callback abort: non-zero return → CALLBACK_ABORTED, detail preserved. */
        rc = jpegz_decode_streaming_rows(
            baseline_2x2_rgb, baseline_2x2_rgb_len, stream_abort_cb, NULL, NULL);
        ASSERT(rc == JPEGZ_ERR_CALLBACK_ABORTED, "abort returns CALLBACK_ABORTED");
        const char *msg = jpegz_last_error_message();
        ASSERT(msg != NULL && strstr(msg, "42") != NULL,
               "abort preserves return code in last_error_message");
    }

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

    /* ── Lenient mode + FindingsSink C ABI ────────────────────────
     * Truncated baseline + lenient=1 + sink → decode returns partial
     * pixels and the sink collects a Finding(.warn, .insufficient_data).
     * Strict-by-default is unchanged (other tests above already
     * exercise the strict path).
     *
     * This block doubles as the canonical C usage example for
     * external consumers. */
    {
        /* Build truncated copy: drop last 24 entropy bytes, re-attach EOI. */
        const size_t cut = 24;
        const size_t corrupt_len = baseline_2x2_rgb_len - cut;
        uint8_t corrupted[2048]; /* fixture is ~690 bytes; ample room */
        ASSERT(corrupt_len <= sizeof(corrupted), "corrupted fits scratch");
        memcpy(corrupted, baseline_2x2_rgb, corrupt_len - 2);
        corrupted[corrupt_len - 2] = 0xFF;
        corrupted[corrupt_len - 1] = 0xD9;

        jpegz_findings_sink_t *sink = jpegz_findings_sink_create();
        ASSERT(sink != NULL, "findings_sink_create returns non-NULL");
        ASSERT(jpegz_findings_sink_count(sink) == 0, "fresh sink is empty");

        jpegz_decode_options_t opts = {0};
        opts.lenient = 1;

        jpegz_image_t lenient_img = {0};
        rc = jpegz_decode_with_findings(corrupted, corrupt_len, &opts, sink, &lenient_img);
        ASSERT(rc == JPEGZ_OK, "lenient decode with findings returns OK");
        ASSERT(lenient_img.width == 2 && lenient_img.height == 2,
               "lenient decode preserved image shape");
        jpegz_image_free(&lenient_img);

        const size_t n = jpegz_findings_sink_count(sink);
        ASSERT(n >= 1, "sink received at least one finding");
        int saw_insufficient = 0;
        for (size_t i = 0; i < n; i++) {
            jpegz_sink_finding_t f = {0};
            rc = jpegz_findings_sink_get(sink, i, &f);
            ASSERT(rc == JPEGZ_OK, "findings_sink_get returns OK for valid idx");
            if (f.severity == JPEGZ_SEVERITY_WARN &&
                f.code == JPEGZ_FINDING_INSUFFICIENT_DATA) {
                saw_insufficient = 1;
            }
        }
        ASSERT(saw_insufficient, "sink contains insufficient_data warn");

        /* Out-of-range index is a soft error, not a crash. */
        jpegz_sink_finding_t bad = {0};
        rc = jpegz_findings_sink_get(sink, n, &bad);
        ASSERT(rc != JPEGZ_OK, "findings_sink_get rejects out-of-range idx");

        jpegz_findings_sink_free(sink);
    }

    printf("PASS: jpegz C FFI smoke (30 assertions, decode + streaming + validate + findings)\n");
    return 0;
}
