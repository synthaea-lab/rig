#!/usr/bin/env python3
"""The Synthaea testing rig: boot a lab VM, build the agent in it, run scenarios, report.

    python rig.py list                          the machine catalog, with this host's boxes
    python rig.py up <machine>                  boot (and on first boot provision) a VM
    python rig.py build <machine> [--offline] [--ort auto|prebuilt|static] [--ort-compat] [--dry-run]
    python rig.py run <machine> [scenario ...] [--dry-run]
                                                run scenarios, copy the report to reports/
    python rig.py report [machine]              print the newest report
    python rig.py down <machine> [--destroy]    halt (or delete) the VM
    python rig.py check                         lint the rig's scripts and scenario catalog

Works the same on Linux (libvirt), Windows (Hyper-V, elevated shell) and Apple Silicon
(QEMU); RIG_PROVIDER overrides the provider. The rig works on its root directory: the
parent of this checkout, holding agent/, rules/ and scenarios/ (server/ optional) next to
rig/. RIG_ROOT (or SYNTHAEA_ROOT) overrides it. README.md is the guide.
"""

from __future__ import annotations

import argparse
import functools
import json
import os
import platform
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import zipfile
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

RIG = Path(__file__).resolve().parent
MACHINES_JSON = RIG / "machines.json"
ROOT = Path(os.environ.get("RIG_ROOT") or os.environ.get("SYNTHAEA_ROOT") or RIG.parent).resolve()
VAGRANT_DIR = RIG / "vagrant"
REPORTS = RIG / "reports"
WINDOWS = os.name == "nt"
# Synced to /synthaea/<name> in Linux guests, uploaded to C:\synthaea\<name> in Windows ones.
SIBLINGS = ["agent", "rules", "scenarios", "server"]
REQUIRED = ["agent", "rules", "scenarios"]
WIN_SRC = "C:\\synthaea"


class RigError(RuntimeError):
    """The task cannot proceed; the message says what to do."""


@functools.cache
def provider() -> str:
    """This host's Vagrant provider (RIG_PROVIDER overrides it), worked out once per process."""
    if os.environ.get("RIG_PROVIDER"):
        return os.environ["RIG_PROVIDER"]
    if WINDOWS:
        return "hyperv"
    if sys.platform == "darwin":
        return "qemu" if platform.machine() == "arm64" else "virtualbox"
    return "libvirt"


@dataclass(frozen=True)
class Machine:
    """One machines.json entry, with the fields rig.py uses (the Vagrantfile reads the rest)."""

    name: str
    guest: str
    matrix: str
    boxes: dict[str, str]

    @classmethod
    def from_entry(cls, name: str, entry: dict) -> Machine:
        return cls(name=name, guest=entry["guest"], matrix=entry["matrix"], boxes=dict(entry["boxes"]))


def load_catalog(path: Path) -> dict[str, Machine]:
    """The machines of the catalog at `path`, by name, in its order."""
    entries = json.loads(path.read_text(encoding="utf-8"))["machines"]
    return {name: Machine.from_entry(name, entry) for name, entry in entries.items()}


@functools.cache
def machines() -> dict[str, Machine]:
    """The rig's machine catalog, read from machines.json once per process."""
    return load_catalog(MACHINES_JSON)


def machine(name: str) -> Machine:
    """Machine `name` of the catalog, which must have a box for this host's provider."""
    catalog, prov = machines(), provider()
    if name not in catalog:
        raise RigError(f"unknown machine '{name}'; known: {' '.join(catalog)}")
    found = catalog[name]
    if prov not in found.boxes:
        raise RigError(f"{name} has no box for the {prov} provider (machines.json); "
                       f"it runs on: {' '.join(found.boxes)}")
    return found


def need_siblings() -> None:
    missing = [p for p in REQUIRED if not (ROOT / p).is_dir()]
    if missing:
        raise RigError(f"{ROOT} has no {', '.join(missing)}: clone them next to rig/ "
                       "(README.md, 'Setup'), or point RIG_ROOT at the directory that has them")


def vagrant_env() -> dict[str, str]:
    env = {**os.environ, "VAGRANT_DEFAULT_PROVIDER": provider(), "RIG_ROOT": str(ROOT)}
    if provider() == "hyperv":
        env.setdefault("VAGRANT_HYPERV_SWITCH", "Default Switch")
    return env


def vagrant_command(args: tuple[str, ...]) -> list[str]:
    exe = shutil.which("vagrant")
    if not exe:
        raise RigError("vagrant is not installed (README.md, 'Prerequisites')")
    return [exe, *args]


def echo_vagrant(args: tuple[str, ...] | list[str]) -> None:
    print(f"+ (vagrant/) vagrant {' '.join(args)}", flush=True)


def vagrant_run(*args: str) -> None:
    """Runs vagrant in vagrant/ with this host's provider as the default; a failure raises
    CalledProcessError."""
    command = vagrant_command(args)
    echo_vagrant(args)
    subprocess.run(command, cwd=VAGRANT_DIR, env=vagrant_env(), check=True)


def vagrant_capture(*args: str) -> subprocess.CompletedProcess:
    """Runs vagrant like vagrant_run, quietly, and returns its exit code and output."""
    return subprocess.run(vagrant_command(args), cwd=VAGRANT_DIR, env=vagrant_env(), check=False,
                          capture_output=True, text=True, encoding="utf-8", errors="replace")


def vagrant_stream(*args: str, on_line: Callable[[str], None]) -> int:
    """Runs vagrant like vagrant_run, echoes each line of its output as it comes and hands
    it to `on_line`, and returns its exit code."""
    command = vagrant_command(args)
    echo_vagrant(args)
    with subprocess.Popen(command, cwd=VAGRANT_DIR, env=vagrant_env(), stdout=subprocess.PIPE,
                          text=True, encoding="utf-8", errors="replace") as proc:
        for line in proc.stdout:
            print(line, end="", flush=True)
            on_line(line)
    return proc.returncode


class Flag(str):
    """A command-line switch (`--machine`, `-Source`) that the guest's shell must see bare,
    where every other argument is quoted."""


FLAG = re.compile(r"--?[A-Za-z][A-Za-z0-9-]*")
ENV_NAME = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
# What PowerShell reads as one literal bare word: no quotes, $, @, `, braces, parentheses,
# commas, ;, |, &, <, >, # or whitespace, and no leading - (that would be a parameter name).
POWERSHELL_BARE = re.compile(r"[A-Za-z0-9_.:\\/][A-Za-z0-9_.:\\/+-]*")
# PowerShell ends a '...' string at any of these, and reads each one doubled as itself.
POWERSHELL_SINGLE_QUOTES = re.compile("['\u2018\u2019\u201a\u201b]")


@dataclass(frozen=True)
class Guest:
    """A lab VM's shell: bash over ssh in Linux guests, PowerShell over WinRM in Windows ones.
    It builds the one command line vagrant sends, quoting every argument for that shell."""

    os: str

    @classmethod
    def of(cls, target: Machine) -> Guest:
        if target.guest not in ("linux", "windows"):
            raise RigError(f"unknown guest '{target.guest}' in machines.json (linux or windows)")
        return cls(target.guest)

    @property
    def windows(self) -> bool:
        return self.os == "windows"

    def script_path(self, rel: str) -> str:
        """Where the rig's `rel` (a / path in this checkout) is in the guest's copy of it."""
        if self.windows:
            return WIN_SRC + "\\rig\\" + rel.replace("/", "\\")
        return f"/synthaea/rig/{rel}"

    def quote(self, arg: str) -> str:
        """`arg` as one literal word of the guest's shell. A Flag stays bare."""
        if isinstance(arg, Flag):
            if not FLAG.fullmatch(arg):
                raise ValueError(f"not a command-line switch: {arg!r}")
            return str(arg)
        if not self.windows:
            return shlex.quote(arg)
        if POWERSHELL_BARE.fullmatch(arg):
            return arg
        return "'" + POWERSHELL_SINGLE_QUOTES.sub(lambda quote: quote.group() * 2, arg) + "'"

    def command(self, program: str, *args: str, env: dict[str, str] | None = None) -> str:
        """The command line that runs `program` with `args` (and, in Linux guests, `env`)."""
        return self._line([self.quote(program)], args, env)

    def invoke(self, script: str, *args: str, env: dict[str, str] | None = None) -> str:
        """The command line that runs the rig's `script` (bash or PowerShell) with `args`."""
        launcher = "&" if self.windows else "bash"
        return self._line([launcher, self.quote(self.script_path(script))], args, env)

    def _line(self, head: list[str], args: tuple[str, ...], env: dict[str, str] | None) -> str:
        assignments = []
        for key, value in (env or {}).items():
            if self.windows:
                raise ValueError("Windows guest scripts take parameters, not environment variables")
            if not ENV_NAME.fullmatch(key):
                raise ValueError(f"not an environment variable name: {key!r}")
            assignments.append(f"{key}={self.quote(value)}")
        return " ".join([*assignments, *head, *map(self.quote, args)])

    def read_file(self, path: str) -> str:
        """The command line that prints the guest's file `path` (UTF-8)."""
        if self.windows:
            return self.command("Get-Content", Flag("-Raw"), Flag("-Encoding"), "UTF8", path)
        return self.command("cat", path)

    def shell(self, name: str, command: str) -> list[str]:
        """The vagrant arguments that run `command` in machine `name`'s shell."""
        if self.windows:
            return ["winrm", name, "--shell", "powershell", "--command", command]
        return ["ssh", name, "--command", command]


def git(path: Path, *args: str) -> str | None:
    """The stripped output of `git -C path args`, or None when git fails (not a repository,
    no commit yet): callers decide what a missing answer means."""
    res = subprocess.run(["git", "-C", str(path), *args], text=True, capture_output=True, check=False)
    return res.stdout.strip() if res.returncode == 0 else None


def source_info() -> str:
    """What the guest builds and runs: the commit (and a dirty mark) of each checkout.
    It runs two git processes per checkout, so a command computes it once."""
    parts = []
    for name in [*SIBLINGS, "rig"]:
        path = RIG if name == "rig" else ROOT / name
        sha = git(path, "rev-parse", "--short", "HEAD") if path.is_dir() else None
        if sha:
            dirty = "+dirty" if git(path, "status", "--porcelain", "--untracked-files=no") else ""
            parts.append(f"{name} {sha}{dirty}")
    return ", ".join(parts)


def sync(target: Machine) -> None:
    """Pushes the sources: rsync for Linux guests, a zip upload for Windows guests (WinRM)."""
    name, guest = target.name, Guest.of(target)
    if not guest.windows:
        vagrant_run("rsync", name)
        return
    archive = RIG / ".offline" / "synthaea-src.zip"
    archive.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as zf:
        for part in [*SIBLINGS, "rig"]:
            base = RIG if part == "rig" else ROOT / part
            if not base.is_dir():
                continue
            files = (git(base, "ls-files", "--cached", "--others", "--exclude-standard") or "").splitlines()
            for rel in files:
                if (base / rel).is_file():
                    zf.write(base / rel, f"{part}/{rel}")
    vagrant_run("upload", str(archive), "C:/synthaea-src.zip", name)
    vagrant_run(*guest.shell(name, guest.command("Expand-Archive", Flag("-Force"), "C:\\synthaea-src.zip", WIN_SRC)))


# --- commands -------------------------------------------------------------------------


def cmd_list() -> None:
    prov = provider()
    print(f"machines (provider for this host: {prov}; RIG_PROVIDER overrides), root {ROOT}:")
    for name, listed in machines().items():
        box = listed.boxes.get(prov, f"- (no {prov} box)")
        print(f"  {name:<11} {listed.guest:<8} {listed.matrix:<24} {box}")


def cmd_up(name: str) -> None:
    machine(name)
    need_siblings()
    vagrant_run("up", name, "--provider", provider())


def build_command(name: str, guest: Guest, source: str, offline: bool, ort: str, ort_compat: bool) -> list[str]:
    """The vagrant arguments that build the agent in the guest; `source` is source_info()."""
    if guest.windows:
        return guest.shell(name, guest.invoke("provisioning/agent-build.ps1", Flag("-Source"), source))
    flags = [Flag("--ort"), ort] + ([Flag("--offline")] if offline else []) + ([Flag("--ort-compat")] if ort_compat else [])
    return guest.shell(name, guest.invoke("provisioning/agent-build.sh", *flags, env={"SYNTHAEA_SOURCE": source}))


def run_command(name: str, guest: Guest, source: str, scenarios: list[str]) -> list[str]:
    """The vagrant arguments that run `scenarios` (default: the catalog's) in the guest;
    `source` is source_info()."""
    if guest.windows:
        return guest.shell(name, guest.invoke("runner/run-scenarios.ps1", Flag("-Machine"), name,
                                              Flag("-Source"), source, *scenarios))
    return guest.shell(name, guest.invoke("runner/run-scenarios.sh", Flag("--machine"), name, *scenarios,
                                          env={"SYNTHAEA_SOURCE": source}))


def print_dry_run(args: list[str]) -> None:
    echo_vagrant(args)
    print("(dry run: nothing synced or run)")


def cmd_build(name: str, offline: bool, ort: str, ort_compat: bool, dry_run: bool = False) -> None:
    target = machine(name)
    guest = Guest.of(target)
    need_siblings()
    args = build_command(name, guest, source_info(), offline, ort, ort_compat)
    if dry_run:
        print_dry_run(args)
        return
    sync(target)
    if offline and not guest.windows:
        subprocess.run([sys.executable, str(RIG / "tools" / "offline_bundle.py"), "--push", name],
                       check=True, env=vagrant_env())
    vagrant_run(*args)


REPORT_LINE = "REPORT: "


def cmd_run(name: str, scenarios: list[str], dry_run: bool = False) -> int:
    target = machine(name)
    guest = Guest.of(target)
    need_siblings()
    args = run_command(name, guest, source_info(), scenarios)
    if dry_run:
        print_dry_run(args)
        return 0
    sync(target)
    report = ""

    def note_report(line: str) -> None:
        """Keeps the guest path of the runner's last `REPORT: <path>` line."""
        nonlocal report
        if line.startswith(REPORT_LINE):
            report = line[len(REPORT_LINE):].strip()

    rc = vagrant_stream(*args, on_line=note_report)
    if not report:
        raise RigError("the runner wrote no report (see its output above)")
    print(f"report: {fetch_report(name, guest, report)}")
    return rc


def fetch_report(name: str, guest: Guest, path: str) -> Path:
    """Copies the report at `path` in machine `name` to reports/ (LF line endings)."""
    fetched = vagrant_capture(*guest.shell(name, guest.read_file(path)))
    if fetched.returncode != 0:
        raise RigError(f"could not fetch {path} from {name}: {fetched.stderr.strip()}")
    dest = REPORTS / Path(path.replace("\\", "/")).name
    REPORTS.mkdir(exist_ok=True)
    dest.write_text(fetched.stdout.replace("\r\n", "\n"), encoding="utf-8")
    return dest


def cmd_report(name: str | None) -> None:
    reports = sorted(REPORTS.glob(f"*-{name}.md" if name else "*-*.md"),
                     key=lambda p: p.stat().st_mtime, reverse=True)
    if not reports:
        raise RigError("no report yet: python rig.py run <machine>")
    print(reports[0].read_text(encoding="utf-8"))
    stamp = time.strftime("%Y-%m-%d %H:%M", time.localtime(reports[0].stat().st_mtime))
    others = f"; others: {', '.join(p.name for p in reports[1:6])}" if len(reports) > 1 else ""
    print(f"({reports[0]}, {stamp}{others})")


def cmd_down(name: str, destroy: bool) -> None:
    machine(name)
    vagrant_run(*(["destroy", "--force", name] if destroy else ["halt", name]))


def cmd_check() -> None:
    """What CI can check without a VM: the unit tests pass, scripts parse and are shellcheck-clean, the catalogs
    match the scenarios, the two runners read the sidecars alike, run-scenarios.sh judges
    alert snapshots as tests/judge states, runner/windows/validate-admin.ps1 loads its
    scenarios sibling, runner/LabAgent.ps1 writes the lab config and drives an agent by pid."""
    bash = shutil.which("bash")
    if not bash:
        raise RigError("bash is needed for the checks (Git for Windows ships one)")
    check_unit_tests()
    scripts = sorted([*RIG.glob("*.sh"), *RIG.glob("*/*.sh")])
    for script in scripts:
        subprocess.run([bash, "-n", str(script.relative_to(RIG))], cwd=RIG, check=True)
    load_catalog(MACHINES_JSON)
    print(f"rig: {len(scripts)} scripts parse, machines.json parses", flush=True)
    check_shellcheck_clean(scripts)
    scenarios = ROOT / "scenarios" / "scenarios"
    if scenarios.is_dir():
        subprocess.run([bash, "runner/run-scenarios.sh", "--check", "--scenarios", scenarios.as_posix()],
                       cwd=RIG, check=True)
    else:
        print(f"skipped: no {scenarios} for the runner catalog check")
    check_runners_read_sidecars_alike(bash, scenarios)
    check_runner_judges_as_stated(bash)
    check_runner_judges_every_sidecar(bash, scenarios)
    check_admin_validation_loads_common()
    check_lab_agent_lifecycle()


def check_unit_tests() -> None:
    """The stdlib unittest suites in tests/ (test_*.py) pass."""
    subprocess.run([sys.executable, "-B", "-m", "unittest", "discover", "--start-directory", "tests",
                    "--pattern", "test_*.py"], cwd=RIG, check=True)


def check_shellcheck_clean(scripts: list[Path]) -> None:
    """Every shell script is shellcheck-clean at its default severity (style and up).
    A finding that is intended carries a `# shellcheck disable=...` with the reason."""
    shellcheck = shutil.which("shellcheck")
    if not shellcheck:
        print("skipped: no shellcheck for the shell script lint")
        return
    found = subprocess.run([shellcheck, *(script.relative_to(RIG).as_posix() for script in scripts)],
                           cwd=RIG, check=False)
    if found.returncode != 0:
        raise RigError("shellcheck has findings in the scripts (above)")
    print(f"rig: {len(scripts)} scripts are shellcheck-clean", flush=True)


SIDECAR_FIXTURES = RIG / "tests" / "sidecars"


def check_runners_read_sidecars_alike(bash: str, scenarios: Path) -> None:
    """run-scenarios.sh and run-scenarios.ps1 each parse the sidecars' expected_detections
    (Linux guests have no pwsh, Windows guests no bash). The bash parser must read what each
    fixture in tests/sidecars states in its `# reads:` lines; where pwsh exists, the
    PowerShell parser must read the same as the bash one from the fixtures and every sidecar."""
    fixtures = sorted(SIDECAR_FIXTURES.glob("*.yaml"))
    sidecars = fixtures + (sorted(scenarios.glob("*.yaml")) if scenarios.is_dir() else [])
    from_bash = {sidecar: bash_expectations(bash, sidecar) for sidecar in sidecars}
    wrong = [f"  {fixture.name}: reads {from_bash[fixture]}, states {stated_expectations(fixture)}"
             for fixture in fixtures if from_bash[fixture] != stated_expectations(fixture)]
    if wrong:
        raise RigError("run-scenarios.sh misreads these sidecar fixtures:\n" + "\n".join(wrong))
    print(f"runners: run-scenarios.sh reads the {len(fixtures)} sidecar fixtures as stated", flush=True)
    pwsh = shutil.which("pwsh")
    if not pwsh:
        print("skipped: no pwsh for the bash/PowerShell sidecar parser parity check")
        return
    from_pwsh = powershell_expectations(pwsh, sidecars)
    drift = [f"  {sidecar.name}: bash {from_bash[sidecar]} vs PowerShell {from_pwsh[sidecar]}"
             for sidecar in sidecars if from_bash[sidecar] != from_pwsh[sidecar]]
    if drift:
        raise RigError("the runners read these sidecars differently:\n" + "\n".join(drift))
    print(f"runners: bash and PowerShell read {len(sidecars)} sidecars alike", flush=True)


def stated_expectations(fixture: Path) -> list[str]:
    """The `technique|min_count|tolerance` lines a fixture states with `# reads: ...`."""
    prefix = "# reads: "
    return [line[len(prefix):].strip() for line in fixture.read_text(encoding="utf-8").splitlines()
            if line.startswith(prefix)]


def bash_expectations(bash: str, sidecar: Path) -> list[str]:
    return subprocess.run([bash, "runner/run-scenarios.sh", "--expectations", sidecar.as_posix()],
                          cwd=RIG, check=True, stdout=subprocess.PIPE, encoding="utf-8").stdout.splitlines()


def powershell_expectations(pwsh: str, sidecars: list[Path]) -> dict[Path, list[str]]:
    out = subprocess.run([pwsh, "-NoProfile", "-NonInteractive", "-File",
                          str(RIG / "tests" / "print-ps-expectations.ps1"), *map(str, sidecars)],
                         cwd=RIG, check=True, stdout=subprocess.PIPE, encoding="utf-8").stdout
    read: dict[Path, list[str]] = {sidecar: [] for sidecar in sidecars}
    for line in out.splitlines():
        path, expectation = line.split("|", 1)
        read[Path(path)].append(expectation)
    return read


JUDGE_FIXTURES = RIG / "tests" / "judge"


def check_runner_judges_as_stated(bash: str) -> None:
    """Golden test of run-scenarios.sh's verdict: each case in tests/judge holds an alerts
    snapshot (alerts.ndjson, absent for none) and a `verdict` file naming the sidecar fixture
    and the script's exit code in `# sidecar:` / `# rc:` lines; its other lines are what
    `run-scenarios.sh --judge` must print."""
    wrong = []
    cases = sorted(case for case in JUDGE_FIXTURES.iterdir() if case.is_dir())
    for case in cases:
        stated = (case / "verdict").read_text(encoding="utf-8").splitlines()
        sidecar = SIDECAR_FIXTURES / stated_value(stated, "sidecar")
        judged = bash_verdict(bash, case / "alerts.ndjson", sidecar, int(stated_value(stated, "rc")))
        if judged != [line for line in stated if not line.startswith("#")]:
            wrong.append(f"  {case.name}: judged {judged}")
    if wrong:
        raise RigError("run-scenarios.sh judges these tests/judge cases otherwise than stated:\n"
                       + "\n".join(wrong))
    print(f"runner: run-scenarios.sh judges the {len(cases)} snapshot fixtures as stated", flush=True)


def check_runner_judges_every_sidecar(bash: str, scenarios: Path) -> None:
    """Each real sidecar's expectations are judged at their bounds: a snapshot with every
    expected technique at min_count passes, one at min_count + tolerance + 1 fails."""
    sidecars = sorted(scenarios.glob("*.yaml")) if scenarios.is_dir() else []
    if not sidecars:
        print(f"skipped: no sidecars in {scenarios} for the runner verdict check")
        return
    wrong = []
    with tempfile.TemporaryDirectory(prefix="rig-judge-") as scratch:
        snapshot = Path(scratch) / "alerts.ndjson"
        for sidecar in sidecars:
            expected = [line.split("|") for line in bash_expectations(bash, sidecar)]
            at_min = {technique: int(min_count) for technique, min_count, _ in expected}
            write_alert_snapshot(snapshot, at_min)
            if verdict_status(bash_verdict(bash, snapshot, sidecar, 0)) != "PASS":
                wrong.append(f"  {sidecar.name}: does not PASS with {at_min}")
            if not expected:
                continue
            over = {technique: int(min_count) + int(tolerance) + 1 for technique, min_count, tolerance in expected}
            write_alert_snapshot(snapshot, over)
            if verdict_status(bash_verdict(bash, snapshot, sidecar, 0)) != "FAIL":
                wrong.append(f"  {sidecar.name}: does not FAIL with {over}")
    if wrong:
        raise RigError("run-scenarios.sh misjudges these sidecars at their bounds:\n" + "\n".join(wrong))
    print(f"runner: run-scenarios.sh judges {len(sidecars)} sidecars at their bounds", flush=True)


def stated_value(lines: list[str], key: str) -> str:
    """The value of a `# key: value` line."""
    prefix = f"# {key}: "
    return next(line[len(prefix):].strip() for line in lines if line.startswith(prefix))


def write_alert_snapshot(path: Path, counts: dict[str, int]) -> None:
    """An alerts snapshot with `count` alerts per technique, in the agent's NDJSON shape."""
    alerts = [json.dumps({"technique": technique, "message": f"alert {index}"}, separators=(",", ":"))
              for technique, count in counts.items() for index in range(count)]
    path.write_text("".join(f"{alert}\n" for alert in alerts), encoding="utf-8", newline="\n")


def bash_verdict(bash: str, snapshot: Path, sidecar: Path, rc: int) -> list[str]:
    command = [bash, "runner/run-scenarios.sh", "--judge", snapshot.as_posix(), sidecar.as_posix(), str(rc)]
    return subprocess.run(command, cwd=RIG, check=True, stdout=subprocess.PIPE, encoding="utf-8").stdout.splitlines()


def verdict_status(verdict: list[str]) -> str:
    return next(line.removeprefix("status=") for line in verdict if line.startswith("status="))


def check_admin_validation_loads_common() -> None:
    """runner/windows/validate-admin.ps1 resolves and loads ROOT/scenarios/scenarios/common.ps1."""
    pwsh = shutil.which("pwsh")
    if not pwsh:
        print("skipped: no pwsh for the runner/windows/validate-admin.ps1 sibling-path check")
        return
    if not (ROOT / "scenarios").is_dir():
        print(f"skipped: no {ROOT / 'scenarios'} for the runner/windows/validate-admin.ps1 sibling-path check")
        return
    subprocess.run([pwsh, "-NoProfile", "-NonInteractive", "-File",
                    str(RIG / "tests" / "validate-admin-resolves-siblings.ps1"), "-Root", str(ROOT)],
                   cwd=RIG, check=True)


def check_lab_agent_lifecycle() -> None:
    """runner/LabAgent.ps1 writes the lab agent.toml of tests/lab-agent/ (from
    runner/lab-agent.toml.template) and starts, waits for and stops an agent by pid (a fake
    one, where /bin/sh exists)."""
    pwsh = shutil.which("pwsh")
    if not pwsh:
        print("skipped: no pwsh for the runner/LabAgent.ps1 lifecycle check")
        return
    subprocess.run([pwsh, "-NoProfile", "-NonInteractive", "-File", str(RIG / "tests" / "lab-agent.ps1")],
                   cwd=RIG, check=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="cmd", required=True)
    sub.add_parser("list")
    sub.add_parser("up").add_argument("machine")
    p = sub.add_parser("build")
    p.add_argument("machine")
    p.add_argument("--offline", action="store_true", help="vendor crates on the host and push them (slow networks)")
    p.add_argument("--ort", choices=["auto", "prebuilt", "static"], default="auto", help="how ONNX Runtime is linked")
    p.add_argument("--ort-compat", action="store_true", help="Debian 12 / Ubuntu 22.04: newer glibc + libstdc++ first")
    p.add_argument("--dry-run", action="store_true", help="print the guest command instead of syncing and running it")
    p = sub.add_parser("run")
    p.add_argument("machine")
    p.add_argument("scenarios", nargs="*", help="default: every default scenario of runner/scenarios.conf")
    p.add_argument("--dry-run", action="store_true", help="print the guest command instead of syncing and running it")
    sub.add_parser("report").add_argument("machine", nargs="?")
    p = sub.add_parser("down")
    p.add_argument("machine")
    p.add_argument("--destroy", action="store_true", help="delete the VM instead of halting it")
    sub.add_parser("check")
    args = parser.parse_args()

    commands = {
        "list": cmd_list,
        "up": lambda: cmd_up(args.machine),
        "build": lambda: cmd_build(args.machine, args.offline, args.ort, args.ort_compat, args.dry_run),
        "run": lambda: cmd_run(args.machine, args.scenarios, args.dry_run),
        "report": lambda: cmd_report(args.machine),
        "down": lambda: cmd_down(args.machine, args.destroy),
        "check": cmd_check,
    }
    try:
        return commands[args.cmd]() or 0
    except RigError as err:
        print(f"error: {err}", file=sys.stderr)
        return 2
    except subprocess.CalledProcessError as err:
        return err.returncode or 1


if __name__ == "__main__":
    sys.exit(main())
