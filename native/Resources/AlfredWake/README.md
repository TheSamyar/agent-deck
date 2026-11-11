# Dedicated Alfred wake detector

This worker performs acoustic inference only. Swift owns the microphone and passes
16 kHz mono signed int16 little-endian PCM over a private pipe. The worker emits
only readiness, candidate wake scores, and errors. It never opens a microphone,
transcribes ambient speech, sends audio to a server, or stores audio.

## Candidate model status

The included manifest points to the community **Alfred** English model from
fwartner/home-assistant-wakewords-collection at immutable commit
8bcd2f20bb7b76c351b2eff871fa1ce873fe9be2. It is not a model trained by this app.
Its classifier detects Alfred; a candidate starts on-device speech recognition
using a memory-only two-second preroll. Only finalized utterances anchored with
**Hey Alfred** reach the existing command router. Candidate detection alone cannot
approve or execute anything. The detector is suspended during Alfred playback.

`validated_acoustically` remains false. Do not enable hands-free by default or
advertise recognition accuracy from the included candidate. A local synthetic
Samantha voice test peaked at 0.481 and did not trigger the conservative 0.7
threshold; this is an observed limitation, not a measured user false-reject rate.
Manual Listen continues to work if runtime/model/setup is unavailable.

## Provenance and licenses

- Classifier source: https://github.com/fwartner/home-assistant-wakewords-collection/tree/8bcd2f20bb7b76c351b2eff871fa1ce873fe9be2/en/alfred
- Collection repository: MIT license, copyright 2023 Florian Wartner. Preserve its license when redistributing weights. Training-data provenance is not separately documented there; do not infer unrestricted commercial training rights from the repository license.
- Runtime source: https://github.com/dscripka/openWakeWord (Apache-2.0 code).
- Feature and VAD assets: immutable v0.5.1 release URLs and SHA-256 in the manifest. Upstream describes included pretrained models as CC BY-NC-SA 4.0. Treat the installed candidate package as personal evaluation until distribution provenance is reviewed.
- Package dependencies retain their respective installed license metadata. This app does not silently substitute the upstream Hey Jarvis classifier for Alfred.

## Setup and checks

Run setup with Python 3.11+, never system Python 3.9. Setup downloads only on an
explicit installation action, verifies asset hashes, installs pinned dependencies,
and checks real model initialization. App launch performs no downloads. Swift and
worker independently reject invalid manifests/checksums. The queue holds at most
32 KiB pending PCM plus a 64 KiB preroll; stale data is cleared on Stop.

```
python3.11 setup.py
python3 test_worker.py
ALFRED_WAKE_TEST_ROOT=/path/to/AlfredWake ALFRED_WAKE_TEST_PYTHON=/path/to/AlfredWake/venv/bin/python python3 test_worker.py
```

## Reproducible training/calibration gate

Use upstream's automated model-training notebook, not a renamed existing model:
https://github.com/dscripka/openWakeWord/blob/main/notebooks/automatic_model_training.ipynb
Generate several thousand English **Hey Alfred** positives with multiple licensed
TTS voices/speeds, record permitted dataset licenses and seeds, and supply licensed
negative speech/music/noise. Train the classifier against the same frozen embedding
and melspectrogram models. Export ONNX and replace `alfred.onnx` in an explicitly
versioned manifest with the new checksum, source, training metadata and thresholds.
Never replace the shipping model or enable the acoustic gate from training loss.

Hold out human recordings and near-miss phrases from training. Evaluate at least
50 intended wake phrases in quiet/noisy settings and two hours of negative music,
conversation and playback. Require at least 95% intended detection and at most
0.5 false candidates/hour, then repeat music/Discord start-stop and device tests.
Do not lower the threshold solely to pass one synthetic positive. Keep model
training/comprehensive acoustic validation marked incomplete until these checks
have actual results. No training or human accuracy result is fabricated here.
