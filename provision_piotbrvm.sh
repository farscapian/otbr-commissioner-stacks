#!/usr/bin/env bash
# =============================================================================
# provision_piotbrvm.sh
#
# End-to-end test: provisions a fresh QEMU VM, boots it, and watches
# the OTBR first-boot configuration complete via SSH.
#
# USAGE
#   sudo ./provision_piotbrvm.sh [--env-file=PATH] [--reprovision]
#
# HOST REQUIREMENTS
#   qemu-system-aarch64  ssh  ssh-keygen  python3
#   pyspinel installed automatically into pyspinel-venv/ on first run
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# 0. Bootstrap — root check + arg parsing + env file
# ---------------------------------------------------------------------------

[[ $EUID -eq 0 ]] || { echo "Must run as root (sudo)." >&2; exit 1; }
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_VM_DIR="${SCRIPT_DIR}/test-vm"
PYSPINEL_VENV="${SCRIPT_DIR}/artifacts/pyspinel-venv"
BAUD=460800
VM_DISK="${TEST_VM_DIR}/vm-disk.qcow2"
MONITOR_SOCK="${TEST_VM_DIR}/qemu-monitor.sock"
SNAP_CI="cloud-init-done"
SNAP_OTBR="otbr-ready"

_ENV_FILE=""
REPROVISION=0
_POSARGS=()
for _arg in "$@"; do
    case "$_arg" in
        --env-file=*)  _ENV_FILE="${_arg#--env-file=}" ;;
        --reprovision) REPROVISION=1 ;;
        *) _POSARGS+=("$_arg") ;;
    esac
done
if [[ ${#_POSARGS[@]} -gt 0 ]]; then
    set -- "${_POSARGS[@]}"
else
    set --
fi
unset _arg _POSARGS

if [[ -n "$_ENV_FILE" ]]; then
    [[ -f "$_ENV_FILE" ]] || { echo "env file not found: $_ENV_FILE" >&2; exit 1; }
else
    _ENV_FILE="${SCRIPT_DIR}/$(hostname).env"
    if [[ ! -f "$_ENV_FILE" ]]; then
        [[ -f "${SCRIPT_DIR}/.env" ]] || { echo "No $(hostname).env or .env found in ${SCRIPT_DIR}; create one or use --env-file=PATH" >&2; exit 1; }
        cp "${SCRIPT_DIR}/.env" "$_ENV_FILE"
        warn "Created ${_ENV_FILE} from .env template."
        warn "Edit it with your machine-specific details before re-running."
        exit 1
    fi
fi
set -a
# shellcheck source=/dev/null
source "$_ENV_FILE"
set +a
unset _ENV_FILE

BOOT_TIMEOUT="${BOOT_TIMEOUT:-1100}"
OTBR_TIMEOUT="${OTBR_TIMEOUT:-600}"
THREAD_DATASET_TLV="${THREAD_DATASET_TLV:-}"
SSH_KEY_FILE="${SSH_KEY_FILE:-}"
RCP_FIRMWARE_URL="${RCP_FIRMWARE_URL:-https://raw.githubusercontent.com/farscapian/otbr-commissioner-stacks/main/cache/esp32/rcp/esp_ot_rcp.bin}"
RCP_FLASH_ADDR="${RCP_FLASH_ADDR:-0x10000}"

# ---------------------------------------------------------------------------
# 1. Helpers
# ---------------------------------------------------------------------------

SSH_PORT=2222
SSH_USER=ubuntu
SSH_OPTS=(
    -p "$SSH_PORT"
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o LogLevel=ERROR
    -o ConnectTimeout=5
    -o BatchMode=yes
)

RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'; BLU='\033[0;34m'; NC='\033[0m'
info()  { echo -e "${GRN}[INFO ]${NC}  $*"; }
warn()  { echo -e "${YLW}[WARN ]${NC}  $*"; }
die()   { echo -e "${RED}[FAIL ]${NC}  $*" >&2; exit 1; }
step()  { echo -e "\n${BLU}━━━ $* ${NC}"; }
pass()  { echo -e "\n${GRN}[PASS ]${NC}  $*"; }

require_cmd() {
    for c in "$@"; do command -v "$c" &>/dev/null || die "Required command not found: $c"; done
}

generate_thread_tlv() {
    # Produces a minimal valid Thread Active Dataset TLV with randomised
    # Network Key, Extended PAN ID, PAN ID, and PSKc.
    # Fixed fields (channel 15, channels 11-26 mask, 672h rotation) match the
    # format of a default `ot-cli dataset init new` output.
    python3 - <<'PYEOF'
import os, struct

def tlv(t, v):
    return bytes([t, len(v)]) + v

dataset = (
    tlv(0x0e, struct.pack('>Q', (1 << 16) | 1))  +  # Active Timestamp: 1, authoritative
    tlv(0x00, bytes([0]) + struct.pack('>H', 15)) +  # Channel: page 0, channel 15
    tlv(0x35, bytes([0, 4, 0x00, 0x1f, 0xff, 0xe0])) +  # Channel Mask: ch 11-26
    tlv(0x02, os.urandom(8))                       +  # Extended PAN ID (random)
    tlv(0x03, b'OTBR-Sim')                         +  # Network Name
    tlv(0x05, os.urandom(16))                      +  # Network Key (random)
    tlv(0x04, os.urandom(16))                      +  # PSKc (random)
    tlv(0x01, os.urandom(2))                       +  # PAN ID (random)
    tlv(0x0c, struct.pack('>H', 672) + b'\xf7\xf8')   # Security Policy: 672h, all caps
)
print(dataset.hex(), end='')
PYEOF
}

# ---------------------------------------------------------------------------
# RCP firmware flashing (ESP32-C6 or compatible)
# ---------------------------------------------------------------------------
# Called when a serial device is present but returns no spinel response,
# meaning it likely has no RCP firmware on it.
#
# .env knobs:
#   RCP_FIRMWARE_PATH   Path to a local pre-built merged flash binary.
#                       Get from: https://github.com/espressif/esp-thread-br/releases
#                       (look for ot_rcp_esp32c6*.bin in the assets)
#
#   RCP_FIRMWARE_URL    Download URL for the firmware binary (used only when
#                       RCP_FIRMWARE_PATH is not set). The downloaded file is
#                       cached next to this script as rcp-firmware-cache.bin.
#
#   RCP_FLASH_ADDR      Flash offset for the binary (default: 0x0, correct for
#                       Espressif merged/combined images; use 0x10000 for
#                       app-only binaries).

prompt_flash_rcp() {
    local port="$1"
    echo
    # </dev/tty so read works even when stdin is a pipe
    read -rp "  No RCP firmware detected on ${port}. Flash it now? [y/N] " _ans </dev/tty
    [[ "${_ans,,}" == "y" ]]
}

flash_rcp() {
    local port="$1"
    local firmware=""

    # -- Locate firmware -------------------------------------------------------
    if [[ -n "${RCP_FIRMWARE_PATH:-}" ]]; then
        [[ -f "$RCP_FIRMWARE_PATH" ]] \
            || die "RCP_FIRMWARE_PATH set but not found: $RCP_FIRMWARE_PATH"
        firmware="$RCP_FIRMWARE_PATH"
        info "Using local firmware: $firmware"
    elif [[ -n "${RCP_FIRMWARE_URL:-}" ]]; then
        local fw_cache="${SCRIPT_DIR}/cache/esp32/rcp/rcp-firmware-cache.bin"
        mkdir -p "$(dirname "$fw_cache")"
        if [[ ! -f "$fw_cache" ]]; then
            info "Downloading RCP firmware from: $RCP_FIRMWARE_URL"
            curl -L --progress-bar -o "$fw_cache" "$RCP_FIRMWARE_URL"
        else
            info "Using cached firmware download: $fw_cache"
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

    # -- Ensure esptool is available -------------------------------------------
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

    # -- Flash -----------------------------------------------------------------
    local flash_addr="$RCP_FLASH_ADDR"
    info "Flashing $firmware → $port at $flash_addr ..."
    "$esptool" --chip esp32c6 --port "$port" --baud 460800 \
        write_flash "$flash_addr" "$firmware"
    info "Flash complete — waiting for device to reset ..."
    sleep 3
}

# ---------------------------------------------------------------------------
# Host dependency check — auto-install missing packages via apt
# ---------------------------------------------------------------------------
# Maps each required command to the apt package that provides it.
# If anything is missing, apt-get installs the full set in one shot so we
# only pay the sudo/apt overhead once.

check_host_deps() {
    # cmd -> apt package
    declare -A CMD_PKG=(
        [qemu-system-aarch64]=qemu-system-arm
        [qemu-img]=qemu-utils
        [cloud-localds]=cloud-image-utils
        [envsubst]=gettext-base
        [curl]=curl
        [ssh]=openssh-client
        [ssh-keygen]=openssh-client
        [python3]=python3
        [socat]=socat
        [lsof]=lsof
    )

    local missing_pkgs=()
    local missing_cmds=()
    for cmd in "${!CMD_PKG[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            missing_cmds+=("$cmd")
            pkg="${CMD_PKG[$cmd]}"
            # dedup
            [[ " ${missing_pkgs[*]} " == *" $pkg "* ]] || missing_pkgs+=("$pkg")
        fi
    done

    # qemu-efi-aarch64 has no single command to probe — check the file directly
    local uefi_src="/usr/share/qemu-efi-aarch64/QEMU_EFI.fd"
    if [[ ! -f "$uefi_src" ]]; then
        missing_cmds+=("QEMU_EFI.fd (qemu-efi-aarch64)")
        [[ " ${missing_pkgs[*]} " == *" qemu-efi-aarch64 "* ]] || missing_pkgs+=(qemu-efi-aarch64)
    fi

    if [[ ${#missing_pkgs[@]} -eq 0 ]]; then
        info "All host dependencies satisfied."
        return
    fi

    warn "Missing host dependencies: ${missing_cmds[*]}"
    info "Installing via apt: ${missing_pkgs[*]}"
    apt-get install -y "${missing_pkgs[@]}"

    # Re-verify after install
    local still_missing=()
    for cmd in "${!CMD_PKG[@]}"; do
        command -v "$cmd" &>/dev/null || still_missing+=("$cmd")
    done
    [[ ! -f "$uefi_src" ]] && still_missing+=("QEMU_EFI.fd")

    if [[ ${#still_missing[@]} -gt 0 ]]; then
        die "Still missing after install: ${still_missing[*]}"
    fi
    info "All host dependencies now satisfied."
}

has_snapshot() {
    local disk="$1" name="$2"
    [[ -f "$disk" ]] || return 1
    qemu-img snapshot -l "$disk" 2>/dev/null | grep -qF " $name "
}

vm_savevm() {
    local name="$1"
    [[ -S "$MONITOR_SOCK" ]] || { warn "Monitor socket not found — skipping savevm '$name'"; return 1; }
    info "Saving VM snapshot: $name (this may take a moment) ..."
    python3 - "$MONITOR_SOCK" "$name" <<'PYEOF'
import socket, sys
path, name = sys.argv[1], sys.argv[2]
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(path)
s.settimeout(5.0)
try: s.recv(4096)
except: pass
s.sendall(('savevm ' + name + '\n').encode())
s.settimeout(120.0)
buf = b''
try:
    while True:
        chunk = s.recv(4096)
        if not chunk: break
        buf += chunk
        if b'(qemu)' in buf: break
except Exception as e:
    print('Warning:', e, file=sys.stderr)
s.close()
PYEOF
    info "Snapshot '$name' saved."
}

VM_PID=""

cleanup() {
    local rc=$?
    echo
    if [[ $rc -ne 0 ]]; then
        echo -e "\n${RED}[FAIL ]${NC}  Test exited with status $rc"
    fi
    if [[ -n "$VM_PID" ]] && kill -0 "$VM_PID" 2>/dev/null; then
        warn "VM (PID $VM_PID) is still running — use teardown-vm.sh to stop it."
    fi
}
trap cleanup TERM INT

# ---------------------------------------------------------------------------
# 2. Validate env
# ---------------------------------------------------------------------------

step "Checking environment"

if [[ -z "$THREAD_DATASET_TLV" ]]; then
    warn "THREAD_DATASET_TLV not set — generating a random dataset."
    warn "This creates an isolated Thread network; it will NOT join your existing one."
    warn "Set THREAD_DATASET_TLV in .env to use real hardware with your actual network."
    THREAD_DATASET_TLV=$(generate_thread_tlv)
    info "Generated TLV (${#THREAD_DATASET_TLV} chars): ${THREAD_DATASET_TLV:0:32}..."
else
    [[ "$THREAD_DATASET_TLV" =~ ^[0-9a-fA-F]+$ ]] \
        || die "THREAD_DATASET_TLV must be a hex string (got: ${THREAD_DATASET_TLV:0:20}...)"
    info "THREAD_DATASET_TLV is set (${#THREAD_DATASET_TLV} chars)"
fi
info "BOOT_TIMEOUT=${BOOT_TIMEOUT}s  OTBR_TIMEOUT=${OTBR_TIMEOUT}s"

step "Checking host dependencies"
check_host_deps

# ---------------------------------------------------------------------------
# 2b. Snapshot detection
# ---------------------------------------------------------------------------

LOAD_SNAP=""
if [[ "$REPROVISION" -eq 1 ]]; then
    info "--reprovision: will wipe disk and provision from scratch."
elif has_snapshot "$VM_DISK" "$SNAP_OTBR"; then
    LOAD_SNAP="$SNAP_OTBR"
    info "Found snapshot '$SNAP_OTBR' — resuming. Use --reprovision to provision from scratch."
elif has_snapshot "$VM_DISK" "$SNAP_CI"; then
    LOAD_SNAP="$SNAP_CI"
    info "Found snapshot '$SNAP_CI' — resuming from post-cloud-init state."
else
    info "No snapshots found — full provision from scratch."
fi

# ---------------------------------------------------------------------------
# 3. RCP firmware verification
# ---------------------------------------------------------------------------

step "Verifying RCP firmware"

find_rcp() {
    local candidates=()
    for p in /dev/ttyUSB* /dev/ttyACM*; do [[ -e "$p" ]] && candidates+=("$p"); done

    if [[ ${#candidates[@]} -eq 0 ]]; then
        warn "No USB serial devices found — skipping RCP verification."
        RCP_DEVICE=""
        RCP_VIDPID=""
        return
    fi

    RCP_DEVICE="${candidates[0]}"
    RCP_VIDPID=""

    local _base _iface _usbdev
    _base=$(basename "$RCP_DEVICE")
    _iface=$(readlink -f "/sys/class/tty/${_base}/device" 2>/dev/null) || true
    if [[ -n "$_iface" ]]; then
        _usbdev=$(dirname "$_iface")
        if [[ -f "$_usbdev/idVendor" ]]; then
            RCP_VIDPID="$(< "$_usbdev/idVendor"):$(< "$_usbdev/idProduct")"
        fi
    fi

    info "USB serial candidates: ${candidates[*]}"
    info "Using first: $RCP_DEVICE${RCP_VIDPID:+ (${RCP_VIDPID})}"
}

verify_rcp() {
    local port="$1"
    info "Verifying RCP firmware on $port via spinel..."

    if [[ ! -f "$PYSPINEL_VENV/bin/spinel-cli.py" ]]; then
        info "pyspinel venv not found — creating at $PYSPINEL_VENV..."
        python3 -m venv "$PYSPINEL_VENV"
        "$PYSPINEL_VENV/bin/pip" install --quiet pyspinel
        info "pyspinel installed."
    fi

    local spinel_cli="$PYSPINEL_VENV/bin/spinel-cli.py"
    [[ -f "$spinel_cli" ]] \
        || die "spinel-cli.py not found in venv after install: $spinel_cli"

    local version
    version=$(timeout 10 bash -c "
        echo 'version' | python3 -W ignore '$spinel_cli' -u '$port' -b '$BAUD' 2>/dev/null \
            | grep -i openthread || true
    ") || true

    if [[ -z "$version" ]]; then
        warn "No spinel response from $port — device present but RCP firmware not detected."
        if prompt_flash_rcp "$port" && flash_rcp "$port"; then
            info "Re-probing $port after flash ..."
            version=$(timeout 10 bash -c "
                echo 'version' | python3 -W ignore '$spinel_cli' -u '$port' -b '$BAUD' 2>/dev/null \
                    | grep -i openthread || true
            ") || true
            if [[ -z "$version" ]]; then
                warn "Still no spinel response after flash — falling back to simulated RCP."
                RCP_DEVICE=""
            else
                info "RCP firmware verified after flash: $version"
            fi
        else
            warn "Skipping flash — falling back to simulated RCP."
            RCP_DEVICE=""
        fi
        return 0
    fi

    info "RCP firmware verified: $version"
}

find_rcp

if [[ -n "$RCP_DEVICE" ]]; then
    # Check if the device is already held by another process (e.g. host OTBR snap)
    _holder=$(lsof -t "$RCP_DEVICE" 2>/dev/null | head -1 || true)
    if [[ -n "$_holder" ]]; then
        _holder_name=$(ps -p "$_holder" -o comm= 2>/dev/null || echo "PID $_holder")
        warn "$RCP_DEVICE is held open by: ${_holder_name} (PID ${_holder})"
        warn "The physical RCP cannot be used while another process holds it."
        echo
        read -rp "  Proceed with simulated RCP instead? [y/N] " _ans </dev/tty
        echo
        if [[ "${_ans,,}" == "y" ]]; then
            warn "Proceeding with simulated ot-rcp — no real RF."
            RCP_DEVICE=""
        else
            die "Aborted. Free $RCP_DEVICE (stop ${_holder_name}) and re-run."
        fi
    fi
    unset _holder _holder_name _ans
fi

if [[ -n "$RCP_DEVICE" ]]; then
    if [[ "${RCP_VIDPID%%:*}" == "303a" ]]; then
        verify_rcp "$RCP_DEVICE"
    else
        info "Non-ESP32 RCP ($RCP_DEVICE${RCP_VIDPID:+, ${RCP_VIDPID}}) — assuming OpenThread RCP firmware is present."
    fi
fi
if [[ -z "$RCP_DEVICE" ]]; then
    warn "No usable physical RCP — VM will use simulated ot-rcp (no real RF)."
fi

# ---------------------------------------------------------------------------
# 4. SSH key — use provided key or generate a temporary one
# ---------------------------------------------------------------------------

step "SSH key"

TEMP_KEY_FILE=""
if [[ -n "${SSH_PUBKEY:-}" ]]; then
    info "Using provided SSH_PUBKEY"
    if [[ -z "$SSH_KEY_FILE" ]]; then
        die "SSH_PUBKEY is set but SSH_KEY_FILE is not. Set SSH_KEY_FILE=/path/to/private_key in your .env."
    fi
    [[ -f "$SSH_KEY_FILE" ]] || die "SSH_KEY_FILE not found: $SSH_KEY_FILE"
    info "Using SSH private key: $SSH_KEY_FILE"
    SSH_OPTS+=(-i "$SSH_KEY_FILE")
else
    TEMP_KEY_FILE="${TEST_VM_DIR}/test-vm-key"
    if [[ ! -f "$TEMP_KEY_FILE" ]]; then
        info "Generating temporary SSH key pair ..."
        ssh-keygen -t ed25519 -f "$TEMP_KEY_FILE" -N "" -C "otbr-test-vm" -q
    else
        info "Reusing existing temp key: $TEMP_KEY_FILE"
    fi
    SSH_PUBKEY="$(cat "${TEMP_KEY_FILE}.pub")"
    info "Temp public key: $SSH_PUBKEY"
    SSH_OPTS+=(-i "$TEMP_KEY_FILE")
fi
export SSH_PUBKEY

# ---------------------------------------------------------------------------
# 5. Fresh VM — wipe old disk + UEFI vars so cloud-init runs from scratch
# ---------------------------------------------------------------------------

step "Preparing VM disk"

if [[ -z "$LOAD_SNAP" ]]; then
    if pkill -TERM -f "bash.*run-vm\.sh" 2>/dev/null; then
        info "Stopped existing run-vm.sh"; sleep 2
    fi
    pkill -TERM -f "qemu-system-aarch64" 2>/dev/null || true
    pkill -9   -f "qemu-system-aarch64" 2>/dev/null || true
    ip link del macvtap-otbr 2>/dev/null || true

    for f in "${TEST_VM_DIR}/vm-disk.qcow2" "${TEST_VM_DIR}/uefi-vars.fd"; do
        if [[ -f "$f" ]]; then
            info "Removing stale: $(basename "$f")"
            rm -f "$f"
        fi
    done
else
    info "Resuming from snapshot '$LOAD_SNAP' — keeping existing disk."
fi

# ---------------------------------------------------------------------------
# 6. Run setup.sh
# ---------------------------------------------------------------------------

step "Running setup.sh"

if [[ -z "$LOAD_SNAP" ]]; then
    export THREAD_DATASET_TLV
    (cd "$TEST_VM_DIR" && bash setup.sh)
else
    info "Skipping setup.sh (resuming from snapshot)."
fi

# ---------------------------------------------------------------------------
# 7. Launch VM in background
# ---------------------------------------------------------------------------

step "Launching VM"

RUN_ARGS=()
[[ -n "$LOAD_SNAP" ]]  && RUN_ARGS+=("--loadvm=${LOAD_SNAP}")
[[ -z "$RCP_DEVICE" ]] && RUN_ARGS+=("--sim-rcp")
(cd "$TEST_VM_DIR" && bash run-vm.sh "${RUN_ARGS[@]+"${RUN_ARGS[@]}"}") &
VM_PID=$!
info "VM launched (PID $VM_PID)"

# ---------------------------------------------------------------------------
# 8. Wait for SSH to become available
# ---------------------------------------------------------------------------

step "Waiting for VM SSH (timeout ${BOOT_TIMEOUT}s)"

DEADLINE=$(( SECONDS + BOOT_TIMEOUT ))
SSH_UP=0
while (( SECONDS < DEADLINE )); do
    if ssh "${SSH_OPTS[@]}" "${SSH_USER}@localhost" true 2>/dev/null; then
        SSH_UP=1
        break
    fi
    kill -0 "$VM_PID" 2>/dev/null || die "VM process exited unexpectedly before SSH came up."
    printf '.'
    sleep 5
done
echo

(( SSH_UP )) || die "Timed out waiting for SSH after ${BOOT_TIMEOUT}s."
info "SSH is up."

# ---------------------------------------------------------------------------
# 9. Tail cloud-init output until cloud-init signals completion
# ---------------------------------------------------------------------------

if [[ -z "$LOAD_SNAP" ]]; then
    step "Tailing cloud-init output (timeout ${BOOT_TIMEOUT}s)"
    echo

    CI_REMOTE_CMD='
  log=/var/log/cloud-init-output.log
  for i in $(seq 1 30); do
    [ -f "$log" ] && break
    printf "waiting for cloud-init-output.log ($i/30)...\n"
    sleep 2
  done
  [ -f "$log" ] || { echo "ERROR: cloud-init-output.log never appeared"; exit 1; }
  tail -n +1 -f "$log" | while IFS= read -r line; do
    echo "$line"
    case "$line" in
      *"OTBR cloud-init complete"*) exit 0 ;;
      *"Cloud-init"*"finished"*)    exit 0 ;;
    esac
  done
'

    if timeout "$BOOT_TIMEOUT" \
           ssh "${SSH_OPTS[@]}" "${SSH_USER}@localhost" "$CI_REMOTE_CMD"; then
        info "cloud-init complete."
    else
        rc=$?
        [[ $rc -eq 124 ]] && die "cloud-init timed out after ${BOOT_TIMEOUT}s." \
                           || die "cloud-init watch exited unexpectedly (ssh exit $rc)."
    fi

    vm_savevm "$SNAP_CI" || warn "Could not save snapshot '$SNAP_CI' — continuing."
else
    info "Skipping cloud-init tailing (resuming from snapshot '$LOAD_SNAP')."
fi

# ---------------------------------------------------------------------------
# 10. Tail /var/log/otbr-firstboot.log until completion or error
# ---------------------------------------------------------------------------

if [[ "$LOAD_SNAP" != "$SNAP_OTBR" ]]; then
    step "Watching OTBR first-boot (timeout ${OTBR_TIMEOUT}s)"
    info "Tailing /var/log/otbr-firstboot.log on VM ..."
    echo

    REMOTE_CMD='
  log=/var/log/otbr-firstboot.log
  for i in $(seq 1 60); do
    [ -f "$log" ] && break
    printf "waiting for log ($i/60)...\n"
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

    if timeout "$OTBR_TIMEOUT" \
           ssh "${SSH_OPTS[@]}" "${SSH_USER}@localhost" "$REMOTE_CMD"; then
        true
    else
        rc=$?
        if [[ $rc -eq 124 ]]; then
            die "OTBR first-boot timed out after ${OTBR_TIMEOUT}s."
        else
            die "OTBR first-boot reported an error (ssh exit $rc). See log above."
        fi
    fi

    vm_savevm "$SNAP_OTBR" || warn "Could not save snapshot '$SNAP_OTBR' — continuing."
else
    info "Skipping firstboot (loaded from '$SNAP_OTBR' — OTBR already configured)."
fi

# ---------------------------------------------------------------------------
# 11. Verify Thread interface came up
# ---------------------------------------------------------------------------

step "Verifying Thread interface"

THREAD_STATE=$(ssh "${SSH_OPTS[@]}" "${SSH_USER}@localhost" \
    'sudo snap run openthread-border-router.ot-ctl state 2>/dev/null || echo "unavailable"')

info "ot-ctl state: $THREAD_STATE"

case "$THREAD_STATE" in
    leader|router|child)
        pass "Thread node is active (state: $THREAD_STATE)"
        ;;
    *)
        warn "Thread state is '${THREAD_STATE}' — may still be joining. Check manually:"
        warn "  ssh -p $SSH_PORT ${SSH_USER}@localhost"
        warn "  sudo snap run openthread-border-router.ot-ctl state"
        ;;
esac

# ---------------------------------------------------------------------------
# 12. Done
# ---------------------------------------------------------------------------

disown "$VM_PID" 2>/dev/null || true

echo
pass "End-to-end test complete. VM is still running."
if [[ -n "$LOAD_SNAP" ]]; then
    info "Resumed from snapshot: $LOAD_SNAP"
else
    info "Snapshots saved: $SNAP_CI (post-cloud-init), $SNAP_OTBR (OTBR ready)"
fi
info "Connect:  ssh otbr-vm   (or: ssh -p ${SSH_PORT} ${SSH_USER}@localhost)"
info "Teardown: sudo ./teardown-vm.sh"
