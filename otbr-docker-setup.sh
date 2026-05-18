#!/usr/bin/env bash
# =============================================================================
# otbr-setup.sh
# OpenThread Border Router setup for Ubuntu 25.10
# Sonoff Dongle-E (EFR32, RCP firmware) + Docker CE + nginx reverse proxy
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# 1. Helpers  (defined first so die/info/etc are available everywhere)
# -----------------------------------------------------------------------------

info()    { echo -e "\n\033[1;34m[INFO]\033[0m $*"; }
success() { echo -e "\033[1;32m[OK]\033[0m $*"; }
warn()    { echo -e "\033[1;33m[WARN]\033[0m $*"; }
die()     { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; exit 1; }

# -----------------------------------------------------------------------------
# 2. Configuration
# Env is loaded by otbrstack before invoking this script.
# -----------------------------------------------------------------------------

validate_config() {
    # Validate required variables
    for var in DONGLE_VENDOR DONGLE_PRODUCT DONGLE_SERIAL THREAD_DATASET_TLV; do
        [[ -n "${!var:-}" ]] || die "Required variable '${var}' not set — run via 'otbrstack docker'"
    done

    # Optional overrides with defaults
    DONGLE_SYMLINK="${DONGLE_SYMLINK:-ttyTHREAD}"
    BAUD_RATE="${BAUD_RATE:-460800}"
}

# Fixed configuration (not in .env)
OTBR_IMAGE="openthread/otbr:latest"
OTBR_CONTAINER="otbr"
OTBR_CONFIG_DIR="/opt/otbr"
NGINX_REST_PORT="8080"
NGINX_WEB_PORT="8088"
OTBR_INTERNAL_REST="127.0.0.1:8081"
OTBR_INTERNAL_WEB="127.0.0.1:80"
TARGET_SUBNET="192.168.4"

# -----------------------------------------------------------------------------
# 3. Disable sleep / suspend
# -----------------------------------------------------------------------------

disable_sleep() {
    info "3. Disabling system sleep and suspend ..."
    sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
    success "Sleep/suspend disabled."
}

# -----------------------------------------------------------------------------
# 4. Detect Ethernet interface on target subnet
# -----------------------------------------------------------------------------

detect_interface() {
    info "4. Detecting Ethernet interface on subnet ${TARGET_SUBNET}.x ..."

    local iface
    iface=$(ip -o -4 addr show \
        | awk -v subnet="$TARGET_SUBNET" '$4 ~ "^" subnet { print $2 }' \
        | head -n1)

    if [[ -z "$iface" ]]; then
        warn "No interface found on ${TARGET_SUBNET}.x — falling back to default route interface."
        iface=$(ip route show default | awk '/default/ { print $5 }' | head -n1)
    fi

    [[ -n "$iface" ]] || die "Could not detect a network interface. Set BACKBONE_IF manually."
    BACKBONE_IF="$iface"
    success "Using interface: $BACKBONE_IF"
}

# -----------------------------------------------------------------------------
# 5. Kernel modules
# -----------------------------------------------------------------------------

load_kernel_modules() {
    info "5. Loading required kernel modules ..."

    for mod in ip6table_filter ip6_tables; do
        if ! lsmod | grep -q "^${mod}"; then
            sudo modprobe "$mod" || warn "Could not load $mod — may already be built-in."
        fi
    done

    sudo tee /etc/modules-load.d/otbr.conf > /dev/null << 'EOF'
ip6table_filter
ip6_tables
EOF
    success "Kernel modules loaded and persisted."
}

# -----------------------------------------------------------------------------
# 6. udev rule
# -----------------------------------------------------------------------------

setup_udev() {
    info "6. Setting up udev rule for Thread dongle ..."

    sudo tee /etc/udev/rules.d/99-thread-dongle.rules > /dev/null << EOF
SUBSYSTEM=="tty", ATTRS{idVendor}=="${DONGLE_VENDOR}", ATTRS{idProduct}=="${DONGLE_PRODUCT}", ATTRS{serial}=="${DONGLE_SERIAL}", SYMLINK+="${DONGLE_SYMLINK}"
EOF

    sudo udevadm control --reload-rules && sudo udevadm trigger

    # Wait up to 5 seconds for symlink to appear
    local i
    for i in {1..10}; do
        [[ -e "/dev/${DONGLE_SYMLINK}" ]] && break
        sleep 0.5
    done

    [[ -e "/dev/${DONGLE_SYMLINK}" ]] \
        || die "/dev/${DONGLE_SYMLINK} did not appear. Check dongle is plugged in and serial matches."

    REAL_DEVICE=$(readlink -f "/dev/${DONGLE_SYMLINK}")
    success "Dongle symlink: /dev/${DONGLE_SYMLINK} -> ${REAL_DEVICE}"
}

# -----------------------------------------------------------------------------
# 7. Install Docker CE
# -----------------------------------------------------------------------------

install_docker() {
    info "7. Installing Docker CE ..."

    if command -v docker &>/dev/null; then
        success "Docker already installed: $(docker --version)"
        return
    fi

    sudo apt-get remove -y docker docker.io containerd runc 2>/dev/null || true
    sudo apt-get update -q
    sudo apt-get install -y ca-certificates curl gnupg

    sudo install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    sudo chmod a+r /etc/apt/keyrings/docker.gpg

    echo \
        "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu \
$(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
        | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

    sudo apt-get update -q
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin

    sudo systemctl enable --now docker
    success "Docker CE installed: $(docker --version)"
}

# -----------------------------------------------------------------------------
# 8. Pull OTBR image
# -----------------------------------------------------------------------------

pull_image() {
    info "8. Pulling OTBR image: ${OTBR_IMAGE} ..."
    sudo docker pull "$OTBR_IMAGE"
    success "Image pulled."
}

# -----------------------------------------------------------------------------
# 9. Write otbr-agent config override
# -----------------------------------------------------------------------------

write_otbr_config() {
    info "9. Writing otbr-agent config to ${OTBR_CONFIG_DIR} ..."

    sudo mkdir -p "$OTBR_CONFIG_DIR"
    sudo tee "${OTBR_CONFIG_DIR}/otbr-agent" > /dev/null << EOF
OTBR_AGENT_OPTS="-I wpan0 -B ${BACKBONE_IF} spinel+hdlc+uart:///dev/${DONGLE_SYMLINK}?uart-baudrate=${BAUD_RATE} trel://${BACKBONE_IF}"
OTBR_NO_AUTO_ATTACH=0
EOF
    success "Config written."
}

# -----------------------------------------------------------------------------
# 10. Launch OTBR container
# -----------------------------------------------------------------------------

launch_container() {
    info "10. Launching OTBR container ..."

    # Remove existing container if present
    if sudo docker ps -a --format '{{.Names}}' | grep -q "^${OTBR_CONTAINER}$"; then
        warn "Existing container '${OTBR_CONTAINER}' found — removing."
        sudo docker stop "$OTBR_CONTAINER" || true
        sudo docker rm "$OTBR_CONTAINER"
    fi

    sudo docker run -d \
        --name "$OTBR_CONTAINER" \
        --restart unless-stopped \
        --privileged \
        --network host \
        -v "${OTBR_CONFIG_DIR}/otbr-agent:/etc/default/otbr-agent:ro" \
        --device "${REAL_DEVICE}:/dev/${DONGLE_SYMLINK}" \
        "$OTBR_IMAGE"

    success "Container launched."

    info "Waiting 10 seconds for agent to initialise ..."
    sleep 10

    sudo docker logs "$OTBR_CONTAINER" 2>&1 | tail -20
}

# -----------------------------------------------------------------------------
# 11. Install and configure nginx reverse proxy
# -----------------------------------------------------------------------------

setup_nginx() {
    info "11. Installing nginx reverse proxy ..."

    sudo apt-get install -y nginx

    # Disable default site
    sudo rm -f /etc/nginx/sites-enabled/default

    sudo tee /etc/nginx/sites-available/otbr > /dev/null << EOF
server {
    listen ${NGINX_REST_PORT};
    location / {
        proxy_pass http://${OTBR_INTERNAL_REST};
    }
}

server {
    listen ${NGINX_WEB_PORT};
    location / {
        proxy_pass http://${OTBR_INTERNAL_WEB};
    }
}
EOF

    sudo ln -sf /etc/nginx/sites-available/otbr /etc/nginx/sites-enabled/otbr
    sudo nginx -t
    sudo systemctl enable --now nginx
    sudo systemctl restart nginx
    success "nginx configured and running."
}

# -----------------------------------------------------------------------------
# 12. Configure ufw
# -----------------------------------------------------------------------------

setup_firewall() {
    info "12. Configuring ufw firewall rules ..."

    if ! command -v ufw &>/dev/null; then
        warn "ufw not found — skipping firewall setup."
        return
    fi

    read -rp "Enter the IP address of your Home Assistant server (e.g. 192.168.4.37): " HA_IP
    [[ -n "$HA_IP" ]] || die "No IP entered."

    # REST API and Web UI (via nginx)
    sudo ufw allow from "$HA_IP" to any port "$NGINX_REST_PORT" comment 'OTBR REST API for HA'
    sudo ufw allow from "$HA_IP" to any port "$NGINX_WEB_PORT"  comment 'OTBR Web UI for HA'

    # TREL (Thread Radio Encapsulation Link) — UDP on ephemeral ports between border routers
    sudo ufw allow from "$HA_IP" to any proto udp comment 'TREL Thread traffic from HA'

    # Thread mDNS multicast — service discovery between border routers
    sudo ufw allow in on "$BACKBONE_IF" proto udp to ff12::/16 comment 'Thread mDNS multicast'

    # Thread border agent port — used by HA to reach the border agent directly
    sudo ufw allow from "$HA_IP" to any port 49191 proto udp comment 'Thread border agent'

    success "ufw rules added for HA at ${HA_IP}."
}

# -----------------------------------------------------------------------------
# 13. Join existing Thread network
# -----------------------------------------------------------------------------

join_thread_network() {
    info "13. Joining existing Thread network ..."

    local DATASET="$THREAD_DATASET_TLV"
    info "Using Thread dataset from .env file."

    # Disable node first to allow dataset replacement
    curl -sf -X PUT "http://localhost:${NGINX_REST_PORT}/node/state" \
        -H 'Content-Type: application/json' \
        -d '"disable"' || true
    sleep 2

    # Use ot-ctl to set dataset cleanly
    sudo docker exec "$OTBR_CONTAINER" ot-ctl thread stop    || true
    sudo docker exec "$OTBR_CONTAINER" ot-ctl ifconfig down  || true
    sudo docker exec "$OTBR_CONTAINER" ot-ctl dataset clear
    sudo docker exec "$OTBR_CONTAINER" ot-ctl dataset set active "$DATASET"
    sudo docker exec "$OTBR_CONTAINER" ot-ctl dataset commit active
    sudo docker exec "$OTBR_CONTAINER" ot-ctl ifconfig up
    sudo docker exec "$OTBR_CONTAINER" ot-ctl thread start

    info "Waiting 15 seconds for Thread network join ..."
    sleep 15

    local state netname
    state=$(sudo docker exec "$OTBR_CONTAINER" ot-ctl state 2>&1 | tr -d '\r')
    netname=$(sudo docker exec "$OTBR_CONTAINER" ot-ctl networkname 2>&1 | tr -d '\r')

    success "Thread state:   $state"
    success "Network name:   $netname"

    if [[ "$state" == "router" || "$state" == "child" || "$state" == "leader" ]]; then
        success "Successfully joined Thread network."
    else
        warn "Unexpected state '${state}'. Check 'docker exec ${OTBR_CONTAINER} ot-ctl state' manually."
    fi
}

# -----------------------------------------------------------------------------
# 14. chip-tool snap (Matter commissioning — BLE+Thread and Thread-only)
# -----------------------------------------------------------------------------

install_chiptool() {
    if snap list chip-tool &>/dev/null; then
        success "chip-tool snap already installed."
        return 0
    fi
    info "Installing chip-tool snap..."
    snap install chip-tool
    success "chip-tool installed."
}

# -----------------------------------------------------------------------------
# 15. Summary
# -----------------------------------------------------------------------------

print_summary() {
    local host_ip
    host_ip=$(ip -o -4 addr show "$BACKBONE_IF" | awk '{print $4}' | cut -d/ -f1)

    echo ""
    echo "============================================================"
    echo "  OTBR Setup Complete"
    echo "============================================================"
    echo "  Backbone interface : $BACKBONE_IF"
    echo "  Host IP            : $host_ip"
    echo "  REST API (for HA)  : http://${host_ip}:${NGINX_REST_PORT}"
    echo "  Web UI             : http://${host_ip}:${NGINX_WEB_PORT}"
    echo ""
    echo "  Add to Home Assistant:"
    echo "  Settings → System → Thread → Add Border Router"
    echo "  URL: http://${host_ip}:${NGINX_REST_PORT}"
    echo "============================================================"
}

# -----------------------------------------------------------------------------
# main
# -----------------------------------------------------------------------------

main() {
    validate_config
    disable_sleep
    detect_interface
    load_kernel_modules
    setup_udev
    install_docker
    pull_image
    write_otbr_config
    launch_container
    setup_nginx
    setup_firewall
    install_chiptool
    join_thread_network
    print_summary
}

main "$@"