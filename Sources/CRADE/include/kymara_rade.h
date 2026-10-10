// RADE V1 receiver: the FreeDV Radio Autoencoder demodulator/decoder (rade_c) followed by the FARGAN vocoder
// (Opus), behind one small API. The library sources are fetched by scripts/fetch-rade.sh.

#ifndef KYMARA_RADE_H
#define KYMARA_RADE_H

#ifdef __cplusplus
extern "C" {
#endif

/// Modem input rate (complex samples) and speech output rate.
#define KYMARA_RADE_MODEM_RATE 8000
#define KYMARA_RADE_SPEECH_RATE 16000

typedef struct kymara_rade kymara_rade;

/// 0 when the RADE sources were not fetched; everything below is then a stub and open returns NULL.
int kymara_rade_available(void);

kymara_rade *kymara_rade_open(void);
void kymara_rade_close(kymara_rade *k);

/// Most speech samples one modem frame can produce; `speech_capacity` must be at least this.
int kymara_rade_max_speech_per_frame(const kymara_rade *k);

/// Feeds complex modem samples (8 kHz, the signal as it appears in USB: carriers at about +1.1…+1.9 kHz).
/// Consumes input until it runs out or until the next modem frame could overflow `speech_capacity`;
/// `*consumed` reports how many input samples were taken. Returns the number of 16 kHz speech samples
/// written to `speech`.
int kymara_rade_process(kymara_rade *k, const float *re, const float *im, int count, int *consumed,
                        float *speech, int speech_capacity);

/// Receiver state, valid after the last kymara_rade_process call.
int kymara_rade_sync(const kymara_rade *k);
/// SNR estimate in a 3 kHz noise bandwidth (dB), valid while in sync.
float kymara_rade_snr_db(const kymara_rade *k);
/// Frequency offset of the received signal (Hz), valid while in sync.
float kymara_rade_frequency_offset(const kymara_rade *k);
/// Number of end-of-over frames seen since opening.
int kymara_rade_end_of_overs(const kymara_rade *k);

#ifdef __cplusplus
}
#endif

#endif
