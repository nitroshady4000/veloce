"""Meeting invariants, with fake ASR/diarization and no downloaded weights."""
from pathlib import Path
import struct
import tempfile
import unittest
import wave

from errors import EngineError
from meetings import AudioSlice, MAX_MEETING_SECONDS, export_meeting_audio, remove_overlap, speech_chunks, transcribe_meeting, validate_track
from worker import Engine


def wav(path, sections):
    with wave.open(str(path), "wb") as audio:
        audio.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
        for seconds, level in sections:
            audio.writeframesraw(struct.pack("<h", level) * int(seconds * 16000))


class MeetingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.directory = Path(self.temp.name)
        self.microphone = self.directory / "microphone.wav"
        self.system = self.directory / "system.wav"
        self.params = {"microphone_path": str(self.microphone), "system_path": str(self.system)}

    def tearDown(self):
        self.temp.cleanup()

    def test_silence_never_reaches_asr_and_sources_are_conserved(self):
        wav(self.microphone, [(5, 0)])
        wav(self.system, [(2, 0), (1, 400), (2, 0)])
        original = self.system.read_bytes()
        calls = []

        class Backend:
            def transcribe(inner, path, language, context):
                with wave.open(str(path), "rb") as audio:
                    calls.append(audio.getnframes() / 16000)
                return {"text": "Bonjour à tous."}

        events = []
        result = transcribe_meeting(self.params, Backend(), events.append)
        self.assertEqual(len(calls), 1)
        self.assertEqual(result["diarization"], "tracks-only")
        self.assertEqual(result["duration"], 5)
        self.assertEqual(result["segments"][0]["source"], "system")
        self.assertEqual(result["segments"][0]["speaker"], "Participants")
        self.assertAlmostEqual(result["segments"][0]["start"], 1.85, places=2)
        self.assertEqual(events[-1]["progress"], 1)
        self.assertEqual(self.system.read_bytes(), original)

    def test_long_continuous_speech_has_bounded_chunks_with_context(self):
        wav(self.microphone, [(95, 400)])
        chunks = speech_chunks(self.microphone, "Vous")
        self.assertEqual(len(chunks), 3)
        self.assertEqual(chunks[0].start, 0)
        self.assertEqual(chunks[-1].end, 95)
        self.assertTrue(all(item.end - item.start <= 40.001 for item in chunks))
        self.assertAlmostEqual(chunks[0].end - chunks[1].start, 1.5)
        self.assertFalse(chunks[0].overlap)
        self.assertTrue(chunks[1].overlap)
        wav(self.microphone, [(1, 0), (95, 400)])
        self.assertTrue(all(item.end - item.start <= 40.000001 for item in speech_chunks(self.microphone, "Vous")))

    def test_pauses_are_preferred_and_do_not_trim_short_utterances(self):
        wav(self.microphone, [(14, 500), (.7, 0), (1, 500), (4, 0)])
        chunks = speech_chunks(self.microphone, "Vous")
        self.assertEqual(len(chunks), 2)
        self.assertAlmostEqual(chunks[0].end, 14.15)
        self.assertLess(chunks[1].start, 14.7)
        self.assertGreater(chunks[1].end, 15.7)
        self.assertFalse(chunks[1].overlap)

    def test_overlap_dedup_keeps_only_exact_multiword_repetition(self):
        self.assertEqual(remove_overlap("Voici le compte rendu.", "compte rendu, avec les actions."), "avec les actions.")
        self.assertEqual(remove_overlap("oui", "oui c’est cela"), "oui c’est cela")
        self.assertEqual(remove_overlap("une autre décision", "décision différente"), "décision différente")

    def test_neural_turn_labels_and_timestamps_are_used_without_claiming_track_separation_is_diarization(self):
        wav(self.microphone, [(1, 500), (4, 0)])
        wav(self.system, [(1, 0), (4, 500)])

        class Diarizer:
            def segments(inner, path, duration, progress):
                progress(1)
                return [AudioSlice(1, 2.5, "Interlocuteur 1"), AudioSlice(3, 5, "Interlocuteur 2")]

        class Backend:
            def transcribe(inner, *args):
                return {"text": "Texte"}

        result = transcribe_meeting({**self.params, "diarize": True}, Backend(), lambda _: None, Diarizer)
        self.assertEqual([item["speaker"] for item in result["segments"]], ["Vous", "Interlocuteur 1", "Interlocuteur 2"])
        self.assertEqual(result["segments"][-1]["start"], 3)
        self.assertEqual(result["diarization"], "sherpa-onnx-pyannote-wespeaker")

    def test_diarization_failure_is_not_silently_reported_as_success(self):
        wav(self.microphone, [(1, 500)])
        wav(self.system, [(1, 500)])

        def missing():
            raise EngineError("diarization_not_ready", "Prepare first")

        with self.assertRaisesRegex(EngineError, "Prepare first"):
            transcribe_meeting({**self.params, "diarize": True}, None, lambda _: None, missing)

    def test_import_uses_neutral_provenance_without_creating_tracks(self):
        imported = self.directory / "imported.wav"
        wav(imported, [(2, 0), (1, 400), (2, 0)])
        original = imported.read_bytes()
        calls = []

        class Backend:
            def transcribe(inner, path, language, context):
                calls.append((language, context))
                return {"text": "Voici l’enregistrement importé."}

        result = transcribe_meeting({"audio_path": str(imported), "language": "French", "context": "Véloce"},
                                    Backend(), lambda _: None)
        self.assertEqual(calls, [("French", "Véloce")])
        self.assertEqual(result["duration"], 5)
        self.assertEqual(result["diarization"], "tracks-only")
        self.assertEqual(len(result["segments"]), 1)
        segment = result["segments"][0]
        self.assertEqual((segment["source"], segment["speaker"]), ("imported", "Audio importé"))
        self.assertTrue(segment["id"].startswith("imported-"))
        self.assertAlmostEqual(segment["start"], 1.85, places=2)
        self.assertIn("Audio importé", result["text"])
        self.assertNotIn("Vous", result["text"])
        self.assertEqual(imported.read_bytes(), original)
        self.assertEqual(list(self.directory.iterdir()), [imported])

    def test_import_diarizes_the_complete_file_and_preserves_imported_source(self):
        imported = self.directory / "imported.wav"
        wav(imported, [(1, 0), (6, 500)])
        received = []

        class Diarizer:
            def segments(inner, path, duration, progress):
                received.append((path, duration))
                progress(1)
                return [AudioSlice(1, 3, "Interlocuteur 1"), AudioSlice(4, 7, "Interlocuteur 2")]

        class Backend:
            def transcribe(inner, *args):
                return {"text": "Passage importé"}

        result = transcribe_meeting({"audio_path": str(imported), "diarize": True},
                                    Backend(), lambda _: None, Diarizer)
        self.assertEqual(received, [(imported.resolve(), 7)])
        self.assertEqual(result["duration"], 7)
        self.assertEqual(result["diarization"], "sherpa-onnx-pyannote-wespeaker")
        self.assertEqual([item["speaker"] for item in result["segments"]], ["Interlocuteur 1", "Interlocuteur 2"])
        self.assertTrue(all(item["source"] == "imported" for item in result["segments"]))
        self.assertEqual(result["segments"][-1]["start"], 4)

    def test_import_rejects_ambiguous_or_missing_source_selection(self):
        # Reject the contract before trying to read any path, even if an extra
        # track value is null. A client must select one clear source mode.
        invalid = [
            {"audio_path": "missing.wav", **self.params},
            {"audio_path": "missing.wav", "microphone_path": None},
            {"audio_path": "missing.wav", "system_path": None},
            {"microphone_path": str(self.microphone)},
            {"system_path": str(self.system)},
            {},
        ]
        for params in invalid:
            with self.subTest(params=params), self.assertRaises(EngineError) as caught:
                transcribe_meeting(params, None, lambda _: None)
            self.assertEqual(caught.exception.code, "invalid_request")

    def test_import_retains_audio_validation_and_skips_silence(self):
        imported = self.directory / "imported.wav"
        with self.assertRaises(EngineError) as caught:
            transcribe_meeting({"audio_path": str(imported)}, None, lambda _: None)
        self.assertEqual(caught.exception.code, "audio_not_found")
        wav(imported, [(2, 0)])
        # A backend of None proves silent audio cannot reach inference.
        result = transcribe_meeting({"audio_path": str(imported)}, None, lambda _: None)
        self.assertEqual(result["segments"], [])
        self.assertEqual(result["duration"], 2)
        with wave.open(str(imported), "wb") as audio:
            audio.setparams((2, 2, 16000, 0, "NONE", "not compressed"))
            audio.writeframes(bytes(32000))
        with self.assertRaises(EngineError) as caught:
            transcribe_meeting({"audio_path": str(imported)}, None, lambda _: None)
        self.assertEqual(caught.exception.code, "invalid_audio")

    def test_stereo_export_preserves_left_right_and_zero_pads_shorter_track(self):
        wav(self.microphone, [(1, 100)])
        wav(self.system, [(2, -200)])
        destination = self.directory / "stereo.wav"
        result = export_meeting_audio({**self.params, "output_path": str(destination)})
        self.assertEqual(result["channels"], 2)
        self.assertEqual(result["duration"], 2)
        with wave.open(str(destination), "rb") as audio:
            self.assertEqual((audio.getnchannels(), audio.getframerate(), audio.getnframes()), (2, 16000, 32000))
            self.assertEqual(struct.unpack("<hh", audio.readframes(1)), (100, -200))
            audio.setpos(16000)
            self.assertEqual(struct.unpack("<hh", audio.readframes(1)), (0, -200))
        with self.assertRaises(EngineError):
            export_meeting_audio({**self.params, "output_path": str(self.microphone)})

    def test_import_export_preserves_mono_audio_and_refuses_overwrite(self):
        imported = self.directory / "imported.wav"
        destination = self.directory / "export.wav"
        wav(imported, [(1, 600), (1, 0)])
        original = imported.read_bytes()
        params = {"audio_path": str(imported), "output_path": str(destination)}
        result = export_meeting_audio(params)
        self.assertEqual(result, {"path": str(destination.resolve()), "duration": 2, "channels": 1})
        self.assertEqual(destination.read_bytes(), original)
        self.assertEqual(imported.read_bytes(), original)
        with wave.open(str(destination), "rb") as audio:
            self.assertEqual((audio.getnchannels(), audio.getnframes()), (1, 32000))
        for output in [destination, imported]:
            with self.subTest(output=output), self.assertRaises(EngineError) as caught:
                export_meeting_audio({**params, "output_path": str(output)})
            self.assertEqual(caught.exception.code, "output_exists")
            self.assertEqual(output.read_bytes(), original)
        self.assertEqual(set(self.directory.iterdir()), {imported, destination})

    def test_import_export_rejects_ambiguous_source_mode_before_writing(self):
        destination = self.directory / "export.wav"
        for key in ["microphone_path", "system_path"]:
            with self.subTest(key=key), self.assertRaises(EngineError) as caught:
                export_meeting_audio({"audio_path": "missing.wav", key: None, "output_path": str(destination)})
            self.assertEqual(caught.exception.code, "invalid_request")
        self.assertFalse(destination.exists())

    def test_truncated_track_rejected(self):
        wav(self.microphone, [(1, 500)])
        self.microphone.write_bytes(self.microphone.read_bytes()[:-2])
        with self.assertRaisesRegex(EngineError, "truncated"):
            validate_track(str(self.microphone))

    def test_capture_finalization_margin_is_bounded(self):
        # Sparse files exercise real WAV duration validation without allocating
        # hundreds of megabytes in a test or pretending a truncated file is valid.
        def sparse(seconds):
            size = seconds * 16000 * 2
            with self.microphone.open("wb") as audio:
                audio.write(struct.pack("<4sI4s4sIHHIIHH4sI", b"RIFF", 36 + size, b"WAVE", b"fmt ",
                                        16, 1, 1, 16000, 32000, 2, 16, b"data", size))
                audio.seek(44 + size - 1)
                audio.write(b"\0")
        sparse(MAX_MEETING_SECONDS)
        self.assertEqual(validate_track(str(self.microphone))[1], MAX_MEETING_SECONDS)
        sparse(MAX_MEETING_SECONDS + 1)
        with self.assertRaises(EngineError):
            validate_track(str(self.microphone))

    def test_meeting_requires_loaded_model_and_restores_ready_after_failure(self):
        engine = Engine(backend_factory=lambda _: object())
        with self.assertRaises(EngineError):
            engine.handle({"method": "transcribe_meeting", "params": self.params})
        engine.handle({"method": "load", "params": {"model": "qwen3-0.6b"}})
        events = []
        engine.emit = events.append
        with self.assertRaises(EngineError):
            engine.handle({"method": "transcribe_meeting", "params": self.params})
        self.assertEqual(events[-1]["state"], "ready")
        self.assertIsNotNone(engine.backend)


if __name__ == "__main__":
    unittest.main()
