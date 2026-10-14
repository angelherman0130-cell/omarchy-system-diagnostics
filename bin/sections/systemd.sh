#!/bin/sh
# System Diagnostics - Systemd section.
#
# Failed/degraded units, user-scoped failures, overall system state, boot time
# and the kernel command line. Read-only: nothing here restarts or enables a
# unit.
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/../bootstrap.sh"
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/../common.sh"

MODE=${1:-}
CAT=systemd
CHECKS=""

if ! have systemctl; then
  emit "systemd.section" "$CAT" unknown 0 "Systemd" "unavailable" \
    "systemctl not found on PATH" ""
  emit_json "$CAT" "$MODE"
  exit 0
fi

# ---------------------------------------------------------------- overall state
_state=$(/usr/bin/systemctl is-system-running 2>/dev/null | /usr/bin/head -n 1)
case "$_state" in
  running)
    emit "systemd.state" "$CAT" ok 0 "System state" "running" \
      "systemd reports the system is fully running" "" ;;
  degraded)
    emit "systemd.state" "$CAT" attention 1 "System state" "degraded" \
      "systemd reports the system is degraded (one or more units failed)" \
      "See the failed units below, or: systemctl --failed" ;;
  maintenance)
    emitr "systemd.state" "$CAT" problem 3 "System state" "maintenance" \
      "systemd is in maintenance mode; the boot never completed cleanly" \
      "Inspect: systemctl list-jobs; systemctl --failed" \
      manual "Investigate the failed boot" "No automatic action is taken." ;;
  starting)
    emit "systemd.state" "$CAT" info 0 "System state" "starting" \
      "systemd is still starting units" "" ;;
  *)
    emit "systemd.state" "$CAT" unknown 0 "System state" "${_state:-unknown}" \
      "systemctl is-system-running did not report a state" "" ;;
esac

# ---------------------------------------------------------------- failed units
_failed_raw=$(/usr/bin/systemctl --failed --no-legend --plain --no-pager 2>/dev/null)
_failed_rc=$?
_failed_lines=$(printf '%s\n' "$_failed_raw" | /usr/bin/grep .)
if [ "$_failed_rc" -ne 0 ]; then
  emit "systemd.failed" "$CAT" unknown 0 "Failed units" "unknown" \
    "systemctl --failed failed (exit $_failed_rc); failed units could not be checked" \
    "Run: systemctl --failed --no-pager"
elif [ -n "$_failed_lines" ]; then
  _d=""
  _n=0
  while IFS= read -r _line; do
    [ -z "$_line" ] && continue
    _d="$_d $_line"
    _n=$((_n + 1))
  done <<EOF
$_failed_lines
EOF
  emitr "systemd.failed" "$CAT" problem 3 "Failed units" "${_n} unit(s)" \
    "One or more system units are in a failed state" \
    "Inspect each: systemctl status <unit>; journalctl -u <unit> -n 100" \
    manual "Inspect and restart failed units" "This plugin does not restart anything." \
    $_d
else
  emit "systemd.failed" "$CAT" ok 0 "Failed units" "none" \
    "No failed system units" ""
fi

# ---------------------------------------------------------------- user failures
_ufailed_raw=$(/usr/bin/systemctl --user --failed --no-legend --plain --no-pager 2>/dev/null)
_ufailed_rc=$?
_ufailed_lines=$(printf '%s\n' "$_ufailed_raw" | /usr/bin/grep .)
if [ "$_ufailed_rc" -ne 0 ]; then
  emit "systemd.user_failed" "$CAT" unknown 0 "Failed user units" "unknown" \
    "systemctl --user --failed failed (exit $_ufailed_rc); user units could not be checked" \
    "Check the user systemd manager and run: systemctl --user --failed"
elif [ -n "$_ufailed_lines" ]; then
  _d=""
  _n=0
  while IFS= read -r _line; do
    [ -z "$_line" ] && continue
    _d="$_d $_line"
    _n=$((_n + 1))
  done <<EOF
$_ufailed_lines
EOF
  emitr "systemd.user_failed" "$CAT" problem 3 "Failed user units" "${_n} unit(s)" \
    "One or more systemd --user units are in a failed state" \
    "Inspect each: systemctl --user status <unit>; journalctl --user -u <unit>" \
    manual "Inspect and restart failed user units" "This plugin does not restart anything." \
    $_d
else
  emit "systemd.user_failed" "$CAT" ok 0 "Failed user units" "none" \
    "No failed user units" ""
fi

# ---------------------------------------------------------------- degraded
_degraded_lines=$(/usr/bin/systemctl list-units --state=degraded --no-legend --plain --no-pager 2>/dev/null | /usr/bin/grep .)
if [ -n "$_degraded_lines" ]; then
  _d=""
  _n=0
  while IFS= read -r _line; do
    [ -z "$_line" ] && continue
    _d="$_d $_line"
    _n=$((_n + 1))
  done <<EOF
$_degraded_lines
EOF
  emit "systemd.degraded" "$CAT" attention 1 "Degraded units" "${_n} unit(s)" \
    "Units in the degraded state are loaded but not fully working" \
    "Inspect: systemctl status <unit>" \
    $_d
else
  emit "systemd.degraded" "$CAT" ok 0 "Degraded units" "none" \
    "No degraded units" ""
fi

# ---------------------------------------------------------------- boot time
if have systemd-analyze; then
  _btime=$(/usr/bin/systemd-analyze 2>/dev/null | /usr/bin/head -n 1)
  # "Startup finished in 5.5s (firmware) + ... = 1min 19.6s" -- only the token
  # after '=' is the total; summing the components as well would double count.
  _total_part=$(printf '%s' "$_btime" | /usr/bin/sed -n 's/.*=[[:space:]]*//p')
  [ -z "$_total_part" ] && _total_part="$_btime"
  _duration_tokens=$(printf '%s' "$_total_part" | /usr/bin/grep -oE '[0-9]+min|[0-9]+(\.[0-9]+)?s')
  _secs=$(printf '%s\n' "$_duration_tokens" \
    | /usr/bin/awk '
        /min/ { sub(/min/,""); m+=$1 }
        /s/   { sub(/s/,"");   s+=$1 }
        END   { printf "%d", m*60+s }')
  case "$_secs" in '' | *[!0-9]*) _secs=0 ;; esac
  if [ -z "$_duration_tokens" ]; then
    emit "systemd.boot_time" "$CAT" unknown 0 "Boot time" "unknown" \
      "systemd-analyze produced no parsable duration" ""
  elif [ "$_secs" -ge 60 ]; then
    emitr "systemd.boot_time" "$CAT" attention 1 "Boot time" "${_secs}s" \
      "The last boot took ${_secs}s; this is slower than expected but is not by itself a boot failure" \
      "Find the slow units: systemd-analyze blame" \
      manual "Review slow services" "No automatic action is taken." \
      "raw: $_btime"
  else
    _boot_value=${_secs}s
    [ "$_secs" -eq 0 ] && _boot_value="<1s"
    emit "systemd.boot_time" "$CAT" ok 0 "Boot time" "$_boot_value" \
      "Boot time is healthy" ""
  fi

  _blame=$(/usr/bin/systemd-analyze blame --no-pager 2>/dev/null | /usr/bin/head -5)
  if [ -n "$_blame" ]; then
    emit "systemd.blame" "$CAT" info 0 "Slowest units" "top 5" \
      "The five slowest units at boot" "" \
      $_blame
  fi
else
  emit "systemd.boot_time" "$CAT" unknown 0 "Boot time" "unknown" \
    "systemd-analyze is not available" ""
fi

# ---------------------------------------------------------------- kernel cmdline
_cmdline=$(read_file /proc/cmdline)
if [ -n "$_cmdline" ]; then
  _bad=""
  for _p in nomodeset vga= video=; do
    case " $_cmdline " in
      *" $_p"*) _bad="$_bad $_p" ;;
    esac
  done
  # Also catch a bare "nomodeset" anywhere.
  case " $_cmdline " in
    *" nomodeset "*) _bad="$_bad nomodeset" ;;
  esac
  if [ -n "$_bad" ]; then
    emitr "systemd.kernel_cmdline" "$CAT" attention 1 "Kernel cmdline" "problematic" \
      "The kernel command line contains parameters that can break Wayland/DRM:$_bad" \
      "Remove them from the bootloader config unless a specific fix requires them" \
      manual "Review the kernel command line" "Edit the bootloader config (e.g. /etc/kernel/cmdline)." \
      "cmdline: $_cmdline"
  else
    emit "systemd.kernel_cmdline" "$CAT" ok 0 "Kernel cmdline" "ok" \
      "No known-problematic kernel parameters" ""
  fi
else
  emit "systemd.kernel_cmdline" "$CAT" unknown 0 "Kernel cmdline" "unknown" \
    "/proc/cmdline could not be read" ""
fi

emit_json "$CAT" "$MODE"
