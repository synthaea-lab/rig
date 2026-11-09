# Reports

Each run writes one Markdown report in the guest, and `rig.py run` copies it to
[`reports/`](../reports/) on the host as `<date>-<machine>.md` (the UTC date of the run). A
later run of the same machine on the same day replaces it. `python3 rig.py report [machine]`
prints the newest. [`reports/2026-11-08-debian12.md`](../reports/2026-11-08-debian12.md) is a
complete example.

## Layout

The Linux runner writes the report at the end of
[`run-scenarios.sh`](../runner/run-scenarios.sh), in this order.

### Header table

| Row | Content | Source |
| --- | --- | --- |
| Machine | The machine name, the guest's hostname, `PRETTY_NAME` from `/etc/os-release` | The guest |
| Kernel | `uname -r` and `uname -m`, the active LSMs from `/sys/kernel/security/lsm`, the glibc version (or `musl`) | The guest |
| Agent build | The binary, profile, ONNX Runtime mode, `offline=`, build time and duration, `rustc` version | `build-info` |
| Sources at build | The commit of each checkout when the agent was built | `build-info` |
| Sources at run | The commit of each checkout when the scenarios ran | `SYNTHAEA_SOURCE` |
| eBPF verifier | How many programs `agent status` accepted, how many status checks were not OK | `runs/<stamp>/status.txt` |
| Run | Start time (UTC), scenario count and duration | The runner |

Read the two Sources rows together: when they differ, the scenarios or rules changed after
the agent was built, which is fine for content changes but means the binary may not match the
current agent code. A `+dirty` mark means uncommitted changes were synced.

When `ort-compat` pinned a newer release for the C and C++ runtime, the Machine row says so:
`/etc/os-release` then names the newer release while the kernel is still the matrix row's
([provisioning.md](provisioning.md#onnx-runtime)).

### Summary and table

A bold tally line (`PASS 7 · UNEXPECTED 5 · FAIL 2 · SKIP 1`), then one row per scenario:

| Column | Content |
| --- | --- |
| Scenario | The name |
| Result | PASS, UNEXPECTED, FAIL, ERROR or SKIP |
| Expected (sidecar) | Each expectation as `technique ×min_count`, with `(+tolerance)` when non-zero |
| Fired | How many times each expected technique fired |
| Unexpected | Every other technique that fired, with its count (follow-ups excluded) |
| Time | Seconds from agent start to agent stop |

### Details

Per scenario: why it is not PASS, the follow-up alerts (not judged), the catalog note, and
the alert snapshot as `technique  message` lines, each clipped to 220 characters.

### eBPF verifier and agent warnings

The `agent status` lines that are not program acceptances, the number of accepted programs,
and the checks that were not OK. Then the distinct `WARN` and `ERROR` lines the agents logged
across the run, with timestamps stripped and PIDs replaced by `N`, counted and sorted, top 20.
A warning that appears in every scenario (a hook the kernel cannot attach, a model file
missing) explains a SKIP or a gap without opening the guest.

The last line names the run directory in the guest, where the raw material stays.

## Results

| Result | Meaning | Exit code |
| --- | --- | --- |
| PASS | Every expected technique fired between `min_count` and `min_count + tolerance` times, and nothing else fired | 0 |
| UNEXPECTED | The expectations are met, but other techniques fired too: a false positive, or an expectation to update | 0 |
| FAIL | An expected technique fired too few or too many times | 1 |
| ERROR | The agent did not start, or the scenario script exited non-zero with the expectations met | 1 |
| SKIP | The guest lacks something the scenario needs (a command, an LSM, a kernel version); the reason is shown | 0 |

The rules behind each result are in [scenario-runs.md](scenario-runs.md#judging).

UNEXPECTED does not fail the run, on purpose: correlated detections legitimately add alerts
on top of a scenario's expected ones (a beacon also opens a listener on a new port), and the
operator's own session is visible to the agent. It is the result to review: either the agent
has a false positive to fix, or the sidecar should expect the extra technique.

## Recording a result

Reports are ignored by git (`/reports/*` in [`.gitignore`](../.gitignore), except the
directory's README). When a run is evidence, such as a target validated or a regression
shown:

1. Review the report. It contains what the guest saw: hostname, paths, process IDs, user
   names in alert messages, commits.
2. Commit it with `git add -f reports/<file>`.
3. Cite it from [machine-matrix.md](machine-matrix.md#validation-status).
