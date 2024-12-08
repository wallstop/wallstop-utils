#!/bin/bash

# Log start
LOG_FILE="$HOME/move_cursor.log"
echo "$(date): move_cursor.sh triggered" >> "$LOG_FILE"

# Get the focused window details
focused_window=$(yabai -m query --windows --window)
if [ -z "$focused_window" ]; then
    echo "$(date): No focused window found" >> "$LOG_FILE"
    exit 1
fi

focused_window_id=$(echo "$focused_window" | jq '.id')

# Get window frame details
window_frame=$(yabai -m query --windows --window "$focused_window_id" | jq '.frame')

# Extract x, y, width, height
x=$(echo "$window_frame" | jq -r '.x')
y=$(echo "$window_frame" | jq -r '.y')
width=$(echo "$window_frame" | jq -r '.w')
height=$(echo "$window_frame" | jq -r '.h')

# Validate that all variables are numeric
if ! [[ "$x" =~ ^-?[0-9]+(\.[0-9]+)?$ ]] || \
   ! [[ "$y" =~ ^-?[0-9]+(\.[0-9]+)?$ ]] || \
   ! [[ "$width" =~ ^-?[0-9]+(\.[0-9]+)?$ ]] || \
   ! [[ "$height" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
    echo "$(date): Invalid window frame values. x=$x, y=$y, width=$width, height=$height" >> "$LOG_FILE"
    exit 1
fi

# Calculate center coordinates
center_x=$(awk "BEGIN {print int($x + $width / 2)}")
center_y=$(awk "BEGIN {print int($y + $height / 2)}")

# Get current mouse position using cliclick
CICLICK_PATH=$(which cliclick)
if [ -z "$CICLICK_PATH" ]; then
    echo "$(date): cliclick not found in PATH" >> "$LOG_FILE"
    exit 1
fi

mouse_pos=$($CICLICK_PATH p:)
mouse_x=$(echo "$mouse_pos" | cut -d, -f1)
mouse_y=$(echo "$mouse_pos" | cut -d, -f2)

# Check if mouse is within window bounds
x=$(awk "BEGIN {print $x}")
y=$(awk "BEGIN {print $y}")
window_right=$(awk "BEGIN {print $x + $width}")
window_bottom=$(awk "BEGIN {print $y + $height}")

# Window coordinates: 457 561 12.0000 1716 50.0000 1038
echo "Window coordinates: $mouse_x $mouse_y $x $window_right $y $window_bottom" >> "$LOG_FILE"

if [ "$mouse_x" -ge "$x" ] && [ "$mouse_x" -le "$window_right" ] && \
   [ "$mouse_y" -ge "$y" ] && [ "$mouse_y" -le "$window_bottom" ]; then
    # Mouse is already inside the window - do nothing
    echo "$(date): Mouse is within the window bounds, not moving cursor" >> "$LOG_FILE"
    exit 0
else
    # Mouse is outside the window, move to center
    echo "$(date): Moving cursor to center ($center_x, $center_y)" >> "$LOG_FILE"
    "$CICLICK_PATH" m:"$center_x","$center_y" >> "$LOG_FILE" 2>&1
fi