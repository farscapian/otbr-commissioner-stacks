#!/usr/bin/env bash
# =============================================================================
# commission.sh
#
# Commission a Thread network on the target OTBR device.
#
# USAGE
#   ./commission.sh [--env-file=PATH] [--otbr | --chiptool]
#
#   --otbr      Use openthread-border-router snap (ot-ctl)  — Thread only
#   --chiptool  Use chip-tool snap — Thread or Bluetooth+Thread
#
# ENV (set in .env or exported):
#   THREAD_DATASET_TLV    Active dataset hex TLV            (required)
#   SSH_HOST              Target hostname or IP             (default: localhost)
#   SSH_PORT              SSH port                          (default: 22)
#   SSH_USER              SSH username                      (default: ubuntu)
#
#   chip-tool only:
#   MATTER_NODE_ID        Logical node ID to assign         (default: 1)
#   MATTER_PIN            Device setup PIN code             (required)
#   MATTER_DISCRIMINATOR  BLE discriminator — if set, uses ble-thread mode;
#                         omit to use Thread-only (code-thread) mode
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Arg parsing
# ---------------------------------------------------------------------------

COMMISSIONER=""
_ENV_FILE=""
_POSARGS=()
for _arg in "$@"; do
    case "$_arg" in
        --env-file=*) _ENV_FILE="${_arg#--env-file=}" ;;
        --otbr)       COMMISSIONER=otbr ;;
        --chiptool)   COMMISSIONER=chiptool ;;
        *) _POSARGS+=("$_arg") ;;
    esac
done
if [[ ${#_POSARGS[@]} -gt 0 ]]; then
    set -- "${_POSARGS[@]}"
else
    set --
fi
unset _arg _POSARGS

if [[ -z "$COMMISSIONER" ]]; then
    echo "Usage: $0 [--env-file=PATH] [--otbr | --chiptool]" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Env file
# ---------------------------------------------------------------------------

if [[ -n "$_ENV_FILE" ]]; then
    [[ -f "$_ENV_FILE" ]] || { echo "env file not found: $_ENV_FILE" >&2; exit 1; }
else
    _ENV_FILE="${SCRIPT_DIR}/.env"
    [[ -f "$_ENV_FILE" ]] || { echo "No .env found in ${SCRIPT_DIR}; use --env-file=PATH" >&2; exit 1; }
fi
set -a
# shellcheck source=/dev/null
source "$_ENV_FILE"
set +a
unset _ENV_FILE

# ---------------------------------------------------------------------------
# SSH setup
# ---------------------------------------------------------------------------

SSH_HOST="${SSH_HOST:-localhost}"
SSH_PORT="${SSH_PORT:-22}"
SSH_USER="${SSH_USER:-ubuntu}"

SSH_OPTS=(
    -p "$SSH_PORT"
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o LogLevel=ERROR
    -o ConnectTimeout=10
    -o BatchMode=yes
)

remote() { ssh "${SSH_OPTS[@]}" "${SSH_USER}@${SSH_HOST}" "$@"; }

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'; BLU='\033[0;34m'; NC='\033[0m'
info() { echo -e "${GRN}[INFO ]${NC}  $*"; }
warn() { echo -e "${YLW}[WARN ]${NC}  $*"; }
die()  { echo -e "${RED}[FAIL ]${NC}  $*" >&2; exit 1; }
step() { echo -e "\n${BLU}━━━ $* ${NC}"; }
pass() { echo -e "\n${GRN}[PASS ]${NC}  $*"; }

# ---------------------------------------------------------------------------
# Validate common requirements
# ---------------------------------------------------------------------------

THREAD_DATASET_TLV="${THREAD_DATASET_TLV:-}"
[[ -n "$THREAD_DATASET_TLV" ]] || die "THREAD_DATASET_TLV not set — cannot commission."
[[ "$THREAD_DATASET_TLV" =~ ^[0-9a-fA-F]+$ ]] \
    || die "THREAD_DATASET_TLV must be a hex string."

# ---------------------------------------------------------------------------
# OTBR commissioning — ot-ctl Thread dataset setup
# ---------------------------------------------------------------------------

commission_otbr() {
    local snap=openthread-border-router
    local tlv="$THREAD_DATASET_TLV"

    step "Commissioning via openthread-border-router (ot-ctl)"

    info "Waiting for ot-ctl to be reachable ..."
    local i
    for i in $(seq 1 30); do
        remote "sudo snap run ${snap}.ot-ctl state" &>/dev/null && break
        echo "  waiting for ot-ctl ($i/30)..."
        sleep 2
    done

    info "Setting active Thread dataset ..."
    remote "sudo snap run ${snap}.ot-ctl dataset set active ${tlv}"
    remote "sudo snap run ${snap}.ot-ctl dataset commit active"

    info "Bringing up Thread interface ..."
    remote "sudo snap run ${snap}.ot-ctl ifconfig up"
    remote "sudo snap run ${snap}.ot-ctl thread start"

    info "Waiting for Thread to reach an active state ..."
    local state
    for i in $(seq 1 30); do
        state=$(remote "sudo snap run ${snap}.ot-ctl state 2>/dev/null || echo unavailable")
        case "$state" in
            leader|router|child)
                pass "Thread is active (state: $state)"
                return 0
                ;;
        esac
        echo "  state: $state ($i/30)..."
        sleep 3
    done
    warn "Thread did not reach an active state within 90s (last: $state)"
    return 1
}

# ---------------------------------------------------------------------------
# chip-tool commissioning — Thread and Bluetooth+Thread
# ---------------------------------------------------------------------------

commission_chiptool() {
    local node_id="${MATTER_NODE_ID:-1}"
    local pin="${MATTER_PIN:-}"
    local discriminator="${MATTER_DISCRIMINATOR:-}"
    local tlv="$THREAD_DATASET_TLV"

    [[ -n "$pin" ]] || die "MATTER_PIN not set — required for chip-tool commissioning."

    if [[ -n "$discriminator" ]]; then
        step "Commissioning via chip-tool (ble-thread, discriminator=${discriminator})"
        info "Node ID: ${node_id}  PIN: ${pin}  Discriminator: ${discriminator}"
        remote "sudo snap run chip-tool pairing ble-thread ${node_id} hex:${tlv} ${pin} ${discriminator}"
    else
        step "Commissioning via chip-tool (Thread-only / code-thread)"
        info "Node ID: ${node_id}  PIN: ${pin}"
        info "(Set MATTER_DISCRIMINATOR in .env to use Bluetooth+Thread mode instead)"
        remote "sudo snap run chip-tool pairing code-thread ${node_id} hex:${tlv} ${pin}"
    fi

    pass "chip-tool commissioning complete (node ${node_id})"
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

info "Target:       ${SSH_USER}@${SSH_HOST}:${SSH_PORT}"
info "Commissioner: ${COMMISSIONER}"
info "Dataset TLV:  ${THREAD_DATASET_TLV:0:32}... (${#THREAD_DATASET_TLV} chars)"

case "$COMMISSIONER" in
    otbr)     commission_otbr ;;
    chiptool) commission_chiptool ;;
esac
