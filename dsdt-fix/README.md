# HP OMEN Transcend 16 — DSDT 覆盖补丁（BIOS F.29）

修复 HP OMEN Transcend 16（16-U1024TX）固件 F.29 的 ACPI bug，解决 Linux 开机卡死、触控板、内置喇叭等问题。

## 根因

DSDT 在 `_SB.PC00` 作用域把 `IC04` 声明了两次：

- 整数字段 `IC04, 64`（Serial IO 控制器配置偏移）
- `Device (IC04)`（`_HID "HPIC0004"`）

同名冲突导致 `I2C4._PS3` 调用 `SOD3 (IC04, ...)` 时，把 Device 当整数做加法
`(GPCB () + Arg0)` → `AE_AML_OPERAND_TYPE`，约一半概率 Oops / 引用计数死循环，开机卡死。
（内核 Bugzilla #221847 的同类问题。）

## 本补丁做了什么（共 6 处，全套）

参考 [j0hnwang/OMEN-Transcend-16-ACPI-fix](https://github.com/j0hnwang/OMEN-Transcend-16-ACPI-fix)、
[no-hands-hand/OMEN-Transcend-16-ACPI-fix-f27](https://github.com/no-hands-hand/OMEN-Transcend-16-ACPI-fix-f27)、
[LauriSarap/omen-transcend-16-linux-fix](https://github.com/LauriSarap/omen-transcend-16-linux-fix)。

1. **提升 OEM revision** `0x00000002 → 0x00000003`（内核才会接受覆盖）。
2. **删除整个 `Device (IC04)` 段**（开机卡死的根因，消除 IC04 同名冲突）。
3. **I2C0 触控板 TPD0 强制 ELAN**：`_INI` 引导到 ELAN07CA 分支 + `_STA` 硬编码可见（修触控板）。
4. **I2C1 `_INI` 引导到 ELAN**（Recommended，作者存疑，可删）。
5. **禁用 I2C1 重复的 TPD0 / LLKB**（`_STA` 返回 Zero）。
6. **修复 Cirrus 音频字符串** `"cirrus,cirrus,boost-peak-milliamp" → "cirrus,boost-peak-milliamp"`（修内置喇叭）。

> 每处的「问题 / 原理 / 出处」详见 `patch.diff` 内的注释。

## 文件

| 文件 | 说明 |
|---|---|
| `dsdt.aml` | 编译好的补丁，**安装这个** |
| `dsdt.dsl` | 补丁后的源码（可二次编辑） |
| `dsdt-original.dsl` | 原始 DSDT 反汇编源码（补丁前，用于对照） |
| `dsdt-original.dat` | 原始 DSDT 二进制（备份） |
| `patch.diff` | 补丁前后源码差异（unified diff） |

## 安装（CachyOS / Arch + Limine）

```bash
sudo mkdir -p /etc/initcpio/acpi_override
sudo cp dsdt.aml /etc/initcpio/acpi_override/

# 编辑 /etc/mkinitcpio.conf，在 HOOKS=(...) 里 base 之后加 acpi_override
sudo mkinitcpio -P
sudo reboot          # 不要带 acpi=off / noapic
```

## 验证

```bash
dmesg | grep -i override                # 应看到 DSDT override + tainting kernel
dmesg | grep -i AE_AML_OPERAND_TYPE     # 应为空
```

## 撤销（万一启动失败）

用 live USB 启动 → `chroot` 进系统 → 删掉 `/etc/initcpio/acpi_override/dsdt.aml`
→ `mkinitcpio -P` → 重启。

## 重要说明

- 这是**运行时覆盖**：不写固件、不会变砖、**不影响 Windows**。
- **只对当前这个 CachyOS 生效**；其他 Linux（含 U 盘 live 系统）需各自重做。
- 触控板靠改动 3/4/5 修复，但**需开机后实际验证**（作者提示可能要根据硬件在 I2C0/I2C1 之间翻转；改动 4 可删）。
- 仅适用于 BIOS **F.29**；更新 BIOS 后需重做。
