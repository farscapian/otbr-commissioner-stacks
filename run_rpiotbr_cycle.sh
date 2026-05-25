#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOSTNAME_FLAG="dev-piotbr"
DEVICE=""   # auto-detected from SD_CARD_PATHS unless --device= is given
YES=0
ENV_FILE="$SCRIPT_DIR/.env"

for _arg in "$@"; do
    case "$_arg" in
        -y) YES=1 ;;
        --device=*) DEVICE="${_arg#--device=}" ;;
        --hostname=*) HOSTNAME_FLAG="${_arg#--hostname=}" ;;
        --env-file=*) ENV_FILE="${_arg#--env-file=}" ;;
        -h|--help)
            echo "Usage: $0 [-y] [--device=/dev/sdX] [--hostname=NAME] [--env-file=FILE]"
            echo "  -y             Skip prompt; sleep 2m with audible alert instead"
            echo "  --device=      Block device to flash (overrides auto-detect)"
            echo "  --hostname=    Target hostname (default: $HOSTNAME_FLAG)"
            echo "  --env-file=    Env file to source (default: .env)"
            exit 0
            ;;
    esac
done

# Source env for SD_CARD_PATHS and other vars before device detection
if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$ENV_FILE"
fi

# ---------------------------------------------------------------------------
# Device detection: match block device by USB port path (ID_PATH)
# ---------------------------------------------------------------------------
find_flash_device() {
    local allowed="${SD_CARD_PATHS:-}"
    if [[ -z "$allowed" ]]; then
        return 1
    fi
    while IFS= read -r dev; do
        local id_path
        id_path=$(udevadm info "/dev/$dev" 2>/dev/null \
            | grep -oP '(?<=E: ID_PATH=)\S+' || true)
        [[ -z "$id_path" ]] && continue
        for entry in $allowed; do
            if [[ "$id_path" == "$entry" ]]; then
                echo "/dev/$dev"
                return 0
            fi
        done
    done < <(lsblk -dno NAME | grep -E '^sd')
    return 1
}

if [[ -z "$DEVICE" ]]; then
    if ! DEVICE=$(find_flash_device); then
        echo "ERROR: No whitelisted SD card reader found." >&2
        echo "  Set SD_CARD_PATHS in your env file, or pass --device=/dev/sdX." >&2
        echo "" >&2
        echo "  To find your reader's path (with card inserted):" >&2
        echo "    udevadm info /dev/sdX | grep ^E:.*ID_PATH=" >&2
        exit 1
    fi
    _dev_info=$(lsblk -dno MODEL,SIZE "$DEVICE" 2>/dev/null | xargs || true)
    echo "Auto-detected flash device: $DEVICE  ($_dev_info)"
    if [[ "$YES" -eq 0 ]]; then
        read -rp "Flash $DEVICE? [y/N] " _confirm
        [[ "$_confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
    fi
fi

# Unified log: all output goes to terminal AND logs/<host>/cycle.log (fresh each run)
LOG="$SCRIPT_DIR/logs/${HOSTNAME_FLAG}/cycle.log"
mkdir -p "$(dirname "$LOG")"
exec > >(tee "$LOG") 2>&1

_git_info=$(git -C "$SCRIPT_DIR" log -1 --oneline 2>/dev/null || echo "no git")
echo "=== run_rpiotbr_cycle.sh $(date '+%Y-%m-%d %H:%M:%S') — ${_git_info} ==="
echo "Device: $DEVICE  Hostname: $HOSTNAME_FLAG  Skip-prompt: $YES"
unset _git_info
echo ""

# ---------------------------------------------------------------------------
# Phase 1: Flash
# ---------------------------------------------------------------------------
echo "--- Phase 1: Flash ---"
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
    for _i in 1 2 3; do
        printf '\a'
        sleep 0.4
    done
    if command -v paplay &>/dev/null; then
        paplay /usr/share/sounds/freedesktop/stereo/complete.oga 2>/dev/null || true
    elif command -v aplay &>/dev/null; then
        aplay /usr/share/sounds/freedesktop/stereo/complete.oga 2>/dev/null || true
    fi
    command -v spd-say &>/dev/null \
        && spd-say "Flash complete. Transfer the SD card now." 2>/dev/null || true
}

if [[ "$YES" -eq 1 ]]; then
    beep_notify
    echo "Waiting 2 minutes for card transfer. Insert card into Pi and power on."
    for _s in $(seq 120 -1 1); do
        printf "\r  %3ds remaining..." "$_s"
        sleep 1
    done
    printf "\r  Done.                    \n"
    for _i in 1 2; do printf '\a'; sleep 0.3; done
    command -v spd-say &>/dev/null \
        && spd-say "Time's up. Waiting for SSH." 2>/dev/null || true
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
