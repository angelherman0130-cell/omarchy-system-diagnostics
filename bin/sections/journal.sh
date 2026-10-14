#!/bin/sh
# System Diagnostics - Journal section.
#
# Error-level journal entries for the current boot (and, in full mode, previous
# boots), plus core dumps and OOM kills. Read-only.
#
# Noise policy: the journal at priority err/alert/crit is full of benign
# firmware chatter (ACPI region warnings, a Bluetooth device that is merely
# asleep). Those entries are still surfaced in `details` so an AI reading the
# report can see them, but they do not by themselves raise the status above ok;
# only NON-noise errors, coredumps or OOM kills do.
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/../bootstrap.sh"
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/../common.sh"

MODE=${1:-}
CAT=journal
CHECKS=""

if ! have journalctl; then
  emit "journal.section" "$CAT" unknown 0 "Journal" "unavailable" \
    "journalctl not found on PATH" ""
  emit_json "$CAT" "$MODE"
  exit 0
fi

# ben_boot_errors BOOTTAG -> emits the check(s) for that boot.
# BOOTTAG is 0 (current), -1, -2, ...
ben_boot_errors() {
  _tag=$1
  _label=$2
  _raw=$(/usr/bin/journalctl -p 0..3 -b "$_tag" --no-pager --no-hostname -n 400 2>/dev/null \
    | /usr/bin/grep -v 'angelherman.system-diagnostics' \
    | /usr/bin/grep -v '^-- No entries --$')
  [ -z "$(printf '%s' "$_raw" | /usr/bin/grep .)" ] && return 0

  _total=$(printf '%s' "$_raw" | /usr/bin/grep -c .)
  # Sources: the "SYSLOG_IDENTIFIER" is usually the token after the timestamp.
  _sources=$(printf '%s' "$_raw" \
    | /usr/bin/awk '{ for (i=1;i<=NF;i++) { if ($i ~ /[a-zA-Z0-9_.-]+\[[0-9]+\]:/ || $i ~ /^[a-zA-Z0-9_.-]+:$/ || $i ~ /^[a-zA-Z0-9_.-]+:[0-9]+$/) { t=$i; sub(/\[[0-9]+\]:?$/,"",t); sub(/:.*$/,"",t); print t; break } } }' \
    | /usr/bin/grep . \
    | /usr/bin/sort | /usr/bin/uniq -c | /usr/bin/sort -rn | /usr/bin/head -8)

  # Noise filter: lines that match these are firmware/hardware chatter.
  _noise=$(printf '%s' "$_raw" | /usr/bin/grep -ciE \
    'ACPI (Error|BIOS Error|Warning)|firmware|Bluetooth|hci|audit|systemd-analyze|wpa_supplicant|iwlwifi .*(fail|err)|Thermal event|GPIO|pcieport')
  _real=$(( _total - _noise ))
  [ "$_real" -lt 0 ] && _real=0

  # Build a details array: source histogram first, then up to N raw lines.
  _d=""
  _n=0
  while IFS= read -r _line; do
    [ -z "$_line" ] && continue
    _d="$_d sources:$_line"
    _n=$((_n + 1))
    [ "$_n" -ge 8 ] && break
  done <<EOF
$_sources
EOF
  _n=0
  while IFS= read -r _line; do
    [ -z "$_line" ] && continue
    _d="$_d $(printf '%s' "$_line" | /usr/bin/head -c 300)"
    _n=$((_n + 1))
    [ "$_n" -ge 30 ] && break
  done <<EOF
$(printf '%s' "$_raw" | /usr/bin/tail -n 30)
EOF

  _id="journal.errors_current"
  [ "$_tag" != "0" ] && _id="journal.errors_boot_$_tag"
  if [ "$_real" -gt 0 ]; then
    emitr "$_id" "$CAT" attention 1 "$_label" "${_real} real / ${_total} total" \
      "${_real} journal error-level entries in ${_label} are not known firmware noise" \
      "Read them: journalctl -p 3 -b $_tag --no-pager -n 200" \
      manual "Review journal errors" "No automatic action is taken." \
      $_d
  else
    emit "journal.errors_current_desc" "$CAT" info 0 "$_label" "${_total} noise-only" \
      "${_total} error-level entries, all matching known firmware/hardware noise" \
      "Inspect if unexpected: journalctl -p 3 -b $_tag --no-pager" \
      $_d
  fi
}

ben_boot_errors 0 "Journal errors (this boot)"

if is_full; then
  ben_boot_errors -1 "Journal errors (previous boot)"
fi

# ---------------------------------------------------------------- coredumps
if have coredumpctl; then
  _cores=$(/usr/bin/coredumpctl list --no-pager 2>/dev/null | /usr/bin/grep -vE '^\s*TIME|^\s*$')
  if [ -n "$_cores" ]; then
    _ntotal=$(printf '%s' "$_cores" | /usr/bin/grep -c .)
    _d=""
    _n=0
    while IFS= read -r _line; do
      [ -z "$_line" ] && continue
      _d="$_d $(printf '%s' "$_line" | /usr/bin/head -c 300)"
      _n=$((_n + 1))
      [ "$_n" -ge 10 ] && break
    done <<EOF
$(printf '%s' "$_cores" | /usr/bin/tail -n 10)
EOF
    # A crash in the current boot is more urgent than an old one.
    _thisboot=$(/usr/bin/journalctl -b 0 --no-pager -o cat 2>/dev/null | /usr/bin/grep -ci 'coredump\|segfault\|general protection\|dumped core')
    if [ "$_thisboot" -gt 0 ] 2>/dev/null; then
      emitr "journal.coredumps" "$CAT" problem 3 "Core dumps" "${_ntotal} recorded" \
        "At least one process crashed during this boot" \
        "Inspect the newest: coredumpctl info; coredumpctl gdb" \
        manual "Investigate the crashing program" "No automatic action is taken." \
        $_d
    else
      emitr "journal.coredumps" "$CAT" attention 1 "Core dumps" "${_ntotal} recorded" \
        "Process crashes were recorded by coredumpctl (none this boot)" \
        "Inspect the newest: coredumpctl info" \
        manual "Review recorded crashes" "No automatic action is taken." \
        $_d
    fi
  else
    emit "journal.coredumps" "$CAT" ok 0 "Core dumps" "none" \
      "coredumpctl has no recorded crashes" ""
  fi
else
  emit "journal.coredumps" "$CAT" unknown 0 "Core dumps" "unknown" \
    "coredumpctl is not available" ""
fi

# ---------------------------------------------------------------- OOM kills
# Only the kernel OOM killer counts. Matching bare "Out of memory" catches the
# NVIDIA driver's NV_ERR_NO_MEMORY assertions (NVRM lines), which are unrelated.
_oom=$(/usr/bin/journalctl -k -b 0 --no-pager \
  -g 'Out of memory: Killed process|oom-kill:|invoked oom-killer|Killed process [0-9]+' 2>/dev/null \
  | /usr/bin/grep -v 'NVRM' | /usr/bin/grep -v '^-- No entries --$' | /usr/bin/grep .)
if [ -n "$_oom" ]; then
  _d=""
  _n=0
  while IFS= read -r _line; do
    [ -z "$_line" ] && continue
    _d="$_d $(printf '%s' "$_line" | /usr/bin/head -c 300)"
    _n=$((_n + 1))
    [ "$_n" -ge 10 ] && break
  done <<EOF
$_oom
EOF
  emitr "journal.oom" "$CAT" problem 3 "OOM kills" "this boot" \
    "The kernel OOM killer acted during this boot: memory was exhausted" \
    "Reduce memory pressure; inspect: free -h; journalctl -k -b 0 -g 'Out of memory'" \
    manual "Reduce memory pressure" "No process is killed or restarted by this plugin." \
    $_d
else
  emit "journal.oom" "$CAT" ok 0 "OOM kills" "none" \
    "No OOM killer activity this boot" ""
fi

emit_json "$CAT" "$MODE"
