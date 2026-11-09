"""Unit tests of how tools/offline_bundle.py pushes a bundle over vagrant (python rig.py check
runs them), with the fake vagrant of test_vagrant.py and the bundle itself stubbed out."""

from __future__ import annotations

import sys
import unittest
from contextlib import redirect_stdout
from io import StringIO
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from test_vagrant import FakeVagrant  # noqa: E402

from tools import offline_bundle, riglib  # noqa: E402

PROBE = "uname -m; cat ~/synthaea-offline/KEY 2>/dev/null || true"


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


if __name__ == "__main__":
    unittest.main()
