# Available DSDT patches

Each published patch lives in `dsdt-fix/<board>/<bios>/` (e.g. `dsdt-fix/8C4D/F.29/`),
so one patch = one `--target` value. Add a row below for every new patch folder;
`dsdt-fix.sh` lists these when the requested patch is not published, and you pass
the first column straight back as `--target`.

| --target |
|----------|
| 8C4D/F.29 |

## Related upstream patches (not distributed here)

Patches for **other OMEN Transcend 16 units / BIOS versions** stay in the
authors' own GPL-3.0 repositories and are **not** copied into this repo, so
`dsdt-fix.sh` cannot install them. If one matches your machine, fetch the
`.aml`/`.dsl` directly from the upstream repo:

- **j0hnwang/OMEN-Transcend-16-ACPI-fix** — F.11 / F.12 / F.27 / F.28 for the
  16-u0017TX — https://github.com/j0hnwang/OMEN-Transcend-16-ACPI-fix
- **no-hands-hand/OMEN-Transcend-16-ACPI-fix-f27** — full F.27 patch flow —
  https://github.com/no-hands-hand/OMEN-Transcend-16-ACPI-fix-f27
- **LauriSarap/omen-transcend-16-linux-fix** — F.25 (IC04 device + Cirrus
  audio) — https://github.com/LauriSarap/omen-transcend-16-linux-fix
