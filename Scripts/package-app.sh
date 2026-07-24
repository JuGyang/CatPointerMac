#!/bin/zsh

set -euo pipefail

PROJECT_DIR=${0:A:h:h}
APP_DIR="$PROJECT_DIR/dist/CatPointer.app"
CONTENTS_DIR="$APP_DIR/Contents"
ICON_PATH="$PROJECT_DIR/Resources/CatPointer.icns"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
    "$PROJECT_DIR/Resources/Info.plist")
ARCHITECTURE=$(/usr/bin/uname -m)
ARTIFACT_BASENAME="CatPointer-v${VERSION}-macOS-${ARCHITECTURE}"
ZIP_PATH="$PROJECT_DIR/dist/${ARTIFACT_BASENAME}.zip"
DMG_PATH="$PROJECT_DIR/dist/${ARTIFACT_BASENAME}.dmg"
CHECKSUM_PATH="$PROJECT_DIR/dist/SHA256SUMS.txt"
STAGING_DIR=$(/usr/bin/mktemp -d \
    "${TMPDIR:-/tmp}/catpointer-release.XXXXXX")

cleanup() {
    /bin/rm -rf "$STAGING_DIR"
}

trap cleanup EXIT

cd "$PROJECT_DIR"
make release
test -f "$ICON_PATH"

rm -rf "$APP_DIR"
mkdir -p "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Resources"
cp "$PROJECT_DIR/.build/release/CatPointer" "$CONTENTS_DIR/MacOS/CatPointer"
cp "$PROJECT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$ICON_PATH" "$CONTENTS_DIR/Resources/CatPointer.icns"
/usr/bin/ditto \
    "$PROJECT_DIR/Resources/Cursors" \
    "$CONTENTS_DIR/Resources/Cursors"
/usr/bin/ditto \
    "$PROJECT_DIR/Resources/Licenses" \
    "$CONTENTS_DIR/Resources/Licenses"
cp \
    "$PROJECT_DIR/LICENSE" \
    "$CONTENTS_DIR/Resources/Licenses/CatPointer-MIT.txt"
cp \
    "$PROJECT_DIR/THIRD_PARTY_NOTICES.md" \
    "$CONTENTS_DIR/Resources/THIRD_PARTY_NOTICES.md"
chmod 755 "$CONTENTS_DIR/MacOS/CatPointer"

/usr/bin/codesign --force --deep --sign - "$APP_DIR"
/usr/bin/codesign --verify --deep --strict "$APP_DIR"

rm -f "$ZIP_PATH"
/usr/bin/ditto \
    -c -k --sequesterRsrc --keepParent \
    "$APP_DIR" \
    "$ZIP_PATH"
/usr/bin/unzip -tq "$ZIP_PATH"

/usr/bin/ditto "$APP_DIR" "$STAGING_DIR/CatPointer.app"
/bin/ln -s /Applications "$STAGING_DIR/Applications"
/usr/bin/hdiutil create \
    -volname "CatPointer ${VERSION}" \
    -srcfolder "$STAGING_DIR" \
    -ov \
    -format UDZO \
    "$DMG_PATH"

(
    cd "$PROJECT_DIR/dist"
    /usr/bin/shasum -a 256 \
        "${ARTIFACT_BASENAME}.dmg" \
        "${ARTIFACT_BASENAME}.zip" \
        > "$CHECKSUM_PATH"
)

echo "$APP_DIR"
echo "$DMG_PATH"
echo "$ZIP_PATH"
echo "$CHECKSUM_PATH"
