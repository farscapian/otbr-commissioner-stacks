#!/usr/bin/env bash
# Source this file (or let ~/.bashrc source it) to get the otbrstack command.
# Do not execute directly.

_OTBRSTACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

otbrstack() {
    local cmd="${1:-}"

    # Collect args after the subcommand, extracting --env-file= if present.
    # Child scripts no longer handle env loading — otbrstack does it here.
    local _env_file=""
    local _pass_args=()
    local _arg
    for _arg in "${@:2}"; do
        case "$_arg" in
            --env-file=*) _env_file="${_arg#--env-file=}" ;;
            *) _pass_args+=("$_arg") ;;
        esac
    done

    # Resolve and export env for all commands that need it (everything except logs/help).
    if [[ -n "$cmd" && "$cmd" != "logs" ]]; then
        if [[ -n "$_env_file" ]]; then
            if [[ ! -f "$_env_file" ]]; then
                echo "[otbrstack] env file not found: $_env_file" >&2; return 1
            fi
        else
            local _hostname_env="${_OTBRSTACK_DIR}/$(hostname).env"
            if [[ -f "$_hostname_env" ]]; then
                _env_file="$_hostname_env"
            elif [[ -f "${_OTBRSTACK_DIR}/.env" ]]; then
                _env_file="${_OTBRSTACK_DIR}/.env"
            else
                echo "[otbrstack] No $(hostname).env or .env found in ${_OTBRSTACK_DIR}; create one or use --env-file=PATH" >&2
                return 1
            fi
        fi
        echo "[otbrstack] Loading env from ${_env_file}"
        set -o allexport
        # shellcheck source=/dev/null
        source "$_env_file"
        set +o allexport
    fi

    case "$cmd" in
        vm)
            local _arch="${_pass_args[0]:-}"
            local _vm_args=("${_pass_args[@]:1}")
            case "$_arch" in
                x64|x86_64)
                    echo "[otbrstack] Incus VM (native x86_64)  (scripts: ${_OTBRSTACK_DIR})"
                    "$_OTBRSTACK_DIR/provision_incus.sh" "${_vm_args[@]+"${_vm_args[@]}"}"
                    ;;
                arm64|aarch64)
                    echo "[otbrstack] Incus VM (arm64)  (scripts: ${_OTBRSTACK_DIR})"
                    "$_OTBRSTACK_DIR/provision_incus.sh" --arch=arm64 "${_vm_args[@]+"${_vm_args[@]}"}"
                    ;;
                *)
                    echo "Usage: otbrstack vm <x64|arm64> [extra args]"
                    return 1
                    ;;
            esac
            ;;
        flash)
            echo "[otbrstack] Flash Ubuntu Server 26.04 to SD card  (scripts: ${_OTBRSTACK_DIR})"
            "$_OTBRSTACK_DIR/flash-piotbr.sh" "${_pass_args[@]+"${_pass_args[@]}"}"
            ;;
        docker)
            echo "[otbrstack] Docker bare-metal provisioner"
            "$_OTBRSTACK_DIR/otbr-docker-setup.sh" "${_pass_args[@]+"${_pass_args[@]}"}"
            ;;
        snap)
            echo "[otbrstack] Snap bare-metal provisioner"
            "$_OTBRSTACK_DIR/otbr-snap-setup.sh" "${_pass_args[@]+"${_pass_args[@]}"}"
            ;;
        logs)
            local _follow=0 _host=""
            for _arg in "${_pass_args[@]+"${_pass_args[@]}"}"; do
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
            echo "Usage: otbrstack [--env-file=PATH] <command> [args]"
            echo ""
            echo "  vm x64        Incus VM test (native x86_64)"
            echo "  vm arm64      Incus VM (arm64)"
            echo "  flash         Flash Ubuntu Server 26.04 to SD card (needs /dev/sdX)"
            echo "  docker        Docker bare-metal provisioner"
            echo "  snap          Snap bare-metal provisioner"
            echo "  logs [-f] <host>  Tail cloud-init + firstboot + OTBR snap logs over SSH"
            [[ -n "$cmd" ]] && return 1 || return 0
            ;;
    esac
}
