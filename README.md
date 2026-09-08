# HP OMEN Transcend 16 — Linux ACPI (DSDT) fix

> **A gibberish from the human owner.** Hi — I spent two days working with Agent to get
> Linux running on this OMEN laptop (maybe it would have taken less time if I
> hadn't used Agent). Once I'd fixed it with community wisdom, I decided to
> automate the whole thing with an agent — which led to a lot of
> over-engineering, then refactoring, and all that (I'm starting to think I
> could write much faster if I only used the agent for the first ten minutes of
> this project). It also burned through a ton of tokens, i.e. money. I'll
> probably end up asking an AI to rephrase this paragraph too. For what it's
> worth: I do review these code changes.

> ⚠️ **AI-agent-led project.** This repository was primarily produced by an AI
> coding agent (GitHub Copilot, powered by DeepSeek) under human guidance and
> review. The diagnosis and the DSDT patch were cross-checked against the public
> Bugzilla [#221847] report and the existing community fixes listed below.

Fixes the broken ACPI on the **HP OMEN Transcend 16** (16-U1024TX / u1-series,
board `8C4D`, BIOS `F.29`) so Linux no longer:

- Hangs / panics at boot — `AE_AML_OPERAND_TYPE`, oops in
  `acpi_ns_build_normalized_path` (the reason people previously booted with
  `acpi=off noapic`).
- Comes up with silent built-in speakers.

> **Status.** One patch is published: **`8C4D/F.29`** (board `8C4D`, BIOS `F.29`). The
> published patch list lives in [`dsdt-fix/index.md`](dsdt-fix/index.md)
> (one `--target` per row, e.g. `8C4D/F.29`). Patches are matched exactly by
> board × BIOS — **never** an automatic fallback to a different BIOS.

## How it works

`dsdt-fix.sh` applies the DSDT override at the initramfs level using
mkinitcpio's standard `acpi_override` hook:

1. Place the patched table at `/etc/initcpio/acpi_override/dsdt.aml`.
2. Make sure `acpi_override` is in the `HOOKS=(base ...)` list of the config
   that is actually used to build initramfs.
3. Rebuild the initramfs so the hook packs `kernel/firmware/acpi/dsdt.aml`
   into the early, uncompressed CPIO that the kernel reads at boot
   (`CONFIG_ACPI_TABLE_UPGRADE` path).

On **CachyOS** the rebuild prefers `limine-mkinitcpio` (rebuild **and** refresh
the auto-managed Limine entries); on plain Arch it falls back to
`mkinitcpio -P`.

### Safety design

- **Two-phase.** The prepare phase never touches a real file — everything is
  staged in a `mktemp -d` directory. Real files are only replaced at the last
  moment (atomic `.new` + `mv`), right before the rebuild.
- **Automatic rollback.** If anything fails before the rebuild is confirmed, an
  `EXIT` trap restores the previous `dsdt.aml` and the mkinitcpio config from
  staged originals. A single-instance `flock` prevents concurrent runs.
- **It verifies, not just hopes.** After the rebuild, `dsdt-fix.sh` resolves the
  images from `/etc/mkinitcpio.d/*.preset` (the same source the boot-entry
  tooling uses) and checks each with `lsinitcpio --early` for
  `kernel/firmware/acpi/dsdt.aml`. If any of the freshly built images lacks it,
  the script errors and rolls back; if none can be found it tells you to check
  manually. This is the single safety net for unusual config layouts.
- **Conservative about configs.** Only `/etc/mkinitcpio.conf` is ever
  auto-edited (it must have a `HOOKS=(... base ...)` line to anchor on); if the
  hook cannot be added automatically it errors and tells you what to add by
  hand.
- **No litter.** Temporary files are removed on exit. The only persistent file
  is a `dsdt.aml.bak-<timestamp>` kept before each overwrite.

## Install (CachyOS / Arch + Limine)

Requirements: `root`, `bash`, `curl` (for downloads), and the `mkinitcpio`
toolchain (with `limine-mkinitcpio` on CachyOS).

**One-line install** — auto-detects board/BIOS from DMI and pulls the matching
patch:

```bash
curl -fsSL https://raw.githubusercontent.com/zxzxn3/omen-transcend-16-dsdt-fix/main/dsdt-fix.sh | sudo bash
```

Before running any downloaded script as root, download it and take a look
first:

```bash
curl -fsSL https://raw.githubusercontent.com/zxzxn3/omen-transcend-16-dsdt-fix/main/dsdt-fix.sh -o dsdt-fix.sh
# read it (it is short), then:
sudo bash dsdt-fix.sh
```

**Common usage:**

```bash
sudo bash dsdt-fix.sh                                  # official: auto-detect via DMI
sudo bash dsdt-fix.sh --target 8C4D/F.29               # official: pick board/BIOS explicitly
sudo bash dsdt-fix.sh /path/to/dsdt.aml                # your own .aml, used as-is (no checks)
sudo bash dsdt-fix.sh --rebuild                        # force an initramfs rebuild
```

### Options

| Option | Meaning |
|---|---|
| `--target ID` | `<board>/<bios>` exactly as in the repo tree (e.g. `8C4D/F.29`). Omit to auto-detect from DMI. |
| `-f, --force` | Skip the machine-match soft warning and the interactive confirmation. |
| `--rebuild` | Force a rebuild even if the override is already installed and unchanged. |
| `-h, --help` | Show help and exit. |

### What the operand means

- **Given** — a `dsdt.aml` path, installed as-is with **no** checks (e.g. a
  patch you compiled yourself; the only check is the `DSDT` file signature).
  `--target` cannot be combined with an operand.
- **Omitted** — the patch is pulled from this GitHub repo as
  `dsdt-fix/<target>/dsdt.aml`, using `--target` or the machine DMI.

An explicit `--target` that does not match the machine's DMI triggers a soft
warning (interactive `y/N`, or abort in non-interactive mode unless `-f`).

## What this patch changes (F.29)

Per-change rationale and sources are annotated in
[`dsdt-fix/8C4D/F.29/patch.diff`](dsdt-fix/8C4D/F.29/patch.diff).

1. **Bump OEM revision** `0x2 → 0x3` so the kernel accepts the override.
   Source: [j0hnwang F27 change 1](https://github.com/j0hnwang/OMEN-Transcend-16-ACPI-fix).
2. **Remove the whole `Device (IC04)`** — fixes the name collision with the
   integer field `IC04` (the boot-hang root cause).
   Sources: [LauriSarap F.25 fix 1](https://github.com/LauriSarap/omen-transcend-16-linux-fix),
   [j0hnwang change 2](https://github.com/j0hnwang/OMEN-Transcend-16-ACPI-fix).
3. **Fix the Cirrus audio string**
   `"cirrus,cirrus,boost-peak-milliamp"` → `"cirrus,boost-peak-milliamp"`
   (built-in speakers).
   Sources: [LauriSarap F.25](https://github.com/LauriSarap/omen-transcend-16-linux-fix),
   [no-hands-hand F27](https://github.com/no-hands-hand/OMEN-Transcend-16-ACPI-fix-f27).

## Verify after installing

The installer already checks (pre-reboot) that the override made it into the
built initramfs:

```bash
lsinitcpio --early /boot/<your-initramfs> | grep kernel/firmware/acpi/dsdt.aml
```

Then, to actually use it:

1. Remove `acpi=off` from the kernel command line (CachyOS/Limine:
   `/etc/default/limine`, then `sudo limine-mkinitcpio`). You may **keep
   `noapic`** for this first boot as a safety margin — `noapic` does not
   disable ACPI, so the override still applies. (Do **not** verify under
   `acpi=off`: it disables ACPI entirely, so the override never runs.)
2. Reboot and confirm it is active:
   ```bash
   dmesg | grep -i "ACPI: Override"      # expect: DSDT ... this is unsafe: tainting kernel
   dmesg | grep -i AE_AML_OPERAND_TYPE   # expect: no output
   ```
3. Built-in speakers should now work. Only once everything passes, also remove
   `noapic`.

## Rollback (if boot fails)

Re-add `acpi=off noapic`, then either:

- restore the pre-change copy:
  `/etc/initcpio/acpi_override/dsdt.aml.bak-<timestamp>` → `dsdt.aml`, remove
  `acpi_override` from `HOOKS`, `sudo mkinitcpio -P`; or
- boot a live USB → `chroot` → remove
  `/etc/initcpio/acpi_override/dsdt.aml`, drop `acpi_override` from `HOOKS`,
  `mkinitcpio -P`, reboot.

## Share your own fix

**Contributions are welcome.** If you fixed the same problem on a different
BIOS or a sibling board — or improved this patch — send a pull request (or open
an issue with your `.aml`/`.dsl`). The owner reviews every submission and
merges it into this repo, so the next person can just run `dsdt-fix.sh` instead
of repeating the whole journey.

A patch folder should look like:

- layout: `dsdt-fix/<board>/<bios>/dsdt.aml` (+ `.dsl` sources and a
  `patch.diff` annotating each change and its source);
- a short `README.md` in the patch folder describing anything patch-specific
  (prerequisites, differences vs other BIOSes, credits) — `dsdt-fix.sh` prints
  it before installing;
- add one row to [`dsdt-fix/index.md`](dsdt-fix/index.md) so the installer can
  list it;
- the `.aml` must be **byte-reproducible** from the committed `.dsl`
  (recompile with `iasl` and compare) so a patch is never a hidden binary blob.

`dsdt-fix.sh` also prints this invitation up front, before anything runs.

## Repository layout

```
dsdt-fix.sh                # the auto-detecting installer (single file)
dsdt-fix/index.md          # published patches: one --target per row
dsdt-fix/<board>/<bios>/   # one patch per board × BIOS
  dsdt.aml                 # compiled override table (what gets installed)
  README.md                # patch-specific note + credits (shown by installer)
  dsdt.dsl / dsdt-original.dsl / dsdt-original.dat
  patch.diff               # per-change rationale + sources
```

Currently: [`dsdt-fix/8C4D/F.29/`](dsdt-fix/8C4D/F.29/).

## Important notes

- **Runtime-only override.** No firmware is written; nothing can brick the
  machine; **Windows is unaffected**.
- **Trust the .aml you install.** A DSDT runs as **kernel code on the next
  boot** (ACPI AML is executed by the kernel; the `DSDT` signature check only
  catches accidental file mix-ups, it is not a security check). Only install
  `.aml` files you trust — e.g. one you built from reviewed source, or the
  reviewed patches published in this repo.
- **Per-Linux-install.** It applies only to the Linux where you run it; other
  systems (including live USBs) need the same steps.
- **Strict board × BIOS match.** One patch = one `--target`. After a BIOS
  upgrade with no matching patch, the installer lists what is available and
  lets you pick explicitly — it never silently falls back.
- The **touchpad is intentionally not modified** (it works with the stock
  firmware; community touchpad changes were tried and reverted).

## References & credits

- **Bugzilla [#221847]** (by David Bue Pedersen) — root-cause analysis.
- [j0hnwang/OMEN-Transcend-16-ACPI-fix] — F.11/F.12/F.27/F.28 patches.
- [no-hands-hand/OMEN-Transcend-16-ACPI-fix-f27] — full F.27 patch flow.
- [LauriSarap/omen-transcend-16-linux-fix] — F.25: remove `IC04` device +
  Cirrus audio string.

This repo's F.29 patch adapts those community patches, item by item, to the
16-U1024TX / F.29 firmware.

## About this project

Built mostly by an **AI coding agent** (GitHub Copilot, powered by DeepSeek)
under human guidance: read-only export of the DSDT from the Windows registry →
disassembly with `iasl` → root-cause identification (the `Device (IC04)` vs
integer-field `IC04` name collision) → adaptation of the complete community
patch → compilation and verification. Findings cross-check against the
community repos and Bugzilla [#221847].

[#221847]: https://bugzilla.kernel.org/show_bug.cgi?id=221847
[j0hnwang/OMEN-Transcend-16-ACPI-fix]: https://github.com/j0hnwang/OMEN-Transcend-16-ACPI-fix
[no-hands-hand/OMEN-Transcend-16-ACPI-fix-f27]: https://github.com/no-hands-hand/OMEN-Transcend-16-ACPI-fix-f27
[LauriSarap/omen-transcend-16-linux-fix]: https://github.com/LauriSarap/omen-transcend-16-linux-fix


