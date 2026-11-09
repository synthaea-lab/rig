"""What rig.py and tools/offline_bundle.py share: the rig's paths, how they drive vagrant, and
how a failed task ends the process.

rig.py imports it as `tools.riglib`; a script in tools/ puts the rig checkout on sys.path first.
"""

from __future__ import annotations

import functools
import os
import platform
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Callable

RIG = Path(__file__).resolve().parents[1]
# The directory holding agent/, rules/ and scenarios/ (server/ optional) next to rig/.
ROOT = Path(os.environ.get("RIG_ROOT") or os.environ.get("SYNTHAEA_ROOT") or RIG.parent).resolve()
VAGRANT_DIR = RIG / "vagrant"
WINDOWS = os.name == "nt"


# The exit codes of every rig tool, the bash scripts' runner/lib/common.sh included
# (CONTRIBUTING.md, "Exit codes"). 0 is OK.
EXIT_FAILED = 1  # the task ran and something failed: a scenario, a check, a build
EXIT_CANNOT_RUN = 2  # a usage error (as argparse's) or an unmet environment


class RigError(RuntimeError):
    """The task cannot run (a usage error or an unmet environment); the message says what to
    do. The process exits with `exit_code`: EXIT_CANNOT_RUN unless the raiser says otherwise."""

    def __init__(self, message: str, exit_code: int = EXIT_CANNOT_RUN) -> None:
        super().__init__(message)
        self.exit_code = exit_code


class CheckFailed(RigError):
    """The task ran and found a problem, which the message describes: the process exits
    EXIT_FAILED."""

    def __init__(self, message: str) -> None:
        super().__init__(message, EXIT_FAILED)


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


def vagrant_env() -> dict[str, str]:
    """The environment vagrant runs in: this host's provider as the default, ROOT as RIG_ROOT."""
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


def run_cli(task: Callable[[], int | None]) -> int:
    """Runs a tool's task and returns the process exit code: the task's own (0 when it returns
    None), a RigError's `exit_code` after printing its message (EXIT_CANNOT_RUN, or
    EXIT_FAILED for a CheckFailed), or the code of a command that failed."""
    try:
        return task() or 0
    except RigError as err:
        print(f"error: {err}", file=sys.stderr)
        return err.exit_code
    except subprocess.CalledProcessError as err:
        return err.returncode or 1
