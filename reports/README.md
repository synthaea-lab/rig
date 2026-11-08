# reports

Scenario run reports, `<date>-<machine>.md`, written by `../runner/run-scenarios.sh` (or
`.ps1`) in the guest and copied here by `python rig.py run <machine>`. `python rig.py report
[machine]` prints the newest.

Gitignored: commit one only when it is evidence (a MATRIX row validated, a regression
shown) with `git add -f reports/<file>`, and cite it from `../MATRIX.md`. What a report
contains and what PASS/UNEXPECTED/FAIL/ERROR/SKIP mean: `../README.md`, "Reports".
