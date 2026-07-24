#!/bin/zsh

set -euo pipefail

PROJECT_DIR=${0:A:h:h}
APP_DIR="$PROJECT_DIR/dist/CatPointer.app"
CONTENTS_DIR="$APP_DIR/Contents"
ICON_PATH="$PROJECT_DIR/Resources/CatPointer.icns"
APPLICATIONS_ICON_PATH="/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/ApplicationsFolderIcon.icns"
BACKGROUND_PATH="$PROJECT_DIR/.build/dmg-background/background.tiff"
STYLE_SCRIPT="$PROJECT_DIR/Scripts/style-dmg.applescript"
ALIAS_SCRIPT="$PROJECT_DIR/Scripts/create-applications-alias.applescript"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
    "$PROJECT_DIR/Resources/Info.plist")
ARCHITECTURE=$(/usr/bin/uname -m)
ARTIFACT_BASENAME="CatPointer-v${VERSION}-macOS-${ARCHITECTURE}"
ZIP_PATH="$PROJECT_DIR/dist/${ARTIFACT_BASENAME}.zip"
DMG_PATH="$PROJECT_DIR/dist/${ARTIFACT_BASENAME}.dmg"
CHECKSUM_PATH="$PROJECT_DIR/dist/SHA256SUMS.txt"
STAGING_DIR=$(/usr/bin/mktemp -d \
    "${TMPDIR:-/tmp}/catpointer-release.XXXXXX")
MOUNT_DIR="/Volumes/CatPointer ${VERSION}"
READ_WRITE_DMG="${TMPDIR:-/tmp}/catpointer-${VERSION}-read-write.dmg"
MOUNTED=0

cleanup() {
    if [[ "$MOUNTED" -eq 1 ]]; then
        /usr/bin/hdiutil detach "$MOUNT_DIR" -quiet || true
    fi
    /bin/rm -rf "$STAGING_DIR"
    /bin/rm -f "$READ_WRITE_DMG"
}

trap cleanup EXIT

cd "$PROJECT_DIR"
make release
make dmg-background
test -f "$ICON_PATH"
test -f "$APPLICATIONS_ICON_PATH"
test -f "$BACKGROUND_PATH"
test -f "$STYLE_SCRIPT"
test -f "$ALIAS_SCRIPT"

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
/usr/bin/osascript "$ALIAS_SCRIPT" "$STAGING_DIR" >/dev/null

APPLICATIONS_ICON_COPY="$STAGING_DIR/.ApplicationsFolderIcon.icns"
APPLICATIONS_ICON_RESOURCE="$STAGING_DIR/.ApplicationsFolderIcon.rsrc"
/bin/cp "$APPLICATIONS_ICON_PATH" "$APPLICATIONS_ICON_COPY"
/usr/bin/sips -i "$APPLICATIONS_ICON_COPY" >/dev/null
/Library/Developer/CommandLineTools/usr/bin/DeRez \
    -only icns \
    "$APPLICATIONS_ICON_COPY" \
    > "$APPLICATIONS_ICON_RESOURCE"
/Library/Developer/CommandLineTools/usr/bin/Rez \
    -append "$APPLICATIONS_ICON_RESOURCE" \
    -o "$STAGING_DIR/Applications"
/Library/Developer/CommandLineTools/usr/bin/SetFile \
    -a C \
    "$STAGING_DIR/Applications"
/bin/rm -f "$APPLICATIONS_ICON_COPY" "$APPLICATIONS_ICON_RESOURCE"

/bin/mkdir -p "$STAGING_DIR/.background"
/bin/cp "$BACKGROUND_PATH" "$STAGING_DIR/.background/background.tiff"
/usr/bin/chflags hidden "$STAGING_DIR/.background"

/bin/rm -f "$READ_WRITE_DMG" "$DMG_PATH"
if [[ -e "$MOUNT_DIR" ]]; then
    echo "Volume already mounted: $MOUNT_DIR" >&2
    exit 1
fi
/usr/bin/hdiutil create \
    -volname "CatPointer ${VERSION}" \
    -fs HFS+ \
    -srcfolder "$STAGING_DIR" \
    -ov \
    -format UDRW \
    "$READ_WRITE_DMG"

/usr/bin/hdiutil attach \
    -readwrite \
    -noverify \
    -noautoopen \
    -mountpoint "$MOUNT_DIR" \
    "$READ_WRITE_DMG" \
    >/dev/null
MOUNTED=1

/usr/bin/osascript "$STYLE_SCRIPT" "CatPointer ${VERSION}"
/bin/cp "$ICON_PATH" "$MOUNT_DIR/.VolumeIcon.icns"
/usr/bin/chflags hidden "$MOUNT_DIR/.VolumeIcon.icns"
/Library/Developer/CommandLineTools/usr/bin/SetFile -a C "$MOUNT_DIR"
/bin/sync
/usr/bin/hdiutil detach "$MOUNT_DIR" -quiet
MOUNTED=0

/usr/bin/hdiutil convert \
    "$READ_WRITE_DMG" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -o "$DMG_PATH" \
    >/dev/null
/usr/bin/hdiutil verify "$DMG_PATH" >/dev/null

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
