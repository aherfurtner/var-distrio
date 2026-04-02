#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REQ_FILE="${SCRIPT_DIR}/apt-requirements.txt"

if [[ "${EUID}" -ne 0 ]]; then
    echo "Error: Please run as root (or with sudo)." >&2
    exit 1
fi

if [[ ! -f "${REQ_FILE}" ]]; then
    echo "Error: Requirements file not found: ${REQ_FILE}" >&2
    exit 1
fi

packages=()
while IFS= read -r line; do
    line="${line%%#*}"
    line="$(echo "${line}" | xargs)"
    [[ -z "${line}" ]] && continue
    packages+=("${line}")
done < "${REQ_FILE}"

if [[ "${#packages[@]}" -eq 0 ]]; then
    echo "No packages listed in ${REQ_FILE}."
    exit 0
fi

echo "Installing apt packages from ${REQ_FILE}:"
printf '  - %s\n' "${packages[@]}"

apt update
DEBIAN_FRONTEND=noninteractive apt install -y "${packages[@]}"

echo
echo "Dependency installation complete."
