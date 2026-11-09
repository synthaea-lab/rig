"""Unit tests of tools/offline_bundle.py (python rig.py check runs them): how it pushes a bundle
over vagrant, with the fake vagrant of test_vagrant.py and the bundle itself stubbed out, and
that its bundle KEY is the one provisioning/agent-build.sh expects in the guest."""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from io import StringIO
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from test_vagrant import FakeVagrant  # noqa: E402

from tools import offline_bundle, riglib  # noqa: E402

PROBE = "uname -m; cat ~/synthaea-offline/KEY 2>/dev/null || true"
AGENT_BUILD = Path(__file__).resolve().parent.parent / "provisioning" / "agent-build.sh"
# The guest's KEY expression in agent-build.sh: Cargo.lock, a NUL, the probe toolchain file,
# hashed and cut to 16 hex digits.
BASH_KEY = re.compile(r"""\{ cat "\$SRC/Cargo\.lock"; printf '\\0'; cat "[^"]+"; \} \| sha256sum \| cut -c1-16""")


class Push(FakeVagrant):
    def setUp(self) -> None:
        super().setUp()
        self.tarball = self.dir / "synthaea-offline-k1-aarch64-unknown-linux-gnu.tar.gz"
        for patcher in (mock.patch.object(offline_bundle, "make_bundle", return_value=self.tarball),
                        mock.patch.object(offline_bundle, "bundle_key", return_value="k1")):
            patcher.start()
            self.addCleanup(patcher.stop)

    def test_builds_for_the_guest_arch_and_uploads(self) -> None:
        self.reply(1, out="aarch64\n")
        with redirect_stdout(StringIO()) as out:
            offline_bundle.push("debian12", None)
        offline_bundle.make_bundle.assert_called_once_with("aarch64-unknown-linux-gnu")
        self.assertEqual(self.args(), [
            ["ssh", "debian12", "--command", PROBE],
            ["upload", str(self.tarball), f"/tmp/{self.tarball.name}", "debian12"]])
        self.assertEqual({Path(call["cwd"]).resolve() for call in self.calls()}, {riglib.VAGRANT_DIR.resolve()})
        self.assertEqual({call["provider"] for call in self.calls()}, {"libvirt"})
        self.assertEqual(out.getvalue().splitlines(), [
            f"+ (vagrant/) vagrant upload {self.tarball} /tmp/{self.tarball.name} debian12",
            f"pushed to debian12:/tmp/{self.tarball.name} (agent-build.sh --offline unpacks it)"])

    def test_a_given_target_wins_over_the_guest_arch(self) -> None:
        self.reply(1, out="x86_64\n")
        with redirect_stdout(StringIO()):
            offline_bundle.push("debian12", "aarch64-unknown-linux-gnu")
        offline_bundle.make_bundle.assert_called_once_with("aarch64-unknown-linux-gnu")

    def test_skips_the_upload_when_the_guest_has_the_key(self) -> None:
        self.reply(1, out="x86_64\nk1\n")
        with redirect_stdout(StringIO()) as out:
            offline_bundle.push("debian12", None)
        self.assertEqual(len(self.calls()), 1)
        self.assertEqual(out.getvalue(), "debian12 already has offline bundle k1\n")

    def test_an_unreachable_guest_is_a_bundle_error_with_vagrant_stderr(self) -> None:
        self.reply(1, err="VM not created. Moving on...\n", rc=1)
        with self.assertRaisesRegex(offline_bundle.BundleError,
                                    r"cannot reach debian12 over vagrant ssh .*:\nVM not created\. Moving on\.\.\.$"):
            offline_bundle.push("debian12", None)
        offline_bundle.make_bundle.assert_not_called()

    def test_a_silent_failure_keeps_the_hint_alone(self) -> None:
        self.reply(1, rc=1)
        with self.assertRaisesRegex(offline_bundle.BundleError, r"\(is it up\? python rig.py up debian12\)$"):
            offline_bundle.push("debian12", None)


# (name, Cargo.lock bytes, ebpf-toolchain.txt bytes) the two KEY formulas must agree on.
KEY_FIXTURES = (
    ("plain", b"# lock\nversion = 4\n", b"nightly-2026-01-01\n"),
    ("no trailing newline", b"version = 4", b"nightly-2026-01-01"),
    ("CRLF and non-ASCII", b"# verrou \xc3\xa9\r\nversion = 4\r\n", b"nightly-2026-01-01\r\n"),
    ("empty toolchain file", b"version = 4\n", b""),
)


@unittest.skipUnless(shutil.which("bash"), "no bash for the guest's KEY expression")
class BundleKeyParity(unittest.TestCase):
    """The host (Python) and the guest (bash) compute the bundle KEY with one formula each; a
    drift would make the guest refuse every bundle, or take one made for other sources."""

    def setUp(self) -> None:
        scratch = tempfile.TemporaryDirectory(prefix="rig-bundle-key-")
        self.addCleanup(scratch.cleanup)
        self.agent = Path(scratch.name) / "agent"
        self.toolchain = self.agent / "packaging" / "toolchain" / "ebpf-toolchain.txt"
        self.toolchain.parent.mkdir(parents=True)

    def bash_key(self) -> str:
        found = BASH_KEY.findall(AGENT_BUILD.read_text(encoding="utf-8"))
        self.assertEqual(len(found), 1, f"expected one bundle KEY expression in {AGENT_BUILD.name}, found {found}")
        # The fixture keeps the toolchain file where the agent checkout has it, whether the
        # expression names it under $SRC or through $EBPF_TOOLCHAIN_FILE.
        env = {**os.environ, "SRC": self.agent.as_posix(), "EBPF_TOOLCHAIN_FILE": self.toolchain.as_posix()}
        res = subprocess.run([shutil.which("bash") or "bash", "-c", found[0]], env=env,
                             capture_output=True, text=True, check=True)
        return res.stdout.strip()

    def test_host_and_guest_compute_the_same_key(self) -> None:
        for name, lock, toolchain in KEY_FIXTURES:
            with self.subTest(name):
                (self.agent / "Cargo.lock").write_bytes(lock)
                self.toolchain.write_bytes(toolchain)
                key = offline_bundle.bundle_key(self.agent)
                self.assertRegex(key, r"^[0-9a-f]{16}$")
                self.assertEqual(self.bash_key(), key)

    def test_the_key_changes_with_either_file(self) -> None:
        (self.agent / "Cargo.lock").write_bytes(b"version = 4\n")
        self.toolchain.write_bytes(b"nightly-2026-01-01\n")
        first = offline_bundle.bundle_key(self.agent)
        self.toolchain.write_bytes(b"nightly-2026-02-01\n")
        second = offline_bundle.bundle_key(self.agent)
        (self.agent / "Cargo.lock").write_bytes(b"version = 4\n# bumped\n")
        self.assertEqual(len({first, second, offline_bundle.bundle_key(self.agent)}), 3)


if __name__ == "__main__":
    unittest.main()
