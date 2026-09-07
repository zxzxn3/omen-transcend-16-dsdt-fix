#!/usr/bin/env bash
# =====================================================================
# HP OMEN Transcend 16 (board 8C4D / u1xxx) — DSDT override installer
#
# 用法:   sudo bash install.sh [选项] [dsdt.aml 的路径或 URL]
#        -f, --force    忽略「板号不符」警告（默认：交互询问[默认否]；非交互安全中止）
#        --rebuild      即使 .aml 未变化也强制重建 initramfs（恢复上次可能没建成的状态）
#        -h, --help     显示英文帮助
#        --            其后的参数一律视为 .aml 路径
# 退出码: 0 成功 / 1 运行错误（板号中止/下载失败/校验失败/重建失败）/ 2 用法错误
# 默认:   自动解析 .aml（优先级）：
#           1) 命令行第一个非选项参数（本地路径或 http(s):// URL）
#           2) 本脚本同目录的 dsdt.aml
#           3) 否则按「本机 BIOS 版本」自动去仓库 dsdt-fix/<BIOS>/ 下载对应版本
# 一行安装（在 CachyOS 上，无需先 clone/挂载；会自动检测 BIOS 并拉取对应补丁）：
#   curl -fsSL https://raw.githubusercontent.com/zxzxn3/omen-transcend-16-dsdt-fix/main/install.sh | sudo bash
# 板号:   期望 8C4D（OMEN Transcend 16-u1xxx）。不一致 → 软警告：交互询问（默认否）/ 非交互安全中止；-f/--force 可忽略。
# BIOS:   精确匹配 dsdt-fix/<BIOS>/；尚未收录 → [WARN] 自动回退到最近的已发布版本（FALLBACK_BIOSES）。
# 功能:   把编译好的 dsdt.aml 装进 initramfs（含 acpi_override hook），然后重建 initramfs
# 幂等:   同补丁已装 + hook 已在 → 无事可做(exit 0)；加 --rebuild 可强制重建。
# 安全:   两阶段：准备阶段不改真文件；重建前最后一刻才 apply；中断/重建失败自动还原；
#         所有中间文件退出时清理，不残留。
# 注意:   curl | bash 时 stdin 不是终端，脚本会自动退回非交互的 mkinitcpio -P。
# =====================================================================
set -euo pipefail
# set -e      : 任何一条命令失败就立即退出（避免出错后继续乱跑）
# set -u      : 用到未定义变量就报错退出（抓笔误）
# set -o pipefail : 管道里任何一环失败都算整体失败（防止 grep 失败被忽略）

# ---- 0. 常量与基本状态 ----
# 本脚本涉及的仓库信息（官方 .aml 都按 dsdt-fix/<BIOS>/dsdt.aml 组织）。
REPO_OWNER="zxzxn3"
REPO_NAME="omen-transcend-16-dsdt-fix"
REPO_BRANCH="main"
RAW_BASE="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${REPO_BRANCH}"
EXPECTED_BOARD="8C4D"            # OMEN Transcend 16-u1xxx 的板号（软警告用）

# 仓库已收录的 DSDT 版本目录（新 → 旧）。新增 dsdt-fix/<ver>/ 时，在此表最前加一项。
# 只用于「本机 BIOS 尚未收录」时自动回退到最近的已发布版本；精确匹配不依赖此表。
FALLBACK_BIOSES=("F.29")

OVERRIDE_DIR="/etc/initcpio/acpi_override"  # initramfs 里放 DSDT 覆盖文件的固定目录
MKINITCPIO_CONF="/etc/mkinitcpio.conf"       # mkinitcpio 主配置文件
HOOK_NAME="acpi_override"                    # 负责把上面的 .aml 打进 initramfs 的 hook 名

# stdin 是不是终端？决定能否交互（读键盘输入）。
if [ -t 0 ]; then INTERACTIVE=1; else INTERACTIVE=0; fi

# ---- 0.6 两阶段基础设施：暂存目录 + 窄兜底还原 + 清理 ----
# 准备阶段的所有中间物都放 $STAGE（mktemp -d），不改任何真文件；
# 只有进入 apply（覆盖真文件）之后、重建成功之前异常退出，才需要还原。
# 规则：BUILT=1 表示 initramfs 重建成功；CHANGED_AML/CONF 表示已覆盖真文件。
#       BUILT≠1 且有过覆盖 → 用 $STAGE 里的原件副本还原。
BUILT=0
CHANGED_AML=0
CHANGED_CONF=0
CONF_TARGET=""    # apply 阶段将被覆盖的 mkinitcpio 配置文件
STAGE=""          # 暂存目录（下载/副本/原件快照都放这，退出时整目录删除）

on_exit() {
  set +e
  if [ "$BUILT" -ne 1 ]; then
    if [ "$CHANGED_AML" -eq 1 ] || { [ "$CHANGED_CONF" -eq 1 ] && [ -f "$STAGE/config.orig" ]; }; then
      echo "  [WARN] Install did not finish (interrupted) — restoring previous state." >&2
      if [ "$CHANGED_AML" -eq 1 ]; then
        if [ -f "$STAGE/dsdt.orig" ]; then
          mv -f "$STAGE/dsdt.orig" "$OVERRIDE_DIR/dsdt.aml" 2>/dev/null
          echo "  [OK] Restored previous override -> $OVERRIDE_DIR/dsdt.aml" >&2
        else
          # 没有 dsdt.orig = 覆盖前本就没有 override → “原状”就是没有该文件，删除即还原
          rm -f -- "$OVERRIDE_DIR/dsdt.aml" 2>/dev/null
          rmdir "$OVERRIDE_DIR" 2>/dev/null    # 若这空目录是本次新建的，一并清掉
          echo "  [OK] Restored previous state (there was no override before)." >&2
        fi
      fi
      if [ "$CHANGED_CONF" -eq 1 ] && [ -n "$CONF_TARGET" ] && [ -f "$STAGE/config.orig" ]; then
        mv -f "$STAGE/config.orig" "$CONF_TARGET" 2>/dev/null
        echo "  [OK] Restored $CONF_TARGET (reverted HOOKS edit)" >&2
      fi
      echo "  Re-run install.sh (add --rebuild to force a rebuild) to try again." >&2
    fi
    # 清掉可能残留的同目录 .new 临时文件
    rm -f -- "$OVERRIDE_DIR/dsdt.aml.new" 2>/dev/null
    [ -n "$CONF_TARGET" ] && rm -f -- "$CONF_TARGET.new" 2>/dev/null
  fi
  # 删除整个暂存目录（下载的 aml / 各副本 / 原件快照）
  [ -n "$STAGE" ] && rm -rf -- "$STAGE"
}
trap on_exit EXIT
trap 'exit 130' INT     # Ctrl-C：先触发 on_exit（还原+清理）再退出
trap 'exit 143' TERM

# ---- 0.5 参数解析（POSIX 惯例：选项在前，操作数在后）----
#   - 长短选项：-f/--force、-h/--help；未知选项/多余操作数 → 用法错误 exit 2
#   - -- 终止选项解析：其后一律视为操作数（可安装以 - 开头的 .aml 文件）
#   - 操作数至多一个 = dsdt.aml 路径或 URL
FORCE=0
REBUILD=0
SRC=""

show_usage() {
  cat <<'EOF'
Usage: sudo bash install.sh [OPTIONS] [dsdt.aml PATH or URL]

Options:
  -f, --force   Bypass the board-mismatch safety check and force install.
      --rebuild  Force an initramfs rebuild even if the override is unchanged
                (use to recover when a previous run may not have finished).
  -h, --help    Show this help and exit.
  --            Treat all remaining arguments as the .aml operand.

Operand (at most one):
  Local path or http(s) URL of a dsdt.aml to install. When omitted, the
  script falls back to ./dsdt.aml next to itself, or auto-downloads
  dsdt-fix/<BIOS>/dsdt.aml for the detected BIOS from the GitHub repo.

Exit status:
  0  success
  1  runtime error (e.g. board check aborted, download failed)
  2  usage / argument error
EOF
}

# 用法错误：信息 + usage 打到 stderr，退出码 2（用法错误 ≠ 运行错误）。
usage_err() {
  echo "Error: $*" >&2
  echo >&2
  show_usage >&2
  exit 2
}

# 解析：选项在前；遇到第一个操作数或 -- 即停止收选项，其余都算操作数。
while [ "$#" -gt 0 ]; do
  case "$1" in
    -f|--force) FORCE=1; shift ;;
    --rebuild)  REBUILD=1; shift ;;
    -h|--help)  show_usage; exit 0 ;;
    --)         shift; break ;;      # 其后全部视为操作数
    -*)         usage_err "unknown option: $1" ;;
    *)          break ;;             # 第一个操作数 → 停止收选项
  esac
done

# 剩余全是操作数；只允许一个
if [ "$#" -gt 1 ]; then
  usage_err "too many arguments: only one dsdt.aml path/URL allowed"
fi
[ "$#" -eq 1 ] && SRC="$1"

# ---- 1. 必须是 root ----
# id -u 返回当前用户 ID；root 是 0。放在最前，别等下载/询问后才报错。
if [ "$(id -u)" -ne 0 ]; then
  echo "Error: please run with sudo." >&2
  exit 1
fi

# ---- 1.5 单实例锁 ----
# 防止两个安装器同时跑（会抢配置/抢重建）。flock 是 util-linux 自带；
# 没有 flock 或没有 /run/lock 的环境（如 Git Bash 沙箱）→ 跳过锁，功能不受影响。
if [ -d /run/lock ] && command -v flock >/dev/null 2>&1; then
  exec 9>/run/lock/dsdt-override.lock || { echo "Error: cannot open the lock file." >&2; exit 1; }
  flock -n 9 || { echo "Error: another dsdt-override install is already running." >&2; exit 1; }
fi

# ---- 2. 检测本机 板号 + BIOS 版本（sysfs，普通用户可读）----
SYS_DMI="/sys/class/dmi/id"
BOARD_NAME="$(cat "$SYS_DMI/board_name"    2>/dev/null || true)"
PRODUCT_NAME="$(cat "$SYS_DMI/product_name" 2>/dev/null || true)"
BIOS_VER="$(cat "$SYS_DMI/bios_version"    2>/dev/null || true)"
# 去掉首尾空白（xargs 无参数时就是 trim）
BOARD_NAME="$(printf '%s' "$BOARD_NAME" | xargs)"
PRODUCT_NAME="$(printf '%s' "$PRODUCT_NAME" | xargs)"
BIOS_VER="$(printf '%s' "$BIOS_VER" | xargs)"

echo "Board: ${BOARD_NAME:-?} (expected ${EXPECTED_BOARD}), BIOS: ${BIOS_VER:-?}"

# ---- 3. 板号软警告（不硬拒）----
# 板号是对的主键：不同代 Transcend 板号不同（u1=8C4D, u0=8BB3），能拦住拿错补丁。
# 检查 board_name 或 product_name 里有没有出现 8C4D。
if [ -n "$BOARD_NAME$PRODUCT_NAME" ] \
   && ! printf '%s\n%s' "$BOARD_NAME" "$PRODUCT_NAME" | grep -q "$EXPECTED_BOARD"; then
  echo "  [WARN] This machine does not look like board ${EXPECTED_BOARD} (${BOARD_NAME:-?} / ${PRODUCT_NAME:-?})." >&2
  if [ "$FORCE" -eq 1 ]; then
    echo "  [OK] Ignoring board check (-f/--force)." >&2
  elif [ "$INTERACTIVE" -eq 1 ]; then
    read -r -p "  Continue anyway? [y/N] " REPLY
    case "$REPLY" in
      y|Y|yes|Yes) ;;
      *) echo "  Aborted." >&2; exit 1 ;;
    esac
  else
    # 非交互无法征询用户 → 走保守安全路径：默认当作「否」中止；提示可加 -f/--force 忽略。
    echo "  Aborted: board check failed in non-interactive run." >&2
    echo "  Re-run with -f/--force to ignore this check." >&2
    exit 1
  fi
fi

# ${BASH_SOURCE[0]} = 本脚本路径（跨目录/各种调用都准）；cd+pwd 拿绝对路径。
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---- 4. 解析 .aml 来源 ----
if [ -n "$SRC" ]; then
  # (a) 用户显式指定（路径或 URL）—— 已在「参数解析」阶段写入 $SRC，直接用
  :
elif [ -f "$SCRIPT_DIR/dsdt.aml" ]; then
  # (b) 本脚本同目录有 dsdt.aml（clone/复制场景）→ 用它
  SRC="$SCRIPT_DIR/dsdt.aml"
else
  # (c) 官方路线：按 BIOS 自动选择 dsdt-fix/<BIOS>/dsdt.aml
  if ! command -v curl >/dev/null 2>&1; then
    echo "Error: official route requires 'curl' (sudo pacman -S curl)." >&2
    exit 1
  fi
  echo "No local dsdt.aml — auto-selecting dsdt-fix/<BIOS>/dsdt.aml from GitHub."
  # 先 HEAD 探测「本机 BIOS」的精确目录是否存在（raw 返回 200 / 404）
  EXACT_URL="$RAW_BASE/dsdt-fix/${BIOS_VER}/dsdt.aml"
  if [ "$(curl -s -o /dev/null -w '%{http_code}' "$EXACT_URL" || true)" = "200" ]; then
    SRC="$EXACT_URL"
  else
    # 本机 BIOS 尚未发布 → 自动回退到「最近的已发布版本」（FALLBACK_BIOSES 新→旧逐个 HEAD）。
    # 新增 dsdt-fix/<ver>/ 时记得把版本加进 FALLBACK_BIOSES 最前面。
    echo "  [WARN] No DSDT published yet for BIOS '${BIOS_VER}'." >&2
    FOUND_URL=""
    FOUND_VER=""
    for ver in "${FALLBACK_BIOSES[@]}"; do
      url="$RAW_BASE/dsdt-fix/${ver}/dsdt.aml"
      if [ "$(curl -s -o /dev/null -w '%{http_code}' "$url" || true)" = "200" ]; then
        FOUND_URL="$url"; FOUND_VER="$ver"
        break
      fi
    done
    if [ -n "$FOUND_URL" ]; then
      echo "  [WARN] Falling back to closest published version ${FOUND_VER}." >&2
      echo "         Want a different one? Pass an explicit .aml path/URL instead." >&2
      SRC="$FOUND_URL"
    else
      echo "  [WARN] Could not reach GitHub, or no DSDT published for this machine." >&2
      echo "         Pass an explicit .aml path/URL instead." >&2
      exit 1
    fi
  fi
fi

# ---- 5. 暂存目录 + 远程 URL 下载 ----
# 所有中间物（下载的 aml、配置副本、原件快照）都收进 $STAGE，退出时整目录删除。
STAGE="$(mktemp -d 2>/dev/null || mktemp -d /tmp/dsdt-override.XXXXXX)"
if [[ "$SRC" == http://* || "$SRC" == https://* ]]; then
  echo "[0/3] Downloading dsdt.aml from: $SRC"
  # curl 参数: -f 出错即失败  -s 静默  -S 出错仍显示  -L 跟随重定向  -o 输出到文件
  curl -fsSL "$SRC" -o "$STAGE/dl.aml" || { echo "Error: download failed: $SRC" >&2; exit 1; }
  SRC="$STAGE/dl.aml"
fi

# ---- 6. 源必须存在 且 是有效 DSDT ----
if [ ! -f "$SRC" ]; then
  echo "Error: dsdt.aml not found at: $SRC" >&2
  echo "Pass the path explicitly, e.g.:  sudo bash install.sh /path/to/dsdt.aml" >&2
  exit 1
fi
# 前 4 字节应为 "DSDT" 签名：拦住抓错的 HTML 页 / 传错文件，避免坏表进 initramfs。
if [ "$(head -c4 "$SRC" 2>/dev/null)" != "DSDT" ]; then
  echo "Error: not a valid DSDT table (missing 'DSDT' signature): $SRC" >&2
  exit 1
fi

# ---- 7. 准备（不改任何真文件）----
echo "[1/3] Preparing ..."

# 7.1 收集 mkinitcpio 配置文件 + 判断 hook 现状（只读）
CONF_FILES=("$MKINITCPIO_CONF")
for f in /etc/mkinitcpio.conf.d/*.conf; do
  [ -f "$f" ] && CONF_FILES+=("$f")
done
HOOK_OK=0
for f in "${CONF_FILES[@]}"; do
  if grep -qE '^\s*HOOKS=.*\bacpi_override\b' "$f" 2>/dev/null; then
    HOOK_OK=1
    break
  fi
done

# 7.2 幂等门：文件相同 + hook 已在 + 没要求强制重建 → 无事可做
if [ "$REBUILD" -ne 1 ] \
   && [ -f "$OVERRIDE_DIR/dsdt.aml" ] && cmp -s "$SRC" "$OVERRIDE_DIR/dsdt.aml" \
   && [ "$HOOK_OK" -eq 1 ]; then
  echo "  [OK] DSDT override already installed and up to date — nothing to do."
  exit 0
fi

# 7.3 判定要做什么
NEED_AML=1
if [ -f "$OVERRIDE_DIR/dsdt.aml" ] && cmp -s "$SRC" "$OVERRIDE_DIR/dsdt.aml"; then
  NEED_AML=0    # 文件相同（多半只是强制重建，或 hook 丢了需自愈）
fi
NEED_CONF=0
if [ "$HOOK_OK" -ne 1 ]; then
  # 补 hook：只在 $STAGE 副本上 sed + 验证，apply 时才覆盖真文件
  for f in "${CONF_FILES[@]}"; do
    if grep -qE '^\s*HOOKS=\(' "$f" 2>/dev/null; then
      cp -f "$f" "$STAGE/config.new"
      if sed -E 's/^(HOOKS=\([^)]*\bbase)\b/\1 '"${HOOK_NAME}"'/' "$STAGE/config.new" \
           > "$STAGE/config.new.tmp" \
         && mv -f "$STAGE/config.new.tmp" "$STAGE/config.new" \
         && grep -qE '^\s*HOOKS=.*\bacpi_override\b' "$STAGE/config.new"; then
        NEED_CONF=1
        CONF_TARGET="$f"
        cp -f "$f" "$STAGE/config.orig"   # 原件副本（重建失败还原用）
        echo "  [OK] Will add ${HOOK_NAME} after 'base' in: $f"
        break
      else
        echo "  [WARN] $f has HOOKS= but no 'base' to anchor on; skipped." >&2
        rm -f -- "$STAGE/config.new" "$STAGE/config.new.tmp"
      fi
    fi
  done
  if [ "$NEED_CONF" -ne 1 ]; then
    echo "Error: '${HOOK_NAME}' hook is missing and could not be added automatically." >&2
    echo "       Add it to the HOOKS line of /etc/mkinitcpio.conf manually, then re-run." >&2
    exit 1
  fi
fi

# 7.4 交互确认（apply 前最后的反悔点；非交互自动放行）
if [ "$INTERACTIVE" -eq 1 ]; then
  echo "  Plan:" >&2
  [ "$NEED_AML" -eq 1 ] && echo "    - install dsdt.aml -> $OVERRIDE_DIR/dsdt.aml" >&2
  [ "$NEED_CONF" -eq 1 ] && echo "    - add ${HOOK_NAME} hook to $CONF_TARGET" >&2
  [ "$REBUILD" -eq 1 ]   && echo "    - force rebuild initramfs" >&2
  read -r -p "  Apply these changes and rebuild now? [y/N] " REPLY
  case "$REPLY" in
    y|Y|yes|Yes) ;;
    *) echo "  Aborted (nothing was changed)." >&2; exit 1 ;;
  esac
fi

# ---- 8. apply（唯一可变窗口）：原子替换 ----
echo "[2/3] Applying changes ..."
mkdir -p "$OVERRIDE_DIR"

if [ "$NEED_AML" -eq 1 ]; then
  # 时间戳历史备份；原件副本留 $STAGE 供失败还原
  if [ -f "$OVERRIDE_DIR/dsdt.aml" ]; then
    cp -f "$OVERRIDE_DIR/dsdt.aml" "$STAGE/dsdt.orig"
    STAMP="$(date +%Y%m%d-%H%M%S)"
    cp -f "$OVERRIDE_DIR/dsdt.aml" "$OVERRIDE_DIR/dsdt.aml.bak-$STAMP"
    echo "  [OK] Previous override backed up -> dsdt.aml.bak-$STAMP"
  fi
  # 同目录写临时文件再 mv（原子 rename，避免读到半截文件）
  cp -f "$SRC" "$OVERRIDE_DIR/dsdt.aml.new"
  mv -f "$OVERRIDE_DIR/dsdt.aml.new" "$OVERRIDE_DIR/dsdt.aml"
  CHANGED_AML=1
  echo "  [OK] Installed -> $OVERRIDE_DIR/dsdt.aml"
else
  echo "  [OK] dsdt.aml unchanged (already the target version)."
fi

if [ "$NEED_CONF" -eq 1 ]; then
  cp -f "$STAGE/config.new" "$CONF_TARGET.new"
  mv -f "$CONF_TARGET.new" "$CONF_TARGET"
  CHANGED_CONF=1
  echo "  [OK] Added ${HOOK_NAME} right after 'base' in: $CONF_TARGET"
fi

# ---- 9. 重建 initramfs ----
echo "[3/3] Rebuilding initramfs ..."
# 交互(有终端)且有 limine-mkinitcpio → 用它（会弹 Y/N 选内核）；否则 mkinitcpio -P。
if [ "$INTERACTIVE" -eq 1 ] && command -v limine-mkinitcpio >/dev/null 2>&1; then
  limine-mkinitcpio || { echo "Error: initramfs rebuild failed." >&2; exit 1; }
else
  mkinitcpio -P || { echo "Error: initramfs rebuild failed." >&2; exit 1; }
fi
BUILT=1   # 重建成功 → 标记完成；重建失败会 exit → on_exit 用 $STAGE 原件还原

echo ""
echo "Done. You can reboot now without acpi=off / noapic."
echo "After reboot, verify with:"
echo '  dmesg | grep -iE "override|taint"   # expect: DSDT override applied / kernel tainted'
echo '  dmesg | grep -i AE_AML_OPERAND_TYPE # expect: no output'
