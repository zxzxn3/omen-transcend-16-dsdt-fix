# DSDT override — 8C4D/F.29

Built on **HP OMEN Transcend 16 (16-U1024TX, board `8C4D`)** with BIOS **F.29** by **zxzxn3**.

Three changes in this patch:

1. Bump the OEM revision `0x2 → 0x3` so the kernel accepts the override.
2. Remove the whole `Device (IC04)` — fixes the `AE_AML_OPERAND_TYPE` boot hang
   (`acpi_ns_build_normalized_path`).
3. Fix the Cirrus audio string so the built-in speakers work.

Per-change rationale and sources are annotated in `patch.diff`.

Sources (all GPL-3.0, adapted for F.29):
- j0hnwang/OMEN-Transcend-16-ACPI-fix — https://github.com/j0hnwang/OMEN-Transcend-16-ACPI-fix
- no-hands-hand/OMEN-Transcend-16-ACPI-fix-f27 — https://github.com/no-hands-hand/OMEN-Transcend-16-ACPI-fix-f27
- LauriSarap/omen-transcend-16-linux-fix — https://github.com/LauriSarap/omen-transcend-16-linux-fix