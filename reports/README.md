# reports

Scenario run reports, `<date>-<machine>.md`. The runner (`../runner/run-scenarios.sh`, or
`run-scenarios.ps1` on Windows guests) writes them in the guest, `python3 rig.py run
<machine>` copies them here, and `python3 rig.py report [machine]` prints the newest.

Reports are ignored by git. What a report contains and what each result means is described
in [`../README.md`](../README.md#reports); how to commit one as evidence is in
[`../CONTRIBUTING.md`](../CONTRIBUTING.md#recording-a-result).
