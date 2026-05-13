#!/usr/bin/env bash
# =============================================================================
# provision_incus.sh
#
# Provision an Incus VM or system container running the OTBR first-boot
# sequence. Functionally equivalent to provision_piotbrvm.sh (QEMU) but runs
# native x86_64 — much faster, no emulation overhead.
#
# USAGE
#   sudo ./provision_incus.sh [options]
#
# OPTIONS
#   --vm              Launch an Incus VM (default)
#   --container       Launch a system container instead of a VM
#   --name=NAME       Instance name (default: otbr-vm or otbr-ct)
#   --env-file=PATH   Path to env file (default: $(hostname).env)
#   --reprovision     Delete existing instance and provision from scratch
#
# PREREQUISITES
#   incus must be installed and the current user must be in the incus group
#   (or run as root).  Run test-vm/setup.sh first to populate cache/snap/ and
#   cache/ot-rcp-sim/ — provision_incus.sh reuses those caches.
#
# DISK SHARING
#   VM:        cache/snap and cache/ot-rcp-sim are virtiofs shares; firstboot
#              mounts them with `mount -t virtiofs <tag> <mountpoint>`.
#   Container: same directories are Incus bind-mounts; firstboot finds them
#              already present at the expected paths.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_VM_DIR="${SCRIPT_DIR}/test-vm"
PYSPINEL_VENV="${SCRIPT_DIR}/artifacts/pyspinel-venv"
INCUS_DIR="${SCRIPT_DIR}/incus"
BAUD=460800

# ---------------------------------------------------------------------------
# Arg parsing
# ---------------------------------------------------------------------------

INSTANCE_MODE="vm"
INSTANCE_NAME=""
_ENV_FILE=""
REPROVISION=0

for _arg in "$@"; do
    case "$_arg" in
        --vm)           INSTANCE_MODE="vm" ;;
        --container)    INSTANCE_MODE="container" ;;
        --name=*)       INSTANCE_NAME="${_arg#--name=}" ;;
        --env-file=*)   _ENV_FILE="${_arg#--env-file=}" ;;
        --reprovision)  REPROVISION=1 ;;
        *) echo "Unknown arg: $_arg" >&2; exit 1 ;;
    esac
done

[[ -z "$INSTANCE_NAME" ]] && INSTANCE_NAME="otbr-$([[ $INSTANCE_MODE == vm ]] && echo vm || echo ct)"

if [[ -n "$_ENV_FILE" ]]; then
    [[ -f "$_ENV_FILE" ]] || { echo "env file not found: $_ENV_FILE" >&2; exit 1; }
else
    _ENV_FILE="${SCRIPT_DIR}/$(hostname).env"
    if [[ ! -f "$_ENV_FILE" ]]; then
        [[ -f "${SCRIPT_DIR}/.env" ]] || { echo "No $(hostname).env or .env found; create one or use --env-file=PATH" >&2; exit 1; }
        cp "${SCRIPT_DIR}/.env" "$_ENV_FILE"
        warn "Created ${_ENV_FILE} from .env template."
        warn "Edit it with your machine-specific details before re-running."
        exit 1
    fi
fi
set -a; source "$_ENV_FILE"; set +a
unset _arg _ENV_FILE

BOOT_TIMEOUT="${BOOT_TIMEOUT:-300}"
OTBR_TIMEOUT="${OTBR_TIMEOUT:-600}"
THREAD_DATASET_TLV="${THREAD_DATASET_TLV:-}"
RCP_FIRMWARE_URL="${RCP_FIRMWARE_URL:-https://raw.githubusercontent.com/farscapian/otbr-commissioner-stacks/main/cache/esp32/rcp/esp_ot_rcp.bin}"
RCP_FLASH_ADDR="${RCP_FLASH_ADDR:-0x10000}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'; BLU='\033[0;34m'; NC='\033[0m'
info()  { echo -e "${GRN}[INFO ]${NC}  $*"; }
warn()  { echo -e "${YLW}[WARN ]${NC}  $*"; }
die()   { echo -e "${RED}[FAIL ]${NC}  $*" >&2; exit 1; }
step()  { echo -e "\n${BLU}━━━ $* ${NC}"; }
pass()  { echo -e "\n${GRN}[PASS ]${NC}  $*"; }

generate_thread_tlv() {
    python3 - <<'PYEOF'
import os, struct

def tlv(t, v):
    return bytes([t, len(v)]) + v

dataset = (
    tlv(0x0e, struct.pack('>Q', (1 << 16) | 1))  +
    tlv(0x00, bytes([0]) + struct.pack('>H', 15)) +
    tlv(0x35, bytes([0, 4, 0x00, 0x1f, 0xff, 0xe0])) +
    tlv(0x02, os.urandom(8))                       +
    tlv(0x03, b'OTBR-Incus')                       +
    tlv(0x05, os.urandom(16))                      +
    tlv(0x04, os.urandom(16))                      +
    tlv(0x01, os.urandom(2))                       +
    tlv(0x0c, struct.pack('>H', 672) + b'\xf7\xf8')
)
print(dataset.hex(), end='')
PYEOF
}

# Same flash_rcp and RCP detection logic as provision_piotbrvm.sh

prompt_flash_rcp() {
    local port="$1"
    echo
    read -rp "  No RCP firmware detected on ${port}. Flash it now? [y/N] " _ans </dev/tty
    [[ "${_ans,,}" == "y" ]]
}

flash_rcp() {
    local port="$1"
    local firmware=""

    if [[ -n "${RCP_FIRMWARE_PATH:-}" ]]; then
        [[ -f "$RCP_FIRMWARE_PATH" ]] || die "RCP_FIRMWARE_PATH not found: $RCP_FIRMWARE_PATH"
        firmware="$RCP_FIRMWARE_PATH"
        info "Using local firmware: $firmware"
    elif [[ -n "${RCP_FIRMWARE_URL:-}" ]]; then
        local fw_cache="${SCRIPT_DIR}/cache/esp32/rcp/rcp-firmware-cache.bin"
        mkdir -p "$(dirname "$fw_cache")"
        if [[ ! -f "$fw_cache" ]]; then
            info "Downloading RCP firmware from: $RCP_FIRMWARE_URL"
            curl -L --progress-bar -o "$fw_cache" "$RCP_FIRMWARE_URL"
        else
            info "Using cached firmware: $fw_cache"
        fi
        firmware="$fw_cache"
    else
        warn "No firmware source configured — cannot flash."
        warn "Set one of these in your .env:"
        warn "  RCP_FIRMWARE_PATH=/path/to/ot_rcp_esp32c6.bin   (local pre-built binary)"
        warn "  RCP_FIRMWARE_URL=https://example.com/ot_rcp_esp32c6.bin   (download URL)"
        warn ""
        warn "Build from source with ESP-IDF:"
        warn "  https://github.com/espressif/esp-thread-br/tree/main/examples/ot_rcp"
        return 1
    fi

    local esptool=""
    for _cmd in esptool.py esptool; do
        command -v "$_cmd" &>/dev/null && esptool="$_cmd" && break
    done
    unset _cmd
    if [[ -z "$esptool" ]]; then
        info "esptool not found — installing via pip ..."
        pip3 install --quiet esptool
        esptool="esptool.py"
    fi

    local flash_addr="$RCP_FLASH_ADDR"
    info "Flashing $firmware → $port at $flash_addr ..."
    "$esptool" --chip esp32c6 --port "$port" --baud 460800 \
        write_flash "$flash_addr" "$firmware"
    info "Flash complete — waiting for USB re-enumeration ..."
    sleep 8
}

find_rcp() {
    local candidates=()
    for p in /dev/ttyUSB* /dev/ttyACM*; do [[ -e "$p" ]] && candidates+=("$p"); done

    if [[ ${#candidates[@]} -eq 0 ]]; then
        warn "No USB serial devices found — skipping RCP verification."
        RCP_DEVICE=""; RCP_VID=""; RCP_PID=""
        return
    fi

    RCP_DEVICE="${candidates[0]}"
    RCP_VID=""; RCP_PID=""

    local _base _iface _usbdev
    _base=$(basename "$RCP_DEVICE")
    _iface=$(readlink -f "/sys/class/tty/${_base}/device" 2>/dev/null) || true
    if [[ -n "$_iface" ]]; then
        _usbdev=$(dirname "$_iface")
        if [[ -f "$_usbdev/idVendor" ]]; then
            RCP_VID=$(< "$_usbdev/idVendor")
            RCP_PID=$(< "$_usbdev/idProduct")
        fi
    fi

    info "USB serial candidates: ${candidates[*]}"
    info "Using first: $RCP_DEVICE${RCP_VID:+ (${RCP_VID}:${RCP_PID})}"
}

verify_rcp() {
    local port="$1"
    info "Verifying RCP firmware on $port via spinel..."

    local holder
    holder=$(lsof -t "$port" 2>/dev/null | head -1 || true)
    if [[ -n "$holder" ]]; then
        local holder_name
        holder_name=$(ps -p "$holder" -o comm= 2>/dev/null || echo "PID $holder")
        warn "$port held by $holder_name — skipping verification, using sim instead."
        RCP_DEVICE=""
        return 0
    fi

    if [[ ! -f "$PYSPINEL_VENV/bin/spinel-cli.py" ]]; then
        info "Installing pyspinel venv ..."
        python3 -m venv "$PYSPINEL_VENV"
        "$PYSPINEL_VENV/bin/pip" install --quiet pyspinel
    fi

    local spinel_cli="$PYSPINEL_VENV/bin/spinel-cli.py"
    local version
    version=$(timeout 5 bash -c "
        echo 'version' | python3 -W ignore '$spinel_cli' -u '$port' -b '$BAUD' 2>/dev/null \
            | grep -i openthread || true
    ") || true

    if [[ -z "$version" ]]; then
        warn "No spinel response from $port — RCP firmware not detected."
        if prompt_flash_rcp "$port" && flash_rcp "$port"; then
            version=$(timeout 10 bash -c "
                echo 'version' | python3 -W ignore '$spinel_cli' -u '$port' -b '$BAUD' 2>/dev/null \
                    | grep -i openthread || true
            ") || true
            if [[ -z "$version" ]]; then
                warn "Still no spinel response — falling back to sim."
                RCP_DEVICE=""
            else
                info "RCP verified after flash: $version"
            fi
        else
            warn "Skipping flash — using sim."
            RCP_DEVICE=""
        fi
        return 0
    fi
    info "RCP firmware verified: $version"
}

# ---------------------------------------------------------------------------
# 1. Validate env
# ---------------------------------------------------------------------------

step "Checking environment"

if [[ -z "$THREAD_DATASET_TLV" ]]; then
    warn "THREAD_DATASET_TLV not set — generating a random dataset."
    warn "This creates an isolated Thread network, not joined to your existing one."
    THREAD_DATASET_TLV=$(generate_thread_tlv)
    info "Generated TLV: ${THREAD_DATASET_TLV:0:32}..."
else
    [[ "$THREAD_DATASET_TLV" =~ ^[0-9a-fA-F]+$ ]] \
        || die "THREAD_DATASET_TLV must be a hex string"
    info "THREAD_DATASET_TLV is set (${#THREAD_DATASET_TLV} chars)"
fi
info "Mode: $INSTANCE_MODE  Name: $INSTANCE_NAME"
info "BOOT_TIMEOUT=${BOOT_TIMEOUT}s  OTBR_TIMEOUT=${OTBR_TIMEOUT}s"

# ---------------------------------------------------------------------------
# 2. Host dependencies
# ---------------------------------------------------------------------------

step "Checking host dependencies"

command -v incus   &>/dev/null || die "incus not found. Install it: https://linuxcontainers.org/incus/docs/main/installing/"
command -v curl    &>/dev/null || die "curl not found"
command -v python3 &>/dev/null || die "python3 not found"
command -v lsof    &>/dev/null || sudo apt-get install -y lsof >/dev/null
# envsubst for template processing
command -v envsubst &>/dev/null || sudo apt-get install -y gettext-base >/dev/null
info "All host dependencies satisfied."

# ---------------------------------------------------------------------------
# 3. RCP firmware verification
# ---------------------------------------------------------------------------

step "Verifying RCP firmware"

find_rcp
if [[ -n "${RCP_DEVICE:-}" ]]; then
    if [[ "${RCP_VID:-}" == "303a" ]]; then
        verify_rcp "$RCP_DEVICE"
    else
        info "Non-ESP32 RCP ($RCP_DEVICE) — assuming OpenThread RCP firmware present."
    fi
fi
if [[ -z "${RCP_DEVICE:-}" ]]; then
    warn "No usable physical RCP — instance will use simulated ot-rcp (no real RF)."
fi

# ---------------------------------------------------------------------------
# 4. Sim binary
# ---------------------------------------------------------------------------

SIM_RCP_DIR="${SCRIPT_DIR}/cache/ot-rcp-sim"
SIM_RCP_BIN_PATH="${SIM_RCP_DIR}/ot-rcp"

if [[ -z "${RCP_DEVICE:-}" ]]; then
    step "Locating sim RCP binary"

    if [[ -n "${SIM_RCP_BIN:-}" ]]; then
        [[ -f "$SIM_RCP_BIN" ]] || die "SIM_RCP_BIN set but not found: $SIM_RCP_BIN"
        SIM_RCP_DIR="$(dirname "$SIM_RCP_BIN")"
        SIM_RCP_BIN_PATH="$SIM_RCP_BIN"
        info "Using SIM_RCP_BIN: $SIM_RCP_BIN_PATH"
    elif [[ -f "$SIM_RCP_BIN_PATH" ]]; then
        info "Cached sim binary: $SIM_RCP_BIN_PATH"
    elif [[ -n "${SIM_RCP_URL:-}" ]]; then
        info "Downloading sim binary from: $SIM_RCP_URL"
        mkdir -p "$SIM_RCP_DIR"
        curl -L --progress-bar -o "$SIM_RCP_BIN_PATH" "$SIM_RCP_URL"
        chmod +x "$SIM_RCP_BIN_PATH"
    else
        die "No sim binary available. Set one of these in your .env:
  SIM_RCP_BIN=/path/to/ot-rcp
  SIM_RCP_URL=https://...ot-rcp
Pre-built binaries: https://github.com/espressif/esp-thread-br/releases"
    fi
fi

# ---------------------------------------------------------------------------
# 5. Snap cache
# ---------------------------------------------------------------------------

step "Checking snap cache"

SNAP_CACHE="${SCRIPT_DIR}/cache/snap"
SNAP_NAME="openthread-border-router"

mkdir -p "$SNAP_CACHE"
if compgen -G "${SNAP_CACHE}/${SNAP_NAME}_*.snap" > /dev/null 2>&1; then
    info "Snap cache: $(ls ${SNAP_CACHE}/${SNAP_NAME}_*.snap | head -1 | xargs basename)"
else
    info "Snap cache empty — downloading ${SNAP_NAME} ..."
    snap download "$SNAP_NAME" --channel=latest/stable --target-directory="$SNAP_CACHE"
    info "Snap cached."
fi

# ---------------------------------------------------------------------------
# 6. Reprovision — delete existing instance
# ---------------------------------------------------------------------------

if [[ "$REPROVISION" -eq 1 ]]; then
    step "Reprovisioning — deleting existing instance"
    if incus info "$INSTANCE_NAME" &>/dev/null; then
        incus delete "$INSTANCE_NAME" --force
        info "Deleted instance: $INSTANCE_NAME"
    else
        info "No existing instance named $INSTANCE_NAME"
    fi
elif incus info "$INSTANCE_NAME" &>/dev/null; then
    warn "Instance '$INSTANCE_NAME' already exists."
    warn "Use --reprovision to delete and reprovision, or --name=NAME to use a different name."
    exit 1
fi

# ---------------------------------------------------------------------------
# 7. Generate cloud-init user-data from template
# ---------------------------------------------------------------------------

step "Generating cloud-init user-data"

USER_DATA=$(THREAD_DATASET_TLV="$THREAD_DATASET_TLV" \
    envsubst '${THREAD_DATASET_TLV}' \
    < "${INCUS_DIR}/user-data.yaml.tpl")

info "User-data generated ($(echo "$USER_DATA" | wc -l) lines)"

# ---------------------------------------------------------------------------
# 8. Init instance
# ---------------------------------------------------------------------------

step "Creating Incus $INSTANCE_MODE: $INSTANCE_NAME"

TYPE_FLAG="$([[ $INSTANCE_MODE == vm ]] && echo "--vm" || echo "")"

# shellcheck disable=SC2086
incus init ubuntu:24.04 "$INSTANCE_NAME" $TYPE_FLAG \
    --config "user.user-data=${USER_DATA}"

# security.nesting lets snapd manage systemd services inside a container
[[ "$INSTANCE_MODE" == "container" ]] && \
    incus config set "$INSTANCE_NAME" security.nesting=true

# ---------------------------------------------------------------------------
# 9. Add disk shares (snap cache + sim binary)
# ---------------------------------------------------------------------------

step "Attaching disk shares"

if [[ "$INSTANCE_MODE" == "vm" ]]; then
    # VM: virtiofs — no path arg; mount tag = device name
    incus config device add "$INSTANCE_NAME" snap_cache disk \
        source="${SNAP_CACHE}" readonly=true
    [[ -z "${RCP_DEVICE:-}" ]] && \
        incus config device add "$INSTANCE_NAME" ot_rcp_sim disk \
        source="${SIM_RCP_DIR}" readonly=true
    info "virtiofs shares: snap_cache${RCP_DEVICE:+} ot_rcp_sim"
else
    # Container: bind-mount — path arg sets the mount point inside the container
    incus config device add "$INSTANCE_NAME" snap_cache disk \
        source="${SNAP_CACHE}" path=/mnt/snap-cache readonly=true
    [[ -z "${RCP_DEVICE:-}" ]] && \
        incus config device add "$INSTANCE_NAME" ot_rcp_sim disk \
        source="${SIM_RCP_DIR}" path=/mnt/ot-rcp-sim readonly=true
    info "bind-mounts: snap_cache${RCP_DEVICE:+} ot_rcp_sim"
fi

# ---------------------------------------------------------------------------
# 10. Attach RCP device (real hardware only)
# ---------------------------------------------------------------------------

if [[ -n "${RCP_DEVICE:-}" ]]; then
    step "Attaching RCP device: $RCP_DEVICE"
    if [[ "$INSTANCE_MODE" == "vm" ]]; then
        # VM: USB passthrough by vendor:product ID
        [[ -n "$RCP_VID" && -n "$RCP_PID" ]] \
            || die "Cannot determine USB VID:PID for $RCP_DEVICE — cannot pass through to VM."
        incus config device add "$INSTANCE_NAME" rcp usb \
            vendorid="$RCP_VID" productid="$RCP_PID"
        info "USB passthrough: ${RCP_VID}:${RCP_PID}"
    else
        # Container: character device bind
        incus config device add "$INSTANCE_NAME" rcp unix-char \
            source="$RCP_DEVICE" path="$RCP_DEVICE"
        info "Character device: $RCP_DEVICE"
    fi
fi

# ---------------------------------------------------------------------------
# 11. Start instance
# ---------------------------------------------------------------------------

step "Starting instance"
incus start "$INSTANCE_NAME"
info "Instance started."

# ---------------------------------------------------------------------------
# 12. Wait for cloud-init to complete
# ---------------------------------------------------------------------------

step "Waiting for cloud-init (timeout ${BOOT_TIMEOUT}s)"

# Poll until exec is available (instance may still be booting)
DEADLINE=$(( SECONDS + BOOT_TIMEOUT ))
while (( SECONDS < DEADLINE )); do
    incus exec "$INSTANCE_NAME" -- true 2>/dev/null && break || sleep 2
done
(( SECONDS < DEADLINE )) || die "Timed out waiting for instance exec to become available."

if timeout "$BOOT_TIMEOUT" \
        incus exec "$INSTANCE_NAME" -- cloud-init status --wait --long; then
    info "cloud-init complete."
else
    rc=$?
    [[ $rc -eq 124 ]] && die "cloud-init timed out after ${BOOT_TIMEOUT}s." \
                       || die "cloud-init failed (exit $rc)."
fi

# ---------------------------------------------------------------------------
# 13. Tail OTBR first-boot log
# ---------------------------------------------------------------------------

step "Watching OTBR first-boot (timeout ${OTBR_TIMEOUT}s)"
info "Tailing /var/log/otbr-firstboot.log ..."
echo

REMOTE_CMD='
log=/var/log/otbr-firstboot.log
for i in $(seq 1 60); do
  [ -f "$log" ] && break
  printf "waiting for log (%d/60)...\n" "$i"
  sleep 2
done
[ -f "$log" ] || { echo "ERROR: log file never appeared"; exit 1; }
tail -f "$log" | while IFS= read -r line; do
  echo "$line"
  case "$line" in
    *"first-boot complete"*)  exit 0 ;;
    *"ERROR:"*)               exit 1 ;;
  esac
done
'

if timeout "$OTBR_TIMEOUT" incus exec "$INSTANCE_NAME" -- bash -c "$REMOTE_CMD"; then
    true
else
    rc=$?
    [[ $rc -eq 124 ]] && die "OTBR first-boot timed out after ${OTBR_TIMEOUT}s." \
                       || die "OTBR first-boot reported an error (exit $rc). See log above."
fi

# ---------------------------------------------------------------------------
# 14. Verify Thread interface
# ---------------------------------------------------------------------------

step "Verifying Thread interface"

THREAD_STATE=$(incus exec "$INSTANCE_NAME" -- \
    snap run openthread-border-router.ot-ctl state 2>/dev/null || echo "unavailable")

info "ot-ctl state: $THREAD_STATE"

case "$THREAD_STATE" in
    leader|router|child)
        pass "Thread node is active (state: $THREAD_STATE)"
        ;;
    *)
        warn "Thread state is '${THREAD_STATE}' — may still be joining."
        warn "Check manually: incus exec $INSTANCE_NAME -- snap run openthread-border-router.ot-ctl state"
        ;;
esac

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------

echo
pass "Provisioning complete. Instance is running."
info "Shell:    incus shell $INSTANCE_NAME"
info "Log:      incus exec $INSTANCE_NAME -- tail -f /var/log/otbr-firstboot.log"
info "ot-ctl:   incus exec $INSTANCE_NAME -- snap run openthread-border-router.ot-ctl state"
info "Teardown: incus delete $INSTANCE_NAME --force"
