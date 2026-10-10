// See include/kymara_rade.h. Modelled on rade_c's rade_rx_wav.c, but driving the V1 receiver directly instead of
// through rade_api.c, which would also link the encoder and the V2 models (~16 MB of weights) a receiver never uses.

#include "kymara_rade.h"

#if !__has_include("rade_rx.h")

// scripts/fetch-rade.sh has not been run.
int kymara_rade_available(void) { return 0; }
kymara_rade *kymara_rade_open(void) { return 0; }
void kymara_rade_close(kymara_rade *k) { (void)k; }
int kymara_rade_max_speech_per_frame(const kymara_rade *k) { (void)k; return 0; }
int kymara_rade_process(kymara_rade *k, const float *re, const float *im, int count, int *consumed,
                        float *speech, int speech_capacity) {
    (void)k; (void)re; (void)im; (void)speech; (void)speech_capacity;
    *consumed = count;
    return 0;
}
int kymara_rade_sync(const kymara_rade *k) { (void)k; return 0; }
float kymara_rade_snr_db(const kymara_rade *k) { (void)k; return 0; }
float kymara_rade_frequency_offset(const kymara_rade *k) { (void)k; return 0; }
int kymara_rade_end_of_overs(const kymara_rade *k) { (void)k; return 0; }
const char *kymara_rade_callsign(const kymara_rade *k) { (void)k; return ""; }
int kymara_rade_callsign_count(const kymara_rade *k) { (void)k; return 0; }

#else

#include <stdlib.h>
#include <string.h>

#include "rade_rx.h"
#include "fargan.h"
#include "lpcnet.h"
#include "rade_text.h"

/// FARGAN needs this many feature frames to prime its state before it synthesises.
#define WARMUP_FRAMES 5

struct kymara_rade {
    rade_rx_state rx;
    FARGANState fargan;
    int warmup_count;
    float warmup[WARMUP_FRAMES * NB_TOTAL_FEATURES];

    RADE_COMP *rx_in;
    int rx_fill;
    float *features;
    int n_features;
    float *eoo_bits;

    int sync;
    float snr_db;
    float frequency_offset;
    int end_of_overs;

    /// FreeDV's end-of-over text: callsign, 6-bit characters, LDPC(112,56) and CRC8.
    rade_text_t text;
    char callsign[16];
    int callsign_count;
};

static void on_callsign(rade_text_t text, const char *callsign, int length, void *state) {
    (void)text;
    kymara_rade *k = state;
    if (length >= (int)sizeof(k->callsign)) length = sizeof(k->callsign) - 1;
    memcpy(k->callsign, callsign, (size_t)length);
    k->callsign[length] = 0;
    k->callsign_count++;
}

kymara_rade *kymara_rade_open(void) {
    kymara_rade *k = calloc(1, sizeof(kymara_rade));
    if (!k) return NULL;
    // As rade_open() sets up a V1 receiver: built-in weights, bottleneck 3, auxiliary data, input BPF.
    if (rade_rx_init(&k->rx, NULL, 3, 1, 1) != 0) {
        free(k);
        return NULL;
    }
    k->rx.verbose = 0;
    k->rx_in = calloc((size_t)rade_rx_nin_max(&k->rx), sizeof(RADE_COMP));
    k->n_features = rade_rx_n_features_out(&k->rx);
    k->features = calloc((size_t)k->n_features, sizeof(float));
    k->eoo_bits = calloc((size_t)rade_rx_n_eoo_bits(&k->rx), sizeof(float));
    if (!k->rx_in || !k->features || !k->eoo_bits) {
        kymara_rade_close(k);
        return NULL;
    }
    fargan_init(&k->fargan);
    k->text = rade_text_create();
    rade_text_enable_stats_output(k->text, 0);
    rade_text_set_rx_callback(k->text, on_callsign, k);
    return k;
}

void kymara_rade_close(kymara_rade *k) {
    if (!k) return;
    if (k->text) rade_text_destroy(k->text);
    free(k->rx_in);
    free(k->features);
    free(k->eoo_bits);
    free(k);
}

int kymara_rade_max_speech_per_frame(const kymara_rade *k) {
    return k->n_features / RADE_NB_TOTAL_FEATURES * LPCNET_FRAME_SIZE;
}

/// Synthesises one 10 ms feature frame; returns the number of speech samples written (0 while warming up).
static int synthesise(kymara_rade *k, const float *feature, float *speech) {
    if (k->warmup_count < WARMUP_FRAMES) {
        // fargan_cont takes the warm-up frames packed at a stride of NB_FEATURES.
        memcpy(&k->warmup[k->warmup_count * NB_FEATURES], feature, NB_FEATURES * sizeof(float));
        if (++k->warmup_count == WARMUP_FRAMES) {
            float zeros[FARGAN_CONT_SAMPLES] = {0};
            fargan_cont(&k->fargan, zeros, k->warmup);
        }
        return 0;
    }
    fargan_synthesize(&k->fargan, speech, feature);
    return LPCNET_FRAME_SIZE;
}

int kymara_rade_process(kymara_rade *k, const float *re, const float *im, int count, int *consumed,
                        float *speech, int speech_capacity) {
    int pos = 0, written = 0;
    int frame_max = kymara_rade_max_speech_per_frame(k);
    while (pos < count) {
        int nin = rade_rx_nin(&k->rx);
        int take = nin - k->rx_fill;
        if (take > count - pos) take = count - pos;
        // Don't complete a frame whose speech might not fit; the caller comes back with more room.
        if (k->rx_fill + take == nin && speech_capacity - written < frame_max) break;
        for (int i = 0; i < take; i++) {
            k->rx_in[k->rx_fill + i].real = re[pos + i];
            k->rx_in[k->rx_fill + i].imag = im[pos + i];
        }
        k->rx_fill += take;
        pos += take;
        if (k->rx_fill < nin) break;
        k->rx_fill = 0;

        int ret = rade_rx_process(&k->rx, k->features, k->eoo_bits, k->rx_in);
        int n_out = (ret & 0x1) ? k->n_features : 0;
        if (ret & 0x2) {
            k->end_of_overs++;
            // eoo_bits holds QPSK symbols as I/Q pairs.
            rade_text_rx(k->text, k->eoo_bits, rade_rx_n_eoo_bits(&k->rx) / 2);
        }
        int sync = rade_rx_sync(&k->rx);
        if (!sync && k->sync) {
            // Lost the signal: start the vocoder afresh on the next over.
            fargan_init(&k->fargan);
            k->warmup_count = 0;
        }
        k->sync = sync;
        if (sync) {
            k->snr_db = rade_rx_snrdB_3k_est(&k->rx);
            k->frequency_offset = rade_rx_freq_offset(&k->rx);
        }
        for (int f = 0; f + RADE_NB_TOTAL_FEATURES <= n_out; f += RADE_NB_TOTAL_FEATURES) {
            written += synthesise(k, &k->features[f], &speech[written]);
        }
    }
    *consumed = pos;
    return written;
}

int kymara_rade_sync(const kymara_rade *k) { return k->sync; }
float kymara_rade_snr_db(const kymara_rade *k) { return k->snr_db; }
float kymara_rade_frequency_offset(const kymara_rade *k) { return k->frequency_offset; }
int kymara_rade_end_of_overs(const kymara_rade *k) { return k->end_of_overs; }
const char *kymara_rade_callsign(const kymara_rade *k) { return k->callsign; }
int kymara_rade_callsign_count(const kymara_rade *k) { return k->callsign_count; }
int kymara_rade_available(void) { return 1; }

#endif
