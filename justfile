# The rig's tasks, run from this directory; each is a shorthand for `python rig.py <task>`.

python := if os_family() == "windows" { "python" } else { "python3" }

# List the recipes.
default:
    @just --list --unsorted

# The machine catalog, with the box each machine uses on this host.
list:
    @{{python}} rig.py list

# Boot a VM (provisions it on first boot).
up machine:
    {{python}} rig.py up {{machine}}

# Sync the sources into a VM and build the agent there (--offline, --ort static|prebuilt, --ort-compat).
build machine *flags:
    {{python}} rig.py build {{machine}} {{flags}}

# Run scenarios in a VM (default: every safe one) and copy the report to reports/.
run machine *scenarios:
    {{python}} rig.py run {{machine}} {{scenarios}}

# Print the newest report (of one machine, if given).
report machine="":
    @{{python}} rig.py report {{machine}}

# Halt a VM (--destroy deletes it).
down machine *flags:
    {{python}} rig.py down {{machine}} {{flags}}

# Lint the scripts and check the scenario catalog (no VM needed).
check:
    {{python}} rig.py check
