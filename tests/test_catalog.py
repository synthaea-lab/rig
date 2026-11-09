"""Unit tests of rig.py's machine catalog (python rig.py check runs them)."""

from __future__ import annotations

import copy
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


VALID = {
    "defaults": {
        "linux": {"memory_mb": 6144, "provision": "agent/packaging/toolchain/linux-toolchain.sh"},
        "windows": {"memory_mb": 8192, "provision": "agent/packaging/toolchain/windows-toolchain.ps1"},
    },
    "machines": {
        "debian12": {"guest": "linux", "matrix": "debian-12", "qemu_ssh_port": 50222,
                     "boxes": {"libvirt": "generic/debian12", "qemu": "arm/debian12"}},
        "fedora41": {"guest": "linux", "matrix": "fedora-41", "prep": ["fedora-lvm-prep.sh"],
                     "qemu_ssh_port": 50422, "boxes": {"qemu": "fedora/41-cloud-base"}},
        "alpine319": {"guest": "linux", "matrix": "alpine-3.24", "memory_mb": 4096,
                      "provision": "agent/packaging/toolchain/alpine-toolchain.sh",
                      "boxes": {"libvirt": "generic/alpine319"}},
        "win11": {"guest": "windows", "matrix": "windows-11", "notes": "WinRM.",
                  "boxes": {"hyperv": "win/11"}},
    },
}


class CatalogValidation(unittest.TestCase):
    """rig.py check rejects a machines.json the Vagrantfile would only trip over at `vagrant up`."""

    def problems(self, change=None) -> list[str]:
        catalog = copy.deepcopy(VALID)
        if change:
            change(catalog)
        return rig.catalog_problems(catalog)

    def assert_one_problem(self, change, problem: str) -> None:
        self.assertEqual(self.problems(change), [problem])

    def test_the_rigs_catalog_is_valid(self) -> None:
        self.assertEqual(rig.catalog_problems(json.loads(rig.MACHINES_JSON.read_text(encoding="utf-8"))), [])

    def test_a_valid_catalog_has_no_problems(self) -> None:
        self.assertEqual(self.problems(), [])

    def test_an_unknown_guest(self) -> None:
        self.assert_one_problem(lambda c: c["machines"]["debian12"].update(guest="bsd"),
                              'debian12: guest is "bsd", not one of linux, windows')

    def test_a_missing_guest(self) -> None:
        self.assert_one_problem(lambda c: c["machines"]["win11"].pop("guest"),
                              "win11: guest is null, not one of linux, windows")

    def test_an_empty_matrix(self) -> None:
        self.assert_one_problem(lambda c: c["machines"]["win11"].update(matrix=" "),
                              "win11: matrix is not a docs/machine-matrix.md row name")

    def test_no_boxes(self) -> None:
        self.assert_one_problem(lambda c: c["machines"]["win11"].update(boxes={}),
                              "win11: boxes is not a non-empty object of provider: box")

    def test_an_unknown_provider(self) -> None:
        self.assert_one_problem(lambda c: c["machines"]["win11"]["boxes"].update(vmware="win/11"),
                              "win11: unknown provider `vmware` in boxes (known: libvirt, hyperv, qemu, virtualbox)")

    def test_an_empty_box_name(self) -> None:
        self.assert_one_problem(lambda c: c["machines"]["win11"]["boxes"].update(hyperv=""),
                              "win11: boxes.hyperv is not a box name")

    def test_a_missing_prep_script(self) -> None:
        self.assert_one_problem(lambda c: c["machines"]["fedora41"].update(prep=["fedora-lvm-perp.sh"]),
                              'fedora41: prep script "fedora-lvm-perp.sh" is not a .sh file in provisioning/')

    def test_a_prep_script_given_as_a_path(self) -> None:
        self.assert_one_problem(lambda c: c["machines"]["fedora41"].update(prep=["provisioning/fedora-lvm-prep.sh"]),
                              'fedora41: prep script "provisioning/fedora-lvm-prep.sh" is not a .sh file in provisioning/')

    def test_prep_as_a_string(self) -> None:
        self.assert_one_problem(lambda c: c["machines"]["fedora41"].update(prep="fedora-lvm-prep.sh"),
                              "fedora41: prep is not a list of script names")

    def test_prep_on_a_windows_guest(self) -> None:
        self.assert_one_problem(lambda c: c["machines"]["win11"].update(prep=["fedora-lvm-prep.sh"]),
                              "win11: prep is set, but Windows guests do not run prep scripts")

    def test_provision_shapes(self) -> None:
        linux_shape = ("not a relative / path into a sibling checkout (agent, rules, scenarios, server) "
                       "ending in .sh")
        for provision in ["/agent/packaging/toolchain/x.sh", "agent\\packaging\\x.sh", "agent/../x.sh",
                          "tools/x.sh", "agent/x.ps1", "agent", "agent//x.sh", 42]:
            with self.subTest(provision=provision):
                self.assert_one_problem(lambda c, p=provision: c["machines"]["alpine319"].update(provision=p),
                                      f"alpine319: provision is {json.dumps(provision)}, {linux_shape}")

    def test_a_windows_provision_is_a_powershell_script(self) -> None:
        self.assert_one_problem(lambda c: c["machines"]["win11"].update(provision="agent/toolchain.sh"),
                              'win11: provision is "agent/toolchain.sh", not a relative / path into a sibling '
                              "checkout (agent, rules, scenarios, server) ending in .ps1")

    def test_a_duplicate_qemu_ssh_port_names_both_machines(self) -> None:
        self.assert_one_problem(lambda c: c["machines"]["fedora41"].update(qemu_ssh_port=50222),
                              "fedora41: qemu_ssh_port 50222 is already debian12's")

    def test_a_qemu_ssh_port_out_of_range(self) -> None:
        for port in [22, 70000, "50222", True]:
            with self.subTest(port=port):
                self.assert_one_problem(lambda c, p=port: c["machines"]["debian12"].update(qemu_ssh_port=p),
                                      f"debian12: qemu_ssh_port is {json.dumps(port)}, "
                                      "not a port number from 1024 to 65535")

    def test_a_bad_memory_mb(self) -> None:
        self.assert_one_problem(lambda c: c["machines"]["alpine319"].update(memory_mb="4G"),
                              'alpine319: memory_mb is "4G", not a positive whole number')

    def test_a_misspelt_field(self) -> None:
        def misspell(catalog: dict) -> None:
            catalog["machines"]["debian12"]["qemu_ssh_prot"] = catalog["machines"]["debian12"].pop("qemu_ssh_port")
        self.assert_one_problem(misspell, "debian12: unknown field `qemu_ssh_prot` (known: boxes, guest, matrix, "
                                        "memory_mb, notes, prep, primary, provision, qemu_ssh_port)")

    def test_defaults_for_each_guest(self) -> None:
        self.assert_one_problem(lambda c: c["defaults"].pop("windows"), "defaults: no `windows` entry")
        self.assert_one_problem(lambda c: c["defaults"]["linux"].pop("memory_mb"),
                              "defaults.linux: memory_mb is null, not a positive whole number")

    def test_no_machines(self) -> None:
        self.assert_one_problem(lambda c: c.update(machines={}), "`machines` is not a non-empty object")

    def test_every_problem_is_listed(self) -> None:
        def break_two_machines(catalog: dict) -> None:
            catalog["machines"]["debian12"].update(guest="bsd", boxes={})
            catalog["machines"]["win11"]["boxes"] = {"vmware": "win/11"}
        self.assertEqual(self.problems(break_two_machines), [
            'debian12: guest is "bsd", not one of linux, windows',
            "debian12: boxes is not a non-empty object of provider: box",
            "win11: unknown provider `vmware` in boxes (known: libvirt, hyperv, qemu, virtualbox)",
        ])


class CheckCatalog(unittest.TestCase):
    """check_catalog over a scratch file: the machines when valid, every problem otherwise."""

    def write(self, text: str) -> Path:
        scratch = tempfile.TemporaryDirectory(prefix="rig-catalog-")
        self.addCleanup(scratch.cleanup)
        path = Path(scratch.name) / "machines.json"
        path.write_text(text, encoding="utf-8")
        return path

    def test_a_valid_catalog_loads(self) -> None:
        catalog = rig.check_catalog(self.write(json.dumps(VALID)))
        self.assertEqual(list(catalog), ["debian12", "fedora41", "alpine319", "win11"])

    def test_an_invalid_catalog_lists_its_problems(self) -> None:
        broken = copy.deepcopy(VALID)
        broken["machines"]["debian12"]["guest"] = "bsd"
        broken["machines"]["fedora41"]["qemu_ssh_port"] = 50222
        with self.assertRaises(rig.RigError) as raised:
            rig.check_catalog(self.write(json.dumps(broken)))
        self.assertEqual(str(raised.exception).splitlines(), [
            "machines.json is invalid:",
            '  debian12: guest is "bsd", not one of linux, windows',
            "  fedora41: qemu_ssh_port 50222 is already debian12's",
        ])

    def test_a_catalog_that_does_not_parse(self) -> None:
        with self.assertRaisesRegex(rig.RigError, "machines.json does not parse: "):
            rig.check_catalog(self.write('{"machines": '))


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
