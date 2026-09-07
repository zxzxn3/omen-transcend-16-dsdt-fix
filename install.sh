#!/usr/bin/env bash
# =====================================================================
# HP OMEN Transcend 16 (board 8C4D / u1xxx) — DSDT override installer
#
# 用法:   sudo bash install.sh [选项] [dsdt.aml 的路径或 URL]
#        -f, --force        别拦也别问：跳过「显式参数与本机不符」软警告，且跳过交互确认
#        --rebuild          即使 .aml 未变化也强制重建 initramfs（恢复上次可能没建成的状态）
#        --board <板号>     官方下拉补丁时指定板号（如 8C4D）
#        --bios  <版本>     官方下拉补丁时指定 BIOS（如 F.29）
#        -h, --help         显示英文帮助
#        --                 其后的参数一律视为 .aml 路径
# 退出码: 0 成功 / 1 运行错误（找不到补丁/下载失败/校验失败/重建失败）/ 2 用法错误
# 来源:   --board/--bios 必须成对给（都给出 或 都不给）。
#         给了路径/URL 且没给 board/bios → 直接当 .aml 用（可能自编译补丁，责任在用户）。
#         给了路径/URL 且给了 board/bios → 把它当 repo 根/镜像（本地 clone 或镜像 URL）拉补丁。
#         没给路径/URL → 官方 repo；board/bios 显式或按本机 DMI 自动检测。
#         未收录 → 打印该源 index.md 的可用补丁表并退出，让你显式给对参数。
# 结构:   补丁按 dsdt-fix/<board>/<bios>/dsdt.aml 组织；可用清单见各源根下的 index.md。
# 一行安装（在 CachyOS 上，自动检测 DMI 并拉取对应补丁）：
#   curl -fsSL https://raw.githubusercontent.com/zxzxn3/omen-transcend-16-dsdt-fix/main/install.sh | sudo bash
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
#   - 标志类：-f/--force、--rebuild、-h/--help
#   - 带值类：--board <板号>、--bios <BIOS>（官方下拉补丁时用；支持 --opt=值 写法）
#   - -- 终止选项解析：其后一律视为操作数
#   - 操作数至多一个 = dsdt.aml 路径或 URL
FORCE=0
REBUILD=0
BOARD=""
BIOS=""
SRC=""

show_usage() {
  cat <<'EOF'
Usage: sudo bash install.sh [OPTIONS] [dsdt.aml PATH or URL]

Options:
  -f, --force      Do not stop or ask: skip the machine-match soft warning and
                   the interactive confirmation before applying/rebuilding.
      --rebuild     Force an initramfs rebuild even if the override is unchanged
                   (use to recover when a previous run may not have finished).
      --board ID    Board id for the official download (e.g. 8C4D).
      --bios VER    BIOS version for the official download (e.g. F.29).
  -h, --help       Show this help and exit.
  --               Treat all remaining arguments as the .aml operand.

Operand (at most one):
  - Without --board/--bios: a dsdt.aml local path or URL, used as-is with no
    checks (it may be a self-built patch).
  - With --board/--bios: a repo base (a local clone directory or an http(s)
    mirror root) from which dsdt-fix/<board>/<bios>/dsdt.aml is taken,
    instead of the GitHub repo.
  - Omitted: the patch is pulled from the GitHub repo as
    dsdt-fix/<board>/<bios>/dsdt.aml, using --board/--bios or the machine DMI.

Available patches are listed in the dsdt-fix/index.md of the repo base.

Exit status:
  0  success
  1  runtime error (e.g. patch not found, download failed)
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
    --board)
      [ "$#" -ge 2 ] || usage_err "--board needs a value (e.g. --board 8C4D)"
      BOARD="$2"; shift 2 ;;
    --board=*)  BOARD="${1#*=}"; shift ;;
    --bios)
      [ "$#" -ge 2 ] || usage_err "--bios needs a value (e.g. --bios F.29)"
      BIOS="$2"; shift 2 ;;
    --bios=*)   BIOS="${1#*=}"; shift ;;
    -h|--help)  show_usage; exit 0 ;;
    --)         shift; break ;;      # 其后全部视为操作数
    -*)         usage_err "unknown option: $1" ;;
    *)          break ;;             # 第一个操作数 → 停止收选项
  esac
done

# 剩余全是操作数；只允许一个
if [ "$#" -gt 1 ]; then
  usage_err "too many arguments: only one operand allowed"
fi
[ "$#" -eq 1 ] && SRC="$1"

# --board/--bios 必须成对：都给出（本地/URL 当 repo 根用）或都不给（直接 .aml / DMI 自动）
if { [ -n "$BOARD" ] || [ -n "$BIOS" ]; } && { [ -z "$BOARD" ] || [ -z "$BIOS" ]; }; then
  usage_err "--board and --bios must be given together (both or neither)"
fi

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

# ---- 2. 来源解析 ----
# 三种情况：
#  A) 给了路径/URL 且没给 board/bios → 直接把它当 .aml 装（不判断，可能自编译补丁）。
#  B) 给了路径/URL 且给了 board+bios → 把它当 repo 根/镜像（本地 clone 或 http(s) 基址），
#     从中拉 dsdt-fix/<board>/<bios>/dsdt.aml —— 相当于换了 raw_base。
#  C) 没给路径/URL → 用官方 repo（RAW_BASE），board/bios 显式或按本机 DMI 自动检测。
# B/C 未收录 → 打印该源的可用补丁表（解析 index.md 表格）并退出，绝不自动回退。
if [ -n "$SRC" ] && [ -z "$BOARD" ] && [ -z "$BIOS" ]; then
  # A) 直接模式
  echo "Using user-provided dsdt.aml: $SRC (no checks; assumed correct by user)."
else
  # B/C) repo 模式
  if ! command -v curl >/dev/null 2>&1; then
    echo "Error: downloading patches requires 'curl' (sudo pacman -S curl)." >&2
    exit 1
  fi
  # 源：给了路径/URL 就当作 repo 根/镜像；否则官方 RAW_BASE
  BASE="$SRC"
  [ -n "$BASE" ] || BASE="$RAW_BASE"
  BASE_LOCAL=0
  if [[ "$BASE" == http://* || "$BASE" == https://* ]]; then BASE_LOCAL=0; else BASE_LOCAL=1; fi

  # 确定 board/bios：显式 > DMI 自动
  SYS_DMI="/sys/class/dmi/id"
  DETECTED_BOARD="$(cat "$SYS_DMI/board_name" 2>/dev/null | xargs 2>/dev/null || true)"
  DETECTED_BIOS="$(cat "$SYS_DMI/bios_version" 2>/dev/null | xargs 2>/dev/null || true)"
  USES_EXPLICIT=0
  if [ -n "$BOARD" ]; then
    USES_EXPLICIT=1
  elif [ -z "$DETECTED_BOARD" ] || [ -z "$DETECTED_BIOS" ]; then
    echo "Error: could not detect board/BIOS from this machine; pass --board and --bios." >&2
    exit 1
  else
    BOARD="$DETECTED_BOARD"; BIOS="$DETECTED_BIOS"
  fi
  if [ "$USES_EXPLICIT" -eq 1 ]; then
    echo "Patch target: board=${BOARD} BIOS=${BIOS} (explicit)"
  else
    echo "Patch target: board=${BOARD} BIOS=${BIOS} (auto-detected from this machine)"
  fi
  [ "$BASE_LOCAL" -eq 1 ] && echo "Repo base (local): $BASE"

  # 探测补丁是否存在
  PATCH_REL="dsdt-fix/${BOARD}/${BIOS}/dsdt.aml"
  FOUND=0
  if [ "$BASE_LOCAL" -eq 1 ]; then
    [ -f "${BASE%/}/$PATCH_REL" ] && FOUND=1
  else
    [ "$(curl -s -o /dev/null -w '%{http_code}' "${BASE%/}/$PATCH_REL" || true)" = "200" ] && FOUND=1
  fi

  if [ "$FOUND" -eq 1 ]; then
    # 显式参数且与本机 DMI 不符 → 软警告（默认保守：交互询问/非交互中止，-f 放行）
    if [ "$USES_EXPLICIT" -eq 1 ] \
       && [ -n "$DETECTED_BOARD$DETECTED_BIOS" ] \
       && { [ "$BOARD" != "$DETECTED_BOARD" ] || [ "$BIOS" != "$DETECTED_BIOS" ]; }; then
      echo "  [WARN] You requested ${BOARD}/${BIOS}, but this machine reports ${DETECTED_BOARD}/${DETECTED_BIOS}." >&2
      if [ "$FORCE" -ne 1 ]; then
        if [ "$INTERACTIVE" -eq 1 ]; then
          read -r -p "  Install ${BOARD}/${BIOS} anyway? [y/N] " REPLY
          case "$REPLY" in
            y|Y|yes|Yes) ;;
            *) echo "  Aborted." >&2; exit 1 ;;
          esac
        else
          echo "  Aborted: the requested patch does not match this machine (non-interactive)." >&2
          echo "         Re-run with -f/--force, or fix --board/--bios." >&2
          exit 1
        fi
      else
        echo "  [OK] Ignoring machine-match warning (-f/--force)." >&2
      fi
    fi
    SRC="${BASE%/}/$PATCH_REL"
  else
    # 未收录 → 显示该源的可用补丁（解析 index.md 表格）并退出（不自动回退）
    echo "  [WARN] No patch for board=${BOARD} BIOS=${BIOS} in this repo base." >&2
    echo "  Available patches (board | BIOS versions):"
    IDX_DATA=""
    if [ "$BASE_LOCAL" -eq 1 ]; then
      IDX_DATA="$(cat "${BASE%/}/dsdt-fix/index.md" 2>/dev/null || true)"
    else
      IDX_DATA="$(curl -fsSL "${BASE%/}/dsdt-fix/index.md" 2>/dev/null || true)"
    fi
    if [ -n "$IDX_DATA" ]; then
      printf '%s\n' "$IDX_DATA" | awk -F'|' '
        /^[[:space:]]*#/ || NF == 0 { next }
        { b=$2; v=$3; gsub(/^[[:space:]]+|[[:space:]]+$/, "", b); gsub(/^[[:space:]]+|[[:space:]]+$/, "", v) }
        v ~ /^-+$/ { next }                 # 分隔线
        v ~ /^[Bb][Ii][Oo][Ss]$/ { next }   # 表头
        b == "" || v == "" { next }
        { if (!(b in have)) { have[b]=1; order[++n]=b } a[b]=a[b] (a[b]==""?"":",") v }
        END { for (i=1;i<=n;i++) print "    " order[i] " | " a[order[i]] }
      ' || true
    else
      echo "    (could not read the patch list from this base)"
    fi
    echo "  Re-run with --board <ID> --bios <VER> matching an available patch," >&2
    echo "  or point at a specific .aml file." >&2
    exit 1
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

# 7.4 交互确认（apply 前最后的反悔点；-f 或非交互则直接放行）
if [ "$INTERACTIVE" -eq 1 ] && [ "$FORCE" -ne 1 ]; then
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
