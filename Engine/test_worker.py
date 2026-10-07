"""Protocol tests use a fake engine and no network, model downloads, or microphone."""
import io
import json
from pathlib import Path
import struct
import tempfile
import unittest
import wave

from worker import Engine, EngineError, serve


class FakeBackend:
    def transcribe(self, path, language, context):
        print("third-party log")
        return {"text": "Bonjour Véloce.", "language": language}


class WorkerTests(unittest.TestCase):
    def setUp(self):
        self.events = []
        self.loads = []

        def create(model_id):
            self.loads.append(model_id)
            return FakeBackend()

        self.engine = Engine(emit=self.events.append, backend_factory=create)

    def load(self, model="qwen3-0.6b"):
        return self.engine.handle({"method": "load", "params": {"model": model}})

    def test_repeated_load_keeps_warm_model_and_switch_releases_it(self):
        self.load()
        first = self.engine.backend
        self.load()
        self.assertIs(first, self.engine.backend)
        self.load("qwen3-1.7b")
        self.assertIsNot(first, self.engine.backend)
        self.assertEqual(self.loads, ["qwen3-0.6b", "qwen3-1.7b"])

    def test_load_is_explicit(self):
        with self.assertRaisesRegex(EngineError, "Load the selected model"):
            self.engine.handle({"method": "transcribe", "params": {"audio_path": "/tmp/no.wav"}})

    def test_cached_load_uses_only_cached_backend_factory(self):
        cached = []
        self.engine.cached_backend_factory = lambda model: cached.append(model) or FakeBackend()
        result = self.engine.handle({"method": "load_cached", "params": {"model": "qwen3-0.6b"}})
        self.assertEqual(result["state"], "ready")
        self.assertEqual(cached, ["qwen3-0.6b"])
        self.assertEqual(self.loads, [])
        self.assertEqual(self.events[0]["state"], "loading_cached")

    def test_cached_load_miss_never_falls_back_to_download(self):
        self.engine.cached_backend_factory = lambda _model: (_ for _ in ()).throw(
            EngineError("model_not_cached", "missing")
        )
        with self.assertRaisesRegex(EngineError, "missing"):
            self.engine.handle({"method": "load_cached", "params": {"model": "qwen3-0.6b"}})
        self.assertEqual(self.loads, [])
        self.assertIsNone(self.engine.backend)
        self.assertIsNone(self.engine.model_id)

    def test_invalid_model_does_not_unload_current_model(self):
        self.load()
        with self.assertRaises(EngineError):
            self.load("unknown")
        self.assertEqual(self.engine.model_id, "qwen3-0.6b")

    def test_bad_load_never_leaves_old_model_reported_ready(self):
        self.load()

        def fail(_model):
            raise EngineError("test", "broken download")

        self.engine.backend_factory = fail
        with self.assertRaises(EngineError):
            self.load("qwen3-1.7b")
        self.assertIsNone(self.engine.model_id)
        self.assertIsNone(self.engine.backend)

    def test_invalid_audio_rejected_before_backend(self):
        self.load()
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "stereo.wav"
            with wave.open(str(path), "wb") as audio:
                audio.setparams((2, 2, 16000, 0, "NONE", "not compressed"))
                audio.writeframes(bytes(1600))
            with self.assertRaisesRegex(EngineError, "mono 16 kHz"):
                self.engine.handle({"method": "transcribe", "params": {"audio_path": str(path)}})

    def test_silence_cannot_hallucinate_or_reach_backend(self):
        self.load()

        class MustNotTranscribe:
            def transcribe(self, *_args):
                raise AssertionError("Silent audio reached the model")

        self.engine.backend = MustNotTranscribe()
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "silence.wav"
            for amplitude in (0, 16, -16):
                with wave.open(str(path), "wb") as audio:
                    audio.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
                    audio.writeframes(struct.pack("<h", amplitude) * 1600)
                result = self.engine.handle({"method": "transcribe", "params": {"audio_path": str(path)}})
                self.assertEqual(result["text"], "")
                self.assertTrue(result["silence_detected"])

    def test_protocol_survives_malformed_request_and_backend_logging(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "test.wav"
            with wave.open(str(path), "wb") as audio:
                audio.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
                audio.writeframes(struct.pack("<h", 20) * 1600)
            requests = [
                '{broken}\n',
                json.dumps({"id": 1, "method": "load", "params": {"model": "qwen3-0.6b"}}) + "\n",
                json.dumps({"id": 2, "method": "transcribe", "params": {"audio_path": str(path), "language": "French"}}) + "\n",
                json.dumps({"id": 3, "method": "status"}) + "\n",
            ]
            output = io.StringIO()
            serve(io.StringIO("".join(requests)), output,
                  lambda emit: Engine(emit=emit, backend_factory=lambda _model: FakeBackend()))
            messages = [json.loads(line) for line in output.getvalue().splitlines()]
            responses = {m["id"]: m for m in messages if "id" in m}
            self.assertEqual(responses[None]["error"]["code"], "invalid_json")
            self.assertEqual(responses[2]["result"]["text"], "Bonjour Véloce.")
            self.assertEqual(responses[2]["result"]["audio_duration_seconds"], 0.1)
            self.assertEqual(responses[3]["result"]["state"], "ready")

    def test_oversized_line_is_drained_without_breaking_next_request(self):
        input_stream = io.StringIO("x" * 70_000 + '\n{"id":1,"method":"status"}\n')
        output = io.StringIO()
        serve(input_stream, output)
        messages = [json.loads(line) for line in output.getvalue().splitlines()]
        self.assertEqual(messages[1]["error"]["code"], "invalid_request")
        self.assertEqual(messages[2]["id"], 1)


if __name__ == "__main__":
    unittest.main()
