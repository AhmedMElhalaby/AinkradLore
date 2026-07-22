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

cat > dist/ainkrad-plugin.json <<JSON
{ "id": "$ID", "name": "$NAME", "icon": "$ICON", "description": "$DESC", "apiVersion": 7, "sha256": "$SHA" }
JSON

gh release create "$VERSION" dist/ainkrad-plugin.json "dist/${ID}.bundle.zip" \
  --title "$NAME $VERSION" --notes "$NAME $VERSION"
echo "Released $VERSION (sha256 $SHA)"
