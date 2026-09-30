# Local dictation engine decisions

Research date: 2026-09-30. Scope: hold Fn, dictate in French, release, paste. Meeting diarization and summarization are different workloads and are outside this first app.

## Decision

Use Qwen3-ASR 1.7B 8-bit as the quality profile, with Qwen3-ASR 0.6B 8-bit as a smaller alternative. The supplied preliminary research reports that Qwen beat Parakeet on the user's own French meeting. That is useful evidence for a starting preference, but is neither an available recording nor a reproducible benchmark. We cannot claim a global French SOTA result from it. Parakeet v3 stays an optional speed candidate.

V1 uses a persistent Python worker with `mlx-qwen3-asr==0.4.4`; Parakeet uses optional `parakeet-mlx==0.5.2`. Keeping the process warm avoids process launch and model reload on each Fn release. MLX runs inference locally on Apple's GPU. Both Python implementations are Apache-2.0; Qwen weights are Apache-2.0, while Parakeet v3 weights require CC-BY-4.0 attribution. See [Qwen's model card](https://huggingface.co/Qwen/Qwen3-ASR-1.7B), [Qwen runtime](https://github.com/moona3k/mlx-qwen3-asr), [Parakeet runtime](https://github.com/senstella/parakeet-mlx), and [NVIDIA's model card](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3).

The selected Qwen runtime supports vocabulary context and an explicit reusable `Session`. It has no core PyTorch dependency. We use only PCM WAV, so no FFmpeg, diarization package, web server, or microphone package is needed. The package's own published quality gates are useful upstream evidence, not measurements of Véloce. [Runtime API and release notes](https://github.com/moona3k/mlx-qwen3-asr/releases).

## Alternatives worth measuring

| Candidate | Why it matters | Present decision |
| --- | --- | --- |
| Qwen3-ASR 1.7B / 0.6B | French support, context vocabulary, larger/smaller quality tradeoff | Implemented via pinned MLX Python runtime |
| Parakeet TDT v3 0.6B | 25 European languages, punctuation, fast non-autoregressive decode | Optional MLX adapter; benchmark before claiming lower latency |
| FluidAudio | Native Swift/CoreML, ANE, Parakeet, optional French text normalization | Strong future native speed adapter |
| Whisper / WhisperKit | Mature Apple integration and a broad baseline | Reference comparison, no additional V1 dependency |
| Nemotron 3.5 ASR 0.6B | Genuine cache-aware multilingual streaming, French supported | Next benchmark candidate; not silently substituted |
| Qwen via native MLX Swift | Avoids Python packaging in a distributable app | Revisit after measuring release build and dependency cost |

[FluidAudio](https://github.com/FluidInference/FluidAudio) supports macOS 14+ with a Swift API. Its releases page currently lists 0.17.4; the README's example still says 0.12.4, so pinning from the example alone would be misleading. Its reported ~190× real-time on M4 Pro is throughput on long audio, not Fn-release-to-paste latency, and cannot establish a French accuracy ranking. [Releases](https://github.com/FluidInference/FluidAudio/releases).

[WhisperKit](https://github.com/argmaxinc/argmax-oss-swift) is part of Argmax's MIT open-source Swift SDK. Its open-source Whisper support is distinct from the additional models and services in the Pro SDK. It remains a useful comparison rather than an automatic choice for a new fast dictation app.

[NVIDIA Nemotron 3.5](https://huggingface.co/nvidia/nemotron-3.5-asr-streaming-0.6b) was released in June 2026, supports French (France and Canada), and uses configurable 80–1120 ms chunks. The card lists 32 usable transcription locales plus 8 that require fine-tuning; “40 languages supported” without that qualification would overstate availability. Its OpenMDW-1.1 license differs from the licenses above. A smaller chunk size is not itself an end-to-end app latency guarantee.

Native Qwen integration exists today: [Blaizzy/mlx-audio-swift](https://github.com/Blaizzy/mlx-audio-swift) exposes `Qwen3ASRModel.fromPretrained(...).generate(...)`; [soniqo/speech-swift](https://github.com/soniqo/speech-swift) exposes a separate `Qwen3ASR` target and `transcribe(audio:sampleRate:)`. Their current manifests bring broader audio/LLM dependency graphs. A Python worker is the simpler implementation for this prototype, but a signed standalone app still needs an embedded runtime or a native adapter. Native implementation is not blocked on model availability.

## Reuse in Famulus

Read-only inspection found `famulus/src/famulus/asr.py` already normalizes whisper.cpp/faster-whisper results into word-aligned output. Its September sidecar plan separately compares Apple dictation and Parakeet using domain vocabulary and a 50-phrase command set. No Famulus files were changed. Véloce's JSONL interface is reusable for plain dictation; it does not provide the word timestamps needed to replace Famulus's dialogue navigation backend. Qwen's forced aligner could provide that in a separate optional adapter later.

## How to keep the selection current

Do not update model weights silently. Every candidate update should be a reviewable PR with package lock changes, immutable model revision changes, license attribution, and a recorded comparison against the previous release. GitHub dependency updates can propose runtime bumps, but do not prove model quality.

Build an explicit, consented test corpus of 50–100 short French recordings: natural dictation, names, numbers, punctuation, French/English code switching, technical vocabulary, hesitations, noise, and silence. Include the user's actual microphone and 1–5, 5–15, and 15–60 second utterances. Keep recordings out of Git unless explicitly cleared for public redistribution; synthetic speech is only a smoke check.

Run identical recordings on each candidate on the same Mac. Log OS/SoC/RAM, power mode, library lock, model revision, language/context options, cold loading separately, five warm repetitions, normalized WER/CER, name/number accuracy, empty-audio false output, peak resident memory, and p50/p95 release-to-paste latency. The worker reports inference time; the app must report full latency. Compare warm inference and quality before promoting a profile. Reject a nominal speed improvement that regresses names/numbers or hallucinates silence.

## Initial smoke observations

On the development Mac (M2 Pro, 16 GiB, macOS 27.2), a 6.01-second French phrase generated by macOS's Thomas voice was successfully transcribed by all three models. The final isolated run, after both fixes and load-time warmup, recorded:

| Model | First dictation after ready | Next two dictations | Silence |
| --- | --- | --- | --- |
| Qwen3-ASR 0.6B 8-bit | 0.2543 s | 0.2431 / 0.2412 s | Empty text |
| Qwen3-ASR 1.7B 8-bit | 0.5118 s | 0.5136 / 0.4968 s | Empty text |
| Parakeet v3 | 0.1214 s | 0.0885 / 0.0892 s | Empty text |

The reproducible output is [the final smoke record](benchmarks/smoke-2026-09-30-m2-pro-clean.json). These are a single synthetic phrase and inference-only timings, not a French accuracy benchmark or a latency guarantee. Parakeet was faster on this clip, but that is insufficient evidence for a universal speed claim; its UI profile is named “Alternative”. The quality profile retained “rendez-vous”; the smaller profile omitted the hyphen. Parakeet returned “dicté” for “dictée” and normalized “quatorze heures” to “14h”.

Both Qwen models produced spurious words on two seconds of digital silence. The shipped worker now blocks recordings whose peak stays at or below −66 dBFS before calling any model, and returns empty text. This is a conservative amplitude check, not speech activity detection. The pre-fix observations are preserved in `benchmarks/smoke-2026-09-30-m2-pro-before-fixes.json`.

Overlapping a loaded app model with the benchmark caused severe memory pressure and invalidated later speed runs. Never compare those contended results against the initial measurements. The worker now limits MLX's free-buffer cache to 128 MiB; model weights still require their own memory. Parakeet computes its FFT/mel frontend in float32, then casts the mel features to bfloat16 to match its encoder weights. Passing bfloat16 PCM directly to parakeet-mlx 0.5.2's frontend breaks its FFT-bin reinterpretation with MLX 0.32.3; the adapter avoids that incompatibility. Both model families process one second of synthetic zeros while loading to compile their Metal kernels before declaring readiness.

The repository includes a weekly GitHub Actions report of upstream package releases. It runs once the repository is published and Actions is enabled. This report proposes research work; it does not download new weights or promote a model. No Codex heartbeat or personal notification schedule was created.
