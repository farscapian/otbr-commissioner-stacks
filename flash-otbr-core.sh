#!/usr/bin/env bash
# =============================================================================
# flash-otbr-core.sh
#
# PURPOSE
#   Download Ubuntu Core 24 (arm64, Raspberry Pi 4), verify integrity,
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
#   NOTE: Ubuntu Core 26 does not yet ship a pre-built Core image (only
#   Desktop/Server images exist for 26.04). UC24 is the current stable Core
#   release. This script will be updated when UC26 Core images are published.
#
# USAGE
#   export WIFI_SSID="MyNetwork"    # optional; omit for eth-only
#   export WIFI_PASSWORD="s3cr3t"   # optional; omit for eth-only
#   export THREAD_DATASET_TLV="0e080000000000010000..."
#   sudo ./flash-otbr-core.sh /dev/sdX
#
# HOST REQUIREMENTS (x86-64 Linux)
#   curl  sha256sum  xzcat  dd  mount  umount  partprobe  lsblk  python3
#   Optional (for RCP probe): python3-serial  (pip3 install pyserial)
# =============================================================================

set -exuo pipefail

# ---------------------------------------------------------------------------
# 0. Bootstrap — auto-source .env if present
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# 1. Configuration
# ---------------------------------------------------------------------------

# 1.1 Image — Ubuntu Core 24, arm64, Raspberry Pi
CORE_VERSION="24"
IMAGE_FILENAME="ubuntu-core-${CORE_VERSION}-arm64+raspi.img.xz"
IMAGE_URL="https://cdimage.ubuntu.com/ubuntu-core/${CORE_VERSION}/stable/current/${IMAGE_FILENAME}"
# SHA-256 of the compressed .xz as published by Canonical
IMAGE_SHA256="f8e1c4882e7bb0b9357dd41789f94ea6f9ad7caa50ce7a16b32a1e628f591c74"

# 1.2 All artefacts live under cache/ and artifacts/ next to this script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "${SCRIPT_DIR}/cache/ubuntu/core"
IMAGE_XZ="${SCRIPT_DIR}/cache/ubuntu/core/${IMAGE_FILENAME}"
IMAGE_IMG="${SCRIPT_DIR}/cache/ubuntu/core/${IMAGE_FILENAME%.xz}"
BAUD=460800

# 1.2.5 Parse --env-file= and source configuration
_ENV_FILE=""
_FORCE_FLASH=0
_SKIP_CONFIRM=0
_POSARGS=()
for _arg in "$@"; do
    case "$_arg" in
        --env-file=*) _ENV_FILE="${_arg#--env-file=}" ;;
        -f)           _FORCE_FLASH=1 ;;
        -y)           _SKIP_CONFIRM=1 ;;
        *) _POSARGS+=("$_arg") ;;
    esac
done
if [[ ${#_POSARGS[@]} -gt 0 ]]; then
    set -- "${_POSARGS[@]}"
else
    set --
fi
unset _arg _POSARGS
FORCE_FLASH=$_FORCE_FLASH; unset _FORCE_FLASH
SKIP_CONFIRM=$_SKIP_CONFIRM; unset _SKIP_CONFIRM

if [[ -n "$_ENV_FILE" ]]; then
    [[ -f "$_ENV_FILE" ]] || { echo "env file not found: $_ENV_FILE" >&2; exit 1; }
else
    _ENV_FILE="${SCRIPT_DIR}/.env"
    [[ -f "$_ENV_FILE" ]] || { echo "No .env found in ${SCRIPT_DIR}; create one or use --env-file=PATH" >&2; exit 1; }
fi
set -a
# shellcheck source=/dev/null
source "$_ENV_FILE"
set +a
unset _ENV_FILE

# 1.3 Credentials — read from env file; THREAD_DATASET_TLV is required
WIFI_SSID="${WIFI_SSID:-}"
WIFI_PASSWORD="${WIFI_PASSWORD:-}"
OTBR_SNAP_CHANNEL="${OTBR_SNAP_CHANNEL:-latest/edge}"

THREAD_DATASET_TLV="${THREAD_DATASET_TLV:?'Set THREAD_DATASET_TLV in the env file'}"

# 1.4 Target block device from CLI
TARGET_DEV="${1:?$'Usage: sudo ./flash-otbr-core.sh [-f] [-y] [--env-file=PATH] /dev/sdX\n  -f  force full reflash even if Ubuntu Core is already on the device\n  -y  skip confirmation prompt (destructive — use with care)'}"

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

# Refuse to flash a device that has any partition currently mounted
if lsblk -no MOUNTPOINT "$TARGET_DEV" 2>/dev/null | grep -q .; then
    die "$TARGET_DEV has mounted partitions — unmount first."
fi

info "Target: $TARGET_DEV"
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT "$TARGET_DEV"
echo

# Detect whether Ubuntu Core is already present on this device
if lsblk -no LABEL "$TARGET_DEV" 2>/dev/null | grep -q '^system-boot$'; then
    if [[ "$FORCE_FLASH" -eq 1 ]]; then
        CLOUD_INIT_ONLY=0
        warn "Ubuntu Core detected on $TARGET_DEV but -f given — full reflash."
    else
        CLOUD_INIT_ONLY=1
        info "Ubuntu Core detected on $TARGET_DEV — updating cloud-init only."
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

# Resolve device path to embed in cloud-init (runtime autodetect snippet
# if we could not find the device on the host machine).
if [[ "$RCP_DEVICE" == "__AUTODETECT__" ]]; then
    RCP_SHELL_SNIPPET='RCP=$(ls /dev/ttyUSB* /dev/ttyACM* 2>/dev/null | head -1)'
    RCP_SNAP_URL="spinel+hdlc+uart://\${RCP}?uart-baudrate=${BAUD}"
else
    info "RCP device locked to: $RCP_DEVICE"
    RCP_SHELL_SNIPPET="RCP=${RCP_DEVICE}"
    RCP_SNAP_URL="spinel+hdlc+uart://${RCP_DEVICE}?uart-baudrate=${BAUD}"
fi

# ---------------------------------------------------------------------------
# 5. Image download, verification, and flash (skipped in cloud-init-only mode)
# ---------------------------------------------------------------------------

if [[ "$CLOUD_INIT_ONLY" -eq 0 ]]; then

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
    IMG_BYTES=$(stat -c%s "$IMAGE_IMG")
    (( IMG_BYTES > 2*1024*1024*1024 )) \
        || die "Extracted image is suspiciously small (${IMG_BYTES} bytes) — re-extract."
    info "Extracted image: $(( IMG_BYTES / 1024 / 1024 )) MiB — OK."

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
# UC24 arm64+raspi partition layout:
#   p1  vfat    system-boot   (~256 MiB) ← cloud-init goes here
#   p2  ext4    ubuntu-seed
#   p3  ext4    ubuntu-save
#   p4  ext4    ubuntu-data

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

CI_DIR="${MOUNT_DIR}/cloud-init"
mkdir -p "$CI_DIR"

# ---------------------------------------------------------------------------
# 8. Write meta-data (required by cloud-init even if minimal)
# ---------------------------------------------------------------------------

cat > "${CI_DIR}/meta-data" <<'EOF'
instance-id: otbr-raspi4-001
local-hostname: otbr-raspi4
EOF

# ---------------------------------------------------------------------------
# 9. Write user-data
# ---------------------------------------------------------------------------
# cloud-init on Ubuntu Core uses a restricted module set.
# Supported: write_files, runcmd, snap (install + set), final_message.
# Not supported on Core: packages, apt, users (managed via SSO/seed.yaml).
#
# Approach:
#   write_files  — netplan, crda/regulatory, networkd-dispatcher hook,
#                  OTBR interface-watcher service unit
#   runcmd       — snap install, snap connect (interfaces), snap set,
#                  ot-ctl dataset commit, enable watcher service

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

cat > "${CI_DIR}/user-data" <<USERDATA
#cloud-config

# --------------------------------------------------------------------------
# 9.1 File payloads
# --------------------------------------------------------------------------
write_files:

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
      import sys, os, time, struct, termios, tty

      HDLC_FLAG = 0x7E
      HDLC_ESC  = 0x7D

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

      BAUD_MAP = {'115200': termios.B115200, '460800': termios.B460800,
                  '921600': termios.B921600}

      port     = sys.argv[1] if len(sys.argv) > 1 else '/dev/ttyACM0'
      baud_str = sys.argv[2] if len(sys.argv) > 2 else '460800'
      baud     = BAUD_MAP.get(baud_str, termios.B460800)

      frame = hdlc_encode(bytes([0x80, 0x02, 0x02]))  # GET PROP_NCP_VERSION

      try:
          fd = os.open(port, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
      except OSError as e:
          print(f'ERROR: cannot open {port}: {e}', file=sys.stderr); sys.exit(1)

      attrs = termios.tcgetattr(fd)
      tty.setraw(fd)
      attrs[4] = attrs[5] = baud
      termios.tcsetattr(fd, termios.TCSANOW, attrs)
      os.set_blocking(fd, True)
      os.write(fd, frame)
      time.sleep(1.0)

      try:
          resp = os.read(fd, 256)
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

  # 9.1.6 First-boot OTBR configuration script (called from runcmd)
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

      # -- Resolve RCP device ------------------------------------------------
      ${RCP_SHELL_SNIPPET}
      if [[ -z "\${RCP:-}" ]]; then
        echo "ERROR: no RCP serial device found"; exit 1
      fi
      echo "RCP device: \$RCP"

      # -- Verify RCP firmware -----------------------------------------------
      echo "Verifying RCP firmware on \$RCP ..."
      if ! python3 /usr/local/sbin/otbr-verify-rcp.py "\$RCP" "${BAUD}"; then
        echo "ERROR: RCP firmware check failed on \$RCP. Is the RCP dongle flashed with OpenThread RCP firmware?"
        exit 1
      fi
      echo "RCP firmware OK."

      # -- Wait for snapd to be fully seeded ---------------------------------
      snap wait system seed.loaded

      # -- Install snap from store -------------------------------------------
      snap install "\$SNAP" --channel=${OTBR_SNAP_CHANNEL}

      # -- Connect interfaces ------------------------------------------------
      # serial-port: access to the RCP tty
      snap connect "\${SNAP}:serial-port" snapd:serial
      # network-control: needed to manage the wpan0 / Thread interface
      snap connect "\${SNAP}:network-control"
      # firewall-control: NAT / ip6tables rules for border routing
      snap connect "\${SNAP}:firewall-control"
      # network-observe: read routing table
      snap connect "\${SNAP}:network-observe"
      # raw-usb: direct USB serial access
      snap connect "\${SNAP}:raw-usb"

      # -- Determine backbone interface --------------------------------------
      INFRA=wlan0
      if ip link show eth0 2>/dev/null | grep -q 'LOWER_UP'; then
        INFRA=eth0
      fi
      echo "Backbone interface: \$INFRA"

      # -- Configure snap ----------------------------------------------------
      snap set "\$SNAP" \
        infra-if="\$INFRA" \
        radio-url="spinel+hdlc+uart://\${RCP}?uart-baudrate=${BAUD}" \
        nat64=false \
        dns64=false

      # -- Start the snap service --------------------------------------------
      snap start --enable "\$SNAP"

      # -- Seed Thread dataset -----------------------------------------------
      # Wait up to 30 s for the agent socket to appear
      for i in \$(seq 1 30); do
        snap run "\$SNAP".ot-ctl state 2>/dev/null && break || sleep 1
      done

      echo "Committing Thread dataset TLV ..."
      snap run "\$SNAP".ot-ctl dataset set active "\$TLV"
      snap run "\$SNAP".ot-ctl dataset commit active
      snap run "\$SNAP".ot-ctl ifconfig up
      snap run "\$SNAP".ot-ctl thread start

      echo "OTBR first-boot complete."

# --------------------------------------------------------------------------
# 9.3 runcmd — executes after write_files and snap modules
# --------------------------------------------------------------------------
runcmd:
  # Apply netplan (will take effect on next boot / networkd restart)
  - netplan generate || true

  # Apply wireless regulatory domain immediately
  - iw reg set US || true

  # Enable and start the interface watcher
  - systemctl daemon-reload
  - systemctl enable otbr-ifwatcher.service

  # Run the OTBR first-boot configurator (background so cloud-init doesn't block)
  - nohup /usr/local/sbin/otbr-firstboot.sh &

final_message: |
  OTBR cloud-init complete. First-boot configuration running in background.
  Check /var/log/otbr-firstboot.log for progress.
USERDATA

info "cloud-init user-data written."

CI_ARTIFACT_DIR="${SCRIPT_DIR}/artifacts/cloud-init-out"
mkdir -p "$CI_ARTIFACT_DIR"
cp "${CI_DIR}/meta-data" "${CI_ARTIFACT_DIR}/meta-data"
cp "${CI_DIR}/user-data" "${CI_ARTIFACT_DIR}/user-data"
info "cloud-init artifacts saved to ${CI_ARTIFACT_DIR}/"

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
info " Logs on device: /var/log/otbr-firstboot.log"
info "============================================================"