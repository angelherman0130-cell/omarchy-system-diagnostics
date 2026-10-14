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
if have ufw; then
  _ufw=$(/usr/bin/ufw status 2>/dev/null | /usr/bin/head -n 1)
  case "$_ufw" in
    *"Status: active"*) _fw="ufw" ;;
    *"Status: inactive"*) _fw="" ;;
  esac
fi
if [ -z "$_fw" ] && have nft; then
  _nft=$(/usr/bin/nft list ruleset 2>/dev/null)
  [ -n "$(printf '%s' "$_nft" | /usr/bin/grep -vE '^\s*$|^table' | /usr/bin/grep .)" ] && _fw="nftables"
fi
if [ -z "$_fw" ] && have firewall-cmd; then
  /usr/bin/firewall-cmd --state 2>/dev/null | /usr/bin/grep -q running && _fw="firewalld"
fi

if [ -n "$_fw" ]; then
  emit "security.firewall" "$CAT" ok 0 "Firewall" "$_fw" \
    "An active firewall was detected ($_fw)" ""
else
  # Omarchy desktops commonly ship with no firewall: not an error, but worth an
  # explicit, actionable info entry rather than silence.
  emit "security.firewall" "$CAT" info 0 "Firewall" "none active" \
    "No active firewall detected (ufw/nftables/firewalld)" \
    "If this machine is exposed, enable one: sudo ufw enable"
fi

# ---------------------------------------------------------------- failed logins
if have journalctl; then
  _fails=$(/usr/bin/journalctl -b 0 --no-pager 2>/dev/null \
    | /usr/bin/grep -ciE 'Failed password|authentication failure|Invalid user')
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
      *.pub | known_hosts* | config) continue ;;
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
  _listen=$(/usr/bin/ss -tulpnH 2>/dev/null | /usr/bin/wc -l | /usr/bin/tr -d ' ')
  case "$_listen" in '' | *[!0-9]*) _listen=0 ;; esac
  _nonlocal=$(/usr/bin/ss -tulpnH 2>/dev/null \
    | /usr/bin/grep -vE '127\.0\.0\.1|\[::1\]|%lo' | /usr/bin/awk '{print $1, $5}' | /usr/bin/head -12)
  emitd "security.listening" "$CAT" info 0 "Listening sockets" "${_listen}" \
    "${_listen} listening TCP/UDP sockets; entries bound beyond loopback are listed" \
    "Review exposed services: ss -tulpn" \
    $_nonlocal
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
    emit "security.secure_boot" "$CAT" info 0 "Secure Boot" "UEFI" \
      "System booted via UEFI; mokutil unavailable to read Secure Boot state" ""
  fi
else
  emit "security.secure_boot" "$CAT" info 0 "Secure Boot" "legacy BIOS" \
    "System is not using UEFI, so Secure Boot does not apply" ""
fi

# ---------------------------------------------------------------- setuid binaries
if have find; then
  _suid=$(/usr/bin/find /usr/bin /usr/sbin /bin /sbin -xdev -perm -4000 -type f 2>/dev/null)
  _n=$(printf '%s' "$_suid" | /usr/bin/grep -c .)
  case "$_n" in '' | *[!0-9]*) _n=0 ;; esac
  emitd "security.suid" "$CAT" info 0 "Setuid binaries" "${_n}" \
    "${_n} setuid/setgid binaries in the system bin paths" \
    "Unexpected setuid binaries are a privilege-escalation risk; review the list" \
    $_suid
fi

emit_json "$CAT" "$MODE"
