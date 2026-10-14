#!/bin/sh
# System Diagnostics - Graphics section.
#
# GPUs, the active session type, the DRM device nodes, and graphics-driver
# errors the kernel logged this boot. Read-only.
#
# The kernel-log probe matters here: on NVIDIA hardware, driver assertion
# failures ("NVRM: ... Assertion failed") appear only in the journal, never in a
# status command, and are a common cause of stutter and app crashes.
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/../bootstrap.sh"
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/../common.sh"

MODE=${1:-}
CAT=graphics
CHECKS=""

# ---------------------------------------------------------------- session type
_sess="${XDG_SESSION_TYPE:-unknown}"
case "$_sess" in
  wayland) emit "graphics.session" "$CAT" ok 0 "Session" "wayland" "Running on Wayland ($_sess)" "" ;;
  x11)     emit "graphics.session" "$CAT" info 0 "Session" "x11" "Running on X11; Omarchy targets Wayland" "" ;;
  *)       emit "graphics.session" "$CAT" unknown 0 "Session" "$_sess" "Session type could not be determined here" "" ;;
esac

# ---------------------------------------------------------------- GPUs
if have lspci; then
  _gpus=$(/usr/bin/lspci 2>/dev/null | /usr/bin/grep -iE 'VGA compatible controller|3D controller|Display controller')
  if [ -n "$_gpus" ]; then
    _d=""
    while IFS= read -r _line; do [ -n "$_line" ] && _d="$_d $_line"; done <<EOF
$_gpus
EOF
    emitd "graphics.gpu" "$CAT" info 0 "GPUs" "$(printf '%s' "$_gpus" | /usr/bin/grep -c .)" \
      "Detected display adapters" "" $_d
  else
    emit "graphics.gpu" "$CAT" unknown 0 "GPUs" "not detected" \
      "lspci did not report a display adapter; this can also happen in virtual or headless environments" ""
  fi
else
  emit "graphics.gpu" "$CAT" unknown 0 "GPUs" "not checked" \
    "lspci is unavailable; the display adapter inventory could not be checked" ""
fi

# ---------------------------------------------------------------- DRM nodes
if [ -d /dev/dri ]; then
  _cards=$(/usr/bin/ls /dev/dri 2>/dev/null | /usr/bin/tr '\n' ' ')
  emit "graphics.dri" "$CAT" ok 0 "DRM devices" "present" \
    "Direct rendering nodes: $_cards" ""
else
  emitr "graphics.dri" "$CAT" attention 1 "DRM devices" "missing" \
    "/dev/dri is missing, so there is no direct rendering (compositor may be software-only)" \
    "Check the kernel driver: dmesg | grep -iE 'drm|gpu'" \
    manual "Investigate the graphics driver" "No automatic action is taken."
fi

# ---------------------------------------------------------------- driver errors
if have journalctl; then
  _gerr_raw=$(/usr/bin/journalctl -k -b 0 --no-pager 2>/dev/null)
  _gerr_rc=$?
  _gerr=$(printf '%s\n' "$_gerr_raw" \
    | /usr/bin/grep -iE 'NVRM:.*(Xid|error|fail|assertion failed|fallen off the bus)|amdgpu: (ERROR|.*fail)|i915 .*(error|fail)|drm.*(error|fail)|GPU has fallen off the bus' \
    | /usr/bin/grep -viE 'nvAssertOkFailedNoLog' | /usr/bin/head -12)
  # Driver load notices and unrelated devices' XID fields are not GPU errors.
  _nvrnm=$(printf '%s\n' "$_gerr" | /usr/bin/grep -icE 'NVRM:.*(Xid|error|fail|assertion failed|fallen off the bus)')
  case "$_nvrnm" in '' | *[!0-9]*) _nvrnm=0 ;; esac
  if [ "$_gerr_rc" -ne 0 ]; then
    emit "graphics.driver_errors" "$CAT" unknown 0 "Graphics driver" "unknown" \
      "journalctl could not read kernel messages (exit $_gerr_rc); graphics errors could not be checked" \
      "Check journal permissions, then run: journalctl -k -b 0"
  elif [ -n "$_gerr" ] || [ "$_nvrnm" -gt 0 ]; then
    _d=""
    _k=0
    while IFS= read -r _line; do
      [ -z "$_line" ] && continue
      _d="$_d $(printf '%s' "$_line" | /usr/bin/head -c 300)"
      _k=$((_k + 1))
      [ "$_k" -ge 12 ] && break
    done <<EOF
$_gerr
EOF
    emitr "graphics.driver_errors" "$CAT" attention 1 "Graphics driver" "errors this boot" \
      "The kernel logged messages matching known graphics-driver error patterns; review the evidence before treating them as faults" \
      "Update the driver/Mesa; check the full log: journalctl -k -b 0 | grep -iE 'NVRM|drm|gpu'" \
      manual "Review graphics driver errors" "No automatic action is taken." \
      $_d
  else
    emit "graphics.driver_errors" "$CAT" ok 0 "Graphics driver" "clean" \
      "No graphics-driver errors in this boot" ""
  fi
else
  emit "graphics.driver_errors" "$CAT" unknown 0 "Graphics driver" "unknown" \
    "journalctl is unavailable; kernel graphics errors could not be checked" ""
fi

# ---------------------------------------------------------------- vulkan (full)
if is_full; then
  if have vulkaninfo; then
    _vk=$(/usr/bin/timeout -k 2 10 /usr/bin/vulkaninfo --summary 2>/dev/null)
    _vk_rc=$?
    _vk=$(printf '%s\n' "$_vk" | /usr/bin/head -40)
    if [ -n "$(printf '%s' "$_vk" | /usr/bin/grep .)" ] && [ "$_vk_rc" -eq 0 ]; then
      emitd "graphics.vulkan" "$CAT" info 0 "Vulkan" "available" \
        "vulkaninfo reported at least one Vulkan device" "" $_vk
    elif [ "$_vk_rc" -eq 124 ] || [ "$_vk_rc" -eq 137 ]; then
      emit "graphics.vulkan" "$CAT" unknown 0 "Vulkan" "timed out" \
        "vulkaninfo exceeded its 10-second timeout" "Inspect the Vulkan driver and ICD configuration"
    elif [ "$_vk_rc" -ne 0 ]; then
      emit "graphics.vulkan" "$CAT" attention 1 "Vulkan" "unavailable" \
        "vulkaninfo exited $_vk_rc without a usable device summary; Vulkan applications may fail" \
        "Inspect installed Vulkan ICDs and run: vulkaninfo --summary"
    else
      emit "graphics.vulkan" "$CAT" unknown 0 "Vulkan" "no device reported" \
        "vulkaninfo returned no device summary; this may be expected on a headless system" ""
    fi
  else
    emit "graphics.vulkan" "$CAT" unknown 0 "Vulkan" "not checked" \
      "vulkaninfo is unavailable; Vulkan support could not be checked" ""
  fi
fi

emit_json "$CAT" "$MODE"
