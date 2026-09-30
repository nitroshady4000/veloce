#!/usr/bin/env python3
"""Persistent, single-threaded JSONL worker. No microphone access or audio upload.

Launch: .venv/bin/python -u worker.py
Model loading is explicit; importing this module never loads MLX or downloads data.
"""
from __future__ import annotations

from array import array
import contextlib
import gc
import importlib.util
import json
import os
from pathlib import Path
import sys
import time
import wave

os.environ.setdefault("HF_HUB_DISABLE_TELEMETRY", "1")
os.environ.setdefault("HF_HUB_DISABLE_PROGRESS_BARS", "1")
os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")

PROTOCOL_VERSION = 1
MAX_AUDIO_SECONDS = 300
MAX_REQUEST_BYTES = 65_536
MODELS = {
    "qwen3-0.6b": {
        "name": "Qwen3 ASR · Rapide", "backend": "qwen",
        "repository": "mlx-community/Qwen3-ASR-0.6B-8bit",
        "revision": "89e96d92ba34aca20b3e29fb10cc284097d1219f",
        "download_bytes": 1_010_772_853, "license": "Apache-2.0",
        "supports_context": True, "supports_language": True,
    },
    "qwen3-1.7b": {
        "name": "Qwen3 ASR · Précision", "backend": "qwen",
        "repository": "mlx-community/Qwen3-ASR-1.7B-8bit",
        "revision": "a8379a2e2f9e313c9292cdf1af4055ab56d50d55",
        "download_bytes": 2_467_858_122, "license": "Apache-2.0",
        "supports_context": True, "supports_language": True,
    },
    "parakeet-v3": {
        "name": "Parakeet v3 · Alternative", "backend": "parakeet",
        "repository": "mlx-community/parakeet-tdt-0.6b-v3",
        "revision": "ed2b7e8c15f9aaa0b5772e2efb986255eaef7e15",
        "download_bytes": 2_509_041_850, "license": "CC-BY-4.0",
        "supports_context": False, "supports_language": False,
    },
}


class EngineError(Exception):
    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code


def validate_audio(path: str) -> tuple[Path, float]:
    """Accept bounded mono PCM WAV only; conversion belongs to the audio client."""
    if not isinstance(path, str) or not path:
        raise EngineError("invalid_audio", "audio_path must be a local WAV path.")
    source = Path(path).expanduser().resolve()
    if not source.is_file():
        raise EngineError("audio_not_found", "The recorded audio file does not exist.")
    try:
        with wave.open(str(source), "rb") as audio:
            if (audio.getnchannels(), audio.getframerate(), audio.getsampwidth(), audio.getcomptype()) != (1, 16000, 2, "NONE"):
                raise EngineError("invalid_audio", "Expected mono 16 kHz, 16-bit PCM WAV.")
            duration = audio.getnframes() / 16000
    except (wave.Error, EOFError) as error:
        raise EngineError("invalid_audio", "The recording is not a readable PCM WAV.") from error
    if duration <= 0 or duration > MAX_AUDIO_SECONDS:
        raise EngineError("invalid_audio", f"Recording must contain 0–{MAX_AUDIO_SECONDS} seconds of audio.")
    return source, duration


def is_effectively_silent(path: Path) -> bool:
    """Conservative amplitude gate: peak at or below 16/32768 (~−66 dBFS).

    This protects empty recordings; it is deliberately not presented as speech
    activity detection and will not reject ordinary room noise or music.
    """
    with wave.open(str(path), "rb") as audio:
        while data := audio.readframes(4096):
            samples = array("h", data)
            if sys.byteorder != "little":
                samples.byteswap()
            if any(abs(sample) > 16 for sample in samples):
                return False
    return True


class QwenBackend:
    def __init__(self, model_path: str):
        from mlx_qwen3_asr import Session
        import mlx.core as mx
        import numpy as np
        mx.set_cache_limit(128 * 1024 * 1024)
        self.session = Session(model=model_path)
        # Compile Metal kernels before declaring the model ready. The output is
        # discarded; no microphone or user audio is involved in this warmup.
        self.session.transcribe(np.zeros(16000, dtype=np.float32), language="French", max_new_tokens=1)

    def transcribe(self, path: Path, language: str | None, context: str) -> dict:
        result = self.session.transcribe(str(path), language=language, context=context, verbose=False)
        if getattr(result, "truncated", False):
            raise EngineError("truncated_transcript", "The model reached its output limit. Try a shorter recording.")
        return {"text": result.text.strip(), "language": result.language}


class ParakeetBackend:
    def __init__(self, model_path: str):
        from parakeet_mlx import from_pretrained
        from parakeet_mlx.audio import get_logmel
        import mlx.core as mx
        mx.set_cache_limit(128 * 1024 * 1024)
        self.model = from_pretrained(model_path)
        # As for Qwen, absorb first-use Metal compilation in explicit loading.
        mel = get_logmel(mx.zeros((16000,), dtype=mx.float32), self.model.preprocessor_config)
        self.model.generate(mel.astype(mx.bfloat16))

    def transcribe(self, path: Path, language: str | None, context: str) -> dict:
        # Use PCM directly: parakeet's file loader calls ffmpeg, unnecessary for dictation.
        import mlx.core as mx
        import numpy as np
        from parakeet_mlx.audio import get_logmel
        with wave.open(str(path), "rb") as audio:
            samples = np.frombuffer(audio.readframes(audio.getnframes()), dtype="<i2").astype(np.float32) / 32768.0
        # MLX 0.32 FFT emits complex64: parakeet's get_logmel reinterprets it
        # using the waveform dtype, so feeding bfloat16 breaks the bin shape.
        # Keep the FFT frontend float32 and match the model dtype afterwards.
        mel = get_logmel(mx.array(samples), self.model.preprocessor_config).astype(mx.bfloat16)
        result = self.model.generate(mel)[0]
        return {"text": result.text.strip(), "language": None}


def make_backend(model_id: str):
    spec = MODELS[model_id]
    module = "mlx_qwen3_asr" if spec["backend"] == "qwen" else "parakeet_mlx"
    if importlib.util.find_spec(module) is None:
        setup = "Engine/bootstrap.sh" + (" --parakeet" if spec["backend"] == "parakeet" else "")
        raise EngineError("dependency_missing", f"Run {setup} to install this engine.")
    from huggingface_hub import snapshot_download
    cache = os.environ.get("VELOCE_MODEL_CACHE", str(Path.home() / "Library/Caches/Veloce/models"))
    model_path = snapshot_download(
        repo_id=spec["repository"], revision=spec["revision"], cache_dir=cache,
        allow_patterns=["*.json", "*.safetensors", "*.txt", "*.model", "*.vocab"],
        local_files_only=os.environ.get("VELOCE_OFFLINE") == "1",
    )
    return QwenBackend(model_path) if spec["backend"] == "qwen" else ParakeetBackend(model_path)


class Engine:
    def __init__(self, emit=lambda _event: None, backend_factory=make_backend):
        self.emit = emit
        self.backend_factory = backend_factory
        self.backend = None
        self.model_id = None

    def unload(self):
        self.backend = None
        self.model_id = None
        gc.collect()
        if "mlx.core" in sys.modules:
            sys.modules["mlx.core"].clear_cache()

    def handle(self, request: dict) -> dict:
        if not isinstance(request, dict):
            raise EngineError("invalid_request", "Request must be a JSON object.")
        method = request.get("method")
        params = request.get("params", {})
        if not isinstance(params, dict):
            raise EngineError("invalid_request", "params must be an object.")
        if method in ("status", "models"):
            return {"protocol_version": PROTOCOL_VERSION, "state": "ready" if self.backend else "idle",
                    "model": self.model_id, "models": [{"id": key, **value} for key, value in MODELS.items()]}
        if method == "unload":
            self.unload()
            return {"state": "idle", "model": None}
        if method == "load":
            model_id = params.get("model")
            if model_id not in MODELS:
                raise EngineError("unknown_model", "Choose a model from the models response.")
            if self.model_id != model_id:
                self.unload()
                self.emit({"event": "status", "state": "loading", "model": model_id})
                self.backend = self.backend_factory(model_id)
                self.model_id = model_id
            self.emit({"event": "status", "state": "ready", "model": model_id})
            return {"state": "ready", "model": model_id}
        if method == "transcribe":
            model_id = params.get("model", self.model_id)
            if self.backend is None or model_id != self.model_id:
                raise EngineError("model_not_loaded", "Load the selected model before recording.")
            path, duration = validate_audio(params.get("audio_path"))
            context = params.get("context", "")
            language = params.get("language")
            if not isinstance(context, str) or len(context) > 4000:
                raise EngineError("invalid_request", "context must be a string of at most 4000 characters.")
            if language is not None and (not isinstance(language, str) or len(language) > 64):
                raise EngineError("invalid_request", "language must be a language name or null.")
            if is_effectively_silent(path):
                return {"text": "", "language": language or None, "model": model_id,
                        "audio_duration_seconds": duration, "inference_seconds": 0.0,
                        "silence_detected": True}
            self.emit({"event": "status", "state": "transcribing", "model": model_id})
            started = time.perf_counter()
            try:
                result = self.backend.transcribe(path, language or None, context)
            finally:
                self.emit({"event": "status", "state": "ready", "model": model_id})
            return {**result, "model": model_id, "audio_duration_seconds": duration,
                    "inference_seconds": round(time.perf_counter() - started, 4)}
        raise EngineError("unknown_method", "Supported methods: status, models, load, transcribe, unload.")


def serve(input_stream=sys.stdin, output_stream=sys.stdout, engine_factory=Engine):
    def emit(payload):
        output_stream.write(json.dumps(payload, ensure_ascii=False, allow_nan=False) + "\n")
        output_stream.flush()

    engine = engine_factory(emit=emit)
    emit({"event": "ready", "protocol_version": PROTOCOL_VERSION})
    while True:
        line = input_stream.readline(MAX_REQUEST_BYTES + 1)
        if not line:
            break
        request_id = None
        try:
            if len(line.encode("utf-8")) > MAX_REQUEST_BYTES:
                # Consume the remaining line so a broken client cannot split one request.
                while not line.endswith("\n"):
                    line = input_stream.readline(MAX_REQUEST_BYTES + 1)
                    if not line:
                        break
                raise EngineError("invalid_request", "Request exceeds 64 KiB.")
            request = json.loads(line)
            if isinstance(request, dict):
                request_id = request.get("id")
            if not isinstance(request_id, (str, int)) or isinstance(request_id, bool):
                raise EngineError("invalid_request", "A string or integer request id is required.")
            # Third-party Python prints must never corrupt the protocol.
            with contextlib.redirect_stdout(sys.stderr):
                result = engine.handle(request)
            emit({"id": request_id, "result": result})
        except json.JSONDecodeError:
            emit({"id": None, "error": {"code": "invalid_json", "message": "Invalid JSON request."}})
        except EngineError as error:
            emit({"id": request_id, "error": {"code": error.code, "message": str(error)}})
        except Exception as error:
            print(f"{type(error).__name__}: {error}", file=sys.stderr, flush=True)
            emit({"id": request_id, "error": {"code": "engine_error", "message": str(error)}})
    engine.unload()


if __name__ == "__main__":
    serve()
