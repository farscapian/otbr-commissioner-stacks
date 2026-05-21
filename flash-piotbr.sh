#!/usr/bin/env bash
# =============================================================================
# flash-piotbr.sh
#
# PURPOSE
#   Download Ubuntu Server 26.04 LTS (arm64, Raspberry Pi), verify integrity,
#   flash it to a target SD card, then inject a cloud-init payload onto the
#   system-boot FAT partition so that on first boot the device:
#
#     1. Connects via eth0 (preferred) or wlan0 (fallback).
#     2. Sets wireless regulatory domain to US.
#     3. Installs the openthread-border-router snap.
#     4. Configures OTBR with the supplied Thread dataset TLV.
#     5. Installs a systemd network-event service that watches for link-state
#        changes and reconfigures/restarts OTBR, always preferring eth0.
#
# USAGE
#   export WIFI_SSID="MyNetwork"    # optional; omit for eth-only
#   export WIFI_PASSWORD="s3cr3t"   # optional; omit for eth-only
#   export THREAD_DATASET_TLV="0e080000000000010000..."
#   sudo ./flash-piotbr.sh /dev/sdX
#
# HOST REQUIREMENTS (x86-64 Linux)
#   curl  sha256sum  xzcat  dd  mount  umount  partprobe  lsblk  python3
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# 1. Configuration
# ---------------------------------------------------------------------------

# 1.1 Image — Ubuntu Server 26.04 LTS, arm64, Raspberry Pi
SERVER_VERSION="26.04"
IMAGE_FILENAME="ubuntu-${SERVER_VERSION}-preinstalled-server-arm64+raspi.img.xz"
IMAGE_URL="https://cdimage.ubuntu.com/releases/26.04/release/${IMAGE_FILENAME}"
# SHA-256 of the compressed .xz as published by Canonical
IMAGE_SHA256="10604098a0c4eeb7359e58e12b01badbce8c74b0d53b414e633ba0b047b512cd"

# 1.2 All artefacts live under cache/ and artifacts/ next to this script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "${SCRIPT_DIR}/cache/ubuntu/server"
IMAGE_XZ="${SCRIPT_DIR}/cache/ubuntu/server/${IMAGE_FILENAME}"
IMAGE_IMG="${SCRIPT_DIR}/cache/ubuntu/server/${IMAGE_FILENAME%.xz}"
BAUD=460800

# 1.2.5 Parse flags (env is loaded by otbrstack before invoking this script)
_HOSTNAME_FLAG=""
_FORCE_FLASH=0
_SKIP_CONFIRM=0
_POSARGS=()
for _arg in "$@"; do
    case "$_arg" in
        --hostname=*)  _HOSTNAME_FLAG="${_arg#--hostname=}" ;;
        -f)            _FORCE_FLASH=1 ;;
        -y)            _SKIP_CONFIRM=1 ;;
        *) _POSARGS+=("$_arg") ;;
    esac
done
if [[ ${#_POSARGS[@]} -gt 0 ]]; then
    set -- "${_POSARGS[@]}"
else
    set --
fi
unset _arg _POSARGS
FORCE_FLASH=$_FORCE_FLASH;    unset _FORCE_FLASH
SKIP_CONFIRM=$_SKIP_CONFIRM;  unset _SKIP_CONFIRM
_HOSTNAME_CLI=$_HOSTNAME_FLAG; unset _HOSTNAME_FLAG

[[ -n "${THREAD_DATASET_TLV:-}" ]] || { echo "[ERROR] THREAD_DATASET_TLV not set — run via 'otbrstack flash'" >&2; exit 1; }

# 1.3 Credentials — read from env file; THREAD_DATASET_TLV is required
WIFI_SSID="${WIFI_SSID:-}"
WIFI_PASSWORD="${WIFI_PASSWORD:-}"
SSH_PUBKEY="${SSH_PUBKEY:-}"
OTBR_SNAP_CHANNEL="${OTBR_SNAP_CHANNEL:-latest/edge}"
SSH_MGMT_CIDRS="${SSH_MGMT_CIDRS:-}"

THREAD_DATASET_TLV="${THREAD_DATASET_TLV:?'Set THREAD_DATASET_TLV in the env file'}"

# Hostname: --hostname= flag > OTBR_HOSTNAME in env > default
OTBR_HOSTNAME="${_HOSTNAME_CLI:-${OTBR_HOSTNAME:-otbr-raspi4}}"
unset _HOSTNAME_CLI

# 1.4 Target block device from CLI
TARGET_DEV="${1:?$'Usage: otbrstack flash [-f] [-y] [--hostname=NAME] /dev/sdX\n  -f  force full reflash\n  -y  skip confirmation prompt\n  --hostname=  device hostname (overrides OTBR_HOSTNAME in env)'}"

# ---------------------------------------------------------------------------
# 2. Helpers
# ---------------------------------------------------------------------------

RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'; NC='\033[0m'
info() { echo -e "${GRN}[INFO]${NC}  $*"; }
warn() { echo -e "${YLW}[WARN]${NC}  $*"; }
die()  { echo -e "${RED}[ERR ]${NC}  $*" >&2; exit 1; }

require_cmd() {
    for c in "$@"; do command -v "$c" &>/dev/null || die "Required command not found: $c"; done
}

# ---------------------------------------------------------------------------
# 3. Pre-flight
# ---------------------------------------------------------------------------

require_cmd curl sha256sum xzcat dd lsblk partprobe python3 snap

[[ -b "$TARGET_DEV" ]] || die "$TARGET_DEV is not a block device."

# Verify the target hostname has an entry in ~/.ssh/config so the device is
# reachable by name after flashing. The check runs as the real user (not root)
# since sudo changes HOME to /root.
_REAL_USER="${SUDO_USER:-$USER}"
_REAL_HOME="$(eval echo "~${_REAL_USER}")"
_SSH_DIR="${_REAL_HOME}/.ssh"
_SSH_CONFIG="${_SSH_DIR}/config"

_ssh_has_host=0
if [[ -f "$_SSH_CONFIG" ]] && grep -qiE "^[[:space:]]*Host[[:space:]]+.*\b${OTBR_HOSTNAME}\b" "$_SSH_CONFIG"; then
    _ssh_has_host=1
fi

if [[ "$_ssh_has_host" -eq 1 ]]; then
    info "SSH config entry found for '${OTBR_HOSTNAME}'."
else
    warn "'${OTBR_HOSTNAME}' not found in ${_SSH_CONFIG}."
    read -rp "  Add a Host entry for '${OTBR_HOSTNAME}' to ${_SSH_CONFIG}? [Y/n] " _yn
    _yn="${_yn:-Y}"
    if [[ "$_yn" =~ ^[Yy] ]]; then
        mkdir -p "$_SSH_DIR"
        chmod 700 "$_SSH_DIR"
        chown "${_REAL_USER}:" "$_SSH_DIR"
        printf '\nHost %s\n    User ubuntu\n' "${OTBR_HOSTNAME}" >> "$_SSH_CONFIG"
        chmod 600 "$_SSH_CONFIG"
        chown "${_REAL_USER}:" "$_SSH_CONFIG"
        info "Added Host entry for '${OTBR_HOSTNAME}' to ${_SSH_CONFIG}."
    else
        die "Add a Host entry for '${OTBR_HOSTNAME}' to ${_SSH_CONFIG} and re-run."
    fi
fi
unset _REAL_USER _REAL_HOME _SSH_DIR _SSH_CONFIG _ssh_has_host _yn

# Refuse to flash a device that has any partition currently mounted
if lsblk -no MOUNTPOINT "$TARGET_DEV" 2>/dev/null | grep -q .; then
    die "$TARGET_DEV has mounted partitions — unmount first."
fi

info "Target: $TARGET_DEV"
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT "$TARGET_DEV"
echo

# Detect whether Ubuntu Server is already present on this device
if lsblk -no LABEL "$TARGET_DEV" 2>/dev/null | grep -q '^system-boot$'; then
    if [[ "$FORCE_FLASH" -eq 1 ]]; then
        CLOUD_INIT_ONLY=0
        warn "Ubuntu Server detected on $TARGET_DEV but -f given — full reflash."
    else
        CLOUD_INIT_ONLY=1
        info "Ubuntu Server detected on $TARGET_DEV — updating cloud-init only."
        info "(Use -f to force a full reflash and overwrite the OS.)"
    fi
else
    CLOUD_INIT_ONLY=0
fi

if [[ "$CLOUD_INIT_ONLY" -eq 0 ]]; then
    if [[ "$SKIP_CONFIRM" -eq 1 ]]; then
        warn "Skipping confirmation (-y). ALL DATA ON $TARGET_DEV WILL BE DESTROYED."
    else
        read -rp "  *** ALL DATA ON $TARGET_DEV WILL BE DESTROYED ***  Type YES to continue: " _yn
        [[ "$_yn" == "YES" ]] || die "Aborted."
    fi
fi

# ---------------------------------------------------------------------------
# 4. Thread RCP detection (ESP32-C6, SONOFF CP210x, or any ttyACM*/ttyUSB*)
# ---------------------------------------------------------------------------

find_rcp() {
    local candidates=()
    for p in /dev/ttyUSB* /dev/ttyACM*; do [[ -e "$p" ]] && candidates+=("$p"); done

    if [[ ${#candidates[@]} -eq 0 ]]; then
        warn "No USB serial devices found. RCP_DEVICE will be auto-detected at boot."
        RCP_DEVICE="__AUTODETECT__"
        return
    fi

    RCP_DEVICE="${candidates[0]}"
    info "USB serial candidates: ${candidates[*]}"
    info "RCP device: $RCP_DEVICE"
}

find_rcp

[[ "$RCP_DEVICE" != "__AUTODETECT__" ]] && info "Host RCP: $RCP_DEVICE (informational — Pi auto-detects at boot)"

# ---------------------------------------------------------------------------
# 5. Image download, verification, and flash (skipped in cloud-init-only mode)
# ---------------------------------------------------------------------------

if [[ "$CLOUD_INIT_ONLY" -eq 0 ]]; then

    if [[ "${SKIP_IMAGE_VERIFICATION:-0}" -eq 1 ]]; then
        [[ -f "$IMAGE_IMG" ]] || die "SKIP_IMAGE_VERIFICATION=1 but extracted image not found: $IMAGE_IMG"
        warn "SKIP_IMAGE_VERIFICATION=1 — skipping download, SHA-256, and size check."
    else
        # 5.1 Download if absent
        if [[ ! -f "$IMAGE_XZ" ]]; then
            info "Downloading ${IMAGE_FILENAME} ..."
            curl -L --progress-bar -o "$IMAGE_XZ" "$IMAGE_URL"
        else
            info "Compressed image already present: $IMAGE_XZ"
        fi

        # 5.2 Verify SHA-256 of compressed image
        info "Verifying SHA-256 ..."
        ACTUAL_SHA=$(sha256sum "$IMAGE_XZ" | awk '{print $1}')
        [[ "$ACTUAL_SHA" == "$IMAGE_SHA256" ]] \
            || die "SHA-256 mismatch!\n  expected: $IMAGE_SHA256\n  got:      $ACTUAL_SHA"
        info "SHA-256 verified."

        # 5.3 Extract if absent
        if [[ ! -f "$IMAGE_IMG" ]]; then
            info "Extracting to ${IMAGE_IMG} ..."
            xzcat "$IMAGE_XZ" > "$IMAGE_IMG"
        else
            info "Extracted image already present: $IMAGE_IMG"
        fi

        # 5.4 Sanity-check extracted size (must be > 2 GiB)
        # timeout guards against stat stalling on sync-watched or slow filesystems
        IMG_BYTES=$(timeout 10 stat -c%s "$IMAGE_IMG" 2>/dev/null || echo 0)
        (( IMG_BYTES > 2*1024*1024*1024 )) \
            || die "Extracted image is suspiciously small (${IMG_BYTES} bytes) — re-extract."
        info "Extracted image: $(( IMG_BYTES / 1024 / 1024 )) MiB — OK."
    fi

    # -------------------------------------------------------------------------
    # 6. Flash
    # -------------------------------------------------------------------------

    info "Flashing to $TARGET_DEV ..."
    sudo dd if="$IMAGE_IMG" of="$TARGET_DEV" bs=4M conv=fsync status=progress
    sync
    info "Flash complete. Re-reading partition table ..."
    sudo partprobe "$TARGET_DEV" 2>/dev/null || true
    sleep 3

fi  # CLOUD_INIT_ONLY

# ---------------------------------------------------------------------------
# 7. Mount system-boot partition
# ---------------------------------------------------------------------------
# Ubuntu Server 26.04 arm64+raspi partition layout:
#   p1  vfat    system-boot   (~256 MiB) ← cloud-init NoCloud seed goes here
#   p2  ext4    writable      (root filesystem)

get_part1() {
    for sfx in "1" "p1"; do
        local c="${TARGET_DEV}${sfx}"
        [[ -b "$c" ]] && { echo "$c"; return; }
    done
    die "Cannot locate partition 1 on $TARGET_DEV after flash."
}

BOOT_PART=$(get_part1)
info "system-boot partition: $BOOT_PART"

MOUNT_DIR=$(mktemp -d /tmp/uc-boot-XXXXXX)
cleanup() {
    sudo umount "$MOUNT_DIR" 2>/dev/null || true
    rmdir  "$MOUNT_DIR" 2>/dev/null || true
}
trap cleanup EXIT

# Mount with uid/gid so the normal user can write cloud-init files directly.
sudo mount -o "uid=$(id -u),gid=$(id -g)" "$BOOT_PART" "$MOUNT_DIR"
info "Mounted $BOOT_PART at $MOUNT_DIR"

# ---------------------------------------------------------------------------
# 7.5 Patch cmdline.txt — inject cfg80211 regulatory domain kernel parameter.
#
#     modprobe.d/cfg80211.conf and cloud-init write_files run AFTER the kernel
#     has already loaded cfg80211/brcmfmac (~14 s into first boot).  The only
#     way to guarantee the regdom is set before the very first channel scan is
#     to add it to the kernel command line, which is evaluated at module load
#     time via the built-in regulatory database path.
#
#     If the param is already present (e.g. reflash), skip the edit.
# ---------------------------------------------------------------------------
_CMDLINE_FILE="${MOUNT_DIR}/cmdline.txt"
if [[ -f "$_CMDLINE_FILE" ]]; then
    _CMDLINE=$(cat "$_CMDLINE_FILE")
    if [[ "$_CMDLINE" != *cfg80211.ieee80211_regdom=* ]]; then
        printf '%s cfg80211.ieee80211_regdom=US\n' "${_CMDLINE%$'\n'}" \
            > "$_CMDLINE_FILE"
        info "Patched cmdline.txt: added cfg80211.ieee80211_regdom=US"
    else
        info "cmdline.txt already has cfg80211.ieee80211_regdom — skipped"
    fi
else
    warn "cmdline.txt not found in system-boot — regulatory param not added"
fi
unset _CMDLINE_FILE _CMDLINE

# Ubuntu Server NoCloud datasource reads user-data/meta-data from the
# root of the system-boot partition, not a subdirectory.
CI_DIR="${MOUNT_DIR}"

# ---------------------------------------------------------------------------
# 8. Write meta-data (required by cloud-init even if minimal)
# ---------------------------------------------------------------------------

cat > "${CI_DIR}/meta-data" << EOF
instance-id: ${OTBR_HOSTNAME}-001
local-hostname: ${OTBR_HOSTNAME}
EOF

# ---------------------------------------------------------------------------
# 9. Write user-data
# ---------------------------------------------------------------------------
# Ubuntu Server supports full cloud-init: write_files, runcmd, users, packages.
#
# Approach:
#   users        — inject SSH public key into the default ubuntu user
#   write_files  — netplan, crda/regulatory, OTBR interface-watcher service
#   runcmd       — snap install, snap connect, snap set, ot-ctl dataset commit

NETPLAN_WIFIS=""
if [[ -n "$WIFI_SSID" && -n "$WIFI_PASSWORD" ]]; then
    NETPLAN_WIFIS=$(cat <<WIFISECT
        wifis:
          wlan0:
            dhcp4: true
            dhcp4-overrides:
              route-metric: 200
            regulatory-domain: US
            access-points:
              "${WIFI_SSID}":
                password: "${WIFI_PASSWORD}"
WIFISECT
)
fi

info "Writing cloud-init user-data ..."

# Build optional users section (SSH key injection)
USERS_SECTION=""
if [[ -n "$SSH_PUBKEY" ]]; then
    USERS_SECTION=$(cat <<USERSECT
users:
  - name: ubuntu
    groups: [sudo, dialout]
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - ${SSH_PUBKEY}
USERSECT
)
else
    warn "SSH_PUBKEY not set — ubuntu user will have no injected SSH key."
    warn "Set SSH_PUBKEY in your env file to enable passwordless SSH access."
fi

cat > "${CI_DIR}/user-data" <<USERDATA
#cloud-config

${USERS_SECTION}

# --------------------------------------------------------------------------
# 9.1 File payloads
# --------------------------------------------------------------------------
write_files:

  # 9.1.0 Tell ModemManager to ignore the ESP32-C6 USB JTAG/Serial (303a:1001).
  #        Without this, ModemManager opens /dev/ttyACM0 and swallows Spinel
  #        frames before the OTBR snap or our verify script can read them.
  - path: /etc/udev/rules.d/99-esp32-no-modemmanager.rules
    owner: root:root
    permissions: '0644'
    content: |
      SUBSYSTEM=="usb", ATTRS{idVendor}=="303a", ENV{ID_MM_DEVICE_IGNORE}="1"
      SUBSYSTEM=="tty", ATTRS{idVendor}=="303a", ENV{ID_MM_DEVICE_IGNORE}="1"

  # 9.1.1 Netplan — eth0 preferred (metric 100), wlan0 fallback (metric 200)
  #        Both interfaces are always configured; Linux routing prefers lower
  #        metric, so eth0 wins when the link is present.
  - path: /etc/netplan/00-otbr.yaml
    owner: root:root
    permissions: '0600'
    content: |
      network:
        version: 2
        renderer: networkd
        ethernets:
          eth0:
            dhcp4: true
            dhcp4-overrides:
              route-metric: 100
            optional: true
${NETPLAN_WIFIS}

  # 9.1.2 Wireless regulatory domain (CRDA / cfg80211)
  - path: /etc/default/crda
    owner: root:root
    permissions: '0644'
    content: |
      REGDOMAIN=US

  - path: /etc/modprobe.d/cfg80211.conf
    owner: root:root
    permissions: '0644'
    content: |
      options cfg80211 ieee80211_regdom=US

  # Disable brcmfmac background roaming scans. On BCM4345/6 (Pi 4B) firmware
  # 7.45.265, the scan loop rejects 5 GHz channels as out-of-regulatory and
  # then crashes at epc 0x000089d8. roamoff=1 prevents the scan loop entirely.
  - path: /etc/modprobe.d/brcmfmac.conf
    owner: root:root
    permissions: '0644'
    content: |
      options brcmfmac roamoff=1

  # Apply regulatory domain and disable power save as soon as wlan* appears.
  # udev fires at driver init (~14 s), well before runcmd (~35 s), so the
  # regulatory is in effect before brcmfmac begins channel probing.
  # Both global (iw reg set) and per-device (iw dev set country) are needed:
  # brcmfmac may ignore the global hint if WIPHY_FLAG_SELF_MANAGED_REG is set.
  - path: /etc/udev/rules.d/99-wifi-power.rules
    owner: root:root
    permissions: '0644'
    content: |
      ACTION=="add", SUBSYSTEM=="net", KERNEL=="wlan*", RUN+="/usr/sbin/iw reg set US"
      ACTION=="add", SUBSYSTEM=="net", KERNEL=="wlan*", RUN+="/usr/sbin/iw dev %k set country US"
      ACTION=="add", SUBSYSTEM=="net", KERNEL=="wlan*", RUN+="/usr/sbin/iw dev %k set power_save off"

  # 9.1.3 OTBR interface-watcher — systemd service that reacts to
  #        networkd interface state changes and reconfigures OTBR.
  #
  #        Mechanism: systemd-networkd emits a D-Bus signal on every
  #        interface state change. We use a lightweight Python D-Bus
  #        listener (sd-notify compatible). When a relevant link event
  #        fires, the watcher re-evaluates which backbone interface is
  #        UP and has a carrier, preferring eth0, then calls
  #        'snap set openthread-border-router infra-if=<iface>' and
  #        restarts the snap service.
  #
  #        This approach is more reliable than networkd-dispatcher scripts
  #        because it reacts to every admin/oper state transition in real
  #        time via the networkd D-Bus API, with no polling.

  - path: /usr/local/sbin/otbr-ifwatcher.py
    owner: root:root
    permissions: '0755'
    content: |
      #!/usr/bin/env python3
      """
      OTBR interface watcher.
      Listens for systemd-networkd D-Bus interface state events and
      reconfigures the openthread-border-router snap backbone interface,
      preferring eth0 over wlan0.
      """
      import subprocess, sys, time, logging
      logging.basicConfig(level=logging.INFO,
                          format='%(asctime)s otbr-ifwatcher %(levelname)s: %(message)s')
      log = logging.getLogger(__name__)

      try:
          from gi.repository import GLib
          import dbus, dbus.mainloop.glib
          HAS_DBUS = True
      except ImportError:
          HAS_DBUS = False
          log.warning("python3-dbus / python3-gi not available; falling back to poll mode")

      PREFER   = ['eth0', 'wlan0']
      SNAP     = 'openthread-border-router'
      INTERVAL = 10   # poll interval in seconds (fallback mode only)

      def iface_up(iface):
          """Return True if iface exists and has LOWER_UP flag."""
          try:
              out = subprocess.check_output(
                  ['ip', 'link', 'show', iface], stderr=subprocess.DEVNULL, text=True)
              return 'LOWER_UP' in out
          except subprocess.CalledProcessError:
              return False

      def best_iface():
          for i in PREFER:
              if iface_up(i):
                  return i
          return None

      _current_iface = None

      def reconfigure(reason='event'):
          global _current_iface
          iface = best_iface()
          if iface is None:
              log.warning("No backbone interface available yet")
              return
          if iface == _current_iface:
              return
          log.info(f"Backbone interface change [{reason}]: {_current_iface} -> {iface}")
          _current_iface = iface
          try:
              subprocess.run(['snap', 'set', SNAP, f'infra-if={iface}'], check=True)
              subprocess.run(['snap', 'restart', SNAP], check=True)
              log.info(f"OTBR reconfigured on {iface}")
          except subprocess.CalledProcessError as e:
              log.error(f"reconfigure failed: {e}")

      if HAS_DBUS:
          dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
          bus = dbus.SystemBus()

          def on_properties_changed(iface, changed, invalidated, path=None):
              # networkd signals on org.freedesktop.network1.Link
              if 'OperationalState' in changed or 'AdministrativeState' in changed:
                  reconfigure('dbus')

          bus.add_signal_receiver(
              on_properties_changed,
              dbus_interface='org.freedesktop.DBus.Properties',
              signal_name='PropertiesChanged',
              path_keyword='path')

          reconfigure('startup')
          log.info("Listening for networkd D-Bus events")
          GLib.MainLoop().run()
      else:
          log.info(f"Poll mode: checking every {INTERVAL}s")
          reconfigure('startup')
          while True:
              time.sleep(INTERVAL)
              reconfigure('poll')

  # 9.1.4 systemd unit for the watcher
  - path: /etc/systemd/system/otbr-ifwatcher.service
    owner: root:root
    permissions: '0644'
    content: |
      [Unit]
      Description=OTBR backbone interface watcher
      After=network.target snap.openthread-border-router.otbr-agent.service
      Wants=snap.openthread-border-router.otbr-agent.service

      [Service]
      Type=simple
      ExecStart=/usr/local/sbin/otbr-ifwatcher.py
      Restart=on-failure
      RestartSec=5s
      StandardOutput=journal
      StandardError=journal

      [Install]
      WantedBy=multi-user.target

  # 9.1.5 RCP firmware verification script (no external deps, raw HDLC probe)
  - path: /usr/local/sbin/otbr-verify-rcp.py
    owner: root:root
    permissions: '0755'
    content: |
      #!/usr/bin/env python3
      """Verify an OpenThread RCP is attached by sending a Spinel version query
      and checking for a valid HDLC response. No external packages required.
      Usage: otbr-verify-rcp.py <port> [baudrate]"""
      import sys, os, time, struct, tty, select, fcntl, termios

      HDLC_FLAG = 0x7E
      TIOCMBIC  = 0x5417  # clear modem control bits (deassert)
      TIOCM_DTR = 0x002
      TIOCM_RTS = 0x004

      def fcs16(data):
          crc = 0xFFFF
          for b in data:
              crc ^= b
              for _ in range(8):
                  crc = (crc >> 1) ^ 0x8408 if crc & 1 else crc >> 1
          return crc ^ 0xFFFF

      def hdlc_encode(payload):
          fcs = fcs16(payload)
          raw = payload + struct.pack('<H', fcs)
          out = bytearray([HDLC_FLAG])
          for b in raw:
              if b in (0x7E, 0x7D):
                  out += bytes([0x7D, b ^ 0x20])
              else:
                  out.append(b)
          out.append(HDLC_FLAG)
          return bytes(out)

      port = sys.argv[1] if len(sys.argv) > 1 else '/dev/ttyACM0'

      # TID=1 in header (0x81): device sends a response.
      # TID=0 (0x80) means unsolicited/no-reply — device will silently ignore it.
      frame = hdlc_encode(bytes([0x81, 0x02, 0x02]))  # GET PROP_NCP_VERSION, TID=1

      try:
          fd = os.open(port, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
      except OSError as e:
          print(f'ERROR: cannot open {port}: {e}', file=sys.stderr); sys.exit(1)

      # Opening the port causes the kernel CDC-ACM driver to send
      # SET_CONTROL_LINE_STATE(DTR=1, RTS=1), which triggers the ESP32-C6
      # USB Serial/JTAG hardware auto-reset. Deassert both lines immediately,
      # then wait for the device to finish rebooting (~4 s) before probing.
      fcntl.ioctl(fd, TIOCMBIC, struct.pack('I', TIOCM_DTR | TIOCM_RTS))
      tty.setraw(fd)
      os.set_blocking(fd, True)
      time.sleep(4)
      termios.tcflush(fd, termios.TCIFLUSH)  # discard boot ROM / IDF startup output

      os.write(fd, frame)
      time.sleep(0.5)

      try:
          ready, _, _ = select.select([fd], [], [], 4.0)
          resp = os.read(fd, 256) if ready else b''
      except OSError:
          resp = b''
      finally:
          os.close(fd)

      if HDLC_FLAG in resp and len(resp) > 4:
          print(f'RCP OK — {len(resp)}-byte HDLC response from {port}')
          sys.exit(0)

      print(f'ERROR: no HDLC response from {port} '
            f'({len(resp)} bytes: {resp.hex() or "empty"})', file=sys.stderr)
      sys.exit(1)

  # 9.1.6 Per-boot RCP radio auto-detection script.
  #        Probes every serial device with a Spinel version query and
  #        configures the OTBR snap with the first device that responds.
  #        Runs on every boot via otbr-radio-detect.service — the snap
  #        never uses a previously cached device path.
  - path: /usr/local/sbin/otbr-radio-detect.sh
    owner: root:root
    permissions: '0755'
    content: |
      #!/usr/bin/env bash
      # Probe serial devices, configure OTBR snap radio-url.
      # Baked-in at flash time: BAUD=${BAUD}  SKIP=${SKIP_RCP_VERIFY:-0}
      set -euo pipefail
      LOG=/var/log/otbr-firstboot.log
      SNAP=openthread-border-router

      log() { printf '[radio-detect] %s\n' "\$*" | tee -a "\$LOG"; }
      log "=== Radio detection \$(date) ==="

      # Stop ModemManager so it releases the device before probing.
      # It is already masked (never restarts); stopping here keeps the
      # device enumerated — the sysfs-reset approach caused cdc_acm to fail.
      systemctl stop ModemManager 2>/dev/null || true
      sleep 1

      # Wait up to 60 s for any serial device to enumerate.
      RCP=""
      for _i in \$(seq 1 30); do
        for _dev in /dev/ttyACM* /dev/ttyUSB*; do
          [[ -c "\$_dev" ]] && RCP="\$_dev" && break 2
        done
        log "Waiting for serial device... \$((_i*2))s"
        sleep 2
      done
      if [[ -z "\$RCP" ]]; then log "ERROR: no serial device found after 60 s"; exit 1; fi

      if [[ "${SKIP_RCP_VERIFY:-0}" -eq 1 ]]; then
        log "SKIP_RCP_VERIFY=1 — using first device: \$RCP"
        FOUND="\$RCP"
      else
        # Probe each device; use first that responds to Spinel.
        FOUND=""
        for _dev in /dev/ttyACM* /dev/ttyUSB*; do
          [[ -c "\$_dev" ]] || continue
          log "Probing \$_dev ..."
          if python3 /usr/local/sbin/otbr-verify-rcp.py "\$_dev" "${BAUD}"; then
            FOUND="\$_dev"; break
          fi
          log "\$_dev: no Spinel response"
        done
        if [[ -z "\$FOUND" ]]; then log "ERROR: no Spinel-responding device found"; exit 1; fi
      fi

      log "RCP detected: \$FOUND — configuring snap"
      snap set "\$SNAP" \
        radio-url="spinel+hdlc+uart://\${FOUND}?uart-baudrate=${BAUD}" \
        otbr-radio-url="spinel+hdlc+uart://\${FOUND}?uart-baudrate=${BAUD}"
      log "Radio URL set: \$FOUND"

  # 9.1.7 Systemd unit: run otbr-radio-detect.sh on every boot,
  #        before the OTBR snap agent starts.
  - path: /etc/systemd/system/otbr-radio-detect.service
    owner: root:root
    permissions: '0644'
    content: |
      [Unit]
      Description=OTBR Radio Auto-Detect (per-boot Spinel probe)
      # Only run once the snap is installed (skip on very first boot;
      # otbr-firstboot.sh calls the script directly that time).
      ConditionPathExists=/snap/openthread-border-router/current
      ConditionPathExists=/usr/local/sbin/otbr-verify-rcp.py
      After=sysinit.target

      [Service]
      Type=oneshot
      RemainAfterExit=yes
      ExecStart=/usr/local/sbin/otbr-radio-detect.sh

      [Install]
      WantedBy=multi-user.target

  # 9.1.8 Drop-in: make the OTBR snap agent wait for radio detection.
  - path: /etc/systemd/system/snap.openthread-border-router.otbr-agent.service.d/10-radio-detect.conf
    owner: root:root
    permissions: '0644'
    content: |
      [Unit]
      After=otbr-radio-detect.service
      Wants=otbr-radio-detect.service

  # 9.1.9 First-boot OTBR configuration script (called from runcmd)
  - path: /usr/local/sbin/otbr-firstboot.sh
    owner: root:root
    permissions: '0755'
    content: |
      #!/usr/bin/env bash
      set -euo pipefail
      SNAP=openthread-border-router
      TLV="${THREAD_DATASET_TLV}"
      LOG=/var/log/otbr-firstboot.log
      exec >> "\$LOG" 2>&1

      echo "=== OTBR first-boot \$(date) ==="

      # -- Wait for snapd to be fully seeded ---------------------------------
      snap wait system seed.loaded

      # -- Ensure networkd has fully applied DNS config before probing --------
      # networkctl wait-online blocks until at least one interface is routable
      # (DHCP complete including DNS), resolving the race between networkd
      # finishing DHCP and systemd-resolved having a working nameserver.
      networkctl wait-online --any --timeout=120 2>/dev/null || true

      # -- Wait for snap store DNS to resolve (systemd-resolved can be slow) --
      for _i in \$(seq 1 30); do
        getent hosts api.snapcraft.io >/dev/null 2>&1 && break
        echo "Waiting for snap store DNS (\$_i/30)..."
        sleep 5
      done

      # -- Install/upgrade packages (DNS is guaranteed up at this point) -------
      apt-get update -q
      apt-get install -y avahi-daemon iw
      # Upgrade linux-firmware to get the latest BCM4345/6 CLM blob, which
      # defines allowed 5 GHz channels. The version shipped in the base image
      # is often months stale and causes reason -52 channel rejections.
      apt-get install -y --only-upgrade linux-firmware || true

      # -- Install snap from store (retry on transient network errors) --------
      for _i in \$(seq 1 5); do
        snap install "\$SNAP" --channel=${OTBR_SNAP_CHANNEL} && break
        echo "Snap install attempt \$_i failed; retrying in 15s ..."
        sleep 15
      done

      # -- Connect interfaces ------------------------------------------------
      snap connect "\${SNAP}:firewall-control"
      snap connect "\${SNAP}:network-control"
      snap connect "\${SNAP}:raw-usb"
      snap connect "\${SNAP}:avahi-control"

      # -- Install chip-tool (Matter commissioning — BLE+Thread and Thread-only)
      snap list chip-tool &>/dev/null || snap install chip-tool

      # -- Detect RCP radio via Spinel probe (sets snap radio-url) ----------
      /usr/local/sbin/otbr-radio-detect.sh

      # -- Determine backbone interface --------------------------------------
      INFRA=wlan0
      if ip link show eth0 2>/dev/null | grep -q 'LOWER_UP'; then
        INFRA=eth0
      fi
      echo "Backbone interface: \$INFRA"

      # -- Configure snap (radio-url already set by otbr-radio-detect.sh) ---
      snap set "\$SNAP" \
        infra-if="\$INFRA" \
        thread-if=wpan0 \
        autostart=true

      # -- Start the snap service --------------------------------------------
      snap start --enable "\$SNAP"

      # -- Seed Thread dataset -----------------------------------------------
      # Wait up to 30 s for the agent socket to appear
      for i in \$(seq 1 30); do
        "\$SNAP".ot-ctl state 2>/dev/null && break || sleep 1
      done

      echo "Committing Thread dataset TLV ..."
      "\$SNAP".ot-ctl dataset set active "\$TLV"
      "\$SNAP".ot-ctl dataset commit active
      "\$SNAP".ot-ctl ifconfig up
      "\$SNAP".ot-ctl thread start

      # -- Configure UFW firewall --------------------------------------------
      ufw --force reset
      ufw default deny incoming
      ufw default allow outgoing
      # SSH
      SSH_MGMT_CIDRS="${SSH_MGMT_CIDRS}"
      if [[ -n "\$SSH_MGMT_CIDRS" ]]; then
        for _cidr in \$SSH_MGMT_CIDRS; do
          ufw allow from "\$_cidr" to any port 22 proto tcp comment 'SSH mgmt'
        done
      else
        ufw allow 22/tcp comment 'SSH (open)'
      fi
      # OTBR REST API and web UI
      ufw allow 8081/tcp comment 'OTBR REST API'
      ufw allow 80/tcp comment 'OTBR web UI'
      # mDNS — Avahi / Home Assistant discovery
      ufw allow 5353/udp comment 'mDNS'
      # Thread mesh interface — allow all traffic on wpan0
      ufw allow in on wpan0 comment 'Thread mesh (wpan0)'
      ufw --force enable
      echo "UFW enabled."

      echo "OTBR first-boot complete."

      # -- Apply pending boot assets (Ubuntu kernel/firmware updates) --------
      # piboot-try uses Ubuntu's tryboot mechanism: if untested assets are in
      # /boot/firmware/new, a reboot is needed to test them. Do it now rather
      # than leaving the banner on every login.
      if [[ -d /boot/firmware/new ]] && command -v piboot-try &>/dev/null; then
        echo "Pending boot assets detected — rebooting to apply (piboot-try)."
        piboot-try --reboot
      fi

# --------------------------------------------------------------------------
# 9.3 runcmd — executes after write_files and snap modules
# --------------------------------------------------------------------------
runcmd:
  # Apply netplan now so networkd has our config before firstboot starts.
  # This also ensures systemd-resolved gets DNS servers from our DHCP config.
  - netplan apply || true

  # Apply wireless regulatory domain if iw is already installed (subsequent
  # boots). On first boot iw is not yet installed; modprobe.d cfg80211.conf
  # handles the initial regdom. firstboot.sh installs iw with working DNS.
  - iw reg set US || true

  # Enable and start the interface watcher
  - systemctl daemon-reload
  - systemctl enable otbr-ifwatcher.service
  - systemctl enable otbr-radio-detect.service

  # Reload udev rules so the ESP32 ModemManager-ignore rule (written above by
  # write_files) takes effect for devices already enumerated at boot.
  - udevadm control --reload-rules
  - udevadm trigger --subsystem-match=usb
  # Mask ModemManager permanently — this OTBR device never needs it.
  # Masking (not just stopping) prevents systemd from restarting it.
  # The actual stop happens inside otbr-radio-detect.sh before each Spinel
  # probe so the device stays enumerated on every boot.
  - systemctl mask ModemManager || true

  # Run the OTBR first-boot configurator (background so cloud-init doesn't block)
  - nohup /usr/local/sbin/otbr-firstboot.sh &

final_message: |
  OTBR cloud-init complete. First-boot configuration running in background.
  Check /var/log/otbr-firstboot.log for progress.
USERDATA

info "cloud-init user-data written."

CI_ARTIFACT_DIR="${SCRIPT_DIR}/artifacts/rpi/${OTBR_HOSTNAME}"
mkdir -p "$CI_ARTIFACT_DIR"
cp "${CI_DIR}/meta-data" "${CI_ARTIFACT_DIR}/meta-data"
cp "${CI_DIR}/user-data" "${CI_ARTIFACT_DIR}/user-data"
info "cloud-init artifacts saved to ${CI_ARTIFACT_DIR}/"

# ---------------------------------------------------------------------------
# 9.5 Write critical kernel config directly to the root (writable) partition.
#
#     Problem: cloud-init write_files runs at ~30 s into first boot, but
#     brcmfmac loads at ~14 s.  The modprobe.d and udev rules written by
#     cloud-init arrive too late to affect the very first driver init.
#
#     Fix: write the same files directly to p2 (root filesystem) during the
#     flash so they are present before the kernel boots for the first time.
#     cloud-init will overwrite them on first boot with identical content.
# ---------------------------------------------------------------------------
_ROOT_PART=""
for _sfx in "2" "p2"; do
    _c="${TARGET_DEV}${_sfx}"
    [[ -b "$_c" ]] && { _ROOT_PART="$_c"; break; }
done

if [[ -z "$_ROOT_PART" ]]; then
    warn "Cannot locate root partition (p2) — brcmfmac config will apply from second boot via cloud-init."
else
    _ROOT_DIR=$(mktemp -d /tmp/uc-root-XXXXXX)
    if sudo mount "$_ROOT_PART" "$_ROOT_DIR" 2>/dev/null; then
        info "Mounted root partition $_ROOT_PART — writing kernel config..."
        sudo mkdir -p \
            "$_ROOT_DIR/etc/modprobe.d" \
            "$_ROOT_DIR/etc/udev/rules.d"

        sudo tee "$_ROOT_DIR/etc/modprobe.d/brcmfmac.conf" > /dev/null <<'BRCM'
options brcmfmac roamoff=1
BRCM

        sudo tee "$_ROOT_DIR/etc/modprobe.d/cfg80211.conf" > /dev/null <<'CFG'
options cfg80211 ieee80211_regdom=US
CFG

        sudo tee "$_ROOT_DIR/etc/udev/rules.d/99-wifi-power.rules" > /dev/null <<'UDEV'
ACTION=="add", SUBSYSTEM=="net", KERNEL=="wlan*", RUN+="/usr/sbin/iw reg set US"
ACTION=="add", SUBSYSTEM=="net", KERNEL=="wlan*", RUN+="/usr/sbin/iw dev %k set country US"
ACTION=="add", SUBSYSTEM=="net", KERNEL=="wlan*", RUN+="/usr/sbin/iw dev %k set power_save off"
UDEV

        sudo umount "$_ROOT_DIR"
        rmdir "$_ROOT_DIR"
        info "Kernel config written to root filesystem — active from first boot."
    else
        warn "Cannot mount root partition $_ROOT_PART — brcmfmac config will apply from second boot via cloud-init."
        rmdir "$_ROOT_DIR"
    fi
    unset _ROOT_PART _ROOT_DIR _sfx _c
fi

# ---------------------------------------------------------------------------
# 10. Unmount and finalise
# ---------------------------------------------------------------------------

sync
sudo umount "$MOUNT_DIR"
rmdir  "$MOUNT_DIR"
trap - EXIT

# Unmount any partitions the OS auto-mounted (udev/udisks) during the operation
while IFS= read -r _mp; do
    [[ -n "$_mp" ]] || continue
    info "Unmounting auto-mounted partition at: $_mp"
    sudo umount "$_mp" 2>/dev/null || warn "Could not unmount $_mp"
done < <(lsblk -no MOUNTPOINT "$TARGET_DEV" 2>/dev/null)
sync

if command -v eject &>/dev/null; then
    sudo eject "$TARGET_DEV" 2>/dev/null && info "Device ejected: $TARGET_DEV" || true
fi

info "============================================================"
if [[ "$CLOUD_INIT_ONLY" -eq 1 ]]; then
    info " Done (cloud-init update only — OS not reflashed)."
    info " cloud-init files updated on $TARGET_DEV."
    info " Safely remove the card, reinsert into the Pi, and reboot to apply."
else
    info " Done."
    info " SD card is ready. Safely remove $TARGET_DEV and insert"
    info " into the Raspberry Pi 4B with the Thread RCP dongle attached via USB."
fi
info ""
info " First boot will:"
if [[ -n "$WIFI_SSID" ]]; then
    info "   1. Connect via eth0 (preferred) or wlan0 (${WIFI_SSID})"
else
    info "   1. Connect via eth0 (WiFi not configured)"
fi
info "   2. Install openthread-border-router snap"
info "   3. Configure OTBR with your Thread TLV"
info "   4. Start OTBR as border router automatically"
info "   5. Start the interface watcher (prefers eth0)"
info ""
if [[ -n "${_HOSTNAME_CLI:-}" ]]; then
    info " SSH:  ssh ${OTBR_HOSTNAME}  (hostname from --hostname flag)"
else
    info " SSH:  ssh ubuntu@<pi-ip>  (or: ssh ${OTBR_HOSTNAME} if DNS/mDNS resolves)"
fi
info " Logs: /var/log/otbr-firstboot.log"
info " Cloud-init: sudo cloud-init status --long"
info "============================================================"