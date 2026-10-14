#!/bin/sh
set -eu

PLUGIN_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
# common.sh defines helpers without running a probe; override the trusted
# system directory only for the test process.
. "$PLUGIN_DIR/bin/common.sh"

test "$(jnum 0)" = 0
test "$(jnum -12)" = -12
test "$(jnum 1.25e+2)" = 1.25e+2
test "$(jnum 01)" = null
test "$(jnum '12x')" = null

tab=$(printf '\t')
newline=$(printf '\nx')
newline=${newline%x}
escaped=$(jstr "quote=\" slash=\\ tab=${tab} newline=${newline}end")
printf '%s\n' "$escaped" | /usr/bin/jq -R -e 'fromjson | index("quote=\" slash=\\ tab=\t newline= end") != null' >/dev/null

valid='{"id":"test.one","details":["quoted: \\\"value\\\"", "line\\nnext"]}'
json_fragment_ok "$valid"
if json_fragment_ok '{"id":"broken"'; then
  echo 'json_fragment_ok accepted truncated JSON' >&2
  exit 1
fi
two_lines=$(printf '%s\n%s' '{"id":"first"}' '{"id":"second"}')
if json_fragment_ok "$two_lines"; then
  echo 'json_fragment_ok accepted multiple JSON lines' >&2
  exit 1
fi
if json_fragment_ok 'not-json'; then
  echo 'json_fragment_ok accepted non-JSON text' >&2
  exit 1
fi

check_json=$(check 'test.check' 'test' unknown 0 'Test' 'unknown' 'not run' '')
printf '%s\n' "$check_json" | /usr/bin/jq -e '.id == "test.check" and .status == "unknown" and .severity == 0' >/dev/null

printf '%s\n' 'common.sh tests passed'
