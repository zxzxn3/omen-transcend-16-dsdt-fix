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
# Flow: args -> pick the .aml (operand, or repo by --target/DMI) -> download
# -> DSDT signature check -> prepare (staged, no writes) -> confirm ->
# atomic apply -> rebuild (limine-mkinitcpio or mkinitcpio -P) -> verify
# the built images contain the override -> done.
# Exit: 0 ok / 1 runtime error / 2 usage error.
# =====================================================================
set -euo pipefail

# ---- config ----
RAW_BASE="https://raw.githubusercontent.com/zxzxn3/omen-transcend-16-dsdt-fix/main"
OVERRIDE_DIR="/etc/initcpio/acpi_override"   # where the hook looks for .aml files
MKINITCPIO_CONF="/etc/mkinitcpio.conf"
HOOK_NAME="acpi_override"
[ -t 0 ] && INTERACTIVE=1 || INTERACTIVE=0

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
    echo "  Re-run dsdt-fix.sh to try again." >&2
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
TARGET=""   # <board>/<bios> (official download); empty = auto-detect from DMI
SRC=""      # optional operand: a local dsdt.aml

show_usage() {
  cat <<'EOF'
Usage: sudo bash dsdt-fix.sh [OPTIONS] [dsdt.aml PATH]

Options:
  -f, --force      Skip the machine-match soft warning and the interactive
                   confirmation before applying/rebuilding.
      --rebuild     Force an initramfs rebuild even if the override is unchanged.
      --target ID   board/BIOS for the official download, e.g. 8C4D/F.29.
                    (omit: auto-detect from the machine DMI)
  -h, --help       Show this help and exit.

Operand (optional): a local dsdt.aml (e.g. one you compiled yourself), used
as-is with no board/BIOS matching.

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

while [ "$#" -gt 0 ]; do
  case "$1" in
    -f|--force)   FORCE=1; shift ;;
    --rebuild)    REBUILD=1; shift ;;
    --target)     [ "$#" -ge 2 ] || usage_err "--target needs a value, e.g. --target 8C4D/F.29"
                  TARGET="$2"; shift 2 ;;
    --target=*)   TARGET="${1#*=}"; shift ;;
    -h|--help)    show_usage; exit 0 ;;
    -*)           usage_err "unknown option: $1" ;;
    *)            [ -n "$SRC" ] && usage_err "too many arguments: only one operand allowed"
                  SRC="$1"; shift ;;
  esac
done

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

# .aml executes as kernel code at next boot; say so up front, and include a
# neutral link for anyone who would rather build/fix their own.
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
else
  command -v curl >/dev/null 2>&1 || { echo "Error: downloading patches requires 'curl'." >&2; exit 1; }
  EXPLICIT=0
  if [ -n "$TARGET" ]; then
    EXPLICIT=1
  elif [ -z "$DETECTED_BOARD" ] || [ -z "$DETECTED_BIOS" ]; then
    echo "Error: could not detect board/BIOS from this machine; pass --target <board>/<bios>." >&2
    exit 1
  else
    TARGET="${DETECTED_BOARD}/${DETECTED_BIOS}"
  fi
  if [ "$EXPLICIT" -eq 1 ]; then
    echo "Patch target: $TARGET (explicit)"
  else
    echo "Patch target: $TARGET (auto-detected)"
  fi

  URL="${RAW_BASE}/dsdt-fix/${TARGET}/dsdt.aml"
  if [ "$(curl -s -o /dev/null -w '%{http_code}' "$URL" || true)" != "200" ]; then
    # no such patch -> list what is available and exit (never auto-fallback).
    # index.md has two tables, parsed by section:
    #   "## Installable with dsdt-fix.sh" -> one <board>/<bios> per row (installable here)
    #   "## Upstream patches ..."         -> <board>/<bios> | <url> (fetch it yourself)
    echo "  [WARN] No patch for target '$TARGET' in this repo." >&2
    LIST=""
    IDX_DATA="$(curl -fsSL "${RAW_BASE}/dsdt-fix/index.md" 2>/dev/null || true)"
    if [ -n "$IDX_DATA" ]; then
      LIST="$(printf '%s\n' "$IDX_DATA" | awk -F'|' '
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
    else
      echo "    (could not read the patch list)" >&2
    fi
    OWN="$(printf '%s\n' "$LIST" | awk -F'\t' '$1=="I"{print $2}') " || true
    UP="$(printf '%s\n' "$LIST" | awk -F'\t' '$1=="U"{print $2"\t"$3}') " || true
    if [ -n "$OWN" ]; then
      echo "  Installable with dsdt-fix.sh:"
      printf '%s\n' "$OWN" | sed 's/^/    /'
    fi
    if [ -n "$UP" ]; then
      echo "  Upstream patches (download & install manually — dsdt-fix.sh won't fetch them):"
      printf '%s\n' "$UP" | awk -F'\t' '{ printf "    %-16s %s\n", $1, $2 }'
    fi
    echo "  Re-run with --target matching an available patch, or pass a local .aml." >&2
    exit 1
  fi

  # explicit target that differs from this machine -> soft warn (conservative)
  if [ "$EXPLICIT" -eq 1 ] && [ -n "$DETECTED_BOARD$DETECTED_BIOS" ] \
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

# one interactive confirmation for the whole operation, before anything is
# downloaded or written (after the patch note above, when there is one)
if [ "$INTERACTIVE" -eq 1 ] && [ "$FORCE" -ne 1 ]; then
  echo "  Plan: install the DSDT override, add the '${HOOK_NAME}' hook if missing," >&2
  echo "        then rebuild the initramfs." >&2
  read -r -p "  Continue? [y/N] " REPLY
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
  if [ -f "$f" ] && grep -qE '^\s*HOOKS=.*\bacpi_override\b' "$f" 2>/dev/null; then
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
  cp -f "$MKINITCPIO_CONF" "$STAGE/config.new"
  if sed -E 's/^(HOOKS=\([^)]*\bbase)\b/\1 '"${HOOK_NAME}"'/' "$STAGE/config.new" \
       > "$STAGE/config.new.tmp" \
     && mv -f "$STAGE/config.new.tmp" "$STAGE/config.new" \
     && bash -n "$STAGE/config.new" 2>/dev/null \
     && grep -qE '^\s*HOOKS=\([^)]*\bacpi_override\b' "$STAGE/config.new"; then
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
# CachyOS: limine-mkinitcpio also refreshes the Limine entries; it is already
# run non-interactively by pacman hooks, so prefer it whenever present.
if command -v limine-mkinitcpio >/dev/null 2>&1; then
  limine-mkinitcpio || { echo "Error: initramfs rebuild failed." >&2; exit 1; }
else
  mkinitcpio -P || { echo "Error: initramfs rebuild failed." >&2; exit 1; }
fi

# ---- verify the freshly built images contain the override ----
# The acpi_override hook places the table at kernel/firmware/acpi/dsdt.aml in
# the early (uncompressed) cpio. Check every image/uki the presets name; if any
# lacks it, roll back rather than report success.
verify_images() {
  local preset p img checked=0 missing=0
  for preset in /etc/mkinitcpio.d/*.preset; do
    [ -f "$preset" ] || continue
    while IFS= read -r img; do
      [ -f "$img" ] || continue
      checked=1
      if lsinitcpio --early "$img" 2>/dev/null | grep -qx 'kernel/firmware/acpi/dsdt.aml'; then
        echo "  [OK] Override verified inside: $img"
      else
        missing=1
        echo "  [WARN] Override NOT found inside: $img" >&2
      fi
    done < <(
      set +u
      . "$preset" 2>/dev/null || true
      for p in ${PRESETS[@]:-}; do
        eval "img=\${${p}_image:-}"; [ -n "$img" ] && printf '%s\n' "$img"
        eval "img=\${${p}_uki:-}";   [ -n "$img" ] && printf '%s\n' "$img"
      done
    )
  done
  if [ "$missing" -eq 1 ]; then
    echo "Error: rebuilt initramfs does not contain the DSDT override." >&2
    echo "       Check that the config used by that preset has '${HOOK_NAME}' in its HOOKS" >&2
    echo "       and that ${OVERRIDE_DIR}/dsdt.aml exists, then re-run. Rolling back." >&2
    exit 1
  fi
  if [ "$checked" -eq 0 ]; then
    echo "  [WARN] No built initramfs found to verify automatically; check manually:" >&2
    echo '         lsinitcpio --early <image> | grep kernel/firmware/acpi/dsdt.aml' >&2
  fi
}
if command -v lsinitcpio >/dev/null 2>&1; then
  verify_images
else
  echo "  [WARN] lsinitcpio not found; skipping initramfs content verification." >&2
fi
BUILT=1   # rebuild confirmed + images verified (when possible); failures above rolled back

echo ""
echo "Install complete. Reboot to apply. Before rebooting:"
echo "  1. Remove 'acpi=off' from the kernel cmdline. You may KEEP 'noapic' for this first boot as a"
echo "     safety margin (noapic does not disable ACPI, so the override still applies)."
echo "  2. After boot, verify the override is active:"
echo '       dmesg | grep -i "ACPI: Override"      # expect: DSDT ... this is unsafe: tainting kernel'
echo '       dmesg | grep -i AE_AML_OPERAND_TYPE   # expect: no output'
echo "  3. Only after those pass, also remove 'noapic'."
echo "  4. If booting without acpi=off fails: re-add acpi=off noapic, remove"
echo "     ${OVERRIDE_DIR}/dsdt.aml, drop '${HOOK_NAME}' from HOOKS in $MKINITCPIO_CONF,"
echo "     then 'sudo mkinitcpio -P'. A pre-change copy is kept as dsdt.aml.bak-<timestamp>."
echo ""


