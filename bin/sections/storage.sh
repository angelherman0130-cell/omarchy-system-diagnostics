#!/bin/sh
# System Diagnostics - Storage section.
#
# Filesystem capacity and inode use, a read-only remount check, and (full mode
# only) Btrfs device stats and SMART health. Read-only.
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/../bootstrap.sh"
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/../common.sh"

MODE=${1:-}
CAT=storage
CHECKS=""

# ---------------------------------------------------------------- capacity
if have df; then
  _df=$(/usr/bin/df -P -x tmpfs -x devtmpfs -x squashfs -x overlay 2>/dev/null | /usr/bin/grep -v '^Filesystem')
  _worst_pct=-1
  _d=""
  _n=0
  _full=""
  while IFS= read -r _line; do
    [ -z "$_line" ] && continue
    # Filesystem 1024-blocks Used Available Capacity Mounted-on
    _pct=$(printf '%s' "$_line" | /usr/bin/awk '{print $5}' | /usr/bin/tr -d '%')
    _mnt=$(printf '%s' "$_line" | /usr/bin/awk '{print $6}')
    case "$_pct" in '' | *[!0-9]*) continue ;; esac
    _d="$_d $_line"
    [ "$_pct" -gt "$_worst_pct" ] && _worst_pct=$_pct
    if [ "$_pct" -ge 85 ]; then
      _full="$_full $_mnt:${_pct}%"
    fi
    _n=$((_n + 1))
  done <<EOF
$_df
EOF
  if [ "$_worst_pct" -ge 95 ]; then
    emitr "storage.capacity" "$CAT" problem 3 "Disk capacity" "${_worst_pct}% used" \
      "A filesystem is over 95% full:$_full" \
      "Free space now: journalctl --vacuum-size=200M; pacman -Sc; delete old snapshots" \
      caution "Reclaim disk space" "Cleaning package and journal caches is safe but is not run here." \
      $_d
  elif [ "$_worst_pct" -ge 85 ]; then
    emitr "storage.capacity" "$CAT" attention 1 "Disk capacity" "${_worst_pct}% used" \
      "A filesystem is over 85% full:$_full" \
      "Review large directories: du -xh --max-depth=1 / | sort -h" \
      manual "Review disk usage" "No automatic action is taken." \
      $_d
  elif [ "$_worst_pct" -ge 0 ]; then
    emit "storage.capacity" "$CAT" ok 0 "Disk capacity" "${_worst_pct}% used" \
      "All readable filesystems below 85%" ""
  else
    emit "storage.capacity" "$CAT" unknown 0 "Disk capacity" "unknown" \
      "df produced no parsable rows" ""
  fi
else
  emit "storage.capacity" "$CAT" unknown 0 "Disk capacity" "unknown" \
    "df is not available" ""
fi

# ---------------------------------------------------------------- inodes
if have df; then
  _dfi=$(/usr/bin/df -P -i -x tmpfs -x devtmpfs -x squashfs -x overlay 2>/dev/null | /usr/bin/grep -v '^Filesystem')
  _worst_i=-1
  _ifull=""
  while IFS= read -r _line; do
    [ -z "$_line" ] && continue
    _pct=$(printf '%s' "$_line" | /usr/bin/awk '{print $5}' | /usr/bin/tr -d '%')
    _mnt=$(printf '%s' "$_line" | /usr/bin/awk '{print $6}')
    case "$_pct" in '' | *[!0-9]*) continue ;; esac
    [ "$_pct" -gt "$_worst_i" ] && _worst_i=$_pct
    [ "$_pct" -ge 85 ] && _ifull="$_ifull $_mnt:${_pct}%"
  done <<EOF
$_dfi
EOF
  if [ "$_worst_i" -ge 85 ]; then
    emitr "storage.inodes" "$CAT" attention 1 "Inode use" "${_worst_i}% used" \
      "A filesystem is running out of inodes:$_ifull" \
      "Find many small files: du -x --inodes -d 1 / 2>/dev/null | sort -n" \
      manual "Review inode use" "No automatic action is taken."
  elif [ "$_worst_i" -ge 0 ]; then
    emit "storage.inodes" "$CAT" ok 0 "Inode use" "${_worst_i}% used" \
      "All filesystems below 85% inodes" ""
  else
    emit "storage.inodes" "$CAT" unknown 0 "Inode use" "unknown" \
      "df did not report numeric inode usage for any filesystem" ""
  fi
else
  emit "storage.inodes" "$CAT" unknown 0 "Inode use" "unknown" \
    "df is unavailable; inode use could not be checked" ""
fi

# ---------------------------------------------------------------- read-only remount
# The kernel logs "EXT4-fs error" / "remounting filesystem read-only" when it
# gives up on a filesystem. That is a serious, easy-to-miss event.
if have journalctl; then
  _ro=$(/usr/bin/journalctl -k -b 0 --no-pager 2>/dev/null \
    | /usr/bin/grep -iE 'remounting filesystem read-only|EXT4-fs error|XFS .*error|I/O error.*(sector|filesystem)' \
    | /usr/bin/grep . | /usr/bin/head -8)
  if [ -n "$_ro" ]; then
    _d=""
    while IFS= read -r _line; do [ -n "$_line" ] && _d="$_d $(printf '%s' "$_line" | /usr/bin/head -c 300)"; done <<EOF
$_ro
EOF
    emitr "storage.io_errors" "$CAT" problem 3 "Filesystem I/O errors" "this boot" \
      "The kernel reported filesystem or I/O errors, possibly a read-only remount" \
      "Check the disk: smartctl -a /dev/sdX; run fsck from a live system" \
      manual "Investigate the disk" "Do not run fsck on a mounted filesystem." \
      $_d
  else
    emit "storage.io_errors" "$CAT" ok 0 "Filesystem I/O errors" "none" \
      "No filesystem or I/O errors in this boot" ""
  fi
else
  emit "storage.io_errors" "$CAT" unknown 0 "Filesystem I/O errors" "unknown" \
    "journalctl is unavailable; kernel filesystem errors could not be checked" ""
fi

# ---------------------------------------------------------------- btrfs
if is_full; then
  if have findmnt; then
    _btrfs_mounts=$(/usr/bin/findmnt -rn -t btrfs -o TARGET 2>/dev/null)
    _findmnt_rc=$?
  else
    _btrfs_mounts=""
    _findmnt_rc=127
  fi
  if [ "$_findmnt_rc" -ne 0 ]; then
    emit "storage.btrfs" "$CAT" unknown 0 "Btrfs device stats" "unknown" \
      "findmnt failed or is unavailable; mounted Btrfs filesystems could not be identified" ""
  elif [ -z "$_btrfs_mounts" ]; then
    emit "storage.btrfs" "$CAT" info 0 "Btrfs device stats" "not applicable" \
      "No mounted Btrfs filesystem was detected" ""
  elif ! have btrfs; then
    emit "storage.btrfs" "$CAT" unknown 0 "Btrfs device stats" "not checked" \
      "A Btrfs filesystem is mounted but the btrfs utility is unavailable" ""
  else
    _btrfs_mnt=$(printf '%s\n' "$_btrfs_mounts" | /usr/bin/head -n 1)
    _dstats_raw=$(/usr/bin/btrfs device stats "$_btrfs_mnt" 2>/dev/null)
    _dstats_rc=$?
    _dstats=$(printf '%s\n' "$_dstats_raw" | /usr/bin/grep -vE ' 0$')
    if [ "$_dstats_rc" -ne 0 ]; then
      emit "storage.btrfs" "$CAT" unknown 0 "Btrfs device stats" "unreadable" \
        "btrfs device stats failed on $_btrfs_mnt (exit $_dstats_rc)" \
        "Run: btrfs device stats '$_btrfs_mnt'"
    elif [ -n "$_dstats" ]; then
      _d=""
      while IFS= read -r _line; do [ -n "$_line" ] && _d="$_d $(printf '%s' "$_line" | /usr/bin/head -c 300)"; done <<EOF
$_dstats
EOF
      emitr "storage.btrfs" "$CAT" problem 3 "Btrfs device stats" "errors" \
        "btrfs device stats reports non-zero error counters on $_btrfs_mnt" \
        "Inspect: btrfs device stats '$_btrfs_mnt'; consider a scrub" \
        manual "Investigate Btrfs errors" "Scrubbing is read-only but not run here." \
        $_d
    else
      emit "storage.btrfs" "$CAT" ok 0 "Btrfs device stats" "clean" \
        "No Btrfs device errors on $_btrfs_mnt" ""
    fi
  fi
fi

# ---------------------------------------------------------------- SMART (full)
if is_full && have smartctl; then
  _disks=$(/usr/bin/lsblk -dno NAME,TYPE 2>/dev/null | /usr/bin/awk '$2=="disk"{print "/dev/"$1}')
  _bad=""
  _sel=""
  for _dk in $_disks; do
    _h=$(/usr/bin/smartctl -H "$_dk" 2>/dev/null | /usr/bin/grep -iE 'SMART overall-health|SMART Health Status')
    if [ -n "$_h" ]; then
      _sel="$_sel $_dk:$_h"
      case "$_h" in
        *PASSED* | *OK* | *Good*) ;;
        *) _bad="$_bad $_dk" ;;
      esac
    fi
  done
  if [ -n "$_bad" ]; then
    emitr "storage.smart" "$CAT" problem 3 "SMART health" "failing" \
      "SMART health check failed on:$_bad" \
      "Back up now and plan a disk replacement" \
      manual "Back up and replace the disk" "No automatic action is taken." \
      $_sel
  elif [ -n "$_sel" ]; then
    emitd "storage.smart" "$CAT" ok 0 "SMART health" "passed" \
      "All readable disks report SMART health passed" "" $_sel
  else
    emit "storage.smart" "$CAT" unknown 0 "SMART health" "unreadable" \
      "smartctl could not read any disk (common without root or on NVMe passthrough)" ""
  fi
elif is_full; then
  emit "storage.smart" "$CAT" unknown 0 "SMART health" "not checked" \
    "smartctl is unavailable; disk health could not be queried" ""
fi

emit_json "$CAT" "$MODE"
