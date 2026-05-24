#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG="$SCRIPT_DIR/dev-piotbr.log"
HOSTNAME_FLAG="dev-piotbr"
DEVICE="/dev/sdd"
YES=0

for _arg in "$@"; do
    case "$_arg" in
        -y) YES=1 ;;
        --device=*) DEVICE="${_arg#--device=}" ;;
        --hostname=*) HOSTNAME_FLAG="${_arg#--hostname=}" ;;
        -h|--help)
            echo "Usage: $0 [-y] [--device=/dev/sdX] [--hostname=NAME]"
            echo "  -y            Skip prompt; sleep 2m with audible alert instead"
            echo "  --device=     Block device to flash (default: $DEVICE)"
            echo "  --hostname=   Target hostname (default: $HOSTNAME_FLAG)"
            exit 0
            ;;
    esac
done

# Unified log: all output goes to terminal AND dev-piotbr.log (truncated at start)
exec > >(tee "$LOG") 2>&1

echo "=== run_rpiotbr_cycle.sh $(date '+%Y-%m-%d %H:%M:%S') ==="
echo "Device: $DEVICE  Hostname: $HOSTNAME_FLAG  Skip-prompt: $YES"
echo ""

# ---------------------------------------------------------------------------
# Phase 1: Flash
# ---------------------------------------------------------------------------
echo "--- Phase 1: Flash ---"
# Source otbrstack.sh to get the otbrstack() function
# shellcheck source=otbrstack.sh
source "$SCRIPT_DIR/otbrstack.sh"

otbrstack flash -f -y --hostname="$HOSTNAME_FLAG" "$DEVICE"

echo ""
echo "--- Flash complete ---"
echo ""

# ---------------------------------------------------------------------------
# Phase 2: Card transfer
# ---------------------------------------------------------------------------
beep_notify() {
    # Try progressively simpler audio methods
    for _i in 1 2 3; do
        printf '\a'
        sleep 0.4
    done
    if command -v paplay &>/dev/null; then
        paplay /usr/share/sounds/freedesktop/stereo/complete.oga 2>/dev/null || true
    elif command -v aplay &>/dev/null; then
        aplay /usr/share/sounds/freedesktop/stereo/complete.oga 2>/dev/null || true
    fi
    if command -v spd-say &>/dev/null; then
        spd-say "Flash complete. Transfer the SD card now." 2>/dev/null || true
    fi
}

if [[ "$YES" -eq 1 ]]; then
    beep_notify
    echo "Waiting 2 minutes for card transfer. Insert card into Pi and power on."
    for _s in $(seq 120 -1 1); do
        printf "\r  %3ds remaining..." "$_s"
        sleep 1
    done
    printf "\r  Done.                    \n"
    # Extra beep to signal countdown finished
    for _i in 1 2; do printf '\a'; sleep 0.3; done
    command -v spd-say &>/dev/null && spd-say "Time's up. Waiting for SSH." 2>/dev/null || true
else
    echo "Remove the SD card from the reader, insert it into the Pi, and power it on."
    read -rp "Press Enter when the Pi is booting... "
fi

echo ""

# ---------------------------------------------------------------------------
# Phase 3: SSH probe
# ---------------------------------------------------------------------------
echo "--- Phase 3: Waiting for SSH on $HOSTNAME_FLAG:22 ---"

_ssh_ready=0
if command -v wait-for-it &>/dev/null; then
    if wait-for-it --timeout=300 "$HOSTNAME_FLAG:22"; then
        _ssh_ready=1
    fi
else
    echo "wait-for-it not found; falling back to nc probe loop (5 min timeout)"
    _deadline=$(( $(date +%s) + 300 ))
    while [[ $(date +%s) -lt $_deadline ]]; do
        if nc -z -w3 "$HOSTNAME_FLAG" 22 2>/dev/null; then
            _ssh_ready=1
            break
        fi
        printf '.'
        sleep 5
    done
    echo ""
fi

if [[ "$_ssh_ready" -eq 0 ]]; then
    echo "ERROR: SSH on $HOSTNAME_FLAG:22 did not become available within 5 minutes." >&2
    exit 1
fi

echo "SSH is up on $HOSTNAME_FLAG."
echo ""

# ---------------------------------------------------------------------------
# Phase 4: Stream logs
# ---------------------------------------------------------------------------
echo "--- Phase 4: Streaming logs from $HOSTNAME_FLAG ---"
otbrstack logs -f "$HOSTNAME_FLAG"
