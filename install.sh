#!/usr/bin/env bash
# =====================================================================
# HP OMEN Transcend 16 (board 8C4D / u1xxx) — DSDT override installer
#
# 用法:   sudo bash install.sh [选项] [dsdt.aml 的路径或 URL]
#        -f, --force   忽略「板号不符」警告（默认：交互询问[默认否]；非交互安全中止）
#        -h, --help    显示英文帮助
#        --           其后的参数一律视为 .aml 路径
# 退出码: 0 成功 / 1 运行错误（如板号中止/下载失败）/ 2 用法错误
# 默认:   自动解析 .aml（优先级）：
#           1) 命令行第一个非选项参数（本地路径或 http(s):// URL）
#           2) 本脚本同目录的 dsdt.aml
#           3) 否则按「本机 BIOS 版本」自动去仓库 dsdt-fix/<BIOS>/ 下载对应版本
# 一行安装（在 CachyOS 上，无需先 clone/挂载；会自动检测 BIOS 并拉取对应补丁）：
#   curl -fsSL https://raw.githubusercontent.com/zxzxn3/omen-transcend-16-u1024tx-f29-dsdt-fix/main/install.sh | sudo bash
# 板号:   期望 8C4D（OMEN Transcend 16-u1xxx）。不一致 → 软警告：交互询问（默认否）/ 非交互安全中止；-f/--force 可忽略。
# BIOS:   无精确匹配时，主动查询仓库里已有的版本让你挑（交互）；非交互则报错并列出可选版本。
# 功能:   把编译好的 dsdt.aml 装进 initramfs（含 acpi_override hook），然后重建 initramfs
# 幂等:   可重复运行，不会重复插入 hook；同一份 .aml 已装则跳过。
# 安全:   复制/改配置后若中途退出（报错/Ctrl-C），自动回滚到改动前状态。
# 注意:   curl | bash 时 stdin 不是终端，脚本会自动退回非交互的 mkinitcpio -P。
# =====================================================================
set -euo pipefail
# set -e      : 任何一条命令失败就立即退出（避免出错后继续乱跑）
# set -u      : 用到未定义变量就报错退出（抓笔误）
# set -o pipefail : 管道里任何一环失败都算整体失败（防止 grep 失败被忽略）

# ---- 0. 常量与基本状态 ----
# 本脚本涉及的仓库信息（官方 .aml 都按 dsdt-fix/<BIOS>/dsdt.aml 组织）。
REPO_OWNER="zxzxn3"
REPO_NAME="omen-transcend-16-u1024tx-f29-dsdt-fix"
REPO_BRANCH="main"
RAW_BASE="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${REPO_BRANCH}"
# GitHub API：列出 dsdt-fix/ 下有哪些版本目录（用于「无精确匹配时让用户挑」）
API_DIR="https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/contents/dsdt-fix"
EXPECTED_BOARD="8C4D"            # OMEN Transcend 16-u1xxx 的板号（软警告用）

OVERRIDE_DIR="/etc/initcpio/acpi_override"  # initramfs 里放 DSDT 覆盖文件的固定目录
MKINITCPIO_CONF="/etc/mkinitcpio.conf"       # mkinitcpio 主配置文件
HOOK_NAME="acpi_override"                    # 负责把上面的 .aml 打进 initramfs 的 hook 名

# stdin 是不是终端？决定能否交互（读键盘输入）。
if [ -t 0 ]; then INTERACTIVE=1; else INTERACTIVE=0; fi

# ---- 0.6 回滚与清理 ----
# 目标：安装中途退出（报错/Ctrl-C/TERM）时，把系统还原到「改动前」，
#       避免留下「override 已复制但 initramfs 未重建」的半成品状态。
# 规则：DONE=1 表示完整成功（重建 initramfs 也成功）；
#       MUTATED=1 表示已对系统做过修改；两者缺一即视为未完成 → 回滚。
DONE=0
MUTATED=0
DIR_CREATED=0
PRIOR_AML=""    # 改动前已存在的 dsdt.aml 快照（临时副本）；空 = 原本没有
CONF_FILE=""    # 本次实际改过的 mkinitcpio 配置文件
CONF_SNAP=""    # 该配置文件改前的快照
TMP_AML=""      # 下载的临时 .aml（退出时清理）

on_exit() {
  set +e
  # 1) 改了系统但没装完 → 还原
  if [ "$DONE" -ne 1 ] && [ "$MUTATED" -eq 1 ]; then
    echo "  [WARN] Install did not finish (interrupted) — restoring previous state." >&2
    if [ -n "$PRIOR_AML" ]; then
      cp -f "$PRIOR_AML" "$OVERRIDE_DIR/dsdt.aml" 2>/dev/null
      echo "  [OK] Restored previous override -> $OVERRIDE_DIR/dsdt.aml" >&2
    else
      rm -f -- "$OVERRIDE_DIR/dsdt.aml" 2>/dev/null
      echo "  [OK] Removed the copied override (there was none before)." >&2
    fi
    if [ -n "$CONF_FILE" ] && [ -n "$CONF_SNAP" ]; then
      cp -f "$CONF_SNAP" "$CONF_FILE" 2>/dev/null
      echo "  [OK] Reverted HOOKS edit in $CONF_FILE" >&2
    fi
    # 若 override 目录是我们本次新建的且已空 → 删掉
    if [ "$DIR_CREATED" -eq 1 ] && [ -d "$OVERRIDE_DIR" ]; then
      rmdir "$OVERRIDE_DIR" 2>/dev/null
    fi
    echo "  Re-run install.sh to try again." >&2
  fi
  # 2) 清理临时文件（下载的 aml / 快照）
  rm -f -- "${TMP_AML:-}" "${PRIOR_AML:-}" "${CONF_SNAP:-}"
}
trap on_exit EXIT
trap 'exit 130' INT     # Ctrl-C：先触发 on_exit 回滚再退出
trap 'exit 143' TERM

# ---- 0.5 参数解析（GNU 命令行惯例）----
# 规范遵循：
#   - 长短选项：-f/--force、-h/--help；未知选项/多余操作数 → 用法错误 exit 2
#   - 短选项可合并成簇：-fh ≡ -f -h
#   - -- 终止选项解析：其后一律视为操作数（可安装以 - 开头的 .aml 文件）
#   - 选项与操作数可混排（GNU 习惯：install.sh path.aml -f 也合法）
#   - 操作数至多一个 = dsdt.aml 路径或 URL
FORCE=0
SRC=""

show_usage() {
  cat <<'EOF'
Usage: sudo bash install.sh [OPTIONS] [dsdt.aml PATH or URL]

Options:
  -f, --force   Bypass the board-mismatch safety check and force install.
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

# GNU 风格解析：选项与操作数可混排（GNU 习惯）；`--` 之后一律视为操作数；
# 短选项支持簇（-fh ≡ -f -h）；未知选项/多余操作数 → 用法错误(exit 2)。
while [ "$#" -gt 0 ]; do
  ARG="$1"; shift
  case "$ARG" in
    --)
      # `--` 终止选项：其后所有参数（哪怕以 - 开头）都当操作数
      while [ "$#" -gt 0 ]; do
        if [ -z "$SRC" ]; then SRC="$1"; else
          usage_err "too many arguments: only one dsdt.aml path/URL allowed"
        fi
        shift
      done
      ;;
    --force|-f) FORCE=1 ;;
    --help|-h)  show_usage; exit 0 ;;
    --*)        usage_err "unknown option: $ARG" ;;
    -*)
      # 短选项簇：-fh、-f、-x…（去掉前导 - 后逐字符解析）
      CLUSTER="${ARG#-}"
      if [ -z "$CLUSTER" ]; then
        # 单独的 "-" 按惯例视为操作数
        if [ -z "$SRC" ]; then SRC="$ARG"; else
          usage_err "too many arguments: only one dsdt.aml path/URL allowed"
        fi
      else
        IDX=0
        while [ "$IDX" -lt "${#CLUSTER}" ]; do
          CH="${CLUSTER:$IDX:1}"; IDX=$((IDX+1))
          case "$CH" in
            f) FORCE=1 ;;
            h) show_usage; exit 0 ;;
            *) usage_err "unknown option: -$CH" ;;
          esac
        done
      fi
      ;;
    *)
      # 普通操作数：dsdt.aml 路径或 URL（至多一个）
      if [ -z "$SRC" ]; then SRC="$ARG"; else
        usage_err "too many arguments: only one dsdt.aml path/URL allowed"
      fi
      ;;
  esac
done

# ---- 1. 必须是 root ----
# id -u 返回当前用户 ID；root 是 0。放在最前，别等下载/询问后才报错。
if [ "$(id -u)" -ne 0 ]; then
  echo "Error: please run with sudo." >&2
  exit 1
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
    echo "  Aborted: board check failed in non-interactive run (safety default = No)." >&2
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
  OFFICIAL_URL="$RAW_BASE/dsdt-fix/${BIOS_VER}/dsdt.aml"
  # 先 HEAD 探测该精确版本是否存在（raw 返回 200 / 404）
  HTTP_CODE="$(curl -s -o /dev/null -w '%{http_code}' "$OFFICIAL_URL" || true)"
  if [ "$HTTP_CODE" = "200" ]; then
    SRC="$OFFICIAL_URL"
  else
    echo "  [WARN] No exact DSDT folder for BIOS '${BIOS_VER}' (tried dsdt-fix/${BIOS_VER}/)." >&2
    # 主动查询仓库里已有哪些版本的目录（GitHub API → python3 解析 json）
    AVAILABLE=""
    if command -v python3 >/dev/null 2>&1; then
      AVAILABLE="$(curl -fsSL "$API_DIR" 2>/dev/null | python3 -c 'import json,sys
try:
    d = json.load(sys.stdin)
    print(" ".join(e["name"] for e in d if e.get("type") == "dir"))
except Exception:
    pass' || true)"
    fi
    if [ -z "$AVAILABLE" ]; then
      echo "  [WARN] Could not list available versions (need python3 + network)." >&2
      echo "         Pass an explicit .aml path/URL instead." >&2
      exit 1
    fi
    if [ "$INTERACTIVE" -eq 1 ]; then
      echo "  Available BIOS versions in the repo:" >&2
      IDX=1
      for NAME in $AVAILABLE; do
        echo "    [$IDX] $NAME" >&2
        IDX=$((IDX+1))
      done
      echo -n "  Pick a version to install (or 0/q to abort): " >&2
      read -r CHOICE
      case "$CHOICE" in
        0|q|Q|"") echo "  Aborted." >&2; exit 1 ;;
      esac
      # 把数字映射回版本名
      IDX=1; PICKED=""
      for NAME in $AVAILABLE; do
        if [ "$CHOICE" = "$IDX" ]; then PICKED="$NAME"; fi
        IDX=$((IDX+1))
      done
      if [ -z "$PICKED" ]; then
        echo "  Invalid choice: $CHOICE" >&2
        exit 1
      fi
      SRC="$RAW_BASE/dsdt-fix/${PICKED}/dsdt.aml"
    else
      echo "  [WARN] Non-interactive: cannot prompt for a version. Available: ${AVAILABLE}" >&2
      echo "         Run interactively, or pass an explicit .aml path/URL." >&2
      exit 1
    fi
  fi
fi

# ---- 5. 远程 URL → 下载到临时文件 ----
# TMP_AML 用 trap 在退出时自动清理（curl | bash 也不残留）。
if [[ "$SRC" == http://* || "$SRC" == https://* ]]; then
  TMP_AML="$(mktemp --suffix=.aml 2>/dev/null || mktemp)"   # 退出时由 on_exit 统一清理
  echo "[0/3] Downloading dsdt.aml from: $SRC"
  # curl 参数: -f 出错即失败  -s 静默  -S 出错仍显示  -L 跟随重定向  -o 输出到文件
  curl -fsSL "$SRC" -o "$TMP_AML" || { echo "Error: download failed: $SRC" >&2; exit 1; }
  SRC="$TMP_AML"
fi

# ---- 6. 源 .aml 必须存在 ----
if [ ! -f "$SRC" ]; then
  echo "Error: dsdt.aml not found at: $SRC" >&2
  echo "Pass the path explicitly, e.g.:  sudo bash install.sh /path/to/dsdt.aml" >&2
  exit 1
fi

# ---- 7. 若已装同一份 → 跳过；否则备份旧 override + 复制新的 ----
echo "[1/3] Installing dsdt.aml ..."
if [ ! -d "$OVERRIDE_DIR" ]; then
  DIR_CREATED=1
  mkdir -p "$OVERRIDE_DIR"
fi

# cmp -s：逐字节比较。已装的就是这份 → 直接退出，省得白重建 initramfs。
if [ -f "$OVERRIDE_DIR/dsdt.aml" ] && cmp -s "$SRC" "$OVERRIDE_DIR/dsdt.aml"; then
  echo "  [OK] Installed dsdt.aml is already identical — nothing to do."
  exit 0
fi

# 改动前先存快照（供中途退出时 on_exit 还原）
if [ -f "$OVERRIDE_DIR/dsdt.aml" ]; then
  PRIOR_AML="$(mktemp 2>/dev/null || mktemp)"
  cp -f "$OVERRIDE_DIR/dsdt.aml" "$PRIOR_AML"
fi

# 覆盖前备份旧的：带时间戳、只增不滚 → 无限历史，每次只加一个新文件。
if [ -f "$OVERRIDE_DIR/dsdt.aml" ]; then
  STAMP="$(date +%Y%m%d-%H%M%S)"
  cp -f "$OVERRIDE_DIR/dsdt.aml" "$OVERRIDE_DIR/dsdt.aml.bak-$STAMP"
  echo "  [OK] Previous override backed up -> dsdt.aml.bak-$STAMP"
fi

cp -f "$SRC" "$OVERRIDE_DIR/dsdt.aml"    # 复制新 override（前面已做备份/去重）
MUTATED=1                                  # 此后若中途退出，on_exit 会回滚
echo "  [OK] Installed -> $OVERRIDE_DIR/dsdt.aml"

# ---- 8. 确保 mkinitcpio 配置里启用了 acpi_override hook ----
echo "[2/3] Checking mkinitcpio HOOKS ..."

# 收集所有可能写 HOOKS= 的配置文件：主配置 + /etc/mkinitcpio.conf.d/ 下的分片。
CONF_FILES=("$MKINITCPIO_CONF")
for f in /etc/mkinitcpio.conf.d/*.conf; do
  [ -f "$f" ] && CONF_FILES+=("$f")
done

# grep 参数说明:
#   -q : quiet  -E : 扩展正则  2>/dev/null : 没权限的报错丢进黑洞
#   正则: ^\s*HOOKS=.*\bacpi_override\b （行首可能有空格 + 内容含独立单词 acpi_override）
HOOK_OK=0
for f in "${CONF_FILES[@]}"; do
  if grep -qE '^\s*HOOKS=.*\bacpi_override\b' "$f" 2>/dev/null; then
    echo "  [OK] $f already has ${HOOK_NAME}"
    HOOK_OK=1
    break
  fi
done

# 若都没找到，在第一个带 HOOKS=( 的配置里插入到 base 之后
if [ "$HOOK_OK" -ne 1 ]; then
  INSERTED=0
  for f in "${CONF_FILES[@]}"; do
    if grep -qE '^\s*HOOKS=\(' "$f" 2>/dev/null; then
      # sed -i -E 's/^(HOOKS=\([^)]*\bbase)\b/\1 acpi_override/'  在 base 后插 hook。
      # 关键：若文件里没有 base，sed 不改动但仍返回 0（假成功），
      # 所以用「sed && 事后 grep 复查」判断是否真的插进去了。
      # 改动该配置文件前先存快照；sed 没成功则丢弃（不留无谓快照）
      CONF_SNAP_TMP="$(mktemp 2>/dev/null || mktemp)"
      cp -f "$f" "$CONF_SNAP_TMP"
      if sed -i -E 's/^(HOOKS=\([^)]*\bbase)\b/\1 '"${HOOK_NAME}"'/' "$f" \
         && grep -qE '^\s*HOOKS=.*\bacpi_override\b' "$f"; then
        CONF_FILE="$f"; CONF_SNAP="$CONF_SNAP_TMP"
        echo "  [OK] Inserted ${HOOK_NAME} right after 'base' in: $f"
        INSERTED=1
        break
      else
        rm -f -- "$CONF_SNAP_TMP"    # 没改成功 → 丢弃快照
        echo "  [WARN] $f has HOOKS= but no 'base' to anchor on; skipped." >&2
      fi
    fi
  done
  if [ "$INSERTED" -ne 1 ]; then
    echo "  [WARN] Could not add '${HOOK_NAME}' to HOOKS automatically." >&2
    echo "         Please add it to the HOOKS line manually, then re-run." >&2
  fi
fi

# ---- 9. 重建 initramfs ----
echo "[3/3] Rebuilding initramfs ..."
# 交互(有终端)且系统有 limine-mkinitcpio → 用它（会弹 Y/N 让你选内核）
# 否则（curl|bash 非交互 / 无 limine）→ mkinitcpio -P（重建所有预设，效果相同）
if [ "$INTERACTIVE" -eq 1 ] && command -v limine-mkinitcpio >/dev/null 2>&1; then
  limine-mkinitcpio
else
  mkinitcpio -P
fi || { echo "Error: initramfs rebuild failed." >&2; exit 1; }
DONE=1   # 重建成功 → 标记完成；此前任何失败退出都会触发 on_exit 回滚

echo ""
echo "Done. You can reboot now (do NOT use acpi=off / noapic)."
echo "After reboot, verify with:"
echo '  dmesg | grep -iE "override|taint"   # expect: DSDT override applied / kernel tainted'
echo '  dmesg | grep -i AE_AML_OPERAND_TYPE # expect: no output'
