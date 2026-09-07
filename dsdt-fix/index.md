# Available DSDT patches

Each published patch lives in `dsdt-fix/<board>/<bios>/` (e.g. `dsdt-fix/8C4D/F.29/`),
so one patch = one `--target` value. Add a row below for every new patch folder;
`dsdt-fix.sh` lists these when the requested patch is not published, and you pass
the first column straight back as `--target`.

| --target |
|----------|
| 8C4D/F.29 |
