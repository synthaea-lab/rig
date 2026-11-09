"""Unit tests of the rig's exit-code convention (python rig.py check runs them): 0 OK, 1 the
task ran and something failed, 2 a usage error or an unmet environment. rig.py's main maps
its commands' outcomes to those codes, and the bash scripts that source runner/lib/common.sh
exit with them before they touch a guest.
"""

from __future__ import annotations

import shutil
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from io import StringIO
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import rig  # noqa: E402

RIG = Path(rig.__file__).resolve().parent


class MainExitCodes(unittest.TestCase):
    def main(self, *argv: str) -> tuple[int, str]:
        """rig.py's exit code for `argv`, as `python rig.py` would exit, and its stderr."""
        with mock.patch.object(sys, "argv", ["rig.py", *argv]), \
                redirect_stdout(StringIO()), redirect_stderr(StringIO()) as err:
            try:
                rc = rig.main()
            except SystemExit as exited:
                rc = exited.code
        return rc, err.getvalue()

    def test_a_command_that_succeeds_exits_0(self) -> None:
        with mock.patch.object(rig, "cmd_list", return_value=None):
            self.assertEqual(self.main("list"), (0, ""))

    def test_an_unknown_command_is_a_usage_error(self) -> None:
        self.assertEqual(self.main("launch")[0], 2)

    def test_a_missing_argument_is_a_usage_error(self) -> None:
        self.assertEqual(self.main("up")[0], 2)

    def test_an_unknown_machine_is_a_usage_error(self) -> None:
        catalog = {"debian12": rig.Machine(name="debian12", guest="linux", matrix="m", boxes={"libvirt": "box"})}
        with mock.patch.object(rig, "machines", return_value=catalog):
            self.assertEqual(self.main("up", "bsd14"), (2, "error: unknown machine 'bsd14'; known: debian12\n"))

    def test_run_exits_with_the_runners_code(self) -> None:
        for runner_rc in (0, 1, 2):
            with self.subTest(runner_rc=runner_rc), mock.patch.object(rig, "cmd_run", return_value=runner_rc):
                self.assertEqual(self.main("run", "debian12")[0], runner_rc)

    def test_a_check_finding_exits_1(self) -> None:
        with mock.patch.object(rig, "run_checks", side_effect=rig.CheckFailed("sidecars drift")):
            self.assertEqual(self.main("check"), (1, "error: sidecars drift\n"))

    def test_a_check_script_that_fails_exits_1_whatever_its_own_code(self) -> None:
        # bash -n exits 2 on a syntax error: still a failed check, not a usage error.
        failed = subprocess.CalledProcessError(2, ["bash", "-n", "runner/run-scenarios.sh"])
        with mock.patch.object(rig, "run_checks", side_effect=failed):
            self.assertEqual(self.main("check"), (1, "error: bash -n runner/run-scenarios.sh exited 2 (above)\n"))

    def test_an_invalid_catalog_is_a_check_finding_in_check(self) -> None:
        with mock.patch.object(rig, "check_unit_tests"), mock.patch.object(rig.subprocess, "run"), \
                mock.patch.object(rig, "check_catalog", side_effect=rig.RigError("machines.json is invalid")):
            self.assertEqual(self.main("check"), (1, "error: machines.json is invalid\n"))

    def test_check_without_bash_cannot_run(self) -> None:
        with mock.patch.object(rig.shutil, "which", return_value=None):
            self.assertEqual(self.main("check")[0], 2)


@unittest.skipUnless(shutil.which("bash"), "no bash")
class ShellExitCodes(unittest.TestCase):
    """The scripts' usage and environment errors exit 2, a failed check 1."""

    def run_script(self, script: str, *args: str) -> tuple[int, str]:
        done = subprocess.run([shutil.which("bash"), script, *args], cwd=RIG, check=False,
                              capture_output=True, encoding="utf-8")
        return done.returncode, done.stderr

    def test_runner_unknown_option(self) -> None:
        self.assertEqual(self.run_script("runner/run-scenarios.sh", "--bogus"),
                         (2, "run-scenarios: unknown option --bogus (see --help)\n"))

    def test_runner_option_without_its_values(self) -> None:
        for args, needs in ((["--judge", "alerts.ndjson", "x.yaml"], "SNAPSHOT SIDECAR RC"),
                            (["--scenarios"], "DIR"), (["--machine", ""], "NAME")):
            with self.subTest(args=args):
                self.assertEqual(self.run_script("runner/run-scenarios.sh", *args),
                                 (2, f"run-scenarios: {args[0]} needs {needs} (see --help)\n"))

    def test_runner_check_without_a_scenarios_directory(self) -> None:
        with tempfile.TemporaryDirectory(prefix="rig-exit-") as scratch:
            missing = (Path(scratch) / "scenarios").as_posix()
            self.assertEqual(self.run_script("runner/run-scenarios.sh", "--check", "--scenarios", missing),
                             (2, f"run-scenarios: no scenarios directory at {missing}\n"))

    def test_runner_catalog_that_fails_its_check(self) -> None:
        with tempfile.TemporaryDirectory(prefix="rig-exit-") as scratch:
            rc, err = self.run_script("runner/run-scenarios.sh", "--scenarios", Path(scratch).as_posix())
        self.assertEqual((rc, err), (1, "run-scenarios: fix the catalog first\n"))

    def test_agent_build_unknown_option(self) -> None:
        self.assertEqual(self.run_script("provisioning/agent-build.sh", "--bogus"),
                         (2, "agent-build: unknown option --bogus (see --help)\n"))

    def test_agent_build_option_without_its_value(self) -> None:
        self.assertEqual(self.run_script("provisioning/agent-build.sh", "--ort"),
                         (2, "agent-build: --ort needs auto|prebuilt|static (see --help)\n"))


if __name__ == "__main__":
    unittest.main()
