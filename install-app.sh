#!/bin/bash
# install-app.sh — build conspectus and assemble a Conspectus.app bundle so it
# shows up in Finder / Launchpad / Dock with its icon. The shell command
# `conspectus` (via the ~/bin shim) keeps working independently for terminal use
# with args (`conspectus`, `conspectus split`).
#
# The bundle's launcher execs the repo's bin/conspectus, so the .app and the
# shell command always run the same freshly-built binary — no divergence.
#
#   ./install-app.sh                       # -> /Applications/Conspectus.app
#   ./install-app.sh ~/Applications         # custom install dir
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
DEST="${1:-/Applications}"
APP="$DEST/Conspectus.app"
BIN="$REPO/.build/release/conspectus"

echo "==> building"
"$REPO/build.sh"

echo "==> rendering icon"
tmp="$(mktemp -d)"
"$BIN" --icon "$tmp/base.png"
iconset="$tmp/conspectus.iconset"; mkdir -p "$iconset"
for s in 16 32 128 256 512; do
  sips -z "$s" "$s"           "$tmp/base.png" --out "$iconset/icon_${s}x${s}.png"    >/dev/null
  sips -z "$((s*2))" "$((s*2))" "$tmp/base.png" --out "$iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$tmp/conspectus.icns"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$tmp/conspectus.icns" "$APP/Contents/Resources/conspectus.icns"

cat > "$APP/Contents/MacOS/Conspectus" <<EOF
#!/bin/bash
# Bundle launcher — runs the repo launcher (overlay + binary) so Finder and the
# shell command share one code path. Args from \`open --args\` pass through.
# Finder/launchd only hands over a minimal PATH, so load the full login PATH
# (same trick as the Alfred scripts) — otherwise yazi/qlpeek aren't found.
export PATH="\$(/bin/zsh -lic 'print -rn -- \$PATH' 2>/dev/null)"
exec "$REPO/bin/conspectus" "\$@"
EOF
chmod +x "$APP/Contents/MacOS/Conspectus"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Conspectus</string>
  <key>CFBundleDisplayName</key><string>Conspectus</string>
  <key>CFBundleIdentifier</key><string>de.uni-weimar.max.conspectus</string>
  <key>CFBundleVersion</key><string>1.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>Conspectus</string>
  <key>CFBundleIconFile</key><string>conspectus</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
</dict></plist>
EOF

# refresh Launch Services + icon cache so Finder/Dock pick up the new bundle
touch "$APP"
LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
[ -x "$LSREG" ] && "$LSREG" -f "$APP" >/dev/null 2>&1 || true

rm -rf "$tmp"
echo "==> installed: $APP"
echo "    Launch from Finder/Launchpad, or: open -a Conspectus   (split: open -a Conspectus --args split)"
echo "    Shell command unchanged: conspectus | conspectus split"
