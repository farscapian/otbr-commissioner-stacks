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
                    echo "[otbrstack] Incus VM (native x86_64)  (scripts: ${_OTBRSTACK_DIR})"
                    "$_OTBRSTACK_DIR/provision_incus.sh" "${@:3}"
                    ;;
                arm64|aarch64)
                    echo "[otbrstack] QEMU aarch64 (Raspberry Pi 4 sim)  (scripts: ${_OTBRSTACK_DIR})"
                    "$_OTBRSTACK_DIR/provision_piotbrvm.sh" "${@:3}"
                    ;;
                *)
                    echo "Usage: otbrstack vm <x86|arm64> [extra args]"
                    return 1
                    ;;
            esac
            ;;
        flash)
            echo "[otbrstack] Flash Ubuntu Server 24.04 to SD card  (scripts: ${_OTBRSTACK_DIR})"
            "$_OTBRSTACK_DIR/flash-piotbr.sh" "${@:2}"
            ;;
        docker)
            echo "[otbrstack] Docker bare-metal provisioner"
            "$_OTBRSTACK_DIR/otbr-docker-setup.sh" "${@:2}"
            ;;
        snap)
            echo "[otbrstack] Snap bare-metal provisioner"
            "$_OTBRSTACK_DIR/otbr-snap-setup.sh" "${@:2}"
            ;;
        logs)
            local _follow=0 _host=""
            for _arg in "${@:2}"; do
                case "$_arg" in
                    -f) _follow=1 ;;
                    *)  _host="$_arg" ;;
                esac
            done
            if [[ -z "$_host" ]]; then
                echo "Usage: otbrstack logs [-f] <ssh_host>"
                return 1
            fi
            echo "[otbrstack] Logs from ${_host}"
            if [[ "$_follow" -eq 1 ]]; then
                ssh -t "$_host" '
                    _cleanup() { kill $(jobs -p) 2>/dev/null; }
                    trap _cleanup EXIT INT TERM
                    sudo tail -f \
                        /var/log/cloud-init-output.log \
                        /var/log/otbr-firstboot.log &
                    sudo snap logs -f openthread-border-router 2>/dev/null &
                    wait
                '
            else
                ssh "$_host" '
                    sudo tail -n 40 \
                        /var/log/cloud-init-output.log \
                        /var/log/otbr-firstboot.log
                    echo
                    sudo snap logs openthread-border-router 2>/dev/null || true
                '
            fi
            ;;
        *)
            echo "Usage: otbrstack <command> [args]"
            echo ""
            echo "  vm x86        Incus VM test (native x86_64)"
            echo "  vm arm64      QEMU aarch64 test (Raspberry Pi 4 sim)"
            echo "  flash         Flash Ubuntu Server 24.04 to SD card (needs /dev/sdX)"
            echo "  docker        Docker bare-metal provisioner"
            echo "  snap          Snap bare-metal provisioner"
            echo "  logs [-f] <host>  Tail cloud-init + firstboot + OTBR snap logs over SSH"
            [[ -n "$cmd" ]] && return 1 || return 0
            ;;
    esac
}
