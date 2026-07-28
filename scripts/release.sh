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

# apiVersion is READ FROM THE BUILT BUNDLE, not hardcoded here.
#
# It was hardcoded as `7` and had been wrong since generation 8: the host loads
# a bundle only when its apiVersion is inside the supported generation range,
# so a stale constant here publishes a sideload manifest for a plugin the host
# refuses to load, with no build failure to warn anyone. The bundle's
# Info.plist is stamped at build time from the AinkradAppKit revision actually
# linked (scripts/stamp-api-version.sh), so it is the single source of truth.
API_VERSION="$(/usr/libexec/PlistBuddy -c 'Print AinkradAPIVersion' "$BUNDLE/Contents/Info.plist")"
[[ -n "$API_VERSION" ]] || { echo "error: could not read AinkradAPIVersion from the built bundle" >&2; exit 1; }

cat > dist/ainkrad-plugin.json <<JSON
{ "id": "$ID", "name": "$NAME", "icon": "$ICON", "description": "$DESC", "apiVersion": $API_VERSION, "sha256": "$SHA" }
JSON

gh release create "$VERSION" dist/ainkrad-plugin.json "dist/${ID}.bundle.zip" \
  --title "$NAME $VERSION" --notes "$NAME $VERSION"
echo "Released $VERSION (sha256 $SHA)"
