#!/usr/bin/env bash
# =====================================================================
# HP OMEN Transcend 16 DSDT override installer for
# CachyOS/Arch + mkinitcpio (+ Limine). Target scope is deliberately narrow:
# one machine family, the standard /etc/mkinitcpio.conf + *.preset layout,
# and the acpi_override hook. Full rationale lives in the README.
#
# One-line install (auto-detects board/BIOS from DMI):
#   curl -fsSL https://raw.githubusercontent.com/zxzxn3/omen-transcend-16-dsdt-fix/main/dsdt-fix.sh | sudo bash
#
# Flow: args -> pick the .aml (operand, or repo by --target/DMI; a --target
# that does not match this machine warns and needs confirmation) -> confirm on
# /dev/tty -> download ->
# DSDT signature check -> prepare (staged, no writes) -> atomic apply ->
# rebuild (limine-mkinitcpio or mkinitcpio -P) -> done.
# Exit: 0 ok / 1 runtime error / 2 usage error.
# =====================================================================
set -euo pipefail

# ---- config ----
RAW_BASE="https://raw.githubusercontent.com/zxzxn3/omen-transcend-16-dsdt-fix/main"
OVERRIDE_DIR="/etc/initcpio/acpi_override"   # where the hook looks for .aml files
MKINITCPIO_CONF="/etc/mkinitcpio.conf"
HOOK_NAME="acpi_override"

#TTY=0 then means no confirmation is possible and installation is refused unless -f/--force is given.
TTY=0
if { : </dev/tty; } 2>/dev/null; then TTY=1; fi

# ---- rollback state ----
# Real files are only touched in apply. If we exit before the rebuild is
# confirmed (BUILT=1), the EXIT trap restores the previous files from $STAGE
# snapshots, then removes the whole staging dir.
BUILT=0
CHANGED_AML=0
CHANGED_CONF=0
STAGE=""

on_exit() {
  set +e
  if [ "$BUILT" -ne 1 ] && { [ "$CHANGED_AML" -eq 1 ] || [ "$CHANGED_CONF" -eq 1 ]; }; then
    echo "  [WARN] Install did not finish — restoring previous state." >&2
    if [ "$CHANGED_AML" -eq 1 ]; then
      if [ -f "$STAGE/dsdt.orig" ]; then
        mv -f "$STAGE/dsdt.orig" "$OVERRIDE_DIR/dsdt.aml"
      else
        # no dsdt.orig = there was no override before; delete it again
        rm -f -- "$OVERRIDE_DIR/dsdt.aml"
        rmdir "$OVERRIDE_DIR" 2>/dev/null || true
      fi
      echo "  [OK] Restored previous override." >&2
    fi
    if [ "$CHANGED_CONF" -eq 1 ]; then
      mv -f "$STAGE/config.orig" "$MKINITCPIO_CONF"
      echo "  [OK] Restored $MKINITCPIO_CONF (reverted HOOKS edit)." >&2
    fi
    echo "  [NOTE] The initramfs was not rebuilt. If a rebuild had already started," >&2
    echo "         images on disk may already contain this change or be truncated;" >&2
    echo "         verify them before rebooting. Re-run dsdt-fix.sh to try again." >&2
    rm -f -- "$OVERRIDE_DIR/dsdt.aml.new" "$MKINITCPIO_CONF.new" 2>/dev/null || true
  fi
  [ -n "$STAGE" ] && rm -rf -- "$STAGE"
}
trap on_exit EXIT
trap 'exit 130' INT     # Ctrl-C / SIGTERM: run on_exit, then exit
trap 'exit 143' TERM

# ---- args ----
FORCE=0
REBUILD=0
LIST=0      # -l/--list: just print the available patches and exit
TARGET=""   # <board>/<bios> (official download); empty = auto-detect from DMI
SRC=""      # optional operand: a local dsdt.aml

show_usage() {
  cat <<'EOF'
Usage: sudo bash dsdt-fix.sh [OPTIONS] [dsdt.aml PATH]

Options:
  -f, --force      Skip the interactive confirmation before applying/rebuilding.
                   This includes accepting a --target that does not match this
                   machine, and is required for unattended use when there is no
                   controlling terminal.
      --rebuild     Force an initramfs rebuild even if the override is unchanged.
      --target ID   board/BIOS for the official download, e.g. 8C4D/F.29.
                    (omit: auto-detect from the machine DMI)
  -l, --list       Print the available patches (installable + upstream links)
                   and exit. Downloads the index only; no root or local changes.
  -h, --help       Show this help and exit.

Operand (optional): a local dsdt.aml (e.g. one you compiled yourself). It is
used as-is: there is no board/BIOS metadata to verify it against.

With no operand the patch is pulled from the GitHub repo as
dsdt-fix/<target>/dsdt.aml. Unknown targets list what is published and exit;
there is never an automatic fallback.

Exit status:
  0  success
  1  runtime error
  2  usage error
EOF
}

usage_err() { echo "Error: $*" >&2; echo >&2; show_usage >&2; exit 2; }

# print the available-patches lists from dsdt-fix/index.md (no install).
# index.md has two tables, parsed by section:
#   "## Installable with dsdt-fix.sh" -> one <board>/<bios> per row (installable here)
#   "## Upstream patches ..."         -> <board>/<bios> | <url> (fetch it yourself)
list_patches() {
  local idx list own up
  idx="$(curl -fsSL "${RAW_BASE}/dsdt-fix/index.md" 2>/dev/null || true)"
  [ -n "$idx" ] || { echo "    (could not read the patch list)" >&2; return 1; }
  list="$(printf '%s\n' "$idx" | awk -F'|' '
    /^##[[:space:]]/ { s=$0; sub(/^##[[:space:]]+/, "", s)
                       mode = (s ~ /^Installable/) ? "I" : (s ~ /^Upstream/) ? "U" : ""
                       next }
    mode == "" || $0 !~ /^\|/ { next }
    { a=$2; b=$3
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", a)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", b)
      if (a == "" || a == "--target" || a ~ /^-+$/) next
      if (mode == "I" && a ~ /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/) print "I\t" a
      else if (mode == "U" && b != "") print "U\t" a "\t" b
    }
  ' || true)"
  [ -n "$list" ] || { echo "    (could not read the patch list)" >&2; return 1; }
  own="$(printf '%s\n' "$list" | awk -F'\t' '$1=="I"{print $2}')" || true
  up="$(printf '%s\n' "$list" | awk -F'\t' '$1=="U"{print $2"\t"$3}')" || true
  if [ -n "$own" ]; then
    echo "  Installable with dsdt-fix.sh:"
    printf '%s\n' "$own" | sed 's/^/    /'
  fi
  if [ -n "$up" ]; then
    echo "  Upstream patches (download & install manually — dsdt-fix.sh won't fetch them):"
    printf '%s\n' "$up" | awk -F'\t' '{ printf "    %-16s %s\n", $1, $2 }'
  fi
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -f|--force)   FORCE=1; shift ;;
    --rebuild)    REBUILD=1; shift ;;
    --target)     [ "$#" -ge 2 ] || usage_err "--target needs a value, e.g. --target 8C4D/F.29"
                  TARGET="$2"; shift 2 ;;
    --target=*)   TARGET="${1#*=}"
                  [ -n "$TARGET" ] || usage_err "--target needs a value, e.g. --target 8C4D/F.29"
                  shift ;;
    -l|--list)    LIST=1; shift ;;
    -h|--help)    show_usage; exit 0 ;;
    -*)           usage_err "unknown option: $1" ;;
    *)            [ -n "$SRC" ] && usage_err "too many arguments: only one operand allowed"
                  SRC="$1"; shift ;;
  esac
done

# -l/--list: download and print the patch index (no root or local changes)
if [ "$LIST" -eq 1 ]; then
  command -v curl >/dev/null 2>&1 || { echo "Error: listing patches requires 'curl'." >&2; exit 1; }
  list_patches || exit 1
  exit 0
fi

# --target must be <board>/<bios>, and only makes sense for the official download
if [ -n "$TARGET" ] && ! printf '%s' "$TARGET" | grep -qE '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'; then
  usage_err "--target must look like '<board>/<bios>', e.g. 8C4D/F.29 (got: $TARGET)"
fi
[ -z "$SRC" ] || [ -z "$TARGET" ] || usage_err "--target is only for the official download; it cannot be combined with an .aml operand"

# ---- root + single instance ----
[ "$(id -u)" -eq 0 ] || { echo "Error: please run with sudo." >&2; exit 1; }
if [ -d /run/lock ] && command -v flock >/dev/null 2>&1; then
  exec 9>/run/lock/dsdt-override.lock || { echo "Error: cannot open the lock file." >&2; exit 1; }
  flock -n 9 || { echo "Error: another dsdt-override install is already running." >&2; exit 1; }
fi

echo "Caution: A dsdt.aml runs as kernel code at the next boot — only install"
echo "  .aml files you trust. Made your own fix? Patches welcome via PR:"
echo "  https://github.com/zxzxn3/omen-transcend-16-dsdt-fix"
echo ""

# read the machine DMI once, up front, and show it when available
SYS_DMI=/sys/class/dmi/id
DETECTED_BOARD="$(cat "$SYS_DMI/board_name" 2>/dev/null | xargs 2>/dev/null || true)"
DETECTED_BIOS="$(cat "$SYS_DMI/bios_version" 2>/dev/null | xargs 2>/dev/null || true)"
if [ -n "$DETECTED_BOARD$DETECTED_BIOS" ]; then
  echo "Machine: ${DETECTED_BOARD}/${DETECTED_BIOS}"
fi

# ---- pick the .aml: user operand, or official repo by --target / DMI ----
if [ -n "$SRC" ]; then
  echo "Using user-provided dsdt.aml: $SRC."
  echo "  Local operand: no board/BIOS metadata to verify; installing it as-is."
else
  command -v curl >/dev/null 2>&1 || { echo "Error: downloading patches requires 'curl'." >&2; exit 1; }
  EXPLICIT=0
  if [ -n "$TARGET" ]; then
    EXPLICIT=1
  elif [ -z "$DETECTED_BOARD" ] || [ -z "$DETECTED_BIOS" ]; then
    echo "Error: could not detect board/BIOS; an official patch cannot be selected safely." >&2
    echo "       Run on the target machine, or supply a local dsdt.aml as an expert override." >&2
    exit 1
  else
    TARGET="${DETECTED_BOARD}/${DETECTED_BIOS}"
  fi

  # Board/BIOS check for the official source, before any download. --target is
  # the operator naming the target on purpose, so a mismatch is a warning they
  # have to accept (interactively, or with -f/--force) rather than an error;
  # with no DMI to compare against there is nothing to warn about. The
  # auto-detect path above already required a complete DMI.
  if [ "$EXPLICIT" -ne 1 ]; then
    echo "Patch target: $TARGET (auto-detected)"
  elif [ -z "$DETECTED_BOARD$DETECTED_BIOS" ] || [ "$TARGET" = "${DETECTED_BOARD}/${DETECTED_BIOS}" ]; then
    echo "Patch target: $TARGET"
  else
    echo "  [WARN] You asked for $TARGET, but this machine reports ${DETECTED_BOARD}/${DETECTED_BIOS}." >&2
    if [ "$FORCE" -eq 1 ]; then
      echo "  [OK] Installing it anyway (-f/--force)." >&2
    elif [ "$TTY" -eq 1 ]; then
      read -r -p "  Install $TARGET anyway? [y/N] " REPLY </dev/tty || REPLY=''
      case "$REPLY" in
        y|Y|yes|Yes) ;;
        *) echo "  Aborted (nothing was changed)." >&2; exit 1 ;;
      esac
    else
      echo "  Aborted: no terminal to confirm on." >&2
      echo "         Re-run with -f/--force to install it anyway, or pass a local dsdt.aml." >&2
      exit 1
    fi
  fi

  URL="${RAW_BASE}/dsdt-fix/${TARGET}/dsdt.aml"
  if [ "$(curl -s -o /dev/null -w '%{http_code}' "$URL" || true)" != "200" ]; then
    # no such patch -> list what is available and exit (never auto-fallback)
    echo "  [WARN] No patch for target '$TARGET' in this repo." >&2
    list_patches || true
    echo "  No patch is published for '$TARGET'; pass a local .aml to install a custom one." >&2
    exit 1
  fi

  # print the patch-specific note (README.md in that patch folder), if any
  PATCH_NOTE="$(curl -fsSL "${RAW_BASE}/dsdt-fix/${TARGET}/README.md" 2>/dev/null || true)"
  if [ -n "$PATCH_NOTE" ]; then
    echo ""
    echo "--- Patch note for $TARGET ---"
    printf '%s\n' "$PATCH_NOTE"
    echo "-------------------------------"
  fi
  SRC="$URL"
fi

# No controlling terminal means there is no way to confirm an install; refuse
# by default. -f/--force is the explicit opt-in for a deliberate unattended
# run. --help and --list returned earlier and never need a terminal.
if [ "$TTY" -ne 1 ] && [ "$FORCE" -ne 1 ]; then
  echo "Error: no controlling terminal for confirmation." >&2
  echo "       Re-run in a terminal, or pass -f/--force for unattended install." >&2
  exit 1
fi

# one interactive confirmation for the whole operation, read from /dev/tty
# (stdin may be the piped script body). -f/--force skips it.
if [ "$FORCE" -ne 1 ]; then
  echo "  Plan: install the DSDT override, add the '${HOOK_NAME}' hook if missing," >&2
  echo "        then rebuild the initramfs." >&2
  read -r -p "  Continue? [y/N] " REPLY </dev/tty || REPLY=''
  case "$REPLY" in
    y|Y|yes|Yes) ;;
    *) echo "  Aborted (nothing was changed)." >&2; exit 1 ;;
  esac
fi

# ---- stage + download ----
# everything transient (download, staged config, rollback snapshots) lives here
STAGE="$(mktemp -d 2>/dev/null || mktemp -d /tmp/dsdt-override.XXXXXX)"
if [[ "$SRC" == http://* || "$SRC" == https://* ]]; then
  echo "[0/3] Downloading dsdt.aml from: $SRC"
  curl -fsSL "$SRC" -o "$STAGE/dl.aml" || { echo "Error: download failed: $SRC" >&2; exit 1; }
  SRC="$STAGE/dl.aml"
fi

# ---- basic validation ----
[ -f "$SRC" ] || { echo "Error: dsdt.aml not found at: $SRC" >&2; exit 1; }
# first four bytes must be "DSDT" (catches HTML error pages / wrong files)
[ "$(head -c4 "$SRC" 2>/dev/null)" = "DSDT" ] \
  || { echo "Error: not a valid DSDT table (missing 'DSDT' signature): $SRC" >&2; exit 1; }

# ---- prepare (no writes yet) ----
echo "[1/3] Preparing ..."

# is the override already installed (and identical)?
NEED_AML=1
if [ -f "$OVERRIDE_DIR/dsdt.aml" ] && cmp -s "$SRC" "$OVERRIDE_DIR/dsdt.aml"; then
  NEED_AML=0    # unchanged; a --rebuild or a missing hook may still force work
fi
# is acpi_override already in the HOOKS of the main config (or its .d)?
HOOK_OK=0
CONF_FILES=("$MKINITCPIO_CONF" /etc/mkinitcpio.conf.d/*.conf)
for f in "${CONF_FILES[@]}"; do
  if [ -f "$f" ] && grep -qE "^\s*HOOKS=.*\b${HOOK_NAME}\b" "$f" 2>/dev/null; then
    HOOK_OK=1
    break
  fi
done

# idempotent: nothing to do
if [ "$REBUILD" -ne 1 ] && [ "$NEED_AML" -eq 0 ] && [ "$HOOK_OK" -eq 1 ]; then
  echo "  [OK] DSDT override already installed and up to date — nothing to do."
  exit 0
fi

# otherwise stage a HOOKS edit on the main config only (validated before apply)
NEED_CONF=0
if [ "$HOOK_OK" -ne 1 ]; then
  [ -f "$MKINITCPIO_CONF" ] || { echo "Error: $MKINITCPIO_CONF not found; cannot add '${HOOK_NAME}' to it." >&2; exit 1; }
  cp -f "$MKINITCPIO_CONF" "$STAGE/config.new"
  if sed -E 's/^(HOOKS=\([^)]*\bbase)\b/\1 '"${HOOK_NAME}"'/' "$STAGE/config.new" \
       > "$STAGE/config.new.tmp" \
     && mv -f "$STAGE/config.new.tmp" "$STAGE/config.new" \
     && bash -n "$STAGE/config.new" 2>/dev/null \
     && grep -qE "^\s*HOOKS=\([^)]*\b${HOOK_NAME}\b" "$STAGE/config.new"; then
    NEED_CONF=1
    cp -f "$MKINITCPIO_CONF" "$STAGE/config.orig"   # rollback snapshot
    echo "  [OK] Will add ${HOOK_NAME} after 'base' in: $MKINITCPIO_CONF"
  else
    echo "Error: could not add '${HOOK_NAME}' into the HOOKS= list of $MKINITCPIO_CONF" >&2
    echo "       (needs a 'HOOKS=(... base ...)' line to anchor on); add it manually, then re-run." >&2
    exit 1
  fi
fi

# ---- apply (the only real-file mutation window) ----
echo "[2/3] Applying changes ..."
mkdir -p "$OVERRIDE_DIR"

if [ "$NEED_AML" -eq 1 ]; then
  if [ -f "$OVERRIDE_DIR/dsdt.aml" ]; then
    cp -f "$OVERRIDE_DIR/dsdt.aml" "$STAGE/dsdt.orig"
    cp -f "$OVERRIDE_DIR/dsdt.aml" "$OVERRIDE_DIR/dsdt.aml.bak-$(date +%Y%m%d-%H%M%S)"
  fi
  cp -f "$SRC" "$OVERRIDE_DIR/dsdt.aml.new"
  mv -f "$OVERRIDE_DIR/dsdt.aml.new" "$OVERRIDE_DIR/dsdt.aml"   # atomic rename
  CHANGED_AML=1
  echo "  [OK] Installed -> $OVERRIDE_DIR/dsdt.aml"
else
  echo "  [OK] dsdt.aml unchanged (already the target version)."
fi

if [ "$NEED_CONF" -eq 1 ]; then
  cp -f "$STAGE/config.new" "$MKINITCPIO_CONF.new"
  mv -f "$MKINITCPIO_CONF.new" "$MKINITCPIO_CONF"
  CHANGED_CONF=1
  echo "  [OK] Added ${HOOK_NAME} right after 'base' in: $MKINITCPIO_CONF"
fi

# ---- rebuild ----
echo "[3/3] Rebuilding initramfs ..."
# The rebuild tool must never read stdin when the script arrived over a pipe:
# stdin there is the script body, not user input. Hand it the controlling
# terminal when one exists, otherwise /dev/null (reachable only via -f/--force).
if [ "$TTY" -eq 1 ]; then REBUILD_IN=/dev/tty; else REBUILD_IN=/dev/null; fi
# CachyOS: limine-mkinitcpio also refreshes the Limine entries; it is already
# run non-interactively by pacman hooks, so prefer it whenever present.
if command -v limine-mkinitcpio >/dev/null 2>&1; then
  limine-mkinitcpio <"$REBUILD_IN" || { echo "Error: initramfs rebuild failed." >&2; exit 1; }
else
  mkinitcpio -P <"$REBUILD_IN" || { echo "Error: initramfs rebuild failed." >&2; exit 1; }
fi
BUILT=1   # rebuild succeeded; the override is baked into the boot images

echo ""
echo "Install complete. Reboot to apply. Before rebooting:"
echo "  1. Remove 'acpi=off' from the kernel cmdline. You may KEEP 'noapic' for this first boot as a"
echo "     safety margin (noapic does not disable ACPI, so the override still applies)."
echo "  2. After boot, verify the override is active:"
echo '       dmesg | grep -i "table override"      # expect: DSDT ... Physical table override'
echo '       dmesg | grep -i AE_AML_OPERAND_TYPE   # expect: no output'
echo "  3. Only after those pass, also remove 'noapic'."
echo "  4. If booting without acpi=off fails: re-add acpi=off noapic, remove"
echo "     ${OVERRIDE_DIR}/dsdt.aml, drop '${HOOK_NAME}' from HOOKS in $MKINITCPIO_CONF,"
echo "     then 'sudo mkinitcpio -P'. A pre-change copy is kept as dsdt.aml.bak-<timestamp>."
echo ""

