#!/bin/sh
umask 077
dir="${XDG_RUNTIME_DIR:-/tmp}"

# Grab every monitor first so the desktop is captured while it is still live and
# on screen, then lock. The lock surface reveals onto these grabs, so they must
# exist before it mounts; showing the live desktop during the grab reads as the
# desktop simply blurring into the lock, with no flash.
#
# `niri msg --json outputs` is a map keyed by connector name, so the names are
# the keys rather than a field. A connected-but-disabled output is still in that
# map, with a null `logical` — grabbing one leaves a stale or empty png that the
# lock surface would later reveal onto, so only mapped outputs are grabbed.
for out in $(niri msg --json outputs \
    | jq -r 'to_entries | map(select(.value.logical != null)) | .[].key'); do
    [ -n "$out" ] || continue
    rm -f "$dir/ricelin-lock-$out.png"
    grim -o "$out" "$dir/ricelin-lock-$out.png" 2>/dev/null &
done
wait

# Poke the lock daemon through its file watch instead of spawning a whole qs client,
# which shaves the Qt client startup off the lock delay.
date +%s%N > "$dir/ricelin-lock-trigger"
