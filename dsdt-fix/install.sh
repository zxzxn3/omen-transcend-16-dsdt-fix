#!/usr/bin/env bash
# =====================================================================
# HP OMEN Transcend 16 (BIOS F.29) — DSDT 覆盖补丁安装脚本（手动挂载版）
#
# 用法:   sudo bash install.sh [dsdt.aml 的路径]
# 示例:   sudo mount /dev/nvme0n1p5 /mnt/d      # 先手动挂载 D 盘
#         sudo bash install.sh /mnt/d/linux-hate-me/dsdt-fix/dsdt.aml
#
# 功能:   把指定的 dsdt.aml 装进 initramfs（含 acpi_override hook）。
# 幂等:   可重复运行，不会重复插入 hook。
# =====================================================================
set -euo pipefail

# ---- 可配置项 ----
SRC="${1:-/mnt/d/linux-hate-me/dsdt-fix/dsdt.aml}"   # .aml 路径（可传参覆盖）
OVERRIDE_DIR="/etc/initcpio/acpi_override"
MKINITCPIO_CONF="/etc/mkinitcpio.conf"
HOOK_NAME="acpi_override"
# -----------------

if [ "$(id -u)" -ne 0 ]; then
  echo "错误：请用 sudo 运行本脚本。例如：sudo bash install.sh" >&2
  exit 1
fi

if [ ! -f "$SRC" ]; then
  echo "错误：找不到 ${SRC}" >&2
  echo "请先手动挂载 D 盘：sudo mount /dev/nvme0n1p5 /mnt/d" >&2
  echo "或直接传入 .aml 路径：sudo bash install.sh /path/to/dsdt.aml" >&2
  exit 1
fi

echo "[1/3] 复制 dsdt.aml 到 ${OVERRIDE_DIR}/ ..."
mkdir -p "$OVERRIDE_DIR"
cp -v "$SRC" "$OVERRIDE_DIR/dsdt.aml"

# 2. 确保 acpi_override hook 存在
echo "[2/3] 检查 mkinitcpio HOOKS ..."
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

# 3. 重建 initramfs（交互式；CachyOS/Limine 用 limine-mkinitcpio，会弹 Y/N 让用户选择）
echo "[3/3] 重建 initramfs ..."
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
