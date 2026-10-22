"""Run the actual compatibility code with real Unix socket traffic.

Only the original bind is made to return a sandbox-like permission error;
the retry, listener, client, permissions and cleanup use the real kernel.
"""
import shutil
import socket
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


class WineSocketTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        compiler = shutil.which("cc")
        if not compiler:
            raise unittest.SkipTest("native C compiler required")
        cls.temp = tempfile.TemporaryDirectory()
        cls.runner = Path(cls.temp.name) / "wine-sockets"
        source = Path(__file__).with_name("WineSocketTests.c")
        options = [] if sys.platform == "darwin" else ["-Wno-format-truncation"]
        result = subprocess.run([compiler, "-std=gnu11", "-Wall", "-Wextra", "-Werror",
                                 *options, "-pthread", str(source), "-o", str(cls.runner)],
                                capture_output=True, text=True)
        if result.returncode:
            cls.temp.cleanup()
            raise AssertionError(result.stderr)

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def test_socket_behaviour(self):
        try:
            probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            probe.close()
        except PermissionError:
            self.skipTest("this executor prohibits socket creation; runs on the macOS build runner")
        for scenario in ("eperm", "eacces", "normal-bind", "other-error", "failed-retry",
                         "unrelated-socket", "outside-home", "other-app", "long-temp", "ipv4"):
            with self.subTest(scenario=scenario):
                result = subprocess.run([str(self.runner), scenario], capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_path_scope(self):
        for scenario in ("other-app", "paths"):
            result = subprocess.run([str(self.runner), scenario], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
