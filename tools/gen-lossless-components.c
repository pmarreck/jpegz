/* Write multi-component lossless JPEG (SOF3) fixtures with libjpeg-turbo 3.x.
 *
 * usage: gen-lossless-components OUT.jpg COMPONENTS PRECISION WIDTH HEIGHT PREDICTOR RESTART
 *
 * Sample (x, y, c) = (37x + 101y + 53c + 7xy) mod 2^PRECISION, so a test can
 * recompute every expected sample: lossless coding with point transform 0
 * must reproduce them exactly. Components use JCS_UNKNOWN, sampling 1x1,
 * which is the layout of a DNG CFA tile (two components per row pair). */
#include <stdio.h>
#include <stdlib.h>
#include <jpeglib.h>

static void report_code(j_common_ptr cinfo) {
	char buffer[JMSG_LENGTH_MAX];
	(*cinfo->err->format_message)(cinfo, buffer);
	fprintf(stderr, "libjpeg message %d: %s\n", cinfo->err->msg_code, buffer);
}

static unsigned sample(unsigned x, unsigned y, unsigned c, unsigned precision) {
	unsigned long v = 37ul * x + 101ul * y + 53ul * c + 7ul * x * y;
	return (unsigned)(v & ((1ul << precision) - 1));
}

int main(int argc, char **argv) {
	if (argc != 8) {
		fprintf(stderr, "usage: %s OUT COMPONENTS PRECISION WIDTH HEIGHT PREDICTOR RESTART\n", argv[0]);
		return 2;
	}
	int nc = atoi(argv[2]), precision = atoi(argv[3]);
	unsigned width = (unsigned)atoi(argv[4]), height = (unsigned)atoi(argv[5]);
	int predictor = atoi(argv[6]), restart = atoi(argv[7]);
	FILE *out = fopen(argv[1], "wb");
	if (!out) { perror(argv[1]); return 1; }

	struct jpeg_compress_struct cinfo;
	struct jpeg_error_mgr jerr;
	cinfo.err = jpeg_std_error(&jerr);
	jerr.output_message = report_code;
	jpeg_create_compress(&cinfo);
	jpeg_stdio_dest(&cinfo, out);
	cinfo.image_width = width;
	cinfo.image_height = height;
	cinfo.input_components = nc;
	cinfo.in_color_space = JCS_UNKNOWN;
	cinfo.data_precision = precision;
	jpeg_set_defaults(&cinfo);
	jpeg_set_colorspace(&cinfo, JCS_UNKNOWN);
	jpeg_enable_lossless(&cinfo, predictor, 0);
	cinfo.restart_interval = (unsigned)restart;
	jpeg_start_compress(&cinfo, TRUE);

	size_t row_len = (size_t)width * (size_t)nc;
	for (unsigned y = 0; y < height; y++) {
		if (precision <= 8) {
			JSAMPLE *row = malloc(row_len);
			for (unsigned x = 0; x < width; x++)
				for (int c = 0; c < nc; c++) row[x * nc + c] = (JSAMPLE)sample(x, y, (unsigned)c, (unsigned)precision);
			JSAMPROW rows[1] = { row };
			jpeg_write_scanlines(&cinfo, rows, 1);
			free(row);
		} else if (precision <= 12) {
			J12SAMPLE *row = malloc(row_len * sizeof *row);
			for (unsigned x = 0; x < width; x++)
				for (int c = 0; c < nc; c++) row[x * nc + c] = (J12SAMPLE)sample(x, y, (unsigned)c, (unsigned)precision);
			J12SAMPROW rows[1] = { row };
			jpeg12_write_scanlines(&cinfo, rows, 1);
			free(row);
		} else {
			J16SAMPLE *row = malloc(row_len * sizeof *row);
			for (unsigned x = 0; x < width; x++)
				for (int c = 0; c < nc; c++) row[x * nc + c] = (J16SAMPLE)sample(x, y, (unsigned)c, (unsigned)precision);
			J16SAMPROW rows[1] = { row };
			jpeg16_write_scanlines(&cinfo, rows, 1);
			free(row);
		}
	}
	jpeg_finish_compress(&cinfo);
	jpeg_destroy_compress(&cinfo);
	fclose(out);
	return 0;
}
