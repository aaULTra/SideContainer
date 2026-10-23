"""Exercise the build launcher independently of a runner's shell setup."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class RustBuildLauncherTests(unittest.TestCase):
    def test_release_build_does_not_source_runner_environment(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            shutil.copyfile(Path(__file__).parents[1] / "build-rust.sh", root / "build-rust.sh")
            (root / "rust-core").mkdir()
            cargo_home = root / "cargo"
            tools = cargo_home / "bin"
            tools.mkdir(parents=True)
            # External runner setup must not be able to exit this build.
            (cargo_home / "env").write_text("exit 91\n")
            log = root / "calls"
            for name in ("cargo", "xcodebuild"):
                tool = tools / name
                tool.write_text('#!/bin/sh\nprintf "%s\\n" "' + name + ' $*" >> "$BUILD_TEST_LOG"\n')
                tool.chmod(0o755)
            env = {**os.environ, "HOME": str(root), "CARGO_HOME": str(cargo_home),
                   "BUILD_TEST_LOG": str(log), "PATH": "/usr/bin:/bin"}
            subprocess.run(["bash", str(root / "build-rust.sh")], env=env,
                           check=True, capture_output=True, text=True)
            calls = log.read_text().splitlines()
            self.assertEqual(calls[:2], [
                "cargo build --release --target aarch64-apple-ios",
                "cargo build --release --target aarch64-apple-ios-sim"])
            self.assertTrue(calls[2].startswith("xcodebuild -create-xcframework "))
