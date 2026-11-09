"""Unit tests of rig.py's guest command lines (python rig.py check runs them).

The expected strings for ordinary names are the bytes rig.py sent before Guest existed:
quoting must not change what an ordinary build or run sends to a VM.
"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import rig  # noqa: E402
from rig import Flag, Guest  # noqa: E402

SOURCE = "agent 1a2b3c4, rules 5d6e7f8+dirty, scenarios 9a0b1c2, rig 3d4e5f6"
LINUX = Guest("linux")
WINDOWS = Guest("windows")


class OrdinaryCommandsAreUnchanged(unittest.TestCase):
    def setUp(self) -> None:
        patcher = mock.patch.object(rig, "source_info", return_value=SOURCE)
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_linux_build(self) -> None:
        self.assertEqual(
            rig.build_command("debian12", LINUX, offline=True, ort="static", ort_compat=True),
            ["ssh", "debian12", "--command",
             f"SYNTHAEA_SOURCE='{SOURCE}' bash /synthaea/rig/provisioning/agent-build.sh "
             "--ort static --offline --ort-compat"])

    def test_linux_build_defaults(self) -> None:
        self.assertEqual(
            rig.build_command("ubuntu2404", LINUX, offline=False, ort="auto", ort_compat=False)[-1],
            f"SYNTHAEA_SOURCE='{SOURCE}' bash /synthaea/rig/provisioning/agent-build.sh --ort auto")

    def test_windows_build(self) -> None:
        self.assertEqual(
            rig.build_command("win11", WINDOWS, offline=True, ort="static", ort_compat=True),
            ["winrm", "win11", "--shell", "powershell", "--command",
             f"& C:\\synthaea\\rig\\provisioning\\agent-build.ps1 -Source '{SOURCE}'"])

    def test_linux_run(self) -> None:
        self.assertEqual(
            rig.run_command("debian12", LINUX, ["beacon", "lineage"]),
            ["ssh", "debian12", "--command",
             f"SYNTHAEA_SOURCE='{SOURCE}' bash /synthaea/rig/runner/run-scenarios.sh "
             "--machine debian12 beacon lineage"])

    def test_linux_run_default_scenarios(self) -> None:
        self.assertEqual(
            rig.run_command("debian12", LINUX, [])[-1],
            f"SYNTHAEA_SOURCE='{SOURCE}' bash /synthaea/rig/runner/run-scenarios.sh --machine debian12")

    def test_windows_run(self) -> None:
        self.assertEqual(
            rig.run_command("win11", WINDOWS, ["bits-job", "windows-container"]),
            ["winrm", "win11", "--shell", "powershell", "--command",
             f"& C:\\synthaea\\rig\\runner\\run-scenarios.ps1 -Machine win11 -Source '{SOURCE}' "
             "bits-job windows-container"])

    def test_windows_unpack(self) -> None:
        self.assertEqual(
            WINDOWS.command("Expand-Archive", Flag("-Force"), "C:\\synthaea-src.zip", rig.WIN_SRC),
            "Expand-Archive -Force C:\\synthaea-src.zip C:\\synthaea")

    def test_report_fetch(self) -> None:
        self.assertEqual(LINUX.read_file("/home/vagrant/synthaea-rig/reports/20261108-debian12.md"),
                         "cat /home/vagrant/synthaea-rig/reports/20261108-debian12.md")
        self.assertEqual(WINDOWS.read_file("C:\\synthaea-rig\\reports\\20261108-win11.md"),
                         "Get-Content -Raw -Encoding UTF8 C:\\synthaea-rig\\reports\\20261108-win11.md")


class CraftedArgumentsStayOneWord(unittest.TestCase):
    def test_linux_quotes_shell_syntax(self) -> None:
        self.assertEqual(LINUX.invoke("runner/run-scenarios.sh", "a b", "x;reboot", "$(id)"),
                         "bash /synthaea/rig/runner/run-scenarios.sh 'a b' 'x;reboot' '$(id)'")

    def test_linux_quotes_a_single_quote_in_env(self) -> None:
        self.assertEqual(LINUX.invoke("provisioning/agent-build.sh", env={"SYNTHAEA_SOURCE": "it's"}),
                         "SYNTHAEA_SOURCE='it'\"'\"'s' bash /synthaea/rig/provisioning/agent-build.sh")

    def test_windows_doubles_single_quotes(self) -> None:
        self.assertEqual(WINDOWS.invoke("runner/run-scenarios.ps1", Flag("-Source"), "it's; Stop-Computer"),
                         "& C:\\synthaea\\rig\\runner\\run-scenarios.ps1 -Source 'it''s; Stop-Computer'")

    def test_windows_doubles_typographic_single_quotes(self) -> None:
        self.assertEqual(WINDOWS.quote("a\u2019b"), "'a\u2019\u2019b'")

    def test_windows_quotes_powershell_syntax(self) -> None:
        for word in ["$env:PATH", "a,b", "@x", "(1)", "a`b", "x|y", "a b", "#c", "", "-Machine"]:
            with self.subTest(word=word):
                self.assertEqual(WINDOWS.quote(word), f"'{word}'")

    def test_linux_quotes_the_empty_word(self) -> None:
        self.assertEqual(LINUX.quote(""), "''")


class GuestBoundaries(unittest.TestCase):
    def test_flags_must_look_like_flags(self) -> None:
        for guest in (LINUX, WINDOWS):
            with self.subTest(guest=guest.os), self.assertRaises(ValueError):
                guest.quote(Flag("--x; reboot"))

    def test_windows_takes_no_env(self) -> None:
        with self.assertRaises(ValueError):
            WINDOWS.invoke("runner/run-scenarios.ps1", env={"SYNTHAEA_SOURCE": SOURCE})

    def test_env_names_are_checked(self) -> None:
        with self.assertRaises(ValueError):
            LINUX.invoke("runner/run-scenarios.sh", env={"A=1 B": "x"})

    def test_unknown_guest_is_an_error(self) -> None:
        with self.assertRaises(rig.RigError):
            Guest.of({"guest": "bsd"})

    def test_script_paths(self) -> None:
        self.assertEqual(LINUX.script_path("runner/run-scenarios.sh"), "/synthaea/rig/runner/run-scenarios.sh")
        self.assertEqual(WINDOWS.script_path("runner/run-scenarios.ps1"),
                         "C:\\synthaea\\rig\\runner\\run-scenarios.ps1")


if __name__ == "__main__":
    unittest.main()
