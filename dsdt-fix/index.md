# Available DSDT patches

Patches installable with `dsdt-fix.sh` live in `dsdt-fix/<board>/<bios>/` — one
`--target` per row. `dsdt-fix.sh` prints these lists when the patch you asked
for is not published here.

## Installable with dsdt-fix.sh

| --target |
|----------|
| 8C4D/F.29 |

## Upstream patches (download & install manually)

These fix the same problem on **sibling units / other BIOS versions of the
OMEN Transcend 16** and are maintained by their authors, **not** copied into
this repo — so `dsdt-fix.sh` does **not** serve or install them. If one matches
your machine, download the `.aml`/`.dsl` from the linked repo and install it
yourself (`dsdt-fix.sh /path/to/dsdt.aml`, or follow the upstream guide).
[j0hnwang/OMEN-Transcend-16-ACPI-fix] and
[no-hands-hand/OMEN-Transcend-16-ACPI-fix-f27] are GPL-3.0.

| --target        | upstream repo |
|-----------------|---------------|
| 8BB3/F.11 Rev.A | https://github.com/j0hnwang/OMEN-Transcend-16-ACPI-fix |
| 8BB3/F.12       | https://github.com/j0hnwang/OMEN-Transcend-16-ACPI-fix |
| 8C4D/F.25       | https://github.com/LauriSarap/omen-transcend-16-linux-fix |
| 8C4D/F.27       | https://github.com/no-hands-hand/OMEN-Transcend-16-ACPI-fix-f27 |
| 8C4D/F.28       | https://github.com/j0hnwang/OMEN-Transcend-16-ACPI-fix |

The `--target` prefix here is the **OEM Table ID written in each patch's DSDT
header**, not the machine's DMI name: F.11 Rev.A / F.12 are the older `8BB3`
generation; F.25 / F.27 / F.28 are the `8C4D` generation — the same ACPI
family as this repo's `8C4D/F.29`. (LauriSarap's repo does not state a
machine; its F.25 label comes from that DSDT's header.)
