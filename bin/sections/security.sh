#!/bin/sh
# System Diagnostics - Security section.
#
# A lightweight, non-exhaustive security posture check: firewall state, SSH key
# permissions, failed login attempts, listening sockets, Secure Boot and setuid
# binaries. Read-only; nothing is enabled, disabled or quarantined.
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/../bootstrap.sh"
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/../common.sh"

MODE=${1:-}
CAT=security
CHECKS=""

# ---------------------------------------------------------------- firewall
_fw=""
_fw_checked=0
_fw_unreadable=0
_fw_uncertain=0
if have ufw; then
  _ufw=$(/usr/bin/ufw status 2>/dev/null)
  _ufw_rc=$?
  case "$_ufw" in
    *"Status: active"*) [ "$_ufw_rc" -eq 0 ] && { _fw="ufw"; _fw_checked=1; } ;;
    *"Status: inactive"*) [ "$_ufw_rc" -eq 0 ] && _fw_checked=1 ;;
  esac
  [ "$_ufw_rc" -ne 0 ] && _fw_unreadable=1
fi
if [ -z "$_fw" ] && have nft; then
  _nft=$(/usr/bin/nft list ruleset 2>/dev/null)
  _nft_rc=$?
  if [ "$_nft_rc" -eq 0 ]; then
    _fw_checked=1
    if [ -n "$(printf '%s' "$_nft" | /usr/bin/grep -vE '^\s*$|^table' | /usr/bin/grep .)" ]; then
      # A ruleset can contain inactive chains or permissive policies. Only call
      # it a detected firewall when an input base chain explicitly defaults to
      # drop; otherwise we report that the ruleset needs human interpretation.
      _nft_input_drop=$(printf '%s\n' "$_nft" | /usr/bin/awk '
        /^[[:space:]]*chain[[:space:]]+/ {
          in_chain = 1; hook_input = ($0 ~ /hook input/); policy_drop = ($0 ~ /policy drop/)
          next
        }
        in_chain {
          if ($0 ~ /hook input/) hook_input = 1
          if ($0 ~ /policy drop/) policy_drop = 1
          if ($0 ~ /}/) {
            if (hook_input && policy_drop) found = 1
            in_chain = 0
          }
        }
        END { print found ? "yes" : "no" }
      ')
      if [ "$_nft_input_drop" = yes ]; then
        _fw="nftables"
      else
        _fw_uncertain=1
      fi
    fi
  else
    _fw_unreadable=1
  fi
fi
if [ -z "$_fw" ] && have firewall-cmd; then
  _fwstate=$(/usr/bin/firewall-cmd --state 2>/dev/null)
  _fwstate_rc=$?
  if [ "$_fwstate_rc" -eq 0 ]; then
    _fw_checked=1
    [ "$_fwstate" = running ] && _fw="firewalld"
  else
    _fw_unreadable=1
  fi
fi
if [ -z "$_fw" ] && ! have nft && ! have firewall-cmd; then
  _fw_unreadable=1
fi

if [ -n "$_fw" ]; then
  emit "security.firewall" "$CAT" ok 0 "Firewall" "$_fw" \
    "An active firewall was detected ($_fw)" ""
elif [ "$_fw_uncertain" -eq 1 ] || [ "$_fw_unreadable" -eq 1 ] || [ "$_fw_checked" -eq 0 ]; then
  emit "security.firewall" "$CAT" unknown 0 "Firewall" "unverified" \
    "Available firewall tools did not provide enough information to determine whether effective filtering is active" \
    "Review firewall policy with ufw status, nft list ruleset, or firewall-cmd --list-all"
else
  # Omarchy desktops commonly ship with no firewall: not an error, but worth an
  # explicit, actionable info entry rather than silence.
  emit "security.firewall" "$CAT" info 0 "Firewall" "none active" \
    "No active firewall detected (ufw/nftables/firewalld)" \
    "If this machine is exposed, enable one: sudo ufw enable"
fi

# ---------------------------------------------------------------- failed logins
if have journalctl; then
  _fail_lines=$(/usr/bin/journalctl -b 0 --no-pager -o cat -n 10000 \
    -g 'Failed password|authentication failure|Invalid user' 2>/dev/null)
  _fail_rc=$?
  if [ "$_fail_rc" -ne 0 ]; then
    emit "security.failed_logins" "$CAT" unknown 0 "Failed logins" "unknown" \
      "journalctl could not read authentication events (exit $_fail_rc)" \
      "Check journal permissions, then review: journalctl -b 0 -g 'Failed password|authentication failure|Invalid user'"
  else
    _fails=$(printf '%s\n' "$_fail_lines" | /usr/bin/grep -c .)
    case "$_fails" in '' | *[!0-9]*) _fails=0 ;; esac
    if [ "$_fails" -ge 10 ]; then
      emitr "security.failed_logins" "$CAT" attention 1 "Failed logins" "${_fails} this boot" \
        "${_fails} failed authentication attempts were logged in this boot" \
        "If SSH is exposed, consider key-only auth and fail2ban: journalctl -b 0 | grep 'Failed password'" \
        manual "Review authentication attempts" "No automatic action is taken." \
        "count: $_fails"
    elif [ "$_fails" -gt 0 ]; then
      emit "security.failed_logins" "$CAT" info 0 "Failed logins" "${_fails} this boot" \
        "${_fails} failed authentication attempts (usually a mistyped password)" ""
    else
      emit "security.failed_logins" "$CAT" ok 0 "Failed logins" "none" \
        "No failed authentication attempts this boot" ""
    fi
  fi
else
  emit "security.failed_logins" "$CAT" unknown 0 "Failed logins" "unknown" \
    "journalctl is not available to read authentication events" ""
fi

# ---------------------------------------------------------------- ssh permissions
if [ -d "$HOME/.ssh" ]; then
  _bad=""
  _perm=$(/usr/bin/stat -c '%a' "$HOME/.ssh" 2>/dev/null)
  case "$_perm" in
    700 | 750 | 755) ;;
    *) _bad="$_bad ~/.ssh:$_perm" ;;
  esac
  for _f in "$HOME/.ssh"/*; do
    [ -f "$_f" ] || continue
    _base=$(basename "$_f")
    case "$_base" in
      *.pub | known_hosts* | config | authorized_keys | authorized_keys2) continue ;;
    esac
    _p=$(/usr/bin/stat -c '%a' "$_f" 2>/dev/null)
    case "$_p" in
      600 | 400) ;;
      *) _bad="$_bad $_base:$_p" ;;
    esac
  done
  if [ -n "$_bad" ]; then
    emitr "security.ssh_perms" "$CAT" attention 1 "SSH permissions" "loose" \
      "SSH files have permissions that OpenSSH rejects or that expose keys:$_bad" \
      "Fix them: chmod 700 ~/.ssh; chmod 600 ~/.ssh/id_* ~/.ssh/config" \
      safe "Fix SSH permissions" "chmod only tightens permissions on your own files." \
      $_bad
  else
    emit "security.ssh_perms" "$CAT" ok 0 "SSH permissions" "ok" \
      "SSH directory and private keys have safe permissions" ""
  fi
fi

# ---------------------------------------------------------------- listening sockets
if have ss; then
  _ss=$(/usr/bin/ss -tulpnH 2>/dev/null)
  _ss_rc=$?
  if [ "$_ss_rc" -ne 0 ]; then
    emit "security.listening" "$CAT" unknown 0 "Listening sockets" "unknown" \
      "ss failed (exit $_ss_rc); listening sockets could not be checked" "Run: ss -tulpn"
  else
  _listen=$(printf '%s\n' "$_ss" | /usr/bin/wc -l | /usr/bin/tr -d ' ')
  case "$_listen" in '' | *[!0-9]*) _listen=0 ;; esac
  _nonlocal=$(printf '%s\n' "$_ss" \
    | /usr/bin/grep -vE '127\.0\.0\.1|\[::1\]|%lo' | /usr/bin/awk '{print $1, $5}' | /usr/bin/head -12)
  emitd "security.listening" "$CAT" info 0 "Listening sockets" "${_listen}" \
    "${_listen} listening TCP/UDP sockets; entries bound beyond loopback are listed" \
    "Review exposed services: ss -tulpn" \
    $_nonlocal
  fi
else
  emit "security.listening" "$CAT" unknown 0 "Listening sockets" "unknown" \
    "ss is unavailable; listening sockets could not be inspected" ""
fi

# ---------------------------------------------------------------- secure boot
if [ -d /sys/firmware/efi ]; then
  if have mokutil; then
    _sb=$(/usr/bin/mokutil --sb-state 2>/dev/null | /usr/bin/head -n 1)
    case "$_sb" in
      *"SecureBoot enabled"*) emit "security.secure_boot" "$CAT" ok 0 "Secure Boot" "enabled" "$_sb" ;;
      *"SecureBoot disabled"*) emit "security.secure_boot" "$CAT" info 0 "Secure Boot" "disabled" \
        "$_sb" "Secure Boot is optional; required only for some anti-cheat/DRM and Microsoft-signed modules" ;;
      *) emit "security.secure_boot" "$CAT" unknown 0 "Secure Boot" "unknown" "${_sb:-mokutil gave no state}" ;;
    esac
  else
    emit "security.secure_boot" "$CAT" unknown 0 "Secure Boot" "not checked" \
      "System booted via UEFI, but mokutil is unavailable so Secure Boot state could not be checked" ""
  fi
else
  emit "security.secure_boot" "$CAT" info 0 "Secure Boot" "legacy BIOS" \
    "System is not using UEFI, so Secure Boot does not apply" ""
fi

# ---------------------------------------------------------------- setuid binaries
if have find; then
  _suid=$(/usr/bin/find /usr/bin /usr/sbin -xdev \( -perm -4000 -o -perm -2000 \) -type f 2>/dev/null)
  _suid_rc=$?
  if [ "$_suid_rc" -eq 0 ]; then
    _n=$(printf '%s' "$_suid" | /usr/bin/grep -c .)
    case "$_n" in '' | *[!0-9]*) _n=0 ;; esac
    emitd "security.suid" "$CAT" info 0 "Setuid/setgid binaries" "${_n}" \
      "${_n} setuid/setgid binaries found under /usr/bin and /usr/sbin" \
      "Review unexpected entries; many system utilities legitimately use these permissions" \
      $_suid
  else
    emit "security.suid" "$CAT" unknown 0 "Setuid/setgid binaries" "unknown" \
      "find failed (exit $_suid_rc); privileged binaries could not be inventoried" ""
  fi
else
  emit "security.suid" "$CAT" unknown 0 "Setuid/setgid binaries" "unknown" \
    "find is unavailable; privileged binaries could not be inventoried" ""
fi

emit_json "$CAT" "$MODE"
