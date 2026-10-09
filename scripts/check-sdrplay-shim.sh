#!/bin/bash
# Checks that the struct layouts in Sources/CSDRplay/include/sdrplay_shim.h match the installed SDRplay API headers.
# Run after upgrading the SDRplay API. Needs the API installed (headers in /usr/local/include).
set -euo pipefail
cd "$(dirname "$0")/.."
INC=${SDRPLAY_INCLUDE:-/usr/local/include}
[ -f "$INC/sdrplay_api.h" ] || { echo "SDRplay API headers not found in $INC" >&2; exit 1; }
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/check.c" <<'C'
#include <stddef.h>
#include <stdio.h>
#include <sdrplay_api.h>
#include "sdrplay_shim.h"

static int failures = 0;
#define SAME_SIZE(real, shim) do { if (sizeof(real) != sizeof(shim)) { \
    printf("size mismatch: %s %zu vs %s %zu\n", #real, sizeof(real), #shim, sizeof(shim)); failures++; } } while (0)
#define SAME_OFFSET(real, shim, field) do { if (offsetof(real, field) != offsetof(shim, field)) { \
    printf("offset mismatch: %s.%s %zu vs %zu\n", #real, #field, offsetof(real, field), offsetof(shim, field)); failures++; } } while (0)

int main(void) {
    SAME_SIZE(sdrplay_api_DeviceT, ksdrplay_Device);
    SAME_OFFSET(sdrplay_api_DeviceT, ksdrplay_Device, hwVer);
    SAME_OFFSET(sdrplay_api_DeviceT, ksdrplay_Device, tuner);
    SAME_OFFSET(sdrplay_api_DeviceT, ksdrplay_Device, rspDuoMode);
    SAME_OFFSET(sdrplay_api_DeviceT, ksdrplay_Device, valid);
    SAME_OFFSET(sdrplay_api_DeviceT, ksdrplay_Device, rspDuoSampleFreq);
    SAME_OFFSET(sdrplay_api_DeviceT, ksdrplay_Device, dev);

    SAME_SIZE(sdrplay_api_DevParamsT, ksdrplay_DevParams);
    SAME_OFFSET(sdrplay_api_DevParamsT, ksdrplay_DevParams, ppm);
    SAME_OFFSET(sdrplay_api_DevParamsT, ksdrplay_DevParams, fsFreq.fsHz);
    SAME_OFFSET(sdrplay_api_DevParamsT, ksdrplay_DevParams, mode);
    SAME_OFFSET(sdrplay_api_DevParamsT, ksdrplay_DevParams, samplesPerPkt);
    SAME_OFFSET(sdrplay_api_DevParamsT, ksdrplay_DevParams, rsp1aParams.rfNotchEnable);
    SAME_OFFSET(sdrplay_api_DevParamsT, ksdrplay_DevParams, rsp1aParams.rfDabNotchEnable);
    SAME_OFFSET(sdrplay_api_DevParamsT, ksdrplay_DevParams, rsp2Params.extRefOutputEn);
    SAME_OFFSET(sdrplay_api_DevParamsT, ksdrplay_DevParams, rspDuoParams.extRefOutputEn);
    SAME_OFFSET(sdrplay_api_DevParamsT, ksdrplay_DevParams, rspDxParams.biasTEnable);
    SAME_OFFSET(sdrplay_api_DevParamsT, ksdrplay_DevParams, rspDxParams.antennaSel);
    SAME_OFFSET(sdrplay_api_DevParamsT, ksdrplay_DevParams, rspDxParams.rfNotchEnable);
    SAME_OFFSET(sdrplay_api_DevParamsT, ksdrplay_DevParams, rspDxParams.rfDabNotchEnable);

    SAME_SIZE(sdrplay_api_RxChannelParamsT, ksdrplay_RxChannelParams);
    SAME_OFFSET(sdrplay_api_RxChannelParamsT, ksdrplay_RxChannelParams, tunerParams.bwType);
    SAME_OFFSET(sdrplay_api_RxChannelParamsT, ksdrplay_RxChannelParams, tunerParams.ifType);
    SAME_OFFSET(sdrplay_api_RxChannelParamsT, ksdrplay_RxChannelParams, tunerParams.gain.gRdB);
    SAME_OFFSET(sdrplay_api_RxChannelParamsT, ksdrplay_RxChannelParams, tunerParams.gain.LNAstate);
    SAME_OFFSET(sdrplay_api_RxChannelParamsT, ksdrplay_RxChannelParams, tunerParams.gain.minGr);
    SAME_OFFSET(sdrplay_api_RxChannelParamsT, ksdrplay_RxChannelParams, tunerParams.rfFreq.rfHz);
    SAME_OFFSET(sdrplay_api_RxChannelParamsT, ksdrplay_RxChannelParams, tunerParams.dcOffsetTuner);
    SAME_OFFSET(sdrplay_api_RxChannelParamsT, ksdrplay_RxChannelParams, ctrlParams.dcOffset.DCenable);
    SAME_OFFSET(sdrplay_api_RxChannelParamsT, ksdrplay_RxChannelParams, ctrlParams.decimation.enable);
    SAME_OFFSET(sdrplay_api_RxChannelParamsT, ksdrplay_RxChannelParams, ctrlParams.decimation.decimationFactor);
    SAME_OFFSET(sdrplay_api_RxChannelParamsT, ksdrplay_RxChannelParams, ctrlParams.agc.enable);
    SAME_OFFSET(sdrplay_api_RxChannelParamsT, ksdrplay_RxChannelParams, ctrlParams.agc.setPoint_dBfs);
    SAME_OFFSET(sdrplay_api_RxChannelParamsT, ksdrplay_RxChannelParams, ctrlParams.adsbMode);
    SAME_OFFSET(sdrplay_api_RxChannelParamsT, ksdrplay_RxChannelParams, rsp1aTunerParams.biasTEnable);
    SAME_OFFSET(sdrplay_api_RxChannelParamsT, ksdrplay_RxChannelParams, rsp2TunerParams.biasTEnable);
    SAME_OFFSET(sdrplay_api_RxChannelParamsT, ksdrplay_RxChannelParams, rsp2TunerParams.amPortSel);
    SAME_OFFSET(sdrplay_api_RxChannelParamsT, ksdrplay_RxChannelParams, rsp2TunerParams.antennaSel);
    SAME_OFFSET(sdrplay_api_RxChannelParamsT, ksdrplay_RxChannelParams, rsp2TunerParams.rfNotchEnable);
    SAME_OFFSET(sdrplay_api_RxChannelParamsT, ksdrplay_RxChannelParams, rspDuoTunerParams.biasTEnable);
    SAME_OFFSET(sdrplay_api_RxChannelParamsT, ksdrplay_RxChannelParams, rspDuoTunerParams.tuner1AmPortSel);
    SAME_OFFSET(sdrplay_api_RxChannelParamsT, ksdrplay_RxChannelParams, rspDuoTunerParams.tuner1AmNotchEnable);
    SAME_OFFSET(sdrplay_api_RxChannelParamsT, ksdrplay_RxChannelParams, rspDuoTunerParams.rfNotchEnable);
    SAME_OFFSET(sdrplay_api_RxChannelParamsT, ksdrplay_RxChannelParams, rspDuoTunerParams.rfDabNotchEnable);
    SAME_OFFSET(sdrplay_api_RxChannelParamsT, ksdrplay_RxChannelParams, rspDxTunerParams.hdrBw);

    SAME_SIZE(sdrplay_api_DeviceParamsT, ksdrplay_DeviceParams);
    SAME_SIZE(sdrplay_api_StreamCbParamsT, ksdrplay_StreamCbParams);
    SAME_SIZE(sdrplay_api_EventParamsT, ksdrplay_EventParams);
    SAME_OFFSET(sdrplay_api_EventParamsT, ksdrplay_EventParams, gainParams.currGain);
    SAME_SIZE(sdrplay_api_CallbackFnsT, ksdrplay_CallbackFns);

    if (failures == 0) printf("sdrplay_shim.h matches the SDRplay API headers\n");
    return failures == 0 ? 0 : 1;
}
C
clang -I"$INC" -ISources/CSDRplay/include -o "$TMP/check" "$TMP/check.c"
"$TMP/check"
