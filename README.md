# Kymara

Native macOS receiver for RTL-SDR dongles and SDRplay RSP receivers (Apple silicon), inspired by SDR Console.
Swift + SwiftUI, DSP with Accelerate/vDSP, spectrum and waterfall rendered on the GPU with Metal.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/screenshot-dark.png">
  <img alt="Kymara receiving an FM broadcast station with RDS" src="docs/screenshot-light.png">
</picture>

## Building and running

```bash
brew install librtlsdr          # only needed to build/bundle; the .app then ships its own librtlsdr + libusb
./scripts/build-app.sh          # → build/Kymara.app
open "build/Kymara.app"
```

During development: `swift run -c release Kymara`. Tests: `swift test -c release`.

RADE (FreeDV) support is built from sources that are not in this repository (~45 MB of neural network
weights). `build-app.sh` fetches them; for `swift run`/`swift test`, run `./scripts/fetch-rade.sh` once first.
Without them Kymara builds without the RADE mode.

### Updates

The app updates itself with [Sparkle](https://sparkle-project.org) (**Kymara → Check for Updates…**, or
automatically). It reads `appcast.xml` from the `main` branch; pre-releases are only offered when **Include
pre-releases** is on in Settings. Updates installed this way are not quarantined, so macOS only asks for approval
on the first install.

### SDRplay receivers

SDRplay RSPs need the official **SDRplay API 3.15 or newer** for macOS, installed from
[sdrplay.com/api](https://www.sdrplay.com/api/). It is closed source, so Kymara cannot bundle it; the app loads it
at runtime from `/usr/local/lib` and works without it for the other sources. Supported: RSP1, RSP1A, RSP1B, RSP2,
RSPduo (single-tuner mode) and RSPdx/RSPdx-R2. Only the RSP1 has been tested with real hardware so far.

After an SDRplay API upgrade, `./scripts/check-sdrplay-shim.sh` checks that Kymara's copy of the API's struct
layouts still matches the installed headers.

## Features

**Sources:** RTL-SDR over USB, SDRplay RSP over USB (16-bit samples), rtl_tcp (network), I/Q files (WAV 8/16-bit/float, raw `.cu8`) and a
demo generator with FM broadcast, AM, NFM, SSB and CW signals, so everything also works without hardware.

**Receiver:** AM, NFM, WFM (stereo with a 19 kHz pilot PLL, 50/75 µs de-emphasis), USB, LSB, CW (adjustable
pitch), DSB and RADE (FreeDV digital voice). Adjustable bandwidth (presets or by dragging the filter edges), tuning step, AGC
(off/fast/medium/slow) or manual AF gain, squelch with hysteresis (level, or auto on carrier-to-noise ratio in FM modes), volume/mute.

**FreeDV RADE:** receives FreeDV's RADE V1 digital voice: a neural decoder and the FARGAN vocoder turn the OFDM
signal back into speech. Shows sync, SNR and frequency offset, and the callsign sent at the end of each over. The
sideband follows the FreeDV convention (LSB below 10 MHz except 60 m, USB above) or can be set by hand.
Optionally reports to [FreeDV Reporter](https://qso.freedv.org) as a receive-only station (Settings → FreeDV
Reporter): your callsign, locator, frequency and an optional message while the radio runs in RADE mode, and the callsigns you decode.

**RDS (WFM):** programme service name, PI code, programme type, TP/TA, RadioText and clock time, with
error correction of short bursts. Shown as a panel over the spectrum; new favourites are named after the station.

**RF/tuner:** sample rate 0.25–3.2 MS/s, RF gain or tuner AGC, RTL AGC, PPM correction, direct sampling (HF),
bias-T, offset tuning, DC correction, I/Q swap, overload indicator. SDRplay: 0.25–10 MS/s, LNA state, IF gain or
IF AGC, low IF (no DC spike, up to 2.048 MS/s) or zero IF with hardware decimation, and depending on the model
antenna or tuner selection, bias-T and FM/DAB/AM notch filters. The S-meter uses the gain reported by the API.

**Display (Metal):** spectrum with fill, peak hold and max-per-pixel rendering; waterfall with 6 palettes,
adjustable speed and levels, which shifts correctly when retuning; FFT 1k–64k, averaging, zoom up to ×256,
auto range. S-meter (S1–S9+60, estimated dBm and dBFS, peak and squelch markers). Light, dark or system theme.

**Recording:** audio (16-bit stereo WAV) and I/Q (8-bit WAV for RTL-SDR, 16-bit for SDRplay, playable as a file source), saved to
`~/Music/Kymara Recordings`.

**Favourites:** grouped, filterable, editable.

**DX cluster:** live amateur radio spots from [DXHeat.com](https://dxheat.com), in a tab beside the favourites and
as callsign labels on the spectrum (coloured by CW, phone or digital, fading with age). Click a spot or label to
tune to it in its mode: CW as reported, digital modes in USB (also when the comment names one, such as RTTY or
FT8, or the spot is on a standard FT8/FT4 frequency), and SSB as reported or by the usual sideband convention. Filter by range, mode, DX continent
or text. Off by default; when on, Kymara checks for new spots every minute (adjustable in Settings), only while its
window is visible.

**Settings** are saved automatically to `~/Library/Preferences/nl.pa3jh.kymara.plist` and survive updates.
Each field is read on its own (missing or unknown → default value), favourites, DX cluster and FreeDV Reporter settings are stored under their own keys,
and unreadable data is backed up instead of overwritten.

## Controls

| Action | Spectrum / waterfall |
|---|---|
| Click | Tune (rounded to the tuning step; ⌥ = exact) |
| Drag the passband | Move the VFO |
| Drag a filter edge | Bandwidth |
| Drag the background | Pan (when zoomed) or move the LO |
| Scroll | Tune by one step |
| ⌘/⌥ + scroll, pinch | Zoom around the cursor |
| ← / → (⇧ = ×10) | Tune; ↑/↓ zoom |
| Right-click | Context menu |

Frequency display: scroll over a digit to change it, click its upper/lower half for +/−,
double-click or type a number (⌘F) to enter a frequency (`145.5`, `7100k`, `1.09G`).
Shortcuts: ⌘R start/stop, ⌘1–7 modes, ⌘D add favourite, ⌘=/⌘−/⌘0 zoom, ⇧⌘A/⇧⌘I record, ⌥⌘B/⌥⌘X favourites/DX spots, ⇧⌘L DX spot labels.

## Architecture

- `Sources/SDRCore` — sources (librtlsdr and the SDRplay API via `dlopen`, rtl_tcp, file, demo), DSP chain
  (NCO → decimation to ~240 kHz → channel filter (overlap-save FFT) → demodulation → ~48 kHz audio, plus the RDS decoder on the FM multiplex),
  spectrum analysis, audio output (AVAudioEngine) and recording.
- `Sources/CRADE` — FreeDV RADE receiver: a small C wrapper around rade_c, Opus's FARGAN and freedv-backend's
  callsign decoder (their sources are fetched by `scripts/fetch-rade.sh`).
- `Sources/CSDRplay` — C declarations of the SDRplay API types (no code; the library is loaded at runtime).
- `Sources/Kymara` — SwiftUI app, `RadioController` (state and settings), Metal renderers, persistence, and the
  DX cluster client (`DXCluster/`) and FreeDV Reporter client (`FreeDVReporter/`).

The DSP processes 1 s of 2.4 MS/s in ~15–25 ms on Apple silicon.

## License

Kymara is free software, licensed under the [GNU General Public License v3.0](LICENSE.md).
Copyright © 2026 Jorith van den Heuvel.

The app bundle includes these libraries (the RADE ones are compiled in), each under its own license. The license
texts are in `Kymara.app/Contents/Resources/Licenses`.

| Library | Version | License | Source |
|---|---|---|---|
| [librtlsdr](https://github.com/steve-m/librtlsdr) | 2.0.3 | GPL-2.0-or-later | [v2.0.3](https://github.com/steve-m/librtlsdr/archive/refs/tags/v2.0.3.tar.gz) |
| [libusb](https://libusb.info) | 1.0.30 | LGPL-2.1-or-later | [v1.0.30](https://github.com/libusb/libusb/releases/download/v1.0.30/libusb-1.0.30.tar.bz2) |
| [Sparkle](https://sparkle-project.org) | 2.10.0 | MIT | [2.10.0](https://github.com/sparkle-project/Sparkle/tree/2.10.0) |
| [rade_c](https://github.com/freedv/rade_c) (RADE V1 receiver) | c8a3dc1 | BSD-2-Clause | [c8a3dc1](https://github.com/freedv/rade_c/tree/c8a3dc156045cae2cd251e1a4be0c304c9ddf2f9) + [patches](scripts/patches) |
| [Opus](https://opus-codec.org) (FARGAN vocoder) | 940d4e5 | BSD-3-Clause | [940d4e5](https://github.com/xiph/opus/tree/940d4e5af64351ca8ba8390df3f555484c567fbb) |
| [freedv-backend](https://github.com/tmiw/freedv-backend) (RADE callsign decoder) | 8018330 | BSD-2-Clause | [8018330](https://github.com/tmiw/freedv-backend/tree/80183302230716029def1d0ae8655fb76f96d91e) |

The SDRplay API is not bundled; it is installed separately under SDRplay's own license.
