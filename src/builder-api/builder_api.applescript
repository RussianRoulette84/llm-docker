-- builder_api.applescript
--
-- Runs the builder-api server in a macOS terminal context. Called by
-- cld/ocd when the user passes `--api` (or `-a`) on a macOS host.
--
-- Usage from shell:
--   osascript builder_api.applescript <launcher> <project-dir> [mode] [port] [handoff]
--     mode    = "split"       (vertical split of current iTerm window)
--             | "new-window"  (default — open a new positioned iTerm window)
--     port    = TCP port the daemon listens on. Used by the reuse path to
--               kill only THIS project's daemon (`lsof -ti :PORT`), not all
--               builder-api processes on the host.
--     handoff = optional path to a short-lived shell file written by the
--               calling cld/ocd; sourced + deleted before run-local.sh runs
--               so the new shell inherits the parent's already-unwrapped
--               secrets without re-prompting Touch ID.
--
-- The launcher-script is builder-api/run-local.sh; it sources .env and
-- execs `python3 server.py` in <project-dir>.
--
-- Layouts:
--   split      — splits the frontmost iTerm window left/right. Right pane
--                is set to 43 columns and runs builder-api; left pane
--                stays with whatever the user was running (their main
--                Claude/OpenCode session).
--   new-window — opens a new iTerm window pinned to the screen's right
--                edge, 43 cols wide, full vertical. Used when we're not
--                already inside iTerm.
--
-- banner.py detects the column count and switches to a compact line
-- format below ~70 cols.

on appExists(appPath)
    try
        do shell script "test -d " & quoted form of appPath
        return true
    on error
        return false
    end try
end appExists

-- Find an existing iTerm session whose name matches `title`. Returns
-- the session record or `missing value` if not present.
on findSessionByTitle(title)
    tell application "iTerm"
        repeat with w in windows
            repeat with t in tabs of w
                repeat with s in sessions of t
                    try
                        if name of s is title then return s
                    end try
                end repeat
            end repeat
        end repeat
    end tell
    return missing value
end findSessionByTitle

-- Find an iTerm session whose tty is the controlling tty of the daemon
-- listening on `portStr`. This survives anything that overwrites the
-- session name (shell prompt, exiting claude, etc.) as long as the
-- daemon itself is alive on the port.
on findSessionByPort(portStr)
    if portStr is "" then return missing value
    set ttyPath to ""
    try
        set ttyPath to do shell script "pid=$(lsof -ti :" & portStr & " 2>/dev/null | head -1); [ -z \"$pid\" ] && exit 1; t=$(ps -o tty= -p $pid 2>/dev/null | tr -d ' '); [ -z \"$t\" ] && exit 1; echo /dev/$t"
    on error
        return missing value
    end try
    if ttyPath is "" then return missing value
    tell application "iTerm"
        repeat with w in windows
            repeat with t in tabs of w
                repeat with s in sessions of t
                    try
                        if tty of s is ttyPath then return s
                    end try
                end repeat
            end repeat
        end repeat
    end tell
    return missing value
end findSessionByPort

-- Build the iTerm session title for a given project. Project-namespaced
-- so two projects running `cld -a` at once get their own panes instead
-- of fighting for one.
on titleForProject(projectDir)
    set AppleScript's text item delimiters to "/"
    set parts to text items of projectDir
    set AppleScript's text item delimiters to ""
    set projName to item -1 of parts
    if projName is "" and (count of parts) > 1 then
        set projName to item -2 of parts
    end if
    return "builder-api: " & projName
end titleForProject

on run argv
    if (count of argv) < 2 then
        error "builder_api.applescript: need <launcher> <project-dir> [mode]"
    end if
    set launcher to item 1 of argv
    set projectDir to item 2 of argv
    set mode to "new-window"
    if (count of argv) >= 3 then
        set mode to item 3 of argv
    end if
    set portStr to ""
    if (count of argv) >= 4 then
        set portStr to item 4 of argv
    end if
    set handoffPath to ""
    if (count of argv) >= 5 then
        set handoffPath to item 5 of argv
    end if

    -- We invoke via `bash` so run-local.sh doesn't need the execute bit set;
    -- quoted form guarantees correct escaping of paths with spaces.
    set cmd to "bash " & quoted form of launcher & " " & quoted form of projectDir
    -- Source the parent's secret handoff (then delete it) so the spawned
    -- shell skips its own env-gorilla call. reuseCmd inherits this prefix
    -- because it builds from `cmd` below.
    if handoffPath is not "" then
        set cmd to ". " & quoted form of handoffPath & " 2>/dev/null; rm -f " & quoted form of handoffPath & "; " & cmd
    end if
    set sessionTitle to my titleForProject(projectDir)
    -- Reuse-path command: kill ONLY the daemon bound to this project's
    -- port, not all builder-api processes on the host. Falls back to a
    -- no-op when port wasn't passed (older callers).
    if portStr is "" then
        set reuseCmd to "clear; " & cmd
    else
        set reuseCmd to "lsof -ti :" & portStr & " 2>/dev/null | xargs -r kill 2>/dev/null; sleep 0.4; clear; " & cmd
    end if

    set winCols to 43

    -- REUSE: prefer finding the pane by the daemon's actual tty (works
    -- even after the iTerm session's name got overwritten — e.g. you
    -- exited claude in the main window and relaunched). Fall back to
    -- the title-tagged lookup when the daemon is dead but the pane is
    -- still open, so we relaunch in-place instead of opening a new one.
    set reuseSession to my findSessionByPort(portStr)
    if reuseSession is missing value then
        set reuseSession to my findSessionByTitle(sessionTitle)
    end if
    if reuseSession is not missing value then
        tell application "iTerm"
            activate
            tell reuseSession
                select
                write text reuseCmd
            end tell
        end tell
        return
    end if

    if mode is "split" then
        -- Split the current iTerm window left/right. Right pane shrinks
        -- to winCols; left pane keeps the rest. The user's existing
        -- Claude/OpenCode session is in the left pane and untouched.
        tell application "iTerm"
            activate
            tell current window
                tell current session
                    set newSession to (split vertically with default profile)
                    tell newSession
                        try
                            set columns to winCols
                        end try
                        set name to sessionTitle
                        write text cmd
                    end tell
                end tell
            end tell
        end tell
        return
    end if

    -- Default mode: open a new window pinned to the right edge of the
    -- main screen. Use Finder for screen bounds (no extra permissions).
    -- Dock detection without Accessibility permission isn't reliable, so
    -- the bottom edge sits flush with screen height — bottom-docked
    -- users will see a slight overlap, top/left/right-docked users won't.
    tell application "Finder"
        set scr to bounds of window of desktop
    end tell
    set screenTop to item 2 of scr
    set screenRight to item 3 of scr
    set screenBottom to item 4 of scr

    -- 43 cols at the default iTerm profile is ~420 px including padding.
    set winW to 420
    set winX to screenRight - winW
    set winY to screenTop
    -- Menu bar buffer: desktop bounds reportedly already exclude it, but
    -- some macOS versions return raw pixels. 24 px keeps the titlebar
    -- visible either way.
    if winY < 24 then set winY to 24

    if appExists("/Applications/iTerm.app") then
        tell application "iTerm"
            activate
            set newWindow to (create window with default profile)
            set bounds of newWindow to {winX, winY, screenRight, screenBottom}
            tell current session of newWindow
                try
                    set columns to winCols
                end try
                set name to sessionTitle
                write text cmd
            end tell
        end tell
    else
        tell application "Terminal"
            activate
            do script cmd
            set bounds of front window to {winX, winY, screenRight, screenBottom}
            set custom title of front window to sessionTitle
        end tell
    end if
end run
