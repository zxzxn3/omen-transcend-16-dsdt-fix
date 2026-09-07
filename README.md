# HP OMEN Transcend 16 — Linux ACPI DSDT Fix (BIOS F.29)

> ⚠️ **AI-agent-led project.** This repository was primarily produced by an AI
> coding agent (GitHub Copilot, powered by DeepSeek) under human guidance and
> review. The diagnosis and the DSDT patch were cross-checked against the public
> Bugzilla #221847 report and existing community fixes.

Fixes the broken ACPI tables of the **HP OMEN Transcend 16 (16-U1024TX, BIOS F.29)**
that cause Linux to:

- hang / panic at boot — `AE_AML_OPERAND_TYPE`, oops in `acpi_ns_build_normalized_path`
- fail to drive the **built-in speakers**

> The **touchpad works out of the box** with the stock tables on this model,
> so it is deliberately left untouched (the community touchpad patches were
> tried and reverted).

## What's inside

- `install.sh` — auto-detecting installer at the repo root: reads your **board +
  BIOS**, then routes to the matching `dsdt-fix/<BIOS>/` patch (or lists the
  available versions if there is no exact match).
- [`dsdt-fix/`](dsdt-fix/) — patches organized by BIOS version:
  - [`dsdt-fix/F.29/`](dsdt-fix/F.29/) — the real **F.29** patch: `dsdt.aml`,
    patched source, original tables, an annotated `patch.diff` (3 changes) and a
    per-firmware README.
  - `dsdt-fix/F.28/` — ⚠️ **fake** placeholder, only for testing the version
    routing.
- Diagnosis logs (`dmesg`, `journalctl`, installer log).

## Quick install (CachyOS / Arch + Limine)

One-line remote install (auto-detects BIOS → pulls the matching patch):

```bash
curl -fsSL https://raw.githubusercontent.com/zxzxn3/omen-transcend-16-u1024tx-f29-dsdt-fix/main/install.sh | sudo bash
```

Local (from this repo, or point at any .aml):

```bash
sudo bash install.sh                     # auto: same-dir dsdt.aml → BIOS route
sudo bash install.sh dsdt-fix/F.29/dsdt.aml
sudo bash install.sh /path/to/dsdt.aml
```

The installer copies the `.aml` into `/etc/initcpio/acpi_override/`, ensures the
`acpi_override` hook, backs up any previous override (timestamped, kept
indefinitely), and rebuilds the initramfs (`limine-mkinitcpio` when interactive,
`mkinitcpio -P` under `curl | bash`).

## Root cause

The DSDT declares `IC04` twice in `_SB.PC00` scope — once as a 64-bit integer
field, once as `Device (IC04)` (`_HID "HPIC0004"`). The name collision makes
`SOD3 (IC04, ...)` receive a Device instead of an Integer → `AE_AML_OPERAND_TYPE`.

## References / 参考与致谢

The diagnosis and the 6 DSDT changes in this repo are adapted from, and
cross-verified against, the following public sources:

- **Bugzilla [#221847](https://bugzilla.kernel.org/show_bug.cgi?id=221847)**
  (by David Bue Pedersen) — original root-cause analysis of the `IC04`
  Device/Integer namespace collision and the `SOD3` abort.
- **[j0hnwang/OMEN-Transcend-16-ACPI-fix](https://github.com/j0hnwang/OMEN-Transcend-16-ACPI-fix)**
  — DSDT patches for firmware F.11 / F.12 / F.27 / F.28.
- **[no-hands-hand/OMEN-Transcend-16-ACPI-fix-f27](https://github.com/no-hands-hand/OMEN-Transcend-16-ACPI-fix-f27)**
  — F.27 full patch procedure (`F27-Patch-Procedure.md`). Its touchpad changes
  were tried but reverted (touchpad already works on 16-U1024TX).
- **[LauriSarap/omen-transcend-16-linux-fix](https://github.com/LauriSarap/omen-transcend-16-linux-fix)**
  — F.25 fix: remove conflicting `IC04` device + Cirrus audio string.

本仓库的 F.29 补丁是把以上社区补丁逐处适配到 16-U1024TX / F.29 固件上的结果。

## 关于本项目（中文）

本仓库主要由 **AI 编程代理**（GitHub Copilot，底层 DeepSeek）在人工指导下完成：
从 Windows 注册表只读导出 DSDT → 用 iasl 反汇编 → 定位根因（`Device (IC04)` 与
整数字段 `IC04` 同名冲突）→ 套用社区完整补丁（6 处改动）→ 编译并验证。

诊断结论与社区仓库（j0hnwang、no-hands-hand、LauriSarap）及 Bugzilla #221847
交叉验证一致。每处改动的「问题 / 原理 / 出处」详见
[`dsdt-fix/F.29/patch.diff`](dsdt-fix/F.29/patch.diff) 内的注释。
