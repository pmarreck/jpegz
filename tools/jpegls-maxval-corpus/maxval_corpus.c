// CharLS custom-MAXVAL admission corpus (validate ruling 2026-11-22).
// Writes OUT/p{P}_m{MAXVAL}_n{NEAR}_{content}.jls and the matching .raw
// source samples (u8 for P<=8, little-endian u16 otherwise).
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <charls/charls.h>

enum { W = 32, H = 32 };

static uint32_t sample(int content, int x, int y, uint32_t maxval, uint32_t *rng) {
    switch (content) {
    case 0: return (uint32_t)((x * 37 + y * 91) ^ (x * y)) % (maxval + 1);
    case 1: return (uint32_t)(x + y) * maxval / (W + H - 2);
    case 2: *rng = *rng * 1103515245u + 12345u; return (*rng >> 8) % (maxval + 1);
    default: return (x / 8 + y / 8) % 2 ? maxval / 2 : maxval / 3;
    }
}
static const char *content_name[] = {"formula", "gradient", "noise", "blocks"};

static int encode(const char *out, int P, uint32_t maxval, int near, int content) {
    size_t bps = P <= 8 ? 1 : 2;
    uint8_t *px = malloc(W * H * bps);
    uint32_t rng = 0x6a7065u ^ maxval ^ (uint32_t)near << 20;
    for (int y = 0; y < H; y++)
        for (int x = 0; x < W; x++) {
            uint32_t v = sample(content, x, y, maxval, &rng);
            if (bps == 1) px[y * W + x] = (uint8_t)v;
            else { px[2 * (y * W + x)] = (uint8_t)v; px[2 * (y * W + x) + 1] = (uint8_t)(v >> 8); }
        }
    char path[1024];
    snprintf(path, sizeof path, "%s/p%d_m%u_n%d_%s", out, P, maxval, near, content_name[content]);
    charls_jpegls_encoder *enc = charls_jpegls_encoder_create();
    charls_frame_info fi = {.width = W, .height = H, .bits_per_sample = P, .component_count = 1};
    charls_jpegls_pc_parameters pc = {.maximum_sample_value = (int32_t)maxval};
    size_t cap = W * H * bps * 4 + 1024;
    uint8_t *dest = malloc(cap);
    int rc = charls_jpegls_encoder_set_frame_info(enc, &fi)
          || charls_jpegls_encoder_set_preset_coding_parameters(enc, &pc)
          || (near > 0 && charls_jpegls_encoder_set_near_lossless(enc, near))
          || charls_jpegls_encoder_set_destination_buffer(enc, dest, cap)
          || charls_jpegls_encoder_encode_from_buffer(enc, px, W * H * bps, W * (uint32_t)bps);
    if (rc) {
        fprintf(stderr, "skip %s (charls rc)\n", path);
    } else {
        size_t n = 0;
        charls_jpegls_encoder_get_bytes_written(enc, &n);
        char p2[1100];
        snprintf(p2, sizeof p2, "%s.jls", path);
        FILE *f = fopen(p2, "wb"); fwrite(dest, 1, n, f); fclose(f);
        snprintf(p2, sizeof p2, "%s.raw", path);
        f = fopen(p2, "wb"); fwrite(px, 1, W * H * bps, f); fclose(f);
    }
    charls_jpegls_encoder_destroy(enc);
    free(dest); free(px);
    return rc ? 0 : 1;
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: maxval_corpus OUTDIR [pow2]\n"); return 2; }
    // "pow2": MAXVAL = 2^k - 1 only, the values CharLS's default_traits
    // (bit-mask clamp, log2_ceiling(MAXVAL) bpp) handle correctly.
    const int pow2 = argc > 2;
    static const uint32_t all8[] = {15, 63, 100, 127, 128, 200, 254};
    static const uint32_t all12[] = {255, 1000, 2047, 4000, 4094};
    static const uint32_t p2_8[] = {15, 63, 127};
    static const uint32_t p2_12[] = {255, 1023, 2047};
    const uint32_t *m8 = pow2 ? p2_8 : all8, *m12 = pow2 ? p2_12 : all12;
    const size_t n8 = pow2 ? 3 : 7, n12 = pow2 ? 3 : 5;
    static const int nears[] = {0, 1, 3};
    int written = 0;
    for (int c = 0; c < 4; c++)
        for (int n = 0; n < 3; n++) {
            for (size_t i = 0; i < n8; i++)
                if ((uint32_t)nears[n] <= m8[i] / 2) written += encode(argv[1], 8, m8[i], nears[n], c);
            for (size_t i = 0; i < n12; i++)
                if ((uint32_t)nears[n] <= m12[i] / 2) written += encode(argv[1], 12, m12[i], nears[n], c);
        }
    fprintf(stderr, "wrote %d streams\n", written);
    return 0;
}
