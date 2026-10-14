#!/bin/sh
# System Diagnostics - Packages section.
#
# Arch package database health: a stale pacman lock, orphaned packages, database
# consistency, foreign (AUR) package count, and in full mode a quick file check
# and the pending-update list. Read-only.
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/../bootstrap.sh"
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/../common.sh"

MODE=${1:-}
CAT=packages
CHECKS=""

if ! have pacman; then
  emit "packages.section" "$CAT" unknown 0 "Packages" "unavailable" \
    "pacman not found on PATH" ""
  emit_json "$CAT" "$MODE"
  exit 0
fi

# ---------------------------------------------------------------- database lock
# A leftover db.lck means a previous pacman run was interrupted. pacman will
# then refuse every operation, which is very confusing without context.
if [ -e /var/lib/pacman/db.lck ]; then
  emitr "packages.lock" "$CAT" problem 3 "Pacman lock" "present" \
    "/var/lib/pacman/db.lck exists, so pacman refuses to run" \
    "Confirm no pacman is running (pgrep -a pacman), then remove the lock file" \
    caution "Remove the stale lock" "Only remove db.lck when no pacman process is running." \
    "path: /var/lib/pacman/db.lck"
else
  emit "packages.lock" "$CAT" ok 0 "Pacman lock" "none" \
    "No stale pacman lock" ""
fi

# ---------------------------------------------------------------- db consistency
_dbdk=$(/usr/bin/pacman -Dk 2>&1)
case "$_dbdk" in
  *"No database errors"* | *"0 errors"*)
    emit "packages.database" "$CAT" ok 0 "Package database" "consistent" \
      "pacman reports no database errors" "" ;;
  *)
    _d=""
    _n=0
    while IFS= read -r _line; do
      [ -z "$_line" ] && continue
      _d="$_d $(printf '%s' "$_line" | /usr/bin/head -c 300)"
      _n=$((_n + 1))
      [ "$_n" -ge 10 ] && break
    done <<EOF
$_dbdk
EOF
    emitr "packages.database" "$CAT" problem 3 "Package database" "errors" \
      "pacman reports inconsistencies in its local database" \
      "Review the output; a reinstall of the affected package is usually enough" \
      manual "Repair the package database" "Do not blindly delete /var/lib/pacman." \
      $_d ;;
esac

# ---------------------------------------------------------------- orphans
_orph=$(/usr/bin/pacman -Qtdq 2>/dev/null | /usr/bin/head -40)
if [ -n "$(printf '%s' "$_orph" | /usr/bin/grep .)" ]; then
  _n=$(printf '%s' "$_orph" | /usr/bin/grep -c .)
  _d=""
  _k=0
  while IFS= read -r _line; do
    [ -z "$_line" ] && continue
    _d="$_d $_line"
    _k=$((_k + 1))
    [ "$_k" -ge 40 ] && break
  done <<EOF
$_orph
EOF
  emitr "packages.orphans" "$CAT" attention 1 "Orphan packages" "${_n}" \
    "${_n} installed packages are no longer required by anything" \
    "Review, then remove: pacman -Qtdq | sudo pacman -Rns -" \
    caution "Remove orphaned packages" "Removing them is a repair and is NOT run by this plugin." \
    $_d
else
  emit "packages.orphans" "$CAT" ok 0 "Orphan packages" "none" \
    "No orphaned packages" ""
fi

# ---------------------------------------------------------------- foreign (AUR)
_foreign=$(/usr/bin/pacman -Qmq 2>/dev/null)
if [ -n "$(printf '%s' "$_foreign" | /usr/bin/grep .)" ]; then
  _nf=$(printf '%s' "$_foreign" | /usr/bin/grep -c .)
  emit "packages.foreign" "$CAT" info 0 "Foreign packages" "${_nf}" \
    "${_nf} packages come from outside the official repos (AUR/manual)" \
    "Update them with your AUR helper (yay/paru) and review for breakage"
else
  emit "packages.foreign" "$CAT" info 0 "Foreign packages" "0" \
    "All installed packages come from the official repositories" ""
fi

# ---------------------------------------------------------------- last upgrade
if [ -r /var/log/pacman.log ]; then
  _last=$(/usr/bin/grep -a 'starting full system upgrade' /var/log/pacman.log | /usr/bin/tail -n 1)
  if [ -n "$_last" ]; then
    _when=$(printf '%s' "$_last" | /usr/bin/sed -n 's/^\[\([^]]*\)\].*/\1/p')
    emit "packages.last_upgrade" "$CAT" info 0 "Last full upgrade" "$_when" \
      "Most recent full system upgrade recorded in pacman.log" ""
  fi
fi

# ---------------------------------------------------------------- updates (full)
if is_full && have checkupdates; then
  # checkupdates uses a temporary sync database and needs no root.
  _upd=$(/usr/bin/checkupdates 2>/dev/null | /usr/bin/head -60)
  if [ -n "$(printf '%s' "$_upd" | /usr/bin/grep .)" ]; then
    _nu=$(printf '%s' "$_upd" | /usr/bin/grep -c .)
    _d=""
    _k=0
    while IFS= read -r _line; do
      [ -z "$_line" ] && continue
      _d="$_d $_line"
      _k=$((_k + 1))
      [ "$_k" -ge 30 ] && break
    done <<EOF
$_upd
EOF
    emitd "packages.updates" "$CAT" attention 1 "Pending updates" "${_nu}" \
      "${_nu} package updates are available" \
      "Apply them: sudo pacman -Syu (reboot afterwards if the kernel or Mesa updated)" \
      $_d
  else
    emit "packages.updates" "$CAT" ok 0 "Pending updates" "none" \
      "No pending package updates" ""
  fi
fi

# ---------------------------------------------------------------- file check (full)
if is_full; then
  # -Qkk verifies every installed package's files against the database. It is
  # slow, so it is gated to full mode and capped.
  _kk=$(/usr/bin/timeout -k 2 15 /usr/bin/pacman -Qkk 2>/dev/null \
    | /usr/bin/grep -iE 'warning|error|missing|modified' \
    | /usr/bin/grep -viE '^warning: .*: mtree file is missing$' | /usr/bin/head -20)
  if [ -n "$_kk" ]; then
    _d=""
    _k=0
    while IFS= read -r _line; do
      [ -z "$_line" ] && continue
      _d="$_d $(printf '%s' "$_line" | /usr/bin/head -c 300)"
      _k=$((_k + 1))
      [ "$_k" -ge 12 ] && break
    done <<EOF
$_kk
EOF
    emitr "packages.file_check" "$CAT" attention 1 "Package file check" "differences" \
      "pacman -Qkk found modified or missing files (often expected after edits)" \
      "Review the lines; reinstall an affected package with: pacman -S <package>" \
      manual "Review changed files" "Modified config files under /etc are normal." \
      $_d
  else
    emit "packages.file_check" "$CAT" ok 0 "Package file check" "clean" \
      "No unexpected file differences reported" ""
  fi
fi

emit_json "$CAT" "$MODE"
