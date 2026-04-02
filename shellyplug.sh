#!/usr/bin/env bash

# Shelly Plug Control Script
# Usage: ./shellyplug.sh [-i <ip/hostname>] <command> [sleep_time]
# Commands: status, on, off, toggle, power-cycle, test
# sleep_time: Optional delay in seconds for power-cycle (default: 1.5)

show_usage() {
    echo "Usage: $0 [-i <ip/hostname>] <command> [sleep_time]"
    echo ""
    echo "Commands:"
    echo "  status        - Get current status of the device"
    echo "  on            - Turn the device on"
    echo "  off           - Turn the device off"
    echo "  toggle        - Toggle the device state"
    echo "  power-cycle   - Turn off, wait, then turn on (default sleep: 1.5s)"
    echo "  test          - Test device availability and basic Shelly plug response"
    echo ""
    echo "Environment variable SHELLY_HOST can be set to override -i silently."
}

check_curl() {
    if ! command -v curl >/dev/null 2>&1; then
        echo "Error: curl is required but not installed."
        exit 1
    fi
}

get_status() {
    local ip=$1
    echo "Getting status for Shelly device ($ip)..."
    response=$(curl -s --connect-timeout 5 "http://$ip/relay/0" 2>/dev/null)
    if [ $? -ne 0 ] || [ -z "$response" ]; then
        echo "Error: Could not connect to device ($ip)"
        return 1
    fi
    if echo "$response" | grep -q '"ison": *true'; then
        echo "Device: ON"
    elif echo "$response" | grep -q '"ison": *false'; then
        echo "Device: OFF"
    else
        echo "Device: Unknown status"
        echo "Raw response: $response"
        return 1
    fi
}

turn_on() {
    local ip=$1
    echo "Turning ON Shelly device ($ip)..."
    response=$(curl -s --connect-timeout 5 "http://$ip/relay/0?turn=on" 2>/dev/null)
    if echo "$response" | grep -q '"ison": *true'; then
        echo "Device successfully turned ON"
    else
        echo "Failed to turn on device"
        echo "Response: $response"
        return 1
    fi
}

turn_off() {
    local ip=$1
    echo "Turning OFF Shelly device ($ip)..."
    response=$(curl -s --connect-timeout 5 "http://$ip/relay/0?turn=off" 2>/dev/null)
    if echo "$response" | grep -q '"ison": *false'; then
        echo "Device successfully turned OFF"
    else
        echo "Failed to turn off device"
        echo "Response: $response"
        return 1
    fi
}

toggle_device() {
    local ip=$1
    echo "Toggling Shelly device ($ip)..."
    response=$(curl -s --connect-timeout 5 "http://$ip/relay/0" 2>/dev/null)
    if echo "$response" | grep -q '"ison": *true'; then
        turn_off "$ip"
    elif echo "$response" | grep -q '"ison": *false'; then
        turn_on "$ip"
    else
        echo "Cannot determine device state"
        echo "Raw response: $response"
        return 1
    fi
}

power_cycle() {
    local ip=$1
    local sleep_time=${2:-1.5}
    echo "Power cycling Shelly device ($ip)..."
    turn_off "$ip" || return 1
    sleep "$sleep_time"
    turn_on "$ip" || return 1
    echo "Power cycle completed."
}

test_device() {
    local ip=$1
    echo "Testing Shelly device ($ip)..."
    response=$(curl -s --connect-timeout 5 "http://$ip/relay/0" 2>/dev/null)
    if [ $? -ne 0 ] || [ -z "$response" ]; then
        echo "Device is unreachable or not a Shelly plug"
        return 1
    fi
    echo "Device responded successfully. Status check:"
    get_status "$ip"
}

main() {
    check_curl

    local ip=""

    # Parse -i option
    while getopts "i:" opt; do
        case $opt in
            i)
                ip="$OPTARG"
                ;;
            *)
                show_usage
                exit 1
                ;;
        esac
    done
    shift $((OPTIND - 1))

    # If environment variable is set, override -i silently
    [ -n "$SHELLY_HOST" ] && ip="$SHELLY_HOST"

    # Validate IP and command
    if [ -z "$ip" ] || [ $# -lt 1 ] || [ $# -gt 2 ]; then
        show_usage
        exit 1
    fi

    local command=$1
    local sleep_time=$2

    case "$command" in
        status)
            get_status "$ip"
            ;;
        on)
            turn_on "$ip"
            ;;
        off)
            turn_off "$ip"
            ;;
        toggle)
            toggle_device "$ip"
            ;;
        power-cycle)
            power_cycle "$ip" "$sleep_time"
            ;;
        test)
            test_device "$ip"
            ;;
        *)
            echo "Error: Invalid command '$command'"
            show_usage
            exit 1
            ;;
    esac
}

main "$@"
