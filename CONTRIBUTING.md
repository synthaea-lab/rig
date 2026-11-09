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
  pins the command lines `rig.py` sends to a guest);
- every shell script parses, and is shellcheck-clean when `shellcheck` is installed;
- `machines.json` parses;
- the runner catalogs (`runner/scenarios.conf`, `runner/scenarios-windows.conf`) have a row
  for every scenario, and every sidecar is readable;
- `run-scenarios.sh` judges the alert snapshots in `tests/judge/` as each case's `verdict`
  file states, and judges every sidecar at its bounds: a PASS with every expected technique
  at `min_count`, a FAIL past `min_count + tolerance`;
- with PowerShell (`pwsh`) installed, `run-scenarios.ps1` reads every sidecar exactly as
  `run-scenarios.sh` does, `runner/windows/validate-admin.ps1` resolves its scenarios
  sibling, and `runner/LabAgent.ps1` (the agent lifecycle both PowerShell runners share)
  writes, from `runner/lab-agent.toml.template`, the lab `agent.toml` of `tests/lab-agent/`
  byte for byte, and starts, waits for and stops an agent
  by pid.

A check that cannot run because a tool is missing prints `skipped:` and the reason. A
change that touches the runners or provisioning is best also run on at least one VM with
`python3 rig.py run <machine>`.
`python3 rig.py build|run <machine> ... --dry-run` prints the command the rig would send
to the guest without syncing or running anything.

`.gitattributes` fixes line endings: LF for shell scripts and the catalogs, which run inside
Linux guests, LF for the `tests/judge/` fixtures, which the bash runner reads on Windows too,
and CRLF for PowerShell scripts, the lab `agent.toml` template and the `tests/lab-agent/`
configs. Keep new files within those patterns.

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
   needs a fix-up. A prep script detects on its own whether it applies.

Nothing else lists machines: `rig.py` and the Vagrantfile both read the catalog.

## Recording a result

Reports in `reports/` are ignored by git. When a run is evidence, such as a target validated
or a regression shown, commit it with `git add -f reports/<file>` and cite it from
`docs/machine-matrix.md`. A report contains what the guest saw (hostname, paths, process IDs,
commits): review it before committing.

## Pull requests

Keep a pull request to one change, describe what you ran (`rig.py check`, and the machines
you ran on), and sign off every commit with `git commit -s`.
