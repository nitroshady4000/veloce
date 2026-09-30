#!/usr/bin/env python3
"""Sequential real-model smoke measurements. Synthetic audio is not an ASR benchmark."""
import argparse
import datetime
import json
import platform
from pathlib import Path
import subprocess
import tempfile
import time
import wave

from worker import Engine, MODELS


def system_value(name):
    return subprocess.check_output(["/usr/sbin/sysctl", "-n", name], text=True).strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("audio", type=Path, help="Mono 16 kHz PCM16 WAV")
    parser.add_argument("--models", nargs="+", choices=MODELS, default=["qwen3-0.6b"])
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument("--reference", default="")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.repeats < 1:
        parser.error("--repeats must be positive")
    report = {"date": datetime.datetime.now(datetime.timezone.utc).isoformat(),
              "kind": "synthetic-smoke-not-quality-benchmark",
              "machine": system_value("machdep.cpu.brand_string"),
              "ram_bytes": int(system_value("hw.memsize")),
              "macos": platform.mac_ver()[0], "python": platform.python_version(),
              "reference": args.reference, "runs": []}
    engine = Engine()
    with tempfile.TemporaryDirectory(prefix="veloce-smoke-") as directory:
        silence = Path(directory) / "silence.wav"
        with wave.open(str(silence), "wb") as audio:
            audio.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
            audio.writeframes(bytes(64000))
        for model_id in args.models:
            run = {"model": model_id, "revision": MODELS[model_id]["revision"], "speech": []}
            report["runs"].append(run)
            try:
                started = time.perf_counter()
                engine.handle({"method": "load", "params": {"model": model_id}})
                run["load_seconds"] = round(time.perf_counter() - started, 4)
                for _ in range(args.repeats):
                    result = engine.handle({"method": "transcribe", "params": {
                        "audio_path": str(args.audio.resolve()), "language": "French"}})
                    run["speech"].append(result)
                    print(json.dumps(result, ensure_ascii=False), flush=True)
                run["silence"] = engine.handle({"method": "transcribe", "params": {
                    "audio_path": str(silence), "language": "French"}})
                print(json.dumps({"silence": run["silence"]}, ensure_ascii=False), flush=True)
            except Exception as error:
                run["error"] = f"{type(error).__name__}: {error}"
                print(run["error"], flush=True)
            finally:
                engine.unload()
                args.output.parent.mkdir(parents=True, exist_ok=True)
                args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")


if __name__ == "__main__":
    main()
