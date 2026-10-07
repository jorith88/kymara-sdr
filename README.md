# Kymara

Native macOS-ontvanger voor RTL-SDR dongles (Apple silicon), geïnspireerd op SDR Console.
Swift + SwiftUI, DSP met Accelerate/vDSP, spectrum en waterfall op de GPU via Metal.

## Bouwen en starten

```bash
brew install librtlsdr          # alleen nodig om te bouwen/bundelen; de .app bevat daarna zelf librtlsdr + libusb
./scripts/build-app.sh          # → build/Kymara.app
open "build/Kymara.app"
```

Tijdens ontwikkelen: `swift run -c release Kymara`. Tests: `swift test -c release`.

## Functies

**Bronnen:** RTL-SDR via USB, rtl_tcp (netwerk), I/Q-bestanden (WAV 8/16-bit/float, raw `.cu8`) en een
demo-generator met FM-omroep, AM, NFM, SSB en CW, zodat alles ook zonder hardware werkt.

**Ontvanger:** AM, NFM, WFM (stereo met 19 kHz pilot-PLL, de-emphasis 50/75 µs), USB, LSB, CW (instelbare
pitch) en DSB. Instelbare bandbreedte (presets of slepen aan de filterranden), stapgrootte, AGC
(uit/snel/middel/langzaam) of handmatige AF-gain, squelch met hysterese, volume/mute.

**RF/tuner:** sample rate 0,25–3,2 MS/s, RF-gain of tuner-AGC, RTL-AGC, PPM-correctie, direct sampling (HF),
bias-T, offset tuning, DC-correctie, I/Q wisselen, overload-indicator.

**Weergave (Metal):** spectrum met fill, peak hold en max-per-pixel weergave; waterfall met 6 paletten,
instelbare snelheid en niveaus, die bij verstemmen correct meeschuift; FFT 1k–64k, averaging, zoom tot ×256,
auto-range. S-meter (S1–S9+60, dBm-schatting en dBFS, piek- en squelchmarkering).

**Opnemen:** audio (16-bit stereo WAV) en I/Q (8-bit WAV, af te spelen als bestandsbron), in
`~/Music/Kymara Recordings`.

**Favorieten:** gegroepeerd, filterbaar, bewerkbaar.

**Instellingen** worden automatisch bewaard in `~/Library/Preferences/nl.pa3jh.kymara.plist` en blijven bij
updates behouden. Elk veld wordt los ingelezen (ontbrekend of onbekend → standaardwaarde), favorieten staan
onder een eigen sleutel, en onleesbare data wordt als back-up bewaard in plaats van overschreven.

## Bediening

| Actie | Spectrum / waterfall |
|---|---|
| Klik | Afstemmen (afgerond op de stapgrootte; ⌥ = exact) |
| Passband slepen | VFO verschuiven |
| Filterrand slepen | Bandbreedte |
| Achtergrond slepen | Pannen (ingezoomd) of LO verschuiven |
| Scrollen | Afstemmen per stap |
| ⌘/⌥ + scrollen, pinch | Zoomen rond de cursor |
| ← / → (⇧ = ×10) | Afstemmen; ↑/↓ zoomen |
| Rechtsklik | Contextmenu |

Frequentiedisplay: scroll over een cijfer om het te wijzigen, klik op de boven/onderhelft voor +/−,
dubbelklik of typ een getal (⌘F) om een frequentie in te voeren (`145.5`, `7100k`, `1.09G`).
Sneltoetsen: ⌘R start/stop, ⌘1–7 modes, ⌘D favoriet, ⌘=/⌘−/⌘0 zoom, ⇧⌘A/⇧⌘I opnemen.

## Architectuur

- `Sources/SDRCore` — bronnen (librtlsdr via `dlopen`, rtl_tcp, bestand, demo), DSP-keten
  (NCO → decimatie naar ~240 kHz → kanaalfilter (overlap-save FFT) → demodulatie → ~48 kHz audio),
  spectrumanalyse, audio-uitvoer (AVAudioEngine) en opname.
- `Sources/Kymara` — SwiftUI-app, `RadioController` (status en instellingen), Metal-renderers.

De DSP verwerkt 1 s aan 2,4 MS/s in ~15–25 ms op Apple silicon.
