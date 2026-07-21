#!/bin/bash
# Build qlpanel (release). First run fetches SwiftTerm via SPM.
set -euo pipefail
REPO="$(cd "$(dirname "$0")" && pwd)"
cd "$REPO"
swift build -c release
echo "built: $REPO/.build/release/qlpanel"
