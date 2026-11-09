"""Unit tests of what rig.py and tools/offline_bundle.py share (python rig.py check runs them)."""

from __future__ import annotations

import subprocess
import sys
import unittest
from contextlib import redirect_stderr
from io import StringIO
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import rig  # noqa: E402
from tools import offline_bundle, riglib  # noqa: E402


class RunCli(unittest.TestCase):
    def run_quietly(self, task) -> tuple[int, str]:
        with redirect_stderr(StringIO()) as err:
            rc = riglib.run_cli(task)
        return rc, err.getvalue()

    def test_a_task_that_returns_nothing_exits_0(self) -> None:
        self.assertEqual(self.run_quietly(lambda: None), (0, ""))

    def test_a_task_returns_its_own_code(self) -> None:
        self.assertEqual(self.run_quietly(lambda: 1), (1, ""))

    def test_a_rig_error_prints_its_message_and_exits_2(self) -> None:
        def task() -> None:
            raise riglib.RigError("do this first")

        self.assertEqual(self.run_quietly(task), (2, "error: do this first\n"))

    def test_a_failed_check_prints_its_message_and_exits_1(self) -> None:
        def task() -> None:
            raise riglib.CheckFailed("the sidecars drift")

        self.assertEqual(self.run_quietly(task), (1, "error: the sidecars drift\n"))

    def test_a_rig_error_can_carry_another_code(self) -> None:
        def task() -> None:
            raise riglib.RigError("the runner wrote no report", riglib.EXIT_FAILED)

        self.assertEqual(self.run_quietly(task), (1, "error: the runner wrote no report\n"))

    def test_a_bundle_error_is_a_rig_error(self) -> None:
        def task() -> None:
            raise offline_bundle.BundleError("no ort-sys")

        self.assertEqual(self.run_quietly(task), (2, "error: no ort-sys\n"))

    def test_a_failed_command_exits_with_its_code(self) -> None:
        def fails(code: int):
            def task() -> None:
                raise subprocess.CalledProcessError(code, ["vagrant", "up"])
            return task

        self.assertEqual(self.run_quietly(fails(5)), (5, ""))
        self.assertEqual(self.run_quietly(fails(-9)), (-9, ""))

    def test_other_errors_propagate(self) -> None:
        def task() -> None:
            raise ValueError("bug")

        with self.assertRaises(ValueError):
            riglib.run_cli(task)


class SharedPaths(unittest.TestCase):
    def test_both_tools_see_one_rig_and_root(self) -> None:
        self.assertEqual(riglib.RIG, Path(rig.__file__).resolve().parent)
        self.assertEqual((rig.RIG, rig.ROOT, rig.VAGRANT_DIR), (riglib.RIG, riglib.ROOT, riglib.VAGRANT_DIR))
        self.assertEqual((offline_bundle.RIG, offline_bundle.ROOT), (riglib.RIG, riglib.ROOT))
        self.assertIs(rig.RigError, riglib.RigError)


if __name__ == "__main__":
    unittest.main()
