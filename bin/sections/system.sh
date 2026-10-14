#!/bin/sh
# System Diagnostics - System section.
#
# Host identity plus the coarse health signals that say whether the machine is
# under stress: load average, memory, swap and thermals. Read-only.
#
# Every probe degrades to an explicit unknown rather than to "ok": an
# unreadable /proc/meminfo must not be reported as a healthy memory state.
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/../bootstrap.sh"
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/../common.sh"

MODE=${1:-}
CAT=system
CHECKS=""

# ---------------------------------------------------------------- identity
_os=$(read_file /etc/os-release | sed -n 's/^PRETTY_NAME="\(.*\)"/\1/p')
[ -z "$_os" ] && _os="Unknown"
_kernel=$(/usr/bin/uname -r 2>/dev/null)
_arch=$(/usr/bin/uname -m 2>/dev/null)
_host=$(read_file /proc/sys/kernel/hostname)
_cpu=$(read_file /proc/cpuinfo | sed -n 's/^model name[[:space:]]*:[[:space:]]*//p' | /usr/bin/head -n 1)
_nproc=$(/usr/bin/getconf _NPROCESSORS_ONLN 2>/dev/null || /usr/bin/nproc 2>/dev/null)

emitd "system.identity" "$CAT" ok 0 "Host identity" "$_host" \
  "$_os, kernel $_kernel ($_arch), ${_nproc:-?} CPUs" "" \
  "$_cpu"

# ---------------------------------------------------------------- kernel
# Compare against the package that supplied the running kernel. Comparing
# against the generic `linux` package is wrong on Omarchy's custom kernels and
# reports a reboot as necessary even when the active kernel is current.
if have pacman; then
  _pkgbase=$(read_file "/usr/lib/modules/$_kernel/pkgbase")
  if [ -n "$_pkgbase" ] && [ -n "$_kernel" ]; then
    _kernel_pkg=$(/usr/bin/pacman -Q "$_pkgbase" 2>/dev/null)
    _kernel_pkg_rc=$?
    _inst=$(printf '%s\n' "$_kernel_pkg" | /usr/bin/awk 'NR==1 {print $2}')
    # Arch package versions use dots for pkgrel separators such as .arch1;
    # uname uses hyphens ( -arch1 ). Normalize before comparing.
    _inst_release=$(printf '%s' "$_inst" | /usr/bin/sed \
      -e 's/\.arch/-arch/g' -e 's/\.zen/-zen/g' \
      -e 's/\.hardened/-hardened/g' -e 's/\.lts/-lts/g')
    if [ "$_kernel_pkg_rc" -ne 0 ] || [ -z "$_inst" ]; then
      emit "system.kernel" "$CAT" unknown 0 "Kernel" "unknown" \
        "The running kernel identifies package $_pkgbase, but its installed package version could not be read" \
        "Run: pacman -Q '$_pkgbase'"
    else
      case "$_kernel" in
        "$_inst_release"*)
          emit "system.kernel" "$CAT" ok 0 "Kernel" "$_kernel" \
            "Running kernel matches installed package $_pkgbase ($_inst)" "" ;;
        *)
          emitr "system.kernel" "$CAT" attention 1 "Kernel" "$_kernel" \
            "Installed package $_pkgbase is $_inst but the running kernel is $_kernel" \
            "Reboot to start the updated kernel and pick up its fixes" \
            safe "Reboot" "A reboot loads the installed kernel. Not run by this plugin." \
            "running: $_kernel" "package: $_pkgbase $_inst" ;;
      esac
    fi
  else
    emit "system.kernel" "$CAT" unknown 0 "Kernel" "unknown" \
      "Could not identify the package that supplied the running kernel" \
      "Check /usr/lib/modules/$(uname -r)/pkgbase and compare with pacman -Q"
  fi
else
  emit "system.kernel" "$CAT" unknown 0 "Kernel" "unknown" \
    "pacman is unavailable; installed kernel version could not be compared with the running kernel" ""
fi

# ---------------------------------------------------------------- uptime
_up_s=$(read_file /proc/uptime | /usr/bin/awk '{print int($1)}')
if [ -n "$_up_s" ]; then
  _up_d=$(( _up_s / 86400 ))
  _up_h=$(( (_up_s % 86400) / 3600 ))
  emit "system.uptime" "$CAT" info 0 "Uptime" "${_up_d}d ${_up_h}h" \
    "System has been up for ${_up_s}s; uptime alone does not indicate a fault" ""
else
  emit "system.uptime" "$CAT" unknown 0 "Uptime" "unknown" \
    "/proc/uptime could not be read" ""
fi

# ---------------------------------------------------------------- load average
_readavg=$(read_file /proc/loadavg)
if [ -n "$_readavg" ] && [ -n "$_nproc" ] && [ "$_nproc" -gt 0 ] 2>/dev/null; then
  _l1=$(printf '%s' "$_readavg" | /usr/bin/awk '{print $1}')
  _l5=$(printf '%s' "$_readavg" | /usr/bin/awk '{print $2}')
  _l15=$(printf '%s' "$_readavg" | /usr/bin/awk '{print $3}')
  _ratio=$(/usr/bin/awk -v l="$_l1" -v n="$_nproc" 'BEGIN{ if (n>0) printf "%.2f", l/n; else printf "0" }')
  _high=$(/usr/bin/awk -v r="$_ratio" 'BEGIN{ print (r >= 1.0) ? "1" : "0" }')
  if [ "$_high" = "1" ]; then
    emitr "system.load" "$CAT" attention 1 "Load average" "$_l1 $_l5 $_l15" \
      "1-minute load ${_l1} is at or above the ${_nproc} online CPUs" \
      "Find the busy process with: ps -eo pid,comm,%cpu --sort=-%cpu | head" \
      manual "Investigate the busy process" "No automatic action is taken." \
      "load1: $_l1" "cpus: $_nproc" "ratio: $_ratio"
  else
    emit "system.load" "$CAT" ok 0 "Load average" "$_l1 $_l5 $_l15" \
      "Load is within ${_nproc} CPUs" ""
  fi
else
  emit "system.load" "$CAT" unknown 0 "Load average" "unknown" \
    "/proc/loadavg could not be read" ""
fi

# ---------------------------------------------------------------- memory
_meminfo=$(read_file /proc/meminfo)
if [ -n "$_meminfo" ]; then
  _total_k=$(printf '%s' "$_meminfo" | /usr/bin/awk '/^MemTotal:/{print $2}')
  _avail_k=$(printf '%s' "$_meminfo" | /usr/bin/awk '/^MemAvailable:/{print $2}')
  _cache_k=$(printf '%s' "$_meminfo" | /usr/bin/awk '/^Cached:/{print $2}')
  if [ -n "$_total_k" ] && [ -n "$_avail_k" ] && [ "$_total_k" -gt 0 ] 2>/dev/null; then
    _used_pct=$(/usr/bin/awk -v t="$_total_k" -v a="$_avail_k" 'BEGIN{ printf "%d", ((t-a)*100)/t }')
    _used_h=$(/usr/bin/awk -v t="$_total_k" -v a="$_avail_k" 'BEGIN{ printf "%.1fGiB / %.1fGiB", (t-a)/1048576, t/1048576 }')
    if [ "$_used_pct" -ge 92 ]; then
      emitr "system.memory" "$CAT" problem 3 "Memory" "${_used_pct}% used" \
        "Memory is nearly exhausted ($_used_h); the OOM killer may act" \
        "Close heavy apps or add RAM; inspect with: ps -eo pid,comm,%mem --sort=-%mem | head" \
        manual "Reduce memory pressure" "No process is killed or restarted by this plugin." \
        "MemTotal_kB: $_total_k" "MemAvailable_kB: $_avail_k"
    elif [ "$_used_pct" -ge 80 ]; then
      emitr "system.memory" "$CAT" attention 1 "Memory" "${_used_pct}% used" \
        "Memory usage is high ($_used_h)" \
        "Watch for swap thrashing; inspect with: ps -eo pid,comm,%mem --sort=-%mem | head" \
        manual "Review memory-hungry processes" "No automatic action is taken." \
        "MemTotal_kB: $_total_k" "MemAvailable_kB: $_avail_k"
    else
      emit "system.memory" "$CAT" ok 0 "Memory" "${_used_pct}% used" \
        "Available memory is healthy ($_used_h)" ""
    fi
  else
    emit "system.memory" "$CAT" unknown 0 "Memory" "unknown" \
      "/proc/meminfo did not expose MemTotal/MemAvailable" ""
  fi
else
  emit "system.memory" "$CAT" unknown 0 "Memory" "unknown" \
    "/proc/meminfo could not be read" ""
fi

# ---------------------------------------------------------------- swap
_swaptotal_k=$(printf '%s' "$_meminfo" | /usr/bin/awk '/^SwapTotal:/{print $2}')
_swapfree_k=$(printf '%s' "$_meminfo" | /usr/bin/awk '/^SwapFree:/{print $2}')
if [ -n "$_swaptotal_k" ] && [ "$_swaptotal_k" -gt 0 ] 2>/dev/null && [ -n "$_swapfree_k" ]; then
  _swap_used_pct=$(/usr/bin/awk -v t="$_swaptotal_k" -v f="$_swapfree_k" 'BEGIN{ printf "%d", ((t-f)*100)/t }')
  _swap_h=$(/usr/bin/awk -v t="$_swaptotal_k" -v f="$_swapfree_k" 'BEGIN{ printf "%.1fGiB / %.1fGiB", (t-f)/1048576, t/1048576 }')
  if [ "$_swap_used_pct" -ge 50 ]; then
    emitr "system.swap" "$CAT" attention 1 "Swap" "${_swap_used_pct}% used" \
      "$_swap_h of swap in use indicates memory pressure" \
      "Frequent swap use slows the machine; consider more RAM" \
      manual "Review memory pressure" "No automatic action is taken." \
      "SwapTotal_kB: $_swaptotal_k" "SwapFree_kB: $_swapfree_k"
  else
    emit "system.swap" "$CAT" ok 0 "Swap" "${_swap_used_pct}% used" \
      "$_swap_h of swap in use" ""
  fi
elif [ "$_swaptotal_k" = "0" ]; then
  emit "system.swap" "$CAT" info 0 "Swap" "none" \
    "No swap is configured" \
    "Omarchy laptops usually have a swapfile; hibernation needs one"
else
  emit "system.swap" "$CAT" unknown 0 "Swap" "unknown" \
    "Swap totals could not be read from /proc/meminfo" ""
fi

# ---------------------------------------------------------------- thermals
_hot=""
_hot_lines=""
_max_temp=0
for _tz in /sys/class/thermal/thermal_zone*; do
  [ -r "$_tz/temp" ] || continue
  _type=$(read_file "$_tz/type")
  _t=$(read_file "$_tz/temp")
  case "$_t" in '' | *[!0-9-]*) continue ;; esac
  _c=$(( _t / 1000 ))
  if [ "$_c" -gt "$_max_temp" ]; then _max_temp=$_c; fi
  if [ "$_c" -ge 75 ]; then
    _hot="$_hot $_type:${_c}C"
  fi
  _hot_lines="$_hot_lines$_type ${_c}C
"
done

if [ "$_max_temp" -gt 0 ]; then
  if [ "$_max_temp" -ge 90 ]; then
    emitr "system.thermal" "$CAT" problem 3 "Thermals" "${_max_temp}C peak" \
      "A thermal zone is at ${_max_temp}C; the CPU/GPU is likely throttling" \
      "Check cooling: sensors; clean fans and vents, verify thermal paste" \
      manual "Investigate cooling" "No automatic action is taken." \
      "peak_c: $_max_temp" "hot_zones:${_hot}"
  elif [ "$_max_temp" -ge 80 ]; then
    emitr "system.thermal" "$CAT" attention 1 "Thermals" "${_max_temp}C peak" \
      "A thermal zone is warm at ${_max_temp}C" \
      "Monitor under load with: watch sensors" \
      manual "Monitor temperatures" "No automatic action is taken." \
      "peak_c: $_max_temp" "hot_zones:${_hot}"
  else
    emit "system.thermal" "$CAT" ok 0 "Thermals" "${_max_temp}C peak" \
      "All thermal zones below 80C" ""
  fi
else
  emit "system.thermal" "$CAT" unknown 0 "Thermals" "unknown" \
    "No readable /sys/class/thermal zones" ""
fi

# ---------------------------------------------------------------- cpu governor
_governor=$(read_file /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)
if [ -n "$_governor" ]; then
  case "$_governor" in
    powersave)
      emit "system.cpu_governor" "$CAT" info 0 "CPU governor" "$_governor" \
        "CPU governor is powersave (common on battery) — check with: omarchy cpu governor" ;;
    *)
      emit "system.cpu_governor" "$CAT" info 0 "CPU governor" "$_governor" \
        "Active CPU scaling governor" ;;
  esac
else
  emit "system.cpu_governor" "$CAT" unknown 0 "CPU governor" "not exposed" \
    "The scaling governor is not exposed at /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor" ""
fi

emit_json "$CAT" "$MODE"
