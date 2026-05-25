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
    if [[ -n "$cmd" && "$cmd" != "logs" && "$cmd" != "shutdown" && "$cmd" != "restart" ]]; then
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
        # Unset every variable declared in .env.example before sourcing the
        # actual env file.  This ensures commented-out or removed entries don't
        # silently inherit stale values from the current shell session.
        while IFS= read -r _eline; do
            [[ "$_eline" =~ ^[[:space:]]*(#|$) ]] && continue
            _evar="${_eline%%=*}"; _evar="${_evar%%[[:space:]]*}"
            [[ -n "$_evar" ]] && unset "$_evar"
        done < "${_OTBRSTACK_DIR}/.env.example"
        echo "[otbrstack] Loading env from ${_env_file}"
        set -o allexport
        # shellcheck source=/dev/null
        source "$_env_file"
        set +o allexport
        # Forward HTTP_PROXY to the lowercase vars used by git and curl.
        # git intentionally ignores uppercase HTTP_PROXY; https_proxy covers
        # GitHub and other TLS endpoints routed through the Squid CONNECT tunnel.
        if [[ -n "${HTTP_PROXY:-}" ]]; then
            export http_proxy="$HTTP_PROXY" https_proxy="$HTTP_PROXY"
            local _proxy_hostport="${HTTP_PROXY#*://}"   # strip scheme
            _proxy_hostport="${_proxy_hostport%/}"        # strip trailing slash
            if command -v wait-for-it &>/dev/null; then
                if ! wait-for-it --timeout=5 "$_proxy_hostport" -- true 2>/dev/null; then
                    echo "[otbrstack] WARNING: HTTP proxy ${_proxy_hostport} is not reachable; network operations may fail" >&2
                fi
            fi
        fi
    fi

    case "$cmd" in
        vm)
            if ! command -v incus &>/dev/null; then
                echo "[otbrstack] incus not found — running setup.sh to install and initialize it ..."
                bash "$_OTBRSTACK_DIR/setup.sh"
                if ! command -v incus &>/dev/null; then
                    echo "[otbrstack] ERROR: incus still not available after setup. Aborting." >&2
                    return 1
                fi
            fi

            # Detect if incus-admin group membership exists in /etc/group but is
            # not yet active in this session (happens right after usermod -aG).
            local _use_sg=0
            if ! incus info &>/dev/null 2>&1; then
                if getent group incus-admin 2>/dev/null | grep -qw "$USER"; then
                    echo "[otbrstack] NOTE: ${USER} is in the incus-admin group but it is not active" \
                         "in this shell session (group was added this run or before a re-login)." >&2
                    echo "[otbrstack] Using 'sg incus-admin' to activate the group for this command." \
                         "Open a new terminal after this to avoid the message in future runs." >&2
                    _use_sg=1
                else
                    echo "[otbrstack] ERROR: cannot reach incus daemon and ${USER} is not in incus-admin." \
                         "Run setup.sh first." >&2
                    return 1
                fi
            fi

            local _arch="${_pass_args[0]:-}"
            local _vm_args=("${_pass_args[@]:1}")

            # Determine instance name for log file (mirrors provision_incus.sh defaults).
            local _vm_log_name="otbrvm64"
            if [[ "$_arch" == "arm64" || "$_arch" == "aarch64" ]]; then
                _vm_log_name="otbrarm64"
            fi
            for _a in "${_vm_args[@]+"${_vm_args[@]}"}"; do
                case "$_a" in
                    --container) _vm_log_name="otbr-ct" ;;
                    --name=*)    _vm_log_name="${_a#--name=}" ;;
                esac
            done
            local _otbr_log="${_OTBRSTACK_DIR}/logs/${_vm_log_name}.log"
            mkdir -p "${_OTBRSTACK_DIR}/logs"
            echo "[otbrstack] Logging to: ${_otbr_log}"

            case "$_arch" in
                x64|x86_64)
                    echo "[otbrstack] Incus VM (native x86_64)  (scripts: ${_OTBRSTACK_DIR})"
                    {
                        if [[ "$_use_sg" -eq 1 ]]; then
                            sg incus-admin -c "\"$_OTBRSTACK_DIR/provision_incus.sh\" ${_vm_args[*]+"${_vm_args[*]}"}"
                        else
                            "$_OTBRSTACK_DIR/provision_incus.sh" "${_vm_args[@]+"${_vm_args[@]}"}"
                        fi
                    } 2>&1 | tee -a "$_otbr_log"
                    ;;
                arm64|aarch64)
                    echo "[otbrstack] Incus VM (arm64)  (scripts: ${_OTBRSTACK_DIR})"
                    {
                        if [[ "$_use_sg" -eq 1 ]]; then
                            sg incus-admin -c "\"$_OTBRSTACK_DIR/provision_incus.sh\" --arch=arm64 ${_vm_args[*]+"${_vm_args[*]}"}"
                        else
                            "$_OTBRSTACK_DIR/provision_incus.sh" --arch=arm64 "${_vm_args[@]+"${_vm_args[@]}"}"
                        fi
                    } 2>&1 | tee -a "$_otbr_log"
                    ;;
                *)
                    echo "Usage: otbrstack vm <x64|arm64> [extra args]"
                    return 1
                    ;;
            esac
            ;;
        flash)
            echo "[otbrstack] Flash Ubuntu Server 26.04 to SD card  (scripts: ${_OTBRSTACK_DIR})"

            # Determine log file from --hostname= flag.
            local _flash_log_host="otbr"
            for _a in "${_pass_args[@]+"${_pass_args[@]}"}"; do
                case "$_a" in --hostname=*) _flash_log_host="${_a#--hostname=}" ;; esac
            done
            local _otbr_log="${_OTBRSTACK_DIR}/logs/${_flash_log_host}.log"
            mkdir -p "${_OTBRSTACK_DIR}/logs"
            echo "[otbrstack] Logging to: ${_otbr_log}"

            # Commit any pending changes to the current branch first.
            (
                cd "$_OTBRSTACK_DIR"
                git add -A
                if ! git diff --cached --quiet; then
                    git commit -m "TEMP: pre-flash snapshot $(date '+%Y-%m-%d %H:%M:%S')"
                fi
            )
            # Create an isolated git worktree so the main working tree stays on
            # its current branch and remains fully editable while flashing runs.
            # The worktree gets its own checkout of a flash branch; cache/ and
            # artifacts/ are symlinked in so both share the same downloaded files.
            local _flash_branch="flash/$(date '+%Y%m%d-%H%M%S')"
            local _flash_wt
            _flash_wt=$(mktemp -d --suffix="-otbrstack-flash")
            git -C "$_OTBRSTACK_DIR" worktree add "$_flash_wt" -b "$_flash_branch"
            for _d in cache artifacts; do
                [[ -e "$_OTBRSTACK_DIR/$_d" ]] || continue
                # Remove any directory git may have created here (e.g. if a
                # file inside cache/ was accidentally tracked) before symlinking.
                rm -rf "${_flash_wt:?}/$_d"
                ln -s "$_OTBRSTACK_DIR/$_d" "$_flash_wt/$_d"
            done
            echo "[otbrstack] Running flash from worktree: ${_flash_wt}"
            echo "[otbrstack] Main working tree remains editable on its current branch."
            { "$_flash_wt/flash-piotbr.sh" "${_pass_args[@]+"${_pass_args[@]}"}"; } 2>&1 \
                | tee -a "$_otbr_log"
            local _flash_rc="${PIPESTATUS[0]}"
            git -C "$_OTBRSTACK_DIR" worktree remove --force "$_flash_wt" \
                || sudo rm -rf "$_flash_wt"
            git -C "$_OTBRSTACK_DIR" worktree prune 2>/dev/null || true
            echo ""
            echo "[otbrstack] Flash complete. Flash branch preserved at: ${_flash_branch}"
            echo "[otbrstack] Git HEAD at time of flash:"
            git -C "$_OTBRSTACK_DIR" log -1 --oneline "$_flash_branch"
            return $_flash_rc
            ;;
        docker)
            echo "[otbrstack] Docker bare-metal provisioner"
            local _otbr_log="${_OTBRSTACK_DIR}/logs/$(hostname).log"
            mkdir -p "${_OTBRSTACK_DIR}/logs"
            echo "[otbrstack] Logging to: ${_otbr_log}"
            { "$_OTBRSTACK_DIR/otbr-docker-setup.sh" "${_pass_args[@]+"${_pass_args[@]}"}"; } 2>&1 \
                | tee -a "$_otbr_log"
            ;;
        snap)
            echo "[otbrstack] Snap bare-metal provisioner"
            local _otbr_log="${_OTBRSTACK_DIR}/logs/$(hostname).log"
            mkdir -p "${_OTBRSTACK_DIR}/logs"
            echo "[otbrstack] Logging to: ${_otbr_log}"
            { "$_OTBRSTACK_DIR/otbr-snap-setup.sh" "${_pass_args[@]+"${_pass_args[@]}"}"; } 2>&1 \
                | tee -a "$_otbr_log"
            ;;
        shutdown)
            local _host="${_pass_args[0]:-}"
            if [[ -z "$_host" ]]; then
                echo "Usage: otbrstack shutdown <ssh_host>"
                return 1
            fi
            echo "[otbrstack] Shutting down ${_host} ..."
            ssh "$_host" -- sudo shutdown -h now
            ;;
        restart)
            local _host="${_pass_args[0]:-}"
            if [[ -z "$_host" ]]; then
                echo "Usage: otbrstack restart <ssh_host>"
                return 1
            fi
            echo "[otbrstack] Restarting ${_host} ..."
            ssh "$_host" -- sudo reboot
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
            local _otbr_log="${_OTBRSTACK_DIR}/logs/${_host}.log"
            mkdir -p "${_OTBRSTACK_DIR}/logs"
            echo "[otbrstack] Logs from ${_host} (appending to: ${_otbr_log})"
            if [[ "$_follow" -eq 1 ]]; then
                local _ssh_target
                _ssh_target=$(ssh -G "$_host" 2>/dev/null | awk '/^hostname / {print $2; exit}')
                _ssh_target="${_ssh_target:-$_host}"
                echo "[otbrstack] Waiting for SSH on ${_ssh_target}:22 (timeout 300s) ..."
                if command -v wait-for-it &>/dev/null; then
                    if ! wait-for-it --timeout=300 "${_ssh_target}:22"; then
                        echo "[otbrstack] ERROR: ${_ssh_target}:22 did not become available." >&2
                        return 1
                    fi
                else
                    local _deadline=$(( $(date +%s) + 300 ))
                    while [[ $(date +%s) -lt $_deadline ]]; do
                        nc -z -w3 "$_ssh_target" 22 2>/dev/null && break
                        printf '.'
                        sleep 5
                    done
                    echo ""
                    if ! nc -z -w3 "$_ssh_target" 22 2>/dev/null; then
                        echo "[otbrstack] ERROR: ${_ssh_target}:22 did not become available." >&2
                        return 1
                    fi
                fi
                ssh -t "$_host" '
                    _cleanup() { kill $(jobs -p) 2>/dev/null; }
                    trap _cleanup EXIT INT TERM
                    sudo journalctl -f -k --no-pager -o short-iso \
                        | sed "s/^/[dmesg] /" &
                    sudo journalctl -f -u "cloud-init*" --no-pager -o short-iso \
                        | sed "s/^/[cloud-init] /" &
                    (until snap list openthread-border-router >/dev/null 2>&1; do
                        sleep 10
                    done; sudo snap logs -f openthread-border-router 2>/dev/null) \
                        | sed "s/^/[otbr-snap] /" &
                    sudo journalctl -f -u "snap.chiptool.*" --no-pager -o short-iso 2>/dev/null \
                        | sed "s/^/[chiptool] /" &
                    sudo tail -f /var/log/otbr-firstboot.log 2>/dev/null \
                        | sed "s/^/[firstboot] /" &
                    wait
                ' | tee -a "$_otbr_log"
            else
                ssh "$_host" '
                    _section() { echo; echo "=== [$1] ==="; }
                    _section "dmesg"
                    sudo journalctl -b -k --no-pager -o short-iso \
                        | sed "s/^/[dmesg] /"
                    _section "cloud-init"
                    sudo journalctl -b -u "cloud-init*" --no-pager -o short-iso \
                        | sed "s/^/[cloud-init] /"
                    _section "otbr-snap"
                    sudo snap logs -n=all openthread-border-router \
                        | sed "s/^/[otbr-snap] /"
                    _section "chiptool"
                    sudo journalctl -b -u "snap.chiptool.*" --no-pager -o short-iso \
                        | sed "s/^/[chiptool] /"
                    _section "firstboot"
                    if [[ -f /var/log/otbr-firstboot.log ]]; then
                        sed "s/^/[firstboot] /" /var/log/otbr-firstboot.log
                    else
                        echo "[firstboot] /var/log/otbr-firstboot.log not found"
                    fi
                ' | tee -a "$_otbr_log"
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
  echo "  shutdown <host>   Graceful shutdown of a remote OTBR device"
  echo "  restart <host>    Reboot a remote OTBR device"
            [[ -n "$cmd" ]] && return 1 || return 0
            ;;
    esac
}
