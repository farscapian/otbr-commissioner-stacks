#!/usr/bin/env bash
# =============================================================================
# test-vm/setup.sh
#
# One-time setup: install deps, download Ubuntu 24.04 arm64 cloud image,
# create a CoW VM disk, and build the cloud-init seed ISO.
#
# USAGE
#   export THREAD_DATASET_TLV="0e080000000000010000..."
#   # Optional: provide your SSH public key for passwordless login
#   export SSH_PUBKEY="$(cat ~/.ssh/id_ed25519.pub)"
#   ./setup.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

THREAD_DATASET_TLV="${THREAD_DATASET_TLV:?'Set THREAD_DATASET_TLV before running'}"
SSH_PUBKEY="${SSH_PUBKEY:-}"

RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'; NC='\033[0m'
info() { echo -e "${GRN}[INFO]${NC}  $*"; }
warn() { echo -e "${YLW}[WARN]${NC}  $*"; }
die()  { echo -e "${RED}[ERR ]${NC}  $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1. Check host dependencies
# ---------------------------------------------------------------------------

REQUIRED_CMDS=(qemu-system-aarch64 qemu-img cloud-localds envsubst)
MISSING=()
for cmd in "${REQUIRED_CMDS[@]}"; do
    command -v "$cmd" &>/dev/null || MISSING+=("$cmd")
done
if [[ ! -f /usr/share/qemu-efi-aarch64/QEMU_EFI.fd ]]; then
    MISSING+=(qemu-efi-aarch64)
fi

if [[ ${#MISSING[@]} -gt 0 ]]; then
    warn "Missing dependencies: ${MISSING[*]}"
    warn "Run the top-level setup.sh first:"
    warn "  ${PROJECT_ROOT}/setup.sh"
    exit 1
fi
info "Host dependencies satisfied."

# ---------------------------------------------------------------------------
# 2. Download Ubuntu 24.04 Server arm64 cloud image
# ---------------------------------------------------------------------------

mkdir -p "${PROJECT_ROOT}/cache/ubuntu/server"
BASE_IMAGE="${PROJECT_ROOT}/cache/ubuntu/server/noble-server-cloudimg-arm64.img"
BASE_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-arm64.img"

if [[ ! -f "$BASE_IMAGE" ]]; then
    info "Downloading Ubuntu 24.04 arm64 cloud image ..."
    curl -L --progress-bar -o "$BASE_IMAGE" "$BASE_URL"
else
    info "Base image already present: $BASE_IMAGE"
fi

# ---------------------------------------------------------------------------
# 3. Create CoW VM disk backed by the base image
# ---------------------------------------------------------------------------

VM_DISK="${SCRIPT_DIR}/vm-disk.qcow2"

if [[ ! -f "$VM_DISK" ]]; then
    info "Creating 12 GiB CoW VM disk ..."
    qemu-img create -f qcow2 -b "$BASE_IMAGE" -F qcow2 "$VM_DISK" 12G
else
    info "VM disk already exists: $VM_DISK"
    warn "To rebuild from scratch: rm ${VM_DISK} and re-run setup.sh"
fi

# ---------------------------------------------------------------------------
# 4. Build cloud-init seed ISO
# ---------------------------------------------------------------------------

# Inject THREAD_DATASET_TLV (and only that variable) into the template.
# All other ${...} expressions in the template are left untouched.
info "Generating user-data.yaml from template ..."
THREAD_DATASET_TLV="$THREAD_DATASET_TLV" \
    envsubst '${THREAD_DATASET_TLV} ${SSH_PUBKEY}' \
    < "${SCRIPT_DIR}/user-data.yaml.tpl" \
    > "${SCRIPT_DIR}/user-data.yaml"

# Optionally inject SSH public key for passwordless login
if [[ -n "$SSH_PUBKEY" ]]; then
    info "Injecting SSH public key ..."
    # Append ssh_authorized_keys block if not already present
    if ! grep -q 'ssh_authorized_keys' "${SCRIPT_DIR}/user-data.yaml"; then
        cat >> "${SCRIPT_DIR}/user-data.yaml" <<EOF

ssh_authorized_keys:
  - ${SSH_PUBKEY}
EOF
    fi
fi

info "Building seed ISO ..."
cloud-localds "${SCRIPT_DIR}/seed.iso" \
    "${SCRIPT_DIR}/user-data.yaml" \
    "${SCRIPT_DIR}/meta-data"

# ---------------------------------------------------------------------------
# 4b. Download snap for offline install
# ---------------------------------------------------------------------------
# Cached in snap-cache/ and mounted into the VM by run-vm.sh via virtio-9p.
# The firstboot script installs from the cache; falls back to the snap store.

SNAP_CACHE="${PROJECT_ROOT}/cache/snap"
mkdir -p "$SNAP_CACHE"
SNAP_NAME="openthread-border-router"

if compgen -G "${SNAP_CACHE}/${SNAP_NAME}_*.snap" > /dev/null 2>&1; then
    info "Snap cache already present: $(ls ${SNAP_CACHE}/${SNAP_NAME}_*.snap | head -1)"
else
    info "Downloading ${SNAP_NAME} snap for offline install ..."
    if snap download "$SNAP_NAME" --channel=latest/edge --target-directory="$SNAP_CACHE"; then
        info "Snap cached in ${SNAP_CACHE}/"
    else
        warn "snap download failed — VM will install ${SNAP_NAME} from the store on first boot."
        warn "This is non-fatal; provisioning continues."
    fi
fi

# ---------------------------------------------------------------------------
# 5. Add / update 'piotbrvm' SSH Host entry (management NIC, localhost:2222)
# ---------------------------------------------------------------------------

SSH_CONFIG="${HOME}/.ssh/config"
mkdir -p "${HOME}/.ssh"
chmod 700 "${HOME}/.ssh"

SSH_BLOCK="Host piotbrvm
    HostName localhost
    Port 2222
    User ubuntu
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null"

if grep -q "^Host piotbrvm" "$SSH_CONFIG" 2>/dev/null; then
    info "SSH Host 'piotbrvm' already present in ${SSH_CONFIG} — skipping."
else
    info "Adding SSH Host 'piotbrvm' to ${SSH_CONFIG} ..."
    {
        echo ""
        echo "$SSH_BLOCK"
    } >> "$SSH_CONFIG"
    chmod 600 "$SSH_CONFIG"
    info "Done. You can now use: ssh piotbrvm"
fi

info "============================================================"
info " Setup complete."
info ""
info " To start the VM:"
info "   cd test-vm && ./run-vm.sh"
info ""
info " SSH (once booted):"
info "   ssh piotbrvm   (via management NIC, localhost:2222)"
info ""
info " Watch first-boot OTBR setup:"
info "   ssh piotbrvm tail -f /var/log/otbr-firstboot.log"
info "============================================================"
