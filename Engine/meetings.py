"""Local, bounded-memory meeting processing. No capture and no implicit download."""
from __future__ import annotations

from array import array
from dataclasses import dataclass
import hashlib
import importlib.metadata
import importlib.util
import math
import os
from pathlib import Path
import re
import shutil
import sys
import tempfile
import wave

from errors import EngineError

RATE = 16000
# UI recording limit is four hours; permit delayed OS capture finalization.
MAX_MEETING_SECONDS = 4 * 60 * 60 + 5 * 60
MAX_CHUNK_SECONDS = 40
CHUNK_OVERLAP_SECONDS = 1.5
DIARIZATION_BLOCK_SECONDS = 300
DIARIZATION_MODELS = {
    "segmentation": {
        "repository": "csukuangfj/sherpa-onnx-pyannote-segmentation-3-0",
        "revision": "9403a6902bb58e3d5ae8c7e77c3422de279db2e0",
        "filename": "model.int8.onnx", "download_bytes": 1540506,
        "sha256": "d582f4b4c6b48205de7e0643c57df0df5615a3c176189be3fc461e9d18827b5d",
        "license": "MIT",
    },
    "embedding": {
        "repository": "csukuangfj/speaker-embedding-models",
        "revision": "0743f301363dec56491a490f6d6cbc9d67f9a3bf",
        "filename": "wespeaker_en_voxceleb_resnet34_LM.onnx", "download_bytes": 26530550,
        "sha256": "e9848563da86f263117134dfd7ad63c92355b37de492b55e325400c9d9c39012",
        "license": "CC-BY-4.0",
    },
}


@dataclass
class AudioSlice:
    start: float
    end: float
    speaker: str
    overlap: bool = False


def validate_track(value: str) -> tuple[Path, float]:
    if not isinstance(value, str) or not value:
        raise EngineError("invalid_audio", "A local meeting WAV path is required.")
    path = Path(value).expanduser().resolve()
    if not path.is_file():
        raise EngineError("audio_not_found", "A meeting audio track is missing.")
    try:
        with wave.open(str(path), "rb") as audio:
            if (audio.getnchannels(), audio.getframerate(), audio.getsampwidth(), audio.getcomptype()) != (1, RATE, 2, "NONE"):
                raise EngineError("invalid_audio", "Meeting tracks must be mono 16 kHz, 16-bit PCM WAV.")
            frames = audio.getnframes()
            duration = frames / RATE
            # Catch a file truncated while recording before producing a partial transcript.
            if frames:
                audio.setpos(frames - 1)
                if len(audio.readframes(1)) != 2:
                    raise EngineError("invalid_audio", "The meeting WAV is truncated; finish recording first.")
    except (wave.Error, EOFError, OSError) as error:
        raise EngineError("invalid_audio", "The meeting track is not a readable PCM WAV.") from error
    if duration <= 0 or duration > MAX_MEETING_SECONDS:
        raise EngineError("invalid_audio", "Meeting tracks must contain audio and be at most four hours plus five minutes long.")
    return path, duration


def _samples(data: bytes) -> array:
    values = array("h", data)
    if sys.byteorder != "little":
        values.byteswap()
    return values


def speech_chunks(path: Path, speaker: str, start: float = 0, end: float | None = None) -> list[AudioSlice]:
    """Conservative energy segmentation, preserving context around bounded cuts.

    This is an amplitude gate, not a learned VAD. Room noise can reach ASR.
    Prefer pauses after 12 seconds; forced 40-second cuts overlap by 1.5s.
    """
    result = []
    with wave.open(str(path), "rb") as audio:
        first = max(0, int(start * RATE))
        limit = min(audio.getnframes(), int(end * RATE) if end is not None else audio.getnframes())
        audio.setpos(first)
        position = first
        active_start = None
        last_active_end = first
        is_overlap = False
        while position < limit:
            data = audio.readframes(min(320, limit - position))
            if not data:
                break
            next_position = position + len(data) // 2
            # Same very conservative digital-silence gate as dictation.
            active = any(abs(sample) > 16 for sample in _samples(data))
            if active:
                if active_start is None:
                    active_start = max(first, position - int(.15 * RATE))
                last_active_end = next_position
            if active_start is not None:
                length = (next_position - active_start) / RATE
                pause = (next_position - last_active_end) / RATE
                if pause >= .5 and length >= 12:
                    result.append(AudioSlice(active_start / RATE, min(limit, last_active_end + int(.15 * RATE)) / RATE, speaker, is_overlap))
                    active_start = None
                    is_overlap = False
                elif length >= MAX_CHUNK_SECONDS:
                    cut = active_start + MAX_CHUNK_SECONDS * RATE
                    result.append(AudioSlice(active_start / RATE, cut / RATE, speaker, is_overlap))
                    # Rewind through a little context, without retaining the whole recording.
                    position = cut - int(CHUNK_OVERLAP_SECONDS * RATE)
                    audio.setpos(position)
                    active_start = position
                    last_active_end = position
                    is_overlap = True
                    continue
            position = next_position
        if active_start is not None and last_active_end > active_start:
            result.append(AudioSlice(active_start / RATE, min(limit, last_active_end + int(.15 * RATE)) / RATE, speaker, is_overlap))
    return result


def write_slice(source: Path, destination: Path, start: float, end: float):
    with wave.open(str(source), "rb") as audio, wave.open(str(destination), "wb") as out:
        out.setparams((1, 2, RATE, 0, "NONE", "not compressed"))
        first, last = round(start * RATE), round(end * RATE)
        audio.setpos(first)
        remaining = last - first
        while remaining > 0:
            data = audio.readframes(min(16000, remaining))
            if not data:
                raise EngineError("invalid_audio", "The meeting track ended unexpectedly.")
            out.writeframesraw(data)
            remaining -= len(data) // 2


def remove_overlap(previous: str, current: str) -> str:
    """Remove only an exact normalized word suffix/prefix (minimum two words)."""
    words = list(re.finditer(r"\S+", current))
    left = [re.sub(r"[^\w]", "", word).casefold() for word in previous.split()]
    right = [re.sub(r"[^\w]", "", match.group()).casefold() for match in words]
    for count in range(min(24, len(left), len(right)), 1, -1):
        if left[-count:] == right[:count] and all(right[:count]):
            return current[words[count - 1].end():].lstrip()
    return current


def _cache_root() -> Path:
    return Path(os.environ.get("VELOCE_MODEL_CACHE", str(Path.home() / "Library/Caches/Veloce/models")))


def _model_paths(download: bool = False) -> dict[str, Path]:
    if importlib.util.find_spec("sherpa_onnx") is None:
        raise EngineError("dependency_missing", "Run Engine/bootstrap.sh --meetings to install speaker detection.")
    try:
        importlib.metadata.version("sherpa-onnx-core")
    except importlib.metadata.PackageNotFoundError as error:
        raise EngineError("dependency_missing", "Run Engine/bootstrap.sh --meetings to install the ONNX runtime.") from error
    from huggingface_hub import hf_hub_download
    paths = {}
    for name, spec in DIARIZATION_MODELS.items():
        try:
            paths[name] = Path(hf_hub_download(
                repo_id=spec["repository"], filename=spec["filename"], revision=spec["revision"],
                cache_dir=str(_cache_root()), local_files_only=not download or os.environ.get("VELOCE_OFFLINE") == "1",
            ))
        except Exception as error:
            raise EngineError("diarization_not_ready", "Prepare speaker detection before processing this meeting.") from error
    return paths


def diarization_ready() -> bool:
    # Do not import ONNX/MLX, hash model weights or access the network on a status query.
    try:
        return all(path.is_file() and path.stat().st_size == DIARIZATION_MODELS[key]["download_bytes"]
                   for key, path in _model_paths().items())
    except (EngineError, ImportError, OSError):
        return False


def _verify_models(paths: dict[str, Path]):
    for key, path in paths.items():
        with path.open("rb") as stream:
            digest = hashlib.file_digest(stream, "sha256").hexdigest()
        if digest != DIARIZATION_MODELS[key]["sha256"]:
            raise EngineError("invalid_model", "A speaker detection model failed its SHA-256 integrity check.")


def prepare_diarization(emit) -> dict:
    emit({"event": "meeting_progress", "progress": 0.0, "detail": "Téléchargement des modèles de voix · 28 Mo"})
    paths = _model_paths(download=True)
    _verify_models(paths)
    # A successful download is not enough: verify the native runtime and both
    # graphs before the UI marks speaker detection ready. No audio is processed.
    verifier = SherpaDiarizer()
    del verifier
    emit({"event": "meeting_progress", "progress": 1.0, "detail": "Détection des interlocuteurs prête"})
    return {"diarization_ready": True}


class SherpaDiarizer:
    """Neural segmentation + clustering in five-minute blocks, with voice matching.

    We carry normalized speaker prototypes across blocks, never full PCM. Labels
    identify acoustic clusters, not people. No biometric database is retained.
    """
    def __init__(self):
        paths = _model_paths()
        _verify_models(paths)
        import numpy as np
        try:
            import sherpa_onnx as sherpa
        except ImportError as error:
            raise EngineError("dependency_missing", "Reinstall speaker detection with Engine/bootstrap.sh --meetings.") from error
        embedding = sherpa.SpeakerEmbeddingExtractorConfig(model=str(paths["embedding"]), num_threads=2, provider="cpu")
        config = sherpa.OfflineSpeakerDiarizationConfig(
            segmentation=sherpa.OfflineSpeakerSegmentationModelConfig(
                pyannote=sherpa.OfflineSpeakerSegmentationPyannoteModelConfig(model=str(paths["segmentation"])),
                num_threads=2, provider="cpu"),
            embedding=embedding,
            clustering=sherpa.FastClusteringConfig(num_clusters=-1, threshold=.5),
            min_duration_on=.3, min_duration_off=.5,
        )
        if not config.validate():
            raise EngineError("invalid_model", "The local speaker detection configuration is invalid.")
        self.model = sherpa.OfflineSpeakerDiarization(config)
        self.extractor = sherpa.SpeakerEmbeddingExtractor(embedding)
        self.np = np

    def segments(self, path: Path, duration: float, progress) -> list[AudioSlice]:
        np = self.np
        prototypes = []
        result = []
        blocks = max(1, math.ceil(duration / DIARIZATION_BLOCK_SECONDS))
        with wave.open(str(path), "rb") as audio:
            for block in range(blocks):
                core_start = block * DIARIZATION_BLOCK_SECONDS
                core_end = min(duration, core_start + DIARIZATION_BLOCK_SECONDS)
                offset = max(0, core_start - 2)
                stop = min(duration, core_end + 2)
                audio.setpos(int(offset * RATE))
                data = audio.readframes(int((stop - offset) * RATE))
                samples = np.frombuffer(data, dtype="<i2").astype(np.float32) / 32768
                if not np.any(np.abs(samples) > 16 / 32768):
                    progress((block + 1) / blocks)
                    continue
                local = self.model.process(samples, callback=lambda done, total: progress((block + done / max(1, total)) / blocks) or 0).sort_by_start_time()
                used = set()
                mapping = {}
                for speaker in dict.fromkeys(turn.speaker for turn in local):
                    examples = sorted((turn for turn in local if turn.speaker == speaker), key=lambda turn: turn.end - turn.start, reverse=True)[:3]
                    embeddings = []
                    weights = []
                    for turn in examples:
                        # Context outside the owned block can contain the next
                        # voice. Do not let a short boundary fragment contaminate
                        # the prototype used to connect long meeting blocks.
                        first = max(turn.start, core_start - offset)
                        last = min(turn.end, core_end - offset, first + 6)
                        chunk = samples[int(first * RATE):int(last * RATE)]
                        if len(chunk) < .8 * RATE:
                            continue
                        stream = self.extractor.create_stream()
                        stream.accept_waveform(sample_rate=RATE, waveform=chunk)
                        stream.input_finished()
                        if self.extractor.is_ready(stream):
                            vector = np.asarray(self.extractor.compute(stream), dtype=np.float32)
                            embeddings.append(vector / max(float(np.linalg.norm(vector)), 1e-8))
                            weights.append(len(chunk))
                    vector = np.average(embeddings, axis=0, weights=weights) if embeddings else None
                    if vector is not None:
                        vector /= max(float(np.linalg.norm(vector)), 1e-8)
                    scores = [(float(np.dot(vector, candidate)), index) for index, candidate in enumerate(prototypes)
                              if vector is not None and candidate is not None and index not in used]
                    score, match = max(scores, default=(-1, -1))
                    # Prefer an extra anonymous label to merging distinct voices.
                    # This is intentionally stricter than within-block clustering.
                    if score < .75:
                        match = len(prototypes)
                        if match >= 64:
                            mapping[speaker] = "Interlocuteur indéterminé"
                            continue
                        prototypes.append(vector)
                    elif vector is not None:
                        average = prototypes[match] + vector
                        prototypes[match] = average / max(float(np.linalg.norm(average)), 1e-8)
                    used.add(match)
                    mapping[speaker] = f"Interlocuteur {match + 1}"
                for turn in local:
                    start, end = max(core_start, offset + turn.start), min(core_end, offset + turn.end)
                    if end > start:
                        result.append(AudioSlice(start, end, mapping[turn.speaker]))
                progress((block + 1) / blocks)
        # Join a continuing turn at a block boundary, keeping all other turn boundaries.
        merged = []
        for item in sorted(result, key=lambda item: item.start):
            if merged and merged[-1].speaker == item.speaker and 0 <= item.start - merged[-1].end <= .25:
                merged[-1].end = item.end
            else:
                merged.append(item)
        return merged


def _uses_imported_audio(params) -> bool:
    imported = "audio_path" in params
    track_keys = ("microphone_path", "system_path")
    if imported and any(key in params for key in track_keys):
        raise EngineError("invalid_request", "Choose audio_path or microphone_path with system_path, never both.")
    if not imported and not all(key in params for key in track_keys):
        raise EngineError("invalid_request", "Provide audio_path or both microphone_path and system_path.")
    return imported


def transcribe_meeting(params, backend, emit, diarizer_factory=SherpaDiarizer) -> dict:
    imported = _uses_imported_audio(params)
    microphone = None
    if imported:
        primary, primary_duration = validate_track(params["audio_path"])
        duration = primary_duration
        primary_source, primary_label = "imported", "Audio importé"
    else:
        microphone, mic_duration = validate_track(params["microphone_path"])
        primary, primary_duration = validate_track(params["system_path"])
        duration = max(mic_duration, primary_duration)
        primary_source, primary_label = "system", "Participants"
    diarize = params.get("diarize", False)
    if not isinstance(diarize, bool):
        raise EngineError("invalid_request", "diarize must be a boolean.")
    context, language = params.get("context", ""), params.get("language")
    if not isinstance(context, str) or len(context) > 4000:
        raise EngineError("invalid_request", "context must be a string of at most 4000 characters.")
    if language is not None and (not isinstance(language, str) or len(language) > 64):
        raise EngineError("invalid_request", "language must be a language name or null.")
    emit({"event": "meeting_progress", "progress": 0.0,
          "detail": "Analyse du fichier audio" if imported else "Analyse des pistes audio"})
    primary_slices = []
    if diarize:
        diarizer = diarizer_factory()
        turns = diarizer.segments(primary, primary_duration, lambda value: emit({
            "event": "meeting_progress", "progress": value * .25, "detail": "Détection des interlocuteurs"}))
        for turn in turns:
            primary_slices.extend(speech_chunks(primary, turn.speaker, turn.start, turn.end))
        del diarizer
    else:
        primary_slices = speech_chunks(primary, primary_label)
    jobs = [(primary, primary_source, item) for item in primary_slices]
    if microphone is not None:
        jobs.extend((microphone, "microphone", item) for item in speech_chunks(microphone, "Vous"))
    jobs.sort(key=lambda job: (job[2].start, job[1]))
    total_work = sum(item.end - item.start for _, _, item in jobs)
    processed = 0
    segments = []
    previous = {}
    with tempfile.TemporaryDirectory(prefix="veloce-meeting-") as directory:
        chunk_path = Path(directory) / "chunk.wav"
        for source_path, source, item in jobs:
            write_slice(source_path, chunk_path, item.start, item.end)
            text = backend.transcribe(chunk_path, language or None, context).get("text", "").strip()
            key = (source, item.speaker)
            if item.overlap and key in previous:
                text = remove_overlap(previous[key], text)
            if text:
                segments.append({"id": f"{source}-{len(segments)}", "start": round(item.start, 3),
                                 "end": round(item.end, 3), "speaker": item.speaker, "source": source, "text": text})
                previous[key] = text
            processed += item.end - item.start
            emit({"event": "meeting_progress", "progress": .25 + .75 * processed / max(total_work, .001),
                  "detail": f"Transcription · {len(segments)} passages"})
    emit({"event": "meeting_progress", "progress": 1.0, "detail": "Transcription terminée"})
    text = "\n\n".join(f"[{int(item['start']) // 60:02d}:{int(item['start']) % 60:02d}] {item['speaker']}\n{item['text']}" for item in segments)
    return {"text": text, "segments": segments, "duration": duration,
            "diarization": "sherpa-onnx-pyannote-wespeaker" if diarize else "tracks-only"}


def export_meeting_audio(params) -> dict:
    imported = _uses_imported_audio(params)
    if imported:
        source, duration = validate_track(params["audio_path"])
        channels = 1
    else:
        microphone, mic_duration = validate_track(params["microphone_path"])
        system, system_duration = validate_track(params["system_path"])
        duration, channels = max(mic_duration, system_duration), 2
    value = params.get("output_path")
    if not isinstance(value, str) or not value:
        raise EngineError("invalid_request", "output_path must be a local WAV path.")
    destination = Path(value).expanduser().resolve()
    if destination.exists():
        raise EngineError("output_exists", "Choose a new export filename; existing recordings are never overwritten.")
    if not destination.parent.is_dir():
        raise EngineError("invalid_request", "The audio export folder does not exist.")
    temporary = None
    try:
        descriptor, name = tempfile.mkstemp(prefix=".veloce-export-", suffix=".wav", dir=destination.parent)
        os.close(descriptor)
        temporary = Path(name)
        if imported:
            with source.open("rb") as audio, temporary.open("wb") as out:
                shutil.copyfileobj(audio, out, length=1024 * 1024)
        else:
            with wave.open(str(microphone), "rb") as left, wave.open(str(system), "rb") as right, wave.open(str(temporary), "wb") as out:
                out.setparams((2, 2, RATE, 0, "NONE", "not compressed"))
                while True:
                    a, b = _samples(left.readframes(16000)), _samples(right.readframes(16000))
                    size = max(len(a), len(b))
                    if not size:
                        break
                    a.extend([0] * (size - len(a)))
                    b.extend([0] * (size - len(b)))
                    interleaved = array("h", [0]) * (size * 2)
                    interleaved[0::2], interleaved[1::2] = a, b
                    if sys.byteorder != "little":
                        interleaved.byteswap()
                    out.writeframesraw(interleaved.tobytes())
        # Atomic publication without overwriting a file created during export.
        os.link(temporary, destination)
    except FileExistsError as error:
        raise EngineError("output_exists", "The export filename already exists.") from error
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
    return {"path": str(destination), "duration": duration, "channels": channels}
