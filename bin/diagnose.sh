#!/bin/sh
# System Diagnostics scan dispatcher.
#
# Usage: diagnose.sh [quick|full] [--checks-only]
#
#   quick  local-only sections (system, omarchy, systemd, journal, storage
#          usage, packages, security). Cheap enough for a periodic scan.
#   full   everything, including deeper probes (network reachability, GPU
#          tooling, SMART, previous boots). Run on demand.
#
# Emits one merged JSON document:
#   {"mode":"quick","ts":<epoch>,"version":"1.0.0","host":{...},"sections":[...],"checks":[ ... ]}
# with --checks-only, just the checks array.
#
# Every section is invoked behind its own timeout. A section that times out,
# crashes, exits non-zero or emits malformed output contributes an explicit
# problem check rather than vanishing -- a missing check must never be mistaken
# for a healthy one.
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/bootstrap.sh"
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/common.sh"

VERSION="1.0.0"

MODE=quick
CHECKS_ONLY=0
for arg in "$@"; do
  case "$arg" in
    quick | full) MODE=$arg ;;
    --checks-only) CHECKS_ONLY=1 ;;
  esac
done
SYSDIAG_MODE=$MODE
export SYSDIAG_MODE

DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

# Per-section deadline in seconds (worst-case budgets, not expected durations).
deadline_for() {
  case "$1" in
    network)  printf '25' ;;
    graphics) printf '20' ;;
    storage)  printf '25' ;;
    journal)  printf '25' ;;
    systemd)  printf '20' ;;
    packages) printf '20' ;;
    security) printf '20' ;;
    omarchy)  printf '15' ;;
    system)   printf '15' ;;
    *)        printf '15' ;;
  esac
}

CHECKS=""
SECTIONS=""

# section_failure NAME VALUE DETAIL SUGGESTION -> a bare check object marking a
# section as unusable. Emitted INSTEAD of that section's own output, never
# alongside it.
section_failure() {
  check "$1.section" "$1" problem 3 "Section" "$2" "$3" "$4"
}

add_section() {
  _name=$1
  _script="$DIR/sections/$_name.sh"
  _budget=$(deadline_for "$_name")
  _run_hint="Run it directly to see the error: sh $DIR/sections/$_name.sh --checks-only"

  if [ ! -r "$_script" ]; then
    arr=$(section_failure "$_name" "missing" "$_name.sh not found" \
      "Reinstall or update the plugin.")
  else
    arr=$(/usr/bin/timeout -k 2 "$_budget" /bin/sh "$_script" --checks-only 2>/dev/null)
    _rc=$?
    arr=$(printf '%s' "$arr" | /usr/bin/tr -d '\n')

    if [ -z "$(printf '%s' "$arr" | /usr/bin/tr -d ' \n')" ]; then
      case "$_rc" in
        124 | 137)
          arr=$(section_failure "$_name" "timed out" \
            "$_name.sh exceeded its ${_budget}s deadline and was killed" \
            "A probe it depends on probably hung. $_run_hint") ;;
        *)
          arr=$(section_failure "$_name" "failed" \
            "$_name.sh produced no output (exit $_rc)" "$_run_hint") ;;
      esac
    elif [ "$_rc" -ne 0 ]; then
      case "$_rc" in
        124 | 137)
          arr=$(section_failure "$_name" "timed out" \
            "$_name.sh was killed at its ${_budget}s deadline after partial output" \
            "Its remaining checks did not run, so they are not reported. $_run_hint") ;;
        *)
          arr=$(section_failure "$_name" "incomplete" \
            "$_name.sh exited $_rc after emitting output, so its remaining checks did not run" \
            "$_run_hint") ;;
      esac
    elif ! json_fragment_ok "$arr"; then
      arr=$(section_failure "$_name" "corrupt" \
        "$_name.sh produced output that is not a valid list of checks" \
        "It was discarded so the rest of this scan survives. $_run_hint")
    fi
  fi

  if [ -z "$(printf '%s' "$CHECKS" | /usr/bin/tr -d ' ')" ]; then
    CHECKS=$arr
  else
    CHECKS="$CHECKS,$arr"
  fi
  SECTIONS="$SECTIONS $_name"
}

# Order matters only for display; quick is the cheap local set.
add_section system
add_section omarchy
add_section systemd
add_section journal
add_section storage
add_section packages
add_section security
if [ "$MODE" = "full" ]; then
  add_section network
  add_section graphics
fi

if [ -z "$(printf '%s' "$CHECKS" | /usr/bin/tr -d ' ')" ]; then
  CHECKS_ARRAY="[]"
else
  CHECKS_ARRAY="[$CHECKS]"
fi

if [ "$CHECKS_ONLY" = "1" ]; then
  printf '%s\n' "$CHECKS_ARRAY"
  exit 0
fi

# Last line of defence: never cache/emit a document the QML layer cannot parse.
if ! json_fragment_ok "$CHECKS"; then
  printf '{"id":"diagnose.merged","category":"system","title":"Scan","status":"problem","severity":3,"value":"corrupt","detail":"the merged check list is malformed and was discarded","suggestion":"Run sh %s/diagnose.sh full to see the raw output."}\n' \
    "$DIR"
  exit 1
fi

# --------------------------------------------------------------- host header
TS=$(/usr/bin/date +%s 2>/dev/null || printf '0')

host_field() { printf '%s' "$1" | /usr/bin/head -n 1 | /usr/bin/tr -d '\n\r'; }

_os=$(host_field "$(read_file /etc/os-release | sed -n 's/^PRETTY_NAME="\(.*\)"/\1/p')")
[ -z "$_os" ] && _os="Unknown"
_kernel=$(/usr/bin/uname -r 2>/dev/null)
_hostname=$(read_file /proc/sys/kernel/hostname)
_om_version=$(host_field "$(read_file /usr/share/omarchy/version)")
_hypr=$(host_field "$(printf '%s' "$(/usr/bin/hyprctl version 2>/dev/null)" | /usr/bin/head -n 1)")
_up=$(/usr/bin/uptime -p 2>/dev/null | /usr/bin/sed 's/^up //')

HOST="{\"hostname\":$(jstr "$_hostname"),\"os\":$(jstr "$_os"),\"kernel\":$(jstr "$_kernel"),\"omarchy\":$(jstr "$_om_version"),\"hyprland\":$(jstr "$_hypr"),\"uptime\":$(jstr "$_up")}"

SECS_JSON=$(printf '%s' "$SECTIONS" | /usr/bin/sed 's/^ *//; s/ /","/g; s/^/"/; s/$/"/')

DOC="{\"mode\":$(jstr "$MODE"),\"version\":\"$VERSION\",\"ts\":$TS,\"host\":$HOST,\"sections\":[$SECS_JSON],\"checks\":$CHECKS_ARRAY}"

printf '%s\n' "$DOC"

# Persist the snapshot atomically so a reader never sees a half-written file.
SNAP="$SYSDIAG_STATE_DIR/last-scan.json"
TMP="$SYSDIAG_STATE_DIR/.last-scan.$$"
if printf '%s\n' "$DOC" > "$TMP" 2>/dev/null; then
  /usr/bin/mv -f "$TMP" "$SNAP" 2>/dev/null || /usr/bin/rm -f "$TMP" 2>/dev/null
fi
printf '%s\n' "$TS" > "$SYSDIAG_STATE_DIR/.last-scan.ts.$$" 2>/dev/null \
  && /usr/bin/mv -f "$SYSDIAG_STATE_DIR/.last-scan.ts.$$" \
                "$SYSDIAG_STATE_DIR/last-scan.ts" 2>/dev/null
exit 0
