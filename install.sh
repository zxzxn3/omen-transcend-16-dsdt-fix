#!/usr/bin/env bash
# =====================================================================
# DSDT override installer
#
# Usage:   sudo bash install.sh [options] [path or URL to dsdt.aml]
#        -f, --force        Do not ask and do not stop: skip the soft warning about explicit parameters not matching the local machine, and skip interactive confirmation
#        --rebuild          Force rebuild of initramfs even if .aml has not changed
#        --target <board/BIOS> Specify the target when pulling official patches, consistent with the dsdt-fix/<target>/ directory (e.g., 8C4D/F.29)
#        -h, --help         Show English help
#        --                 其后的参数一律视为 .aml 路径
# 退出码: 0 成功 / 1 运行错误（找不到补丁/下载失败/校验失败/重建失败）/ 2 用法错误
# 来源:   --target 可选；给了就显式指定，不给就按本机 DMI 自动检测（target=<board>/<bios>）。
#         给了路径/URL 且没给 --target → 直接当 .aml 用（可能自编译补丁，责任在用户）。
#         给了路径/URL 且给了 --target → 把它当 repo 根/镜像（本地 clone 或镜像 URL）拉补丁。
#         没给路径/URL → 官方 repo；--target 显式或按本机 DMI 自动检测。
#         未收录 → 打印该源 index.md 的可用 --target 清单并退出，绝不自动回退。
# 结构:   补丁按 dsdt-fix/<target>/dsdt.aml（如 dsdt-fix/8C4D/F.29/）组织；可用清单见各源根 index.md。
# 一行安装（在 CachyOS 上，自动检测 DMI 并拉取对应补丁）：
#   curl -fsSL https://raw.githubusercontent.com/zxzxn3/omen-transcend-16-dsdt-fix/main/install.sh | sudo bash
# 功能:   把编译好的 dsdt.aml 装进 initramfs（含 acpi_override hook），然后重建 initramfs
# 幂等:   同补丁已装 + hook 已在 → 无事可做(exit 0)；加 --rebuild 可强制重建。
# 安全:   两阶段：准备阶段不改真文件；重建前最后一刻才 apply；中断/重建失败自动还原；
#         所有中间文件退出时清理，不残留。
# 注意:   重建优先用 CachyOS 的 limine-mkinitcpio（无终端也安全），否则 mkinitcpio -P；
#         重建后自动校验 override 是否真的进了 initramfs（lsinitcpio --early）。
# =====================================================================
set -euo pipefail
# set -e      : 任何一条命令失败就立即退出（避免出错后继续乱跑）
# set -u      : 用到未定义变量就报错退出（抓笔误）
# set -o pipefail : 管道里任何一环失败都算整体失败（防止 grep 失败被忽略）

# ---- 0. 常量与基本状态 ----
# 本脚本涉及的仓库信息（官方 .aml 都按 dsdt-fix/<target>/dsdt.aml 组织，如 dsdt-fix/8C4D/F.29/）。
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
      echo "  Re-run install.sh to try again." >&2
      echo "  Note: if some kernels were rebuilt before the failure, re-run once so all are consistent." >&2
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
#   - 带值类：--target <board>/<bios>（官方下拉补丁时用；支持 --target=<值> 写法）
#   - -- 终止选项解析：其后一律视为操作数
#   - 操作数至多一个 = dsdt.aml 路径或 URL
FORCE=0
REBUILD=0
TARGET=""   # 形如 <board>/<bios>（如 8C4D/F.29），对应 dsdt-fix/<target>/；空 = 按 DMI 自动
SRC=""

show_usage() {
  cat <<'EOF'
Usage: sudo bash install.sh [OPTIONS] [dsdt.aml PATH or URL]

Options:
  -f, --force      Do not stop or ask: skip the machine-match soft warning and
                   the interactive confirmation before applying/rebuilding.
      --rebuild     Force an initramfs rebuild even if the override is unchanged.
      --target ID   Board/BIOS for the official download, exactly as it appears
                   in the dsdt-fix/<board>/<bios>/ tree (e.g. 8C4D/F.29).
  -h, --help       Show this help and exit.
  --               Treat all remaining arguments as the .aml operand.

Operand (at most one):
  - Without --target: a dsdt.aml local path or URL, used as-is with no checks
    (it may be a self-built patch).
  - With --target: a repo base (a local clone directory or an http(s) mirror
    root) from which dsdt-fix/<target>/dsdt.aml is taken, instead of the
    GitHub repo.
  - Omitted: the patch is pulled from the GitHub repo as
    dsdt-fix/<target>/dsdt.aml, using --target or the machine DMI.

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
    --target)
      [ "$#" -ge 2 ] || usage_err "--target needs a value (e.g. --target 8C4D/F.29)"
      TARGET="$2"; shift 2 ;;
    --target=*) TARGET="${1#*=}"; shift ;;
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

# --target 格式必须 <board>/<bios>（与 dsdt-fix/<target>/ 目录一致）；非空且不合规 → 用法错误
if [ -n "$TARGET" ] && ! printf '%s' "$TARGET" | grep -qE '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'; then
  usage_err "--target must look like '<board>/<bios>', e.g. 8C4D/F.29 (got: $TARGET)"
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
#  A) 给了路径/URL 且没给 --target → 直接把它当 .aml 装（不判断，可能自编译补丁）。
#  B) 给了路径/URL 且给了 --target → 把它当 repo 根/镜像（本地 clone 或 http(s) 基址），
#     从中拉 dsdt-fix/<target>/dsdt.aml —— 相当于换了 raw_base。
#  C) 没给路径/URL → 用官方 repo（RAW_BASE），--target 显式或按本机 DMI 自动检测。
# B/C 未收录 → 打印该源可用 --target 清单（解析 index.md）并退出，绝不自动回退。
if [ -n "$SRC" ] && [ -z "$TARGET" ]; then
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

  # 确定 target：显式 > DMI 自动（target=<board>/<bios>，与 dsdt-fix/<target>/ 目录一致）
  SYS_DMI="/sys/class/dmi/id"
  DETECTED_BOARD="$(cat "$SYS_DMI/board_name" 2>/dev/null | xargs 2>/dev/null || true)"
  DETECTED_BIOS="$(cat "$SYS_DMI/bios_version" 2>/dev/null | xargs 2>/dev/null || true)"
  USES_EXPLICIT=0
  if [ -n "$TARGET" ]; then
    USES_EXPLICIT=1
  elif [ -z "$DETECTED_BOARD" ] || [ -z "$DETECTED_BIOS" ]; then
    echo "Error: could not detect board/BIOS from this machine; pass --target <board>/<bios>." >&2
    exit 1
  else
    TARGET="${DETECTED_BOARD}/${DETECTED_BIOS}"
  fi
  if [ "$USES_EXPLICIT" -eq 1 ]; then
    echo "Patch target: $TARGET (explicit)"
  else
    echo "Patch target: $TARGET (auto-detected from this machine)"
  fi
  [ "$BASE_LOCAL" -eq 1 ] && echo "Repo base (local): $BASE"

  # 探测补丁是否存在
  PATCH_REL="dsdt-fix/${TARGET}/dsdt.aml"
  FOUND=0
  if [ "$BASE_LOCAL" -eq 1 ]; then
    [ -f "${BASE%/}/$PATCH_REL" ] && FOUND=1
  else
    [ "$(curl -s -o /dev/null -w '%{http_code}' "${BASE%/}/$PATCH_REL" || true)" = "200" ] && FOUND=1
  fi

  if [ "$FOUND" -eq 1 ]; then
    # 显式 target 且与本机 DMI 不符 → 软警告（默认保守：交互询问/非交互中止，-f 放行）
    if [ "$USES_EXPLICIT" -eq 1 ] \
       && [ -n "$DETECTED_BOARD$DETECTED_BIOS" ] \
       && [ "$TARGET" != "${DETECTED_BOARD}/${DETECTED_BIOS}" ]; then
      echo "  [WARN] You requested $TARGET, but this machine reports ${DETECTED_BOARD}/${DETECTED_BIOS}." >&2
      if [ "$FORCE" -ne 1 ]; then
        if [ "$INTERACTIVE" -eq 1 ]; then
          read -r -p "  Install $TARGET anyway? [y/N] " REPLY
          case "$REPLY" in
            y|Y|yes|Yes) ;;
            *) echo "  Aborted." >&2; exit 1 ;;
          esac
        else
          echo "  Aborted: the requested patch does not match this machine (non-interactive)." >&2
          echo "         Re-run with -f/--force, or fix --target." >&2
          exit 1
        fi
      else
        echo "  [OK] Ignoring machine-match warning (-f/--force)." >&2
      fi
    fi
    SRC="${BASE%/}/$PATCH_REL"
  else
    # 未收录 → 显示该源可用 --target 清单（index.md 中每个 <board>/<bios>）并退出（不自动回退）
    echo "  [WARN] No patch for target '$TARGET' in this repo base." >&2
    echo "  Available patches (--target values):"
    IDX_DATA=""
    if [ "$BASE_LOCAL" -eq 1 ]; then
      IDX_DATA="$(cat "${BASE%/}/dsdt-fix/index.md" 2>/dev/null || true)"
    else
      IDX_DATA="$(curl -fsSL "${BASE%/}/dsdt-fix/index.md" 2>/dev/null || true)"
    fi
    if [ -n "$IDX_DATA" ]; then
      # 只取形如 <board>/<bios> 的单元格：表头/分隔线/正文因不是完整键而被跳过
      printf '%s\n' "$IDX_DATA" | awk -F'|' '
        { c=$2; gsub(/^[[:space:]]+|[[:space:]]+$/, "", c) }
        c ~ /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/ { print "    " c }
      ' || true
    else
      echo "    (could not read the patch list from this base)"
    fi
    echo "  Re-run with --target matching an available patch (e.g. --target 8C4D/F.29)," >&2
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

# 7.1 收集配置文件 + 判断 hook 现状（只读）
# 只自动改主 /etc/mkinitcpio.conf；若 HOOKS 只写在 .d 片段里 → 明确报错让用户手动。
CONF_FILES=("$MKINITCPIO_CONF")
for f in /etc/mkinitcpio.conf.d/*.conf; do
  [ -f "$f" ] && CONF_FILES+=("$f")
done
HOOK_OK=0
MAIN_HAS_HOOKS=0
for f in "${CONF_FILES[@]}"; do
  if grep -qE '^\s*HOOKS=.*\bacpi_override\b' "$f" 2>/dev/null; then
    HOOK_OK=1
    break
  fi
done
grep -qE '^\s*HOOKS=\(' "$MKINITCPIO_CONF" 2>/dev/null && MAIN_HAS_HOOKS=1

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
  # 补 hook：只在 $STAGE 副本上 sed + 验证，apply 时才覆盖真文件（只自动改主配置文件）
  if [ "$MAIN_HAS_HOOKS" -ne 1 ]; then
    echo "Error: HOOKS is not defined in $MKINITCPIO_CONF (only in a .d fragment)." >&2
    echo "       Add '${HOOK_NAME}' to that fragment's HOOKS line manually, then re-run." >&2
    exit 1
  fi
  cp -f "$MKINITCPIO_CONF" "$STAGE/config.new"
  if sed -E 's/^(HOOKS=\([^)]*\bbase)\b/\1 '"${HOOK_NAME}"'/' "$STAGE/config.new" \
       > "$STAGE/config.new.tmp" \
     && mv -f "$STAGE/config.new.tmp" "$STAGE/config.new" \
     && bash -n "$STAGE/config.new" 2>/dev/null \
     && grep -qE '^\s*HOOKS=\([^)]*\bacpi_override\b' "$STAGE/config.new"; then
    NEED_CONF=1
    CONF_TARGET="$MKINITCPIO_CONF"
    cp -f "$MKINITCPIO_CONF" "$STAGE/config.orig"   # 原件副本（重建失败还原用）
    echo "  [OK] Will add ${HOOK_NAME} after 'base' in: $MKINITCPIO_CONF"
  else
    echo "Error: could not add '${HOOK_NAME}' into the HOOKS= list of $MKINITCPIO_CONF" >&2
    echo "       (no 'base' anchor, or the edited config failed to parse/validate)." >&2
    echo "       Add it to the HOOKS line manually, then re-run." >&2
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
# CachyOS 的 limine-mkinitcpio = 重建 initramfs + 用 limine-entry-tool 刷新 Limine 启动条目
# （/etc/default/limine -> /boot/limine.conf）。它由 pacman hook 在无终端场景调用，非交互安全，
# 所以只要装了就用它（与有无终端无关）；否则退回 mkinitcpio -P。
if command -v limine-mkinitcpio >/dev/null 2>&1; then
  limine-mkinitcpio || { echo "Error: initramfs rebuild failed." >&2; exit 1; }
else
  mkinitcpio -P || { echo "Error: initramfs rebuild failed." >&2; exit 1; }
fi

# ---- 9.5 校验 override 真的进了重建出的 initramfs ----
# acpi_override hook 用 add_file_early 把 .aml 放进镜像内早期无压缩 cpio 的
# kernel/firmware/acpi/dsdt.aml；镜像路径从 /etc/mkinitcpio.d/*.preset 解析
# （mkinitcpio 与 limine-entry-tool 用的是同一来源）。
preset_images() {
  local preset p img
  for preset in /etc/mkinitcpio.d/*.preset; do
    [ -f "$preset" ] || continue
    (
      set +u
      # shellcheck disable=SC1090
      . "$preset" 2>/dev/null || true
      for p in ${PRESETS[@]:-}; do
        eval "img=\${${p}_image:-}"; [ -n "$img" ] && printf '%s\n' "$img"
        eval "img=\${${p}_uki:-}";   [ -n "$img" ] && printf '%s\n' "$img"
      done
    )
  done
}

VERIFIED_IMGS=0
MISSING_IMGS=0
if command -v lsinitcpio >/dev/null 2>&1; then
  while IFS= read -r img; do
    [ -f "$img" ] || continue
    if lsinitcpio --early "$img" 2>/dev/null | grep -qx 'kernel/firmware/acpi/dsdt.aml'; then
      VERIFIED_IMGS=$((VERIFIED_IMGS+1))
      echo "  [OK] Override verified inside: $img"
    else
      MISSING_IMGS=$((MISSING_IMGS+1))
      echo "  [WARN] Override NOT found inside: $img" >&2
    fi
  done < <(preset_images)
  # 确实查过 >=1 个镜像、却一个都不含 override → 硬失败（触发还原），别假装成功
  if [ "$MISSING_IMGS" -gt 0 ] && [ "$VERIFIED_IMGS" -eq 0 ]; then
    echo "Error: rebuilt initramfs does not contain the DSDT override (hook inactive)." >&2
    echo "       Rolling back; check HOOKS and ${OVERRIDE_DIR}/ then re-run." >&2
    exit 1
  fi
  if [ "$VERIFIED_IMGS" -eq 0 ]; then
    echo "  [WARN] No built initramfs found to verify automatically; check manually:" >&2
    echo '         lsinitcpio --early <image> | grep kernel/firmware/acpi/dsdt.aml' >&2
  fi
else
  echo "  [WARN] lsinitcpio not found; skipping initramfs content verification." >&2
fi
BUILT=1   # 重建成功且（可验证时）确认 override 已进镜像 → 标记完成；此前的失败 exit 均由 on_exit 还原

echo ""
echo "Install complete. Before rebooting:"
echo "  1. Confirm the override is inside the initramfs (done above when possible), e.g.:"
echo '       lsinitcpio --early /boot/<image> | grep kernel/firmware/acpi/dsdt.aml'
echo "  2. Remove 'acpi=off' from the kernel cmdline (CachyOS: /etc/default/limine, then"
echo "     re-run 'sudo limine-mkinitcpio'). You may KEEP 'noapic' for this first boot as a"
echo "     safety margin (noapic does not disable ACPI, so the override still applies)."
echo "  3. Reboot and verify the override is actually active:"
echo '       dmesg | grep -i "ACPI: Override"      # expect: DSDT ... this is unsafe: tainting kernel'
echo '       dmesg | grep -i AE_AML_OPERAND_TYPE   # expect: no output'
echo "       (built-in speakers should also work)"
echo "  4. Only after those pass, also remove 'noapic'."
echo "If booting without acpi=off fails, restore acpi=off noapic and roll back:"
echo "  remove ${OVERRIDE_DIR}/dsdt.aml, drop '${HOOK_NAME}' from HOOKS in $MKINITCPIO_CONF,"
echo "  then 'sudo mkinitcpio -P'. A pre-change copy is kept as dsdt.aml.bak-<timestamp>."
echo ""
echo "Made your own DSDT fix (or for a sibling board)? Share it back via a PR/issue:"
echo "  https://github.com/zxzxn3/omen-transcend-16-dsdt-fix"
echo "  (layout: dsdt-fix/<board>/<bios>/dsdt.aml + a row in dsdt-fix/index.md)"
