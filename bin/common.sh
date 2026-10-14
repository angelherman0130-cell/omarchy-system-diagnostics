#!/bin/sh
# Shared helpers for System Diagnostics backend scripts.
# POSIX-only. Every script sources bootstrap.sh first, then this file for the
# JSON emitters and check helpers below.
#
# Design notes
# ------------
# * Scripts emit ONE JSON document on stdout. stderr is discarded by diagnose.sh,
#   so a diagnostic must never depend on writing there.
# * JSON is built by printf, not echo, so values containing spaces, quotes or
#   backslashes cannot corrupt the document. `jstr` is the only way a shell
#   value enters the JSON.
# * No command is ever invoked through `eval` or a dynamically built shell
#   string. Callers pass fixed argument vectors.
# * A failing probe must not abort the script: `have` gates optional tools and
#   every probe is written to degrade to an "unknown"/skipped state. A missing
#   check must NEVER be mistaken for a healthy one.

: "${SYSDIAG_STATE_DIR:=$HOME/.local/state/system-diagnostics}"

# ---------------------------------------------------------------- JSON output

# jstr VALUE -> print a quoted, escaped JSON string.
#
# Every byte JSON forbids inside a string literal must be escaped here. Leaving
# any of them raw makes the WHOLE document unparseable, and because the QML
# layer treats an unparseable scan as "no scan", one odd byte anywhere in one
# check silently discards every other finding. The reachable carriers are
# directory names under $HOME and verbatim command output (hyprctl
# configerrors, journal lines), so this is not theoretical.
#
# Order matters: backslash and double quote first, then the control characters,
# then newline flattening.
jstr() {
  _s=$1
  _s=$(printf '%s' "$_s" | /usr/bin/sed \
        -e 's/\\/\\\\/g' \
        -e 's/"/\\"/g' \
        -e 's/\x01/\\u0001/g' -e 's/\x02/\\u0002/g' \
        -e 's/\x03/\\u0003/g' -e 's/\x04/\\u0004/g' \
        -e 's/\x05/\\u0005/g' -e 's/\x06/\\u0006/g' \
        -e 's/\x07/\\u0007/g' \
        -e 's/\x08/\\b/g'    -e 's/\x09/\\t/g' \
        -e 's/\x0a/\\n/g'    -e 's/\x0b/\\u000b/g' \
        -e 's/\x0c/\\f/g'    -e 's/\x0d/\\r/g' \
        -e 's/\x0e/\\u000e/g' -e 's/\x0f/\\u000f/g' \
        -e 's/\x10/\\u0010/g' -e 's/\x11/\\u0011/g' \
        -e 's/\x12/\\u0012/g' -e 's/\x13/\\u0013/g' \
        -e 's/\x14/\\u0014/g' -e 's/\x15/\\u0015/g' \
        -e 's/\x16/\\u0016/g' -e 's/\x17/\\u0017/g' \
        -e 's/\x18/\\u0018/g' -e 's/\x19/\\u0019/g' \
        -e 's/\x1a/\\u001a/g' -e 's/\x1b/\\u001b/g' \
        -e 's/\x1c/\\u001c/g' -e 's/\x1d/\\u001d/g' \
        -e 's/\x1e/\\u001e/g' -e 's/\x1f/\\u001f/g' \
        -e 's/\x7f/\\u007f/g')
  printf '"%s"' "$_s"
}

# jnum VALUE -> print a JSON number, or null when the value is not a JSON number.
#
# Matches the JSON number grammar exactly and returns null for everything else:
#   -?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?
jnum() {
  SYSDIAG_JNUM=$1 /usr/bin/awk 'BEGIN {
    num = "^-?(0|[1-9][0-9]*)(\\.[0-9]+)?([eE][+-]?[0-9]+)?$"
    v = ENVIRON["SYSDIAG_JNUM"]
    print (v ~ num) ? v : "null"
  }'
}

# check ID CATEGORY STATUS SEVERITY TITLE VALUE DETAIL SUGGESTION
#
# Emits one check object. Field order in the JSON is deliberately
# id, category, title, status, severity, value, detail, suggestion -- which is
# NOT the argument order (status/severity precede title for readability at the
# call site). Keep this mapping and the call sites in sync.
#
# STATUS   is one of: ok | info | unknown | attention | problem
# SEVERITY is the internal weight: 0 (ok/info/unknown) | 1 (attention) | 3 (problem)
check() {
  printf '{"id":%s,"category":%s,"title":%s,"status":%s,"severity":%s,"value":%s,"detail":%s,"suggestion":%s}' \
    "$(jstr "$1")" "$(jstr "$2")" "$(jstr "$5")" \
    "$(jstr "$3")" "$(jnum "$4")" \
    "$(jstr "$6")" "$(jstr "$7")" "$(jstr "$8")"
}

# jlines [STRING...] -> a JSON array of the non-empty arguments, [] if none.
jlines() {
  _jl=""
  for _jl_s in "$@"; do
    [ -z "$_jl_s" ] && continue
    if [ -z "$_jl" ]; then
      _jl=$(jstr "$_jl_s")
    else
      _jl="$_jl,$(jstr "$_jl_s")"
    fi
  done
  if [ -z "$_jl" ]; then printf '[]'; else printf '[%s]' "$_jl"; fi
}

# checkd ID CATEGORY STATUS SEVERITY TITLE VALUE DETAIL SUGGESTION [DETAIL...]
#
# As check(), plus an OPTIONAL "details" array for structured evidence.
checkd() {
  _cd_id=$1; _cd_cat=$2; _cd_st=$3; _cd_sv=$4
  _cd_ti=$5; _cd_va=$6; _cd_de=$7; _cd_sg=$8
  shift 8
  printf '{"id":%s,"category":%s,"title":%s,"status":%s,"severity":%s,"value":%s,"detail":%s,"suggestion":%s,"details":%s}' \
    "$(jstr "$_cd_id")" "$(jstr "$_cd_cat")" "$(jstr "$_cd_ti")" \
    "$(jstr "$_cd_st")" "$(jnum "$_cd_sv")" \
    "$(jstr "$_cd_va")" "$(jstr "$_cd_de")" "$(jstr "$_cd_sg")" \
    "$(jlines "$@")"
}

# checkr ID CATEGORY STATUS SEVERITY TITLE VALUE DETAIL SUGGESTION TIER LABEL [REPAIR_DETAIL] [DETAIL...]
#
# As checkd(), plus an optional "repair" descriptor. TIER is safe|caution|manual.
# DESCRIPTIVE ONLY -- this plugin is read-only and never runs a repair.
checkr() {
  _cr_id=$1; _cr_cat=$2; _cr_st=$3; _cr_sv=$4
  _cr_ti=$5; _cr_va=$6; _cr_de=$7; _cr_sg=$8
  _cr_tier=$9; shift 9
  _cr_rlabel=${1:-}
  if [ "$#" -ge 2 ]; then
    _cr_rdetail=$2
    shift 2
  else
    _cr_rdetail=""
    shift 2>/dev/null || :
  fi
  printf '{"id":%s,"category":%s,"title":%s,"status":%s,"severity":%s,"value":%s,"detail":%s,"suggestion":%s,"details":%s,"repair":%s}' \
    "$(jstr "$_cr_id")" "$(jstr "$_cr_cat")" "$(jstr "$_cr_ti")" \
    "$(jstr "$_cr_st")" "$(jnum "$_cr_sv")" \
    "$(jstr "$_cr_va")" "$(jstr "$_cr_de")" "$(jstr "$_cr_sg")" \
    "$(jlines "$@")" \
    "$(jrepair "$_cr_tier" "$_cr_rlabel" "$_cr_rdetail")"
}

# jrepair TIER LABEL DETAIL -> a repair object, or "null" when LABEL is empty.
jrepair() {
  if [ -z "$2" ]; then printf 'null'; return 0; fi
  _jr_tier=$(printf '%s' "$1" | /usr/bin/tr 'A-Z' 'a-z')
  case "$_jr_tier" in safe | caution | manual) ;; *) _jr_tier=manual ;; esac
  printf '{"tier":"%s","label":%s,"detail":%s}' \
    "$_jr_tier" "$(jstr "$2")" "$(jstr "$3")"
}

# Accumulate one check object into $CHECKS. This only appends a comma-separated
# object; the enclosing [ ... ] is added once at print time by emit_json.
emit() {
  _c=$(check "$@")
  if [ -z "$CHECKS" ]; then CHECKS=$_c; else CHECKS="$CHECKS,$_c"; fi
}

emitd() {
  _c=$(checkd "$@")
  if [ -z "$CHECKS" ]; then CHECKS=$_c; else CHECKS="$CHECKS,$_c"; fi
}

emitr() {
  _c=$(checkr "$@")
  if [ -z "$CHECKS" ]; then CHECKS=$_c; else CHECKS="$CHECKS,$_c"; fi
}

# Print the accumulated checks as JSON. $1 is the section name; $2 may be
# "--checks-only" to emit the BARE comma-separated objects (no enclosing
# brackets) so diagnose.sh can concatenate several sections and wrap the result
# in exactly one [ ... ].
emit_json() {
  if [ -z "$CHECKS" ]; then CHECKS=""; fi
  case "${2:-}" in
    --checks-only) printf '%s\n' "$CHECKS" ;;
    *) printf '{"section":%s,"checks":[%s]}\n' "$(jstr "$1")" "$CHECKS" ;;
  esac
}

# ------------------------------------------------------------------- probing

# have CMD -> succeed when CMD is resolvable on the trusted PATH.
have() {
  command -v "$1" >/dev/null 2>&1
}

# read_file PATH -> contents of PATH, or empty when unreadable.
read_file() {
  [ -r "$1" ] || return 1
  /usr/bin/cat "$1" 2>/dev/null
}

# first_line -> the first line of stdin.
first_line() {
  /usr/bin/head -n 1
}

# trim STRING -> STRING with leading/trailing whitespace removed.
trim() {
  printf '%s' "$1" | /usr/bin/sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

# --- mode helpers: sections read $SYSDIAG_MODE to skip expensive probes.
is_full() { [ "${SYSDIAG_MODE:-quick}" = "full" ]; }

# ------------------------------------------------------------ JSON validation

# json_fragment_ok FRAGMENT -> true when "[FRAGMENT]" is a syntactically
# well-formed JSON array of objects that each carry an "id".
json_fragment_ok() {
  case "$1" in
    *'"id"'*) ;;
    *) return 1 ;;
  esac
  printf '%s' "$1" | /usr/bin/awk '
    BEGIN { depth = 0; instr = 0; esc = 0; bad = 0; lines = 0; state = 0 }
    {
      lines++
      if (lines > 1) bad = 1
      s = $0
      n = length(s)
      for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        if (instr) {
          if (esc) { esc = 0 }
          else if (c == "\\") { esc = 1 }
          else if (c == "\"") { instr = 0 }
          else if (c >= "\001" && c <= "\037") { bad = 1 }
          continue
        }
        if (c == " " || c == "\t") continue
        if (state == 0) {
          if (c == "{") { depth = 1; state = 1 }
          else bad = 1
          continue
        }
        if (state == 2) {
          if (c == ",") state = 0
          else bad = 1
          continue
        }
        if (c == "\"") instr = 1
        else if (c == "{" || c == "[") depth++
        else if (c == "}" || c == "]") {
          depth--
          if (depth == 0) state = 2
          else if (depth < 0) bad = 1
        }
      }
    }
    END { exit (bad || instr || state != 2) ? 1 : 0 }
  '
}
