# HP OMEN Transcend 16 (u1xxx / board 8C4D) — Linux ACPI DSDT Fix

> ⚠️ **AI-agent-led project.** This repository was primarily produced by an AI
> coding agent (GitHub Copilot, powered by DeepSeek) under human guidance and
> review. The diagnosis and the DSDT patch were cross-checked against the public
> Bugzilla #221847 report and existing community fixes.

修复 **HP OMEN Transcend 16（16-U1024TX，板号 8C4D，u1 系列）** 的 ACPI bug，
让 Linux 不再：

- 开机卡死 / panic —— `AE_AML_OPERAND_TYPE`，oops in `acpi_ns_build_normalized_path`
- 内置喇叭无声

> 本仓库只服务 **board 8C4D（u1xxx）**。其他 OMEN Transcend 修订（如 u0 = 8BB3）
> 的 DSDT 不同，请勿盲装 —— install.sh 会检测板号并软警告。
> **触控板未做修改**（本机原始固件下可用，社区触控板改动已尝试并回退）。

## 仓库结构

- `install.sh`（根）—— 自动检测 **板号 + BIOS** 的安装器：
  读取 sysfs → 打印 → 板号软警告 → 按 BIOS 路由到 `dsdt-fix/<BIOS>/`，
  无精确匹配时列出可用版本让你选（交互）。
- `dsdt-fix/<BIOS>/` —— 每个固件版本一份补丁：
  - `dsdt.aml` — 编译好的覆盖表（安装用）
  - `dsdt.dsl` / `dsdt-original.dsl` / `dsdt-original.dat` — 源码与原始表
  - `patch.diff` — **每处改动的 问题/原理/出处（带 URL）**，改动细节以它为准
- 目前版本：`F.29/`（真实补丁）、`F.28/`（⚠️ FAKE，仅测路由）。

## 安装（CachyOS / Arch + Limine）

**一行远程安装**（自动检测 BIOS → 拉对应补丁）：

```bash
curl -fsSL https://raw.githubusercontent.com/zxzxn3/omen-transcend-16-u1024tx-f29-dsdt-fix/main/install.sh | sudo bash
```

**本地安装**（从仓库里跑，或指向任意 .aml）：

```bash
sudo bash install.sh                     # 自动：同目录 dsdt.aml → 按 BIOS 路由
sudo bash install.sh dsdt-fix/F.29/dsdt.aml
sudo bash install.sh /path/to/dsdt.aml   # 或任意 URL
```

安装器会：复制 `.aml` 到 `/etc/initcpio/acpi_override/` → 确保 `acpi_override`
hook（已存在则跳过，幂等）→ 备份旧 override（时间戳、无限保留）→ 重建 initramfs
（交互用 `limine-mkinitcpio`，`curl | bash` 下自动用非交互 `mkinitcpio -P`）。

> BIOS 不匹配：交互时列出仓库已有版本让你选或中止；非交互报错并列出。
> 板号不是 8C4D：交互询问是否继续，非交互警告后继续。

## 本补丁改了什么（F.29，共 3 处）

> 每处的问题/原理/出处细节见 [`dsdt-fix/F.29/patch.diff`](dsdt-fix/F.29/patch.diff) 内的注释。

1. **提升 OEM revision** `0x2 → 0x3`（内核才会接受覆盖）。
   出处：[j0hnwang F27 Change 1](https://github.com/j0hnwang/OMEN-Transcend-16-ACPI-fix)。
2. **删除整个 `Device (IC04)`**（消除与整数字段 `IC04` 的同名冲突 —— 开机卡死根因）。
   出处：[LauriSarap F.25 Fix 1](https://github.com/LauriSarap/omen-transcend-16-linux-fix)、
   [j0hnwang Change 2](https://github.com/j0hnwang/OMEN-Transcend-16-ACPI-fix)。
3. **修复 Cirrus 音频字符串** `"cirrus,cirrus,boost-peak-milliamp"` → `"cirrus,boost-peak-milliamp"`（内置喇叭）。
   出处：[LauriSarap F.25](https://github.com/LauriSarap/omen-transcend-16-linux-fix)、
   [no-hands-hand F27](https://github.com/no-hands-hand/OMEN-Transcend-16-ACPI-fix-f27)。

## 验证

```bash
dmesg | grep -i override              # 应看到 DSDT override applied + kernel tainted
dmesg | grep -i AE_AML_OPERAND_TYPE   # 应为空
```

## 撤销（万一启动失败）

用 live USB 启动 → `chroot` 进系统 → 删掉 `/etc/initcpio/acpi_override/dsdt.aml`
→ `mkinitcpio -P` → 重启。安装器每次覆盖前也会留 `dsdt.aml.bak-<时间>`，可拷回回滚。

## 重要说明

- **运行时覆盖**：不写固件、不会变砖、**不影响 Windows**。
- **只对当前这个 Linux 生效**；其他 Linux（含 live U 盘）需各自重做。
- **严格对应 板号 × BIOS**：本仓库针对 **8C4D** 与所列 BIOS 版本；升级 BIOS 后需
  重新 dump/适配（旧补丁有时能继续用，install.sh 会按你的 BIOS 找对应版本）。
- 触控板**未修改**，本机原始固件下可用。

## 参考与致谢

- **Bugzilla [#221847](https://bugzilla.kernel.org/show_bug.cgi?id=221847)**
  (by David Bue Pedersen) — 根因分析。
- **[j0hnwang/OMEN-Transcend-16-ACPI-fix](https://github.com/j0hnwang/OMEN-Transcend-16-ACPI-fix)**
  — F.11 / F.12 / F.27 / F.28 补丁。
- **[no-hands-hand/OMEN-Transcend-16-ACPI-fix-f27](https://github.com/no-hands-hand/OMEN-Transcend-16-ACPI-fix-f27)**
  — F.27 完整补丁流程（6 处改动的来源）。
- **[LauriSarap/omen-transcend-16-linux-fix](https://github.com/LauriSarap/omen-transcend-16-linux-fix)**
  — F.25：删 `IC04` 设备 + Cirrus 音频字符串。

本仓库的 F.29 补丁是把以上社区补丁逐处适配到 16-U1024TX / F.29 固件上的结果。

## 关于本项目

本仓库主要由 **AI 编程代理**（GitHub Copilot，底层 DeepSeek）在人工指导下完成：
从 Windows 注册表只读导出 DSDT → 用 iasl 反汇编 → 定位根因（`Device (IC04)` 与
整数字段 `IC04` 同名冲突）→ 套用社区完整补丁并逐处适配 → 编译并验证。
诊断结论与社区仓库及 Bugzilla #221847 交叉验证一致。

