#!/bin/bash
# Check if Quake is listening on the expected port
# Override Q3_HOME if your Quake install lives elsewhere.
Q3_HOME="${Q3_HOME:-$HOME/quake3}"
lsof -i :27960 -i :27961 2>/dev/null | head -20
echo "---"
# Also check what the rcon password is in autoexec
grep -i rcon "$Q3_HOME/baseq3/autoexec.cfg" 2>/dev/null
echo "---"
# Check .quake3home config
grep -i rcon "$Q3_HOME/.quake3home/baseq3/q3config.cfg" 2>/dev/null | head -5
