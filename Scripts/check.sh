#!/bin/sh
# The full suite — what a CI server would run before accepting a change.
#
# Usage: Scripts/check.sh
#        SKIP_SMOKE=1 Scripts/check.sh    # unit tests only, no app window
#
#   1. Unit tests      (Scripts/test.sh)        ~90 tests of the core logic
#   2. Smoke test      (Scripts/smoke-test.sh)  the real app on a real vault
#
# Exits non-zero if anything fails; release.sh refuses to release unless this
# passes.

set -u
cd "$(dirname "$0")/.."

STATUS=0
RESULTS=""

run() {  # run "label" command...
    label="$1"; shift
    echo
    echo "=== $label ==="
    if "$@"; then
        RESULTS="$RESULTS  passed  $label\n"
    else
        RESULTS="$RESULTS  FAILED  $label\n"
        STATUS=1
    fi
}

run "Unit tests" Scripts/test.sh
if [ "${SKIP_SMOKE:-0}" = "1" ]; then
    RESULTS="$RESULTS  skipped End-to-end smoke test (SKIP_SMOKE=1)\n"
else
    run "End-to-end smoke test" Scripts/smoke-test.sh
fi

echo
echo "=== Summary ==="
printf "$RESULTS"
[ "$STATUS" -eq 0 ] && echo "All checks passed." || echo "Checks FAILED."
exit "$STATUS"
