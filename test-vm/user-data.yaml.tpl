#cloud-config

# Ubuntu Server 24.04 arm64 (QEMU virt) adaptation of flash-otbr-core.sh cloud-init.
# Differences from the raspi image:
#   - No WiFi (QEMU virt has no wireless NIC)
#   - Dual NIC: LAN via MACVTAP (MAC 52:54:00:aa:bb:01, real router DHCP, metric 100)
#               MGMT via NAT    (MAC 52:54:00:aa:bb:02, host SSH only,    metric 200)
#   - Netplan matches by MAC so interface naming doesn't matter
#   - OTBR backbone interface auto-detected via `ip route get` (picks lower-metric LAN NIC)
#   - Snap installed from virtio-9p snap-cache share if present; falls back to store
#   - No `snap wait system seed.loaded` (Ubuntu Core only)
#   - python3-dbus / python3-gi installed via apt so ifwatcher uses D-Bus mode

packages:
  - python3-dbus
  - python3-gi
  - iw
  - liblz4-tool

write_files:

  # Pre-write authorized_keys during modules:config (~122s kernel time) so SSH auth
  # works long before cloud-init's ssh module runs in modules:final (~943s).
  - path: /home/ubuntu/.ssh/authorized_keys
    owner: ubuntu:ubuntu
    permissions: '0600'
    content: |
      ${SSH_PUBKEY}

  # Use lz4 for initramfs compression — dramatically faster than gzip on emulated aarch64.
  - path: /etc/initramfs-tools/conf.d/compress.conf
    owner: root:root
    permissions: '0644'
    content: |
      COMPRESS=lz4

  # Load USB serial drivers at boot.
  #   cdc_acm  — ESP32-C6 and other CDC-ACM devices  → /dev/ttyACM*
  #   cp210x   — SONOFF and other Silicon Labs dongles → /dev/ttyUSB*
  - path: /etc/modules-load.d/thread-rcp.conf
    owner: root:root
    permissions: '0644'
    content: |
      cdc_acm
      cp210x

  # Netplan — two NICs matched by fixed MAC address so interface naming doesn't matter.
  #   lan  (52:54:00:aa:bb:01) — MACVTAP, real LAN IP, metric 100 (default route)
  #   mgmt (52:54:00:aa:bb:02) — NAT,     host SSH,    metric 200
  - path: /etc/netplan/00-otbr.yaml
    owner: root:root
    permissions: '0600'
    content: |
      network:
        version: 2
        renderer: networkd
        ethernets:
          lan:
            match:
              macaddress: "52:54:00:aa:bb:01"
            dhcp4: true
            dhcp4-overrides:
              route-metric: 100
            optional: true
          mgmt:
            match:
              macaddress: "52:54:00:aa:bb:02"
            dhcp4: true
            dhcp4-overrides:
              route-metric: 200
            optional: true

  # OTBR interface watcher — D-Bus mode (python3-dbus available on Server)
  - path: /usr/local/sbin/otbr-ifwatcher.py
    owner: root:root
    permissions: '0755'
    content: |
      #!/usr/bin/env python3
      """
      OTBR interface watcher.
      Listens for systemd-networkd D-Bus interface state events and
      reconfigures the openthread-border-router snap backbone interface.
      On QEMU virt the only interface is enp0s1; on real Pi 4B it prefers eth0.
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

      SNAP     = 'openthread-border-router'
      INTERVAL = 10

      def best_iface():
          """Return the interface on the default route (lowest metric wins).
          With dual NIC, the LAN/MACVTAP NIC has metric 100 and will always
          win over the NAT management NIC (metric 200)."""
          import re
          try:
              out = subprocess.check_output(
                  ['ip', 'route', 'get', '1.1.1.1'], text=True, stderr=subprocess.DEVNULL)
              m = re.search(r'\bdev\s+(\S+)', out)
              if m:
                  return m.group(1)
          except subprocess.CalledProcessError:
              pass
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

  # systemd unit for the watcher
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

  # First-boot OTBR configurator — Ubuntu Server variant (no offline snap cache,
  # no snap wait seed.loaded, interface name auto-detected from default route)
  - path: /usr/local/sbin/otbr-firstboot.sh
    owner: root:root
    permissions: '0755'
    content: |
      #!/usr/bin/env bash
      set -euo pipefail
      SNAP=openthread-border-router
      TLV="${THREAD_DATASET_TLV}"
      LOG=/var/log/otbr-firstboot.log
      exec >> "$LOG" 2>&1

      echo "=== OTBR first-boot $(date) ==="

      # -- Resolve RCP device ------------------------------------------------
      modprobe cdc_acm 2>/dev/null || true
      modprobe cp210x  2>/dev/null || true
      sleep 1
      RCP=$(ls /dev/ttyUSB* /dev/ttyACM* 2>/dev/null | head -1 || true)
      if [[ -z "${RCP:-}" ]]; then
        echo "ERROR: no RCP serial device found — is the ESP32-C6 passed through?"
        exit 1
      fi
      echo "RCP device: $RCP"

      # -- Wait for snapd to be ready ----------------------------------------
      for i in $(seq 1 30); do
        snap version &>/dev/null && break || { echo "waiting for snapd ($i)..."; sleep 2; }
      done

      # -- Install snap from 9p cache, fall back to store -------------------
      SNAP_MOUNT=/mnt/snap-cache
      mkdir -p "$SNAP_MOUNT"
      if mount -t 9p -o trans=virtio,ro snap_cache "$SNAP_MOUNT" 2>/dev/null; then
        SNAP_FILE=$(ls "$SNAP_MOUNT"/${SNAP}_*.snap 2>/dev/null | head -1 || true)
        ASSERT_FILE=$(ls "$SNAP_MOUNT"/${SNAP}_*.assert 2>/dev/null | head -1 || true)
        if [[ -n "$SNAP_FILE" && -n "$ASSERT_FILE" ]]; then
          echo "Installing $SNAP from cache: $(basename "$SNAP_FILE")"
          snap ack "$ASSERT_FILE"
          snap install "$SNAP_FILE"
        else
          echo "Cache mounted but snap not found — falling back to store"
          snap install "$SNAP" --channel=latest/stable
        fi
        umount "$SNAP_MOUNT" 2>/dev/null || true
      else
        echo "No snap cache available — installing from store"
        snap install "$SNAP" --channel=latest/stable
      fi

      # -- Connect interfaces ------------------------------------------------
      snap connect "${SNAP}:serial-port"      snapd:serial       || true
      snap connect "${SNAP}:network-control"                     || true
      snap connect "${SNAP}:firewall-control"                    || true
      snap connect "${SNAP}:network-observe"                     || true
      snap connect "${SNAP}:raw-usb"                             || true

      # -- Determine backbone interface (default route interface) ------------
      INFRA=$(ip route get 1.1.1.1 2>/dev/null \
              | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' \
              | head -1 || true)
      INFRA=${INFRA:-enp0s1}
      echo "Backbone interface: $INFRA"

      # -- Configure snap ----------------------------------------------------
      snap set "$SNAP" \
        infra-if="$INFRA" \
        radio-url="spinel+hdlc+uart://${RCP}?uart-baudrate=460800" \
        nat64=false \
        dns64=false

      # -- Start the snap service --------------------------------------------
      snap start --enable "$SNAP"

      # -- Seed Thread dataset -----------------------------------------------
      for i in $(seq 1 30); do
        snap run "$SNAP".ot-ctl state 2>/dev/null && break || sleep 1
      done

      echo "Committing Thread dataset TLV ..."
      snap run "$SNAP".ot-ctl dataset set active "$TLV"
      snap run "$SNAP".ot-ctl dataset commit active
      snap run "$SNAP".ot-ctl ifconfig up
      snap run "$SNAP".ot-ctl thread start

      echo "OTBR first-boot complete."

runcmd:
  - apt-get install -y linux-modules-extra-$(uname -r) || apt-get install -y linux-modules-extra-generic || true
  - netplan apply || true
  - systemctl daemon-reload
  - systemctl enable otbr-ifwatcher.service
  - nohup /usr/local/sbin/otbr-firstboot.sh &

final_message: |
  OTBR cloud-init complete. First-boot configuration running in background.
  SSH in and tail /var/log/otbr-firstboot.log for progress.
  Default credentials: ubuntu / (SSH key from setup.sh, or see run-vm.sh for console access)
