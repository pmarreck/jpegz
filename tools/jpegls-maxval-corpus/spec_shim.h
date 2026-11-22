// Force-included into CharLS's make_scan_codec.cpp only: derive the coding
// traits (RANGE, qbpp, bpp, LIMIT, clamp) from the preset MAXVAL, as T.87
// A.2.1 specifies, instead of from 2^P - 1.
#include "jpegls_algorithm.hpp"
#define calculate_maximum_bit_sample_value(b) (pc_parameters.maximum_sample_value)
