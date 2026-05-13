#!/usr/bin/env bash
# Tear down the OTBR test VM started by provision_piotbrvm.sh.
# Kills run-vm.sh (which cascades to QEMU via its own trap), then removes
# the macvtap interface if it survived.

set -euo pipefail

RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'; NC='\033[0m'
info() { echo -e "${GRN}[INFO]${NC}  $*"; }
warn() { echo -e "${YLW}[WARN]${NC}  $*"; }

found=0

if pkill -TERM -f "bash.*run-vm\.sh" 2>/dev/null; then
    info "Sent SIGTERM to run-vm.sh (QEMU and macvtap will be cleaned up by its trap)"
    sleep 2
    found=1
fi

# Belt-and-suspenders: kill QEMU directly if it outlived run-vm.sh
if pkill -TERM -f "qemu-system-aarch64" 2>/dev/null; then
    info "Sent SIGTERM to qemu-system-aarch64"
    sleep 1
    found=1
fi
pkill -9 -f "qemu-system-aarch64" 2>/dev/null || true

# Remove macvtap in case run-vm.sh's cleanup trap didn't fire
if ip link show macvtap-otbr &>/dev/null 2>&1; then
    sudo ip link del macvtap-otbr
    info "Removed macvtap-otbr"
fi

if [[ $found -eq 1 ]]; then
    info "VM torn down."
else
    warn "No running VM found."
fi
