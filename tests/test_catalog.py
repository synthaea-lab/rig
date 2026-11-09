"""Unit tests of rig.py's machine catalog (python rig.py check runs them)."""

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
from rig import Machine  # noqa: E402

PROVIDERS = {"libvirt", "hyperv", "qemu", "virtualbox"}
CATALOG = {
    "_doc": ["a test catalog"],
    "defaults": {"linux": {"memory_mb": 1}},
    "machines": {
        "debian12": {"guest": "linux", "matrix": "debian-12", "qemu_ssh_port": 50222,
                     "boxes": {"libvirt": "generic/debian12", "qemu": "arm/debian12"}},
        "win11": {"guest": "windows", "matrix": "windows-11", "boxes": {"hyperv": "win/11"}},
    },
}
DEBIAN12 = Machine(name="debian12", guest="linux", matrix="debian-12",
                   boxes={"libvirt": "generic/debian12", "qemu": "arm/debian12"})


class TheRigsCatalog(unittest.TestCase):
    """machines.json itself loads into machines rig.py can drive."""

    def setUp(self) -> None:
        self.catalog = rig.load_catalog(rig.MACHINES_JSON)

    def test_every_machine_loads_under_its_own_name(self) -> None:
        self.assertTrue(self.catalog)
        for name, listed in self.catalog.items():
            with self.subTest(machine=name):
                self.assertEqual(listed.name, name)
                self.assertTrue(listed.matrix)

    def test_every_guest_is_one_the_rig_drives(self) -> None:
        for name, listed in self.catalog.items():
            with self.subTest(machine=name):
                self.assertEqual(rig.Guest.of(listed).os, listed.guest)

    def test_every_machine_has_boxes_for_known_providers_only(self) -> None:
        for name, listed in self.catalog.items():
            with self.subTest(machine=name):
                self.assertTrue(listed.boxes)
                self.assertLessEqual(set(listed.boxes), PROVIDERS)


class ACatalogFile(unittest.TestCase):
    """The once-per-process catalog over a scratch machines.json, on a libvirt host."""

    def setUp(self) -> None:
        scratch = tempfile.TemporaryDirectory(prefix="rig-catalog-")
        self.addCleanup(scratch.cleanup)
        self.path = Path(scratch.name) / "machines.json"
        self.path.write_text(json.dumps(CATALOG), encoding="utf-8")
        for patcher in (mock.patch.object(rig, "MACHINES_JSON", self.path),
                        mock.patch.dict(os.environ, {"RIG_PROVIDER": "libvirt"})):
            patcher.start()
            self.addCleanup(patcher.stop)
        for cached in (rig.machines, rig.provider):
            cached.cache_clear()
            self.addCleanup(cached.cache_clear)

    def test_loads_the_fields_rig_uses_in_catalog_order(self) -> None:
        catalog = rig.load_catalog(self.path)
        self.assertEqual(list(catalog), ["debian12", "win11"])
        self.assertEqual(catalog["debian12"], DEBIAN12)

    def test_machine_returns_the_entry(self) -> None:
        self.assertEqual(rig.machine("debian12"), DEBIAN12)

    def test_an_unknown_machine_names_the_known_ones(self) -> None:
        with self.assertRaisesRegex(rig.RigError, "unknown machine 'bsd14'; known: debian12 win11"):
            rig.machine("bsd14")

    def test_a_machine_without_a_box_for_this_provider_names_where_it_runs(self) -> None:
        with self.assertRaisesRegex(rig.RigError, "win11 has no box for the libvirt provider "
                                                  r"\(machines.json\); it runs on: hyperv"):
            rig.machine("win11")

    def test_the_file_is_read_once_per_process(self) -> None:
        with mock.patch.object(rig, "load_catalog", wraps=rig.load_catalog) as load:
            rig.machine("debian12")
            rig.machines()
            with self.assertRaises(rig.RigError):
                rig.machine("win11")
        load.assert_called_once_with(self.path)

    def test_list_prints_each_machine_with_this_providers_box(self) -> None:
        with redirect_stdout(StringIO()) as out:
            rig.cmd_list()
        self.assertEqual(out.getvalue().splitlines(), [
            f"machines (provider for this host: libvirt; RIG_PROVIDER overrides), root {rig.ROOT}:",
            "  debian12    linux    debian-12                generic/debian12",
            "  win11       windows  windows-11               - (no libvirt box)",
        ])


class Git(unittest.TestCase):
    def test_a_failed_command_is_none(self) -> None:
        with tempfile.TemporaryDirectory(prefix="rig-not-a-repo-") as scratch:
            self.assertIsNone(rig.git(Path(scratch) / "missing", "rev-parse", "--short", "HEAD"))

    def test_output_is_stripped(self) -> None:
        with tempfile.TemporaryDirectory(prefix="rig-repo-") as scratch:
            self.assertEqual(rig.git(Path(scratch), "init", "--quiet"), "")
            self.assertEqual(rig.git(Path(scratch), "rev-parse", "--is-inside-work-tree"), "true")


class SourceInfo(unittest.TestCase):
    def test_names_each_checkout_with_its_commit_and_dirty_mark(self) -> None:
        answers = {("rev-parse", "--short", "HEAD"): "1a2b3c4",
                   ("status", "--porcelain", "--untracked-files=no"): None}
        dirty = {("rev-parse", "--short", "HEAD"): "5d6e7f8",
                 ("status", "--porcelain", "--untracked-files=no"): " M rig.py"}

        def fake_git(path: Path, *args: str) -> str | None:
            return (dirty if path == rig.RIG else answers)[args]

        with tempfile.TemporaryDirectory(prefix="rig-root-") as scratch:
            root = Path(scratch)
            (root / "agent").mkdir()
            (root / "rules").mkdir()
            with mock.patch.object(rig, "ROOT", root), mock.patch.object(rig, "git", side_effect=fake_git):
                self.assertEqual(rig.source_info(), "agent 1a2b3c4, rules 1a2b3c4, rig 5d6e7f8+dirty")


if __name__ == "__main__":
    unittest.main()
