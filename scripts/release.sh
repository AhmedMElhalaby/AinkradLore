#!/usr/bin/env bash
set -euo pipefail
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
VERSION="${1:?usage: release.sh vX.Y.Z}"
ID="lore"; NAME="Lore"; ICON="book.closed"
DESC="Markdown-native notes for Ainkrad."

xcodegen generate
xcodebuild -scheme LorePlugin -configuration Release -derivedDataPath build -destination 'platform=macOS' build
BUNDLE="build/Build/Products/Release/LorePlugin.bundle"

rm -rf dist && mkdir -p dist
/usr/bin/ditto -c -k --keepParent "$BUNDLE" "dist/${ID}.bundle.zip"
SHA="$(shasum -a 256 "dist/${ID}.bundle.zip" | awk '{print $1}')"

# apiVersion READ FROM THE BUILT BUNDLE (stamped from the linked SDK by
# scripts/stamp-api-version.sh), never hardcoded — a stale constant here
# publishes a plugin the host refuses to load, silently.
API_VERSION="$(/usr/libexec/PlistBuddy -c 'Print AinkradAPIVersion' "$BUNDLE/Contents/Info.plist")"
[[ -n "$API_VERSION" ]] || { echo "error: could not read AinkradAPIVersion from the built bundle" >&2; exit 1; }

cat > dist/ainkrad-plugin.json <<JSON
{ "id": "$ID", "name": "$NAME", "icon": "$ICON", "description": "$DESC", "apiVersion": $API_VERSION, "sha256": "$SHA",\n  "author": "Ahmed M. Elhalaby" }
JSON

gh release create "$VERSION" dist/ainkrad-plugin.json "dist/${ID}.bundle.zip" \
  --title "$NAME $VERSION" --notes "$NAME $VERSION"
echo "Released $VERSION (sha256 $SHA)"
