-- builder_api.applescript
--
-- Opens a new macOS terminal window and runs the builder-api server
-- inside the given project directory. Called by cld/ocd when the user
-- passes `--api` (or `-a`) on a macOS host.
--
-- Usage from shell:
--   osascript builder_api.applescript <launcher-script> <project-dir>
--
-- The launcher-script is builder-api/run-local.sh; it sources .env and
-- execs `python3 server.py` in <project-dir>.
--
-- Prefers iTerm.app if installed, otherwise falls back to Terminal.app.

on appExists(appPath)
    try
        do shell script "test -d " & quoted form of appPath
        return true
    on error
        return false
    end try
end appExists

on run argv
    if (count of argv) < 2 then
        error "builder_api.applescript: need <launcher-script> <project-dir>"
    end if
    set launcher to item 1 of argv
    set projectDir to item 2 of argv

    -- We invoke via `bash` so run-local.sh doesn't need the execute bit set;
    -- quoted form guarantees correct escaping of paths with spaces.
    set cmd to "bash " & quoted form of launcher & " " & quoted form of projectDir

    if appExists("/Applications/iTerm.app") then
        tell application "iTerm"
            activate
            set newWindow to (create window with default profile)
            tell current session of newWindow
                write text cmd
            end tell
        end tell
    else
        tell application "Terminal"
            activate
            do script cmd
        end tell
    end if
end run
