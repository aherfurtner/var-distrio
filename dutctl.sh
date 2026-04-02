#!/usr/bin/env bash

# DUT controller wrapper for SD mux and power switching.

set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/.config"
SD_SCRIPT="$SCRIPT_DIR/tools/sdcardmux.sh"
POWER_SCRIPT="$SCRIPT_DIR/tools/shellyplug.sh"
FLASH_SCRIPT="$SCRIPT_DIR/tools/sdflash.sh"

FORCE=0
FLASH_ATTACH_WAIT_SECONDS=2

usage() {
    cat <<EOF
Usage:
  $0 [-f] sd <attach|detach>
  $0 power <on|off|power-cycle> [pause_seconds]
  $0 flash <image>

Options:
  -f    Force SD operation even when DUT is powered on.

Notes:
  - If .config exists beside this script, it is sourced automatically.
  - sd attach -> SD card connected to DUT (mux mode: dut)
  - sd detach -> SD card disconnected from DUT / connected to host (mux mode: host)
  - flash <image> -> power off DUT (with prompt if needed), detach SD to host, run sdflash clone
EOF
    exit 1
}

die() {
    echo "Error: $*" >&2
    exit 1
}

run_script() {
    local script="$1"
    shift

    [ -f "$script" ] || die "Required helper script not found: $script"

    if [ -x "$script" ]; then
        "$script" "$@"
    else
        bash "$script" "$@"
    fi
}

source_local_config() {
    if [ -f "$CONFIG_FILE" ]; then
        # shellcheck disable=SC1090
        . "$CONFIG_FILE"
    fi
}

power_state() {
    local out

    if ! out="$(run_script "$POWER_SCRIPT" status 2>&1)"; then
        echo "unknown"
        return 0
    fi

    if echo "$out" | grep -qi "Device: ON"; then
        echo "on"
    elif echo "$out" | grep -qi "Device: OFF"; then
        echo "off"
    else
        echo "unknown"
    fi
}

confirm_sd_switch_when_powered() {
    local answer

    if [ ! -t 0 ]; then
        die "DUT appears powered on. Refusing SD switch in non-interactive mode. Turn power off first or use -f."
    fi

    echo "DUT appears to be powered ON."
    echo "Choose one action:"
    echo "  o - power off DUT, then continue"
    echo "  q - quit"
    echo "  f - force SD switch while DUT is on"

    while true; do
        read -r -p "Selection [o/q/f]: " answer
        case "$answer" in
            o|O)
                run_script "$POWER_SCRIPT" off || die "Failed to power off DUT."
                FORCE=0
                return 0
                ;;
            q|Q|"")
                die "Operation cancelled by user."
                ;;
            f|F)
                FORCE=1
                return 0
                ;;
            *)
                echo "Please choose 'o', 'q', or 'f'."
                ;;
        esac
    done
}

handle_sd() {
    local action="$1"
    local mux_mode=""
    local state

    case "$action" in
        attach)
            mux_mode="dut"
            ;;
        detach)
            mux_mode="host"
            ;;
        *)
            usage
            ;;
    esac

    state="$(power_state)"

    if [ "$state" = "on" ] && [ "$FORCE" -eq 0 ]; then
        confirm_sd_switch_when_powered
    fi

    if [ "$state" = "on" ] && [ "$FORCE" -eq 1 ]; then
        echo "Warning: forcing SD switch while DUT is powered on."
    fi

    run_script "$SD_SCRIPT" "$mux_mode"
}

validate_pause() {
    local value="$1"
    echo "$value" | grep -Eq '^[0-9]+([.][0-9]+)?$' || die "Invalid pause_seconds: '$value'"
}

handle_power() {
    local action="$1"
    local pause="${2:-}"

    case "$action" in
        on|off)
            [ -z "$pause" ] || usage
            run_script "$POWER_SCRIPT" "$action"
            ;;
        power-cycle)
            if [ -n "$pause" ]; then
                validate_pause "$pause"
                run_script "$POWER_SCRIPT" power-cycle "$pause"
            else
                run_script "$POWER_SCRIPT" power-cycle
            fi
            ;;
        *)
            usage
            ;;
    esac
}

confirm_power_off_for_flash() {
    local answer

    if [ ! -t 0 ]; then
        die "DUT appears powered on. Refusing flash in non-interactive mode. Power off DUT first."
    fi

    while true; do
        read -r -p "DUT is powered ON. Power it OFF and continue flashing? [y/N]: " answer
        case "$answer" in
            y|Y|yes|YES)
                run_script "$POWER_SCRIPT" off || die "Failed to power off DUT."
                return 0
                ;;
            n|N|no|NO|"")
                die "Operation cancelled by user."
                ;;
            *)
                echo "Please answer y or n."
                ;;
        esac
    done
}

handle_flash() {
    local image="$1"
    local state
    local answer

    [ -e "$image" ] || die "Image file not found: $image"

    state="$(power_state)"
    if [ "$state" = "on" ]; then
        confirm_power_off_for_flash
    elif [ "$state" = "unknown" ]; then
        die "Could not determine DUT power state. Aborting flash for safety."
    fi

    echo "Detaching SD card to host..."
    run_script "$SD_SCRIPT" host

    echo "Waiting ${FLASH_ATTACH_WAIT_SECONDS}s for host block device to settle..."
    sleep "$FLASH_ATTACH_WAIT_SECONDS"

    echo "Flashing image with sdflash..."
    run_script "$FLASH_SCRIPT" -a -i "$image" clone

    if [ ! -t 0 ]; then
        echo "Flash completed. Non-interactive mode: leaving DUT power state unchanged (OFF)."
        return 0
    fi

    while true; do
        read -r -p "Flash completed. Power ON DUT now? [y/N]: " answer
        case "$answer" in
            y|Y|yes|YES)
                run_script "$POWER_SCRIPT" on || die "Failed to power on DUT."
                return 0
                ;;
            n|N|no|NO|"")
                echo "Leaving DUT powered OFF."
                return 0
                ;;
            *)
                echo "Please answer y or n."
                ;;
        esac
    done
}

main() {
    source_local_config

    while getopts "f" opt; do
        case "$opt" in
            f)
                FORCE=1
                ;;
            *)
                usage
                ;;
        esac
    done
    shift $((OPTIND - 1))

    [ $# -ge 2 ] || usage

    local group="$1"
    local action="$2"
    local arg3="${3:-}"

    case "$group" in
        sd)
            [ $# -eq 2 ] || usage
            handle_sd "$action"
            ;;
        power)
            [ $# -le 3 ] || usage
            handle_power "$action" "$arg3"
            ;;
        flash)
            [ $# -eq 2 ] || usage
            handle_flash "$action"
            ;;
        *)
            usage
            ;;
    esac
}

main "$@"
