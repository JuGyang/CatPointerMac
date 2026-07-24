on run argv
    if (count of argv) is not 1 then error "usage: style-dmg.applescript <volume name>"
    set volumeName to item 1 of argv

    tell application "Finder"
        tell disk volumeName
            open
            delay 1

            set dmgWindow to container window
            set current view of dmgWindow to icon view
            set toolbar visible of dmgWindow to false
            set statusbar visible of dmgWindow to false
            set bounds of dmgWindow to {120, 120, 840, 592}

            set viewOptions to icon view options of dmgWindow
            set arrangement of viewOptions to not arranged
            set icon size of viewOptions to 104
            set text size of viewOptions to 13
            set shows item info of viewOptions to false
            set shows icon preview of viewOptions to true
            set background picture of viewOptions to file ".background:background.tiff"

            set position of item "CatPointer.app" to {174, 250}
            set position of item "Applications" to {546, 250}

            update without registering applications
            delay 1
            close
            open
            delay 1
            close
        end tell
    end tell
end run
