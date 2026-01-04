#!/bin/bash
# Quick test run script - builds and runs emulator for a few seconds
# Usage: ./test-run.sh [rom_path] [duration_seconds] [debug]
# Examples:
#   ./test-run.sh                           # Default ROM, 3 seconds, no debug
#   ./test-run.sh myrom.sfc 5               # Custom ROM, 5 seconds
#   ./test-run.sh myrom.sfc 3 debug         # With debug output

ROM="${1:-test/games/Super Mario World (USA).sfc}"
DURATION="${2:-3}"
DEBUG_FLAG=""
if [ "$3" = "debug" ]; then
    DEBUG_FLAG="-Ddebug=true"
fi

# Kill any existing instances first
pkill -f zupernes 2>/dev/null

zig build $DEBUG_FLAG && ./zig-out/bin/zupernes "$ROM" 2>&1 &
PID=$!
sleep "$DURATION"
kill $PID 2>/dev/null
wait $PID 2>/dev/null

# Clean up at end too
pkill -f zupernes 2>/dev/null
