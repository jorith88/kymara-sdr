// Opus build configuration for the subset compiled into CRADE (float build, Apple silicon only).
// NEON and the dot-product extension are part of every Apple silicon core, so no runtime CPU detection.
#define OPUS_BUILD 1
#define USE_ALLOCA 1
#define HAVE_LRINTF 1
#define HAVE_LRINT 1
#define FLOAT_APPROX 1
#define ENABLE_DEEP_PLC 1
#define OPUS_ARM_MAY_HAVE_NEON_INTR 1
#define OPUS_ARM_PRESUME_NEON_INTR 1
#define OPUS_ARM_PRESUME_AARCH64_NEON_INTR 1
#define OPUS_ARM_MAY_HAVE_DOTPROD 1
#define OPUS_ARM_PRESUME_DOTPROD 1
