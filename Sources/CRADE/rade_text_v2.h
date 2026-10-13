// RADE V2's callsign decoder: freedv-backend's rade_text (radev2-dev branch) under names that don't clash with the
// V1 decoder's. See rade_text_v2.cpp.

#ifndef KYMARA_RADE_TEXT_V2_H
#define KYMARA_RADE_TEXT_V2_H

#ifdef __cplusplus
extern "C" {
#endif

typedef void (*kymara_rade_text_v2_callback)(void *rt, const char *text, int length, void *state);

void *kymara_rade_text_v2_create(void);
void kymara_rade_text_v2_destroy(void *rt);
void kymara_rade_text_v2_set_rx_callback(void *rt, kymara_rade_text_v2_callback callback, void *state);
/// One soft-decision BPSK data symbol per modem frame that produced features.
void kymara_rade_text_v2_rx_symbol(void *rt, float symbol);
/// Forgets the partly received text; call when sync is lost.
void kymara_rade_text_v2_rx_reset(void *rt);
void kymara_rade_text_v2_enable_stats_output(void *rt, int enable);

#ifdef __cplusplus
}
#endif

#endif
