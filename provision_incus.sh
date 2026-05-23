#!/usr/bin/env bash
# =============================================================================
# provision_incus.sh
#
# Provision an Incus VM or system container running the OTBR first-boot
# sequence. Supports native x86_64 and QEMU-emulated arm64.
#
# USAGE
#   sudo ./provision_incus.sh [options]
#
# OPTIONS
#   --vm              Launch an Incus VM (default)
#   --container       Launch a system container instead of a VM
#   --arch=arm64      Use arm64 image (QEMU-emulated; default: amd64)
#   --arm64           Shorthand for --arch=arm64
#   --name=NAME       Instance name (default: otbrvm64 / otbrarm64 / otbr-ct)
#   (env is loaded by otbrstack before invoking this script)
#   --reprovision     Delete existing instance and provision from scratch
#
# PREREQUISITES
#   incus must be installed and the current user must be in the incus group
#   (or run as root).  Run test-vm/setup.sh first to populate cache/snap/ and
#   cache/ot-rcp-sim/ — provision_incus.sh reuses those caches.
#
# FILE INJECTION
#   After the instance starts, snap cache (.snap + .assert) and sim binary are
#   pushed via `incus file push` into /root/snap-cache/ and /root/ot-rcp-sim/.
#   Disk shares are not used: the Incus daemon runs as a non-root user and
#   cannot stat paths under /home, so source-path validation always fails.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
TEST_VM_DIR="${SCRIPT_DIR}/test-vm"
PYSPINEL_VENV="${SCRIPT_DIR}/artifacts/pyspinel-venv"
INCUS_DIR="${SCRIPT_DIR}/incus"
BAUD=460800

# ---------------------------------------------------------------------------
# Arg parsing
# ---------------------------------------------------------------------------

INSTANCE_MODE="vm"
INSTANCE_ARCH="amd64"
INSTANCE_NAME=""
REPROVISION=0

for _arg in "$@"; do
    case "$_arg" in
        --vm)           INSTANCE_MODE="vm" ;;
        --container)    INSTANCE_MODE="container" ;;
        --arm64)        INSTANCE_ARCH="arm64" ;;
        --arch=*)       INSTANCE_ARCH="${_arg#--arch=}" ;;
        --name=*)       INSTANCE_NAME="${_arg#--name=}" ;;
        --reprovision)  REPROVISION=1 ;;
        *) echo "Unknown arg: $_arg" >&2; exit 1 ;;
    esac
done

if [[ -z "$INSTANCE_NAME" ]]; then
    if [[ "$INSTANCE_MODE" == "vm" && "$INSTANCE_ARCH" == "arm64" ]]; then
        INSTANCE_NAME="otbrarm64"
    elif [[ "$INSTANCE_MODE" == "vm" ]]; then
        INSTANCE_NAME="otbrvm64"
    else
        INSTANCE_NAME="otbr-ct"
    fi
fi

# All incus instance-level commands use the local: remote explicitly.
INST="local:${INSTANCE_NAME}"

# Env is loaded by otbrstack before invoking this script.
[[ -n "${THREAD_DATASET_TLV:-}" ]] || { echo "[ERROR] THREAD_DATASET_TLV not set — run via 'otbrstack vm'" >&2; exit 1; }
unset _arg

BOOT_TIMEOUT="${BOOT_TIMEOUT:-300}"
OTBR_TIMEOUT="${OTBR_TIMEOUT:-600}"
THREAD_DATASET_TLV="${THREAD_DATASET_TLV:-}"
IDF_PATH="${IDF_PATH:-}"

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

build_and_flash_rcp() {
    local port="$1"
    local cached_bin="${SCRIPT_DIR}/cache/esp32/rcp/esp_ot_rcp.bin"

    # ------------------------------------------------------------------
    # 1. Ensure ESP-IDF is available; track whether it changed.
    #    Priority: idf.py in PATH > IDF_PATH env var > cache/esp-idf clone.
    # ------------------------------------------------------------------
    local _idf_path=""
    local _src_changed=0

    if command -v idf.py &>/dev/null; then
        _idf_path="${IDF_PATH:-}"
    elif [[ -n "${IDF_PATH:-}" ]]; then
        _idf_path="$IDF_PATH"
        [[ -f "${_idf_path}/export.sh" ]] \
            || die "IDF_PATH set but ${_idf_path}/export.sh not found."
    else
        _idf_path="${SCRIPT_DIR}/cache/esp-idf"
        if [[ ! -d "$_idf_path" ]]; then
            info "Cloning ESP-IDF into cache/esp-idf ..."
            git -c advice.detachedHead=false clone --depth 1 \
                --recurse-submodules --shallow-submodules \
                https://github.com/espressif/esp-idf.git "$_idf_path"
            "${_idf_path}/install.sh" esp32c6
            _src_changed=1
        else
            local _idf_hash_before
            _idf_hash_before=$(git -C "$_idf_path" rev-parse HEAD)
            info "Updating ESP-IDF ..."
            git -C "$_idf_path" fetch --depth 1 origin
            git -C "$_idf_path" reset --hard origin/HEAD
            git -C "$_idf_path" submodule update --init --recursive
            "${_idf_path}/install.sh" esp32c6
            local _idf_hash_after
            _idf_hash_after=$(git -C "$_idf_path" rev-parse HEAD)
            if [[ "$_idf_hash_before" != "$_idf_hash_after" ]]; then
                info "ESP-IDF updated: ${_idf_hash_before:0:8} → ${_idf_hash_after:0:8}"
                _src_changed=1
            else
                info "ESP-IDF already at latest (${_idf_hash_after:0:8})."
            fi
        fi
    fi

    # ot_rcp example is bundled with ESP-IDF at examples/openthread/ot_rcp.
    local _resolved_idf_path="${_idf_path:-${IDF_PATH:-}}"
    local ot_rcp_dir="${_resolved_idf_path}/examples/openthread/ot_rcp"

    [[ -d "$ot_rcp_dir" ]] \
        || die "ot_rcp example not found at: $ot_rcp_dir — check IDF_PATH."

    # ------------------------------------------------------------------
    # 2. Write required sdkconfig overrides.
    # ------------------------------------------------------------------
    cat > "${ot_rcp_dir}/sdkconfig.defaults.otbrstack" <<'SDKEOF'
# Required for ESP32-C6 USB JTAG RCP (generated by otbrstack)
CONFIG_OPENTHREAD_RCP_USB_SERIAL_JTAG=y
CONFIG_OPENTHREAD_RADIO=y
CONFIG_OPENTHREAD_RADIO_NATIVE=y
CONFIG_ESP_COEX_SW_COEXIST_ENABLE=n
SDKEOF

    # ------------------------------------------------------------------
    # 3. Build only if source changed or no prior build exists.
    # ------------------------------------------------------------------
    local _built="${ot_rcp_dir}/build/esp_ot_rcp.bin"
    if [[ "$_src_changed" -eq 1 || ! -f "$_built" ]]; then
        info "Building ot_rcp for esp32c6 ..."
        (
            set -euo pipefail
            [[ -n "${_idf_path:-}" ]] && source "${_idf_path}/export.sh" > /dev/null
            set -euo pipefail   # re-assert after export.sh may have cleared it
            cd "$ot_rcp_dir"
            export SDKCONFIG_DEFAULTS="sdkconfig.defaults;sdkconfig.defaults.otbrstack"
            idf.py set-target esp32c6
            idf.py build
        )
    else
        info "Source unchanged — skipping rebuild."
    fi

    [[ -f "$_built" ]] || die "Build failed — ${_built} not found."

    # ------------------------------------------------------------------
    # 4. Flash only if the built binary differs from the cached copy.
    #    The cached copy reflects what was last flashed to a device.
    # ------------------------------------------------------------------
    local _do_flash=0
    if [[ ! -f "$cached_bin" ]]; then
        _do_flash=1
    else
        local _sum_built _sum_cached
        _sum_built=$(sha256sum "$_built" | awk '{print $1}')
        _sum_cached=$(sha256sum "$cached_bin" | awk '{print $1}')
        if [[ "$_sum_built" != "$_sum_cached" ]]; then
            info "Firmware changed — reflashing device."
            _do_flash=1
        else
            info "Device already running latest firmware — no flash needed."
        fi
    fi

    if [[ "$_do_flash" -eq 1 ]]; then
        info "Flashing $port (bootloader + partition table + app) ..."
        (
            set -euo pipefail
            [[ -n "${_idf_path:-}" ]] && source "${_idf_path}/export.sh" > /dev/null
            set -euo pipefail
            cd "$ot_rcp_dir"
            idf.py -p "$port" flash
        )
        mkdir -p "${SCRIPT_DIR}/cache/esp32/rcp"
        cp "$_built" "$cached_bin"
        info "Flash complete — waiting for USB re-enumeration ..."
        sleep 8
    fi
}

flash_rcp() {
    build_and_flash_rcp "$1"
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

ensure_pyspinel_venv() {
    if "${PYSPINEL_VENV}/bin/python3" -c "import serial" 2>/dev/null; then
        return 0
    fi
    info "Setting up pyspinel venv at ${PYSPINEL_VENV} ..."
    rm -rf "$PYSPINEL_VENV"
    mkdir -p "$(dirname "$PYSPINEL_VENV")"
    python3 -m venv "$PYSPINEL_VENV"
    "$PYSPINEL_VENV/bin/pip" install --quiet pyspinel
}

# Delegates to scripts/verify_rcp.py — the single canonical probe.
_probe_rcp() {
    local port="$1"
    ensure_pyspinel_venv
    "${PYSPINEL_VENV}/bin/python3" "${SCRIPT_DIR}/scripts/verify_rcp.py" "$port"
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

    if _probe_rcp "$port"; then
        info "RCP firmware verified."
        return 0
    fi

    warn "No spinel response from $port — RCP firmware not detected."
    if prompt_flash_rcp "$port" && flash_rcp "$port"; then
        if _probe_rcp "$port"; then
            info "RCP firmware verified after flash."
        else
            warn "Still no spinel response — falling back to sim."
            RCP_DEVICE=""
        fi
    else
        warn "Skipping flash — using sim."
        RCP_DEVICE=""
    fi
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
info "Mode: $INSTANCE_MODE  Arch: $INSTANCE_ARCH  Name: $INSTANCE_NAME"
info "BOOT_TIMEOUT=${BOOT_TIMEOUT}s  OTBR_TIMEOUT=${OTBR_TIMEOUT}s"

# Scope all incus commands to this project (INCUS_PROJECT is honoured by the CLI)
INCUS_PROJECT="${INCUS_PROJECT:-dev}"
export INCUS_PROJECT
info "Incus project: $INCUS_PROJECT"

# ---------------------------------------------------------------------------
# 2. Host dependencies
# ---------------------------------------------------------------------------

step "Checking host dependencies"

command -v incus   &>/dev/null || die "incus not found. Install it: https://linuxcontainers.org/incus/docs/main/installing/"

# Ensure the target project exists (unset INCUS_PROJECT so this is not self-referential)
if ! INCUS_PROJECT="" incus project show "${INCUS_PROJECT}" &>/dev/null; then
    info "Creating Incus project '${INCUS_PROJECT}' ..."
    INCUS_PROJECT="" incus project create "${INCUS_PROJECT}" \
        -c features.images=false \
        -c features.profiles=false
    info "Project '${INCUS_PROJECT}' created (shares images + profiles with default)."
fi

command -v curl    &>/dev/null || die "curl not found"
command -v python3 &>/dev/null || die "python3 not found"
if [[ -n "${HTTP_PROXY:-}" ]]; then
    echo "Acquire::http::Proxy \"${HTTP_PROXY}\";" \
        | sudo tee /etc/apt/apt.conf.d/90apt-cache >/dev/null
fi
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
# 4. Sim binary — build from OpenThread source if not cached
#    The simulation ot-rcp and ot-cli binaries are Linux-native executables
#    built from the OpenThread repository (cloned to cache/openthread/).
#    Both are produced by a single cmake simulation build; ot-rcp is used
#    here, and ot-cli is picked up by tests/test_otbr_vm.sh.
# ---------------------------------------------------------------------------

SIM_RCP_DIR="${SCRIPT_DIR}/cache/ot-rcp-sim"
SIM_RCP_BIN_PATH="${SIM_RCP_DIR}/ot-rcp"
_OT_SRC="${SCRIPT_DIR}/cache/openthread"

if [[ -z "${RCP_DEVICE:-}" ]]; then
    step "Locating sim RCP binary"

    if [[ -f "$SIM_RCP_BIN_PATH" ]]; then
        chmod +x "$SIM_RCP_BIN_PATH"
        info "Cached sim binary: $SIM_RCP_BIN_PATH"
    else
        info "sim binary not found — building from OpenThread source ..."
        if [[ ! -d "$_OT_SRC" ]]; then
            info "Cloning OpenThread into cache/openthread ..."
            git -c advice.detachedHead=false clone --depth 1 \
                https://github.com/openthread/openthread.git "$_OT_SRC"
        fi
        (
            set -euo pipefail
            cd "$_OT_SRC"
            ./script/cmake-build simulation
        )
        mkdir -p "$SIM_RCP_DIR"
        cp "${_OT_SRC}/build/simulation/examples/apps/ncp/ot-rcp" "$SIM_RCP_BIN_PATH"
        chmod +x "$SIM_RCP_BIN_PATH"
        # ot-cli is built alongside ot-rcp; cache it for the test suite.
        _ot_cli_built="${_OT_SRC}/build/simulation/examples/apps/cli/ot-cli"
        [[ -f "$_ot_cli_built" ]] && cp "$_ot_cli_built" "${SIM_RCP_DIR}/ot-cli" \
            && chmod +x "${SIM_RCP_DIR}/ot-cli" || true
        unset _ot_cli_built
        info "Sim binaries built: $SIM_RCP_BIN_PATH"
    fi
fi
unset _OT_SRC

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
    snap download "$SNAP_NAME" --channel=latest/edge --target-directory="$SNAP_CACHE"
    info "Snap cached."
fi

# ---------------------------------------------------------------------------
# 6. Reprovision — delete existing instance
# ---------------------------------------------------------------------------

if [[ "$REPROVISION" -eq 1 ]]; then
    step "Reprovisioning — deleting existing instance"
    if incus info "$INST" &>/dev/null; then
        incus delete "$INST" --force
        info "Deleted instance: $INSTANCE_NAME"
    else
        info "No existing instance named $INSTANCE_NAME"
    fi
elif incus info "$INST" &>/dev/null; then
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

_TS="$(date +%Y%m%d-%H%M%S)"
_ARTIFACT_SUBDIR="$([[ $INSTANCE_ARCH == arm64 ]] && echo arm64vm || echo x64vm)"
_ARTIFACT_DIR="${SCRIPT_DIR}/artifacts/${_ARTIFACT_SUBDIR}/${INSTANCE_NAME}/${_TS}"
mkdir -p "$_ARTIFACT_DIR"
echo "$USER_DATA" > "${_ARTIFACT_DIR}/user-data.yaml"
info "User-data saved to ${_ARTIFACT_DIR}/user-data.yaml ($(echo "$USER_DATA" | wc -l) lines)"
unset _TS _ARTIFACT_SUBDIR _ARTIFACT_DIR

# ---------------------------------------------------------------------------
# 8. Init instance
# ---------------------------------------------------------------------------

step "Creating Incus $INSTANCE_MODE ($INSTANCE_ARCH): $INSTANCE_NAME"

TYPE_FLAG="$([[ $INSTANCE_MODE == vm ]] && echo "--vm" || echo "")"

if [[ "$INSTANCE_ARCH" == "arm64" ]]; then
    INCUS_IMAGE="ubuntu:26.04/arm64"
else
    INCUS_IMAGE="ubuntu:26.04"
fi

# shellcheck disable=SC2086
incus init "$INCUS_IMAGE" "$INST" $TYPE_FLAG \
    --config "user.user-data=${USER_DATA}"

# security.nesting lets snapd manage systemd services inside a container
[[ "$INSTANCE_MODE" == "container" ]] && \
    incus config set "$INST" security.nesting=true

# ---------------------------------------------------------------------------
# 9. Attach RCP device (real hardware only)
# ---------------------------------------------------------------------------

if [[ -n "${RCP_DEVICE:-}" ]]; then
    step "Attaching RCP device: $RCP_DEVICE"
    if [[ "$INSTANCE_MODE" == "vm" ]]; then
        # VM: USB passthrough by vendor:product ID
        [[ -n "$RCP_VID" && -n "$RCP_PID" ]] \
            || die "Cannot determine USB VID:PID for $RCP_DEVICE — cannot pass through to VM."
        incus config device add "$INST" rcp usb \
            vendorid="$RCP_VID" productid="$RCP_PID"
        info "USB passthrough: ${RCP_VID}:${RCP_PID}"
    else
        # Container: character device bind
        incus config device add "$INST" rcp unix-char \
            source="$RCP_DEVICE" path="$RCP_DEVICE"
        info "Character device: $RCP_DEVICE"
    fi
fi

# ---------------------------------------------------------------------------
# 10. Start instance
# ---------------------------------------------------------------------------

step "Starting instance"
incus start "$INST"
info "Instance started."

# ---------------------------------------------------------------------------
# 11. Push snap cache + sim binary into running instance
# ---------------------------------------------------------------------------

step "Injecting snap cache and sim binary (timeout ${BOOT_TIMEOUT}s)"

# The Incus daemon runs as a non-root user and cannot stat paths under /home.
# incus file push transfers files through the Incus API, bypassing that limit.

DEADLINE=$(( SECONDS + BOOT_TIMEOUT ))
while (( SECONDS < DEADLINE )); do
    incus exec "$INST" -- true 2>/dev/null && break || sleep 2
done
(( SECONDS < DEADLINE )) || die "Timed out waiting for instance exec to become available."

incus exec "$INST" -- mkdir -p /root/snap-cache /root/ot-rcp-sim

_snap_pushed=0
for _f in "${SNAP_CACHE}"/*.snap "${SNAP_CACHE}"/*.assert; do
    [[ -f "$_f" ]] || continue
    incus file push "$_f" "${INST}/root/snap-cache/$(basename "$_f")"
    _snap_pushed=1
done
[[ "$_snap_pushed" -eq 1 ]] && info "Snap cache pushed to instance." \
                             || warn "No snap files found — firstboot will install from store."
unset _f _snap_pushed

if [[ -z "${RCP_DEVICE:-}" && -f "${SIM_RCP_BIN_PATH}" ]]; then
    incus file push --mode 0755 "${SIM_RCP_BIN_PATH}" \
        "${INST}/root/ot-rcp-sim/ot-rcp"
    info "Sim binary pushed to /root/ot-rcp-sim/ot-rcp"
fi

# ---------------------------------------------------------------------------
# 12. Wait for cloud-init to complete
# ---------------------------------------------------------------------------

step "Waiting for cloud-init (timeout ${BOOT_TIMEOUT}s)"

if timeout "$BOOT_TIMEOUT" \
        incus exec "$INST" -- cloud-init status --wait --long; then
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

if timeout "$OTBR_TIMEOUT" incus exec "$INST" -- bash -c "$REMOTE_CMD"; then
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

THREAD_STATE=$(incus exec "$INST" -- \
    snap run openthread-border-router.ot-ctl state 2>/dev/null || echo "unavailable")

info "ot-ctl state: $THREAD_STATE"

case "$THREAD_STATE" in
    leader|router|child)
        pass "Thread node is active (state: $THREAD_STATE)"
        ;;
    *)
        warn "Thread state is '${THREAD_STATE}' — may still be joining."
        warn "Check manually: incus exec local:$INSTANCE_NAME -- snap run openthread-border-router.ot-ctl state"
        ;;
esac

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------

echo
pass "Provisioning complete. Instance is running."
info "Shell:    incus shell local:$INSTANCE_NAME"
info "Log:      incus exec local:$INSTANCE_NAME -- tail -f /var/log/otbr-firstboot.log"
info "ot-ctl:   incus exec local:$INSTANCE_NAME -- snap run openthread-border-router.ot-ctl state"
info "Teardown: incus delete local:$INSTANCE_NAME --force"
