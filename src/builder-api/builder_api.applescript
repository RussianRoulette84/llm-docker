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
    -- Optional 6th arg: shell command to run in a SECOND new pane
    -- horizontally-split off the source pane (typically the cld-status
    -- live dashboard). Empty = don't spawn one. Only honored in "split"
    -- mode — new-window mode opens a separate iTerm window and has no
    -- "source pane" to split off of.
    set statusCmd to ""
    if (count of argv) >= 6 then
        set statusCmd to item 6 of argv
    end if
    -- Optional 7th arg: shell command for a THIRD pane (verbose console),
    -- horizontally-split BELOW the builder-api pane. Empty = skip. Split
    -- mode only (new-window mode has no source pane to stack onto).
    set verboseCmd to ""
    if (count of argv) >= 7 then
        set verboseCmd to item 7 of argv
    end if

    -- Build the shell command that needs to run in the new pane.
    -- We invoke via `bash` so run-local.sh doesn't need the execute bit
    -- set; quoted form guarantees correct escaping of paths with spaces.
    -- Handoff path is passed as the SECOND positional arg to run-local.sh
    -- (run-local.sh sources + deletes it).
    set cmd to "bash " & quoted form of launcher & " " & quoted form of projectDir
    if handoffPath is not "" then
        set cmd to cmd & " " & quoted form of handoffPath
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

    -- Pane width in COLUMNS, not pixels — iTerm multiplies by the
    -- profile's font size, so a user with a larger font sees a wider
    -- pixel pane than the col count alone implies. 40 cols keeps the
    -- right pane at ~23% of a typical 1500-px-wide screen at Yaro's
    -- font size; banner.py clamps its box (BOX_WIDTH=61) to whatever
    -- the actual pane width turns out to be.
    set winCols to 40

    -- REUSE: prefer finding the pane by the daemon's actual tty (works
    -- even after the iTerm session's name got overwritten — e.g. you
    -- exited claude in the main window and relaunched). Fall back to
    -- the title-tagged lookup when the daemon is dead but the pane is
    -- still open, so we relaunch in-place instead of opening a new one.
    set reuseSession to my findSessionByPort(portStr)
    set daemonAlive to (reuseSession is not missing value)
    if reuseSession is missing value then
        set reuseSession to my findSessionByTitle(sessionTitle)
    end if
    if reuseSession is not missing value then
        tell application "iTerm"
            activate
            tell reuseSession
                select
                if not daemonAlive then
                    write text reuseCmd
                end if
            end tell
        end tell
        return
    end if

    -- No reuse pane found anywhere. If an orphan daemon is still bound
    -- to this port (its pane was closed), kill it so the fresh spawn
    -- below can bind cleanly.
    if portStr is not "" then
        try
            do shell script "lsof -ti :" & portStr & " 2>/dev/null | xargs kill 2>/dev/null; sleep 0.4"
        end try
    end if

    if mode is "split" then
        -- Split the current iTerm window left/right and shrink the new
        -- right pane to winCols. iTerm's `set columns` on a session
        -- resizes the entire OUTER window (not just the pane) — so we
        -- snapshot the window bounds before the split, apply the column
        -- count, then restore the snapshot. iTerm rebalances the two
        -- panes to fit the original window width, which leaves the
        -- user's left pane visually untouched outside the divider.
        tell application "iTerm"
            activate
            tell current window
                set origBounds to bounds
                set sourceSession to current session

                if statusCmd is not "" then
                    -- TOP-RIGHT: status pane created and written FIRST.
                    -- Same proven pattern: write IMMEDIATELY after split,
                    -- before any other operations touch other panes.
                    tell sourceSession
                        set rightPane to (split vertically with default profile)
                    end tell
                    -- Settle delay BEFORE the first write (placed outside the
                    -- session tell, like the 0.5 below). Each new terminal runs
                    -- a Matrix intro animation whose terminal output otherwise
                    -- lands in front of the command as `?exec` (zsh: no matches
                    -- found). 2.5s lets the animation finish before we type.
                    delay 2.5
                    tell rightPane
                        try
                            set columns to winCols
                        end try
                        set name to "cld-status"
                        write text statusCmd
                    end tell

                    delay 0.5

                    -- BOTTOM-RIGHT: builder-api pane. Split rightPane
                    -- horizontally; new pane appears below. Write text
                    -- to it IMMEDIATELY before touching anything else.
                    tell rightPane
                        set bottomPane to (split horizontally with default profile)
                    end tell
                    tell bottomPane
                        set name to sessionTitle
                        write text cmd
                    end tell

                    -- THIRD pane: verbose console, split horizontally BELOW the
                    -- builder-api pane. Write IMMEDIATELY after the split, same
                    -- proven pattern as the panes above.
                    if verboseCmd is not "" then
                        delay 0.5
                        tell bottomPane
                            set verbosePane to (split horizontally with default profile)
                        end tell
                        tell verbosePane
                            set name to "verbose"
                            write text verboseCmd
                        end tell
                    end if

                    -- Rebalance row heights. With a verbose pane the stack is
                    -- status / api / verbose; give the scrolling console the
                    -- remainder. Without it, keep the original status=15.
                    delay 0.2
                    if verboseCmd is not "" then
                        tell rightPane
                            try
                                set rows to 12
                            end try
                        end tell
                        tell bottomPane
                            try
                                set rows to 14
                            end try
                        end tell
                    else
                        tell rightPane
                            try
                                set rows to 15
                            end try
                        end tell
                    end if
                else
                    -- Single-pane HEAD code path (no status pane).
                    tell sourceSession
                        set rightPane to (split vertically with default profile)
                    end tell
                    tell rightPane
                        try
                            set columns to winCols
                        end try
                        set name to sessionTitle
                        write text cmd
                    end tell
                end if

                try
                    set bounds to origBounds
                end try
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

    -- Approximate pixel width for the new-window mode (only used when
    -- we're NOT already inside iTerm — split mode lets iTerm size by
    -- columns). Scales with winCols: ~9.5 px per column at the default
    -- profile + a small constant for chrome/padding.
    set winW to 510
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
