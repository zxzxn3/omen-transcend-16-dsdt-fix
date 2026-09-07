# HP OMEN Transcend 16 — DSDT 覆盖补丁（BIOS F.29）

修复 HP OMEN Transcend 16（16-U1024TX）固件 F.29 的 ACPI bug，解决 Linux 开机卡死、触控板、内置喇叭等问题。

## 根因

DSDT 在 `_SB.PC00` 作用域把 `IC04` 声明了两次：

- 整数字段 `IC04, 64`（Serial IO 控制器配置偏移）
- `Device (IC04)`（`_HID "HPIC0004"`）

同名冲突导致 `I2C4._PS3` 调用 `SOD3 (IC04, ...)` 时，把 Device 当整数做加法
`(GPCB () + Arg0)` → `AE_AML_OPERAND_TYPE`，约一半概率 Oops / 引用计数死循环，开机卡死。
（内核 Bugzilla #221847 的同类问题。）

## 本补丁做了什么（共 3 处）

参考 [j0hnwang/OMEN-Transcend-16-ACPI-fix](https://github.com/j0hnwang/OMEN-Transcend-16-ACPI-fix)、
[LauriSarap/omen-transcend-16-linux-fix](https://github.com/LauriSarap/omen-transcend-16-linux-fix)。

1. **提升 OEM revision** `0x00000002 → 0x00000003`（内核才会接受覆盖）。
2. **删除整个 `Device (IC04)` 段**（开机卡死的根因，消除 IC04 同名冲突）。
3. **修复 Cirrus 音频字符串** `"cirrus,cirrus,boost-peak-milliamp" → "cirrus,boost-peak-milliamp"`（修内置喇叭）。

> 每处的「问题 / 原理 / 出处」详见 `patch.diff` 内的注释。

> ⚠️ **触控板未做修改**：社区补丁的第 3/4/5 处（强制 ELAN / 禁用重复设备）在本机
> （16-U1024TX）会导致触控板失效，已回退。本机触控板在原始固件下本来就能用。

## 参考与致谢

- Bugzilla [#221847](https://bugzilla.kernel.org/show_bug.cgi?id=221847)（David Bue Pedersen）——根因分析
- [j0hnwang/OMEN-Transcend-16-ACPI-fix](https://github.com/j0hnwang/OMEN-Transcend-16-ACPI-fix) —— F.11/F.12/F.27/F.28 补丁
- [no-hands-hand/OMEN-Transcend-16-ACPI-fix-f27](https://github.com/no-hands-hand/OMEN-Transcend-16-ACPI-fix-f27) —— F.27 完整补丁流程（6 处改动的来源）
- [LauriSarap/omen-transcend-16-linux-fix](https://github.com/LauriSarap/omen-transcend-16-linux-fix) —— F.25：删 IC04 + Cirrus 字符串

## 文件

| 文件 | 说明 |
|---|---|
| `dsdt.aml` | 编译好的补丁，**安装这个** |
| `dsdt.dsl` | 补丁后的源码（可二次编辑） |
| `dsdt-original.dsl` | 原始 DSDT 反汇编源码（补丁前，用于对照） |
| `dsdt-original.dat` | 原始 DSDT 二进制（备份） |
| `patch.diff` | 补丁前后源码差异（unified diff） |
| `install.sh` | 一键安装脚本（挂载 D 盘 → 装 hook → 重建 initramfs） |

## 安装（CachyOS / Arch + Limine）

```bash
sudo mkdir -p /etc/initcpio/acpi_override
sudo cp dsdt.aml /etc/initcpio/acpi_override/

# 编辑 /etc/mkinitcpio.conf，在 HOOKS=(...) 里 base 之后加 acpi_override
sudo mkinitcpio -P
sudo reboot          # 不要带 acpi=off / noapic
```

或跑脚本（先手动挂载 D 盘，脚本负责复制 .aml、插 hook、重建）：

```bash
sudo mount /dev/nvme0n1p5 /mnt/d
sudo bash install.sh /mnt/d/linux-hate-me/dsdt-fix/dsdt.aml
```

### 一键远程安装（curl | bash，无需先 clone/挂载）

```bash
curl -fsSL https://raw.githubusercontent.com/zxzxn3/omen-transcend-16-u1024tx-f29-dsdt-fix/main/dsdt-fix/install.sh \
  | sudo bash -s -- https://raw.githubusercontent.com/zxzxn3/omen-transcend-16-u1024tx-f29-dsdt-fix/main/dsdt-fix/dsdt.aml
```

> 远程方式下 stdin 是管道而非终端，脚本会自动用非交互的 `mkinitcpio -P` 重建
> （效果相同，只是不弹 Y/N 让你选内核）。本机交互跑仍用 `limine-mkinitcpio`。

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
- 触控板**未做修改**：社区的第 3/4/5 处改动在本机（16-U1024TX）会导致触控板失效，已回退（本机触控板原始固件下可用）。
- 仅适用于 BIOS **F.29**；更新 BIOS 后需重做。
