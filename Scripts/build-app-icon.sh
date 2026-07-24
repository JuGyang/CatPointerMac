#!/bin/zsh

set -euo pipefail

PROJECT_DIR=${0:A:h:h}
MASTER_PATH="$PROJECT_DIR/Resources/AppIcon.png"
ICONSET_DIR="$PROJECT_DIR/.build/AppIcon.iconset"
ICNS_PATH="$PROJECT_DIR/Resources/CatPointer.icns"
BACKGROUND_PATH="$PROJECT_DIR/Resources/IconSource/AppIconBackground-chroma.png"
SUBJECT_PATH="$PROJECT_DIR/Resources/Cursors/default/120.png"

mkdir -p "$PROJECT_DIR/.build"
rm -rf "$ICONSET_DIR"
mkdir -p "$ICONSET_DIR"

/usr/bin/swift \
    "$PROJECT_DIR/Tools/make_app_icon.swift" \
    "$BACKGROUND_PATH" \
    "$SUBJECT_PATH" \
    "$MASTER_PATH"

function make_icon_size() {
    local pixels=$1
    local name=$2
    /usr/bin/sips \
        -s format png \
        -z "$pixels" "$pixels" \
        "$MASTER_PATH" \
        --out "$ICONSET_DIR/$name" >/dev/null
}

make_icon_size 16 icon_16x16.png
make_icon_size 32 icon_16x16@2x.png
make_icon_size 32 icon_32x32.png
make_icon_size 64 icon_32x32@2x.png
make_icon_size 128 icon_128x128.png
make_icon_size 256 icon_128x128@2x.png
make_icon_size 256 icon_256x256.png
make_icon_size 512 icon_256x256@2x.png
make_icon_size 512 icon_512x512.png
make_icon_size 1024 icon_512x512@2x.png

/usr/bin/iconutil \
    -c icns \
    "$ICONSET_DIR" \
    -o "$ICNS_PATH"

/usr/bin/sips -g pixelWidth -g pixelHeight -g hasAlpha "$MASTER_PATH"
/usr/bin/file "$ICNS_PATH"
