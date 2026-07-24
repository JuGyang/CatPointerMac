on run argv
    if (count of argv) is not 1 then error "usage: create-applications-alias.applescript <destination>"
    set destinationFolder to POSIX file (item 1 of argv) as alias
    set applicationsFolder to POSIX file "/Applications" as alias

    tell application "Finder"
        set installAlias to make new alias file at destinationFolder to applicationsFolder
        set name of installAlias to "Applications"
    end tell
end run
