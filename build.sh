#!/bin/bash
# Build conspectus (release). First run fetches SwiftTerm via SPM.
set -euo pipefail
REPO="$(cd "$(dirname "$0")" && pwd)"
cd "$REPO"
swift build -c release
BIN="$REPO/.build/release/conspectus"
# Sign with a stable identity so macOS keeps its privacy grants (Downloads,
# Desktop, Documents, network volumes, Full Disk Access) across rebuilds. The
# SwiftPM default is an ad-hoc signature, which is just the hash of this
# build; TCC stores each grant against that hash, so every rebuild is a new
# app to it and asks for everything again. Off unless the identity is named
# (see docs/handbook.md, "Privacy permissions").
if [ -n "${CONSPECTUS_SIGN_IDENTITY:-}" ]; then
  codesign --force --sign "$CONSPECTUS_SIGN_IDENTITY" "$BIN"
  echo "signed: $CONSPECTUS_SIGN_IDENTITY"
fi
echo "built: $BIN"
