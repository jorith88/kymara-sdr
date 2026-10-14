// RADE V2 sends the callsign during the over, one bit per modem frame on the BPSK data-symbol channel, as repeated
// LDPC(112,56) blocks (freedv-backend's radev2-dev rade_text.cpp, fetched by scripts/fetch-rade.sh). Its C functions
// have the same names as the V1 decoder's and its C++ types may too, so it is compiled here inside a namespace with
// the functions renamed.

#include "rade_text_v2.h"

#if __has_include("vendor/freedv_v2/pipeline/rade_text.cpp.inc")

// Everything the decoder includes from the standard library, outside the namespace.
#include <algorithm>
#include <array>
#include <assert.h>
#include <climits>
#include <cmath>
#include <cstdint>
#include <ctype.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <vector>

#define rade_text_create kymara_rade_text_v2_create
#define rade_text_destroy kymara_rade_text_v2_destroy
#define rade_text_generate_tx_string kymara_rade_text_v2_generate_tx_string
#define rade_text_tx_next_symbol kymara_rade_text_v2_tx_next_symbol
#define rade_text_set_rx_callback kymara_rade_text_v2_set_rx_callback_impl
#define rade_text_rx_symbol kymara_rade_text_v2_rx_symbol
#define rade_text_enable_stats_output kymara_rade_text_v2_enable_stats_output
#define rade_text_rx_reset kymara_rade_text_v2_rx_reset
#define rade_text_enable_rx_combining kymara_rade_text_v2_enable_rx_combining
#define rade_text_enable_rx_combine_confirm kymara_rade_text_v2_enable_rx_combine_confirm

namespace kymara_rade_v2 {
#include "vendor/freedv_v2/pipeline/rade_text.cpp.inc"
}

// The vendored callback type is declared in the namespace; this one is the same function type.
extern "C" void kymara_rade_text_v2_set_rx_callback(void *rt, kymara_rade_text_v2_callback callback, void *state) {
    kymara_rade_v2::kymara_rade_text_v2_set_rx_callback_impl(rt, callback, state);
}

#else

// scripts/fetch-rade.sh has not been run.
extern "C" {
void *kymara_rade_text_v2_create(void) { return nullptr; }
void kymara_rade_text_v2_destroy(void *) {}
void kymara_rade_text_v2_set_rx_callback(void *, kymara_rade_text_v2_callback, void *) {}
void kymara_rade_text_v2_rx_symbol(void *, float) {}
void kymara_rade_text_v2_rx_reset(void *) {}
void kymara_rade_text_v2_enable_stats_output(void *, int) {}
}

#endif
