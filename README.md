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

Fixes the broken ACPI on the **HP OMEN Transcend 16** so Linux no longer:

- Hangs / panics at boot — `AE_AML_OPERAND_TYPE`, oops in
  `acpi_ns_build_normalized_path` (the reason people previously booted with
  `acpi=off noapic`).
- Comes up with silent built-in speakers.
- And other problems depend on which patch you choose.

Check [dsdt-fix/index.md](dsdt-fix/index.md) to see available patches.

## Quickstart

```bash
curl -fsSL https://raw.githubusercontent.com/zxzxn3/omen-transcend-16-dsdt-fix/main/dsdt-fix.sh | sudo bash
```
or read it before you `sudo`

```bash
curl -fsSL https://raw.githubusercontent.com/zxzxn3/omen-transcend-16-dsdt-fix/main/dsdt-fix.sh -o dsdt-fix.sh
# read it, then:
sudo bash dsdt-fix.sh
```

All options, one per line — `--list` and `-h` need no root:

```bash
sudo bash dsdt-fix.sh --list               # list available patches (installable + upstream links); nothing is downloaded
sudo bash dsdt-fix.sh --target 8C4D/F.29   # install one specific <board>/<bios>; omit it to auto-detect from DMI
sudo bash dsdt-fix.sh --force              # skip the machine-match warning and the y/N confirmation
sudo bash dsdt-fix.sh --rebuild            # force an initramfs rebuild even if nothing changed
sudo bash dsdt-fix.sh /path/to/dsdt.aml    # your own .aml, installed as-is (only a 'DSDT' signature check)
sudo bash dsdt-fix.sh -h                   # print all options
```

Passing a `.aml` operand uses your file as-is; it cannot be combined with
`--target`. An explicit `--target` that does not match this machine's DMI asks
for confirmation before applying (`-f` skips it). With no operand, the patch is
pulled from this repo as `dsdt-fix/<target>/dsdt.aml`.

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

## Safety design

A DSDT override runs as **kernel code on every boot**, so the installer is
deliberately conservative:

- **Two-phase + auto-rollback.** Nothing real is written until the last moment
  (everything is staged in a `mktemp -d`, then applied with atomic `.new` +
  `mv`). If anything fails before the rebuild is confirmed, an `EXIT` trap
  restores the previous files; a single-instance `flock` prevents concurrent
  runs.
- **Verifies, not hopes.** After the rebuild it checks every image named by
  `/etc/mkinitcpio.d/*.preset` with `lsinitcpio --early` for
  `kernel/firmware/acpi/dsdt.aml`; if any freshly built image lacks it, it
  errors and rolls back (and if none can be found, it tells you to check
  manually).
- **Conservative about configs.** Only `/etc/mkinitcpio.conf` is ever
  auto-edited (it must have a `HOOKS=(... base ...)` line to anchor on);
  otherwise it tells you exactly what to add by hand.
- **No litter.** Temporary files are removed on exit; the only persistent file
  is a `dsdt.aml.bak-<timestamp>` kept before each overwrite.

**If boot fails**, re-add `acpi=off noapic` and roll back — restore the
pre-change copy (`/etc/initcpio/acpi_override/dsdt.aml.bak-<timestamp>` →
`dsdt.aml`, remove `acpi_override` from `HOOKS`, `sudo mkinitcpio -P`); or if
you cannot boot at all, from a live USB → `chroot` → delete
`/etc/initcpio/acpi_override/dsdt.aml`, drop `acpi_override` from `HOOKS`,
`mkinitcpio -P`, reboot.

## Share your own fix

**Contributions are welcome.** If you fixed the same problem on a different
BIOS or a sibling board — or improved this patch — send a pull request (or open
an issue with your `.aml`/`.dsl`). The owner reviews every submission and
merges it into this repo, so the next person can just run `dsdt-fix.sh` instead
of repeating the whole journey.

A patch folder should look like:

- layout: `dsdt-fix/<board>/<bios>/dsdt.dsl` (+ an optional
  `dsdt.diff` annotating each change and its source);
- a short `README.md` in the patch folder describing anything patch-specific
  (prerequisites, differences vs other BIOSes, credits) — `dsdt-fix.sh` prints
  it before installing;
- add one row to [`dsdt-fix/index.md`](dsdt-fix/index.md) so the installer can
  list it;

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

## References & credits

- **Bugzilla [#221847]** (by David Bue Pedersen) — root-cause analysis.
- [j0hnwang/OMEN-Transcend-16-ACPI-fix] — F.11/F.12/F.27/F.28 patches.
- [no-hands-hand/OMEN-Transcend-16-ACPI-fix-f27] — full F.27 patch flow.
- [LauriSarap/omen-transcend-16-linux-fix] — F.25: remove `IC04` device +
  Cirrus audio string.

This repo's F.29 patch adapts those community patches, item by item, to the
16-U1024TX / F.29 firmware. [j0hnwang/OMEN-Transcend-16-ACPI-fix] and
[no-hands-hand/OMEN-Transcend-16-ACPI-fix-f27] are **GPL-3.0** and stay the
canonical source for their own units/BIOS versions — this repo does not
redistribute their patches, it only publishes ones it can vouch for (currently
`8C4D/F.29`) and points visitors at the upstream repos for anything else (see
[`dsdt-fix/index.md`](dsdt-fix/index.md)).

## License

GPL-3.0

## Disclaimer

This is **not** an official HP tool and is not affiliated with HP. A DSDT
override runs as **kernel code on every boot**; nothing here writes firmware or
touches Windows, but a faulty `.aml` can keep Linux from booting (see
[Safety design](#safety-design)). Use this project **at your own risk**, on
hardware you own, only with `.aml` files you trust, and never on a machine you
cannot afford to reinstall. The project is provided "as is" with **no warranty
of any kind**; if you are not comfortable changing how your hardware's ACPI
behaves, don't run it.


[#221847]: https://bugzilla.kernel.org/show_bug.cgi?id=221847
[j0hnwang/OMEN-Transcend-16-ACPI-fix]: https://github.com/j0hnwang/OMEN-Transcend-16-ACPI-fix
[no-hands-hand/OMEN-Transcend-16-ACPI-fix-f27]: https://github.com/no-hands-hand/OMEN-Transcend-16-ACPI-fix-f27
[LauriSarap/omen-transcend-16-linux-fix]: https://github.com/LauriSarap/omen-transcend-16-linux-fix
