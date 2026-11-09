"""Unit tests of how rig.py drives vagrant (python rig.py check runs them).

A fake `vagrant` goes first on PATH. Call n (from 1) logs its arguments, working directory
and default provider as one JSON line in calls.log, prints n.out and n.err from its directory
when they exist, and exits with the code in n.rc (default 0).
"""

from __future__ import annotations

import json
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from io import StringIO
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import rig  # noqa: E402

FAKE_VAGRANT = r'''
import json, os, sys
from pathlib import Path
here = Path(os.environ["FAKE_VAGRANT_DIR"])
log = here / "calls.log"
n = len(log.read_text(encoding="utf-8").splitlines()) + 1 if log.exists() else 1
with log.open("a", encoding="utf-8") as calls:
    calls.write(json.dumps({"args": sys.argv[1:], "cwd": os.getcwd(),
                            "provider": os.environ.get("VAGRANT_DEFAULT_PROVIDER")}) + "\n")
for suffix, stream in (("out", sys.stdout), ("err", sys.stderr)):
    reply = here / f"{n}.{suffix}"
    if reply.exists():
        stream.buffer.write(reply.read_bytes())
        stream.flush()
rc = here / f"{n}.rc"
sys.exit(int(rc.read_text()) if rc.exists() else 0)
'''


class FakeVagrant(unittest.TestCase):
    """Puts the fake vagrant first on PATH and reports/ in a scratch directory."""

    def setUp(self) -> None:
        scratch = tempfile.TemporaryDirectory(prefix="rig-fake-vagrant-")
        self.addCleanup(scratch.cleanup)
        self.dir = Path(scratch.name)
        bin_dir = self.dir / "bin"
        bin_dir.mkdir()
        (bin_dir / "fake_vagrant.py").write_text(FAKE_VAGRANT, encoding="utf-8")
        if os.name == "nt":
            (bin_dir / "vagrant.cmd").write_text(
                f'@"{sys.executable}" "{bin_dir / "fake_vagrant.py"}" %*\r\n', encoding="utf-8")
        else:
            stub = bin_dir / "vagrant"
            stub.write_text(f"#!{sys.executable}\n" + FAKE_VAGRANT, encoding="utf-8")
            stub.chmod(0o755)
        env = {"PATH": f"{bin_dir}{os.pathsep}{os.environ.get('PATH', '')}",
               "FAKE_VAGRANT_DIR": str(self.dir), "RIG_PROVIDER": "libvirt"}
        for patcher in (mock.patch.dict(os.environ, env),
                        mock.patch.object(rig, "REPORTS", self.dir / "reports")):
            patcher.start()
            self.addCleanup(patcher.stop)
        # provider() is worked out once per process: forget it on both sides of RIG_PROVIDER.
        rig.provider.cache_clear()
        self.addCleanup(rig.provider.cache_clear)

    def reply(self, call: int, out: str = "", err: str = "", rc: int = 0) -> None:
        """What call `call` of the fake vagrant prints and exits with."""
        (self.dir / f"{call}.out").write_bytes(out.encode("utf-8"))
        (self.dir / f"{call}.err").write_bytes(err.encode("utf-8"))
        (self.dir / f"{call}.rc").write_text(str(rc), encoding="utf-8")

    def calls(self) -> list[dict]:
        log = self.dir / "calls.log"
        if not log.exists():
            return []
        return [json.loads(line) for line in log.read_text(encoding="utf-8").splitlines()]

    def args(self) -> list[list[str]]:
        return [call["args"] for call in self.calls()]


class VagrantRun(FakeVagrant):
    def test_runs_in_the_vagrant_directory_with_the_provider(self) -> None:
        with redirect_stdout(StringIO()) as out:
            rig.vagrant_run("up", "debian12", "--provider", "libvirt")
        self.assertEqual(out.getvalue(), "+ (vagrant/) vagrant up debian12 --provider libvirt\n")
        [call] = self.calls()
        self.assertEqual(call["args"], ["up", "debian12", "--provider", "libvirt"])
        self.assertEqual(Path(call["cwd"]).resolve(), rig.VAGRANT_DIR.resolve())
        self.assertEqual(call["provider"], "libvirt")

    def test_a_failure_raises(self) -> None:
        self.reply(1, rc=3)
        with redirect_stdout(StringIO()), self.assertRaises(rig.subprocess.CalledProcessError) as raised:
            rig.vagrant_run("halt", "debian12")
        self.assertEqual(raised.exception.returncode, 3)

    def test_no_vagrant_is_a_rig_error(self) -> None:
        with mock.patch.object(rig.shutil, "which", return_value=None), self.assertRaises(rig.RigError):
            rig.vagrant_run("status")


class VagrantCapture(FakeVagrant):
    def test_returns_the_output_without_echo_or_raising(self) -> None:
        self.reply(1, out="body\n", err="oops\n", rc=1)
        with redirect_stdout(StringIO()) as out:
            done = rig.vagrant_capture("ssh", "debian12", "--command", "cat x")
        self.assertEqual(out.getvalue(), "")
        self.assertEqual((done.returncode, done.stdout, done.stderr), (1, "body\n", "oops\n"))
        self.assertEqual(self.args(), [["ssh", "debian12", "--command", "cat x"]])


class VagrantStream(FakeVagrant):
    def test_echoes_each_line_hands_it_over_and_returns_the_code(self) -> None:
        self.reply(1, out="one\ntwo\n", rc=4)
        seen: list[str] = []
        with redirect_stdout(StringIO()) as out:
            rc = rig.vagrant_stream("ssh", "debian12", on_line=seen.append)
        self.assertEqual(rc, 4)
        self.assertEqual(seen, ["one\n", "two\n"])
        self.assertEqual(out.getvalue(), "+ (vagrant/) vagrant ssh debian12\none\ntwo\n")


class FetchReport(FakeVagrant):
    def test_writes_the_guest_report_to_reports_with_lf(self) -> None:
        self.reply(1, out="# report\r\nPASS\r\n")
        dest = rig.fetch_report("win11", rig.Guest("windows"), "C:\\synthaea-rig\\reports\\20261108-win11.md")
        self.assertEqual(dest, self.dir / "reports" / "20261108-win11.md")
        self.assertEqual(dest.read_bytes(), b"# report\nPASS\n")
        self.assertEqual(self.args(), [["winrm", "win11", "--shell", "powershell", "--command",
                                        "Get-Content -Raw -Encoding UTF8 C:\\synthaea-rig\\reports\\20261108-win11.md"]])

    def test_a_failed_fetch_is_a_rig_error(self) -> None:
        self.reply(1, err="no such file\n", rc=1)
        with self.assertRaisesRegex(rig.RigError, "could not fetch /r.md from debian12: no such file"):
            rig.fetch_report("debian12", rig.Guest("linux"), "/r.md")


class RunCommand(FakeVagrant):
    """cmd_run end to end, with the sources sync stubbed out."""

    def setUp(self) -> None:
        super().setUp()
        target = rig.Machine(name="debian12", guest="linux", matrix="m", boxes={"libvirt": "box"})
        for patcher in (mock.patch.object(rig, "machine", return_value=target),
                        mock.patch.object(rig, "need_siblings"),
                        mock.patch.object(rig, "sync"),
                        mock.patch.object(rig, "source_info", return_value="rig 1a2b3c4")):
            patcher.start()
            self.addCleanup(patcher.stop)

    def test_streams_the_runner_then_fetches_its_last_report(self) -> None:
        self.reply(1, out="start\nREPORT: /old.md\nREPORT: /home/vagrant/r/20261108-debian12.md \nend\n", rc=1)
        self.reply(2, out="# report\n")
        with redirect_stdout(StringIO()) as out:
            rc = rig.cmd_run("debian12", ["beacon"])
        self.assertEqual(rc, 1)
        self.assertEqual(self.args(), [
            rig.run_command("debian12", rig.Guest("linux"), "rig 1a2b3c4", ["beacon"]),
            ["ssh", "debian12", "--command", "cat /home/vagrant/r/20261108-debian12.md"]])
        dest = self.dir / "reports" / "20261108-debian12.md"
        self.assertEqual(dest.read_text(encoding="utf-8"), "# report\n")
        self.assertEqual(out.getvalue().splitlines()[1:], [
            "start", "REPORT: /old.md", "REPORT: /home/vagrant/r/20261108-debian12.md ", "end",
            f"report: {dest}"])
        rig.source_info.assert_called_once_with()

    def test_no_report_line_is_a_rig_error_with_the_runners_code(self) -> None:
        for runner_rc, exit_code in ((2, 2), (1, 1), (0, 1)):
            with self.subTest(runner_rc=runner_rc):
                (self.dir / "calls.log").unlink(missing_ok=True)
                self.reply(1, out="stopped\n", rc=runner_rc)
                with redirect_stdout(StringIO()), self.assertRaisesRegex(rig.RigError, "wrote no report") as raised:
                    rig.cmd_run("debian12", [])
                self.assertEqual(raised.exception.exit_code, exit_code)
                self.assertEqual(len(self.calls()), 1)


if __name__ == "__main__":
    unittest.main()
