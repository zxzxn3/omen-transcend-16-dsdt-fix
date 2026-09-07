#!/usr/bin/env bash
# =====================================================================
# HP OMEN Transcend 16 (BIOS F.29) — DSDT override installer
#
# 用法:   sudo bash install.sh [dsdt.aml 的路径]
# 默认:   不传参数时，自动使用「本脚本所在目录」下的 dsdt.aml
# 功能:   把编译好的 dsdt.aml 装进 initramfs（含 acpi_override hook），然后重建 initramfs
# 幂等:   可重复运行，不会重复插入 hook
#
# 本脚本从「已编译好的 .aml」开始，负责的是纯机械的安装部分；
# 之前「怎么改代码、怎么编译」的判断工作不在这里。
# =====================================================================
set -euo pipefail
# set -e      : 任何一条命令失败就立即退出（避免出错后继续乱跑）
# set -u      : 用到未定义变量就报错退出（抓笔误）
# set -o pipefail : 管道里任何一环失败都算整体失败（防止 grep 失败被忽略）

# ---------------------------------------------------------------
# 0. 确定 .aml 路径
# ---------------------------------------------------------------
# ${BASH_SOURCE[0]} = 本脚本的路径（无论从哪个目录、用什么方式调用都准）。
# dirname  取它所在的目录；cd 过去再 pwd 是为了拿到「绝对路径」。
# 这样 SCRIPT_DIR 永远指向 install.sh 自己所在的文件夹。
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 第 1 个参数（$1）给了就用它；没给就用「同目录下的 dsdt.aml」。
# 之所以默认同目录：你能执行本脚本，就说明脚本和 .aml 基本是放在一起被复制/挂载过来的。
SRC="${1:-$SCRIPT_DIR/dsdt.aml}"

OVERRIDE_DIR="/etc/initcpio/acpi_override"  # initramfs 里放 DSDT 覆盖文件的固定目录
MKINITCPIO_CONF="/etc/mkinitcpio.conf"       # mkinitcpio 主配置文件
HOOK_NAME="acpi_override"                    # 负责把上面的 .aml 打进 initramfs 的 hook 名
# ---------------------------------------------------------------

# ---- 1. 必须是 root ----
# id -u 返回当前用户 ID；root 是 0。不是 0 就提示用 sudo 并退出。
if [ "$(id -u)" -ne 0 ]; then
  echo "Error: please run with sudo.  e.g.  sudo bash install.sh" >&2
  exit 1
fi

# ---- 2. 源 .aml 必须存在 ----
# -f 判断「是文件且存在」；不存在就报错退出，别让后面 cp 报一堆噪音。
if [ ! -f "$SRC" ]; then
  echo "Error: dsdt.aml not found at: $SRC" >&2
  echo "Pass the path explicitly, e.g.:  sudo bash install.sh /path/to/dsdt.aml" >&2
  exit 1
fi

# ---- 3. 复制 .aml 到 initramfs 覆盖目录 ----
echo "[1/3] Copying dsdt.aml -> ${OVERRIDE_DIR}/ ..."
mkdir -p "$OVERRIDE_DIR"        # -p：目标目录已存在也不报错（相当于「确保存在」）
cp -v "$SRC" "$OVERRIDE_DIR/dsdt.aml"   # -v：verbose，打印它复制了哪个文件

# ---- 4. 确保 mkinitcpio 配置里启用了 acpi_override hook ----
echo "[2/3] Checking mkinitcpio HOOKS ..."

# 收集所有可能写 HOOKS= 的配置文件：主配置 + /etc/mkinitcpio.conf.d/ 下的分片。
# 有的发行版会把 hooks 拆成小文件放在 conf.d 里，所以要都检查一遍。
CONF_FILES=("$MKINITCPIO_CONF")
for f in /etc/mkinitcpio.conf.d/*.conf; do
  [ -f "$f" ] && CONF_FILES+=("$f")
done

# grep 参数说明:
#   -q : quiet，只问「有没有」，不打印内容
#   -E : 用扩展正则（支持 \b 这种）
#   2>/dev/null : 文件读不了(如没权限)时的报错丢进黑洞，别刷屏
#   正则含义: ^\s*HOOKS=.*\bacpi_override\b
#     ^\s*       行首可能有空格
#     HOOKS=     以 HOOKS= 开头
#     .*         后面任意内容
#     \bacpi_override\b  出现独立的单词 acpi_override（\b=词边界，避免匹配到别的词）
HOOK_OK=0
for f in "${CONF_FILES[@]}"; do
  if grep -qE '^\s*HOOKS=.*\bacpi_override\b' "$f" 2>/dev/null; then
    echo "  [OK] $f already has ${HOOK_NAME}"
    HOOK_OK=1
    break
  fi
done

# 若上面全都没找到，就在第一个带 HOOKS=( 的配置文件里插入
if [ "$HOOK_OK" -ne 1 ]; then
  INSERTED=0
  for f in "${CONF_FILES[@]}"; do
    if grep -qE '^\s*HOOKS=\(' "$f" 2>/dev/null; then
      # sed 是流编辑器; 参数说明:
      #   -i : in-place，直接改写原文件
      #   -E : 扩展正则
      #   s/正则/替换/  : 把匹配到的那段换成替换内容
      # 正则: ^(HOOKS=\([^)]*\bbase)\b
      #   ^          行首
      #   \(         字面左括号（HOOKS=( 的括号）
      #   [^)]*      任意不是右括号的字符（即括号里的全部内容）
      #   \bbase     其中出现的单词 base
      # 替换: \1 acpi_override  => 保留括号内到 base 为止的部分，再在后面加 hook 名
      # 效果: HOOKS=(base ...)  ->  HOOKS=(base acpi_override ...)
      # 注: base 必须是 Arch 系默认的第一个 hook，hook 顺序很重要，acpi_override 要尽量靠前
      sed -i -E 's/^(HOOKS=\([^)]*\bbase)\b/\1 '"${HOOK_NAME}"'/' "$f"
      echo "  [OK] Inserted ${HOOK_NAME} right after 'base' in: $f"
      INSERTED=1
      break
    fi
  done
  if [ "$INSERTED" -ne 1 ]; then
    echo "  [WARN] Could not find a HOOKS=(...) line automatically." >&2
    echo "         Please add '${HOOK_NAME}' to HOOKS manually, then re-run." >&2
  fi
fi

# ---- 5. 重建 initramfs ----
echo "[3/3] Rebuilding initramfs ..."
# CachyOS 配 Limine 引导器时用 limine-mkinitcpio（它会弹出 Y/N 让你选要重建哪个内核）。
# 注意: 不要给它喂 </dev/null —— 它需要交互输入，我们要保留终端，让用户自己敲 Y。
if command -v limine-mkinitcpio >/dev/null 2>&1; then
  # command -v: 检查系统里有没有这个命令
  limine-mkinitcpio
else
  # 没有 limine-mkinitcpio 就退回标准 mkinitcpio
  # -P : 重建「所有预设」，即 /etc/mkinitcpio.d/ 里每个 .preset 都建一遍
  mkinitcpio -P
fi

echo ""
echo "Done. You can reboot now (do NOT use acpi=off / noapic)."
echo "After reboot, verify with:"
echo "  dmesg | grep -i override             # expect: DSDT override applied + kernel tainted"
echo "  dmesg | grep -i AE_AML_OPERAND_TYPE  # expect: no output"
