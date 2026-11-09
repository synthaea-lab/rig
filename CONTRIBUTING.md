# Contributing to rig

The organization-wide rules (issues, the Developer Certificate of Origin, licensing of
contributions) are in the
[Synthaea contributing guide](https://github.com/synthaea-lab/.github/blob/main/CONTRIBUTING.md).
This page covers what is specific to the rig. Report vulnerabilities privately, as described
in the [security policy](https://github.com/synthaea-lab/.github/blob/main/SECURITY.md),
never in a public issue.

## Local checks

`python3 rig.py check` (or `python rig.py check` on Windows, or `just check`) is everything
the rig can check without a VM. Run it before opening a pull request. It needs the
[scenarios](https://github.com/synthaea-lab/scenarios) checkout next to the rig and bash
(on Windows, the one from Git for Windows). It verifies that:

- the Python unit tests in `tests/test_*.py` pass (stdlib `unittest`; `tests/test_rig.py`
  pins the command lines `rig.py` sends to a guest, `tests/test_vagrant.py` how it runs
  vagrant, against a fake `vagrant` on `PATH`, `tests/test_offline_bundle.py` how
  `tools/offline_bundle.py` pushes a bundle with the same fake and that its bundle KEY matches
  the one `provisioning/agent-build.sh` computes in bash, `tests/test_riglib.py` the
  exit codes of `tools/riglib.py`, which both tools share, `tests/test_exit_codes.py`
  how `rig.py` and the bash scripts follow the [exit-code convention](#exit-codes),
  and `tests/test_agent_build.py` what `provisioning/agent-build.sh` runs, refuses and
  records in `build-info`, against a fake guest (Linux only);
- every shell script parses, and is shellcheck-clean when `shellcheck` is installed;
- `machines.json` holds what the Vagrantfile and `rig.py` rely on: a `linux` or `windows`
  guest, a non-empty `boxes` of known providers, `prep` scripts that exist in `provisioning/`,
  a `provision` path into a sibling checkout, unique `qemu_ssh_port`s and no unknown field
  (`tests/test_catalog.py` pins each message, which names the machine);
- the runner catalogs (`runner/scenarios.conf`, `runner/scenarios-windows.conf`) have a row
  for every scenario, and every sidecar is readable;
- `run-scenarios.sh` judges the alert snapshots in `tests/judge/` as each case's `verdict`
  file states, and judges every sidecar at its bounds: a PASS with every expected technique
  at `min_count`, a FAIL past `min_count + tolerance`;
- with PowerShell (`pwsh`) installed, `run-scenarios.ps1` reads every sidecar exactly as
  `run-scenarios.sh` does, `runner/windows/validate-admin.ps1` resolves its scenarios
  sibling and its phase functions record, against fakes of the ETW host and the agent, the
  results and calls `tests/validate-admin-phases.ps1` states, and `runner/LabAgent.ps1`
  (the agent lifecycle both PowerShell runners share) writes, from `runner/lab-agent.toml.template`, the lab `agent.toml` of `tests/lab-agent/`
  byte for byte, and starts, waits for and stops an agent
  by pid; and the scripts that dot-source `powershell/RigCommon.ps1` (the admin check
  `Assert-RigAdministrator` and the summary writer `Write-RigSummary`) parse, find it and keep no
  copy of their own, and no RigCommon name is also defined by the scenarios' `common.ps1`
  (`tests/rig-common.ps1`); and `vagrant/hyperv/helpers.ps1` names its commands Verb-Noun,
  keeps the short names (`vup`, `vssh`, ...) as their aliases, and runs, through them, the
  `rig.py` or `vagrant` command lines `tests/hyperv-helpers.ps1` states.

A check that cannot run because a tool is missing prints `skipped:` and the reason. A
change that touches the runners or provisioning is best also run on at least one VM with
`python3 rig.py run <machine>`.
`python3 rig.py build|run <machine> ... --dry-run` prints the command the rig would send
to the guest without syncing or running anything.

`.gitattributes` fixes line endings: LF for shell scripts and the catalogs, which run inside
Linux guests, LF for the `tests/judge/` fixtures, which the bash runner reads on Windows too,
and CRLF for PowerShell scripts, the lab `agent.toml` template and the `tests/lab-agent/`
configs. Keep new files within those patterns.

## Exit codes

Every rig tool exits with the same three codes, so `rig.py`, CI and a shell loop over the
tools can tell a failure from a run that never started:

| Code | Meaning | Examples |
| --- | --- | --- |
| 0 | OK | every scenario passed, every check passed, the agent is built |
| 1 | The task ran and something failed | a scenario FAILed or ERRORed, `rig.py check` or `run-scenarios.sh --check` found a problem, the build failed or has no eBPF probes |
| 2 | The task could not run: a usage error or an unmet environment | an unknown option, command or machine, an option without its value, no vagrant or bash, sources not synced, no build in the guest, no passwordless sudo |

In Python, raise `RigError` (`tools/riglib.py`) for a usage or environment problem and
`CheckFailed` for a finding; `run_cli` prints the message and exits 2 or 1. A command that
fails exits with its own code, and `rig.py run` with the runner's. In bash, source
`runner/lib/common.sh` and stop with `die_env` or `die_usage` (2) or `die` (1); check an
option's values with `need_values`. Say a script's exit status in its header comment.

## Adding a scenario

Scenarios live in [synthaea-lab/scenarios](https://github.com/synthaea-lab/scenarios): one
`<name>.sh` or `<name>.ps1` script and a `<name>.yaml` sidecar with its
`expected_detections`. The rig reads sidecars as they are and never edits them.

1. Add the script and the sidecar in the scenarios repository.
2. Add a row to `runner/scenarios.conf` (Windows: `runner/scenarios-windows.conf`). The
   header of each file documents the columns: `default` for a safe, self-contained
   scenario, `opt-in` with a note for one that needs setup the runner does not do, and the
   root, required commands or LSMs, oldest kernel, extra agent flags, environment, extra
   YARA files and settle time.
3. Run `python3 rig.py check`. A sidecar shape the runners must handle gets a fixture in
   `tests/sidecars/`; a verdict rule, a case in `tests/judge/` (an `alerts.ndjson` snapshot
   and the `verdict` it must get).
4. Run `python3 rig.py run <machine> <name>` to see it on a VM; the report says PASS or why
   not.

## Adding a machine

1. Add the target to [docs/machine-matrix.md](docs/machine-matrix.md), with what it proves.
2. Add the entry to `machines.json`: a box per provider that publishes one, `provision` if
   the guest is not apt- or dnf-based, and a `prep` script in `provisioning/` if the box
   needs a fix-up. A prep script detects on its own whether it applies. `python3 rig.py check`
   validates the entry.

Nothing else lists machines: `rig.py` and the Vagrantfile both read the catalog.

## Recording a result

Reports in `reports/` are ignored by git. When a run is evidence, such as a target validated
or a regression shown, commit it with `git add -f reports/<file>` and cite it from
`docs/machine-matrix.md`. A report contains what the guest saw (hostname, paths, process IDs,
commits): review it before committing.

## Pull requests

Keep a pull request to one change, describe what you ran (`rig.py check`, and the machines
you ran on), and sign off every commit with `git commit -s`.
