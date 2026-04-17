use framework "AppKit"
use scripting additions

-- Usage: osascript pro_llm.applescript <toolPath> <windowCount> <projectDir> <restore|new>
on run argv
	set toolPath to item 1 of argv
	set winCount to (item 2 of argv) as integer
	set projDir to item 3 of argv
	set slotMode to item 4 of argv

	-- Kill iTerm and wipe its session state so nothing restores
	do shell script "killall iTerm2 2>/dev/null; sleep 1; rm -rf ~/Library/Saved\\ Application\\ State/com.googlecode.iterm2.savedState 2>/dev/null; true"
	delay 1

	-- Screen geometry
	set nsScreens to current application's NSScreen's screens()
	set primaryH to 0
	repeat with s in nsScreens
		set ff to s's frame()
		set ffList to ff as list
		set ffOrigin to item 1 of ffList
		set ffSz to item 2 of ffList
		set ffx to (item 1 of ffOrigin) as integer
		set ffy to (item 2 of ffOrigin) as integer
		set ffh to (item 2 of ffSz) as integer
		if ffx = 0 and ffy = 0 then set primaryH to ffh
	end repeat

	set screenList to {}
	repeat with s in nsScreens
		set vf to s's visibleFrame()
		set vfList to vf as list
		set vOrigin to item 1 of vfList
		set vSz to item 2 of vfList
		set vx to (item 1 of vOrigin) as integer
		set vy to (item 2 of vOrigin) as integer
		set vw to (item 1 of vSz) as integer
		set vh to (item 2 of vSz) as integer
		set vTop to primaryH - vy - vh
		set end of screenList to {vx:vx, vTop:vTop, vw:vw, vh:vh}
	end repeat

	-- Sort screens left to right
	set screenCount to count of screenList
	repeat with i from 1 to screenCount - 1
		repeat with j from 1 to screenCount - i
			if (vx of item j of screenList) > (vx of item (j + 1) of screenList) then
				set tmp to item j of screenList
				set item j of screenList to item (j + 1) of screenList
				set item (j + 1) of screenList to tmp
			end if
		end repeat
	end repeat

	-- Pick target screens (1=all, 2=right, 3+=skip middle)
	set targets to {}
	if screenCount = 1 then
		set targets to {item 1 of screenList}
	else if screenCount = 2 then
		set targets to {item 2 of screenList}
	else
		repeat with i from 1 to screenCount
			if i is not 2 then set end of targets to item i of screenList
		end repeat
	end if

	-- Distribute windows across screens
	set targetCount to count of targets
	set windowsPerScreen to {}
	set remaining to winCount
	repeat with i from 1 to targetCount
		if i = targetCount then
			set end of windowsPerScreen to remaining
		else
			set perScreen to winCount div targetCount
			set end of windowsPerScreen to perScreen
			set remaining to remaining - perScreen
		end if
	end repeat

	-- Build bounds + commands
	set toolName to do shell script "basename " & quoted form of toolPath
	set allBounds to {}
	set allCommands to {}
	set slotNum to 1

	repeat with si from 1 to targetCount
		set scr to item si of targets
		set numWin to item si of windowsPerScreen
		set cols to 2
		if numWin = 1 then set cols to 1
		set rows to (numWin + cols - 1) div cols
		if rows < 1 then set rows to 1
		set cellW to (vw of scr) div cols
		set cellH to (vh of scr) div rows

		repeat with row from 0 to rows - 1
			repeat with col from 0 to cols - 1
				if slotNum > winCount then exit repeat
				set wx to (vx of scr) + col * cellW
				set wy to (vTop of scr) + row * cellH
				set end of allBounds to {wx, wy, wx + cellW, wy + cellH}

				if toolName = "cld" then
					set cmd to "cd " & projDir & " && " & toolPath & " --slot " & slotNum
					if slotMode = "restore" then set cmd to cmd & " -c"
				else
					set cmd to "cd " & projDir & " && " & toolPath
					if slotMode = "restore" then set cmd to cmd & " -c"
				end if

				set end of allCommands to cmd
				set slotNum to slotNum + 1
			end repeat
			if slotNum > winCount then exit repeat
		end repeat
	end repeat

	-- Create windows, position, wait for animation, then type commands
	tell application "iTerm"
		activate
		delay 1

		set winRefs to {}
		repeat with i from 1 to count of allBounds
			set w to (create window with default profile)
			delay 0.5
			set bounds of w to item i of allBounds
			set end of winRefs to w
		end repeat

		-- Wait for cmatrix animation + shell prompt to be fully ready
		delay 2

		-- Type commands into each window
		set killLine to (ASCII character 21)
		repeat with i from 1 to count of winRefs
			tell current session of item i of winRefs
				-- Ctrl+U clears any garbage, then type command
				write text killLine & (item i of allCommands)
			end tell
			delay 0.5
		end repeat
	end tell
end run
