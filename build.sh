#!/bin/zsh
# Builds Local Grammar.app and installs it into /Applications.
# Usage: [VERSION=1.0.0] ./build.sh [--no-install]
# Needs Xcode 26 (or its Command Line Tools), Rust (cargo) and uv (`brew install uv`).
set -euo pipefail

cd "$(dirname "$0")"
APP_NAME="Local Grammar"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"
INSTALL_PATH="/Applications/$APP_NAME.app"
VERSION="${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)}"
VERSION="${VERSION:-0.0.0}"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
UV_BIN="${UV_BIN:-$(command -v uv || true)}"
[[ -x "$UV_BIN" ]] || { echo "uv not found — install it with: brew install uv"; exit 1; }

swift build -c release --arch arm64 --package-path app
cargo build --release --manifest-path harper-lint/Cargo.toml

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/engine"
cp app/.build/arm64-apple-macosx/release/LocalGrammar "$APP/Contents/MacOS/"
cp app/Resources/Info.plist "$APP/Contents/"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
cp app/Resources/{AppIcon.icns,Logo.png,MenuBarIcon.png,MenuBarIcon@2x.png} "$APP/Contents/Resources/"
# Live grammar checking (Harper), and the Qwen engine's scripts plus the uv that installs Python and MLX for them.
cp harper-lint/target/release/harper-lint "$APP/Contents/Resources/"
cp "$UV_BIN" "$APP/Contents/Resources/uv"
cp engine/{server.py,corrector.py,models.py,benchmark.py,pyproject.toml,uv.lock,.python-version} "$APP/Contents/Resources/engine/"

# A stable certificate keeps the Accessibility permission across rebuilds;
# ad-hoc signatures change every build and macOS asks for it again.
SIGNING_IDENTITY="${SIGNING_IDENTITY:-Local Grammar Dev}"
security find-identity -p codesigning | grep -q "\"$SIGNING_IDENTITY\"" || SIGNING_IDENTITY="-"
for binary in harper-lint uv; do
  codesign --force --sign "$SIGNING_IDENTITY" "$APP/Contents/Resources/$binary"
done
codesign --force --sign "$SIGNING_IDENTITY" --identifier com.samir.local-grammar "$APP"
echo "Built $APP $VERSION ($BUILD_NUMBER), signed with: $SIGNING_IDENTITY"

if [[ "${1:-}" != "--no-install" ]]; then
  pkill -x LocalGrammar 2>/dev/null && sleep 1 || true
  rm -rf "$INSTALL_PATH"
  cp -R "$APP" "$INSTALL_PATH"
  open "$INSTALL_PATH"
  echo "Installed and opened $INSTALL_PATH"
fi
