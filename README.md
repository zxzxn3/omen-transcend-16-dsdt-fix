# HP OMEN Transcend 16 — Linux ACPI DSDT Fix (BIOS F.29)

> ⚠️ **AI-agent-led project.** This repository was primarily produced by an AI
> coding agent (GitHub Copilot, powered by DeepSeek) under human guidance and
> review. The diagnosis and the DSDT patch were cross-checked against the public
> Bugzilla #221847 report and existing community fixes.

Fixes the broken ACPI tables of the **HP OMEN Transcend 16 (16-U1024TX, BIOS F.29)**
that cause Linux to:

- hang / panic at boot — `AE_AML_OPERAND_TYPE`, oops in `acpi_ns_build_normalized_path`
- fail to detect the **touchpad**
- fail to drive the **built-in speakers**

## What's inside

- [`dsdt-fix/`](dsdt-fix/) — the compiled DSDT override (`dsdt.aml`), patched
  source, original tables, and an annotated `patch.diff` (6 changes, each with
  problem / principle / source).
- [`dsdt-fix/README.md`](dsdt-fix/README.md) — install / verify / revert instructions.
- Diagnosis logs (`dmesg`, `journalctl`, installer log).

## Quick install (CachyOS / Arch + Limine)

```bash
sudo mkdir -p /etc/initcpio/acpi_override
sudo cp dsdt-fix/dsdt.aml /etc/initcpio/acpi_override/
# add `acpi_override` to HOOKS in /etc/mkinitcpio.conf
sudo mkinitcpio -P
sudo reboot          # do NOT use acpi=off / noapic
```

## Root cause

The DSDT declares `IC04` twice in `_SB.PC00` scope — once as a 64-bit integer
field, once as `Device (IC04)` (`_HID "HPIC0004"`). The name collision makes
`SOD3 (IC04, ...)` receive a Device instead of an Integer → `AE_AML_OPERAND_TYPE`.

## 关于本项目（中文）

本仓库主要由 **AI 编程代理**（GitHub Copilot，底层 DeepSeek）在人工指导下完成：
从 Windows 注册表只读导出 DSDT → 用 iasl 反汇编 → 定位根因（`Device (IC04)` 与
整数字段 `IC04` 同名冲突）→ 套用社区完整补丁（6 处改动）→ 编译并验证。

诊断结论与社区仓库（j0hnwang、no-hands-hand、LauriSarap）及 Bugzilla #221847
交叉验证一致。每处改动的「问题 / 原理 / 出处」详见
[`dsdt-fix/patch.diff`](dsdt-fix/patch.diff) 内的注释。
