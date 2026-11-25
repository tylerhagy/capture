#!/bin/bash
# Every check, with nothing on the screen and none of your data: the core logic, then the real app hidden.
set -uo pipefail
cd "$(dirname "$0")"
FAIL=0
echo "== Core (stitching, paste queue, library, shortcuts, Chrome messages)"
swift test 2>&1 | grep -E "error|Executed [0-9]+ tests" | tail -2; swift test >/dev/null 2>&1 || FAIL=1
echo "== The app, hidden"
./build.sh | tail -1
D=$(mktemp -d)
out=$(CAPTURE_LIBRARY="$D/library" CAPTURE_SHOTS="${CAPTURE_SHOTS:-$D/shots}" perl -e 'alarm 120; exec @ARGV' build/Capture.app/Contents/MacOS/Capture --selftest ${1:-} 2>&1 | grep -E "PASS|FAIL|SKIP|SELFTEST")
echo "$out"; echo "$out" | grep -q "SELFTEST OK" || FAIL=1
rm -rf "$D"
exit $FAIL
