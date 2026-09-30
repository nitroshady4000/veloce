# Third-party notices

Véloce's own code is licensed under MIT. Dependencies and model weights retain their respective licenses. At the owner's request, the interface follows Famulus's **Feu follet** design (`app/poc/Pill.swift`, `Magic.swift`, `Skin.swift`, `SkinFeuFollet.swift`): warm dark glass, its palette and proportions, the voice envelope and animation timing. The app icon's V and the compact Metal renderer are original Véloce implementations. The dictation pill has no logo or mascot; the flame mascot and its artwork are not included. Famulus itself is not a runtime dependency and is not modified by this project.

## Speech runtimes and weights

| Component | Version / immutable revision | License / attribution |
| --- | --- | --- |
| [mlx-qwen3-asr](https://github.com/moona3k/mlx-qwen3-asr) | 0.4.4 | Apache-2.0; moona3k and contributors |
| [parakeet-mlx](https://github.com/senstella/parakeet-mlx) (optional) | 0.5.2 | Apache-2.0; senstella and contributors |
| [MLX / MLX Metal](https://github.com/ml-explore/mlx) | 0.32.3 | MIT; Apple Inc. and contributors |
| [Qwen3-ASR 0.6B, MLX 8-bit](https://huggingface.co/mlx-community/Qwen3-ASR-0.6B-8bit) | `89e96d92ba34aca20b3e29fb10cc284097d1219f` | Apache-2.0; Qwen team, Alibaba Cloud; quantized conversion by mlx-community |
| [Qwen3-ASR 1.7B, MLX 8-bit](https://huggingface.co/mlx-community/Qwen3-ASR-1.7B-8bit) | `a8379a2e2f9e313c9292cdf1af4055ab56d50d55` | Apache-2.0; Qwen team, Alibaba Cloud; quantized conversion by mlx-community |
| [Parakeet TDT 0.6B v3, MLX conversion](https://huggingface.co/mlx-community/parakeet-tdt-0.6b-v3) | `ed2b7e8c15f9aaa0b5772e2efb986255eaef7e15` | [CC-BY-4.0](https://creativecommons.org/licenses/by/4.0/); NVIDIA; MLX conversion by mlx-community |

The Parakeet weights are adapted from [NVIDIA's original model](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3). The referenced conversion changes the storage/runtime format; Véloce does not change the converted weights. Attribution does not imply endorsement by NVIDIA, Alibaba Cloud, Apple, or other contributors.

Python dependency versions and artifact hashes are recorded in `Engine/uv.lock`. Dependency distributions include their own license files. Preserve these files when assembling a release, including notices for bundled numerical libraries. This source checkout installs dependencies locally; it does not yet redistribute a bundled Python runtime.

## Installed dependency license inventory

### Meeting speaker detection

| Component | Version / immutable revision | License / attribution |
| --- | --- | --- |
| [Sherpa ONNX](https://github.com/k2-fsa/sherpa-onnx) (`sherpa-onnx`, `sherpa-onnx-core`) | 1.13.8 | Apache-2.0; k2-fsa and contributors |
| [Pyannote segmentation 3.0, ONNX int8 conversion](https://huggingface.co/csukuangfj/sherpa-onnx-pyannote-segmentation-3-0) | `9403a6902bb58e3d5ae8c7e77c3422de279db2e0` | MIT; pyannote contributors, conversion distributed by csukuangfj |
| [WeSpeaker ResNet34 LM, ONNX conversion](https://huggingface.co/csukuangfj/speaker-embedding-models) | `0743f301363dec56491a490f6d6cbc9d67f9a3bf` | [CC-BY-4.0](https://creativecommons.org/licenses/by/4.0/); [WeSpeaker](https://github.com/wenet-e2e/wespeaker) contributors, ONNX distribution by csukuangfj |

The model conversions change storage/runtime representation. Véloce uses these converted weights unchanged, downloads them explicitly, and verifies their SHA-256 hashes. Attribution does not imply endorsement. Apple's ScreenCaptureKit and optional Foundation Models framework are system dependencies under Apple's platform terms; the meeting summary uses `SystemLanguageModel`, never Private Cloud Compute. No MacParakeet source code is incorporated in the meeting implementation; its public audio design informed the choice to retain independent tracks and export microphone-left/system-right stereo.

### Base speech environment

The following inventory is extracted from the locked macOS Python 3.12 environment on 2026-09-30, including the optional Parakeet extra. Package metadata may use broader names such as “BSD”; the distribution's actual license files remain authoritative. Optional audio packages include LGPL components and must retain their corresponding notices and redistribution terms if bundled.

| Package | Version | Declared license |
| --- | --- | --- |
| annotated-doc | 0.0.5 | MIT |
| anyio | 4.15.1 | MIT |
| certifi | 2026.7.22 | MPL-2.0 |
| cffi | 2.1.1 | MIT-0 |
| charset-normalizer | 3.5.2 | MIT |
| click | 8.5.0 | BSD-3-Clause |
| cloudpickle | 3.1.2 | BSD-3-Clause |
| dacite | 1.9.2 | MIT |
| decorator | 5.3.1 | BSD-2-Clause |
| filelock | 4.0.7 | MIT |
| fsspec | 2026.9.0 | BSD-3-Clause |
| h11 | 0.16.0 | MIT |
| hf-xet | 1.6.0 | Apache-2.0 |
| httpcore2 | 2.13.1 | BSD-3-Clause |
| httpx2 | 2.13.1 | BSD-3-Clause |
| huggingface_hub | 2.0.0 | Apache-2.0 |
| idna | 3.20 | BSD-3-Clause |
| joblib | 1.6.0 | BSD-3-Clause |
| lazy-loader | 0.6 | BSD-3-Clause |
| librosa | 1.0.0 | ISC |
| llvmlite | 0.49.0 | BSD-2-Clause AND Apache-2.0 WITH LLVM-exception |
| markdown-it-py | 4.2.0 | OSI Approved :: MIT License |
| mdurl | 0.1.2 | OSI Approved :: MIT License |
| mlx | 0.32.3 | MIT |
| mlx-metal | 0.32.3 | MIT |
| mlx-qwen3-asr | 0.4.4 | Apache-2.0 |
| msgpack | 1.2.3 | Apache-2.0 |
| narwhals | 2.26.0 | MIT |
| numba | 0.67.0 | BSD |
| numpy | 2.5.3 | BSD-3-Clause AND 0BSD AND MIT AND Zlib AND CC0-1.0 |
| packaging | 26.3 | Apache-2.0 OR BSD-2-Clause |
| parakeet-mlx | 0.5.2 | Apache-2.0 |
| platformdirs | 4.12.2 | MIT |
| pooch | 1.9.0 | BSD-3-Clause |
| pycparser | 3.0 | BSD-3-Clause |
| Pygments | 2.21.0 | BSD-2-Clause |
| PyYAML | 6.0.3 | MIT |
| regex | 2026.9.29 | Apache-2.0 AND CNRI-Python |
| requests | 2.34.2 | Apache-2.0 |
| rich | 15.0.0 | MIT |
| scikit-learn | 1.9.1 | BSD-3-Clause |
| scipy | 1.18.1 | OSI Approved :: BSD License |
| shellingham | 1.5.4 | ISC License |
| soundfile | 0.14.0 | BSD 3-Clause License |
| soxr | 1.1.0 | LGPL-2.1-or-later |
| threadpoolctl | 3.7.0 | BSD-3-Clause |
| tqdm | 4.70.1 | MPL-2.0 AND MIT |
| truststore | 0.10.4 | MIT |
| typer | 0.27.2 | MIT |
| typing_extensions | 4.16.0 | PSF-2.0 |
| urllib3 | 2.8.0 | MIT |
