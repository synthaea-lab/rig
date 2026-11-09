# Testing the rig

The rig tests an agent, but it is code too, and a wrong verdict is worse than no verdict: a
runner that misreads a sidecar turns a regression into a PASS. Everything that can be checked
without a VM is checked by one command, and the parts that need a VM are kept small and
idempotent so that a VM run is a confirmation rather than the only test.

## `rig.py check`

```bash
python3 rig.py check     # python rig.py check on Windows, or: just check
```

It needs bash (on Windows, Git for Windows' bash) and the
[scenarios](https://github.com/synthaea-lab/scenarios) checkout in the root. `shellcheck`
and PowerShell 7 (`pwsh`) are optional: a check whose tool is missing prints `skipped:` and
the reason instead of failing, so read the output, not only the exit code. The checks run in
this order ([`run_checks`](../rig.py)), and the first failure stops the run with exit 1:

| Check | What it proves |
| --- | --- |
| Unit tests | `python -m unittest discover` over `tests/test_*.py` passes (below) |
| Shell syntax | `bash -n` on every `*.sh` at the top level, one directory down, and in `runner/lib/` |
| Catalog | `machines.json` is valid ([machines.md](machines.md#validation)) |
| shellcheck | Every one of those scripts is clean at shellcheck's default severity. An intended finding carries a `# shellcheck disable=...` with the reason |
| Runner catalog | `run-scenarios.sh --check` against the scenarios checkout: every scenario has a row and every row a script and a readable sidecar ([scenario-runs.md](scenario-runs.md#catalog-checks)) |
| Catalog parsing | `run-scenarios.sh --catalog-rows` reads [`tests/catalog/scenarios.conf`](../tests/catalog/scenarios.conf) as its `# reads:` lines state |
| Sidecar parsing | `run-scenarios.sh --expectations` reads each fixture in [`tests/sidecars/`](../tests/sidecars/) as stated; with `pwsh`, `run-scenarios.ps1`'s parser reads every fixture and every real sidecar exactly as the bash one does |
| Verdicts | `run-scenarios.sh --judge` gives each case in [`tests/judge/`](../tests/judge/) its stated verdict |
| Sidecar bounds | Every real sidecar PASSes with each expected technique at exactly `min_count`, and FAILs at `min_count + tolerance + 1` |
| Admin validation (`pwsh`) | [`validate-admin.ps1`](../runner/windows/validate-admin.ps1) finds the scenarios' `common.ps1`, and its phase functions record the stated results and calls against fakes of the ETW host and the agent |
| Lab agent (`pwsh`) | [`LabAgent.ps1`](../runner/LabAgent.ps1) writes the configurations of [`tests/lab-agent/`](../tests/lab-agent/) byte for byte, and starts, waits for and stops a fake agent by PID |
| RigCommon (`pwsh`) | The scripts that dot-source [`RigCommon.ps1`](../powershell/RigCommon.ps1) parse and find it, keep no copy of their own, and no RigCommon name collides with the scenarios' `common.ps1` |
| Windows runner (`pwsh`) | `run-scenarios.ps1` sets strict mode, its functions count, format and run a scenario as stated, and scenario names bind to `-Names` only, never to `-Root` or `-State` by position |
| Hyper-V helpers (`pwsh`) | [`helpers.ps1`](../vagrant/hyperv/helpers.ps1) names its commands Verb-Noun, keeps each short name as an alias, and runs the stated `rig.py` or `vagrant` command line |

The sidecar-parsing parity check exists because the two runners cannot share code: Linux
guests have no PowerShell, Windows guests have no bash. The fixtures and the real sidecars are
the contract between them.

Run it locally before opening a pull request: it is the gate.
[`.github/workflows/ci.yml`](../.github/workflows/ci.yml) defines the same command as a job on
Ubuntu and Windows, with the scenarios repository checked out beside the rig, so that where
GitHub Actions is enabled both runners' halves are checked where they really run.

## Unit tests

Standard-library `unittest`, no dependency. Each suite fakes what it drives instead of
needing it:

| Suite | Covers |
| --- | --- |
| [`test_rig.py`](../tests/test_rig.py) | The exact command lines `rig.py` sends to Linux and Windows guests, and the quoting of every kind of argument |
| [`test_vagrant.py`](../tests/test_vagrant.py) | How `rig.py` runs vagrant, against a fake `vagrant` first on `PATH` that logs each call's arguments, directory and provider and replays canned output and exit codes |
| [`test_catalog.py`](../tests/test_catalog.py) | Every catalog validation message, and that the real catalog loads |
| [`test_offline_bundle.py`](../tests/test_offline_bundle.py) | How the bundle is pushed (with the fake vagrant), and that its key matches the one `agent-build.sh` computes in bash |
| [`test_agent_build.py`](../tests/test_agent_build.py) | What `agent-build.sh` runs, refuses and records in `build-info`, against a fake guest (fake `cargo`, `rustup`, `rustc`, `bpf-linker` and `sudo`). Linux only |
| [`test_riglib.py`](../tests/test_riglib.py) | The shared exit-code wrapper |
| [`test_exit_codes.py`](../tests/test_exit_codes.py) | That `rig.py` and the bash scripts exit 0, 1 or 2 as the [convention](architecture.md#exit-codes) says |

Run one suite from the rig checkout:

```bash
python3 -B -m unittest tests.test_rig
python3 -B -m unittest discover -s tests -p test_catalog.py
```

`-B` keeps `__pycache__` out of the tree.

## Fixtures

Fixtures state their expected result inside themselves, in comment lines, so a fixture and
its expectation cannot drift apart.

**Sidecar fixtures** (`tests/sidecars/*.yaml`) are sidecars in the documented shape, each
exercising one parsing case (quoting styles, defaults, comments, a block that ends at the next
key, no block at all). Each `# reads: technique|min_count|tolerance` line is one expectation
both runners must read, in order:

```yaml
# reads: T1059|2|1
# reads: T1071/T1041|1|0
expected_detections:
  - technique: "T1059"
    min_count: 2
    tolerance: 1
  - technique: 'T1071/T1041'
```

**Catalog fixture** (`tests/catalog/scenarios.conf`) has rows in the runner catalog's shape
(tabs, a `|` inside the note, a short row) and one `# reads:` line per row, as
`--catalog-rows` must print it.

**Verdict cases** (`tests/judge/<case>/`) each hold:

- `alerts.ndjson`: an alert snapshot in the agent's shape (only `technique` is read), or no
  file for "no alert at all";
- `verdict`: free comment lines describing the case, `# sidecar: <fixture in tests/sidecars>`,
  `# rc: <script exit code>`, then the five lines `--judge` must print, exactly.

```text
# a count over min_count + tolerance fails
# sidecar: defaults-and-quotes.yaml
# rc: 0
status=FAIL
fired=T1059 ×4, T1071/T1041 ×1, T1486 ×3, RESPONSE-KILL ×1
unexpected=
follow_ups=
detail=T1059 fired 4×, allows ≤3
```

To add a verdict rule, add a case whose `verdict` states the new behaviour, see it fail, then
change [`judge`](../runner/run-scenarios.sh). The PowerShell runner judges with the same rules
and should change in the same pull request.

## Testing a change

- **Host side** (`rig.py`, `riglib`, the catalog): unit tests, then `--dry-run` to see the
  exact command a step would send:

  ```bash
  python3 rig.py run debian12 beacon --dry-run
  ```

- **Runner logic**: `--judge`, `--expectations` and `--catalog-rows` run on the host.
- **Guest scripts**: on at least one VM, `python3 rig.py build <machine>` and
  `python3 rig.py run <machine>`, and say in the pull request which machines you ran.
- **Line endings**: [`.gitattributes`](../.gitattributes) keeps shell scripts, catalogs, JSON
  and judge fixtures LF (they run in Linux guests, and the bash runner reads the fixtures on
  Windows too) and PowerShell scripts, the lab `agent.toml` template and its goldens CRLF. A
  stray `\r` in a shell script breaks every command in the guest; keep new files within those
  patterns.
