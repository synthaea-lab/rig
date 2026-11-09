"""Unit tests of provisioning/agent-build.sh (python rig.py check runs them).

The script runs in a Linux lab guest. Here it runs against a fake guest in a scratch
directory: SYNTHAEA_ROOT holds a fake agent checkout and rig, HOME is the scratch home, and
fakes of cargo, rustup, rustc, bpf-linker and sudo go first on PATH. The fake cargo logs its
arguments and environment to cargo.log and writes an agent binary whose `status` prints
$FAKE_STATUS; the fake sudo logs to sudo.log and runs everything but `install`.
"""

from __future__ import annotations

import hashlib
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

RIG = Path(__file__).resolve().parent.parent
SCRIPT = RIG / "provisioning" / "agent-build.sh"
EBPF_TOOLCHAIN = "nightly-2026-01-01"
BUILD_INFO_KEYS = ["agent_bin", "source", "built_at", "build_seconds", "profile", "ort", "offline", "rustc"]

FAKE_TOOLS = {
    "cargo": r'''#!/usr/bin/env bash
printf 'args=%s\nRUSTFLAGS=%s\nCARGO_HOME=%s\n' "$*" "${RUSTFLAGS:-}" "${CARGO_HOME:-}" >> "$FAKE_LOG/cargo.log"
profile=debug
for arg in "$@"; do [ "$arg" = --release ] && profile=release; done
bin=${CARGO_TARGET_DIR:-$PWD/target}/$profile/agent
mkdir -p "$(dirname "$bin")"
printf '#!/usr/bin/env bash\nprintf "\\033[32m%%s\\033[0m\\n" "$FAKE_STATUS"\n' > "$bin"
chmod +x "$bin"
echo "   Compiling agent"
''',
    "rustup": f'''#!/usr/bin/env bash
echo "{EBPF_TOOLCHAIN}-x86_64-unknown-linux-gnu"
echo "stable-x86_64-unknown-linux-gnu (default)"
for ((i = 0; i < ${{FAKE_MORE_TOOLCHAINS:-0}}; i++)); do echo "1.$i-x86_64-unknown-linux-gnu"; done
''',
    "rustc": '#!/usr/bin/env bash\necho "rustc 1.99.0 (fake)"\n',
    "bpf-linker": "#!/usr/bin/env bash\n",
    "sudo": r'''#!/usr/bin/env bash
echo "$*" >> "$FAKE_LOG/sudo.log"
[ "$1" = install ] && exit 0
exec "$@"
''',
}


@unittest.skipUnless(sys.platform.startswith("linux"), "agent-build.sh runs in Linux guests only")
class FakeGuest(unittest.TestCase):
    """A fake Linux guest in a scratch directory, where agent-build.sh can run end to end."""

    def setUp(self) -> None:
        scratch = tempfile.TemporaryDirectory(prefix="rig-agent-build-")
        self.addCleanup(scratch.cleanup)
        self.dir = Path(scratch.name)
        self.root = self.dir / "synthaea"
        self.src = self.root / "agent"
        self.home = self.dir / "home"
        self.state = self.home / "synthaea-rig"
        self.home.mkdir()
        self.write(self.src / "Cargo.toml", "[package]\nname = \"agent\"\n")
        self.write(self.src / "Cargo.lock", "# lock\n")
        self.write(self.src / "packaging" / "toolchain" / "ebpf-toolchain.txt", f"{EBPF_TOOLCHAIN}\n")
        self.write(self.src / "crates" / "config" / "data" / "default-agent.toml", "# template\n")
        self.set_ort_compat_check(passes=True)
        self.bin = self.dir / "bin"
        for name, body in FAKE_TOOLS.items():
            self.write(self.bin / name, body, executable=True)
        self.env = {
            "PATH": f"{self.bin}{os.pathsep}/usr/bin{os.pathsep}/bin",
            "HOME": str(self.home),
            "SYNTHAEA_ROOT": str(self.root),
            "SYNTHAEA_SOURCE": "agent 1a2b3c4",
            "FAKE_LOG": str(self.dir),
            "FAKE_STATUS": "eBPF probes loaded",
        }

    @staticmethod
    def write(path: Path, text: str, executable: bool = False) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
        if executable:
            path.chmod(0o755)

    def set_ort_compat_check(self, passes: bool) -> None:
        """The rig's ort-compat.sh: logs its arguments, and `--check` passes or fails."""
        self.write(self.root / "rig" / "provisioning" / "ort-compat.sh",
                   f'echo "$*" >> "$FAKE_LOG/ort-compat.log"\n'
                   f'[ "$1" = --check ] && exit {0 if passes else 1}\nexit 0\n')

    def make_bundle(self, key: str | None = None) -> Path:
        """An unpacked bundle in ~/synthaea-offline, made for the fake checkout unless `key` says otherwise."""
        bundle = self.home / "synthaea-offline"
        lock = (self.src / "Cargo.lock").read_bytes()
        toolchain = (self.src / "packaging" / "toolchain" / "ebpf-toolchain.txt").read_bytes()
        want = hashlib.sha256(lock + b"\0" + toolchain).hexdigest()[:16]
        self.write(bundle / "KEY", f"{key or want}\n")
        self.write(bundle / "vendor-config.toml", '[source.vendored]\ndirectory = "@VENDOR@"\n')
        for crate in ("serde", "libc"):
            (bundle / "vendor" / crate).mkdir(parents=True)
        self.write(bundle / "ort-cache" / "dfbin" / "runtime.tgz", "")
        return bundle

    def run_build(self, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(["bash", str(SCRIPT), *args], env=self.env, cwd=self.dir,
                              capture_output=True, text=True, check=False)

    def log(self, name: str) -> str:
        path = self.dir / name
        return path.read_text(encoding="utf-8") if path.exists() else ""

    def build_info(self) -> dict[str, str]:
        lines = (self.state / "build-info").read_text(encoding="utf-8").splitlines()
        return dict(line.split("=", 1) for line in lines)

    def assert_built(self, result: subprocess.CompletedProcess[str]) -> None:
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def assert_stopped(self, result: subprocess.CompletedProcess[str], message: str, rc: int = 1) -> None:
        self.assertEqual(result.returncode, rc, result.stdout + result.stderr)
        self.assertIn(message, result.stderr)


class DefaultBuild(FakeGuest):
    def test_builds_release_with_prebuilt_runtime_when_the_guest_can_link_it(self) -> None:
        result = self.run_build()
        self.assert_built(result)
        self.assertIn("args=build --release -p agent\n", self.log("cargo.log"))
        self.assertEqual(self.log("ort-compat.log"), "--check\n")
        self.assertIn("prebuilt (pyke, ort-sys download-binaries)", result.stdout)
        self.assertIn("== cargo build (release, all jobs) ==", result.stdout)

    def test_records_the_build_info_keys_in_order(self) -> None:
        self.assert_built(self.run_build())
        info = self.build_info()
        self.assertEqual(list(info), BUILD_INFO_KEYS)
        self.assertEqual(info["agent_bin"], str(self.src / "target" / "release" / "agent"))
        self.assertEqual(info["source"], "agent 1a2b3c4")
        self.assertRegex(info["built_at"], r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$")
        self.assertRegex(info["build_seconds"], r"^\d+$")
        self.assertEqual((info["profile"], info["ort"], info["offline"]), ("release", "prebuilt", "0"))
        self.assertEqual(info["rustc"], "rustc 1.99.0 (fake)")

    def test_says_who_sets_the_source_when_nobody_did(self) -> None:
        del self.env["SYNTHAEA_SOURCE"]
        self.assert_built(self.run_build())
        self.assertEqual(self.build_info()["source"], "unknown (set by rig.py)")

    def test_writes_the_build_log_and_the_status_without_colours(self) -> None:
        self.assert_built(self.run_build())
        self.assertIn("Compiling agent", (self.state / "build.log").read_text(encoding="utf-8"))
        self.assertEqual((self.state / "status.txt").read_text(encoding="utf-8"), "eBPF probes loaded\n")

    def test_installs_the_default_config_and_runs_status_as_root(self) -> None:
        if Path("/etc/synthaea/agent.toml").exists():
            self.skipTest("this host has an /etc/synthaea/agent.toml, so the script installs none")
        self.assert_built(self.run_build())
        bin_path = self.src / "target" / "release" / "agent"
        self.assertEqual(self.log("sudo.log").splitlines(), [
            f"install -D -m 0644 {self.src}/crates/config/data/default-agent.toml /etc/synthaea/agent.toml",
            f"{bin_path} status",
        ])

    def test_finds_the_probe_toolchain_at_the_top_of_a_long_list(self) -> None:
        # A grep that stops reading at the first match makes rustup's later writes fail,
        # and pipefail used to report that as a missing toolchain.
        self.env["FAKE_MORE_TOOLCHAINS"] = "20000"
        self.assert_built(self.run_build())

    def test_debug_builds_without_release(self) -> None:
        self.assert_built(self.run_build("--debug"))
        self.assertIn("args=build -p agent\n", self.log("cargo.log"))
        info = self.build_info()
        self.assertEqual(info["profile"], "debug")
        self.assertEqual(info["agent_bin"], str(self.src / "target" / "debug" / "agent"))

    def test_honours_the_cargo_target_dir(self) -> None:
        self.env["CARGO_TARGET_DIR"] = str(self.dir / "target")
        self.assert_built(self.run_build())
        self.assertEqual(self.build_info()["agent_bin"], str(self.dir / "target" / "release" / "agent"))

    def test_ort_compat_installs_before_checking(self) -> None:
        self.assert_built(self.run_build("--ort-compat"))
        self.assertEqual(self.log("ort-compat.log"), "--apply\n--check\n")

    def test_explicit_prebuilt_skips_the_check(self) -> None:
        self.assert_built(self.run_build("--ort", "prebuilt"))
        self.assertEqual(self.log("ort-compat.log"), "")
        self.assertEqual(self.build_info()["ort"], "prebuilt")

    def test_moves_a_global_vendored_sources_config_aside(self) -> None:
        config = self.home / ".cargo" / "config.toml"
        self.write(config, '[source.vendored-sources]\ndirectory = "x"\n')
        result = self.run_build()
        self.assert_built(result)
        self.assertFalse(config.exists())
        self.assertTrue((self.home / ".cargo" / "config.toml.vendored-bak").exists())
        self.assertIn("moved a global vendored-sources ~/.cargo/config.toml aside", result.stdout)

    def test_help_prints_the_header_without_comment_marks(self) -> None:
        result = self.run_build("--help")
        self.assert_built(result)
        self.assertTrue(result.stdout.startswith("Builds the agent inside a provisioned Linux lab guest"), result.stdout)
        self.assertIn("  --debug          a debug build instead of --release\n", result.stdout)
        self.assertNotIn("set -euo", result.stdout)
        self.assertEqual(self.log("cargo.log"), "")


class StaticRuntime(FakeGuest):
    def setUp(self) -> None:
        super().setUp()
        self.ort_lib = self.src / "onnxruntime" / "build" / "Linux" / "Release"
        self.write(self.ort_lib / "libonnxruntime_session.a", "")
        self.write(self.ort_lib / "_deps" / "re2-build" / "libre2.a", "")
        self.write(self.src / "packaging" / "toolchain" / "ort-static-link-flags.sh",
                   'echo "export RUSTFLAGS=\'-L $ORT_LIB_LOCATION -l static=onnxruntime_session\'"\n')

    def test_links_the_source_built_runtime_with_the_generated_flags(self) -> None:
        result = self.run_build("--ort", "static")
        self.assert_built(result)
        cargo = self.log("cargo.log")
        self.assertIn("args=build --release -p agent --no-default-features --features test-key\n", cargo)
        self.assertIn(f"RUSTFLAGS=-L {self.ort_lib} -l static=onnxruntime_session\n", cargo)
        self.assertIn(f"static from source: ORT_LIB_LOCATION={self.ort_lib}", result.stdout)
        self.assertIn("== cargo build (release --no-default-features --features test-key, all jobs) ==",
                      result.stdout)
        self.assertEqual(self.build_info()["ort"], "static")

    def test_stops_when_the_link_flags_cannot_be_generated(self) -> None:
        self.write(self.src / "packaging" / "toolchain" / "ort-static-link-flags.sh",
                   'echo "no .a files found under $ORT_LIB_LOCATION" >&2\nexit 1\n')
        self.assert_stopped(self.run_build("--ort", "static"), "no .a files found under")
        self.assertEqual(self.log("cargo.log"), "")

    def test_static_is_not_possible_offline(self) -> None:
        self.assert_stopped(self.run_build("--ort", "static", "--offline"), "no offline bundle in the guest", rc=2)
        self.make_bundle()
        self.assert_stopped(self.run_build("--ort", "static", "--offline"),
                            "agent-build: --ort static clones and builds onnxruntime: not possible offline", rc=2)


class OfflineBundle(FakeGuest):
    def test_builds_from_the_unpacked_bundle(self) -> None:
        bundle = self.make_bundle()
        result = self.run_build("--offline")
        self.assert_built(result)
        cargo_home = bundle / "cargo-home"
        self.assertEqual((cargo_home / "config.toml").read_text(encoding="utf-8"),
                         f'[source.vendored]\ndirectory = "{bundle}/vendor"\n\n[net]\noffline = true\n')
        self.assertIn(f"CARGO_HOME={cargo_home}\n", self.log("cargo.log"))
        self.assertTrue((self.home / ".cache" / "ort.pyke.io" / "dfbin" / "runtime.tgz").exists())
        self.assertIn(f"vendored crates: 2, cargo home: {cargo_home}", result.stdout)
        self.assertEqual(self.build_info()["offline"], "1")

    def test_ort_compat_warns_that_it_needs_the_mirror(self) -> None:
        self.make_bundle()
        result = self.run_build("--offline", "--ort-compat")
        self.assert_built(result)
        self.assertIn("--ort-compat installs packages: it needs the guest's package mirror even with --offline",
                      result.stdout)

    def test_stops_without_a_bundle(self) -> None:
        self.assert_stopped(self.run_build("--offline"), "agent-build: no offline bundle in the guest", rc=2)
        self.assertEqual(self.log("cargo.log"), "")

    def test_stops_on_a_bundle_for_another_lock(self) -> None:
        self.make_bundle(key="0123456789abcdef")
        self.assert_stopped(self.run_build("--offline"), "the offline bundle (0123456789abcdef) was made for another", rc=2)


class Refusals(FakeGuest):
    def test_unknown_option(self) -> None:
        self.assert_stopped(self.run_build("--fast"), "agent-build: unknown option --fast (see --help)", rc=2)

    def test_unknown_ort_mode(self) -> None:
        self.assert_stopped(self.run_build("--ort", "shared"), "agent-build: --ort must be auto, prebuilt or static", rc=2)

    def test_ort_without_a_mode(self) -> None:
        self.assert_stopped(self.run_build("--ort"), "agent-build: --ort needs auto|prebuilt|static (see --help)", rc=2)

    def test_auto_stops_when_the_guest_cannot_link_the_prebuilt_runtime(self) -> None:
        self.set_ort_compat_check(passes=False)
        result = self.run_build()
        self.assert_stopped(result, "agent-build: this guest cannot link the prebuilt ONNX Runtime", rc=2)
        self.assertIn("  --ort static   build ONNX Runtime from source", result.stderr)
        self.assertEqual(self.log("cargo.log"), "")

    def test_unsynced_sources(self) -> None:
        (self.src / "Cargo.toml").unlink()
        self.assert_stopped(self.run_build(), "Cargo.toml missing - are the sources synced?", rc=2)

    def test_no_cargo(self) -> None:
        if Path("/usr/bin/cargo").exists() or Path("/bin/cargo").exists():
            self.skipTest("a system cargo is on the fake guest's PATH")
        (self.bin / "cargo").unlink()
        self.assert_stopped(self.run_build(), "no cargo - the guest is not provisioned", rc=2)

    def test_no_bpf_linker(self) -> None:
        if shutil.which("bpf-linker", path=f"/usr/bin{os.pathsep}/bin"):
            self.skipTest("a system bpf-linker is on the fake guest's PATH")
        (self.bin / "bpf-linker").unlink()
        self.assert_stopped(self.run_build(), "bpf-linker not on PATH", rc=2)

    def test_missing_probe_toolchain(self) -> None:
        self.write(self.src / "packaging" / "toolchain" / "ebpf-toolchain.txt", "nightly-2099-01-01\n")
        self.assert_stopped(self.run_build(), "probe toolchain nightly-2099-01-01 missing", rc=2)

    def test_failing_rustup_reports_the_missing_probe_toolchain(self) -> None:
        self.write(self.bin / "rustup", "#!/usr/bin/env bash\nexit 127\n", executable=True)
        self.assert_stopped(self.run_build(), f"probe toolchain {EBPF_TOOLCHAIN} missing (vagrant provision <machine>)", rc=2)

    def test_a_build_without_probes(self) -> None:
        self.env["FAKE_STATUS"] = "agent built without embedded eBPF probes"
        self.assert_stopped(self.run_build(), "the build has no eBPF probes")
        self.assertFalse((self.state / "build-info").exists())

    def test_a_failed_cargo_build_exits_1_not_cargos_code(self) -> None:
        self.write(self.bin / "cargo", "#!/usr/bin/env bash\necho 'error[E0425]: oops'\nexit 101\n", executable=True)
        result = self.run_build()
        self.assert_stopped(result, f"agent-build: cargo build failed (see {self.state / 'build.log'})")
        self.assertIn("error[E0425]: oops", (self.state / "build.log").read_text(encoding="utf-8"))
        self.assertFalse((self.state / "build-info").exists())


if __name__ == "__main__":
    unittest.main()
