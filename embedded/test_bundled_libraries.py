import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from bundled_libraries import dependencies, normalize, verify


@unittest.skipUnless(sys.platform == 'darwin', 'Native dyld test requires macOS')
class BundledLibraryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.app = Path(self.temp.name) / 'Host.app'
        frameworks = self.app / 'Frameworks'
        crypto = frameworks / 'OpenSSL.framework/OpenSSL'
        crypto.parent.mkdir(parents=True)
        self.crypto = crypto
        self.signer = frameworks / 'ZSign.dylib'
        self.guest = frameworks / 'SideInstallerApp.framework/Guest'
        self.guest.parent.mkdir()
        src = Path(self.temp.name)
        (src / 'crypto.c').write_text('int crypto_value(void) { return 42; }')
        (src / 'signer.c').write_text('extern int crypto_value(void); int signing_test(void) { return crypto_value(); }')
        (src / 'guest.c').write_text('''#include <dlfcn.h>
#include <stdio.h>
int main(int argc, char **argv) {
 void *h = dlopen(argv[1], RTLD_NOW);
 if (!h) { fprintf(stderr, "%s", dlerror()); return 2; }
 int (*test)(void) = dlsym(h, "signing_test");
 return !test || test() != 42;
}''')
        subprocess.run(['clang', '-dynamiclib', str(src / 'crypto.c'), '-install_name',
                        '@rpath/OpenSSL.framework/OpenSSL', '-o', str(crypto)], check=True)
        subprocess.run(['clang', '-dynamiclib', str(src / 'signer.c'), str(crypto),
                        '-Wl,-headerpad_max_install_names', '-o', str(self.signer)], check=True)
        subprocess.run(['clang', str(src / 'guest.c'), '-Wl,-rpath,@executable_path/Frameworks',
                        '-o', str(self.guest)], check=True)
        self.env = {k: v for k, v in os.environ.items() if not k.startswith('DYLD_')}

    def test_zsign_openssl_loads_from_embedded_guest(self):
        before = subprocess.run([str(self.guest), str(self.signer)], env=self.env, capture_output=True)
        self.assertEqual(before.returncode, 2)
        self.assertIn(b'OpenSSL.framework/OpenSSL', before.stderr)
        with self.assertRaisesRegex(ValueError, 'Guest-dependent'):
            verify(self.app)
        changed = normalize(self.app)
        self.assertIn(self.signer, changed)
        for image in changed:
            subprocess.run(['codesign', '--force', '--sign', '-', str(image)], check=True)
        self.assertIn('@loader_path/OpenSSL.framework/OpenSSL', dependencies(self.signer.read_bytes()))
        after = subprocess.run([str(self.guest), str(self.signer)], env=self.env, capture_output=True)
        self.assertEqual(after.returncode, 0, after.stderr.decode())
        # Exercise an extension-like loader independently of the guest too.
        extension = self.app / 'PlugIns/LiveProcess.appex'
        extension.mkdir(parents=True)
        caller = extension / 'LiveProcess'
        shutil.copyfile(self.guest, caller)
        caller.chmod(0o755)
        result = subprocess.run([str(caller), str(self.signer)], env=self.env, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        self.assertTrue(verify(self.app))

    def test_missing_openssl_is_rejected_before_packaging(self):
        self.crypto.unlink()
        with self.assertRaisesRegex(ValueError, 'Missing bundled dependency'):
            normalize(self.app)
