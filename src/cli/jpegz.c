/* jpegz — validate JPEG-family files and report *why* they are broken.
 *
 * This CLI exists to dogfood `include/jpegz_core.h`. It is written in C, not
 * Zig, on purpose: C cannot `@import` the Zig module, so bypassing the FFI is
 * inexpressible here rather than merely discouraged. Every consumer of jpegz
 * (validate, tiffz, anything downstream) crosses the same boundary this
 * program crosses, so a defect in the ABI surfaces here first.
 *
 * Scope is deliberately VALIDATION ONLY — no decode, convert, or encode
 * subcommands. jpegz is the outward-facing interface for the whole JPEG
 * family, and the thing worth exposing at a terminal is the unified error
 * vocabulary.
 *
 * Exit codes:
 *   0  every input was valid
 *   1  at least one input was CORRUPT
 *   2  usage or I/O error (could not even attempt validation)
 *   3  nothing corrupt, but at least one input was unsupported or
 *      indeterminate — "I could not check this" must not read as "fine"
 *
 * Verdicts go to stdout; diagnostics about the run go to stderr.
 */

/* We compile with strict -std=c23, which hides POSIX declarations. isatty()
 * and fileno() are POSIX, and we need them to decide whether decoration is
 * safe (never colorize a pipe). Must precede every #include. */
#if !defined(_WIN32)
#define _POSIX_C_SOURCE 200809L
#endif

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>
#include <errno.h>

#if defined(_WIN32)
#include <io.h>
#define isatty _isatty
#define fileno _fileno
#else
#include <unistd.h>
#endif

#include "jpegz_core.h"

#define EXIT_OK 0
#define EXIT_INVALID 1
#define EXIT_USAGE 2
/* Nothing was found damaged, but at least one input could not be given a
 * clean bill of health either — an unsupported feature or an unrecognized
 * container. Distinct from 0 so a script does not read "I could not check
 * this" as "this is fine", and distinct from 1 so it is not reported to a
 * user as corruption. */
#define EXIT_INCONCLUSIVE 3

/* Largest input we will buffer. jpegz borrows the buffer for the call only,
 * so this bounds memory, not correctness. */
#define MAX_INPUT_BYTES ((size_t)1 << 31)
#define STDIN_CHUNK ((size_t)1 << 16)

typedef struct {
    bool json;
    bool color;
    bool ansi;
    bool quiet;
} options_t;

/* ── Presentation ─────────────────────────────────────────────────── */

static const char *sev_label(jpegz_severity_t s) {
    switch (s) {
    case JPEGZ_SEVERITY_PASS: return "PASS";
    case JPEGZ_SEVERITY_INFO: return "INFO";
    case JPEGZ_SEVERITY_WARN: return "WARN";
    case JPEGZ_SEVERITY_FAIL: return "FAIL";
    }
    return "????";
}

/* Empty strings when color is off, so every call site stays branch-free. */
static const char *sev_color(jpegz_severity_t s, const options_t *o) {
    if (!o->color) return "";
    switch (s) {
    case JPEGZ_SEVERITY_PASS: return "\033[32m";
    case JPEGZ_SEVERITY_INFO: return "\033[36m";
    case JPEGZ_SEVERITY_WARN: return "\033[33m";
    case JPEGZ_SEVERITY_FAIL: return "\033[31m";
    }
    return "";
}

static const char *color_reset(const options_t *o) { return o->color ? "\033[0m" : ""; }
static const char *color_dim(const options_t *o) { return o->color ? "\033[2m" : ""; }
static const char *color_bold(const options_t *o) { return o->color ? "\033[1m" : ""; }

static const char *variant_name(jpegz_variant_t v) {
    switch (v) {
    case JPEGZ_VARIANT_UNKNOWN:                return "unknown";
    case JPEGZ_VARIANT_BASELINE_HUFFMAN:       return "baseline (huffman)";
    case JPEGZ_VARIANT_EXTENDED_HUFFMAN:       return "extended sequential (huffman)";
    case JPEGZ_VARIANT_PROGRESSIVE_HUFFMAN:    return "progressive (huffman)";
    case JPEGZ_VARIANT_LOSSLESS_HUFFMAN:       return "lossless (huffman)";
    case JPEGZ_VARIANT_BASELINE_ARITHMETIC:    return "baseline (arithmetic)";
    case JPEGZ_VARIANT_PROGRESSIVE_ARITHMETIC: return "progressive (arithmetic)";
    case JPEGZ_VARIANT_LOSSLESS_ARITHMETIC:    return "lossless (arithmetic)";
    case JPEGZ_VARIANT_JPEGLS:                 return "JPEG-LS";
    case JPEGZ_VARIANT_JPEG2000:               return "JPEG 2000";
    case JPEGZ_VARIANT_JPEG_XL:                return "JPEG XL";
    }
    return "unknown";
}

/* ── JSON ─────────────────────────────────────────────────────────── */

/* RFC 8259 string escaping. Detail strings originate in the library and can
 * contain quotes or control bytes; emitting them raw would produce JSON that
 * silently fails to parse downstream. */
static void json_puts(FILE *f, const char *s) {
    fputc('"', f);
    for (const unsigned char *p = (const unsigned char *)s; *p; p++) {
        switch (*p) {
        case '"':  fputs("\\\"", f); break;
        case '\\': fputs("\\\\", f); break;
        case '\n': fputs("\\n", f); break;
        case '\r': fputs("\\r", f); break;
        case '\t': fputs("\\t", f); break;
        default:
            if (*p < 0x20) fprintf(f, "\\u%04x", *p);
            else fputc(*p, f); /* UTF-8 passes through unchanged */
        }
    }
    fputc('"', f);
}

/* ── Input ────────────────────────────────────────────────────────── */

static bool is_stdin_path(const char *p) {
    return strcmp(p, "-") == 0 || strcmp(p, "@stdin") == 0;
}

/* Returns malloc'd buffer, or NULL with a message already on stderr. */
static uint8_t *read_all(const char *path, size_t *out_len) {
    FILE *f = NULL;
    bool from_stdin = is_stdin_path(path);

    if (from_stdin) {
        f = stdin;
    } else {
        f = fopen(path, "rb");
        if (!f) {
            fprintf(stderr, "jpegz: cannot open '%s': %s\n", path, strerror(errno));
            return NULL;
        }
    }

    size_t cap = STDIN_CHUNK, len = 0;
    uint8_t *buf = (uint8_t *)malloc(cap);
    if (!buf) {
        if (!from_stdin) fclose(f);
        fprintf(stderr, "jpegz: out of memory reading '%s'\n", path);
        return NULL;
    }

    for (;;) {
        if (len == cap) {
            if (cap >= MAX_INPUT_BYTES) {
                fprintf(stderr, "jpegz: '%s' exceeds the %zu-byte input limit\n",
                        path, MAX_INPUT_BYTES);
                free(buf);
                if (!from_stdin) fclose(f);
                return NULL;
            }
            size_t ncap = cap * 2;
            uint8_t *nbuf = (uint8_t *)realloc(buf, ncap);
            if (!nbuf) {
                free(buf);
                if (!from_stdin) fclose(f);
                fprintf(stderr, "jpegz: out of memory reading '%s'\n", path);
                return NULL;
            }
            buf = nbuf;
            cap = ncap;
        }
        size_t got = fread(buf + len, 1, cap - len, f);
        len += got;
        if (got == 0) {
            if (ferror(f)) {
                fprintf(stderr, "jpegz: read error on '%s'\n", path);
                free(buf);
                if (!from_stdin) fclose(f);
                return NULL;
            }
            break; /* EOF */
        }
    }

    if (!from_stdin) fclose(f);
    *out_len = len;
    return buf;
}

/* ── Verdict presentation ─────────────────────────────────────────── */

/* Container sniffing used to live here, in C, and knew only JPEG and JPEG
 * 2000 — so a JPEG XL file was unreachable and anything unrecognized fell
 * through to the T.81 path and got described in T.81 vocabulary. Routing is
 * now `jpegz_validate_any`, which keeps one answer for the whole family and
 * lets every consumer of the FFI inherit it instead of re-deriving it. */

static const char *verdict_label(int verdict) {
    return jpegz_verdict_name(verdict);
}

static const char *verdict_color(int verdict, const options_t *o) {
    if (!o->color) return "";
    switch (verdict) {
    case JPEGZ_VERDICT_VALID:         return "\033[32m"; /* green  */
    case JPEGZ_VERDICT_CORRUPT:       return "\033[31m"; /* red    */
    case JPEGZ_VERDICT_UNSUPPORTED:   return "\033[36m"; /* cyan   */
    case JPEGZ_VERDICT_INDETERMINATE: return "\033[33m"; /* yellow */
    default:                          return "";
    }
}

/* ── Reporting ────────────────────────────────────────────────────── */

static void print_human(const char *path, const jpegz_strict_result_t *r,
                        const options_t *o) {
    printf("%s%s%s: %s%s%s",
           color_bold(o), path, color_reset(o),
           verdict_color(r->verdict, o), verdict_label(r->verdict), color_reset(o));

    if (r->width && r->height) {
        printf("  %ux%u", r->width, r->height);
    }
    /* Prefer the variant: "baseline (Huffman)" tells the user more than
     * "jpeg". Fall back to the format when no variant was detected, so a JXL
     * or an unparseable file still says which validator answered. */
    if (r->variant != JPEGZ_VARIANT_UNKNOWN) {
        printf("  %s%s%s", color_dim(o), variant_name(r->variant), color_reset(o));
    } else if (r->format != JPEGZ_FORMAT_UNKNOWN) {
        printf("  %s%s%s", color_dim(o),
               jpegz_validation_format_name(r->format), color_reset(o));
    }
    printf("\n");

    for (size_t i = 0; i < r->findings_len; i++) {
        const jpegz_strict_finding_t *f = &r->findings[i];
        /* INT64_MIN is the library's "not applicable" sentinel — printing it
         * as a byte offset would be worse than printing nothing. */
        bool has_offset = f->offset != INT64_MIN;

        printf("  %s%s%s %s",
               sev_color(f->severity, o), sev_label(f->severity), color_reset(o),
               jpegz_finding_code_name(f->code));

        /* A code jpegz has no name for still has the leaf's own number, which
         * is what makes a bug report against jp2z or libjxlz actionable. */
        if (f->code == JPEGZ_FINDING_UNMAPPED) {
            printf(" %s(leaf %u)%s", color_dim(o), f->leaf_code, color_reset(o));
        }
        if (has_offset) {
            printf(" %s@%lld%s", color_dim(o), (long long)f->offset, color_reset(o));
        }
        if (f->detail && f->detail[0]) {
            printf(" — %s", f->detail);
        }
        printf("\n");
    }
}

static void print_json(const char *path, const jpegz_strict_result_t *r) {
    printf("{");
    printf("\"file\":");        json_puts(stdout, path);
    printf(",\"verdict\":");    json_puts(stdout, verdict_label(r->verdict));
    printf(",\"format\":");     json_puts(stdout, jpegz_validation_format_name(r->format));
    printf(",\"variant\":");    json_puts(stdout, variant_name(r->variant));
    printf(",\"width\":%u", r->width);
    printf(",\"height\":%u", r->height);
    printf(",\"frames_validated\":%u", r->frames_validated);
    printf(",\"findings\":[");
    for (size_t i = 0; i < r->findings_len; i++) {
        const jpegz_strict_finding_t *f = &r->findings[i];
        if (i) printf(",");
        printf("{\"severity\":");
        json_puts(stdout, sev_label(f->severity));
        printf(",\"code\":");
        json_puts(stdout, jpegz_finding_code_name(f->code));
        printf(",\"code_number\":%d", (int)f->code);
        printf(",\"leaf_code\":%u", f->leaf_code);
        if (f->offset != INT64_MIN) printf(",\"offset\":%lld", (long long)f->offset);
        else printf(",\"offset\":null");
        if (f->host_offset != INT64_MIN) printf(",\"host_offset\":%lld", (long long)f->host_offset);
        else printf(",\"host_offset\":null");
        printf(",\"offset_is_exact\":%s", f->offset_is_exact ? "true" : "false");
        printf(",\"detail\":");
        if (f->detail) json_puts(stdout, f->detail); else printf("null");
        printf("}");
    }
    printf("]}\n");
}

/* ── Usage ────────────────────────────────────────────────────────── */

static const char *platform_name(void) {
#if defined(__linux__)
    return "linux";
#elif defined(__APPLE__)
    return "macos";
#elif defined(_WIN32)
    return "windows";
#else
    return "unknown";
#endif
}

static const char *arch_name(void) {
#if defined(__aarch64__) || defined(_M_ARM64)
    return "aarch64";
#elif defined(__x86_64__) || defined(_M_X64)
    return "x86_64";
#else
    return "unknown";
#endif
}

static void print_about(void) {
    printf("jpegz %s — JPEG-family validator (JPEG/JPEG-LS/JPEG 2000) [%s-%s]\n",
           jpegz_version(), platform_name(), arch_name());
}

static void print_help(void) {
    printf(
        "jpegz — validate JPEG-family files and report why they are broken.\n"
        "\n"
        "USAGE:\n"
        "  jpegz [options] <file>...\n"
        "\n"
        "  Reads stdin when <file> is '-' or '@stdin'. Everything after '--'\n"
        "  is treated as a path, never a switch.\n"
        "\n"
        "OPTIONS:\n"
        "  -h, --help        Show this help and exit.\n"
        "      --about       One-line version / platform summary and exit.\n"
        "      --json        Emit one JSON object per input on stdout.\n"
        "      --no-json     Disable JSON (default).\n"
        "      --color       Force ANSI color on, even when piped.\n"
        "      --ansi        Alias for --color.\n"
        "      --no-color    Suppress ANSI color.\n"
        "      --no-ansi     Suppress all ANSI sequences.\n"
        "      --simple      Plain ASCII, no color or decoration.\n"
        "      --lang CODE   UI language, e.g. --lang fr. Overrides JPEGZ_LANG,\n"
        "                    which overrides the system locale.\n"
        "  -q, --quiet       Suppress per-file output; exit code only.\n"
        "\n"
        "  Later options override earlier ones. Non-positional options may\n"
        "  appear in any order.\n"
        "\n"
        "VERDICTS:\n"
        "  valid          no problems found\n"
        "  corrupt        the file is damaged\n"
        "  unsupported    well-formed, but uses a feature jpegz cannot check\n"
        "  indeterminate  no conclusion reached (unrecognized container,\n"
        "                 resource limit, or an untyped validator error)\n"
        "\n"
        "EXIT CODES:\n"
        "  0  every input was valid\n"
        "  1  at least one input was CORRUPT\n"
        "  2  usage or I/O error\n"
        "  3  nothing corrupt, but at least one input was unsupported or\n"
        "     indeterminate\n"
        "\n"
        "FORMATS:\n"
        "  JPEG and JPEG-LS (T.81 / T.87), JPEG 2000 (T.800, via jp2z), and\n"
        "  JPEG XL (ISO/IEC 18181, via libjxlz). The container is detected\n"
        "  from its signature; you do not have to say which you have.\n"
        "\n"
        "Validation only by design; jpegz does not decode or convert here.\n");
}

/* ── Main ─────────────────────────────────────────────────────────── */

int main(int argc, char **argv) {
#ifndef NDEBUG
    if (!getenv("MUTE_DEBUG_STATUS")) {
        /* The banner must precede argument parsing (it warns about the binary
         * itself, regardless of what is being asked of it), but it still has
         * to honor the decoration switches — so pre-scan argv rather than
         * hardcoding escapes. It also writes to stderr, so its color is
         * gated on stderr being a terminal, NOT stdout: `jpegz f > out.txt`
         * on a real terminal should still colorize the warning, while
         * capturing stderr must not inject escapes into the capture. */
        bool banner_color = isatty(fileno(stderr)) ? true : false;
        for (int i = 1; i < argc; i++) {
            if (strcmp(argv[i], "--") == 0) break;
            if (strcmp(argv[i], "--no-color") == 0 ||
                strcmp(argv[i], "--no-ansi") == 0 ||
                strcmp(argv[i], "--simple") == 0) {
                banner_color = false;
            } else if (strcmp(argv[i], "--color") == 0 ||
                       strcmp(argv[i], "--ansi") == 0) {
                banner_color = true; /* later-wins, same as the real parser */
            }
        }
        if (banner_color) fputs("\033[33mDEBUG BUILD\033[0m\n", stderr);
        else fputs("DEBUG BUILD\n", stderr);
    }
#endif
    options_t opt = {
        .json = false,
        /* Decoration is opt-out, but only when stdout is a terminal — piping
         * to another tool must not inject escape sequences. */
        .color = isatty(fileno(stdout)) ? true : false,
        .ansi = isatty(fileno(stdout)) ? true : false,
        .quiet = false,
    };

    const char **paths = (const char **)calloc((size_t)argc, sizeof(char *));
    if (!paths) {
        fprintf(stderr, "jpegz: out of memory\n");
        return EXIT_USAGE;
    }
    size_t npaths = 0;
    bool only_paths = false;
    /* Collected during parsing, resolved once afterwards so that later
     * arguments override earlier ones like every other switch. */
    const char *lang_arg = NULL;

    for (int i = 1; i < argc; i++) {
        const char *a = argv[i];

        if (!only_paths && strcmp(a, "--") == 0) { only_paths = true; continue; }

        /* '-' alone means stdin, so it must be tested before the switch
         * prefix check or it would be parsed as an empty option. */
        if (only_paths || a[0] != '-' || is_stdin_path(a)) {
            paths[npaths++] = a;
            continue;
        }

        if (strcmp(a, "-h") == 0 || strcmp(a, "--help") == 0) {
            print_help(); free(paths); return EXIT_OK;
        } else if (strcmp(a, "--about") == 0) {
            print_about(); free(paths); return EXIT_OK;
        } else if (strcmp(a, "--json") == 0) {
            opt.json = true;
        } else if (strcmp(a, "--no-json") == 0) {
            opt.json = false;
        } else if (strcmp(a, "--color") == 0 || strcmp(a, "--ansi") == 0) {
            /* Force decoration on. Needed because the default is "on only if
             * stdout is a terminal", which is right for pipes but leaves no
             * way to colorize output headed for a pager or a captured log.
             * Color implies ANSI — it is delivered as escape sequences. */
            opt.color = true;
            opt.ansi = true;
        } else if (strcmp(a, "--no-color") == 0) {
            opt.color = false;
        } else if (strcmp(a, "--no-ansi") == 0) {
            opt.color = false; opt.ansi = false;
        } else if (strcmp(a, "--simple") == 0) {
            opt.color = false; opt.ansi = false;
        } else if (strcmp(a, "--lang") == 0) {
            if (i + 1 >= argc) {
                fprintf(stderr, "jpegz: --lang needs a locale code (e.g. --lang fr)\n");
                free(paths);
                return EXIT_USAGE;
            }
            lang_arg = argv[++i];
        } else if (strncmp(a, "--lang=", 7) == 0) {
            lang_arg = a + 7;
        } else if (strcmp(a, "-q") == 0 || strcmp(a, "--quiet") == 0) {
            opt.quiet = true;
        } else {
            fprintf(stderr, "jpegz: unknown option '%s'\n", a);
            fprintf(stderr, "Try 'jpegz --help'.\n");
            free(paths);
            return EXIT_USAGE;
        }
    }

    /* Locale resolution. The library owns the precedence rule; this only
     * gathers the signals and reports what it could not honor.
     *
     * i18n prepare phase (RULES.md): only English has a catalog, so a
     * recognized locale still renders in English — but it says so. Warning is
     * the point; a silent fallback is how a missing catalog survives for a
     * year unnoticed. Goes to stderr so it never pollutes --json on stdout. */
    {
        jpegz_locale_resolution_t loc = {0};
        jpegz_locale_resolve(lang_arg, getenv("JPEGZ_LANG"), getenv("LC_ALL"),
                             getenv("LC_MESSAGES"), getenv("LANG"), &loc);
        if (loc.unsupported_request) {
            const char *asked = lang_arg ? lang_arg : getenv("JPEGZ_LANG");
            fprintf(stderr, "jpegz: unsupported locale '%s'; using English\n",
                    asked ? asked : "?");
        } else if (!loc.has_catalog) {
            fprintf(stderr,
                    "jpegz: no '%s' translation yet; using English\n",
                    jpegz_locale_code(loc.locale));
        }
    }

    if (npaths == 0) {
        fprintf(stderr, "jpegz: no input files\n");
        fprintf(stderr, "Try 'jpegz --help'.\n");
        free(paths);
        return EXIT_USAGE;
    }

    int exit_code = EXIT_OK;

    for (size_t i = 0; i < npaths; i++) {
        const char *path = paths[i];
        size_t len = 0;
        uint8_t *data = read_all(path, &len);
        if (!data) { exit_code = EXIT_USAGE; continue; }

        jpegz_strict_result_t report = {0};
        jpegz_status_t rc = jpegz_validate_any(data, len, &report);

        if (rc != JPEGZ_OK) {
            fprintf(stderr, "jpegz: validation could not run on '%s': %s\n",
                    path, jpegz_last_error_message());
            free(data);
            exit_code = EXIT_USAGE;
            continue;
        }

        if (!opt.quiet) {
            if (opt.json) print_json(path, &report);
            else print_human(path, &report, &opt);
        }

        /* Corruption is the strongest verdict and must survive being mixed
         * with inconclusive inputs in one invocation — otherwise a batch run
         * over a directory could hide a damaged file behind an unsupported
         * one. EXIT_USAGE, once set by an I/O failure, still wins. */
        if (report.verdict == JPEGZ_VERDICT_CORRUPT) {
            if (exit_code == EXIT_OK || exit_code == EXIT_INCONCLUSIVE) {
                exit_code = EXIT_INVALID;
            }
        } else if (report.verdict != JPEGZ_VERDICT_VALID && exit_code == EXIT_OK) {
            exit_code = EXIT_INCONCLUSIVE;
        }

        jpegz_strict_result_free(&report);
        free(data);
    }

    free(paths);
    return exit_code;
}
