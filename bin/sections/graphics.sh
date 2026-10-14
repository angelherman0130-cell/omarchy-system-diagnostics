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
  *)       emit "graphics.session" "$CAT" info 0 "Session" "$_sess" "Session type could not be determined here" "" ;;
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
  fi
fi

# ---------------------------------------------------------------- DRM nodes
if [ -d /dev/dri ]; then
  _cards=$(/usr/bin/ls /dev/dri 2>/dev/null | /usr/bin/tr '\n' ' ')
  emit "graphics.dri" "$CAT" ok 0 "DRM devices" "present" \
    "Direct rendering nodes: $_cards" ""
else
  emitr "graphics.dri" "$CAT" problem 3 "DRM devices" "missing" \
    "/dev/dri is missing, so there is no direct rendering (compositor may be software-only)" \
    "Check the kernel driver: dmesg | grep -iE 'drm|gpu'" \
    manual "Investigate the graphics driver" "No automatic action is taken."
fi

# ---------------------------------------------------------------- driver errors
if have journalctl; then
  _gerr=$(/usr/bin/journalctl -k -b 0 --no-pager 2>/dev/null \
    | /usr/bin/grep -iE 'NVRM|amdgpu: (ERROR|.*fail)|i915 .*(error|fail)|drm.*(error|fail)|GPU has fallen off the bus|Xid' \
    | /usr/bin/grep -viE 'nvAssertOkFailedNoLog' | /usr/bin/head -12)
  # NVIDIA also logs benign nvAssert messages; exclude the noisy ones but keep
  # the printk-less assertions only when they are not the common "NoLog" line.
  _nvrnm=$(/usr/bin/journalctl -k -b 0 --no-pager 2>/dev/null \
    | /usr/bin/grep -icE 'NVRM:.*Assertion failed|Xid')
  case "$_nvrnm" in '' | *[!0-9]*) _nvrnm=0 ;; esac
  if [ -n "$_gerr" ] || [ "$_nvrnm" -gt 0 ]; then
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
      "The kernel logged graphics-driver errors this boot (count ${_nvrnm}); they can cause stutter or app crashes" \
      "Update the driver/Mesa; check the full log: journalctl -k -b 0 | grep -iE 'NVRM|drm|gpu'" \
      manual "Review graphics driver errors" "No automatic action is taken." \
      $_d
  else
    emit "graphics.driver_errors" "$CAT" ok 0 "Graphics driver" "clean" \
      "No graphics-driver errors in this boot" ""
  fi
fi

# ---------------------------------------------------------------- vulkan (full)
if is_full && have vulkaninfo; then
  _vk=$(/usr/bin/timeout -k 2 10 /usr/bin/vulkaninfo --summary 2>/dev/null | /usr/bin/head -40)
  if [ -n "$(printf '%s' "$_vk" | /usr/bin/grep .)" ]; then
    emitd "graphics.vulkan" "$CAT" info 0 "Vulkan" "available" \
      "vulkaninfo reported at least one Vulkan device" "" $_vk
  else
    emit "graphics.vulkan" "$CAT" attention 1 "Vulkan" "unavailable" \
      "vulkaninfo produced no device summary; Vulkan apps may fail" \
      "Install/refresh the Vulkan ICD: sudo pacman -S vulkan-icd-loader"
  fi
fi

emit_json "$CAT" "$MODE"
