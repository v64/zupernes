#!/bin/bash
# Quick test run script - builds and runs emulator for a few seconds
# Usage: ./test-run.sh [rom_path] [duration_seconds] [debug]
# Examples:
#   ./test-run.sh                           # Default ROM, 3 seconds, no debug
#   ./test-run.sh myrom.sfc 5               # Custom ROM, 5 seconds
#   ./test-run.sh myrom.sfc 3 debug         # With debug output
#
# Output is automatically logged to /tmp/zupernes-<romname>.log
# Grep this file instead of re-running the test repeatedly!

ROM="${1:-test/games/Super Mario World (USA).sfc}"
DURATION="${2:-3}"
DEBUG_FLAG=""
if [ "$3" = "debug" ]; then
    DEBUG_FLAG="-Ddebug=true"
fi

# Generate log file name from ROM basename (replace spaces with underscores)
ROM_BASENAME=$(basename "$ROM" | sed 's/\.[^.]*$//' | tr ' ' '_' | tr -cd '[:alnum:]_-')
LOGFILE="/tmp/zupernes-${ROM_BASENAME}.log"

# Kill any existing instances first
pkill -f zupernes 2>/dev/null

echo "Building with flags: $DEBUG_FLAG"
echo "Running: $ROM for $DURATION seconds"
echo "Logging to: $LOGFILE"
echo "---"

# Build first, then run with output going to both console and log file
if zig build $DEBUG_FLAG; then
    # Use process substitution to capture emulator PID, not tee's PID
    ./zig-out/bin/zupernes "$ROM" > >(tee "$LOGFILE") 2>&1 &
    PID=$!
    sleep "$DURATION"
    kill $PID 2>/dev/null
    wait $PID 2>/dev/null
    sleep 0.5  # Let tee finish writing
else
    echo "Build failed!"
    exit 1
fi

# Clean up at end too
pkill -f zupernes 2>/dev/null

echo ""
echo "---"
echo "Log saved to: $LOGFILE"
echo "Lines captured: $(wc -l < "$LOGFILE")"
echo ""
echo "Grep examples:"
echo "  grep 'SPC' $LOGFILE"
echo "  grep '\$0549' $LOGFILE"
