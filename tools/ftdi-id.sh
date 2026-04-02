#!/usr/bin/env bash

set -u

SCRIPT_NAME="$(basename "$0")"

die() {
    echo "Error: $*" >&2
    exit 1
}

usage() {
    cat <<EOF
Usage:
  $SCRIPT_NAME list
  $SCRIPT_NAME read  (--tty /dev/ttyUSBX | --busdev BUS:DEV)
  $SCRIPT_NAME write (--tty /dev/ttyUSBX | --busdev BUS:DEV) --serial SERIAL [--manufacturer NAME] [--product NAME] [--chip CHIP]

Examples:
  $SCRIPT_NAME list
  $SCRIPT_NAME read --tty /dev/ttyUSB0
  $SCRIPT_NAME read --busdev 001:007
  $SCRIPT_NAME write --tty /dev/ttyUSB0 --serial DUT_UART_A

Notes:
  - 'write' requires the 'ftdi_eeprom' tool and root privileges.
  - --chip is optional and stored for compatibility/future use.
EOF
    exit 1
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

normalize_busdev() {
    local in="$1"
    local bus dev
    IFS=':' read -r bus dev <<< "$in"
    [ -n "${bus:-}" ] && [ -n "${dev:-}" ] || die "Invalid BUS:DEV format: $in"
    printf "%03d:%03d\n" "$bus" "$dev"
}

usb_fields_from_busdev() {
    local busdev="$1"
    local bus dev line

    line="$(lsusb -s "$busdev" 2>/dev/null || true)"
    [ -n "$line" ] || die "No USB device found at $busdev"

    bus="$(echo "$line" | awk '{print $2}')"
    dev="$(echo "$line" | awk '{print $4}' | tr -d ':')"
    echo "$bus" "$dev"
}

sys_usb_dir_from_tty() {
    local tty="$1"
    local path

    [ -e "$tty" ] || die "TTY device not found: $tty"
    path="$(readlink -f "/sys/class/tty/$(basename "$tty")/device")"
    [ -n "$path" ] || die "Could not resolve sysfs path for $tty"

    while [ "$path" != "/" ]; do
        if [ -f "$path/busnum" ] && [ -f "$path/devnum" ]; then
            echo "$path"
            return 0
        fi
        path="$(dirname "$path")"
    done

    die "Could not find USB device directory for $tty"
}

busdev_from_tty() {
    local tty="$1"
    local usbdir bus dev

    usbdir="$(sys_usb_dir_from_tty "$tty")"
    bus="$(cat "$usbdir/busnum")"
    dev="$(cat "$usbdir/devnum")"
    printf "%03d:%03d\n" "$bus" "$dev"
}

read_identifiers() {
    local busdev="$1"
    local line

    line="$(lsusb -s "$busdev" 2>/dev/null || true)"
    [ -n "$line" ] || die "No USB device found at $busdev"

    echo "Device: $line"
    lsusb -s "$busdev" -v 2>/dev/null | awk '
        /idVendor/ || /idProduct/ || /iManufacturer/ || /iProduct/ || /iSerial/ {
            print
        }
    '
}

list_ftdi() {
    local tty ttybase busdev line

    need_cmd lsusb

    echo "Detected FTDI tty devices:"
    for tty in /dev/ttyUSB*; do
        [ -e "$tty" ] || continue
        ttybase="$(basename "$tty")"
        if ! udevadm info -q property -n "$tty" 2>/dev/null | grep -q '^ID_VENDOR_ID=0403$'; then
            continue
        fi

        busdev="$(busdev_from_tty "$tty")"
        line="$(lsusb -s "$busdev" 2>/dev/null || true)"

        echo "- $tty"
        echo "  busdev: $busdev"
        [ -n "$line" ] && echo "  usb:    $line"

        udevadm info -q property -n "$tty" 2>/dev/null | awk -F= '
            /^ID_MODEL=/ {print "  model:  " $2}
            /^ID_SERIAL_SHORT=/ {print "  serial: " $2}
        '
    done
}

write_identifiers() {
    local busdev="$1"
    local serial="$2"
    local manufacturer="$3"
    local product="$4"
    local chip="$5"
    local cfg tmpdir bus dev vid pid

    need_cmd ftdi_eeprom
    [ "${EUID}" -eq 0 ] || die "write requires root privileges"

    read -r bus dev <<< "$(usb_fields_from_busdev "$busdev")"

    vid="$(lsusb -s "$busdev" | awk '{print $6}' | cut -d: -f1)"
    pid="$(lsusb -s "$busdev" | awk '{print $6}' | cut -d: -f2)"

    tmpdir="$(mktemp -d)"
    cfg="$tmpdir/ftdi.conf"

    {
        echo "vendor_id=0x$vid"
        echo "product_id=0x$pid"
        echo "bus=$((10#$bus))"
        echo "device=$((10#$dev))"
        [ -n "$manufacturer" ] && echo "manufacturer=\"$manufacturer\""
        [ -n "$product" ] && echo "product=\"$product\""
        echo "serial=\"$serial\""
        echo "use_serial=true"
        [ -n "$chip" ] && echo "# chip=$chip"
    } > "$cfg"

    echo "Writing FTDI EEPROM on $busdev ..."
    ftdi_eeprom --flash-eeprom "$cfg"

    rm -rf "$tmpdir"
    echo "Write completed."
}

main() {
    local cmd busdev="" tty="" serial="" manufacturer="" product="" chip=""

    need_cmd lsusb
    need_cmd udevadm

    [ $# -ge 1 ] || usage
    cmd="$1"
    shift

    case "$cmd" in
        list)
            [ $# -eq 0 ] || usage
            list_ftdi
            ;;
        read|write)
            while [ $# -gt 0 ]; do
                case "$1" in
                    --tty)
                        shift
                        [ $# -gt 0 ] || die "--tty requires a value"
                        tty="$1"
                        ;;
                    --busdev)
                        shift
                        [ $# -gt 0 ] || die "--busdev requires a value"
                        busdev="$(normalize_busdev "$1")"
                        ;;
                    --serial)
                        shift
                        [ $# -gt 0 ] || die "--serial requires a value"
                        serial="$1"
                        ;;
                    --manufacturer)
                        shift
                        [ $# -gt 0 ] || die "--manufacturer requires a value"
                        manufacturer="$1"
                        ;;
                    --product)
                        shift
                        [ $# -gt 0 ] || die "--product requires a value"
                        product="$1"
                        ;;
                    --chip)
                        shift
                        [ $# -gt 0 ] || die "--chip requires a value"
                        chip="$1"
                        ;;
                    *)
                        usage
                        ;;
                esac
                shift
            done

            if [ -n "$tty" ] && [ -n "$busdev" ]; then
                die "Use either --tty or --busdev, not both"
            fi
            if [ -z "$tty" ] && [ -z "$busdev" ]; then
                die "Provide --tty or --busdev"
            fi
            [ -n "$busdev" ] || busdev="$(busdev_from_tty "$tty")"

            if [ "$cmd" = "read" ]; then
                read_identifiers "$busdev"
            else
                [ -n "$serial" ] || die "write requires --serial"
                write_identifiers "$busdev" "$serial" "$manufacturer" "$product" "$chip"
            fi
            ;;
        *)
            usage
            ;;
    esac
}

main "$@"
