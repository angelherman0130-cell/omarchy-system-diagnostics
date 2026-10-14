#!/bin/sh
# System Diagnostics - Network section.
#
# Interface inventory, default route, DNS configuration and (full mode only)
# reachability and name resolution. Read-only.
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/../bootstrap.sh"
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/../common.sh"

MODE=${1:-}
CAT=network
CHECKS=""

# ---------------------------------------------------------------- interfaces
if have ip; then
  _if=$(/usr/bin/ip -br addr 2>/dev/null)
  if [ -n "$_if" ]; then
    # A physical interface with no carrier is worth an info entry; no link at
    # all is worth attention only when there is also no default route.
    emitd "network.interfaces" "$CAT" info 0 "Interfaces" "$(printf '%s' "$_if" | /usr/bin/grep -c .)" \
      "Network interfaces and their addresses" "" \
       $_if
  else
    emit "network.interfaces" "$CAT" unknown 0 "Interfaces" "unknown" \
      "ip returned no interface inventory" ""
  fi
else
  emit "network.interfaces" "$CAT" unknown 0 "Interfaces" "unknown" \
    "the ip command is not available" ""
fi

# ---------------------------------------------------------------- default route
_gw=""
if have ip; then
  _gw_raw=$(/usr/bin/ip route show default 2>/dev/null)
  _gw_rc=$?
  _gw=$(printf '%s\n' "$_gw_raw" | /usr/bin/head -n 1)
  if [ "$_gw_rc" -ne 0 ]; then
    emit "network.gateway" "$CAT" unknown 0 "Default route" "unknown" \
      "ip route failed (exit $_gw_rc); the default route could not be checked" ""
  elif [ -n "$_gw" ]; then
    emit "network.gateway" "$CAT" ok 0 "Default route" "$(printf '%s' "$_gw" | /usr/bin/awk '{print $3}')" \
      "Default route present: $_gw" ""
  else
    emit "network.gateway" "$CAT" info 0 "Default route" "absent" \
      "ip reported no default route; this can be intentional on offline or isolated systems" \
      "Check the connection: nmcli device status; ip route"
  fi
else
  emit "network.gateway" "$CAT" unknown 0 "Default route" "unknown" \
    "ip is unavailable; the default route could not be checked" \
    "Install iproute2 or inspect the route table with an available network tool"
fi

# ---------------------------------------------------------------- DNS
_dns=""
if have resolvectl; then
  _dns=$(/usr/bin/resolvectl status 2>/dev/null | /usr/bin/grep -E 'Current DNS Server|DNS Servers' | /usr/bin/head -4)
fi
if [ -z "$_dns" ] && [ -r /etc/resolv.conf ]; then
  _dns=$(/usr/bin/grep -E '^nameserver' /etc/resolv.conf 2>/dev/null | /usr/bin/head -4)
fi
if [ -n "$_dns" ]; then
  emitd "network.dns" "$CAT" ok 0 "DNS" "configured" \
    "DNS servers are configured" "" $_dns
elif [ -r /etc/resolv.conf ] || have resolvectl; then
  emit "network.dns" "$CAT" info 0 "DNS" "none reported" \
    "No DNS server was reported; this can be expected on offline or isolated systems" \
    "Name resolution will fail; check the network configuration"
else
  emit "network.dns" "$CAT" unknown 0 "DNS" "unknown" \
    "Neither resolvectl nor a readable /etc/resolv.conf was available" ""
fi

# ---------------------------------------------------------------- time sync
if have timedatectl; then
  _synced=$(/usr/bin/timedatectl show -p NTPSynchronized --value 2>/dev/null)
  case "$_synced" in
    yes) emit "network.timesync" "$CAT" ok 0 "Time sync" "synced" "System clock is NTP-synchronized" ;;
    no)  emitr "network.timesync" "$CAT" attention 1 "Time sync" "not synced" \
           "The system clock is not synchronized; TLS and logs can misbehave" \
           "Enable it: sudo timedatectl set-ntp true" \
           safe "Enable NTP" "Turns on network time synchronization." ;;
    *)   emit "network.timesync" "$CAT" unknown 0 "Time sync" "unknown" \
           "timedatectl did not report whether the clock is synchronized" \
           "Check with: timedatectl status" ;;
  esac
else
  emit "network.timesync" "$CAT" unknown 0 "Time sync" "unknown" \
    "timedatectl is unavailable; time synchronization could not be checked" ""
fi

if ! is_full; then
  emit_json "$CAT" "$MODE"
  exit 0
fi

# ---------------------------------------------------------------- reachability (full)
if have ping; then
  if /usr/bin/ping -c 1 -W 3 1.1.1.1 >/dev/null 2>&1; then
    _rtt=$(/usr/bin/ping -c 1 -W 3 1.1.1.1 2>/dev/null | /usr/bin/grep -oE 'time=[0-9.]+' | /usr/bin/head -n 1)
    emit "network.reachability" "$CAT" ok 0 "Reachability" "$_rtt" \
      "Ping to 1.1.1.1 succeeded" ""
  else
    emit "network.reachability" "$CAT" info 0 "Reachability" "ICMP ping failed" \
      "Ping to 1.1.1.1 failed; ICMP may be blocked, so this alone does not prove internet is unavailable" \
      "Check gateway and DNS: ip route; resolvectl status"
  fi
else
  emit "network.reachability" "$CAT" unknown 0 "Reachability" "not checked" \
    "ping is unavailable; external reachability could not be tested" ""
fi

# ---------------------------------------------------------------- name resolution (full)
if have getent; then
  if /usr/bin/getent hosts one.one.one.one >/dev/null 2>&1; then
    emit "network.name_resolution" "$CAT" ok 0 "Name resolution" "ok" \
      "DNS resolution of one.one.one.one succeeded" ""
  else
    emitr "network.name_resolution" "$CAT" attention 1 "Name resolution" "failed" \
      "Resolution of the test name one.one.one.one failed even though a DNS server was reported" \
      "Check the DNS server: resolvectl query one.one.one.one" \
      manual "Investigate DNS" "No automatic action is taken."
  fi
else
  emit "network.name_resolution" "$CAT" unknown 0 "Name resolution" "not checked" \
    "getent is unavailable; external name resolution could not be tested" ""
fi

emit_json "$CAT" "$MODE"
