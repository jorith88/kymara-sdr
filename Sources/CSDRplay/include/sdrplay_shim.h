// Declarations for the SDRplay API 3.x (libsdrplay_api), which Kymara loads at runtime with dlopen.
// Only the types Kymara uses are declared. Struct layouts must match the API headers exactly; they are
// checked with scripts/check-sdrplay-shim.sh against an installed API (written for 3.15).
#ifndef KYMARA_SDRPLAY_SHIM_H
#define KYMARA_SDRPLAY_SHIM_H

#define KSDRPLAY_MAX_DEVICES 16
#define KSDRPLAY_MAX_SER_NO_LEN 64

typedef int ksdrplay_Err;   // 0 = success, 14 = service not responding

// Device list entry (sdrplay_api_DeviceT).
typedef struct {
    char SerNo[KSDRPLAY_MAX_SER_NO_LEN];
    unsigned char hwVer;
    int tuner;                 // 1 = A, 2 = B, 3 = both
    int rspDuoMode;            // 1 = single tuner, 2 = dual, 4 = master, 8 = slave
    unsigned char valid;
    double rspDuoSampleFreq;
    void *dev;
} ksdrplay_Device;

// Device parameters (sdrplay_api_DevParamsT).
typedef struct {
    double ppm;
    struct { double fsHz; unsigned char syncUpdate; unsigned char reCal; } fsFreq;
    struct { unsigned int sampleNum; unsigned int period; } syncUpdate;
    struct { unsigned char resetGainUpdate; unsigned char resetRfUpdate; unsigned char resetFsUpdate; } resetFlags;
    int mode;                  // 0 = isochronous, 1 = bulk
    unsigned int samplesPerPkt;
    struct { unsigned char rfNotchEnable; unsigned char rfDabNotchEnable; } rsp1aParams;
    struct { unsigned char extRefOutputEn; } rsp2Params;
    struct { int extRefOutputEn; } rspDuoParams;
    struct {
        unsigned char hdrEnable;
        unsigned char biasTEnable;
        int antennaSel;        // 0 = A, 1 = B, 2 = C
        unsigned char rfNotchEnable;
        unsigned char rfDabNotchEnable;
    } rspDxParams;
} ksdrplay_DevParams;

// Per-tuner parameters (sdrplay_api_RxChannelParamsT).
typedef struct {
    struct {
        int bwType;            // kHz: 200, 300, 600, 1536, 5000, 6000, 7000, 8000
        int ifType;            // kHz: 0 (zero IF), 450, 1620, 2048
        int loMode;
        struct {
            int gRdB;          // IF gain reduction, 20…59 dB
            unsigned char LNAstate;
            unsigned char syncUpdate;
            int minGr;
            struct { float curr; float max; float min; } gainVals;
        } gain;
        struct { double rfHz; unsigned char syncUpdate; } rfFreq;
        struct { unsigned char dcCal; unsigned char speedUp; int trackTime; int refreshRateTime; } dcOffsetTuner;
    } tunerParams;
    struct {
        struct { unsigned char DCenable; unsigned char IQenable; } dcOffset;
        struct { unsigned char enable; unsigned char decimationFactor; unsigned char wideBandSignal; } decimation;
        struct {
            int enable;        // 0 = off, 1 = 100 Hz, 2 = 50 Hz, 3 = 5 Hz, 4 = control enabled
            int setPoint_dBfs;
            unsigned short attack_ms;
            unsigned short decay_ms;
            unsigned short decay_delay_ms;
            unsigned short decay_threshold_dB;
            int syncUpdate;
        } agc;
        int adsbMode;
    } ctrlParams;
    struct { unsigned char biasTEnable; } rsp1aTunerParams;
    struct { unsigned char biasTEnable; int amPortSel; int antennaSel; unsigned char rfNotchEnable; } rsp2TunerParams;
    struct {
        unsigned char biasTEnable;
        int tuner1AmPortSel;   // 1 = Hi-Z (AM port 1), 0 = 50 Ω
        unsigned char tuner1AmNotchEnable;
        unsigned char rfNotchEnable;
        unsigned char rfDabNotchEnable;
        struct { unsigned char resetGainUpdate; unsigned char resetRfUpdate; } resetSlaveFlags;
    } rspDuoTunerParams;
    struct { int hdrBw; } rspDxTunerParams;
} ksdrplay_RxChannelParams;

typedef struct {
    ksdrplay_DevParams *devParams;
    ksdrplay_RxChannelParams *rxChannelA;
    ksdrplay_RxChannelParams *rxChannelB;
} ksdrplay_DeviceParams;

typedef struct {
    unsigned int firstSampleNum;
    int grChanged;
    int rfChanged;
    int fsChanged;
    unsigned int numSamples;
} ksdrplay_StreamCbParams;

// Event parameters: gain change (gRdB, lnaGRdB, currGain) or power overload (type in the first int).
typedef union {
    struct { unsigned int gRdB; unsigned int lnaGRdB; double currGain; } gainParams;
    struct { int powerOverloadChangeType; } powerOverloadParams;   // 0 = detected, 1 = corrected
    struct { int modeChangeType; } rspDuoModeParams;
} ksdrplay_EventParams;

typedef void (*ksdrplay_StreamCallback)(short *xi, short *xq, ksdrplay_StreamCbParams *params,
                                         unsigned int numSamples, unsigned int reset, void *cbContext);
typedef void (*ksdrplay_EventCallback)(int eventId, int tuner, ksdrplay_EventParams *params, void *cbContext);

typedef struct {
    ksdrplay_StreamCallback StreamACbFn;
    ksdrplay_StreamCallback StreamBCbFn;
    ksdrplay_EventCallback EventCbFn;
} ksdrplay_CallbackFns;

// Function signatures, resolved with dlsym.
typedef ksdrplay_Err (*ksdrplay_Void_t)(void);                       // Open, Close, LockDeviceApi, UnlockDeviceApi
typedef ksdrplay_Err (*ksdrplay_ApiVersion_t)(float *apiVer);
typedef ksdrplay_Err (*ksdrplay_GetDevices_t)(ksdrplay_Device *devices, unsigned int *numDevs, unsigned int maxDevs);
typedef ksdrplay_Err (*ksdrplay_DeviceFn_t)(ksdrplay_Device *device); // SelectDevice, ReleaseDevice
typedef const char * (*ksdrplay_GetErrorString_t)(ksdrplay_Err err);
typedef ksdrplay_Err (*ksdrplay_GetDeviceParams_t)(void *dev, ksdrplay_DeviceParams **deviceParams);
typedef ksdrplay_Err (*ksdrplay_Init_t)(void *dev, ksdrplay_CallbackFns *callbackFns, void *cbContext);
typedef ksdrplay_Err (*ksdrplay_Uninit_t)(void *dev);
typedef ksdrplay_Err (*ksdrplay_Update_t)(void *dev, int tuner, unsigned int reasonForUpdate, unsigned int reasonForUpdateExt1);

#endif
