# Véloce engine

An independent, persistent Python process speaks JSON Lines over stdin/stdout. It is reusable by Famulus or any other client; it does not depend on AppKit, microphone capture, the clipboard, or the Véloce UI. All inference stays on the Mac. Model files download from Hugging Face only when `load` needs uncached assets. Telemetry is disabled.

## Setup

Requires Apple Silicon, macOS, and [uv](https://docs.astral.sh/uv/getting-started/installation/).

```sh
bash Engine/bootstrap.sh
# Optional Parakeet backend:
bash Engine/bootstrap.sh --parakeet
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
python3 -m unittest -v test_worker.py
```

Protocol tests need no third-party package and do not download models. They verify warm model reuse, switching/failure state, audio validation, malformed requests, and separation of inference logs from JSON responses. Real model smoke tests and French quality evaluation are separate; see `../docs/research-asr.md`.

`smoke.py` measures real models one at a time and also tests two seconds of digital silence. Run it when no build or other GPU workload is active; concurrent models and memory pressure can invalidate the timing.

```sh
VELOCE_MODEL_CACHE="$PWD/.models" .venv/bin/python smoke.py /tmp/french.wav \
  --models qwen3-0.6b qwen3-1.7b parakeet-v3 --repeats 3 \
  --output ../docs/benchmarks/local-smoke.json
```
