#!/usr/bin/env bash
# =============================================================================
# test-vm/run-vm.sh
#
# Launch the QEMU aarch64 VM with dual NIC networking and optional ESP32-C6
# USB passthrough.
#
# NETWORKING
#   NIC 1 — MACVTAP (bridge mode) on the host's default route interface.
#            The VM gets its own real IP from your router via DHCP.
#            Home Assistant can reach this IP directly.
#            MAC: 52:54:00:aa:bb:01  (fixed; matches netplan in user-data)
#
#   NIC 2 — QEMU user-mode NAT.
#            Host-only; used for SSH from this machine (localhost:2222).
#            MAC: 52:54:00:aa:bb:02  (fixed; matches netplan in user-data)
#
#   NOTE: MACVTAP creation requires CAP_NET_ADMIN (sudo). The tap character
#   device is chowned to the calling user after creation so QEMU can open it
#   without further privilege escalation. The Linux kernel blocks direct
#   host↔macvtap-child traffic, which is why we keep the NAT NIC for host SSH.
#
# USAGE
#   ./run-vm.sh             # auto-detects physical RCP dongle
#   ./run-vm.sh --sim-rcp   # use simulated ot-rcp via socat PTY (no hardware)
#   ./run-vm.sh --no-usb    # skip USB passthrough entirely
#
# EXIT
#   Ctrl+C (or kill) tears down QEMU and removes the macvtap interface.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'; NC='\033[0m'
info() { echo -e "${GRN}[INFO]${NC}  $*"; }
warn() { echo -e "${YLW}[WARN]${NC}  $*"; }
die()  { echo -e "${RED}[ERR ]${NC}  $*" >&2; exit 1; }

NO_USB=0
SIM_RCP=0
LOADVM=""
for arg in "$@"; do
    case "$arg" in
        --no-usb)   NO_USB=1 ;;
        --sim-rcp)  SIM_RCP=1; NO_USB=1 ;;
        --loadvm=*) LOADVM="${arg#--loadvm=}" ;;
    esac
done

VM_DISK="${SCRIPT_DIR}/vm-disk.qcow2"
SEED_ISO="${SCRIPT_DIR}/seed.iso"
UEFI_FW_SRC="/usr/share/qemu-efi-aarch64/QEMU_EFI.fd"
UEFI_FW="${SCRIPT_DIR}/uefi-code.fd"   # 64 MiB padded copy required by pflash

[[ -f "$VM_DISK"    ]] || die "VM disk not found. Run setup.sh first."
[[ -f "$SEED_ISO"   ]] || die "Seed ISO not found. Run setup.sh first."
[[ -f "$UEFI_FW_SRC" ]] || die "UEFI firmware not found: install qemu-efi-aarch64."

# pflash0 must be exactly 64 MiB; QEMU_EFI.fd is ~3 MiB raw — pad with zeros.
if [[ ! -f "$UEFI_FW" ]]; then
    cp "$UEFI_FW_SRC" "$UEFI_FW"
    truncate -s 64M "$UEFI_FW"
fi

# ---------------------------------------------------------------------------
# MACVTAP — LAN NIC
# ---------------------------------------------------------------------------

LAN_MAC="52:54:00:aa:bb:01"   # fixed — must match netplan in user-data.yaml.tpl
MGMT_MAC="52:54:00:aa:bb:02"  # fixed — must match netplan in user-data.yaml.tpl
MACVTAP_NAME="macvtap-otbr"
MACVTAP_FD=""
QEMU_PID=""
SIM_RCP_PID=""
SIM_PTY=""
MONITOR_SOCK=""

cleanup() {
    [[ -n "$QEMU_PID" ]]     && kill "$QEMU_PID"     2>/dev/null || true
    [[ -n "$SIM_RCP_PID" ]]  && kill "$SIM_RCP_PID"  2>/dev/null || true
    [[ -n "$MACVTAP_FD" ]]   && { eval "exec ${MACVTAP_FD}>&-" 2>/dev/null || true; }
    sudo ip link del "$MACVTAP_NAME" 2>/dev/null || true
    [[ -n "$MONITOR_SOCK" ]] && rm -f "$MONITOR_SOCK"
    rm -f "${SIM_PTY:-}"
}
trap cleanup EXIT TERM INT

# Find a physical ethernet interface for MACVTAP.
# Uses sysfs to identify real PCI/USB NICs, skipping VPN tunnels, bridges, etc.
# Prefers the interface on the default route; falls back to first physical NIC found.
find_host_iface() {
    local -a candidates=()
    local route_iface iface devpath

    route_iface=$(ip route show | awk '/^default/{for(i=1;i<NF;i++) if($i=="dev"){print $(i+1); exit}}')

    for iface in $(ls /sys/class/net/); do
        devpath=$(readlink -f "/sys/class/net/${iface}/device" 2>/dev/null) || continue
        # Only PCI and USB-backed NICs — excludes wg*, tun*, lo, macvtap, bridges
        [[ "$devpath" == */pci* || "$devpath" == */usb* ]] || continue
        [[ "$(< "/sys/class/net/${iface}/operstate")" == "up" ]] || continue
        candidates+=("$iface")
    done

    [[ ${#candidates[@]} -eq 0 ]] && return 1

    for iface in "${candidates[@]}"; do
        [[ "$iface" == "$route_iface" ]] && { echo "$iface"; return 0; }
    done
    echo "${candidates[0]}"
}

HOST_IFACE=$(find_host_iface) || die "No physical ethernet interface found (up and PCI/USB-backed). Connect a wired NIC."
info "Host physical interface for MACVTAP: ${HOST_IFACE}"

# Warn if wireless — many WiFi drivers reject MACVTAP bridge mode
if [[ -d "/sys/class/net/${HOST_IFACE}/wireless" ]]; then
    warn "Interface ${HOST_IFACE} is wireless."
    warn "Many WiFi drivers silently drop MACVTAP bridged frames."
    warn "A USB Ethernet dongle is strongly recommended for reliable OTBR backbone routing."
    warn "Proceeding anyway — if the VM never gets a LAN IP, switch to a wired interface."
fi

# Remove stale macvtap from a previous unclean exit
if ip link show "$MACVTAP_NAME" &>/dev/null; then
    warn "Removing stale ${MACVTAP_NAME} ..."
    sudo ip link del "$MACVTAP_NAME"
fi

info "Creating MACVTAP interface (${MACVTAP_NAME}, MAC ${LAN_MAC}) on ${HOST_IFACE} ..."
sudo ip link add link "$HOST_IFACE" name "$MACVTAP_NAME" address "$LAN_MAC" type macvtap mode bridge
sudo ip link set "$MACVTAP_NAME" up

MACVTAP_IDX=$(cat /sys/class/net/${MACVTAP_NAME}/ifindex)
# Tap device is root-owned after creation; give the current user access so
# QEMU (running unprivileged) can inherit the open fd.
sudo chown "$(id -u):$(id -g)" "/dev/tap${MACVTAP_IDX}"

# Open the tap character device; fd is inherited by QEMU after fork.
# bash exec {var}<>file opens without O_CLOEXEC so the child inherits it.
exec {MACVTAP_FD}<>/dev/tap${MACVTAP_IDX}
info "MACVTAP tap fd: ${MACVTAP_FD}  (/dev/tap${MACVTAP_IDX})"

# ---------------------------------------------------------------------------
# ESP32-C6 USB passthrough
# ---------------------------------------------------------------------------

USB_ARGS=()

if [[ $NO_USB -eq 0 ]]; then
    # Detect first Thread RCP serial port (ttyACM* or ttyUSB*) via sysfs.
    # VID-agnostic: works with ESP32-C6, SONOFF CP210x dongles, or any RCP.
    RCP_FOUND=0
    for _dev in /dev/ttyACM* /dev/ttyUSB*; do
        [[ -e "$_dev" ]] || continue
        _base=$(basename "$_dev")
        _iface=$(readlink -f "/sys/class/tty/${_base}/device" 2>/dev/null) || continue
        _usbdev=$(dirname "$_iface")
        [[ -f "$_usbdev/idVendor" ]] || continue
        _vid=$(< "$_usbdev/idVendor")
        _pid=$(< "$_usbdev/idProduct")
        _bus=$(< "$_usbdev/busnum")
        _devnum=$(< "$_usbdev/devnum")
        info "Thread RCP detected — ${_dev} (${_vid}:${_pid}, Bus ${_bus}, Device ${_devnum})"
        info "Passing through to VM"
        USB_ARGS=(
            -device qemu-xhci,id=xhci
            -device "usb-host,hostbus=${_bus},hostaddr=${_devnum}"
        )
        RCP_FOUND=1
        break
    done
    unset _dev _base _iface _usbdev _vid _pid _bus _devnum
    if [[ $RCP_FOUND -eq 0 ]]; then
        warn "No Thread RCP detected (/dev/ttyACM* or /dev/ttyUSB*). VM boots without RCP."
        warn "Connect the RCP dongle and restart, or pass --no-usb to suppress this warning."
    fi
else
    warn "--no-usb: starting without RCP passthrough."
fi

# ---------------------------------------------------------------------------
# Simulated RCP — ot-rcp simulation binary connected via socat PTY
# ---------------------------------------------------------------------------
# The ot-rcp simulation speaks spinel/HDLC over stdio. socat bridges it to a
# PTY; QEMU exposes that PTY to the VM as a USB serial device (/dev/ttyUSB0).
# No real RF — the simulated Thread node becomes network leader on its own.
#
SIM_RCP_ARGS=()

ensure_sim_rcp_binary() {
    local bin="${SIM_RCP_BIN:-${PROJECT_ROOT}/cache/ot-rcp-sim/ot-rcp}"

    # 1. Binary already present (default path or explicit SIM_RCP_BIN)
    if [[ -f "$bin" ]]; then
        chmod +x "$bin"
        info "Sim RCP binary: $bin"
        SIM_RCP_BIN_RESOLVED="$bin"
        return
    fi

    # 2. Download from URL
    if [[ -n "${SIM_RCP_URL:-}" ]]; then
        info "Downloading ot-rcp simulation binary from: $SIM_RCP_URL"
        mkdir -p "$(dirname "$bin")"
        curl -L --progress-bar -o "$bin" "$SIM_RCP_URL"
        chmod +x "$bin"
        info "Cached: $bin"
        SIM_RCP_BIN_RESOLVED="$bin"
        return
    fi

    die "No ot-rcp simulation binary available. Set one of these in your .env:
  SIM_RCP_BIN=/path/to/ot-rcp        (local Linux x86_64 binary)
  SIM_RCP_URL=https://...ot-rcp       (download URL)
Build from source: cd openthread && ./script/cmake-build simulation
  Binary: build/simulation/examples/apps/ncp/ot-rcp"
}

if [[ $SIM_RCP -eq 1 ]]; then
    ensure_sim_rcp_binary
    SIM_PTY="/tmp/ot-sim-pty-$$"

    info "Starting simulated ot-rcp, PTY: ${SIM_PTY} ..."
    socat PTY,link="${SIM_PTY}",raw,echo=0,b460800 \
          EXEC:"${SIM_RCP_BIN_RESOLVED} 1",pty,raw,b460800 &
    SIM_RCP_PID=$!

    for _i in $(seq 1 20); do [[ -e "$SIM_PTY" ]] && break || sleep 0.1; done
    unset _i
    [[ -e "$SIM_PTY" ]] || die "Simulated RCP PTY never appeared at ${SIM_PTY}"
    info "Simulated RCP ready (PID ${SIM_RCP_PID})"

    SIM_RCP_ARGS=(
        -chardev "serial,id=simrcp,path=${SIM_PTY}"
        -device  qemu-xhci,id=simxhci
        -device  "usb-serial,chardev=simrcp,bus=simxhci.0"
    )
fi

# ---------------------------------------------------------------------------
# Snap cache — virtio-9p share of host snap-cache/ directory
# ---------------------------------------------------------------------------
# setup.sh downloads the openthread-border-router snap + assert into cache/snap/.
# Mounting it here lets otbr-firstboot.sh install offline without hitting the
# snap store, avoiding rate limits and speeding up the first-boot sequence.

SNAP_CACHE="${PROJECT_ROOT}/cache/snap"
SNAP_CACHE_ARGS=()
if compgen -G "${SNAP_CACHE}/*.snap" > /dev/null 2>&1; then
    SNAP_CACHE_ARGS=(
        -virtfs "local,path=${SNAP_CACHE},mount_tag=snap_cache,security_model=none,readonly=on"
    )
    info "Snap cache found — mounting into VM via virtio-9p"
else
    warn "No snap cache found in ${SNAP_CACHE} — VM will install from store"
    warn "Run setup.sh to populate the snap cache"
fi

# ---------------------------------------------------------------------------
# UEFI variables store
# ---------------------------------------------------------------------------

UEFI_VARS="${SCRIPT_DIR}/uefi-vars.fd"
[[ -f "$UEFI_VARS" ]] || dd if=/dev/zero of="$UEFI_VARS" bs=1M count=64 status=none

MONITOR_SOCK="${SCRIPT_DIR}/qemu-monitor.sock"
LOADVM_ARGS=()
[[ -n "$LOADVM" ]] && LOADVM_ARGS=(-loadvm "$LOADVM")

# ---------------------------------------------------------------------------
# Launch QEMU
# ---------------------------------------------------------------------------

info "Starting QEMU aarch64 VM ..."
info "  LAN IP:  check your router DHCP leases for MAC ${LAN_MAC}"
info "  SSH:     ssh -p 2222 ubuntu@localhost  (via NAT NIC)"
info "  Console: Ctrl+A X to quit QEMU"
echo

qemu-system-aarch64 \
    -M virt \
    -cpu cortex-a72 \
    -smp 4 \
    -m 2G \
    \
    -drive "if=pflash,format=raw,file=${UEFI_FW},readonly=on" \
    -drive "if=pflash,format=raw,file=${UEFI_VARS}" \
    \
    -drive "if=virtio,format=qcow2,file=${VM_DISK}" \
    -drive "if=virtio,format=raw,file=${SEED_ISO},media=cdrom,readonly=on" \
    \
    -device "virtio-net-pci,netdev=lan0,mac=${LAN_MAC}" \
    -netdev  "tap,id=lan0,fd=${MACVTAP_FD}" \
    \
    -device "virtio-net-pci,netdev=mgmt0,mac=${MGMT_MAC}" \
    -netdev  "user,id=mgmt0,hostfwd=tcp::2222-:22" \
    \
    -device virtio-rng-pci \
    \
    "${USB_ARGS[@]+"${USB_ARGS[@]}"}" \
    \
    "${SIM_RCP_ARGS[@]+"${SIM_RCP_ARGS[@]}"}" \
    \
    "${SNAP_CACHE_ARGS[@]+"${SNAP_CACHE_ARGS[@]}"}" \
    \
    -chardev "socket,id=monitor0,path=${MONITOR_SOCK},server=on,wait=off" \
    -mon "chardev=monitor0,mode=readline" \
    \
    "${LOADVM_ARGS[@]+"${LOADVM_ARGS[@]}"}" \
    \
    -nographic \
    -serial mon:stdio &

QEMU_PID=$!
info "QEMU PID: ${QEMU_PID}"
wait "$QEMU_PID" || true

# =============================================================================
# OPTIONAL: udev rule for non-root USB passthrough
# (MACVTAP still requires root regardless)
#
#   echo 'SUBSYSTEM=="usb", ATTRS{idVendor}=="303a", MODE="0664", GROUP="plugdev"' \
#       | sudo tee /etc/udev/rules.d/99-espressif.rules
#   sudo udevadm control --reload-rules && sudo udevadm trigger
#   sudo usermod -aG plugdev $USER
# =============================================================================
