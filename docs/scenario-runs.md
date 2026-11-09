# Scenario runs

`python3 rig.py run <machine> [scenario ...]` runs scenarios from the
[scenarios](https://github.com/synthaea-lab/scenarios) checkout against a fresh agent, judges
the alerts against each scenario's expectations, and writes a report. The work happens in the
guest, in [`runner/run-scenarios.sh`](../runner/run-scenarios.sh) on Linux and
[`runner/run-scenarios.ps1`](../runner/run-scenarios.ps1) on Windows. This page describes the
Linux runner, which is the reference; [windows.md](windows.md#the-windows-runner) lists where
the Windows one differs.

## Two sources of truth

What a scenario must trigger and how to run it on a lab VM are kept apart on purpose:

- **The sidecar** (`<name>.yaml` in the scenarios repository) says what must fire:
  its `expected_detections`. The rig reads sidecars as they are and never edits them. They
  are shared with other consumers, and the scenarios repository pins their bytes with a
  checksum file, so a lab-specific tweak would break more than the lab.
- **The runner catalog** ([`runner/scenarios.conf`](../runner/scenarios.conf)) says how to
  run each scenario here: as root or not, what it needs, which agent flags, how long to let
  alerts settle.

## The runner catalog

One row per scenario, `|`-separated, `-` for an empty cell. The header of
[`scenarios.conf`](../runner/scenarios.conf) documents the columns; this is the same
information with the rules the runner applies.

| Column | Values | Effect |
| --- | --- | --- |
| `name` | scenario stem | The runner runs `<scenarios>/scenarios/<name>.sh` and judges against `<name>.yaml` |
| `set` | `default` or `opt-in` | `default`: safe and self-contained, part of a plain `rig.py run`. `opt-in`: needs setup the runner does not do (the note says what); runs only when named |
| `root` | `yes` or `no` | `yes` runs the script under `sudo` |
| `needs` | space-separated | Each word is a command that must exist, `a/b` for "a or b", or `lsm:<name>` for an LSM that must be active in `/sys/kernel/security/lsm`. A missing need makes the scenario SKIP with the reason |
| `min_kernel` | version | The oldest kernel the detection can work on; an older one makes it SKIP |
| `agent_flags` | words | Extra `agent run` flags, word-split (for example `--enable-dns-capture`) |
| `env` | `KEY=VALUE ...` | Extra environment for the script |
| `yara` | file names | YARA files from the scenarios directory, added to this run's content |
| `settle` | seconds | Wait after the script before reading alerts; default 3 |
| `note` | text | Why a scenario is opt-in, or what to know. It may contain `\|`; it is shown in the report |

A row such as:

```text
dns-exfil                | default | no   | python3        | -          | --enable-dns-capture | -              | -                  | 3      | glibc only (getaddrinfo uprobe)
```

runs `dns-exfil.sh` as the `vagrant` user, skips it where `python3` is missing, starts the
agent with `--enable-dns-capture`, and waits at least 3 s before judging.

Cells are trimmed of spaces and tabs; blank lines and lines starting with `#` (after leading
whitespace) are skipped; a short row leaves the missing cells empty.
[`load_catalog`](../runner/run-scenarios.sh) reads the file once into an associative array and
`catalog_get NAME COLUMN` is the only accessor, so the column order is written in one place
(`CATALOG_COLUMNS`). `--catalog-rows FILE` prints each row as the runner read it, which is how
[`tests/catalog/scenarios.conf`](../tests/catalog/scenarios.conf) pins the parsing
([testing.md](testing.md)).

### Catalog checks

Before any run, and with `--check`, [`check`](../runner/run-scenarios.sh) requires that:

- every row has a `.sh` script and a `.yaml` sidecar with at least one readable
  expectation;
- every `set` is `default` or `opt-in`;
- every `yara` file exists in the scenarios directory;
- every `.sh` script in the scenarios directory has a row, so a new scenario cannot be
  forgotten silently.

## Expectations

The sidecar format is defined in the
[scenarios catalog](https://github.com/synthaea-lab/scenarios/blob/main/scenarios/README.md#sidecar-format).
The runner reads only `expected_detections`:

```yaml
expected_detections:
  - technique: "T1071/T1041"
    min_count: 1
    tolerance: 0
```

| Key | Default | Meaning |
| --- | --- | --- |
| `technique` | | The alert's `technique` field to count. Quoted with `"` or `'`, or bare |
| `min_count` | 1 | Fewest alerts of that technique that must fire |
| `tolerance` | 0 | How many more than `min_count` may fire |

[`expectations`](../runner/run-scenarios.sh) is a small awk parser rather than a YAML
library, because Linux guests have no YAML parser guaranteed and the Windows runner must read
the same files with PowerShell 5.1. It handles exactly the documented shape: the block starts
at `expected_detections:`, ends at the next top-level key, ignores `#` comments, and starts a
new expectation at each `technique:`. `--expectations FILE` prints one
`technique|min_count|tolerance` line per expectation:

```console
$ bash runner/run-scenarios.sh --expectations tests/sidecars/defaults-and-quotes.yaml
T1059|2|1
T1071/T1041|1|0
T1486|3|0
RESPONSE-KILL|1|20
```

Where `pwsh` is installed, `rig.py check` holds both runners to the same reading of every
sidecar ([testing.md](testing.md#rigpy-check)).

## One scenario

The runner starts one agent per scenario, so no state, belief score or late alert leaks from
one scenario into the next. [`run_one`](../runner/run-scenarios.sh):

1. **Skip check.** The first unmet `needs` entry, or a kernel older than `min_kernel`,
   records SKIP with the reason and moves on.
2. **Content.** Copies `rules/sigma` and `rules/yara` from the rules checkout into
   `runs/<stamp>/<name>/content/rules/`, plus the row's `yara` files, so a scenario's
   private YARA rule never reaches another scenario's agent.
3. **Agent.** Starts, under `sudo` with `RUST_LOG=info`:

   ```bash
   agent run --standalone --content-dir <run>/<name>/content \
     --alerts <run>/<name>/alerts.ndjson --events <run>/<name>/events.jsonl [agent_flags]
   ```

   `--standalone` keeps the agent off any control plane. The agent creates the alert and event
   files itself: a root process cannot open a file another user pre-created in a sticky
   directory under `fs.protected_regular`.
4. **Readiness.** Waits up to 90 s for `sensor-linux: listening` in `agent.log`. If the agent
   exits or the line never comes, the scenario is an ERROR ("agent did not start"). Then waits
   one more second.
5. **Script.** Runs `bash <name>.sh` in the scenario's run directory, under `sudo` when `root`
   is `yes`, with a 300 s timeout, and with `EVENTS`, `ALERTS` and `AGENT_PID` set (plus the
   row's `env`), so a self-checking scenario can read the agent's files or signal it. Output
   goes to `scenario.log`.
6. **Settle.** Sleeps the row's `settle` seconds, then polls the alert file once a second
   until its size has not changed for 2 s, for at most 20 s. Correlated detections (beaconing,
   respawn, Bayesian belief) arrive after the activity that caused them.
7. **Snapshot**, before stopping the agent: stopping it sends a signal to a security
   process, which is itself a detection (`T1562.001`) and would pollute every scenario.
8. **Stop.** `SIGINT` through `sudo`, up to 15 s to exit, then `SIGKILL`. The agent runs as
   root under `sudo`, so the runner reads liveness from `/proc/<pid>` and signals through
   `sudo`.
9. **Judge** the snapshot (below) and write the verdict to `<run>/<name>/verdict`. When the
   script exited non-zero, the first five lines of `scenario.log` that contain `FAIL` or
   `ERROR` are added to the detail, since a self-checking scenario says there why it failed.

Before the first scenario the runner also checks the guest (a `build-info`, an executable
agent, `/etc/synthaea/agent.toml`, the rules checkout, passwordless `sudo`; each missing one
exits 2), creates `/run/synthaea` for the agent's local control socket, and saves
`agent status` to `runs/<stamp>/status.txt` for the report's verifier summary.

## Judging

[`judge SNAPSHOT SIDECAR RC`](../runner/run-scenarios.sh) reads only the alert snapshot and
the sidecar, so it can be tested without a VM. It counts alerts per `technique` value in the
NDJSON snapshot (a missing snapshot counts as no alert), then:

1. For each expectation, the count must be between `min_count` and `min_count + tolerance`.
   Any miss makes the result **FAIL**, with the reason (`T1059.004 fired 6×, allows ≤3`).
2. Otherwise, a non-zero script exit makes it **ERROR** (`script exited 1`).
3. Otherwise, any technique that fired and is not expected makes it **UNEXPECTED**.
4. Otherwise **PASS**.

A FAIL with a non-zero script exit also notes the exit code. `fired` lists the expected
techniques in sidecar order, with a count of 0 for one that never fired; `unexpected` and
`follow_ups` are sorted by technique.

**Follow-ups.** The agent adds a `RESPONSE-ESCALATE` record on top of detections when it
escalates a process. It accompanies most scenarios and is not a detection in its own right,
so it is listed apart as a follow-up and never judged, unless a sidecar expects it, in which
case it is counted like any other technique. The follow-up list is `FOLLOW_UPS` in the
runner.

`--judge` prints five `key=value` lines, the same format as the `verdict` file:

```text
status=UNEXPECTED
fired=T1059 ×2, T1071/T1041 ×1, T1486 ×3, RESPONSE-KILL ×1
unexpected=BAYES ×1, T9999 ×2
follow_ups=RESPONSE-ESCALATE ×4
detail=
```

## Runner options

```text
bash /synthaea/rig/runner/run-scenarios.sh [options] [scenario ...]
```

| Option | Effect |
| --- | --- |
| (no names) | Every `default` scenario of the catalog |
| `<name> ...` | Just these, opt-in ones included; an unknown name exits 2 |
| `--list` | Print each scenario with its set and expectations, run nothing |
| `--check` | Validate the catalog against the scenarios directory, run nothing |
| `--expectations FILE` | Print the expectations of a sidecar, run nothing |
| `--catalog-rows FILE` | Print each row of a runner catalog as read, run nothing |
| `--judge SNAPSHOT SIDECAR RC` | Print the verdict on an alert snapshot, run nothing |
| `--machine NAME` | The machine name in the report (default: the hostname without `synthaea-`) |
| `--scenarios DIR` | The scenarios directory (default: `$SYNTHAEA_ROOT/scenarios/scenarios`) |

The read-only modes work on any host with bash, which is how `rig.py check` uses them. The
environment is that of the build script: `SYNTHAEA_ROOT`, `RIG_STATE`, `SYNTHAEA_SOURCE`.

## Run directory

Everything a run produced stays in the guest under `~/synthaea-rig/runs/<UTC stamp>/`:

```text
runs/20261108T183855Z/
├── status.txt                  agent status at the start of the run
└── <scenario>/
    ├── content/rules/          the Sigma and YARA content this agent loaded
    ├── agent.log               the agent's output
    ├── alerts.ndjson           alerts, as the agent wrote them (including after the stop)
    ├── alerts.snapshot.ndjson  alerts at the snapshot, what was judged
    ├── events.jsonl            every normalized event
    ├── scenario.log            the script's output
    └── verdict                 the judge's five lines
```

The report is written to `~/synthaea-rig/reports/<date>-<machine>.md` and its path printed as
`REPORT: <path>`, which `rig.py` uses to fetch it ([reports.md](reports.md)).

## Adding a scenario

1. Add the script and its sidecar to the scenarios repository
   ([its contributing guide](https://github.com/synthaea-lab/scenarios/blob/main/CONTRIBUTING.md)).
2. Add a row to `runner/scenarios.conf` (Windows: `runner/scenarios-windows.conf`). Choose
   `default` only if the scenario is safe on a disposable VM and needs nothing the runner
   does not set up.
3. Run `python3 rig.py check`. If the sidecar uses a shape the runners must learn, add a
   fixture to `tests/sidecars/`; if it needs a new verdict rule, add a case to `tests/judge/`
   ([testing.md](testing.md#fixtures)).
4. Run it on a VM: `python3 rig.py run <machine> <name>`. The report says PASS, or why not.
