#!/usr/bin/env bash
# SPDX-License-Identifier: (GPL-2.0+ OR MIT)
# Copyright 2023 Variscite Ltd.
 
# globals
readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
 
# SOM machines
readonly MACHINES=(\
        "imx8mm-var-dart"\
        "imx8mn-var-som"\
        "imx8mp-var-dart"\
        "imx8qm-var-som"\
        "imx8qxp-var-som"\
        "imx93-var-som"\
        )
 
# some commands do need to have MACHINE specified. So,
# let's default it to keep the order of the arguments
# of function calls.
if [ -z "${MACHINE}" ]; then
    MACHINE="n/a"
fi
 
readonly UBOOT_KEYVALMAP_ATTR_IDX_BS="1"
readonly UBOOT_KEYVALMAP_ATTR_IDX_SEEK="2"
 
# U-Boot image write offset
# tuple<MACHINE,BLOCKSIZE,SEEK/OFFSET>
readonly UBOOT_KEYVALMAP_ATTR=(\
        "imx8mm-var-dart:1K:33"\
        "imx8mn-var-som:1K:32"\
        "imx8mp-var-dart:1K:32"\
        "imx8qm-var-som:1K:33"\
        "imx8qxp-var-som:1K:33"\
        "imx93-var-som:1K:32"\
        )
 
# Image types
readonly IMAGE_TYPES=(\
        "uboot"\
        "kernel"\
        "env" \
        )
 
# exit with error
# $1 - error message
exit_erronous() {
    if [ -n "$1" ]; then
        echo "$1"
    fi
    echo
    echo "Exiting here..."
    exit 1
}
 
# exit with success
exit_succes() {
    echo
    echo "Done."
    exit 0
}
 
exit_success_silent() {
    exit 0
}
 
# help epilog
help() {
    echo "Variscite flash util (c) 2023"
    echo
    echo "Helper to flash storage devices for Variscite SOMs."
    echo
    echo "Basically the device should be a removable block device, such as a phyisical SD card, or"
    echo "SOM internal storage attached using the USB gadget. But a loop device can be used to 'flash' an image"
    echo "as well."
    echo
    echo " Usage: ${SCRIPT_NAME} [-d <device>] [-i <image>] <command>"
    echo
    echo " Options:"
    echo " -h|--help        Display this help message"
    echo " -a|--auto        Auto-select a suitable removable block device"
    echo " -d|--device      Select a removable block device (e.g. /dev/sda)."
    echo "                  If no device was specified, it will try to auto select one, prompting for validation or a choice selection"
    echo " -i|--image       Image to clone to the block device, can be a zipped one or just raw."
    echo " -e|--skiperase   Do not erase the device before taking action"
    echo
    echo " Commands:"
    echo " list             list all block devices attached"
    echo " check            Validate the block device (removable sd card device)"
    echo " erase            Erase the block device (includes a 100 MiB zero'ing)"
    echo " format           Format the block device (needs format option)"
    echo " clone            Clone the given image"
    echo
}
 
# locals
PARAM_CMD="n/a"
PARAM_FILE="n/a"
PARAM_DEVICE="n/a"
PARAM_SKIP_CHECK="n"
PARAM_SKIP_ERASE="n"
 
# parse input arguments
#readonly SHORTOPTS="c:o:d:h"
#readonly LONGOPTS="cmd:,output:,dev:,help,debug"
 
#ARGS=$(getopt -s bash --options ${SHORTOPTS}  \
#  --longoptions ${LONGOPTS} --name ${SCRIPT_NAME} -- "$@" )
 
#eval set -- "$ARGS"
 
# parse arguments
# $1 -- all arguments
#  ? -- n/a
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                help
                exit_success_silent
                ;;
            -e|--skiperase)
                PARAM_SKIP_ERASE='y'
                ;;
            -a|--auto)
                PARAM_DEVICE="auto"
                ;;
            -d|--device)
                shift
                [ "${PARAM_DEVICE}" == "n/a" ] || {
                    exit_erronous "E: Auto select has been choosen."
                }
                [ -e "$1" ] || {
                    exit_erronous "E: Device '$1' does not exists."
                }
                PARAM_DEVICE="$1"
                ;;
            -i|--image)
                shift
                [ "${PARAM_FILE}" == "n/a" ] || {
                    exit_erronous "E: Image file already set."
                }
                [ -e "$1" ] || {
                    exit_erronous "E: File '$1' does not exists."
                }
                PARAM_FILE="$1"
                ;;
            check|erase|format|mount|umount|clone|list)
                PARAM_CMD="$1"
                ;;
            *) # unknown option
                exit_erronous "Unknown option: '$1'"
                ;;
        esac
        shift
    done
}
 
# parse arguments
parse_args "$@"

require_cmd() {
    local cmd="$1"
    command -v "$cmd" >/dev/null 2>&1 || {
        exit_erronous "E: Missing required command: '$cmd'"
    }
}

check_requirements() {
    # Core tools used by all command paths.
    require_cmd lsblk

    # Clone/check image paths rely on these tools.
    if [ "${PARAM_CMD}" = "clone" ] || [ "${PARAM_FILE}" != "n/a" ]; then
        require_cmd file
        require_cmd realpath
    fi

    # Write/erase/format paths rely on these tools.
    if [ "${PARAM_CMD}" = "clone" ] || [ "${PARAM_CMD}" = "erase" ] || [ "${PARAM_CMD}" = "format" ]; then
        require_cmd sudo
        require_cmd dd
        require_cmd partprobe
        require_cmd pv
    fi

    # Optional but recommended for non-removable media checks in check_device().
    if ! command -v udisksctl >/dev/null 2>&1 || ! command -v gdbus >/dev/null 2>&1; then
        echo "W: Optional tools missing for advanced removable-media checks: udisksctl and/or gdbus"
        echo "W: Install with: apt update && apt install -y udisks2 libglib2.0-bin"
    fi
}
 
# get value from keymap
# $1 -- key
# $2 -- idx n (beginning from 0)
# $3 -- map array
keymap_valn() {
    local key="$1"; shift
    local idx="$1"; shift
    local map=("$@")
    local val=""
    for pair in "${map[@]}"; do
        local tmpkey="${pair%%:*}"
        if [ "${tmpkey}" == "${key}" ]; then
            local tmpvalues="${pair#${tmpkey}:}"
            while [ "${idx}" -gt 0 ]; do
                tmpvalues="${tmpvalues#${val}:}"
                val="${tmpvalues%%:*}"
                idx=$(( ${idx} - 1 ))
            done
            break
        fi
    done
    echo ${val}
}
 
# get bootloader blocksize value
# $1 -- machine
#  ? -- n/a
get_bootloader_bs() {
    local machine="$1"
    keymap_valn "${machine}" \
        "${UBOOT_KEYVALMAP_ATTR_IDX_SEEK}" \
        "${UBOOT_KEYVALMAP_ATTR[@]}"
}
 
# get bootloader seek value
# $1 -- machine
#  ? -- n/a
get_bootloader_seek() {
    local machine="$1"
    keymap_valn "${machine}" \
        "${UBOOT_KEYVALMAP_ATTR_IDX_BS}"\
        "${UBOOT_KEYVALMAP_ATTR[@]}"
}
 
# evaluate image
# $1 -- file path
#  ? --
image_type() {
    local file="$1"
 
    # eval file type, and pre-process is necessary
    local ftype=`file -b ${image}`
    case "${ftype}" in
        data) # nothing to do
        ;;
        gz) # gzip file, uncompress
                        # TODO:
                        # - Unzip to tmp folder
                        # - Set image path to the tmp file
                        # - Install handler to delete tmp file on exit
        ;;
        *) # unsupported
            ERRMSG="E: File type '${ftype}' not supported (file: ${file})."
            return 1
        ;;
    esac
}
 
# list block devices
list_devices() {
    # TODO:
    # grab for sd*, and mmc*
    # check if they are removeable devices
    # For now, just do a lsblk
    # list some details about the block devices
    lsblk | grep -e "sd" -e "mmc"
}
 
# check device
# $1 -- device node (e.g., /dev/sdX)
# Error message: ERRMSG
check_device() {
    local dev="$1"
    local node
    node="$(basename "$1")"
    ERRMSG=""
 
    echo "I: Checking device ${dev}"
    # check that parameter is a valid block device
    if [ ! -b "$1" ]; then
        ERRMSG="E: '$1' is not a valid block device"
        return 1
    fi
 
    local removable=$(cat /sys/block/${node}/removable)
    local size=$((512*$(cat /sys/class/block/${node}/size)))
    
    # check that /sys/block/$dev exists
    if [ ! -d "/sys/block/${node}" ]; then
        ERRMSG="E: Directory /sys/block/${dev} missing"
        return 1
    fi
 
    # non-removable SD card readers require additional check
    if [ "${removable}" != "1" ]; then
        local drive
        drive="$(udisksctl info -b "${dev}" | grep "Drive:" | cut -d"'" -f 2)"
        local mediaremovable=$(gdbus call --system --dest org.freedesktop.UDisks2 \
            --object-path ${drive} --method org.freedesktop.DBus.Properties.Get \
            org.freedesktop.UDisks2.Drive MediaRemovable)
        if [[ "${mediaremovable}" = *"true"* ]]; then
            removable=1
        fi
    fi
 
    # check that device is either removable or loop
    if [ "${removable}" != "1" -a "$(stat -c '%t' "${dev}")" != 7 ]; then
        ERRMSG="E: $1 is not a removable device"
        return 1
    fi
        
        # check that device is attached
        if [ "${size}" -eq 0 ]; then
            ERRMSG="E: $1 is not attached"
            return 1
    fi
 
    return 0
}
 
# check image
# $1 -- device node (e.g., /dev/sdX)
# Error message: ERRMSG
check_image() {
    local file="$1"
 
    # eval exists
    if [ ! -e "${file}" ]; then
        ERRMSG="E: File '${image}' does not exists."
        return 1
    fi
 
    echo "I: Checking file type"
    local ftype
    ftype="$(file -b "$(realpath "${file}")" | head -n1 | cut -d " " -f1)"
    case "${ftype}" in
        gzip|Zstandard) # gzip or zst file, uncompress image file
            : # nothing to do for now (TODO: zstdcat/zcat and check for strings, machine etc.)
        ;;
        DOS/MBR) # uncompressed mmc image (TODO: nand image)
            : # nothing to do (TODO: check for strings, machine etc.)
        ;;
        data) # uncompressed zImage or bootloader (TODO: only bootloader supported for now!)
            echo "I: File type found: '${ftype}'"
            echo "I: Image file, trying to find a firmware signature"
            signature=$(strings "${file}" | grep -e "U-Boot" | head -n1)
            ret="$?"
            if [[ ${ret} -gt 0 || -z ${signature} ]]; then
                ERRMSG="E: Image type not supported, no U-Boot firmware."
                return 1
            fi
            echo "I: Firmware Signature found: '${signature}'"
            for machine in "${MACHINES[@]}"; do
                tmp=$(strings "${file}" | grep -i "${machine}")
                if [ -n "${tmp}" ]; then
                    echo "I: Machine found: '${machine}'"
                    MACHINE=${machine}
                    break
                fi
            done
            ret="$?"
            if [ -z "${MACHINE}" ]; then
                ERRMSG="E: Could not find SOM machine type."
                return 1
            fi
 
            return 0
        ;;
        *) # unsupported
            ERRMSG="E: File type '${ftype}' not supported (file: ${file})."
            return 1
        ;;
    esac
}
 
# erase device
# $1 device node (e.g., /dev/sdX)
cmd_erase() {
    local dev="$1"
    local parts
    parts="$(lsblk -o NAME -ln "${dev}" | tail -n +2)"
 
    if [ "${PARAM_SKIP_ERASE}" == 'y' ]; then
        return 0
    fi
    
    if [ -n "${parts}" ]; then
        # TODO: create fdisk script dynamically to avoid erros, and check for erros
        for part in ${parts}; do
            echo "I: Delete partition ${part}"
            ((echo d; echo "$(echo "${part}" | tr -dc '0-9')"; echo w) | sudo fdisk "${dev}")
        done
        sync
    fi
    echo "I: Zero first 100 MiBs"
    sudo dd if=/dev/zero of="${dev}" bs=1M count=100 status=progress # conv=fsync
    sync | pv -t
}
 
# format device
# $1 -- block device
# $2 -- layout type
cmd_format() {
    local dev="$1"
    if [ "$(echo "${dev}" | grep -c mmcblk)" -ne 0 ] \
        || [[ ${dev} == *"loop"* ]]; then
        part="p"
    fi
    mkfs.ext4 "${dev}${part}1" -L rootfs
}

# Try to read zstd decompressed size in bytes for pv ETA.
zstd_uncompressed_size_bytes() {
    local file="$1"
    local size

    # Read only the "Decompressed Size" line to avoid matching other fields
    # like "Window Size" that also contain "(... B)".
    size="$(LC_ALL=C zstd -lv "${file}" 2>/dev/null | sed -n 's/^Decompressed Size:.*(\([0-9][0-9,]*\) B).*/\1/p' | head -n1 | tr -d ',')"
    if echo "${size}" | grep -Eq '^[0-9]+$'; then
        echo "${size}"
        return 0
    fi

    # Fallback for zstd output variants without parenthesized byte value.
    size="$(LC_ALL=C zstd -lv "${file}" 2>/dev/null | sed -n 's/^Decompressed Size:[[:space:]]*\([0-9][0-9,]*\).*/\1/p' | head -n1 | tr -d ',')"
    if echo "${size}" | grep -Eq '^[0-9]+$'; then
        echo "${size}"
        return 0
    fi

    return 1
}
 
# Clone the given image to the target device
# $1 -- machine
# $2 -- block device
# $3 -- image file
cmd_clone() {
    local machine="$1"
    local dev="$2"
    local file="$(realpath "$3")"
    local flags2="oflag=sync" # status=progress
    local flags="oflag=sync status=progress" 
 
    echo "I: Cloning image '$(basename ${file})'"
    local ftype
    ftype="$(file -b "${file}" | head -n1 | cut -d " " -f1)" # consulidate to an own function
    case "${ftype}" in
        gzip) # gzip file, uncompress image file
            zcat "${file}" | sudo dd of="${dev}" bs=1M ${flags} && \
            sync | pv -t
        ;;
        Zstandard) # gzip file, uncompress image file
            local size_bytes=""
            zstd --test "${file}" # TODO: fail here if integrity check is false!

            if size_bytes="$(zstd_uncompressed_size_bytes "${file}")"; then
                zstdcat "${file}" | pv -s "${size_bytes}" | sudo dd of="${dev}" bs=1M ${flags2} && \
                sync
            else
                echo "W: Could not determine decompressed zstd size; running progress without ETA."
                zstdcat "${file}" | pv | sudo dd of="${dev}" bs=1M ${flags2} && \
                sync
            fi
        ;;
        DOS/MBR) # uncompressed mmc image (TODO: nand image)
            sudo dd if="${file}" of="${dev}" bs=1M ${flags} && \
            sync | pv -t
        ;;
        data) # data is mapped to the bootloader for now
            sudo dd if="${file}" of="${dev}" bs="$(get_bootloader_bs "${machine}")" seek="$(get_bootloader_seek "${machine}")" ${flags} && \
            sync | pv -t
        ;;
        *) # unsupported
            exit_erronous "E: File type '${ftype}' not supported (file: ${file})."
        ;;
    esac
        
    return 0
}
 
# Mount the storage device
# $1 -- block device
# $2 -- mount point
cmd_mount() {
    return 0
}
 
# erase device
# $1 -- device node (e.g., /dev/sdX)
cmd_unmount() {
    local dev="$1"
    local dir
    local parts
    dir="$(dirname "$1")"
    parts="$(lsblk -o NAME -ln "${dev}" | tail -n +2)"
 
    echo "I: Unmount partitions"
    sudo partprobe
    for part in ${parts}; do
        sudo umount "${dir}/${part}" &>/dev/null || true
    done
}
 
# list all available block devices
cmd_list() {
    list_devices
}
 
if [ "${PARAM_CMD}" == "n/a" ]; then
    help
    exit_erronous "E: Command argument missing"
fi

check_requirements
 
# handle the 'list' command here and exit
if [ "${PARAM_CMD}" == "list" ]; then
    cmd_list
    exit_success_silent
fi
 
if [ "${PARAM_DEVICE}" == "n/a" ]; then
    #help
    #exit_erronous "E: Please specifiy the device or use auto selection"
    PARAM_DEVICE="auto"
fi
 
# super-user gard
if [[ $EUID -ne 0 && "${PARAM_CMD}" != "list" && "${PARAM_CMD}" != "check" ]] ; then
    exit_erronous "E: This script must be run with super-user privileges"
    exit 1
fi
 
# device auto select
if [ "${PARAM_DEVICE}" == "auto" ]; then
    echo "I: Auto device selection enabled."
    PARAM_SKIP_CHECK="y"
    # aggregate available devices
    devlist=""
    listtmp=$(lsblk --noheadings --raw --nodeps -oNAME | grep -e "sd" -e "mmc")
    if [ -z "${listtmp}" ]; then
        exit_erronous "E: No devices available."
    fi
    for dev in $(echo ${listtmp}); do
        check_device "/dev/${dev}"
        if [ "$?" -eq 0 ]; then
            devlist="${devlist} /dev/${dev}"
        else
            echo "I: Device '/dev/${dev}' not usable - DROP"
        fi
    done
    # choose device
    devlist=(${devlist})
    if [ "${#devlist[@]}" -gt 1 ]; then
        echo
        echo "I: List of available devices:"
        devid=1
        for dev in ${devlist[*]}; do
            echo "${devid}  $(lsblk --nodeps --noheadings ${dev})"
            devid=$((devid+1))
        done
        read -p "Please choose one:" sel
        sel=$((sel-1))
        # ToDo: validate selection!
        PARAM_DEVICE=${devlist[${sel}]}
    else
        PARAM_DEVICE=${devlist}
    fi
 
    if [ -z "${PARAM_DEVICE}" ]; then
        exit_erronous "E: Could not determine any device."
    else
        echo "I: Device check '${PARAM_DEVICE}' - OK"
    fi
fi
 
echo "I: Command: '${PARAM_CMD}'"
echo "I: Device: '${PARAM_DEVICE}'"
if [ ! "${PARAM_FILE}" == "n/a" ]; then
    echo "I: File/Image: $(realpath --relative-to="$(pwd)" "${PARAM_FILE}")"
fi
echo
read -p "Press Enter to continue or use ^C to exit here..."
 
# check device
if [ "${PARAM_SKIP_CHECK}" == "n" ]; then
    check_device "${PARAM_DEVICE}"
    if [ "$?" -gt 0 ]; then
        exit_erronous "${ERRMSG}"
    else
        echo "I: Device check '${PARAM_DEVICE}' - OK"
    fi
fi
 
# check image
if [ ! "${PARAM_FILE}" == "n/a" ]; then
    check_image "${PARAM_FILE}"
 
    if [ "$?" -gt 0 ]; then
        exit_erronous "${ERRMSG}"
    else
        echo "I: Image check '$(basename ${PARAM_FILE})' - OK"
    fi
fi
 
case ${PARAM_CMD} in
    check)
        : # A check is always done, so nothing to do here.
    ;;
    erase)
        cmd_unmount ${PARAM_DEVICE} &&
        cmd_erase ${PARAM_DEVICE}
    ;;
    format)
        cmd_unmount ${PARAM_DEVICE} &&
        cmd_erase ${PARAM_DEVICE} &&
        cmd_format ${PARAM_DEVICE}
    ;;
    clone)
        # TODO seperate clone and write, only on clone we will erase (mount back?)
        cmd_unmount ${PARAM_DEVICE} &&
        cmd_clone ${MACHINE} ${PARAM_DEVICE} ${PARAM_FILE}
        # cmd_erase ${PARAM_DEVICE} &&
    ;;
    * )
        exit_erronous "E: Invalid command: \"${PARAM_CMD}\"";
    ;;
esac
 
exit_succes