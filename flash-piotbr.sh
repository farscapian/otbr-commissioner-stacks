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
CHIP_TOOL_SNAP_CHANNEL="${CHIP_TOOL_SNAP_CHANNEL:-latest/stable}"
SSH_MGMT_CIDRS="${SSH_MGMT_CIDRS:-}"
# Set DEPLOY_MATTER_SERVER=0 in your env file to skip python-matter-server installation.
DEPLOY_MATTER_SERVER="${DEPLOY_MATTER_SERVER:-1}"

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

require_cmd curl sha256sum xzcat dd lsblk partprobe python3 snap rsync

[[ -b "$TARGET_DEV" ]] || die "$TARGET_DEV is not a block device."

# Verify the target hostname has an entry in ~/.ssh/config so the device is
# reachable by name after flashing. The check runs as the real user (not root)
# since sudo changes HOME to /root.
_REAL_USER="${SUDO_USER:-$USER}"
_REAL_HOME="$(eval echo "~${_REAL_USER}")"
_SSH_DIR="${_REAL_HOME}/.ssh"
_SSH_CONFIG="${_SSH_DIR}/config"

if [[ -f "$_SSH_CONFIG" ]] && grep -qE "^Host[[:space:]]+${OTBR_HOSTNAME}([[:space:]]|$)" "$_SSH_CONFIG"; then
    info "SSH config entry found for '${OTBR_HOSTNAME}'."
else
    info "No SSH config entry for '${OTBR_HOSTNAME}' — creating stub in ${_SSH_CONFIG}."
    mkdir -p "$_SSH_DIR" && chmod 700 "$_SSH_DIR" && chown "${_REAL_USER}:" "$_SSH_DIR"
    printf '\nHost %s\n    HostName %s.local\n    User ubuntu\n' \
        "${OTBR_HOSTNAME}" "${OTBR_HOSTNAME}" >> "$_SSH_CONFIG"
    chmod 600 "$_SSH_CONFIG" && chown "${_REAL_USER}:" "$_SSH_CONFIG"
fi
unset _REAL_USER _REAL_HOME _SSH_DIR _SSH_CONFIG

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
    command -v qemu-aarch64 &>/dev/null \
        || die "qemu-aarch64 not found — required for arm64 chroot.\n  Install with: sudo apt-get install qemu-user-binfmt"

    if [[ "$SKIP_CONFIRM" -eq 1 ]]; then
        warn "Skipping confirmation (-y). ALL DATA ON $TARGET_DEV WILL BE DESTROYED."
    else
        read -rp "  *** ALL DATA ON $TARGET_DEV WILL BE DESTROYED ***  Type YES to continue: " _yn
        [[ "$_yn" == "YES" ]] || die "Aborted."
    fi
fi


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
# Ubuntu 26.04 arm64+raspi moved kernel files to a firmware/ subdirectory
# on the system-boot partition; try both locations.
_CMDLINE_FILE="${MOUNT_DIR}/cmdline.txt"
[[ -f "$_CMDLINE_FILE" ]] || _CMDLINE_FILE="${MOUNT_DIR}/firmware/cmdline.txt"
if [[ -f "$_CMDLINE_FILE" ]]; then
    _CMDLINE=$(cat "$_CMDLINE_FILE")
    _CMDLINE_CHANGED=0
    if [[ "$_CMDLINE" != *cfg80211.ieee80211_regdom=* ]]; then
        _CMDLINE="${_CMDLINE%$'\n'} cfg80211.ieee80211_regdom=US"
        _CMDLINE_CHANGED=1
    fi
    if [[ "$_CMDLINE" != *brcmfmac.feature_disable=* ]]; then
        _CMDLINE="${_CMDLINE%$'\n'} brcmfmac.feature_disable=0x82000"
        _CMDLINE_CHANGED=1
    fi
    if [[ "$_CMDLINE_CHANGED" -eq 1 ]]; then
        printf '%s\n' "$_CMDLINE" > "$_CMDLINE_FILE"
        info "Patched cmdline.txt: cfg80211.ieee80211_regdom=US brcmfmac.feature_disable=0x82000"
    else
        info "cmdline.txt already patched — skipped"
    fi
    unset _CMDLINE_CHANGED
else
    info "cmdline.txt not present in system-boot (expected — Ubuntu 26.04 uses GRUB/UEFI; modprobe.d covers regulatory)"
fi
unset _CMDLINE_FILE _CMDLINE

# Patch config.txt with country=US — Pi firmware reads this before brcmfmac
# loads, making it the most authoritative regulatory source.
_CONFIG_FILE="${MOUNT_DIR}/config.txt"
if [[ -f "$_CONFIG_FILE" ]]; then
    if grep -q "^country=" "$_CONFIG_FILE"; then
        sed -i "s/^country=.*/country=US/" "$_CONFIG_FILE"
        info "config.txt: updated country=US"
    else
        echo "country=US" >> "$_CONFIG_FILE"
        info "config.txt: added country=US"
    fi
else
    warn "config.txt not found in system-boot — Pi firmware regulatory not set"
fi
unset _CONFIG_FILE

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
            accept-ra: true
            optional: true
            dhcp4-overrides:
              route-metric: 200
            regulatory-domain: US
            access-points:
              "${WIFI_SSID}":
                auth:
                  key-management: psk
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

# Base64-encode the canonical probe script so it can be embedded in the
# cloud-init YAML without escaping issues (cloud-init decodes it on the Pi).
_VERIFY_RCP_B64=$(base64 -w 0 "${SCRIPT_DIR}/scripts/verify_rcp.py")
_FLASH_RCP_B64=$(base64 -w 0 "${SCRIPT_DIR}/scripts/flash_rcp.sh")

# Conditionally build the cloud-init apt proxy stanza and the chroot proxy
# command.  Both are empty when HTTP_PROXY is unset, so users without a
# local cache get direct internet access with no config changes required.
_APT_PROXY_YAML=""
_APT_PROXY_CHROOTCMD=""
if [[ -n "${HTTP_PROXY:-}" ]]; then
    _APT_PROXY_YAML="apt:
  http_proxy: ${HTTP_PROXY}
"
    _APT_PROXY_CHROOTCMD="echo 'Acquire::http::Proxy \"${HTTP_PROXY}\";' > /etc/apt/apt.conf.d/90apt-cache"
fi

cat > "${CI_DIR}/user-data" <<USERDATA
#cloud-config

${USERS_SECTION}

${_APT_PROXY_YAML}
# Install iw before runcmd so 'iw reg set US' works.  The packages module
# runs earlier in cloud-init's lifecycle than runcmd.
packages:
  - iw

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
            accept-ra: true
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

  # roamoff=1   — disables background roaming scans (prevents scan-loop crash)
  # feature_disable=0x82000 — disables SAE offload (0x80000) + SWSUP (0x2000).
  #   BCM4345/6 (Pi 4B) brcmfmac SAE firmware engine is broken: attempting SAE
  #   auth against WPA2+WPA3 transition-mode APs produces ASSOC-REJECT
  #   status_code=16 with bssid=00:00:00:00:00:00 (locally generated).
  #   Disabling offload forces wpa_supplicant to handle auth in software and
  #   fall back cleanly to WPA2-PSK.
  - path: /etc/modprobe.d/brcmfmac.conf
    owner: root:root
    permissions: '0644'
    content: |
      options brcmfmac roamoff=1 feature_disable=0x82000

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

  # 9.1.5 RCP firmware verification script — base64-encoded from scripts/verify_rcp.py.
  #        Uses pyserial when available; falls back to stdlib so no venv is needed.
  - path: /usr/local/sbin/otbr-verify-rcp.py
    owner: root:root
    permissions: '0755'
    encoding: b64
    content: ${_VERIFY_RCP_B64}

  # 9.1.6 ESP32-C6 RCP flash script — embedded from scripts/flash_rcp.sh.
  #        Clones/updates ESP-IDF, builds ot_rcp, and flashes only when the
  #        firmware changes.  On the Pi, IDF lives at /opt/esp-idf.
  - path: /usr/local/sbin/otbr-flash-rcp.sh
    owner: root:root
    permissions: '0755'
    encoding: b64
    content: ${_FLASH_RCP_B64}

  # 9.1.7 Per-boot RCP orchestration script.
  #        Waits for the ESP32-C6 to enumerate, calls otbr-flash-rcp.sh to
  #        build/flash firmware if changed, then sets the snap radio-url.
  #        Called directly by otbr-firstboot.sh on first boot; run as a
  #        systemd service (otbr-rcp-update.service) on every subsequent boot.
  - path: /usr/local/sbin/otbr-rcp-update.sh
    owner: root:root
    permissions: '0755'
    content: |
      #!/usr/bin/env bash
      # Build/flash ESP32-C6 RCP firmware; configure OTBR snap radio-url.
      # Baked-in at flash time: BAUD=${BAUD}
      set -euo pipefail
      LOG=/var/log/otbr-firstboot.log
      SNAP=openthread-border-router

      exec >> "\$LOG" 2>&1
      log() { printf '[rcp-update] %s\n' "\$*"; }

      # Prevent both concurrent and sequential re-runs within the same boot.
      # flock handles concurrent callers racing; the /run sentinel handles
      # sequential re-invocations (e.g. systemd Wants= triggering a second run
      # after otbr-firstboot.sh already called us directly).
      # /run is a tmpfs cleared on every reboot, so the sentinel is auto-reset.
      exec 9>/var/lock/otbr-rcp-update.lock
      if ! flock -n 9; then
        log "Another instance already running — exiting."
        exit 0
      fi
      _DONE_FLAG=/run/otbr-rcp-update.done
      if [[ -f "\$_DONE_FLAG" ]]; then
        log "Already ran this boot — exiting."
        exit 0
      fi
      touch "\$_DONE_FLAG"

      log "=== RCP update \$(date) ==="

      # Proxy for git/curl — baked in at flash time from HTTP_PROXY env var.
      # git ignores uppercase HTTP_PROXY, so we export the lowercase variants.
      ${HTTP_PROXY:+export http_proxy="${HTTP_PROXY}" https_proxy="${HTTP_PROXY}"}
      # Skip git network ops on the Pi when baked in at flash time.
      ${PULL_LATEST_REPOS:+export PULL_LATEST_REPOS="${PULL_LATEST_REPOS}"}

      # Wait up to 120 s for NTP to sync.  The Pi has no RTC, so its clock
      # starts from fake-hwclock's last saved value.  git ls-remote uses
      # TLS, and TLS cert validation fails when the clock is significantly
      # wrong.  WiFi-only boots need extra time: WiFi association + DHCP can
      # take 30-60 s before NTP has a reachable server.
      for _ntp_i in \$(seq 1 40); do
        timedatectl show --property=NTPSynchronized --value 2>/dev/null \
          | grep -q yes && break
        log "Waiting for NTP sync (\${_ntp_i}/40)..."
        sleep 3
      done

      systemctl stop ModemManager 2>/dev/null || true
      sleep 1

      # Wait indefinitely for an ESP32-C6 (idVendor=303a) on ttyACM*.
      RCP=""
      _i=0
      while [[ -z "\$RCP" ]]; do
        for _dev in /dev/ttyACM*; do
          [[ -c "\$_dev" ]] || continue
          _base=\$(basename "\$_dev")
          _usb=\$(readlink -f "/sys/class/tty/\${_base}/device" 2>/dev/null) || continue
          while [[ -n "\$_usb" && "\$_usb" != "/" && ! -f "\$_usb/idVendor" ]]; do
            _usb=\$(dirname "\$_usb")
          done
          if [[ -f "\$_usb/idVendor" ]] && [[ "\$(cat "\$_usb/idVendor")" == "303a" ]]; then
            RCP="\$_dev"; break
          fi
        done
        if [[ -z "\$RCP" ]]; then
          _i=\$(( _i + 1 ))
          log "Waiting for ESP32-C6 (\${_i})..."
          sleep 2
        fi
      done
      log "ESP32-C6 detected: \$RCP"

      mkdir -p /var/lib/otbr
      IDF_DIR=/opt/esp-idf \
      IDF_TOOLS_PATH=/opt/esp-idf-tools \
      RCP_BIN_CACHE=/var/lib/otbr/esp_ot_rcp.bin \
        /usr/local/sbin/otbr-flash-rcp.sh --port "\$RCP"

      snap set "\$SNAP" \
        radio-url="spinel+hdlc+uart://\${RCP}?uart-baudrate=${BAUD}" \
        otbr-radio-url="spinel+hdlc+uart://\${RCP}?uart-baudrate=${BAUD}"
      log "Radio URL configured: \$RCP"

  # 9.1.8 Systemd unit: run otbr-rcp-update.sh on every boot,
  #        before the OTBR snap agent starts.
  #        ConditionPathExists skips this on the very first boot (snap not yet
  #        installed); otbr-firstboot.sh calls the script directly that time.
  - path: /etc/systemd/system/otbr-rcp-update.service
    owner: root:root
    permissions: '0644'
    content: |
      [Unit]
      Description=OTBR ESP32-C6 RCP firmware update (build from ESP-IDF + flash)
      ConditionPathExists=/snap/openthread-border-router/current
      After=sysinit.target
      Before=snap.openthread-border-router.otbr-agent.service

      [Service]
      Type=oneshot
      RemainAfterExit=yes
      ExecStart=/usr/local/sbin/otbr-rcp-update.sh
      TimeoutStartSec=1800
      StandardOutput=journal+console
      StandardError=journal+console

      [Install]
      WantedBy=multi-user.target

  # 9.1.8a Persistent early-boot service: confirm any pending RPi tryboot and
  #   remove /boot/firmware/new/ so no stale kernel assets survive a reboot.
  #   Runs on every boot before sysinit.target.  Prevents the unattended-upgrades
  #   reboot loop: apt-get upgrade → flash-kernel → /new/ → auto-reboot → repeat.
  - path: /etc/systemd/system/otbr-boot-cleanup.service
    owner: root:root
    permissions: '0644'
    content: |
      [Unit]
      Description=Confirm Raspberry Pi tryboot and clean up pending boot assets
      DefaultDependencies=no
      After=local-fs.target
      Before=sysinit.target

      [Service]
      Type=oneshot
      ExecStart=-/usr/sbin/piboot-try --confirm
      ExecStart=/bin/rm -rf /boot/firmware/new/

      [Install]
      WantedBy=sysinit.target

  # 9.1.8b Tell flash-kernel the machine type so it selects the correct Pi 4B
  #   DTB (bcm2711-rpi-4-b.dtb) instead of guessing Pi 5 when
  #   /etc/flash-kernel.conf is absent.  Without this, apt-triggered
  #   initrd rebuilds (dracut + flash-kernel) copy the wrong DTB tree.
  #   Note: /etc/flash-kernel.conf is the correct override file;
  #   /etc/default/flash-kernel only sets env vars and doesn't affect MACHINE.
  - path: /etc/flash-kernel.conf
    owner: root:root
    permissions: '0644'
    content: |
      MACHINE="Raspberry Pi 4 Model B"

  # 9.1.8c Load kernel modules at boot.
  #   tun        — /dev/net/tun used by otbr-agent
  #   ip_set*    — ipset support required by otbr-setup firewall script
  #   xt_set     — iptables ipset match used by otbr-setup
  - path: /etc/modules-load.d/otbr.conf
    owner: root:root
    permissions: '0644'
    content: |
      tun
      ip_set
      ip_set_hash_net
      xt_set

  # 9.1.9 Drop-in: make the OTBR snap agent wait for RCP firmware update;
  #        disable StartLimitAction=reboot so crashes don't boot-loop the Pi.
  - path: /etc/systemd/system/snap.openthread-border-router.otbr-agent.service.d/10-radio-detect.conf
    owner: root:root
    permissions: '0644'
    content: |
      [Unit]
      After=otbr-rcp-update.service
      Wants=otbr-rcp-update.service
      StartLimitIntervalSec=0
      StartLimitAction=none

  # 9.1.10 Weekly reboot timer — triggers RCP firmware check via boot service.
  - path: /etc/systemd/system/otbr-weekly-reboot.timer
    owner: root:root
    permissions: '0644'
    content: |
      [Unit]
      Description=Weekly reboot to trigger OTBR RCP firmware update check

      [Timer]
      OnCalendar=weekly
      Unit=otbr-weekly-reboot.service

      [Install]
      WantedBy=timers.target

  - path: /etc/systemd/system/otbr-weekly-reboot.service
    owner: root:root
    permissions: '0644'
    content: |
      [Unit]
      Description=Reboot to trigger OTBR RCP firmware update check

      [Service]
      Type=oneshot
      ExecStart=/usr/sbin/reboot

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

      # One-shot guard: cloud-init runcmd triggers on every cloud-init run,
      # including the tryboot second boot.  Skip if we already ran successfully.
      if [[ -f /var/lib/otbr/firstboot-done ]]; then
        echo "=== first-boot already completed — skipping second run ==="
        exit 0
      fi

      # Patch Pi firmware country code — authoritative for brcmfmac regulatory.
      if grep -q "^country=" /boot/firmware/config.txt 2>/dev/null; then
        sed -i "s/^country=.*/country=US/" /boot/firmware/config.txt
      else
        echo "country=US" >> /boot/firmware/config.txt
      fi

      # -- Wait for snapd to be fully seeded ---------------------------------
      snap wait system seed.loaded

      # -- Ensure networkd has fully applied DNS config before probing --------
      # networkctl wait-online blocks until at least one interface is routable
      # (DHCP complete including DNS), resolving the race between networkd
      # finishing DHCP and systemd-resolved having a working nameserver.
      networkctl wait-online --any --timeout=120 2>/dev/null || true

      # -- Wait for NTP clock sync before apt (Pi has no RTC; clock starts ----
      # wrong and apt rejects release files with "not valid yet" errors until
      # timesyncd has corrected it).
      for _i in \$(seq 1 60); do
        if timedatectl show --property=NTPSynchronized --value 2>/dev/null | grep -q yes; then
          echo "Clock synchronized (\${_i} attempts)."
          break
        fi
        echo "Waiting for NTP sync (\${_i}/60)..."
        sleep 5
      done

      # -- Wait for snap store DNS to resolve (systemd-resolved can be slow) --
      for _i in \$(seq 1 30); do
        getent hosts api.snapcraft.io >/dev/null 2>&1 && break
        echo "Waiting for snap store DNS (\$_i/30)..."
        sleep 5
      done

      # -- Install/upgrade packages -------------------------------------------
      # Packages are pre-installed at flash time via chroot when qemu-user-static
      # is available; these calls are fast no-ops in that case.  They also ensure
      # packages are present when flashing without qemu-user-static.
      # Disable unattended-upgrades permanently on this appliance device.
      # Kernel upgrades triggered by unattended-upgrades cause flash-kernel to
      # write to /boot/firmware/new/ and trigger a tryboot reboot loop on the Pi.
      # We do a controlled upgrade below (first boot only); ongoing kernel updates
      # are held to prevent this loop.
      systemctl disable --now unattended-upgrades apt-daily.service apt-daily-upgrade.service \
        apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
      for _i in \$(seq 1 30); do
        fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || break
        echo "Waiting for dpkg lock (\${_i}/30)..."
        sleep 5
      done
      apt-get update -q
      apt-get upgrade -y -q
      apt-get install -y avahi-daemon iw git cmake ninja-build python3-venv python3-pip python3-dbus python3-gi libusb-1.0-0
      # Upgrade linux-firmware to get the latest BCM4345/6 CLM blob, which
      # defines allowed 5 GHz channels. The version shipped in the base image
      # is often months stale and causes reason -52 channel rejections.
      apt-get install -y --only-upgrade linux-firmware || true

      # Hold kernel packages so no subsequent apt run can upgrade the kernel.
      # Kernel upgrades trigger flash-kernel → /boot/firmware/new/ → tryboot →
      # unattended-upgrades auto-reboot → infinite boot loop.
      apt-mark hold linux-raspi linux-image-raspi linux-headers-raspi 2>/dev/null || true
      # Belt-and-suspenders: even if unattended-upgrades somehow runs, don't reboot.
      printf 'Unattended-Upgrade::Automatic-Reboot "false";\n' \
        > /etc/apt/apt.conf.d/99otbr-no-reboot

      # -- Ensure snap is installed -------------------------------------------
      # Stop ModemManager now so it cannot hold ttyACM0 during snap install or
      # the interface-connect restarts that follow.  The mask (from runcmd)
      # prevents it from restarting; the explicit stop here is needed because
      # mask alone does not stop an already-running instance.
      systemctl stop ModemManager 2>/dev/null || true

      # Try the pre-loaded /opt/otbr-snap/ file first (installed with
      # --dangerous --devmode: arm64 revision assertions aren't publicly
      # fetchable, and the thread-reference edge build lacks firewall-control /
      # network-control plugs so its AppArmor profile never gets CAP_NET_ADMIN.
      # --devmode puts AppArmor into complain mode so ip6tables and ipset work.
      if ! snap list "\$SNAP" &>/dev/null; then
        _snap_file=\$(ls /opt/otbr-snap/*.snap 2>/dev/null | head -1)
        if [[ -n "\$_snap_file" ]]; then
          echo "Installing \$SNAP from pre-loaded file: \$(basename "\$_snap_file")"
          snap install --dangerous --devmode "\$_snap_file" || true
          snap switch "\$SNAP" --channel=${OTBR_SNAP_CHANNEL} 2>/dev/null || true
        fi
      fi
      if ! snap list "\$SNAP" &>/dev/null; then
        echo "\$SNAP not yet installed — installing from store ..."
        for _i in \$(seq 1 5); do
          snap install "\$SNAP" --channel=${OTBR_SNAP_CHANNEL} --devmode && break
          echo "Snap install attempt \$_i failed; retrying in 15s ..."
          sleep 15
        done
      fi

      # -- Disable snap before connecting interfaces --------------------------
      # snap disable prevents services from auto-restarting during snap connect
      # calls.  snap enable is called below — before any snap set — so the
      # configure hook can find /snap/<snap>/current.  snap start brings up the
      # agent once all settings are in place.
      snap disable "\${SNAP}" 2>/dev/null || true

      # -- Connect interfaces ------------------------------------------------
      # Dynamically connect every plug the snap exposes that is not yet
      # connected.  This adapts to whatever plug names the installed snap
      # version actually declares, avoiding "no plug named X" noise.
      while IFS= read -r _plug; do
        [[ -n "\$_plug" ]] || continue
        snap connect "\${SNAP}:\${_plug}" 2>/dev/null || true
      done < <(snap connections --all "\${SNAP}" 2>/dev/null \
        | awk 'NR>1 && \$3=="-" {split(\$2,a,":"); if (a[2]!="") print a[2]}')

      # -- Install chip-tool (Matter commissioning — BLE+Thread and Thread-only)
      if ! snap list chip-tool &>/dev/null; then
        _ct_file=\$(ls /opt/chip-tool/*.snap 2>/dev/null | head -1)
        if [[ -n "\$_ct_file" ]]; then
          snap install --dangerous "\$_ct_file" || true
        fi
        if ! snap list chip-tool &>/dev/null; then
          echo "chip-tool not yet installed — installing from store ..."
          for _i in \$(seq 1 5); do
            snap install chip-tool --channel=${CHIP_TOOL_SNAP_CHANNEL} && break
            echo "chip-tool install attempt \$_i failed; retrying in 15s ..."
            sleep 15
          done
        fi
        unset _ct_file
      fi

      # -- Re-enable snap so the configure hook can find /snap/<name>/current --
      # snap set (below and inside rcp-update.sh) triggers the configure hook;
      # the hook uses readlink /snap/<name>/current which only exists while the
      # snap is enabled.  Enabling here is safe: autostart=false (set by the
      # install hook) keeps all services stopped until we explicitly start them.
      snap enable "\${SNAP}" 2>/dev/null || true

      # -- Silence AppArmor devmode audit noise for ttyACM0 ------------------
      # The snap runs in --devmode (needed for ip6tables/ipset CAP_NET_ADMIN).
      # Devmode logs every access that strict mode would deny; the serial-port
      # plug is not connected to a slot covering /dev/ttyACM*, so every Spinel
      # read generates an ALLOWED audit record.  Adding an explicit allow via
      # the local override stops AppArmor from auditing these reads.
      # /etc/apparmor.d/local/ is #include'd by the snap-generated profile and
      # survives snap refreshes — snapd regenerates the profile but always
      # re-includes this directory.
      mkdir -p /etc/apparmor.d/local
      cat > /etc/apparmor.d/local/snap.openthread-border-router.otbr-agent <<'AAEOF'
  # Explicit allow for USB CDC-ACM RCP (ESP32-C6); suppresses devmode audit noise.
  /dev/ttyACM* rw,
AAEOF
      _aa_profile=/var/lib/snapd/apparmor/profiles/snap.openthread-border-router.otbr-agent
      if [[ -f "\$_aa_profile" ]]; then
          apparmor_parser -r "\$_aa_profile" 2>/dev/null || true
      fi

      # -- Update/flash RCP firmware; sets snap radio-url ------------------
      mkdir -p /var/lib/otbr
      /usr/local/sbin/otbr-rcp-update.sh

      # -- Snap-dependent pre-start setup (skip if snap install failed) -------
      _snap_ok=0
      if snap list "\$SNAP" &>/dev/null; then
        _snap_ok=1

        # -- Determine backbone interface ------------------------------------
        INFRA=wlan0
        if ip link show eth0 2>/dev/null | grep -q 'LOWER_UP'; then
          INFRA=eth0
        fi
        echo "Backbone interface: \$INFRA"

        # -- Configure snap (radio-url already set by otbr-rcp-update.sh) --
        # autostart=false keeps the configure hook from starting the agent here;
        # we start it explicitly after UFW is up and the dataset is committed.
        snap set "\$SNAP" \
          infra-if="\$INFRA" \
          thread-if=wpan0 \
          autostart=false

        # -- Ensure ipset kernel modules are loaded before snap start ---------
        # otbr-setup (a snap service dependency) uses ipset to manage firewall
        # rules; it fails with "Cannot open session to kernel" if ip_set isn't
        # loaded.  modules-load.d handles subsequent boots; modprobe covers the
        # first boot before systemd-modules-load has run those rules.
        modprobe ip_set ip_set_hash_net xt_set 2>/dev/null || true
      else
        echo "WARNING: \$SNAP not installed — skipping OTBR configuration."
        echo "         Re-run /usr/local/sbin/otbr-firstboot.sh once the snap store is reachable."
      fi

      # -- Configure UFW firewall (always runs, before snap starts) ----------
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
      # Matter Server WebSocket API (Home Assistant or other controller connects here)
      if [[ "${DEPLOY_MATTER_SERVER}" -eq 1 ]]; then
        ufw allow 5580/tcp comment 'Matter Server WebSocket'
      fi
      ufw --force enable
      echo "UFW enabled."

      # -- Start snap service (last step — firewall is up before snap runs) --
      if [[ "\$_snap_ok" -eq 1 ]]; then
        snap start --enable "\$SNAP"

        # -- Start interface watcher for immediate eth0/wlan0 failover ------
        systemctl start otbr-ifwatcher.service || true

        # -- Seed Thread dataset ---------------------------------------------
        # Wait up to 60 s for the agent socket AND its settings storage.
        # The socket becomes ready almost immediately, but the agent may not
        # have finished initialising its on-disk settings db yet.  Committing
        # a dataset before the db is ready returns "Done" but writes nothing.
        # We detect readiness by waiting for the settings data file to appear
        # in the snap's common directory (it is created on first write).
        _SETTINGS_DIR=/var/snap/openthread-border-router/common/thread-data
        for i in \$(seq 1 60); do
          "\$SNAP".ot-ctl state 2>/dev/null \
            && [[ \$(ls "\$_SETTINGS_DIR"/*.data 2>/dev/null | wc -l) -ge 1 ]] \
            && break
          sleep 1
        done

        # -- Clear any stale TLVs cached in RCP NVM before committing dataset --
        echo "Factory-resetting RCP to clear cached TLVs ..."
        "\$SNAP".ot-ctl factoryreset || true
        # Agent reconnects to RCP after reset; wait for it to be ready again.
        for i in \$(seq 1 30); do
          "\$SNAP".ot-ctl state 2>/dev/null && break
          sleep 2
        done

        echo "Committing Thread dataset TLV ..."
        "\$SNAP".ot-ctl dataset set active "\$TLV"
        "\$SNAP".ot-ctl ifconfig up
        "\$SNAP".ot-ctl thread start

        # Verify the dataset landed: read it back and compare the TLV.
        _readback=\$("\$SNAP".ot-ctl dataset active -x 2>/dev/null | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]' || true)
        _expected=\$(echo "\$TLV" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
        if [[ "\$_readback" != "\$_expected" ]]; then
          echo "WARNING: dataset readback mismatch — retrying after 5 s ..."
          sleep 5
          "\$SNAP".ot-ctl dataset set active "\$TLV"
          "\$SNAP".ot-ctl ifconfig up
          "\$SNAP".ot-ctl thread start
        fi

        # Dataset is committed and interface is up — now enable autostart so
        # subsequent boots bring the agent up automatically via snapd.
        snap set "\$SNAP" autostart=true
      fi

      # -- Install python-matter-server -----------------------------------------
      # Provides a WebSocket Matter controller on port 5580.
      # Home Assistant can point its Matter integration at ws://<hostname>:5580
      # to control Thread devices through this fabric instead of its local one.
      if [[ "${DEPLOY_MATTER_SERVER}" -eq 1 ]]; then
        echo "Installing python-matter-server ..."
        apt-get install -y --no-install-recommends bluetooth
        python3 -m venv /var/lib/matter-server/venv
        /var/lib/matter-server/venv/bin/pip install --upgrade pip wheel
        /var/lib/matter-server/venv/bin/pip install 'python-matter-server[server]'
        mkdir -p /var/lib/matter-server/state
        systemctl daemon-reload
        systemctl enable matter-server.service
        systemctl start matter-server.service
        echo "matter-server running on ws://\$(hostname -I | awk '{print \$1}'):5580"
      fi

      # Mark first-boot complete so the tryboot second boot doesn't re-run us.
      mkdir -p /var/lib/otbr
      touch /var/lib/otbr/firstboot-done

      # Clean up any tryboot assets flash-kernel may have written to
      # /boot/firmware/new/ during the apt-triggered dracut/flash-kernel run.
      # Without piboot-try, those files would never be applied and only
      # cause a stale-assets MOTD banner on subsequent logins.
      rm -rf /boot/firmware/new/ 2>/dev/null || true

      echo "OTBR first-boot complete."

  - path: /etc/systemd/system/matter-server.service
    owner: root:root
    permissions: '0644'
    content: |
      [Unit]
      Description=Matter Server (python-matter-server)
      Documentation=https://github.com/home-assistant-libs/python-matter-server
      After=network-online.target bluetooth.service snap.openthread-border-router.otbr-agent.service
      Wants=network-online.target bluetooth.service

      [Service]
      Type=simple
      ExecStart=/var/lib/matter-server/venv/bin/matter-server --storage-path /var/lib/matter-server/state --port 5580 --log-level info
      Restart=on-failure
      RestartSec=10
      StandardOutput=journal
      StandardError=journal

      [Install]
      WantedBy=multi-user.target

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
  - systemctl enable otbr-boot-cleanup.service
  - systemctl enable otbr-ifwatcher.service
  - systemctl enable otbr-rcp-update.service
  - systemctl enable otbr-weekly-reboot.timer

  # Reload udev rules so the ESP32 ModemManager-ignore rule (written above by
  # write_files) takes effect for devices already enumerated at boot.
  - udevadm control --reload-rules
  - udevadm trigger --subsystem-match=usb
  # Mask ModemManager permanently — this OTBR device never needs it.
  # Masking (not just stopping) prevents systemd from restarting it.
  # The actual stop happens inside otbr-rcp-update.sh before each build/flash.
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
    # Expand the root partition to fill the SD card before mounting/chroot so
    # the chroot has full disk space.  Cloud-init growpart would do this on
    # first boot, but that's too late for our pre-seeding step.
    info "Expanding root partition to fill ${TARGET_DEV} ..."
    sudo parted -s "$TARGET_DEV" resizepart 2 100%
    sudo partprobe "$TARGET_DEV" 2>/dev/null || true
    sudo e2fsck -f -y "$_ROOT_PART" >/dev/null 2>&1 || true
    sudo resize2fs "$_ROOT_PART"
    info "Root partition expanded."

    _ROOT_DIR=$(mktemp -d /tmp/uc-root-XXXXXX)
    if sudo mount "$_ROOT_PART" "$_ROOT_DIR" 2>/dev/null; then
        info "Mounted root partition $_ROOT_PART — writing kernel config..."
        sudo mkdir -p \
            "$_ROOT_DIR/etc/modprobe.d" \
            "$_ROOT_DIR/etc/modules-load.d" \
            "$_ROOT_DIR/etc/udev/rules.d"

        sudo tee "$_ROOT_DIR/etc/modules-load.d/otbr.conf" > /dev/null <<'MODULES'
tun
ip_set
ip_set_hash_net
xt_set
MODULES

        sudo tee "$_ROOT_DIR/etc/modprobe.d/brcmfmac.conf" > /dev/null <<'BRCM'
options brcmfmac roamoff=1 feature_disable=0x82000
BRCM

        sudo tee "$_ROOT_DIR/etc/modprobe.d/cfg80211.conf" > /dev/null <<'CFG'
options cfg80211 ieee80211_regdom=US
CFG

        sudo tee "$_ROOT_DIR/etc/udev/rules.d/99-wifi-power.rules" > /dev/null <<'UDEV'
ACTION=="add", SUBSYSTEM=="net", KERNEL=="wlan*", RUN+="/usr/sbin/iw reg set US"
ACTION=="add", SUBSYSTEM=="net", KERNEL=="wlan*", RUN+="/usr/sbin/iw dev %k set country US"
ACTION=="add", SUBSYSTEM=="net", KERNEL=="wlan*", RUN+="/usr/sbin/iw dev %k set power_save off"
UDEV

        # flash-kernel machine type — prevents it from guessing Pi 5 DTB when
        # the file is absent (happens on apt upgrade → dracut → flash-kernel).
        # /etc/flash-kernel.conf is the correct override; /etc/default/flash-kernel
        # only sets env vars and doesn't affect machine detection.
        sudo mkdir -p "$_ROOT_DIR/etc"
        printf 'MACHINE="Raspberry Pi 4 Model B"\n' \
            | sudo tee "$_ROOT_DIR/etc/flash-kernel.conf" > /dev/null
        info "Written /etc/flash-kernel.conf (MACHINE=Raspberry Pi 4 Model B)"

        # Pre-load development assets so the Pi doesn't need to download them
        # on first boot.  All sections are conditional — skipped if not cached.
        # Only done on a full flash; cloud-init-only updates leave the live Pi
        # filesystem alone.
        if [[ "$CLOUD_INIT_ONLY" -eq 0 ]]; then

            # ------------------------------------------------------------------
            # Seed /var/log/otbr-firstboot.log so it exists from first insert.
            # otbr-firstboot.sh opens it with exec >>; having it pre-created
            # means `tail -f` works immediately without waiting for the script
            # to run.
            # ------------------------------------------------------------------
            sudo mkdir -p "$_ROOT_DIR/var/log"
            printf '=== otbr-firstboot.log created at flash time: %s ===\n=== insert SD card and power on — first-boot provisioning will begin shortly ===\n' \
                "$(date '+%Y-%m-%dT%H:%M:%S%z')" \
                | sudo tee "$_ROOT_DIR/var/log/otbr-firstboot.log" > /dev/null
            info "Seeded /var/log/otbr-firstboot.log on root partition."

            # ------------------------------------------------------------------
            # Update (or clone) ESP-IDF cache so the pre-seeded SD card has
            # the latest source.  Doing this here means the Pi's boot-time
            # git fetch has nothing (or almost nothing) to pull.
            # ------------------------------------------------------------------
            _IDF_CACHE="${SCRIPT_DIR}/cache/esp-idf"
            if [[ "${PULL_LATEST_REPOS:-1}" -ne 0 ]]; then
                info "Resolving latest ESP-IDF release tag ..."
                _idf_tag=$(git ls-remote --tags --sort=-v:refname \
                    https://github.com/espressif/esp-idf.git 'v[0-9]*' \
                    | grep -oE $'\trefs/tags/v[0-9]+\.[0-9]+\.[0-9]+$' \
                    | head -1 | sed 's|.*refs/tags/||')
                [[ -n "$_idf_tag" ]] || die "Could not resolve latest ESP-IDF release tag"
                info "Latest ESP-IDF release: $_idf_tag"

                if [[ -d "$_IDF_CACHE/.git" ]]; then
                    _idf_cur=$(git -C "$_IDF_CACHE" describe --tags --exact-match 2>/dev/null \
                        || git -C "$_IDF_CACHE" rev-parse --short HEAD)
                    if [[ "$_idf_cur" != "$_idf_tag" ]]; then
                        info "Updating ESP-IDF cache: $_idf_cur → $_idf_tag"
                        git -C "$_IDF_CACHE" fetch --depth 1 origin tag "$_idf_tag"
                        git -C "$_IDF_CACHE" checkout "$_idf_tag"
                        git -C "$_IDF_CACHE" submodule update --init --recursive --depth 1
                        info "ESP-IDF cache updated to $_idf_tag."
                    else
                        info "ESP-IDF cache already at $_idf_tag."
                    fi
                elif [[ ! -d "$_IDF_CACHE" ]]; then
                    info "Cloning ESP-IDF $_idf_tag into cache ..."
                    git -c advice.detachedHead=false clone --depth 1 --branch "$_idf_tag" \
                        --recurse-submodules --shallow-submodules \
                        https://github.com/espressif/esp-idf.git "$_IDF_CACHE"
                    info "ESP-IDF cloned at $_idf_tag."
                fi
            else
                if [[ -d "$_IDF_CACHE/.git" ]]; then
                    _idf_cur=$(git -C "$_IDF_CACHE" describe --tags --exact-match 2>/dev/null \
                        || git -C "$_IDF_CACHE" rev-parse --short HEAD 2>/dev/null || echo 'unknown')
                    info "PULL_LATEST_REPOS=0 — skipping ESP-IDF update; cache at: ${_idf_cur}"
                else
                    warn "PULL_LATEST_REPOS=0 and no ESP-IDF cache found — Pi will clone on first boot."
                fi
            fi

            # ------------------------------------------------------------------
            # Pre-load ESP-IDF source BEFORE the chroot so install.sh is
            # available inside it.  Build/ dirs are excluded — they hold
            # host-arch (x86_64) objects that are useless on the Pi.
            # ------------------------------------------------------------------
            if [[ -d "$_IDF_CACHE" ]]; then
                _idf_size=$(du -sh "$_IDF_CACHE" | cut -f1)
                info "Pre-loading ESP-IDF source (${_idf_size}, skipping build/ dirs) → /opt/esp-idf ..."
                sudo mkdir -p "$_ROOT_DIR/opt/esp-idf"
                sudo rsync -a --chown=root:root --exclude='build/' \
                    "${_IDF_CACHE}/" "$_ROOT_DIR/opt/esp-idf"
                info "ESP-IDF source pre-loaded."
            else
                info "cache/esp-idf not found — Pi will clone ESP-IDF on first boot."
            fi

            # ------------------------------------------------------------------
            # Decide whether to build RCP firmware inside the chroot.
            # The ESP32-C6 binary is RISC-V — identical bytes whether the
            # cross-compiler ran on x86_64 or arm64.  Building here populates
            # the host cache and pre-seeds the SD card so the Pi skips the
            # build entirely on first boot.
            # ------------------------------------------------------------------
            if [[ "${SKIP_CHROOT:-0}" -eq 1 ]]; then
                info "SKIP_CHROOT=1 — skipping arm64 chroot; first-boot will handle apt packages."
            else

            _do_rcp_build=0
            if [[ ! -f "${SCRIPT_DIR}/cache/esp32/rcp/esp_ot_rcp.bin" ]]; then
                if [[ -d "$_ROOT_DIR/opt/esp-idf" ]]; then
                    _do_rcp_build=1
                    info "No cached RCP firmware — will build inside arm64 chroot (~10 min)."
                else
                    info "No ESP-IDF source and no cached firmware — Pi will build on first boot."
                fi
            else
                info "Cached RCP firmware found — skipping chroot build."
            fi

            # ------------------------------------------------------------------
            # Chroot: apt upgrade + install + ESP-IDF toolchain + optional build.
            # The binfmt_misc entry for qemu-aarch64 uses the F (fix-binary)
            # flag so the kernel holds the interpreter open — no copy needed.
            #
            # The setup script is written to a temp file (not passed via -c)
            # so the host can expand ${_do_rcp_build} into the script body.
            # Literal backslashes must be doubled (\\) and literal $ escaped (\$).
            # ------------------------------------------------------------------
            info "Running arm64 chroot — apt upgrade + install + ESP-IDF toolchain ..."
            sudo mkdir -p "$_ROOT_DIR/tmp"
            sudo tee "$_ROOT_DIR/tmp/otbr-chroot-setup.sh" > /dev/null <<CHROOTSCRIPT
#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
# Suppress needrestart kernel-upgrade check — running kernel is always
# the host kernel, never the arm64 raspi kernel we're installing.
export NEEDRESTART_MODE=l NEEDRESTART_SUSPEND_THREADS=1
mkdir -p /etc/needrestart/conf.d
printf '%s\n' '\$nrconf{kernelhints} = 0;' > /etc/needrestart/conf.d/no-chroot-hints.conf

${_APT_PROXY_CHROOTCMD}

apt-get update -q
apt-get upgrade -y
apt-get install -y \\
    avahi-daemon iw zstd \\
    git cmake ninja-build \\
    python3-venv python3-pip \\
    python3-dbus python3-gi \\
    libusb-1.0-0

if [[ -x /opt/esp-idf/install.sh ]]; then
    export IDF_TOOLS_PATH=/opt/esp-idf-tools
    export PIP_QUIET=1
    /opt/esp-idf/install.sh esp32c6

    if [[ "${_do_rcp_build}" == "1" ]]; then
        echo "[chroot] Building ESP32-C6 RCP firmware with arm64 toolchain ..."
        source /opt/esp-idf/export.sh
        set -euo pipefail
        _rcp_dir=/opt/esp-idf/examples/openthread/ot_rcp
        cat > "\${_rcp_dir}/sdkconfig.defaults.otbrstack" <<'SDKEOF'
CONFIG_ESP_CONSOLE_SECONDARY_USB_SERIAL_JTAG=y
CONFIG_OPENTHREAD_RCP_USB_SERIAL_JTAG=y
CONFIG_OPENTHREAD_RADIO=y
CONFIG_OPENTHREAD_RADIO_NATIVE=y
CONFIG_ESP_COEX_SW_COEXIST_ENABLE=n
SDKEOF
        cd "\${_rcp_dir}"
        export SDKCONFIG_DEFAULTS="sdkconfig.defaults;sdkconfig.defaults.otbrstack"
        idf.py set-target esp32c6
        idf.py build
        echo "[chroot] RCP firmware build complete."
    fi
fi

# Free space consumed by downloaded .deb archives and man-page cache.
# This reclaims ~100-150 MB before snap/ESP-IDF assets are copied in.
apt-get clean
rm -rf /var/cache/man/* /var/lib/apt/lists/*
CHROOTSCRIPT
            sudo chmod +x "$_ROOT_DIR/tmp/otbr-chroot-setup.sh"
            # Temporarily replace resolv.conf — on Ubuntu 26.04 it is a
            # dangling symlink to /run/systemd/resolve/stub-resolv.conf which
            # doesn't exist in a bare mounted image.
            sudo rm -f "$_ROOT_DIR/etc/resolv.conf"
            echo "nameserver 8.8.8.8" | sudo tee "$_ROOT_DIR/etc/resolv.conf" > /dev/null
            # Bind-mount the host-side toolchain cache at /opt/esp-idf-tools so
            # install.sh writes the arm64 riscv32-esp-elf toolchain to the HOST
            # cache instead of the 4 GB SD card root partition (which has no
            # room for it).  The Pi downloads the toolchain on first boot.
            _IDF_TOOLS_CACHE="${SCRIPT_DIR}/cache/esp-idf-tools-arm64"
            mkdir -p "$_IDF_TOOLS_CACHE"
            sudo mkdir -p "$_ROOT_DIR/opt/esp-idf-tools"
            sudo mount --bind "$_IDF_TOOLS_CACHE" "$_ROOT_DIR/opt/esp-idf-tools"
            sudo mount --bind /proc    "$_ROOT_DIR/proc"
            sudo mount --bind /sys     "$_ROOT_DIR/sys"
            sudo mount --bind /dev     "$_ROOT_DIR/dev"
            sudo mount --bind /dev/pts "$_ROOT_DIR/dev/pts"
            sudo chroot "$_ROOT_DIR" /bin/bash /tmp/otbr-chroot-setup.sh \
                || warn "chroot operation encountered errors — continuing."
            sudo umount "$_ROOT_DIR/dev/pts"         2>/dev/null || true
            sudo umount "$_ROOT_DIR/dev"             2>/dev/null || true
            sudo umount "$_ROOT_DIR/sys"             2>/dev/null || true
            sudo umount "$_ROOT_DIR/proc"            2>/dev/null || true
            sudo umount "$_ROOT_DIR/opt/esp-idf-tools" 2>/dev/null || true
            sudo rm -f "$_ROOT_DIR/tmp/otbr-chroot-setup.sh"
            # Restore the standard Ubuntu 26.04 resolv.conf symlink
            sudo rm -f "$_ROOT_DIR/etc/resolv.conf"
            sudo ln -sf /run/systemd/resolve/stub-resolv.conf \
                "$_ROOT_DIR/etc/resolv.conf"
            info "chroot complete."

            # ------------------------------------------------------------------
            # If we built RCP firmware in the chroot, copy it to the host cache
            # so subsequent flashes skip the build entirely.  The copy below
            # then seeds the binary onto the SD card.
            # ------------------------------------------------------------------
            _built_bin="$_ROOT_DIR/opt/esp-idf/examples/openthread/ot_rcp/build/esp_ot_rcp.bin"
            if [[ "$_do_rcp_build" -eq 1 && -f "$_built_bin" ]]; then
                mkdir -p "${SCRIPT_DIR}/cache/esp32/rcp"
                sudo cp "$_built_bin" "${SCRIPT_DIR}/cache/esp32/rcp/esp_ot_rcp.bin"
                sudo chown "$(id -u):$(id -g)" \
                    "${SCRIPT_DIR}/cache/esp32/rcp/esp_ot_rcp.bin"
                info "RCP firmware cached: cache/esp32/rcp/esp_ot_rcp.bin"
            elif [[ "$_do_rcp_build" -eq 1 ]]; then
                warn "RCP build was requested but binary not found — Pi will build on first boot."
            fi
            unset _built_bin _do_rcp_build

            fi  # SKIP_CHROOT

            # ------------------------------------------------------------------
            # Patch brcmfmac NVRAM with ccode=US on the host-mounted root
            # partition.  The firmware reads this country code before the kernel
            # regulatory stack initialises, eliminating reason -52 channel
            # rejections that prevent WiFi association.  Runs unconditionally so
            # SKIP_CHROOT=1 does not silently bypass the fix.
            # ------------------------------------------------------------------
            _nvram_zst=$(sudo find "$_ROOT_DIR/usr/lib/firmware/brcm" \
                -name 'brcmfmac43455-sdio.raspberrypi,4-model-b.txt.zst' \
                2>/dev/null | head -1)
            if [[ -n "$_nvram_zst" ]]; then
                if command -v zstd &>/dev/null; then
                    _nvram_tmp=$(mktemp /tmp/nvram-pi4b-XXXXXX.txt)
                    sudo zstd -d "$_nvram_zst" -o "$_nvram_tmp" --force -q
                    printf '\nccode=US\nregrev=0\n' | sudo tee -a "$_nvram_tmp" > /dev/null
                    sudo zstd -19 -f "$_nvram_tmp" -o "$_nvram_zst" -q
                    sudo rm -f "$_nvram_tmp"
                    unset _nvram_tmp
                    info "brcmfmac NVRAM patched with ccode=US (eliminates reason -52 on 5GHz)"
                else
                    warn "zstd not found on host — brcmfmac NVRAM not patched; WiFi 5GHz may fail with reason -52"
                fi
            else
                warn "brcmfmac NVRAM file not found on root partition — skipping WiFi country patch"
            fi
            unset _nvram_zst

            # ------------------------------------------------------------------
            # Download arm64 snaps from Snap Store REST API.
            # cache/snap/ holds host-arch (amd64) for Incus x64 VMs;
            # cache/snap-arm64/ holds arm64 for Raspberry Pi.
            # `snap download` has no --arch flag, so we use the v2 API directly.
            #
            # The API returns channel names without the "latest/" track prefix
            # (e.g. "edge" not "latest/edge"), so strip it before comparing.
            # ------------------------------------------------------------------
            _SNAP_ARM64="${SCRIPT_DIR}/cache/snap-arm64"
            mkdir -p "$_SNAP_ARM64"

            # _cache_snap <snap-name> <channel>
            # Downloads .snap into _SNAP_ARM64 if not already cached.
            _cache_snap() {
                local _sname="$1" _channel="$2"
                if compgen -G "${_SNAP_ARM64}/${_sname}_*.snap" > /dev/null 2>&1; then
                    info "${_sname} arm64 snap already cached: $(basename "$(ls "${_SNAP_ARM64}/${_sname}_"*.snap | head -1)")"
                    return 0
                fi
                info "Fetching arm64 ${_sname} metadata (channel: ${_channel}) ..."
                local _info=""
                if ! _info=$(curl -fsSL \
                        --retry 3 --retry-delay 5 --max-time 60 \
                        -H 'Snap-Device-Series: 16' \
                        -H 'Snap-Device-Architecture: arm64' \
                        "https://api.snapcraft.io/v2/snaps/info/${_sname}?fields=channel-map,snap-id,download,revision"); then
                    warn "Snap Store API unreachable for ${_sname} — Pi will install from store."
                    return 1
                fi
                local _snap_id _dl_url _revision _sha3
                read -r _snap_id _dl_url _revision _sha3 < <(echo "$_info" | python3 -c "
import json, sys
d = json.load(sys.stdin)
snap_id = d.get('snap-id', '')
channel = sys.argv[1]
# API omits 'latest/' prefix for the default track
api_ch = channel[len('latest/'):] if channel.startswith('latest/') else channel
for e in d.get('channel-map', []):
    c = e.get('channel', {})
    if c.get('name') == api_ch and c.get('architecture') == 'arm64':
        dl = e.get('download', {})
        print(snap_id, dl.get('url',''), e.get('revision',''), dl.get('sha3-384',''))
        sys.exit(0)
print(snap_id, '', '', '')
" "$_channel")
                if [[ -z "$_dl_url" ]]; then
                    warn "No arm64 ${_sname} on channel ${_channel} — Pi will install from store."
                    return 1
                fi
                local _base="${_sname}_${_revision}"
                info "Downloading ${_base}.snap (arm64, ${_channel}) ..."
                if curl -fL --progress-bar \
                        --retry 3 --retry-delay 10 --max-time 600 \
                        -o "${_SNAP_ARM64}/${_base}.snap" \
                        "$_dl_url"; then
                    info "${_sname} arm64 snap cached: ${_base}"
                else
                    warn "Failed to download ${_sname} arm64 snap — Pi will install from store."
                    rm -f "${_SNAP_ARM64}/${_base}.snap"
                    return 1
                fi
            }

            _cache_snap "openthread-border-router" "${OTBR_SNAP_CHANNEL}"
            _cache_snap "chip-tool" "${CHIP_TOOL_SNAP_CHANNEL}"

            # No seed.yaml: snapd requires store-signed snap-revision assertions
            # for offline seeding, and those are not fetchable via the public API
            # (arm64 snap-revision assertions require snapd's internal batch RPC).
            # The /opt/otbr-snap/ fallback in firstboot.sh covers offline install.

            # Pre-built RCP binary — flash_rcp.sh compares sha256 against this;
            # identical hash skips the flash step on first boot.
            if [[ -f "${SCRIPT_DIR}/cache/esp32/rcp/esp_ot_rcp.bin" ]]; then
                sudo mkdir -p "$_ROOT_DIR/var/lib/otbr"
                sudo cp "${SCRIPT_DIR}/cache/esp32/rcp/esp_ot_rcp.bin" \
                    "$_ROOT_DIR/var/lib/otbr/esp_ot_rcp_staged.bin"
                info "RCP binary staged: /var/lib/otbr/esp_ot_rcp_staged.bin"
            fi

            # OTBR snap at /opt/otbr-snap/ — firstboot.sh installs with --dangerous.
            _snap_src=("${_SNAP_ARM64}"/openthread-border-router_*.snap)
            if [[ -f "${_snap_src[0]}" ]]; then
                sudo mkdir -p "$_ROOT_DIR/opt/otbr-snap"
                sudo cp "${_SNAP_ARM64}"/openthread-border-router_*.snap \
                    "$_ROOT_DIR/opt/otbr-snap/"
                info "OTBR snap pre-loaded: $(basename "${_snap_src[0]}")"
            else
                info "arm64 OTBR snap not cached — Pi will install from snap store."
            fi

            # chip-tool snap at /opt/chip-tool/ — firstboot.sh installs with --dangerous.
            _ct_src=$(ls "${_SNAP_ARM64}"/chip-tool_*.snap 2>/dev/null | head -1)
            if [[ -n "$_ct_src" ]]; then
                sudo mkdir -p "$_ROOT_DIR/opt/chip-tool"
                sudo cp "${_SNAP_ARM64}"/chip-tool_*.snap "$_ROOT_DIR/opt/chip-tool/"
                info "chip-tool snap pre-loaded: $(basename "$_ct_src")"
            else
                info "arm64 chip-tool not cached — Pi will install from snap store."
            fi
            unset _SNAP_ARM64 _snap_src _ct_src

        fi  # CLOUD_INIT_ONLY=0

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
info " Logs: otbrstack logs -f ${OTBR_HOSTNAME}"
info " Cloud-init: sudo cloud-init status --long"
info "============================================================"