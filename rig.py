#!/usr/bin/env python3
"""The Synthaea testing rig: boot a lab VM, build the agent in it, run scenarios, report.

    python rig.py list                          the machine catalog, with this host's boxes
    python rig.py up <machine>                  boot (and on first boot provision) a VM
    python rig.py build <machine> [--offline] [--ort auto|prebuilt|static] [--ort-compat]
    python rig.py run <machine> [scenario ...]  run scenarios, copy the report to reports/
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
import json
import os
import platform
import shutil
import subprocess
import sys
import time
import zipfile
from pathlib import Path

RIG = Path(__file__).resolve().parent
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


def provider() -> str:
    if os.environ.get("RIG_PROVIDER"):
        return os.environ["RIG_PROVIDER"]
    if WINDOWS:
        return "hyperv"
    if sys.platform == "darwin":
        return "qemu" if platform.machine() == "arm64" else "virtualbox"
    return "libvirt"


def machines() -> dict:
    return json.loads((RIG / "machines.json").read_text(encoding="utf-8"))["machines"]


def machine(name: str) -> dict:
    catalog, prov = machines(), provider()
    if name not in catalog:
        raise RigError(f"unknown machine '{name}'; known: {' '.join(catalog)}")
    if prov not in catalog[name]["boxes"]:
        raise RigError(f"{name} has no box for the {prov} provider (machines.json); "
                       f"it runs on: {' '.join(catalog[name]['boxes'])}")
    return catalog[name]


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


def vagrant(*args: str, capture: bool = False) -> subprocess.CompletedProcess:
    """Runs vagrant in vagrant/ with this host's provider as the default."""
    exe = shutil.which("vagrant")
    if not exe:
        raise RigError("vagrant is not installed (README.md, 'Prerequisites')")
    if not capture:
        print(f"+ (vagrant/) vagrant {' '.join(args)}", flush=True)
    return subprocess.run([exe, *args], cwd=VAGRANT_DIR, env=vagrant_env(), text=True,
                          encoding="utf-8", errors="replace", check=not capture, capture_output=capture)


def guest_shell(name: str, spec: dict, command: str) -> list[str]:
    """The vagrant arguments that run `command` in the guest's shell."""
    if spec["guest"] == "windows":
        return ["winrm", name, "--shell", "powershell", "--command", command]
    return ["ssh", name, "--command", command]


def git(path: Path, *args: str) -> str:
    res = subprocess.run(["git", "-C", str(path), *args], text=True, capture_output=True)
    return res.stdout.strip() if res.returncode == 0 else ""


def source_info() -> str:
    """What the guest builds and runs: the commit (and a dirty mark) of each checkout."""
    parts = []
    for name in [*SIBLINGS, "rig"]:
        path = RIG if name == "rig" else ROOT / name
        sha = git(path, "rev-parse", "--short", "HEAD") if path.is_dir() else ""
        if sha:
            dirty = "+dirty" if git(path, "status", "--porcelain", "--untracked-files=no") else ""
            parts.append(f"{name} {sha}{dirty}")
    return ", ".join(parts)


def sync(name: str, spec: dict) -> None:
    """Pushes the sources: rsync for Linux guests, a zip upload for Windows guests (WinRM)."""
    if spec["guest"] != "windows":
        vagrant("rsync", name)
        return
    archive = RIG / ".offline" / "synthaea-src.zip"
    archive.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as zf:
        for part in [*SIBLINGS, "rig"]:
            base = RIG if part == "rig" else ROOT / part
            if not base.is_dir():
                continue
            files = git(base, "ls-files", "--cached", "--others", "--exclude-standard").splitlines()
            for rel in files:
                if (base / rel).is_file():
                    zf.write(base / rel, f"{part}/{rel}")
    vagrant("upload", str(archive), "C:/synthaea-src.zip", name)
    vagrant(*guest_shell(name, spec, f"Expand-Archive -Force C:\\synthaea-src.zip {WIN_SRC}"))


# --- commands -------------------------------------------------------------------------


def cmd_list() -> None:
    prov = provider()
    print(f"machines (provider for this host: {prov}; RIG_PROVIDER overrides), root {ROOT}:")
    for name, spec in machines().items():
        box = spec["boxes"].get(prov, f"- (no {prov} box)")
        print(f"  {name:<11} {spec['guest']:<8} {spec['matrix']:<24} {box}")


def cmd_up(name: str) -> None:
    machine(name)
    need_siblings()
    vagrant("up", name, "--provider", provider())


def cmd_build(name: str, offline: bool, ort: str, ort_compat: bool) -> None:
    spec = machine(name)
    need_siblings()
    sync(name, spec)
    if spec["guest"] == "windows":
        vagrant(*guest_shell(name, spec, f"& {WIN_SRC}\\rig\\provisioning\\agent-build.ps1 -Source '{source_info()}'"))
        return
    if offline:
        subprocess.run([sys.executable, str(RIG / "tools" / "offline_bundle.py"), "--push", name],
                       check=True, env=vagrant_env())
    flags = ["--ort", ort] + (["--offline"] if offline else []) + (["--ort-compat"] if ort_compat else [])
    vagrant(*guest_shell(name, spec, f"SYNTHAEA_SOURCE='{source_info()}' bash /synthaea/rig/provisioning/agent-build.sh {' '.join(flags)}"))


def cmd_run(name: str, scenarios: list[str]) -> int:
    spec = machine(name)
    need_siblings()
    sync(name, spec)
    names = " ".join(scenarios)
    if spec["guest"] == "windows":
        cmd = f"& {WIN_SRC}\\rig\\runner\\run-scenarios.ps1 -Machine {name} -Source '{source_info()}' {names}"
    else:
        cmd = f"SYNTHAEA_SOURCE='{source_info()}' bash /synthaea/rig/runner/run-scenarios.sh --machine {name} {names}"
    args = guest_shell(name, spec, cmd)
    print(f"+ (vagrant/) vagrant {' '.join(args)}", flush=True)
    proc = subprocess.Popen([shutil.which("vagrant") or "vagrant", *args], cwd=VAGRANT_DIR, env=vagrant_env(),
                            text=True, stdout=subprocess.PIPE, encoding="utf-8", errors="replace")
    report = None
    for line in proc.stdout:
        print(line, end="", flush=True)
        if line.startswith("REPORT: "):
            report = line[len("REPORT: "):].strip()
    rc = proc.wait()
    if not report:
        raise RigError("the runner wrote no report (see its output above)")
    fetch = "Get-Content -Raw -Encoding UTF8 " if spec["guest"] == "windows" else "cat "
    fetched = vagrant(*guest_shell(name, spec, fetch + report), capture=True)
    if fetched.returncode != 0:
        raise RigError(f"could not fetch {report} from {name}: {fetched.stderr.strip()}")
    dest = REPORTS / Path(report.replace("\\", "/")).name
    REPORTS.mkdir(exist_ok=True)
    dest.write_text(fetched.stdout.replace("\r\n", "\n"), encoding="utf-8")
    print(f"report: {dest}")
    return rc


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
    vagrant(*(["destroy", "--force", name] if destroy else ["halt", name]))


def cmd_check() -> None:
    """What CI can check without a VM: scripts parse, the catalogs match the scenarios,
    the two runners read the sidecars alike, runner/windows/validate-admin.ps1 loads its
    scenarios sibling."""
    bash = shutil.which("bash")
    if not bash:
        raise RigError("bash is needed for the checks (Git for Windows ships one)")
    scripts = sorted([*RIG.glob("*.sh"), *RIG.glob("*/*.sh")])
    for script in scripts:
        subprocess.run([bash, "-n", str(script.relative_to(RIG))], cwd=RIG, check=True)
    json.loads((RIG / "machines.json").read_text(encoding="utf-8"))
    print(f"rig: {len(scripts)} scripts parse, machines.json parses", flush=True)
    scenarios = ROOT / "scenarios" / "scenarios"
    if scenarios.is_dir():
        subprocess.run([bash, "runner/run-scenarios.sh", "--check", "--scenarios", scenarios.as_posix()],
                       cwd=RIG, check=True)
    else:
        print(f"skipped: no {scenarios} for the runner catalog check")
    check_runners_read_sidecars_alike(bash, scenarios)
    check_admin_validation_loads_common()


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
    p = sub.add_parser("run")
    p.add_argument("machine")
    p.add_argument("scenarios", nargs="*", help="default: every default scenario of runner/scenarios.conf")
    sub.add_parser("report").add_argument("machine", nargs="?")
    p = sub.add_parser("down")
    p.add_argument("machine")
    p.add_argument("--destroy", action="store_true", help="delete the VM instead of halting it")
    sub.add_parser("check")
    args = parser.parse_args()

    commands = {
        "list": cmd_list,
        "up": lambda: cmd_up(args.machine),
        "build": lambda: cmd_build(args.machine, args.offline, args.ort, args.ort_compat),
        "run": lambda: cmd_run(args.machine, args.scenarios),
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
