#!/bin/sh
# Run the whole contract check. Usage:
#   BOOKMASTER_REPO=/path/to/BookMaster ios/Checks/bookmaster/run.sh [data]
# `data` runs only the checks that need no servers.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
cd "$HERE"
command -v swift >/dev/null || { echo "swift not found — install a Swift 6 toolchain (swift.org/install)"; exit 2; }
./assemble.sh
# a failed build must stop the run — otherwise the previous binary would be run and report green
if ! swift build > .build.log 2>&1; then grep -E "error:" .build.log | head -30; echo "build failed"; exit 1; fi
tail -3 .build.log
if [ "$1" = data ]; then BM_ONLY=data .build/debug/bmcheck; exit $?; fi
: "${BOOKMASTER_REPO:?set BOOKMASTER_REPO to a BookMaster checkout}"
./stack.sh reset
trap './stack.sh stop' EXIT
BM_HARNESS="$HERE" BM_CODE=$(cat .work/code) BM_BRIDGE=http://127.0.0.1:8789/api/bookmaster .build/debug/bmcheck
