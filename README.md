<div align="center">
  <img src="webroot/assets/logo.svg" alt="Clarifae" height="64" />
  <h3>Real-time AI audio clarity for rooted Android</h3>
  <p>A Magisk / KernelSU / APatch module that cleans your microphone in real time
  using open-source speech-enhancement models — configurable from a WebUI.</p>
</div>

---

Clarifae installs a custom **Android audio pre-processing effect** (`libclarifae.so`)
and registers it via `audio_effects.xml` so it attaches to your capture streams
(microphone, calls/VoIP, camcorder, voice recognition). Captured audio is denoised
on the fly by one of three engines, selectable as **clarity modes**.

> Brand: primary `#435787`, secondary `#68aaf3`, font *Creative Caps*.

## Contents

- [Clarity modes](#clarity-modes)
- [Features](#features)
- [Requirements](#requirements)
- [Quick start](#quick-start)
- [How it works](#how-it-works)
- [Configuration reference](#configuration-reference)
- [`clarifae-ctl` commands](#clarifae-ctl-commands)
- [Limitations & caveats](#limitations--caveats)
- [Licensing & credits](#licensing--credits)

## Clarity modes

| Mode | Engine | Profile | Status |
|---|---|---|---|
| **1 · Low latency** | [RNNoise](https://github.com/xiph/rnnoise) | Compact RNN denoiser, lowest CPU/latency, 48 kHz framed | ✅ **Default, works out of the box** |
| **2 · Balanced** | [DTLN](https://github.com/breizhn/DTLN) | Dual-signal LSTM via TensorFlow Lite, stronger denoising | ⚠️ Experimental — needs TFLite + models |
| **3 · Maximum clarity** | [DeepFilterNet](https://github.com/Rikorose/DeepFilterNet) | Full-band 48 kHz deep filtering, highest quality | ⚠️ Experimental — needs `libdf` + model |

Modes 2 and 3 are optional builds. If their runtime/models aren't present, Clarifae
**transparently falls back to RNNoise** — it never silently breaks your mic.

## Features

- System-wide mic noise suppression as a native AudioFlinger pre-processing effect.
- Three AI clarity modes with graceful fallback.
- **Branded WebUI**: master toggle, mode picker, strength / max-suppression / voice-gate
  sliders, high-pass & auto-gain toggles, capture-source selection, live engine status, logs.
- Live, reboot-free settings via `persist.clarifae.*` properties (the effect re-reads
  on change).
- `clarifae-ctl` CLI for scripting and debugging.
- Clean uninstall — the original `audio_effects.xml` is only *shadowed*, never edited.

## Requirements

- A rooted Android device with **Magisk ≥ 24.0**, **KernelSU**, or **APatch**.
- For the WebUI: KernelSU/APatch have a built-in WebUI launcher; on **Magisk**, install
  **[MMRL](https://github.com/MMRLApp/MMRL)** to open module WebUIs.
- To build from source: Android NDK (r27+), CMake, and network access for `fetch_deps.sh`.

## Quick start

```bash
# from the project folder:
# 1. fetch RNNoise + weights, then build the native effect for all ABIs
./scripts/fetch_deps.sh
./build.sh                      # -> lib/<abi>/

# 2. package a flashable zip
./scripts/package.sh            # -> dist/clarifae-v1.0.0.zip

# 3. flash dist/clarifae-v1.0.0.zip in Magisk/KernelSU/APatch, reboot
# 4. open the Clarifae WebUI, toggle it on, pick a mode
```

See **[INSTALL.md](INSTALL.md)** for details, optional DTLN/DeepFilterNet builds, and
verification steps.

## How it works

```
 mic app ─▶ AudioRecord ─▶ AudioFlinger capture chain
                               │  (audio_effects.xml: <preprocess> attaches clarifae_ns)
                               ▼
                         libclarifae.so  (effect.c)
                               │  s16/float ⇄ float, live config from persist.clarifae.*
                               ▼
                  backend: rnnoise │ dtln │ deepfilternet
                               │  resample ⇄ engine rate, frame, enhance, wet/dry + atten cap
                               ▼
                         cleaned audio ─▶ back to the app
```

Configuration flows: **WebUI → `clarifae-ctl` → `config.conf` → `persist.clarifae.*` →
effect**. The effect detects a property change (via the property serial) and reloads
parameters / re-opens the backend on the next audio buffer, so most changes apply without
a reboot. See **[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)**.

## Configuration reference

`/data/adb/clarifae/config.conf` is the source of truth (edited by the WebUI/`clarifae-ctl`)
and is mirrored to system properties the effect reads:

| Key / property `persist.clarifae.*` | Values | Default | Meaning |
|---|---|---|---|
| `enabled`  | `0` / `1` | `1` | Master on/off (bypass = passthrough) |
| `mode`     | `1` / `2` / `3` | `1` | RNNoise / DTLN / DeepFilterNet |
| `strength` | `0`–`100` | `70` | Wet/dry blend of the cleaned signal |
| `atten_db` | `0`–`60` | `24` | Max suppression depth (protects tone) |
| `vad`      | `0`–`100` | `50` | Voice-activity sensitivity (gate / auto-gain) |
| `targets`  | csv of `mic,voice_comm,camcorder,voice_rec` | `mic,voice_comm` | Capture sources to attach to |
| `highpass` | `0` / `1` | `1` | DC/rumble high-pass pre-filter |
| `autogain` | `0` / `1` | `0` | Gentle make-up gain on speech |
| `loglevel` | `0`–`3` | `1` | logcat verbosity (tag `Clarifae`) |

The Clarifae effect UUID is `c1a71fae-0001-4a5e-9b10-43578768aaf3` (type = AOSP noise-suppression).

## `clarifae-ctl` commands

```
clarifae-ctl get                 # print config.conf
clarifae-ctl get-json            # settings as JSON
clarifae-ctl set KEY VALUE       # validate + write config + sync property
clarifae-ctl set-many K=V K=V…   # batch set
clarifae-ctl apply               # push all config -> persist.clarifae.*
clarifae-ctl status              # human-readable engine status
clarifae-ctl status-json         # status as JSON (used by the WebUI)
clarifae-ctl restart-audio       # respawn audioserver to reload effects
clarifae-ctl reset               # restore defaults
clarifae-ctl log                 # tail ctl log + logcat -s Clarifae
clarifae-ctl version
```

## Limitations & caveats

- **Auto-attach is device-dependent.** It edits the device's `audio_effects.xml` via an
  overlay. Some vendors use non-standard formats/locations; if patching fails the library is
  still installed and you can attach it manually (see
  [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)).
- **Not every app gets cleaned.** Pre-processing effects apply per capture *audio source*.
  Apps that open exotic sources, use their own DSP, or hold a raw/`unprocessed` source may
  bypass it. Newly opened capture sessions pick up changes; some need a `restart-audio`.
- **SELinux/vendor variance.** `persist.clarifae.*` live under `default_prop`; a defensive
  `sepolicy.rule` is included for stricter devices.
- **DTLN/DeepFilterNet are experimental** and require extra runtimes/models; without them
  Clarifae uses RNNoise.
- Real-time enhancement adds a small fixed latency (~10 ms for RNNoise + resampler).

## Licensing & credits

Clarifae module code is provided as-is for the brand owner. It builds on:

- **RNNoise** — BSD-3-Clause — <https://github.com/xiph/rnnoise>
- **DeepFilterNet** — MIT / Apache-2.0 — <https://github.com/Rikorose/DeepFilterNet>
- **DTLN** — see repo — <https://github.com/breizhn/DTLN> · web: <https://github.com/sapphi-red/DTLN-web>
- **RNNoise voice plugin** — <https://github.com/werman/noise-suppression-for-voice>
- **DTLN-AEC** (echo cancellation) — <https://github.com/breizhn/DTLN-aec>
- The vendored `native/include/audio_effect.h` is a trimmed AOSP-compatible ABI header
  (Apache-2.0, The Android Open Source Project).

Verify each upstream license before redistribution. TensorFlow Lite (DTLN backend) is
Apache-2.0.
