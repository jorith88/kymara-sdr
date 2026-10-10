#!/bin/bash
# Fetches the RADE (FreeDV Radio Autoencoder) V1 receiver from the C port, the parts of Opus it needs (the FARGAN
# vocoder and the neural-network kernels) and FreeDV's end-of-over callsign decoder into Sources/CRADE/vendor.
# The sources hold ~45 MB of generated model weights, so they are not checked in. Without them CRADE builds as a
# stub and RADE mode is hidden.
#
# Usage: scripts/fetch-rade.sh [--if-needed]
#   --if-needed  only fetch when the vendor folder is missing or was made from other pinned versions, another
#                version of this script or other patches (build-app.sh uses this)
set -euo pipefail

RADE_C_COMMIT=c8a3dc156045cae2cd251e1a4be0c304c9ddf2f9   # github.com/freedv/rade_c
OPUS_COMMIT=940d4e5af64351ca8ba8390df3f555484c567fbb     # github.com/xiph/opus (the commit rade_c builds against)
OPUS_MODEL_SHA256=4ed9445b96698bad25d852e912b41495ddfa30c8dbc8a55f9cde5826ed793453
FREEDV_BACKEND_COMMIT=80183302230716029def1d0ae8655fb76f96d91e   # github.com/tmiw/freedv-backend (rade_text, LDPC)

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/Sources/CRADE/vendor"

# Identifies what the vendor folder was made from.
RECIPE=$(cat "$ROOT/scripts/fetch-rade.sh" "$ROOT"/scripts/patches/rade_c-*.patch "$ROOT/Sources/CRADE/ulog_stub.h" \
    | shasum -a 256 | cut -c1-16)
VERSION_LINE="RADE_C_COMMIT=$RADE_C_COMMIT OPUS_COMMIT=$OPUS_COMMIT OPUS_MODEL_SHA256=$OPUS_MODEL_SHA256"
VERSION_LINE+=" FREEDV_BACKEND_COMMIT=$FREEDV_BACKEND_COMMIT RECIPE=$RECIPE"
if [ "${1:-}" = "--if-needed" ] && [ "$(cat "$DEST/VERSION" 2>/dev/null)" = "$VERSION_LINE" ]; then
    echo "RADE sources are up to date"
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fetch_commit() {  # url commit dir [sparse paths...]
    local url=$1 commit=$2 dir=$3
    shift 3
    git init -q "$dir"
    git -C "$dir" remote add origin "$url"
    if [ $# -gt 0 ]; then git -C "$dir" sparse-checkout set "$@"; fi
    git -C "$dir" fetch -q --depth 1 --filter=blob:none origin "$commit"
    git -C "$dir" -c advice.detachedHead=false checkout -q FETCH_HEAD
}

echo "Fetching rade_c $RADE_C_COMMIT"
fetch_commit https://github.com/freedv/rade_c.git "$RADE_C_COMMIT" "$WORK/rade_c" src
echo "Fetching opus $OPUS_COMMIT"
fetch_commit https://github.com/xiph/opus.git "$OPUS_COMMIT" "$WORK/opus" celt dnn include
echo "Fetching freedv-backend $FREEDV_BACKEND_COMMIT"
fetch_commit https://github.com/tmiw/freedv-backend.git "$FREEDV_BACKEND_COMMIT" "$WORK/freedv" src/pipeline

MODEL="opus_data-$OPUS_MODEL_SHA256.tar.gz"
echo "Fetching Opus model data"
curl -fsSL -o "$WORK/$MODEL" "https://media.xiph.org/opus/models/$MODEL"
echo "$OPUS_MODEL_SHA256  $WORK/$MODEL" | shasum -a 256 -c - >/dev/null
tar -xzf "$WORK/$MODEL" -C "$WORK/opus"

# Local fixes to rade_c (each patch file explains itself).
for p in "$ROOT"/scripts/patches/rade_c-*.patch; do
    patch -s -d "$WORK/rade_c" -p1 < "$p"
done

rm -rf "$DEST"
mkdir -p "$DEST/rade" "$DEST/freedv/pipeline" "$DEST/freedv/util/logging" "$DEST/opus/celt/arm" "$DEST/opus/celt/x86" "$DEST/opus/dnn/arm" "$DEST/opus/include"

# Only the V1 receiver is compiled (kymara_rade.c drives it directly): the encoder and the V2 models would add
# ~16 MB of weights to the app. All headers come along, since rade_api.h (included by rade_text) pulls them in.
R="$WORK/rade_c/src"
for f in rade_dsp rade_bpf rade_ofdm rade_acq rade_rx rade_dec rade_dec_data; do
    cp "$R/$f.c" "$DEST/rade/"
done
find "$R" -maxdepth 1 -name 'rade_*.h' -exec cp {} "$DEST/rade/" \;
cp "$WORK/rade_c/LICENSE" "$DEST/rade/LICENSE"

O="$WORK/opus"
for f in kiss_fft mathops celt_lpc pitch; do cp "$O/celt/$f.c" "$DEST/opus/celt/"; done
for f in pitch_neon_intr celt_neon_intr; do cp "$O/celt/arm/$f.c" "$DEST/opus/celt/arm/"; done
for f in fargan fargan_data freq nnet nnet_default pitchdnn pitchdnn_data lpcnet_tables parse_lpcnet_weights burg; do
    cp "$O/dnn/$f.c" "$DEST/opus/dnn/"
done
for f in nnet_neon nnet_dotprod; do cp "$O/dnn/arm/$f.c" "$DEST/opus/dnn/arm/"; done
cp "$O"/celt/*.h "$DEST/opus/celt/"
cp "$O"/celt/arm/*.h "$DEST/opus/celt/arm/"
cp "$O"/celt/x86/x86_arch_macros.h "$DEST/opus/celt/x86/"
cp "$O"/dnn/*.h "$DEST/opus/dnn/"
cp "$O"/dnn/arm/*.h "$DEST/opus/dnn/arm/"
cp "$O"/include/*.h "$DEST/opus/include/"
cp "$O/COPYING" "$DEST/opus/COPYING"

F="$WORK/freedv"
for f in rade_text.cpp rade_text.h ldpc_decode.cpp ldpc_decode.h ldpc_encode.cpp ldpc_encode.h HRA_56_56.h; do
    cp "$F/src/pipeline/$f" "$DEST/freedv/pipeline/"
done
cp "$F/LICENSE" "$DEST/freedv/LICENSE"
# rade_text.cpp logs through freedv's ulog; compile it out.
cp "$ROOT/Sources/CRADE/ulog_stub.h" "$DEST/freedv/util/logging/ulog.h"

# kymara_rade.c picks the real decoder or stubs with __has_include; make the build recompile it.
touch "$ROOT/Sources/CRADE/kymara_rade.c"

echo "$VERSION_LINE" > "$DEST/VERSION"
echo "Done: $(du -sh "$DEST" | cut -f1) in Sources/CRADE/vendor"
