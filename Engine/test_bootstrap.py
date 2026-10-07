"""Bootstrap layout and update contracts without installing Python or packages."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class BootstrapTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / "Veloce.app/Contents/Resources/Engine"
        self.source.mkdir(parents=True)
        for name in ("bootstrap.sh", "uv.lock", "pyproject.toml"):
            shutil.copyfile(Path(__file__).parent / name, self.source / name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.executable(self.bin / "uname", '#!/bin/bash\nif [[ "$1" == -m ]]; then echo arm64; else echo Darwin; fi\n')
        self.executable(self.source.parent / "uv", '''#!/bin/bash
printf '%s\\n' "$UV_PROJECT_ENVIRONMENT" "$UV_CACHE_DIR" "$UV_PYTHON_INSTALL_DIR" "$@" > "$BOOTSTRAP_TEST_LOG"
exit "${BOOTSTRAP_TEST_STATUS:-0}"
''')
        self.environment = {key: value for key, value in os.environ.items()
                            if not key.startswith(("VELOCE_", "UV_"))}
        self.runtime = self.root / "persistent runtime"
        self.environment.update(VELOCE_ENGINE_RUNTIME_DIR=str(self.runtime),
                                PATH=str(self.bin) + ":" + os.environ["PATH"],
                                BOOTSTRAP_TEST_LOG=str(self.root / "uv-call"))

    @staticmethod
    def executable(path, contents):
        path.write_text(contents)
        path.chmod(0o755)

    def run_bootstrap(self, *args):
        return subprocess.run(["/bin/bash", str(self.source / "bootstrap.sh"), *args],
                              env=self.environment, capture_output=True, text=True)

    def uv_call(self):
        return (self.root / "uv-call").read_text().splitlines()

    def test_bootstrap_keeps_source_immutable_and_passes_external_paths_to_uv(self):
        before = {path: path.read_bytes() for path in self.source.iterdir()}
        result = self.run_bootstrap()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.uv_call()[:3], [str(self.runtime / name)
                                            for name in (".venv", ".uv-cache", ".python")])
        self.assertIn("--managed-python", self.uv_call())
        self.assertEqual(before, {path: path.read_bytes() for path in self.source.iterdir()})
        for name in ("uv.lock", "pyproject.toml"):
            self.assertEqual((self.source / name).read_bytes(),
                             (self.runtime / (".installed-" + name)).read_bytes())

    def test_optional_features_are_resynchronized_after_app_update(self):
        self.assertEqual(self.run_bootstrap("--parakeet", "--meetings").returncode, 0)
        (self.source / "uv.lock").write_text("updated release lock\n")
        self.assertEqual(self.run_bootstrap().returncode, 0)
        self.assertIn("parakeet", self.uv_call())
        self.assertIn("meetings", self.uv_call())
        self.assertEqual((self.runtime / ".installed-uv.lock").read_text(), "updated release lock\n")

    def test_failed_sync_does_not_mark_release_or_extra_installed(self):
        self.environment["BOOTSTRAP_TEST_STATUS"] = "7"
        self.assertEqual(self.run_bootstrap("--meetings").returncode, 7)
        self.assertFalse((self.runtime / ".installed-uv.lock").exists())
        self.assertFalse((self.runtime / ".extra-meetings").exists())

    def test_explicit_runtime_directory(self):
        self.environment["VELOCE_ENGINE_RUNTIME_DIR"] = str(self.root / "custom runtime")
        self.assertEqual(self.run_bootstrap().returncode, 0)
        self.assertEqual(self.uv_call()[0], str(self.root / "custom runtime/.venv"))

    def test_development_retains_checkout_python(self):
        self.environment["VELOCE_ENGINE_RUNTIME_DIR"] = str(self.source)
        self.assertEqual(self.run_bootstrap().returncode, 0)
        self.assertEqual(self.uv_call()[0], str(self.source / ".venv"))
        self.assertNotIn("--managed-python", self.uv_call())

    def test_invalid_options_do_not_create_runtime(self):
        self.assertEqual(self.run_bootstrap("--invalid").returncode, 2)
        self.assertFalse(self.runtime.exists())
        self.assertFalse((self.root / "uv-call").exists())


if __name__ == "__main__":
    unittest.main()
