#!/usr/bin/env bash

# Simple wrapper for usbsdmux (Linux Automation)
# Default device: /dev/sg0

DEVICE="/dev/sg0"

usage() {
    echo "Usage: $0 [host|dut|off|test] [-d <device>]"
    echo ""
    echo "Environment variable SDCARDMUX_DEVICE can be set to override -d silently."
    exit 1
}

# Check dependency
if ! command -v usbsdmux >/dev/null 2>&1; then
    echo "Error: usbsdmux not found in PATH"
    exit 1
fi

# Parse optional -d argument
while getopts "d:" opt; do
    case $opt in
        d)
            DEVICE="$OPTARG"
            ;;
        *)
            usage
            ;;
    esac
done

shift $((OPTIND - 1))

# Mode (host/dut/off/test) is the first positional argument
[ $# -lt 1 ] && usage
MODE="$1"

# If environment variable is set, override DEVICE silently
if [ -n "$SDCARDMUX_DEVICE" ]; then
    DEVICE="$SDCARDMUX_DEVICE"
fi

# Function to read current state
get_state() {
    usbsdmux "$DEVICE" get 2>/dev/null
}

# Switch / Test
case "$MODE" in
    host|dut|off)
        echo "Switching SD card to $MODE ($DEVICE)..."
        if ! usbsdmux "$DEVICE" "$MODE"; then
            echo "Switch command failed!"
            exit 1
        fi
        ;;
    test)
        echo "TEST mode: SD card device is '$DEVICE'"
        STATE="$(get_state)"
        echo "Current state: $STATE"
        exit 0
        ;;
    *)
        usage
        ;;
esac

# Verify
sleep 0.5  # small delay for hardware to settle

STATE="$(get_state)"
echo "Current state: $STATE"

if echo "$STATE" | grep -qi "$MODE"; then
    echo "Switch to $MODE successful."
    exit 0
else
    echo "Switch verification FAILED!"
    exit 1
fi
