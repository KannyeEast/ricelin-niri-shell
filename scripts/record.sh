#!/bin/sh
# Record the monitor you are looking at. An empty name is fine: the shell reads
# an empty monitor argument as "the focused output" and resolves it itself, so a
# niri that cannot answer right now still lands on the right screen.
mon=$(niri msg --json focused-output 2>/dev/null | jq -r '.name // empty')
qs -c pill ipc call pill quickRecord "$mon"
