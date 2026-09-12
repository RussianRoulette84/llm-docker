-- close_api_panes.applescript
--
-- Teardown helper invoked by cld/ocd on exit. Closes ONE project's
-- builder-api pane and its cld-status dashboard pane, and stops the daemon.
--
-- Usage:
--   osascript close_api_panes.applescript <port> <project-dir> [debug]
--     debug = print what was found/closed (run manually to diagnose).
--
-- Deliberately a SEPARATE file from builder_api.applescript: a bug in here
-- must never be able to break the spawn path.
--
-- Targeting (and why it won't touch OTHER claude sessions' panels):
--   * the builder-api pane is found by THIS project's daemon tty (resolved
--     from its unique port), with the project title as a fallback;
--   * the cld-status pane is matched by the tty of a running cld-status
--     process, but ONLY within the tab that already holds this project's api
--     pane — so a different project's api/status panes (different port, different
--     tab) are never selected.
-- Processes are killed BEFORE the sessions are closed, so iTerm shows no
-- "close this session?" confirmation.

-- Split "a,b,c" into a list on the given delimiter.
on splitText(txt, delim)
    set AppleScript's text item delimiters to delim
    set parts to text items of txt
    set AppleScript's text item delimiters to ""
    return parts
end splitText


on run argv
    if (count of argv) < 2 then return "need <port> <project-dir>"
    set portStr to item 1 of argv
    set projectDir to item 2 of argv
    -- 3rd arg (optional): the CALLER's tty (the cld/ocd pane). When given, we
    -- close every OTHER session in the api pane's tab — the whole right column
    -- (status/api/verbose) — and spare only the caller. Far more reliable than
    -- matching each pane by tty/name, which drift.
    set keepTty to ""
    if (count of argv) >= 3 and item 3 of argv is not "debug" and item 3 of argv is not "caller-only" then set keepTty to item 3 of argv
    set dbg to false
    -- "caller-only": match the tab by the caller's tty ALONE. Used when another
    -- window owns the daemon — matching by port/title would find THAT window's
    -- tab and close its column.
    set callerOnly to false
    -- "ttys=/dev/ttys1,/dev/ttys2": the exact panes to close, recorded when they
    -- were created. Exact identity beats re-finding them by port or title —
    -- those drift as soon as a pane is renamed or a second window joins in.
    set ttyList to {}
    repeat with _a in argv
        set _t to _a as text
        if _t is "debug" then set dbg to true
        if _t is "caller-only" then set callerOnly to true
        if _t starts with "ttys=" then set ttyList to my splitText(text 6 thru -1 of _t, ",")
    end repeat
    set logTxt to "keepTty=" & keepTty & linefeed

    -- 1) Resolve the daemon's tty from its port (shell work outside any tell).
    set apiTty to ""
    if portStr is not "" then
        try
            set apiTty to do shell script "pid=$(lsof -ti :" & portStr & " 2>/dev/null | head -1); [ -z \"$pid\" ] && exit 1; t=$(ps -o tty= -p $pid 2>/dev/null | tr -d ' '); [ -z \"$t\" ] && exit 1; echo /dev/$t"
        end try
    end if
    set logTxt to logTxt & "apiTty=[" & apiTty & "]" & linefeed

    -- 2) ttys of every running cld-status AND cld-verbose pane process.
    set statusTtys to {}
    try
        set rawTtys to do shell script "for p in $(pgrep -f '/cld-status' 2>/dev/null; pgrep -f '/cld-verbose' 2>/dev/null); do t=$(ps -o tty= -p $p 2>/dev/null | tr -d ' '); [ -n \"$t\" ] && echo /dev/$t; done"
        if rawTtys is not "" then
            set AppleScript's text item delimiters to linefeed
            set statusTtys to text items of rawTtys
            set AppleScript's text item delimiters to ""
        end if
    end try
    set logTxt to logTxt & "statusTtys=" & (my joinList(statusTtys)) & linefeed

    set sessTitle to my titleForProject(projectDir)

    -- 3) Walk iTerm read-only: find the tab holding the api pane, collect the
    --    target sessions + their ttys inside THAT tab.
    set victims to {}
    set victimTtys to {}
    if ttyList is not {} and application "iTerm" is running then
      try
        tell application "iTerm"
            repeat with w in windows
                repeat with tb in tabs of w
                    repeat with s in sessions of tb
                        try
                            set stt to tty of s
                            if my listHas(ttyList, stt) and stt is not keepTty then
                                set end of victims to s
                                set end of victimTtys to stt
                            end if
                        end try
                    end repeat
                end repeat
            end repeat
        end tell
      end try
    else if application "iTerm" is running then
      try
        tell application "iTerm"
            repeat with w in windows
                repeat with tb in tabs of w
                    set hasApi to false
                    repeat with s in sessions of tb
                        try
                            if not callerOnly then
                                if apiTty is not "" and (tty of s) is apiTty then set hasApi to true
                                if (name of s) is sessTitle then set hasApi to true
                            end if
                            if keepTty is not "" and (tty of s) is keepTty then set hasApi to true
                        end try
                    end repeat
                    if hasApi then
                        repeat with s in sessions of tb
                            try
                                set stt to tty of s
                                set isVictim to false
                                if keepTty is not "" then
                                    -- Close the whole right column: EVERY session
                                    -- in the api pane's tab except the caller's own
                                    -- (keepTty). No per-pane tty/name matching that
                                    -- can drift — this is the reliable path.
                                    if stt is not keepTty then set isVictim to true
                                else
                                    -- Legacy fallback (no caller tty): match by
                                    -- daemon tty / title / cld-status|verbose names
                                    -- / pgrep'd ttys. `contains` catches auto-renamed
                                    -- panes (iTerm rewrites the name to the running
                                    -- command's title, so exact `is` was missing them).
                                    set snm to name of s
                                    if (apiTty is not "" and stt is apiTty) or (snm is sessTitle) or (snm contains "cld-status") or (snm contains "verbose") or (my listHas(statusTtys, stt)) then set isVictim to true
                                end if
                                if isVictim then
                                    set end of victims to s
                                    set end of victimTtys to stt
                                end if
                            end try
                        end repeat
                    end if
                end repeat
            end repeat
        end tell
      end try
    end if
    set logTxt to logTxt & "victimTtys=" & (my joinList(victimTtys)) & linefeed

    -- 4) Kill the panes' processes + the daemon (outside the tell) so the
    --    sessions can close without a confirmation prompt.
    try
        if portStr is not "" then do shell script "lsof -ti :" & portStr & " 2>/dev/null | xargs kill 2>/dev/null || true"
    end try
    repeat with tt in victimTtys
        try
            do shell script "ps -t " & (do shell script "basename " & quoted form of (tt as text)) & " -o pid= 2>/dev/null | xargs kill 2>/dev/null || true"
        end try
    end repeat

    -- 5) Close the (now dead) iTerm sessions. Guarded so we never LAUNCH iTerm
    --    on a Terminal.app-only machine.
    set closed to 0
    if application "iTerm" is running then
        tell application "iTerm"
            repeat with v in victims
                try
                    close v
                    set closed to closed + 1
                end try
            end repeat
        end tell
    end if

    -- 5b) Terminal.app fallback: when spawned outside iTerm the builder-api
    --     window is titled "builder-api: <proj>" (no cld-status pane — splits
    --     are iTerm-only). Close it by title. Daemon already killed above, so
    --     no confirmation prompt.
    if application "Terminal" is running then
        try
            tell application "Terminal"
                repeat with win in windows
                    try
                        if (custom title of win) is sessTitle then
                            close win
                            set closed to closed + 1
                        end if
                    end try
                end repeat
            end tell
        end try
    end if
    set logTxt to logTxt & "closed=" & closed & " of " & (count of victims) & linefeed

    if dbg then return logTxt
    return ""
end run

on titleForProject(projectDir)
    set AppleScript's text item delimiters to "/"
    set parts to text items of projectDir
    set AppleScript's text item delimiters to ""
    set projName to item -1 of parts
    if projName is "" and (count of parts) > 1 then set projName to item -2 of parts
    return "builder-api: " & projName
end titleForProject

on listHas(lst, val)
    repeat with x in lst
        try
            if (x as text) is (val as text) then return true
        end try
    end repeat
    return false
end listHas

on joinList(lst)
    set s to ""
    repeat with x in lst
        set s to s & "(" & (x as text) & ")"
    end repeat
    return s
end joinList
