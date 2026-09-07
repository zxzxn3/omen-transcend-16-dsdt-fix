# HP OMEN Transcend 16 (u1xxx / board 8C4D) — Linux ACPI DSDT Fix

> ⚠️ **AI-agent-led project.** This repository was primarily produced by an AI
> coding agent (GitHub Copilot, powered by DeepSeek) under human guidance and
> review. The diagnosis and the DSDT patch were cross-checked against the public
> Bugzilla #221847 report and existing community fixes.

修复 **HP OMEN Transcend 16（16-U1024TX，板号 8C4D，u1 系列）** 的 ACPI bug，
让 Linux 不再：

- 开机卡死 / panic —— `AE_AML_OPERAND_TYPE`，oops in `acpi_ns_build_normalized_path`
- 内置喇叭无声

> 目前只发布了 **board 8C4D / BIOS F.29** 一份补丁。仓库结构按
> `dsdt-fix/<board>/<bios>/` 组织（清单见 `dsdt-fix/index.txt`），方便日后收录其它板/BIOS。
> 官方下拉会按 **board×BIOS** 精确匹配；你显式指定的与本机不符时给软警告。
> 自己给路径/URL 装 `.aml` 属「自负责任」，安装器不做任何匹配判断。
> **触控板未做修改**（本机原始固件下可用，社区触控板改动已尝试并回退）。

## 仓库结构

- `install.sh`（根）—— 安装器：
  - 给路径/URL → 直接用（不判断，可能是自编译补丁）
  - 不给 → 从官方 repo 拉：用 `--board/--bios`，否则按本机 DMI 自动检测；
    精确命中即装（显式参数与本机不符→软警告）；未收录→打印可用补丁表并退出。
- `dsdt-fix/<board>/<bios>/` —— 每台机器（板）× 固件版本 一份补丁：
  - `dsdt.aml` — 编译好的覆盖表（安装用）
  - `dsdt.dsl` / `dsdt-original.dsl` / `dsdt-original.dat` — 源码与原始表
  - `patch.diff` — **每处改动的 问题/原理/出处（带 URL）**，改动细节以它为准
- `dsdt-fix/index.txt` —— 已发布补丁清单（`<board> <bios>` 一行一个），供列表显示。
- 目前只有：`dsdt-fix/8C4D/F.29/`。

## 安装（CachyOS / Arch + Limine）

**一行远程安装**（自动检测 BIOS → 拉对应补丁）：

```bash
curl -fsSL https://raw.githubusercontent.com/zxzxn3/omen-transcend-16-dsdt-fix/main/install.sh | sudo bash
```

**常用用法**：

```bash
sudo bash install.sh                                  # 官方自动：按本机 DMI 拉 dsdt-fix/<board>/<bios>/dsdt.aml
sudo bash install.sh --board 8C4D --bios F.29         # 官方：显式指定板/BIOS
sudo bash install.sh /path/to/dsdt.aml                # 本地：直接用，不判断（可自编译）
sudo bash install.sh --rebuild                        # 强制重建（上次可能没建成时恢复）
```

安装器是两阶段：先准备（校验 DSDT 签名、暂存、交互确认），最后一刻才覆盖真文件并
重建 initramfs（交互用 `limine-mkinitcpio`，`curl | bash` 自动非交互 `mkinitcpio -P`）。
中断/失败自动还原、退出即清理临时文件、单实例锁——不弄脏机器。
`-f/--force` 跳过「显式参数与本机不符」的软警告和交互确认。

## 本补丁改了什么（F.29，共 3 处）

> 每处的问题/原理/出处细节见 [`dsdt-fix/8C4D/F.29/patch.diff`](dsdt-fix/8C4D/F.29/patch.diff) 内的注释。

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
- **严格对应 板号 × BIOS**：官方下拉按 `dsdt-fix/<board>/<bios>/` 精确匹配；升级
  BIOS 后若没有对应补丁，安装器会列出已有补丁并让你显式 `--board/--bios` 选，绝不自动回退。
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

