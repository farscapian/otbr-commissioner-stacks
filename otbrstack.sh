#!/usr/bin/env bash
# Source this file (or let ~/.bashrc source it) to get the otbrstack command.
# Do not execute directly.

_OTBRSTACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

otbrstack() {
    local cmd="${1:-}"

    case "$cmd" in
        vm)
            case "${2:-}" in
                x86|x86_64)
                    echo "[otbrstack] Incus VM (native x86_64)"
                    "$_OTBRSTACK_DIR/provision_incus.sh" "${@:3}"
                    ;;
                arm64|aarch64)
                    echo "[otbrstack] QEMU aarch64 (Raspberry Pi 4 sim)"
                    "$_OTBRSTACK_DIR/provision_piotbrvm.sh" "${@:3}"
                    ;;
                *)
                    echo "Usage: otbrstack vm <x86|arm64> [extra args]"
                    return 1
                    ;;
            esac
            ;;
        flash)
            echo "[otbrstack] Flash Ubuntu Core 24 to SD card"
            "$_OTBRSTACK_DIR/flash-otbr-core.sh" "${@:2}"
            ;;
        docker)
            echo "[otbrstack] Docker bare-metal provisioner"
            "$_OTBRSTACK_DIR/otbr-docker-setup.sh" "${@:2}"
            ;;
        snap)
            echo "[otbrstack] Snap bare-metal provisioner"
            "$_OTBRSTACK_DIR/otbr-snap-setup.sh" "${@:2}"
            ;;
        *)
            echo "Usage: otbrstack <command> [args]"
            echo ""
            echo "  vm x86    Incus VM test (native x86_64)"
            echo "  vm arm64  QEMU aarch64 test (Raspberry Pi 4 sim)"
            echo "  flash     Flash Ubuntu Core 24 to SD card (needs /dev/sdX)"
            echo "  docker    Docker bare-metal provisioner"
            echo "  snap      Snap bare-metal provisioner"
            [[ -n "$cmd" ]] && return 1 || return 0
            ;;
    esac
}
