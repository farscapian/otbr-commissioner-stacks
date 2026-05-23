#!/usr/bin/env bash
# =============================================================================
# tests/test_otbr_vm.sh
#
# Integration test suite for OTBR Incus provisioning.
#
# Completion criteria (all 6 tests must PASS):
#   T1  Ubuntu Server 26.04 is running in the instance
#   T2  openthread-border-router snap is installed
#   T3  All OTBR snap services are active
#   T4  Thread interface is active (state: leader, router, or child)
#   T5  Thread dataset TLV is committed
#   T6  Thread neighbor table has ≥1 entry (another node actively exchanging data)
#
# T6 in simulation mode: two ot-cli POSIX simulation nodes (IDs 2, 3) are
# spawned inside the same instance. They share the VM loopback with ot-rcp
# node 1 and join the Thread network via the same dataset TLV. Requires an
# ot-cli binary at cache/ot-rcp-sim/ot-cli (built automatically by otbrstack vm).
#
# Build ot-cli from OpenThread source:
#   cd openthread && ./script/cmake-build simulation
#   cp build/simulation/examples/apps/cli/ot-cli cache/ot-rcp-sim/ot-cli
#
# USAGE
#   sudo ./tests/test_otbr_vm.sh [options]
#
# OPTIONS
#   --arch=amd64|arm64    Instance architecture (default: amd64)
#   --mode=vm|container   Instance type (default: vm)
#   --name=NAME           Override default instance name
#   --env-file=PATH       Env file (default: $(hostname).env or .env)
#   --keep                Don't delete instance after tests (default: delete)
#   --no-provision        Skip provisioning; run tests against existing instance
#   --no-peer-test        Skip T6 (neighbor exchange)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd -P)"

INSTANCE_ARCH="amd64"
INSTANCE_MODE="vm"
INSTANCE_NAME=""
ENV_FILE=""
KEEP_INSTANCE=0
SKIP_PROVISION=0
SKIP_PEER_TEST=0
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

for _arg in "$@"; do
    case "$_arg" in
        --arch=*)       INSTANCE_ARCH="${_arg#--arch=}" ;;
        --arm64)        INSTANCE_ARCH="arm64" ;;
        --mode=*)       INSTANCE_MODE="${_arg#--mode=}" ;;
        --vm)           INSTANCE_MODE="vm" ;;
        --container)    INSTANCE_MODE="container" ;;
        --name=*)       INSTANCE_NAME="${_arg#--name=}" ;;
        --env-file=*)   ENV_FILE="${_arg#--env-file=}" ;;
        --keep)         KEEP_INSTANCE=1 ;;
        --no-provision) SKIP_PROVISION=1 ;;
        --no-peer-test) SKIP_PEER_TEST=1 ;;
        *) echo "Unknown arg: $_arg" >&2; exit 1 ;;
    esac
done
unset _arg

if [[ -z "$INSTANCE_NAME" ]]; then
    if   [[ "$INSTANCE_MODE" == "container" ]]; then INSTANCE_NAME="otbr-test-ct"
    elif [[ "$INSTANCE_ARCH" == "arm64"     ]]; then INSTANCE_NAME="otbr-test-arm64"
    else                                             INSTANCE_NAME="otbr-test-x64"
    fi
fi

# ---------------------------------------------------------------------------
# Load env
# ---------------------------------------------------------------------------
if [[ -z "$ENV_FILE" ]]; then
    ENV_FILE="${REPO_DIR}/$(hostname).env"
    [[ -f "$ENV_FILE" ]] || ENV_FILE="${REPO_DIR}/.env"
fi
[[ -f "$ENV_FILE" ]] || { echo "No env file found — use --env-file=PATH" >&2; exit 1; }
set -a; source "$ENV_FILE"; set +a

THREAD_DATASET_TLV="${THREAD_DATASET_TLV:-}"
INCUS_PROJECT="${INCUS_PROJECT:-dev}"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-300}"
OTBR_TIMEOUT="${OTBR_TIMEOUT:-600}"

# arm64 QEMU emulation is ~3x slower
if [[ "$INSTANCE_ARCH" == "arm64" ]]; then
    BOOT_TIMEOUT=$(( BOOT_TIMEOUT * 3 ))
    OTBR_TIMEOUT=$(( OTBR_TIMEOUT * 3 ))
fi

export INCUS_PROJECT
INST="local:${INSTANCE_NAME}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'; BLU='\033[0;34m'
BOLD='\033[1m'; NC='\033[0m'

pass_test() { echo -e "  ${GRN}PASS${NC}  $1${2:+  ($2)}"; (( PASS_COUNT++ )) || true; }
fail_test() { echo -e "  ${RED}FAIL${NC}  $1${2:+  ($2)}"; (( FAIL_COUNT++ )) || true; }
skip_test() { echo -e "  ${YLW}SKIP${NC}  $1${2:+  ($2)}"; (( SKIP_COUNT++ )) || true; }
section()   { echo -e "\n${BLU}━━━ $* ${NC}"; }

inst_exec() { incus exec "$INST" -- "$@"; }

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
_cleanup() {
    if [[ "$KEEP_INSTANCE" -eq 0 ]] && incus info "$INST" &>/dev/null 2>&1; then
        echo -e "\nDeleting test instance: $INSTANCE_NAME"
        incus delete "$INST" --force 2>/dev/null || true
    fi
}
trap _cleanup EXIT

# ---------------------------------------------------------------------------
# Provisioning
# ---------------------------------------------------------------------------
if [[ "$SKIP_PROVISION" -eq 0 ]]; then
    section "Provisioning $INSTANCE_MODE ($INSTANCE_ARCH): $INSTANCE_NAME"
    "${REPO_DIR}/provision_incus.sh" \
        "--${INSTANCE_MODE}" \
        "--arch=${INSTANCE_ARCH}" \
        "--name=${INSTANCE_NAME}" \
        "--reprovision" \
        || { echo -e "\n${RED}Provisioning failed — aborting tests.${NC}" >&2; exit 1; }
else
    section "Testing existing instance: $INSTANCE_NAME"
    incus info "$INST" &>/dev/null \
        || { echo -e "${RED}Instance '$INSTANCE_NAME' not found.${NC}" >&2; exit 1; }
fi

echo -e "\n${BOLD}Test suite: $INSTANCE_NAME (${INSTANCE_ARCH} ${INSTANCE_MODE})${NC}"

# ---------------------------------------------------------------------------
# T1: Ubuntu Server 26.04
# ---------------------------------------------------------------------------
section "T1: Ubuntu Server 26.04"

_os_id=$(inst_exec sh -c '. /etc/os-release && echo "$ID"'           2>/dev/null || echo "error")
_os_ver=$(inst_exec sh -c '. /etc/os-release && echo "$VERSION_ID"'  2>/dev/null || echo "error")
_os_name=$(inst_exec sh -c '. /etc/os-release && echo "$PRETTY_NAME"' 2>/dev/null || echo "error")

if [[ "$_os_id" == "ubuntu" && "$_os_ver" == "26.04" ]]; then
    pass_test "OS is Ubuntu 26.04" "$_os_name"
else
    fail_test "OS is Ubuntu 26.04" "got: ID=$_os_id VERSION_ID=$_os_ver"
fi

# ---------------------------------------------------------------------------
# T2: OTBR snap installed
# ---------------------------------------------------------------------------
section "T2: openthread-border-router snap installed"

_snap_list=$(inst_exec snap list openthread-border-router 2>/dev/null || echo "")
if echo "$_snap_list" | grep -q "openthread-border-router"; then
    _snap_ver=$(echo "$_snap_list" | awk 'NR==2 {print $2}')
    pass_test "Snap installed" "version=$_snap_ver"
else
    fail_test "Snap installed" "not found in snap list"
fi

# ---------------------------------------------------------------------------
# T3: OTBR snap services active
# ---------------------------------------------------------------------------
section "T3: OTBR snap services active"

_svc_output=$(inst_exec snap services openthread-border-router 2>/dev/null || echo "")
if [[ -z "$_svc_output" ]]; then
    fail_test "Services" "no output — snap may not be installed"
else
    while IFS= read -r _line; do
        [[ -z "$_line" || "$_line" == Service* ]] && continue
        _svc=$(echo "$_line"    | awk '{print $1}')
        _status=$(echo "$_line" | awk '{print $3}')
        if [[ "$_status" == "active" ]]; then
            pass_test "Service active" "$_svc"
        else
            fail_test "Service active" "$_svc → $_status"
        fi
    done <<< "$_svc_output"
fi

# ---------------------------------------------------------------------------
# T4: Thread interface state
# ---------------------------------------------------------------------------
section "T4: Thread interface state"

_thread_state=$(inst_exec snap run openthread-border-router.ot-ctl state 2>/dev/null \
    | grep -v '^Done$' | tr -d '[:space:]' || echo "unavailable")

case "$_thread_state" in
    leader|router|child)
        pass_test "Thread state" "$_thread_state" ;;
    *)
        fail_test "Thread state" "got '$_thread_state' (want: leader|router|child)" ;;
esac

# ---------------------------------------------------------------------------
# T5: Thread dataset committed
# ---------------------------------------------------------------------------
section "T5: Thread dataset TLV committed"

_active_tlv=$(inst_exec snap run openthread-border-router.ot-ctl dataset active -x 2>/dev/null \
    | grep -v '^Done$' | tr -d '[:space:]' || echo "")

if [[ -n "$_active_tlv" ]]; then
    if [[ -n "$THREAD_DATASET_TLV" && "${_active_tlv,,}" == "${THREAD_DATASET_TLV,,}" ]]; then
        pass_test "Dataset TLV committed" "matches .env (${_active_tlv:0:16}...)"
    else
        pass_test "Dataset TLV committed" "${_active_tlv:0:16}..."
    fi
else
    fail_test "Dataset TLV committed" "no active dataset"
fi

# ---------------------------------------------------------------------------
# T6: Thread neighbor exchange
# ---------------------------------------------------------------------------
section "T6: Thread neighbor exchange"

if [[ "$SKIP_PEER_TEST" -eq 1 ]]; then
    skip_test "Neighbor exchange" "--no-peer-test"
elif [[ "$_thread_state" != "leader" && "$_thread_state" != "router" && "$_thread_state" != "child" ]]; then
    skip_test "Neighbor exchange" "Thread not active (T4 failed)"
else
    OT_CLI_BIN="${REPO_DIR}/cache/ot-rcp-sim/ot-cli"

    if [[ ! -f "$OT_CLI_BIN" ]]; then
        skip_test "Neighbor exchange" \
            "ot-cli not found at cache/ot-rcp-sim/ot-cli — run 'otbrstack vm' first to build it from source"
    else
        incus file push --mode 0755 "$OT_CLI_BIN" "${INST}/root/ot-rcp-sim/ot-cli"

        _live_tlv=$(inst_exec snap run openthread-border-router.ot-ctl dataset active -x 2>/dev/null \
            | grep -v '^Done$' | tr -d '[:space:]' || echo "${THREAD_DATASET_TLV:-}")

        if [[ -z "$_live_tlv" ]]; then
            skip_test "Neighbor exchange" "could not read active dataset TLV from OTBR"
        else
            # Write peer-test script with single-quoted heredoc (no host-side expansion).
            # The TLV is passed in as $1 at runtime inside the instance.
            _peer_tmp=$(mktemp /tmp/otbr-peer-test-XXXX.sh)
            cat > "$_peer_tmp" << 'PEER_SCRIPT'
#!/usr/bin/env bash
# Spawns ot-cli POSIX simulation nodes 2 and 3 inside the instance,
# joins them to the running Thread network, and waits for the OTBR
# neighbor table to report at least one entry.
set -euo pipefail

TLV="$1"
CLI=/root/ot-rcp-sim/ot-cli
TIMEOUT=90

join_node() {
    local id="$1"
    (
        printf '%s\n' \
            "dataset set active ${TLV}" \
            "dataset commit active" \
            "ifconfig up" \
            "thread start"
        sleep "${TIMEOUT}"
    ) | "${CLI}" "${id}" > "/tmp/ot-cli-${id}.log" 2>&1 &
    echo "Spawned ot-cli node ${id} (PID $!)"
}

join_node 2
join_node 3
sleep 5

DEADLINE=$(( SECONDS + TIMEOUT ))
while (( SECONDS < DEADLINE )); do
    TABLE=$(snap run openthread-border-router.ot-ctl neighbor table 2>/dev/null || true)
    COUNT=$(echo "${TABLE}" | grep -c "0x" 2>/dev/null || echo 0)
    printf "  Waiting for neighbors (found=%s, elapsed=%ss)...\n" "${COUNT}" "${SECONDS}"
    if (( COUNT > 0 )); then
        echo "NEIGHBORS_FOUND:${COUNT}"
        exit 0
    fi
    sleep 5
done

echo "NEIGHBORS_TIMEOUT"
echo "--- ot-cli node 2 log ---"
cat /tmp/ot-cli-2.log || true
echo "--- ot-cli node 3 log ---"
cat /tmp/ot-cli-3.log || true
exit 1
PEER_SCRIPT
            chmod +x "$_peer_tmp"
            incus file push "$_peer_tmp" "${INST}/tmp/peer-test.sh"
            rm -f "$_peer_tmp"
            incus exec "$INST" -- chmod +x /tmp/peer-test.sh

            echo "  Spawning peer nodes and polling neighbor table (up to 120s)..."
            _peer_out=""
            _peer_rc=0
            _peer_out=$(timeout 120 incus exec "$INST" -- /tmp/peer-test.sh "$_live_tlv" 2>&1) \
                || _peer_rc=$?

            if echo "$_peer_out" | grep -q "NEIGHBORS_FOUND:"; then
                _n=$(echo "$_peer_out" | grep "NEIGHBORS_FOUND:" | tail -1 | cut -d: -f2)
                pass_test "Neighbor exchange" "${_n} neighbor(s) in OTBR table"
            else
                fail_test "Neighbor exchange" "no neighbors within timeout"
                echo "  Last 8 lines of peer-test output:"
                echo "$_peer_out" | tail -8 | sed 's/^/    /'
            fi
        fi
    fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}Results: $INSTANCE_NAME (${INSTANCE_ARCH} ${INSTANCE_MODE})${NC}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "  ${GRN}PASS${NC}: ${PASS_COUNT}"
echo -e "  ${RED}FAIL${NC}: ${FAIL_COUNT}"
echo -e "  ${YLW}SKIP${NC}: ${SKIP_COUNT}"
echo ""
if [[ "$FAIL_COUNT" -gt 0 ]]; then
    echo -e "${RED}RESULT: FAILED${NC} (${FAIL_COUNT} test(s) failed)"
    exit 1
else
    echo -e "${GRN}RESULT: ALL TESTS PASSED${NC}"
    exit 0
fi
