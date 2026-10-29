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

#include <assert.h>

#include "jpegz_core.h"

/* The strict-result structs are declared TWICE — once as a Zig `extern struct`
 * in src/ffi/c_api.zig, once as a C struct here in the header. Nothing makes
 * the compiler compare them, so a field added on one side only would not be a
 * compile error: it would be silent memory corruption at the ABI boundary,
 * showing up as garbage offsets or a wild `detail` pointer. Pin the layout
 * mechanically. Update these ONLY alongside a deliberate ABI change. */
/* 4x int/uint32 (16) + 2x int64 (16) + int (4) + 4 pad + pointer (8) = 48. */
static_assert(sizeof(jpegz_strict_finding_t) == 48,
              "jpegz_strict_finding_t layout changed — sync src/ffi/c_api_validate.zig");
static_assert(offsetof(jpegz_strict_finding_t, offset) == 16,
              "jpegz_strict_finding_t.offset moved — sync src/ffi/c_api_validate.zig");
static_assert(offsetof(jpegz_strict_finding_t, detail) == 40,
              "jpegz_strict_finding_t.detail moved — sync src/ffi/c_api_validate.zig");
/* 6x 4-byte scalars (24) + pointer (8) + size_t (8) = 40. */
static_assert(sizeof(jpegz_strict_result_t) == 40,
              "jpegz_strict_result_t layout changed — sync src/ffi/c_api_validate.zig");
static_assert(offsetof(jpegz_strict_result_t, findings) == 24,
              "jpegz_strict_result_t.findings moved — sync src/ffi/c_api_validate.zig");

/* baseline_2x2_rgb.jpg, hand-converted from the binary file via xxd. */
static const unsigned char baseline_2x2_rgb[] = {
#embed "../unit/fixtures/baseline_2x2_rgb.jpg"
};
static const size_t baseline_2x2_rgb_len = sizeof(baseline_2x2_rgb);

static const uint8_t grayscale_4x4[] = {
#embed "../unit/fixtures/baseline_4x4_grayscale.jpg"
};

static const uint8_t zero_padding[] = {
#embed "../unit/fixtures/zero_pad_16x16_420.jpg"
};

/* Counted by the macro rather than hand-tallied in the PASS line: the
 * literal "30 assertions" had already drifted once. A number a human has
 * to remember to bump is a number that lies. */
static int assertions_run = 0;

#define ASSERT(cond, msg) do { \
    assertions_run++; \
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
	{
		jpegz_strict_result_t defect = {0};
		ASSERT(jpegz_validate_any(zero_padding, sizeof zero_padding, &defect) == JPEGZ_OK,
		       "known encoder defect validation completes");
		ASSERT(JPEGZ_VERDICT_KNOWN_DEFECT == 4 && defect.verdict == JPEGZ_VERDICT_KNOWN_DEFECT,
		       "known defect has its own appended verdict");
		ASSERT(strcmp(jpegz_verdict_name(defect.verdict), "known_defect") == 0,
		       "C API names the known-defect classification");
		jpegz_strict_result_free(&defect);
	}
    /* Version is non-empty. */
    const char *v = jpegz_version();
    ASSERT(v != NULL && v[0] != '\0', "jpegz_version() returns non-empty");

    /* Finding codes are nameable through the ABI. Without this, every
     * consumer wanting to report a cause (the jpegz CLI, validate) has to
     * hand-maintain its own code->name table, which silently drifts from
     * src/core/errors.zig the moment a code is appended. */
    {
        const char *n = jpegz_finding_code_name(JPEGZ_FINDING_TRUNCATED_STREAM);
        ASSERT(n != NULL && n[0] != '\0', "finding_code_name returns non-empty");
        ASSERT(strcmp(n, "truncated_stream") == 0,
               "finding_code_name matches the Zig enum tag");
		ASSERT(JPEGZ_FINDING_CBLK_CONTRIBUTION_ENDS_FF == 261,
		       "approved JP2 finding keeps wire value 261 in the generated header");
		ASSERT(strcmp(jpegz_finding_code_name((jpegz_finding_code_t)261),
		              "cblk_contribution_ends_ff") == 0,
		       "approved JP2 finding 261 has its stable C ABI name");
		ASSERT(JPEGZ_FINDING_SEQUENTIAL_SCAN_INVALID == 64 && JPEGZ_FINDING_PROGRESSIVE_SCAN_INVALID == 59,
		       "sequential scan finding appends 64 and preserves progressive 59");
		ASSERT(strcmp(jpegz_finding_code_name((jpegz_finding_code_t)64), "sequential_scan_invalid") == 0,
		       "sequential scan finding has its stable C ABI name");
		ASSERT(JPEGZ_FINDING_JFIF_METADATA_INVALID == 65,
		       "JFIF metadata finding appends its approved wire value");
		ASSERT(strcmp(jpegz_finding_code_name((jpegz_finding_code_t)65), "jfif_metadata_invalid") == 0,
		       "JFIF metadata finding has its stable C ABI name");
		ASSERT(JPEGZ_FINDING_SOF_SAMPLING_INVALID == 66 && JPEGZ_FINDING_JFIF_METADATA_INVALID == 65,
		       "sampling finding appends 66 and preserves metadata 65");
		ASSERT(strcmp(jpegz_finding_code_name((jpegz_finding_code_t)66), "sof_sampling_invalid") == 0,
		       "sampling finding has its stable C ABI name");
		ASSERT(JPEGZ_FINDING_JFIF_VERSION_UNCHECKED == 67 && JPEGZ_FINDING_SOF_SAMPLING_INVALID == 66,
		       "future JFIF coverage finding appends 67 and preserves 66");
		ASSERT(strcmp(jpegz_finding_code_name((jpegz_finding_code_t)67), "jfif_version_unchecked") == 0,
		       "future JFIF coverage finding has its stable C ABI name");

        /* Distinct codes must not collapse onto one string — a table that
         * returns the same label for everything would pass a single-value
         * check while being useless. */
        const char *a = jpegz_finding_code_name(JPEGZ_FINDING_MISSING_SOI);
        const char *b = jpegz_finding_code_name(JPEGZ_FINDING_MISSING_EOI);
        ASSERT(strcmp(a, b) != 0, "distinct finding codes yield distinct names");

        /* A code outside the enum must be handled, not crash or return
         * garbage — findings cross an ABI boundary and a newer library can
         * hand an older consumer a code it has never heard of. */
        const char *u = jpegz_finding_code_name((jpegz_finding_code_t)999999);
        ASSERT(u != NULL && u[0] != '\0', "unknown finding code yields a safe label");
    }
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

    /* ── Strict JPEG-family facade through the ABI ─────────────────
     *
     * The Zig core gained a four-way verdict and family-wide routing; this
     * asserts a C consumer can actually reach them. Without these, `validate`
     * would have to link jp2z and libjxlz itself, which is the fragmentation
     * the facade exists to end. */
    {
        static const uint8_t jp2_sig[] = {
            0x00, 0x00, 0x00, 0x0C, 'j', 'P', ' ', ' ', 0x0D, 0x0A, 0x87, 0x0A
        };
        static const uint8_t jxl_sig[] = {
            0x00, 0x00, 0x00, 0x0C, 'J', 'X', 'L', ' ', 0x0D, 0x0A, 0x87, 0x0A
        };
        static const uint8_t png_sig[] = { 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A };

        /* Sniffing is a classifier, so assert over a set. The JP2 and JXL
         * boxes differ only at bytes 4..8 — a sniffer that keys on anything
         * else still passes a single-format check. */
        ASSERT(jpegz_sniff(baseline_2x2_rgb, baseline_2x2_rgb_len) == JPEGZ_FORMAT_JPEG,
               "sniff: T.81 stream is JPEG");
        ASSERT(jpegz_sniff(jp2_sig, sizeof jp2_sig) == JPEGZ_FORMAT_JPEG2000,
               "sniff: JP2 signature box is JPEG 2000");
        ASSERT(jpegz_sniff(jxl_sig, sizeof jxl_sig) == JPEGZ_FORMAT_JPEG_XL,
               "sniff: JXL signature box is JPEG XL");
        ASSERT(jpegz_sniff(png_sig, sizeof png_sig) == JPEGZ_FORMAT_UNKNOWN,
               "sniff: PNG belongs to no JPEG format");

        jpegz_strict_result_t sr = {0};
        jpegz_status_t src = jpegz_validate_any(baseline_2x2_rgb, baseline_2x2_rgb_len, &sr);
        ASSERT(src == JPEGZ_OK, "validate_any returns OK on a good JPEG");
        ASSERT(sr.verdict == JPEGZ_VERDICT_VALID, "good JPEG is VALID");
        ASSERT(sr.format == JPEGZ_FORMAT_JPEG, "good JPEG routed to the JPEG validator");
        ASSERT(sr.width == 2 && sr.height == 2, "dimensions survive the strict ABI");
        jpegz_strict_result_free(&sr);

        /* Unrecognized input must not read as clean. */
        jpegz_strict_result_t ur = {0};
        ASSERT(jpegz_validate_any(png_sig, sizeof png_sig, &ur) == JPEGZ_OK,
               "validate_any returns OK on foreign bytes");
        ASSERT(ur.verdict == JPEGZ_VERDICT_INDETERMINATE,
               "foreign bytes are INDETERMINATE, not VALID and not CORRUPT");
        ASSERT(ur.format == JPEGZ_FORMAT_UNKNOWN, "foreign bytes have no format");
        ASSERT(ur.findings_len == 1, "an indeterminate result still explains itself");
        ASSERT(strcmp(jpegz_finding_code_name(ur.findings[0].code),
                      "unrecognized_container") == 0,
               "the explanation is unrecognized_container");
        jpegz_strict_result_free(&ur);

		{
			size_t sos = 0;
			for (size_t i = 0; i + 1 < baseline_2x2_rgb_len; i++) {
				if (baseline_2x2_rgb[i] == 0xff && baseline_2x2_rgb[i + 1] == 0xda) { sos = i; break; }
			}
			ASSERT(sos != 0 && sos + 4 < baseline_2x2_rgb_len, "SOS control exists");
			const size_t ss = sos + 5 + 2 * baseline_2x2_rgb[sos + 4];
			ASSERT(ss + 2 < baseline_2x2_rgb_len, "SOS parameter control is complete");
			const struct { size_t byte; uint8_t value; const char *first; const char *second; } cases[] = {
				{0, 7, "Ss=7; required 0", NULL},
				{1, 17, "Se=17; required 63", NULL},
				{2, 0x30, "Ah (high nibble)=3; required 0", NULL},
				{2, 0x05, "Al (low nibble)=5; required 0", NULL},
				{2, 0x21, "Ah (high nibble)=2; required 0", "Al (low nibble)=1; required 0"},
			};
			uint8_t *copy = malloc(baseline_2x2_rgb_len);
			ASSERT(copy != NULL, "SOS control buffer allocated");
			for (size_t c = 0; c < sizeof cases / sizeof cases[0]; c++) {
				memcpy(copy, baseline_2x2_rgb, baseline_2x2_rgb_len);
				copy[ss + cases[c].byte] = cases[c].value;
				jpegz_strict_result_t r = {0};
				ASSERT(jpegz_validate_any(copy, baseline_2x2_rgb_len, &r) == JPEGZ_OK,
				       "invalid SOS validation returns through the ABI");
				ASSERT(r.verdict == JPEGZ_VERDICT_CORRUPT, "invalid sequential SOS is corrupt");
				size_t failures = 0;
				int locations = 1, first = 0, second = cases[c].second == NULL;
				for (size_t i = 0; i < r.findings_len; i++) {
					const jpegz_strict_finding_t f = r.findings[i];
					if (f.severity != JPEGZ_SEVERITY_FAIL) continue;
					failures++;
					locations &= f.code == JPEGZ_FINDING_SEQUENTIAL_SCAN_INVALID && f.offset_is_exact &&
						f.offset == (int64_t)(ss + cases[c].byte) && f.host_offset == f.offset;
					if (f.detail != NULL) {
						first |= strstr(f.detail, cases[c].first) != NULL;
						if (cases[c].second != NULL) second |= strstr(f.detail, cases[c].second) != NULL;
					}
				}
				ASSERT(locations && failures == (cases[c].second == NULL ? 1u : 2u),
				       "SOS causes retain their exact original and host field bytes");
				ASSERT(first && second, "SOS details name fields, observed values and requirements");
				jpegz_strict_result_free(&r);
			}
			free(copy);
		}

		{
			ASSERT(baseline_2x2_rgb_len > 20 && memcmp(baseline_2x2_rgb + 6, "JFIF\0", 5) == 0,
			       "JFIF units control has the complete declared identifier");
			uint8_t *copy = malloc(baseline_2x2_rgb_len);
			ASSERT(copy != NULL, "JFIF units control buffer allocated");
			const uint8_t units[] = {0, 1, 2, 3, 255};
			for (uint8_t minor = 1; minor <= 2; minor++) {
				for (size_t c = 0; c < sizeof units; c++) {
					memcpy(copy, baseline_2x2_rgb, baseline_2x2_rgb_len);
					copy[12] = minor; /* Both evidenced, approved units contracts. */
					copy[13] = units[c];
					jpegz_strict_result_t r = {0};
					ASSERT(jpegz_validate_any(copy, baseline_2x2_rgb_len, &r) == JPEGZ_OK,
					       "JFIF validation returns through the ABI");
					ASSERT(r.verdict == (units[c] <= 2 ? JPEGZ_VERDICT_VALID : JPEGZ_VERDICT_CORRUPT),
					       "JFIF units distinguish valid metadata from a profile violation");
					if (units[c] > 2) {
						size_t failures = 0;
						int exact = 1, detail = 0;
						char observed[32];
						snprintf(observed, sizeof observed, "units=%u", (unsigned)units[c]);
						for (size_t i = 0; i < r.findings_len; i++) {
							const jpegz_strict_finding_t f = r.findings[i];
							if (f.severity != JPEGZ_SEVERITY_FAIL) continue;
							failures++;
							exact &= f.code == JPEGZ_FINDING_JFIF_METADATA_INVALID && f.offset == 13 &&
								f.host_offset == 13 && f.offset_is_exact;
							detail |= f.detail != NULL && strstr(f.detail, observed) != NULL &&
								strstr(f.detail, "0, 1 or 2") != NULL;
						}
						ASSERT(exact && failures == 1, "JFIF profile violation retains exact original and host metadata bytes");
						ASSERT(detail, "JFIF metadata detail gives observed and allowed unit values");
					}
					jpegz_strict_result_free(&r);
				}
			}
			free(copy);
		}

		{
			const struct { uint8_t factor; size_t failures; const char *first; const char *second; } cases[] = {
				{0x11, 0, NULL, NULL},
				{0x10, 1, "Vi (low nibble)=0", NULL},
				{0x01, 1, "Hi (high nibble)=0", NULL},
				{0xee, 2, "Hi (high nibble)=14", "Vi (low nibble)=14"},
				{0x44, 0, NULL, NULL},
			};
			const size_t factor_offset = 100;
			ASSERT(sizeof grayscale_4x4 > factor_offset && grayscale_4x4[89] == 255 &&
			       grayscale_4x4[90] == 0xc0 && grayscale_4x4[98] == 1,
			       "single-component SOF sampling fixture has its declared shape");
			uint8_t *copy = malloc(sizeof grayscale_4x4);
			ASSERT(copy != NULL, "sampling fixture buffer allocated");
			for (uint8_t sof = 0xc0; sof <= 0xc1; sof++) {
				for (size_t c = 0; c < sizeof cases / sizeof cases[0]; c++) {
					memcpy(copy, grayscale_4x4, sizeof grayscale_4x4);
					copy[90] = sof;
					copy[factor_offset] = cases[c].factor;
					jpegz_strict_result_t r = {0};
					ASSERT(jpegz_validate_any(copy, sizeof grayscale_4x4, &r) == JPEGZ_OK,
					       "sampling validation returns through the ABI");
					ASSERT(r.verdict == (cases[c].failures == 0 ? JPEGZ_VERDICT_VALID : JPEGZ_VERDICT_CORRUPT),
					       "sampling factor bounds distinguish validity from corruption");
					size_t failures = 0;
					int exact = 1, first = cases[c].first == NULL, second = cases[c].second == NULL;
					for (size_t i = 0; i < r.findings_len; i++) {
						const jpegz_strict_finding_t f = r.findings[i];
						if (f.severity != JPEGZ_SEVERITY_FAIL) continue;
						failures++;
						exact &= f.code == JPEGZ_FINDING_SOF_SAMPLING_INVALID && f.offset == 100 &&
							f.host_offset == 100 && f.offset_is_exact;
						if (f.detail != NULL && strstr(f.detail, "component ID 1") != NULL &&
							strstr(f.detail, "allowed 1..4") != NULL) {
							if (cases[c].first != NULL) first |= strstr(f.detail, cases[c].first) != NULL;
							if (cases[c].second != NULL) second |= strstr(f.detail, cases[c].second) != NULL;
						}
					}
					ASSERT(exact && failures == cases[c].failures, "sampling findings retain exact original and host factor bytes");
					ASSERT(first && second, "sampling details retain component, nibble and allowed range");
					jpegz_strict_result_free(&r);
				}
			}
			free(copy);
		}

		{
			uint8_t *copy = malloc(baseline_2x2_rgb_len);
			ASSERT(copy != NULL, "segment extent control buffer allocated");
			memcpy(copy, baseline_2x2_rgb, baseline_2x2_rgb_len);
			copy[4] = 255;
			copy[5] = 255;
			jpegz_strict_result_t r = {0};
			ASSERT(jpegz_validate_any(copy, baseline_2x2_rgb_len, &r) == JPEGZ_OK,
			       "declared segment extent validates through the ABI");
			ASSERT(r.verdict == JPEGZ_VERDICT_CORRUPT && r.findings_len == 1,
			       "a segment beyond the input retains its corrupt verdict and single cause");
			const jpegz_strict_finding_t f = r.findings[0];
			ASSERT(f.code == JPEGZ_FINDING_TRUNCATED_STREAM && f.offset == INT64_MIN &&
			       f.host_offset == INT64_MIN && !f.offset_is_exact,
			       "a declared segment extent is not exposed as an input byte");
			ASSERT(f.detail != NULL && strstr(f.detail, "65539") != NULL,
			       "declared segment extent remains available in diagnostic detail");
			jpegz_strict_result_free(&r);
			free(copy);
		}

		{
			const struct { uint8_t major, minor; size_t offset; } cases[] = {
				{1, 3, 12}, {1, 255, 12}, {2, 0, 11}, {254, 1, 11},
			};
			uint8_t *copy = malloc(baseline_2x2_rgb_len);
			ASSERT(copy != NULL, "future JFIF control buffer allocated");
			for (size_t c = 0; c < sizeof cases / sizeof cases[0]; c++) {
				memcpy(copy, baseline_2x2_rgb, baseline_2x2_rgb_len);
				copy[11] = cases[c].major;
				copy[12] = cases[c].minor;
				copy[13] = 255;
				jpegz_strict_result_t r = {0};
				ASSERT(jpegz_validate_any(copy, baseline_2x2_rgb_len, &r) == JPEGZ_OK,
				       "future JFIF validation returns through the ABI");
				ASSERT(r.verdict == JPEGZ_VERDICT_INDETERMINATE,
				       "future metadata semantics are inconclusive without claiming corruption");
				size_t notices = 0;
				int correct = 1;
				char observed[32];
				snprintf(observed, sizeof observed, "JFIF version %u.%02u", cases[c].major, cases[c].minor);
				for (size_t i = 0; i < r.findings_len; i++) {
					const jpegz_strict_finding_t f = r.findings[i];
					correct &= f.severity != JPEGZ_SEVERITY_FAIL;
					if (f.code != JPEGZ_FINDING_JFIF_VERSION_UNCHECKED) continue;
					notices++;
					correct &= f.severity == JPEGZ_SEVERITY_WARN && f.offset == (int64_t)cases[c].offset &&
						f.host_offset == f.offset && f.offset_is_exact;
					correct &= f.detail != NULL && strstr(f.detail, observed) != NULL &&
						strstr(f.detail, "metadata semantics are unchecked") != NULL;
				}
				ASSERT(correct && notices == 1, "future JFIF notice retains its severity and exact version byte");
				jpegz_strict_result_free(&r);
			}
			free(copy);
		}

        /* A truncated JPEG is genuine damage — the gate must be able to fire. */
        jpegz_strict_result_t cr = {0};
        ASSERT(jpegz_validate_any(baseline_2x2_rgb, baseline_2x2_rgb_len / 2, &cr) == JPEGZ_OK,
               "validate_any returns OK on a truncated JPEG");
        ASSERT(cr.verdict == JPEGZ_VERDICT_CORRUPT, "a truncated JPEG is CORRUPT");
        ASSERT(cr.findings_len > 0, "a corrupt verdict names at least one finding");
        jpegz_strict_result_free(&cr);

        ASSERT(strcmp(jpegz_verdict_name(JPEGZ_VERDICT_VALID), "valid") == 0,
               "verdict names are stable strings");
        ASSERT(strcmp(jpegz_verdict_name(JPEGZ_VERDICT_INDETERMINATE), "indeterminate") == 0,
               "indeterminate has its own name");
        ASSERT(strcmp(jpegz_validation_format_name(JPEGZ_FORMAT_JPEG_XL), "jpeg_xl") == 0,
               "format names are stable strings");

        /* Freeing a zero-initialized result is a no-op, not a crash. */
        jpegz_strict_result_t zeroed = {0};
        jpegz_strict_result_free(&zeroed);
        ASSERT(zeroed.findings_len == 0, "freeing a zeroed strict result is safe");
    }

    printf("PASS: jpegz C FFI smoke (%d assertions, decode + streaming + validate + findings)\n",
           assertions_run);
    return 0;
}
