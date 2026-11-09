# Limits and known gaps

What the rig does not do, or does only partly. Each item says what it means for a result.

## Coverage

- **Validation evidence is thin.** Only the Debian 12 row has a committed report. Other rows
  were validated before the current runner existed, or not at all
  ([machine-matrix.md](machine-matrix.md#validation-status)). Re-run and commit a report before
  quoting a result for them.
- **The Windows runner has not run end to end on a lab VM.** Its parsing, judging, agent
  lifecycle and parameter binding are tested against fakes, but no Windows report exists yet.
- **Windows scenarios have no sidecars.** Their expectations live in the runner's
  `expect` column, copied from each script's header, so they can drift from the script.
- **No macOS guest.** No Vagrant box exists for macOS; the EndpointSecurity sensors are tested
  on real hardware, outside the rig.
- **Rocky Linux 9 is replay-only.** It has no LLVM recent enough to build the probes, so an
  agent built elsewhere has to be copied in; the rig has no command for that.
- **The Alpine row runs an older Alpine.** `generic/alpine319` (3.19, kernel 6.6) stands in
  for the 3.24 row; it covers musl and BusyBox, not the 6.18 kernel.
- **`--ort-compat` changes the C library under test.** A Debian 12 or Ubuntu 22.04 result
  built that way runs the next release's glibc and libstdc++ on the row's kernel. The report
  says so; `--ort static` avoids it at the cost of a much longer build.
- **Opt-in scenarios need manual setup.** Web, database, canary and control-plane scenarios
  need services or configuration the runner does not install; their catalog notes say what.

## Runner behaviour

- **Expectations are counted by technique only.** The judge counts alerts whose `technique`
  field matches. It does not check which rule fired, the process, or the message. Two
  different rules raising the same technique are indistinguishable.
- **The sidecar parser handles the documented shape only.** It is a line-based reader, not a
  YAML parser: flow sequences, anchors or multi-line technique values are not understood.
  `rig.py check` catches a sidecar with no readable expectation, not one that is read wrong
  in a way the fixtures do not cover.
- **Timing is heuristic.** Readiness is a log line (Linux) or the first event (Windows);
  settling is a fixed delay plus 2 s of a quiet alert file, capped at 20 s. A detection slower
  than that is missed and reported as FAIL.
- **Scenario scripts get 300 s** (Linux) before they are killed; the Windows runner sets no
  limit.
- **The Windows runner never SKIPs.** Its catalog has no `needs` or `min_kernel` columns, and
  it has no `agent_flags`, `env`, `yara` or `settle` either.
- **One run at a time per VM.** The Linux runner does not guard against a second run in the
  same guest, and two agents running at once would see each other's scenarios. The Windows
  runner refuses to start while an `agent.exe` runs.

## Sync and build

- **Windows sync does not delete.** The zip is expanded over `C:\synthaea` with `-Force`,
  which overwrites files but leaves ones deleted on the host. A renamed or deleted scenario
  stays in the guest until the VM is rebuilt.
- **Windows builds ignore `--offline` and `--ort`.** `rig.py` drops them for Windows guests
  without a warning.
- **The source description is only as good as git.** `+dirty` ignores untracked files, and a
  checkout that is not a git repository is left out of the description.
- **Offline is not fully offline.** Provisioning, `--ort-compat` and `--ort static` all need
  the network ([offline-builds.md](offline-builds.md#limits)).
- **`rig.py check` lints shell scripts at most one directory deep** (plus `runner/lib/`). A
  script added deeper is neither syntax-checked nor shellchecked.

## Hosts

- **Hyper-V needs elevation** for every command that touches a VM, and its community boxes
  for the 6.8, 6.12 and Fedora targets need one-time manual fix-ups.
- **QEMU has no snapshots.** To roll back, destroy the VM and `up` again.
- **Resources.** Each Linux VM takes about 20 GB of disk once built and 6 GB of RAM by
  default; on a 16 GB host, run one VM at a time.
