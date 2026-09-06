#!/usr/bin/env bash
# =====================================================================
# HP OMEN Transcend 16 (BIOS F.29) — DSDT 覆盖补丁安装脚本
#
# 用法:   sudo bash install.sh [D盘分区设备]
# 示例:   sudo bash install.sh /dev/nvme0n1p5
#
# 功能:   挂载 Windows 的 D: 盘(NTFS)，把其中的
#         linux-hate-me/dsdt-fix/dsdt.aml 安装进 initramfs。
# 幂等:   可重复运行，不会重复插入 hook。
# =====================================================================
set -euo pipefail

# ---- 可配置项 ----
D_PART="${1:-/dev/nvme0n1p5}"                 # D: 盘分区（可用 lsblk 确认）
SRC_REL="linux-hate-me/dsdt-fix/dsdt.aml"     # .aml 在 D 盘上的相对路径
OVERRIDE_DIR="/etc/initcpio/acpi_override"
MKINITCPIO_CONF="/etc/mkinitcpio.conf"
HOOK_NAME="acpi_override"
# -----------------

if [ "$(id -u)" -ne 0 ]; then
  echo "错误：请用 sudo 运行本脚本。例如：sudo bash install.sh" >&2
  exit 1
fi

# 挂载点 + 退出时自动清理
MNT="$(mktemp -d /tmp/dsdt-mnt.XXXXXX)"
trap 'umount "$MNT" 2>/dev/null; rmdir "$MNT" 2>/dev/null' EXIT

echo "[1/4] 挂载 ${D_PART}（NTFS）..."
if ! mount "$D_PART" "$MNT" 2>/dev/null; then
  if ! mount -t ntfs3 "$D_PART" "$MNT" 2>/dev/null; then
    echo "错误：无法挂载 ${D_PART}。请用 lsblk 确认 D: 盘分区，并作为参数传入：" >&2
    echo "     sudo bash install.sh /dev/nvme0n1pX" >&2
    exit 1
  fi
fi

# 2. 复制 dsdt.aml
SRC="$MNT/$SRC_REL"
if [ ! -f "$SRC" ]; then
  echo "错误：在挂载点内找不到 ${SRC_REL}" >&2
  echo "请确认分区正确，或该路径下确有 dsdt-fix/dsdt.aml。" >&2
  exit 1
fi

echo "[2/4] 复制 dsdt.aml 到 ${OVERRIDE_DIR}/ ..."
mkdir -p "$OVERRIDE_DIR"
cp -v "$SRC" "$OVERRIDE_DIR/dsdt.aml"

# 3. 确保 acpi_override hook 存在
echo "[3/4] 检查 mkinitcpio HOOKS ..."
CONF_FILES=("$MKINITCPIO_CONF")
for f in /etc/mkinitcpio.conf.d/*.conf; do
  [ -f "$f" ] && CONF_FILES+=("$f")
done

HOOK_OK=0
for f in "${CONF_FILES[@]}"; do
  if grep -qE '^\s*HOOKS=.*\bacpi_override\b' "$f" 2>/dev/null; then
    echo "  ✓ $f 已包含 ${HOOK_NAME}"
    HOOK_OK=1
    break
  fi
done

if [ "$HOOK_OK" -ne 1 ]; then
  INSERTED=0
  for f in "${CONF_FILES[@]}"; do
    if grep -qE '^\s*HOOKS=\(' "$f" 2>/dev/null; then
      # 在 HOOKS=(... base ...) 的 base 之后插入 acpi_override
      sed -i -E 's/^(HOOKS=\([^)]*\bbase)\b/\1 '"${HOOK_NAME}"'/' "$f"
      echo "  ✓ 已在 $f 的 base 之后插入 ${HOOK_NAME}（请人工核对）"
      INSERTED=1
      break
    fi
  done
  if [ "$INSERTED" -ne 1 ]; then
    echo "  ⚠ 未能自动定位 HOOKS= 行，请手动在 mkinitcpio 配置里加入 ${HOOK_NAME}" >&2
  fi
fi

# 4. 重建 initramfs（交互式；CachyOS/Limine 用 limine-mkinitcpio，会弹 Y/N 让用户选择）
echo "[4/4] 重建 initramfs ..."
if command -v limine-mkinitcpio >/dev/null 2>&1; then
  limine-mkinitcpio
else
  mkinitcpio -P
fi

echo ""
echo "完成。现在可以重启（不要带 acpi=off / noapic）。"
echo "重启后验证："
echo "  dmesg | grep -i override              # 应看到 DSDT override + taint"
echo "  dmesg | grep -i AE_AML_OPERAND_TYPE   # 应为空"
