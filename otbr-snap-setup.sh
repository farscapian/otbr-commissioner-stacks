#!/usr/bin/env bash
# otbr-setup.sh
# Detects ESP32 RCP device, verifies spinel firmware, configures and restarts OTBR snap.
# Run as normal user — sudo is invoked only when needed for snap commands.

set -euo pipefail

# ---------------------------------------------------------------------------
# 1. Configuration
# ---------------------------------------------------------------------------
BAUD=460800
INFRA_IF="${INFRA_IF:-$(ip route show default | awk '/default/ {print $5; exit}')}"
THREAD_IF="${THREAD_IF:-wpan0}"
PYSPINEL_VENV="${PYSPINEL_VENV:-$(dirname "$0")/artifacts/pyspinel-venv}"
ESPRESSIF_VENDOR_ID="303a"
SONOFF_VENDOR_ID="10c4"
SONOFF_PRODUCT_ID="ea60"
ENV_FILE="${ENV_FILE:-$(dirname "$0")/.env}"

# ---------------------------------------------------------------------------
# 2. Helpers
# ---------------------------------------------------------------------------
log()  { echo "[INFO]  $*"; }
warn() { echo "[WARN]  $*" >&2; }
die()  { echo "[ERROR] $*" >&2; exit 1; }

require() {
    command -v "$1" &>/dev/null || die "Required command not found: $1"
}


# ---------------------------------------------------------------------------
# 3. Load .env file
# ---------------------------------------------------------------------------
load_env() {
    if [[ ! -f "$ENV_FILE" ]]; then
        die ".env file not found at $ENV_FILE. Set ENV_FILE= to override the path."
    fi

    log "Loading environment from $ENV_FILE..."

    # Source only valid KEY=VALUE lines, ignoring comments and blanks
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// }" ]] && continue
        if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
            export "${BASH_REMATCH[1]}"="${BASH_REMATCH[2]}"
        fi
    done < "$ENV_FILE"

    [[ -n "${THREAD_DATASET_TLV:-}" ]] || die "THREAD_DATASET_TLV not set in $ENV_FILE"
    log "THREAD_DATASET_TLV loaded (${#THREAD_DATASET_TLV} hex chars)."
}

# ---------------------------------------------------------------------------
# 4. Find Thread radio device (ESP32-C6 preferred, Sonoff fallback)
# ---------------------------------------------------------------------------

# Usage: _find_usb_tty <vendor_id> [product_id]
# Searches all tty devices (ttyACM* and ttyUSB*) for a matching USB vendor/product.
_find_usb_tty() {
    local wanted_vendor="$1"
    local wanted_product="${2:-}"

    for dev in /dev/ttyACM* /dev/ttyUSB*; do
        [[ -e "$dev" ]] || continue
        local devname
        devname=$(basename "$dev")

        local check_path
        check_path=$(readlink -f /sys/class/tty/"$devname"/device 2>/dev/null || true)
        while [[ -n "$check_path" && "$check_path" != "/" ]]; do
            if [[ -f "$check_path/idVendor" ]]; then
                local vendor product
                vendor=$(cat "$check_path/idVendor")
                product=$(cat "$check_path/idProduct" 2>/dev/null || true)
                if [[ "$vendor" == "$wanted_vendor" ]]; then
                    if [[ -z "$wanted_product" || "$product" == "$wanted_product" ]]; then
                        echo "$dev"
                        return 0
                    fi
                fi
                break
            fi
            check_path=$(dirname "$check_path")
        done
    done
}

find_thread_device() {
    # NOTE: This function must be called directly (not in a subshell) so that
    # THREAD_DEVICE_TYPE and THREAD_DEVICE_PORT globals are set in the parent shell.
    local port

    # Prefer ESP32-C6
    port=$(_find_usb_tty "$ESPRESSIF_VENDOR_ID")
    if [[ -n "$port" ]]; then
        THREAD_DEVICE_TYPE="esp32c6"
        THREAD_DEVICE_PORT="$port"
        return 0
    fi

    # Fall back to Sonoff dongle
    port=$(_find_usb_tty "$SONOFF_VENDOR_ID" "$SONOFF_PRODUCT_ID")
    if [[ -n "$port" ]]; then
        THREAD_DEVICE_TYPE="sonoff"
        THREAD_DEVICE_PORT="$port"
        return 0
    fi

    THREAD_DEVICE_TYPE=""
    THREAD_DEVICE_PORT=""
    return 1
}

# ---------------------------------------------------------------------------
# 5. Check serial port group membership
# ---------------------------------------------------------------------------
check_serial_group() {
    # Determine the owning group of ttyACM devices (typically 'dialout' on Ubuntu)
    local group="dialout"
    local dev
    for dev in /dev/ttyACM*; do
        [[ -e "$dev" ]] || continue
        group=$(stat -c "%G" "$dev")
        break
    done

    if ! getent group "$group" &>/dev/null; then
        warn "Group '$group' not found on this system — skipping group check."
        return
    fi

    # Check permanent membership in /etc/group
    if ! id -nG "$USER" | grep -qw "$group"; then
        log "Adding $USER to group '$group'..."
        sudo usermod -aG "$group" "$USER"
        echo ""
        echo "  ╔══════════════════════════════════════════════════════╗"
        echo "  ║  Added $USER to '$group'.                            "
        echo "  ║  You must log out and log back in for this           "
        echo "  ║  to take effect, then re-run this script.            "
        echo "  ╚══════════════════════════════════════════════════════╝"
        echo ""
        exit 0
    fi

    # Permanent membership exists — check if active session reflects it
    if ! groups | grep -qw "$group"; then
        echo ""
        echo "  ╔══════════════════════════════════════════════════════╗"
        echo "  ║  You are in the '$group' group but your current      "
        echo "  ║  session does not reflect it yet.                    "
        echo "  ║  Please log out and log back in, then re-run.        "
        echo "  ╚══════════════════════════════════════════════════════╝"
        echo ""
        exit 0
    fi

    log "Group membership OK: $USER is in '$group'."
}


# ---------------------------------------------------------------------------
# 6. Ensure required kernel modules are loaded
# ---------------------------------------------------------------------------
ensure_kernel_modules() {
    local modules=(ip_set ip_set_hash_net ip_set_hash_ip ip_set_bitmap_port)
    local loaded=0

    for mod in "${modules[@]}"; do
        if ! lsmod | grep -q "^${mod}"; then
            log "Loading kernel module: $mod"
            sudo modprobe "$mod"
            loaded=1
        fi
    done

    # Persist across reboots
    local conf=/etc/modules-load.d/otbr.conf
    if [[ ! -f "$conf" ]]; then
        log "Persisting kernel modules to $conf..."
        printf '%s
' "${modules[@]}" | sudo tee "$conf" > /dev/null
    fi

    [[ "$loaded" -eq 1 ]] && sleep 1
}

# ---------------------------------------------------------------------------
# 7. Stop OTBR snap if running (to free the serial port)
# ---------------------------------------------------------------------------
stop_otbr_if_running() {
    if ! snap list openthread-border-router &>/dev/null; then
        log "OTBR snap not installed — skipping stop."
        return 0
    fi
    local running
    running=$(sudo snap services openthread-border-router | awk 'NR>1 && $3=="active" {print $1}' | head -1)
    if [[ -n "$running" ]]; then
        log "Stopping OTBR snap to free serial port..."
        sudo snap stop openthread-border-router
        sleep 1
    else
        log "OTBR snap is not running — no need to stop."
    fi
}


# ---------------------------------------------------------------------------
# 7. Verify RCP firmware via spinel version query (ESP32-C6 only)
# ---------------------------------------------------------------------------
verify_rcp() {
    local port="$1"

    log "Verifying RCP firmware on $port via spinel..."

    # Create pyspinel venv if missing
    if [[ ! -f "$PYSPINEL_VENV/bin/activate" ]]; then
        log "pyspinel venv not found — creating at $PYSPINEL_VENV..."
        python3 -m venv "$PYSPINEL_VENV"
        "$PYSPINEL_VENV/bin/pip" install --quiet pyspinel
        log "pyspinel installed."
    fi

    # shellcheck disable=SC1091
    source "$PYSPINEL_VENV/bin/activate"
    require spinel-cli.py

    local version
    version=$(timeout 5 bash -c "
        echo 'version' | python3 -W ignore \$(which spinel-cli.py) -u '$port' -b '$BAUD' 2>/dev/null \
            | grep -i openthread || true
    ") || true

    deactivate 2>/dev/null || true

    if [[ -z "$version" ]]; then
        die "No spinel response from $port. Is RCP firmware flashed with CONFIG_OPENTHREAD_RCP_USB_SERIAL_JTAG=y?"
    fi

    log "RCP firmware verified: $version"
}

# ---------------------------------------------------------------------------
# 8. Configure and restart OTBR snap
# ---------------------------------------------------------------------------
configure_otbr() {
    local port="$1"
    local radio_url="spinel+hdlc+uart://${port}?uart-baudrate=${BAUD}"
    local changed=0

    log "Configuring OTBR snap..."

    # Install snap if not present
    if ! snap list openthread-border-router &>/dev/null; then
        log "openthread-border-router snap not installed — installing..."
        sudo snap install openthread-border-router --channel=latest/edge
        changed=1
    fi

    # Both radio-url (used by agent startup script) and otbr-radio-url must be set
    local current_url
    current_url=$(sudo snap get openthread-border-router radio-url 2>/dev/null || true)
    if [[ "$current_url" != "$radio_url" ]]; then
        log "Setting radio-url to: $radio_url"
        sudo snap set openthread-border-router radio-url="$radio_url"
        changed=1
    else
        log "radio-url already correct: $radio_url"
    fi

    local current_otbr_url
    current_otbr_url=$(sudo snap get openthread-border-router otbr-radio-url 2>/dev/null || true)
    if [[ "$current_otbr_url" != "$radio_url" ]]; then
        log "Setting otbr-radio-url to: $radio_url"
        sudo snap set openthread-border-router otbr-radio-url="$radio_url"
        changed=1
    else
        log "otbr-radio-url already correct: $radio_url"
    fi

    local current_infra
    current_infra=$(sudo snap get openthread-border-router infra-if 2>/dev/null || true)
    if [[ "$current_infra" != "$INFRA_IF" ]]; then
        log "Setting infra-if to: $INFRA_IF"
        sudo snap set openthread-border-router infra-if="$INFRA_IF"
        changed=1
    fi

    local current_thread
    current_thread=$(sudo snap get openthread-border-router thread-if 2>/dev/null || true)
    if [[ "$current_thread" != "$THREAD_IF" ]]; then
        log "Setting thread-if to: $THREAD_IF"
        sudo snap set openthread-border-router thread-if="$THREAD_IF"
        changed=1
    fi

    # Ensure autostart is enabled
    local current_autostart
    current_autostart=$(sudo snap get openthread-border-router autostart 2>/dev/null || true)
    if [[ "$current_autostart" != "true" ]]; then
        log "Enabling autostart..."
        sudo snap set openthread-border-router autostart=true
        changed=1
    fi

    if [[ "$changed" -eq 1 ]]; then
        log "Configuration changed — restarting OTBR snap..."
        sudo snap restart openthread-border-router
        sleep 2
        sudo snap services openthread-border-router
    else
        # Even if config unchanged, ensure services are actually running
        local inactive
        inactive=$(sudo snap services openthread-border-router | awk 'NR>1 && $3=="inactive" {print $1}')
        if [[ -n "$inactive" ]]; then
            log "Starting inactive services..."
            sudo snap start openthread-border-router
            sleep 2
            sudo snap services openthread-border-router
        else
            log "No configuration changes needed — services already running."
        fi
    fi
}



# ---------------------------------------------------------------------------
# 9. Ensure required snap interface connections
# ---------------------------------------------------------------------------
ensure_snap_connections() {
    log "Checking snap interface connections..."

    local interfaces=(
        "firewall-control::firewall-control"
        "network-control::network-control"
        "raw-usb::raw-usb"
        "avahi-control::avahi-control"
    )

    local reconnected=0
    for entry in "${interfaces[@]}"; do
        local plug slot
        plug="${entry%%:*}"
        slot="${entry##*:}"
        local connected
        connected=$(snap connections openthread-border-router | awk -v plug="openthread-border-router:$plug" '$1!="" && $2==plug {print $3}')
        if [[ -z "$connected" || "$connected" == "-" ]]; then
            log "Connecting interface: $plug -> :$slot"
            sudo snap connect "openthread-border-router:$plug" ":$slot"
            reconnected=1
        else
            log "Interface already connected: $plug"
        fi
    done

    if [[ "$reconnected" -eq 1 ]]; then
        log "Interfaces changed — restarting snap..."
        sudo snap restart openthread-border-router
        sleep 2
    fi
}

# ---------------------------------------------------------------------------
# 10. Configure UFW rules for OTBR
# ---------------------------------------------------------------------------
configure_ufw() {
    if ! command -v ufw &>/dev/null; then
        log "ufw not found — skipping firewall configuration."
        return 0
    fi

    local ufw_status
    ufw_status=$(sudo ufw status | head -1)
    if [[ "$ufw_status" != "Status: active" ]]; then
        log "ufw is not active — skipping firewall configuration."
        return 0
    fi

    log "Configuring UFW rules for OTBR..."

    # Ensure iptables-persistent is installed so ip6tables rules survive reboots
    if ! dpkg -s iptables-persistent &>/dev/null; then
        log "Installing iptables-persistent..."
        # Pre-answer debconf prompts so apt doesn't pause for interactive input
        echo "iptables-persistent iptables-persistent/autosave_v4 boolean true" | sudo debconf-set-selections
        echo "iptables-persistent iptables-persistent/autosave_v6 boolean true" | sudo debconf-set-selections
        sudo apt-get install -y iptables-persistent
    fi

    # IPv6 forwarding: Thread (wpan0) <-> upstream interface
    # UFW persists route rules in its own config — no extra step needed.
    if ! sudo ufw status verbose | grep -q "Anywhere on wpan0"; then
        log "Adding UFW route rules for wpan0..."
        sudo ufw route allow in on wpan0
        sudo ufw route allow out on wpan0
    else
        log "UFW route rules for wpan0 already present."
    fi

    # ICMPv6: required for NDP / router advertisements
    local ip6tables_changed=0
    if ! sudo ip6tables -C FORWARD -p icmpv6 -j ACCEPT 2>/dev/null; then
        log "Allowing ICMPv6 forwarding..."
        sudo ip6tables -A FORWARD -p icmpv6 -j ACCEPT
        ip6tables_changed=1
    else
        log "ICMPv6 FORWARD rule already present."
    fi
    if ! sudo ip6tables -C INPUT -p icmpv6 -j ACCEPT 2>/dev/null; then
        log "Allowing ICMPv6 input..."
        sudo ip6tables -A INPUT -p icmpv6 -j ACCEPT
        ip6tables_changed=1
    else
        log "ICMPv6 INPUT rule already present."
    fi

    # Persist ip6tables rules so they survive reboots
    if [[ "$ip6tables_changed" -eq 1 ]]; then
        log "Saving ip6tables rules..."
        sudo netfilter-persistent save
    fi

    # mDNS: needed for Thread SRP / service discovery
    # UFW persists allow rules in its own config — no extra step needed.
    if ! sudo ufw status | grep -q "5353/udp"; then
        log "Allowing mDNS (UDP 5353)..."
        sudo ufw allow 5353/udp
    else
        log "mDNS rule already present."
    fi

    log "UFW configuration done."
}

# ---------------------------------------------------------------------------
# 12. Join Thread network using Active Dataset from .env
# ---------------------------------------------------------------------------
join_thread_network() {
    local dataset="$1"
    local ot="sudo openthread-border-router.ot-ctl"

    log "Configuring Thread network dataset..."
    $ot dataset set active "$dataset"
    $ot dataset commit active

    log "Bringing Thread interface up..."
    $ot ifconfig up
    $ot thread start

    log "Waiting for Thread to attach (up to 30s)..."
    local i=0
    while [[ $i -lt 30 ]]; do
        local state
        state=$($ot state 2>/dev/null | head -1 || true)
        if [[ "$state" == "router" || "$state" == "child" || "$state" == "leader" ]]; then
            log "Thread attached — state: $state"
            return 0
        fi
        sleep 1
        (( i++ ))
    done

    local final_state
    final_state=$($ot state 2>/dev/null | head -1 || true)
    warn "Thread did not attach within 30s — current state: $final_state"
    warn "Check: sudo snap logs openthread-border-router.otbr-agent -f"
}

# ---------------------------------------------------------------------------
# 13. Main
# ---------------------------------------------------------------------------
main() {
    [[ "$EUID" -eq 0 ]] && die "Do not run as root. Run as your normal user — sudo will be invoked as needed."
    require snap

    load_env
    check_serial_group
    ensure_kernel_modules

    log "Searching for Thread radio device (ESP32-C6 preferred, Sonoff fallback)..."
    THREAD_DEVICE_TYPE=""
    THREAD_DEVICE_PORT=""
    find_thread_device || true

    if [[ -z "$THREAD_DEVICE_PORT" ]]; then
        die "No Thread radio device found. Connect an ESP32-C6 or Sonoff Thread dongle."
    fi

    log "Found $THREAD_DEVICE_TYPE device at: $THREAD_DEVICE_PORT"

    stop_otbr_if_running
    if [[ "$THREAD_DEVICE_TYPE" == "esp32c6" ]]; then
        verify_rcp "$THREAD_DEVICE_PORT"
    else
        log "Skipping spinel verification for $THREAD_DEVICE_TYPE device."
    fi
    configure_otbr "$THREAD_DEVICE_PORT"
    ensure_snap_connections
    configure_ufw
    join_thread_network "$THREAD_DATASET_TLV"

    log "Done."
}

main "$@"