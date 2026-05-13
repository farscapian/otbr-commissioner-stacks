#cloud-config

# Ubuntu Server 24.04 amd64 cloud-init for Incus VM and system container.
# Differences from the QEMU (test-vm) variant:
#   - Networking managed by Incus; no custom netplan or dual-NIC setup needed
#   - sim-rcp runs INSIDE the instance (native x86_64), no host PTY bridge required
#   - Disk shares arrive via virtiofs (VM) or Incus bind-mount (container);
#     the firstboot script handles both transparently
#   - No ifwatcher — single NIC, backbone is always the default route interface
#   - No initramfs lz4 tweak — native x86_64 doesn't need it

packages:
  - socat

write_files:

  # Load USB serial drivers at boot.
  - path: /etc/modules-load.d/thread-rcp.conf
    owner: root:root
    permissions: '0644'
    content: |
      cdc_acm
      cp210x

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

      echo "=== OTBR first-boot (incus) $(date) ==="

      # -- Load RCP kernel modules (may be no-op in system containers) -------
      modprobe cdc_acm 2>/dev/null || true
      modprobe cp210x  2>/dev/null || true
      sleep 1

      # -- Resolve RCP device ------------------------------------------------
      RCP=$(ls /dev/ttyUSB* /dev/ttyACM* 2>/dev/null | head -1 || true)

      if [[ -z "${RCP:-}" ]]; then
        # No real hardware — try sim binary from virtiofs share (VM) or
        # bind-mount (container). Both land at /mnt/ot-rcp-sim/ot-rcp.
        SIM_DIR=/mnt/ot-rcp-sim
        mkdir -p "$SIM_DIR"
        # VM: needs explicit virtiofs mount; container: already bind-mounted, mount is a no-op
        mount -t virtiofs ot_rcp_sim "$SIM_DIR" 2>/dev/null || true

        SIM_BIN="${SIM_DIR}/ot-rcp"
        if [[ -x "$SIM_BIN" ]]; then
          echo "Starting simulated ot-rcp from $SIM_BIN ..."
          mkdir -p /run/ot-sim
          socat PTY,link=/run/ot-sim/tty,raw,echo=0,b460800 \
                EXEC:"$SIM_BIN 1",pty,raw,b460800 &
          for i in $(seq 1 20); do [[ -e /run/ot-sim/tty ]] && break || sleep 0.1; done
          [[ -e /run/ot-sim/tty ]] || { echo "ERROR: sim PTY never appeared"; exit 1; }
          # Resolve symlink — some snap AppArmor profiles need the real /dev/pts/N path
          RCP=$(readlink -f /run/ot-sim/tty)
          echo "Simulated RCP at $RCP"
        else
          echo "ERROR: no RCP device and no sim binary at $SIM_BIN"
          exit 1
        fi
      fi
      echo "RCP device: $RCP"

      # -- Wait for snapd ----------------------------------------------------
      for i in $(seq 1 30); do
        snap version &>/dev/null && break || { echo "waiting for snapd ($i)..."; sleep 2; }
      done

      # -- Install snap from virtiofs/bind-mount cache or store --------------
      # VM: virtiofs mount needed first; container: already at /mnt/snap-cache
      SNAP_MOUNT=/mnt/snap-cache
      mkdir -p "$SNAP_MOUNT"
      mount -t virtiofs snap_cache "$SNAP_MOUNT" 2>/dev/null || true

      SNAP_FILE=$(ls  "$SNAP_MOUNT"/${SNAP}_*.snap   2>/dev/null | head -1 || true)
      ASSERT_FILE=$(ls "$SNAP_MOUNT"/${SNAP}_*.assert 2>/dev/null | head -1 || true)

      if [[ -n "$SNAP_FILE" && -n "$ASSERT_FILE" ]]; then
        echo "Installing $SNAP from cache: $(basename "$SNAP_FILE")"
        snap ack "$ASSERT_FILE"
        snap install "$SNAP_FILE"
      else
        echo "Snap cache empty or unavailable — installing from store"
        snap install "$SNAP" --channel=latest/stable
      fi

      # -- Connect interfaces ------------------------------------------------
      snap connect "${SNAP}:serial-port"     snapd:serial  || true
      snap connect "${SNAP}:network-control"               || true
      snap connect "${SNAP}:firewall-control"              || true
      snap connect "${SNAP}:network-observe"               || true
      snap connect "${SNAP}:raw-usb"                       || true

      # -- Backbone interface (lowest-metric default route) ------------------
      INFRA=$(ip route get 1.1.1.1 2>/dev/null \
              | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' \
              | head -1 || true)
      INFRA=${INFRA:-eth0}
      echo "Backbone interface: $INFRA"

      # -- Configure and start snap ------------------------------------------
      snap set "$SNAP" \
        infra-if="$INFRA" \
        radio-url="spinel+hdlc+uart://${RCP}?uart-baudrate=460800" \
        nat64=false \
        dns64=false

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
  - systemctl daemon-reload
  - nohup /usr/local/sbin/otbr-firstboot.sh &

final_message: |
  OTBR cloud-init complete. First-boot configuration running in background.
  Run: incus exec <name> -- tail -f /var/log/otbr-firstboot.log
