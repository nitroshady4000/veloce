# Véloce engine

An independent, persistent Python process speaks JSON Lines over stdin/stdout. It is reusable by Famulus or any other client; it does not depend on AppKit, microphone capture, the clipboard, or the Véloce UI. All inference stays on the Mac. Model files download from Hugging Face only when `load` needs uncached assets. Telemetry is disabled.

## Setup

Requires Apple Silicon, macOS, and [uv](https://docs.astral.sh/uv/getting-started/installation/).

```sh
bash Engine/bootstrap.sh
# Optional Parakeet backend:
bash Engine/bootstrap.sh --parakeet
# Optional local speaker detection (may be combined with --parakeet):
bash Engine/bootstrap.sh --meetings
Engine/.venv/bin/python -u Engine/worker.py
```

`uv.lock` pins all transitive dependencies. `bootstrap.sh` uses Python 3.12, preferring an installed compatible interpreter; uv may download Python when missing. The venv is a development environment, not a relocatable distribution runtime. A signed release needs an embedded Python runtime with license notices and an installation test on a clean Mac.

Run setup from the app only after an explicit setup action. Never invoke shell snippets constructed from user text. Pass process arguments as separate values.

## Protocol version 1

Each request needs a unique string or integer `id`. The worker handles one request at a time on the same thread, retaining its model between recordings. Its stdout contains JSON only; diagnostics go to stderr. Consume both pipes concurrently.

```json
{"id":"1","method":"status"}
{"id":"2","method":"load","params":{"model":"qwen3-1.7b"}}
{"id":"3","method":"transcribe","params":{"model":"qwen3-1.7b","audio_path":"/tmp/recording.wav","language":"French","context":"Culturespaces Ableton Pro Tools"}}
{"id":"4","method":"unload"}
```

Boot notification: `{"event":"ready","protocol_version":1}`. Status notifications use `event: "status"`, `state: "loading" | "ready" | "transcribing"`, and `model`. A model load may take minutes the first time. The `ready` boot event means the process is available, not that model weights are loaded.

Responses are `{"id":"3","result":{...}}` or `{"id":"3","error":{"code":"...","message":"..."}}`. A transcript result includes `text`, `language`, `model`, `audio_duration_seconds`, and `inference_seconds`. The elapsed inference time excludes model loading and the client's capture/paste overhead. `status` and `models` return the current state plus the catalog.

`load` is explicit. `transcribe` returns `model_not_loaded` for an unloaded or different model; it never silently downloads a new model. `load` releases the old model before loading a replacement. A failed load leaves the engine idle. Cancel an in-flight call by terminating the worker and restarting it; protocol cancellation is not implemented.

Audio must be a local mono 16 kHz 16-bit PCM WAV, at most 300 seconds. The client owns and deletes its temporary audio. The worker does not keep audio or transcript history. No FFmpeg is required for this contract. Language may be `null` for automatic detection. Qwen supports context vocabulary; Parakeet auto-detects the language and ignores context. Read each model's capability flags when building a client UI.

## Meetings

The same persistent worker accepts aligned, separate microphone/system tracks.
Their first sample must describe the same capture timestamp; a client must write
silence for a missing track rather than remove gaps. Both are mono 16 kHz PCM16
WAV files. The UI stops recording at four hours; the engine accepts an additional
five minutes solely to accommodate delayed capture finalization. It never deletes
or rewrites these source files. Meeting capture and storage belong to the client.

```json
{"id":"5","method":"prepare_diarization"}
{"id":"6","method":"transcribe_meeting","params":{"microphone_path":"/local/microphone.wav","system_path":"/local/system.wav","model":"qwen3-0.6b","language":"French","context":"Véloce Famulus","diarize":true}}
{"id":"7","method":"export_meeting_audio","params":{"microphone_path":"/local/microphone.wav","system_path":"/local/system.wav","output_path":"/local/meeting-stereo.wav"}}
```

`transcribe_meeting` requires the selected ASR model already loaded. It returns
`{text, segments, duration, diarization}`. Each segment has `id`, `start` and `end`
(seconds from recording start), `speaker`, `source` (`microphone` or `system`),
and `text`. Timestamps describe audio passages, not word alignment. Progress uses
`{event:"meeting_progress", progress:0.0, detail:"…"}` through 1.0. Cancellation
uses the existing worker termination mechanism; source audio remains available
for retry. Temporary ASR chunks are managed by a private temporary directory.

With `diarize:false`, labels are **Vous** and **Participants**; the result says
`diarization:"tracks-only"`. This is track separation, not speaker detection.
The microphone is assumed to contain one local speaker. With `diarize:true`, the
system track is split using neural segmentation and voice embedding clustering;
labels become **Interlocuteur 1**, **Interlocuteur 2**, etc., and the result says
`diarization:"sherpa-onnx-pyannote-wespeaker"`. Labels are acoustic clusters, never
an assertion of a person's identity. Embeddings exist only during that request.

`prepare_diarization` is the only operation that may download the optional 28 MB
speaker models. It verifies SHA-256 hashes and loads both ONNX graphs before
returning `{diarization_ready:true}`. Run `bootstrap.sh --meetings` first; it
installs pinned **sherpa-onnx 1.13.8** and **sherpa-onnx-core 1.13.8**, preserving
previously installed optional backends. `status`/`models` include
`diarization_ready`; a missing installation/cache produces an explicit error,
never a silent fallback or download during transcription. `VELOCE_OFFLINE=1`
also applies to preparation. The normal dictation installation remains small.

Audio reads are bounded: ASR uses passages of at most 40 seconds, prefers pauses,
and overlaps a forced cut by 1.5 seconds. Matching word suffixes/prefixes are
deduplicated only at forced overlaps. The digital-silence gate is conservative;
it is not a trained speech/noise classifier. Diarization runs in five-minute CPU
blocks with two seconds of surrounding context. Normalized voice prototypes
connect blocks using a conservative cosine match, so the full meeting waveform
is never held in RAM. Short turns, simultaneous speech, similar voices, music,
speakerphone echo and changes of microphone can cause errors. In particular,
this does not separate overlapping voices into clean individual audio tracks.
It has not yet been evaluated on a representative French meeting corpus.

`export_meeting_audio` streams a stereo WAV: **microphone left, system right**.
It zero-pads the shorter track and returns `{path,duration,channels:2}`. Export
publishes atomically and refuses to overwrite existing files or source tracks.
The two original mono files remain available for editing in an audio workstation.

Speaker model provenance (immutable revisions and hashes are in `meetings.py`):

- [Pyannote segmentation 3.0, sherpa ONNX conversion](https://huggingface.co/csukuangfj/sherpa-onnx-pyannote-segmentation-3-0), INT8, **MIT**, by Hervé Bredin / pyannote.audio; conversion by Fangjun Kuang. Original weights are unchanged apart from ONNX conversion/quantization upstream.
- [WeSpeaker VoxCeleb ResNet34 LM](https://huggingface.co/Wespeaker/wespeaker-voxceleb-resnet34-LM), **CC-BY-4.0**, by the WeSpeaker team; [sherpa ONNX conversion](https://huggingface.co/csukuangfj/speaker-embedding-models). WeSpeaker: A Research and Production oriented Speaker Embedding Learning Toolkit, Wang et al., ICASSP 2023. Véloce does not alter these upstream converted weights.
- [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx), **Apache-2.0**; [official Python diarization example](https://k2-fsa.github.io/sherpa/onnx/speaker-diarization/python.html) and [model documentation](https://k2-fsa.github.io/sherpa/onnx/speaker-diarization/models.html).

A September 30, 2026 smoke check on M2 Pro used 32.74 seconds of offline macOS
synthetic French speech (Thomas → Amélie → Thomas). Real ONNX inference returned
the expected 1 → 2 → 1 clusters in 6.94 seconds, without loading a second ASR
model. A separate check forced 11-second blocks to exercise cross-block voice
matching; the same main labels persisted, with roughly 0.1–0.2 second boundary
fragments misattributed. This is an integration smoke check, not a quality or
speed benchmark on real meetings.

A conservative amplitude gate returns empty text without running ASR when the recording's peak never exceeds 16 PCM units (about −66 dBFS). This blocks the observed Qwen hallucinations on digital silence. It is not a VAD and does not distinguish room noise/music from speech; extremely quiet recordings below this threshold are also ignored.

Models: `qwen3-1.7b` (8-bit, ~2.5 GB), `qwen3-0.6b` (8-bit, ~1 GB), `parakeet-v3` (~2.5 GB). Download sizes are not peak RAM usage. Catalog revisions are immutable commits in `worker.py`.

Environment:

- `VELOCE_MODEL_CACHE`: defaults to `~/Library/Caches/Veloce/models`. For development use `$PWD/Engine/.models`.
- `VELOCE_OFFLINE=1`: forbids fetching missing model files. Already cached models continue working.
- `VELOCE_UV_BIN`: optional absolute uv path for setup.
- `UV_CACHE_DIR` and `UV_PYTHON_INSTALL_DIR`: optional setup cache/runtime locations.

The app locates this directory itself (`VELOCE_ENGINE_DIR` is an app setting); pass the absolute `.venv/bin/python` and `worker.py` paths to `Process`.

## Verification

```sh
cd Engine
python3 -m unittest discover -p 'test_*.py' -v
```

Protocol tests need no third-party package and do not download models. They verify warm model reuse, switching/failure state, audio validation, malformed requests, and separation of inference logs from JSON responses. Real model smoke tests and French quality evaluation are separate; see `../docs/research-asr.md`.

`smoke.py` measures real models one at a time and also tests two seconds of digital silence. Run it when no build or other GPU workload is active; concurrent models and memory pressure can invalidate the timing.

```sh
VELOCE_MODEL_CACHE="$PWD/.models" .venv/bin/python smoke.py /tmp/french.wav \
  --models qwen3-0.6b qwen3-1.7b parakeet-v3 --repeats 3 \
  --output ../docs/benchmarks/local-smoke.json
```
