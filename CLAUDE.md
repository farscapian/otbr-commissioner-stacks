# raspi-otbr

Flash a Raspberry Pi 4B with Ubuntu Server 26.04 LTS pre-configured as an OpenThread Border Router (OTBR), using an ESP32-C6 as the Radio Co-Processor (RCP). Combined with a UPS Hat, batteries, and a small USB keypad, this makes a purpose-built Thread OTBR with Bluetooth+Thread commissioning capability via the chiptool snap.

## Key commands

```bash
# Full flash (or cloud-init-only if Ubuntu Server already present)
sudo ./flash-piotbr.sh /dev/sdX

# Force full reflash
sudo ./flash-piotbr.sh -f /dev/sdX

# Skip confirmation prompt
sudo ./flash-piotbr.sh -y /dev/sdX

# Use a specific env file
sudo ./flash-piotbr.sh --env-file=pangolin.env /dev/sdX

# Incus VM test (native x86_64, faster)
sudo ./provision_incus.sh

# Incus system container test
sudo ./provision_incus.sh --container

# Tear down Incus instance
incus delete otbrvm64 --force   # or otbr-ct

# Docker on bare metal (Ubuntu Server/Desktop; installs Docker CE + nginx)
sudo ./otbr-docker-setup.sh

# Snap on bare metal (Ubuntu Server/Desktop; installs/configures openthread-border-router snap)
./otbr-snap-setup.sh
```

## Environment setup

Copy and edit an env file before running:

```bash
cp pangolin.env .env   # or tvpc.env — pick the closest example
# Edit .env: set THREAD_DATASET_TLV, WIFI_SSID, WIFI_PASSWORD, etc.
```

Scripts source the env file directly — no `export` or `sudo -E` needed.

### Relevant .env variables

| Variable | Scripts | Purpose |
|----------|---------|---------|
| `THREAD_DATASET_TLV` | all | Thread Active Operational Dataset (hex). Required. |
| `SSH_PUBKEY` | flash, incus | SSH public key to inject into VM/image |
| `SSH_MGMT_CIDRS` | flash | Space-separated IPs/CIDRs allowed SSH inbound via UFW (empty = allow all) |
| `RCP_FIRMWARE_PATH` | flash | Path to ESP32-C6 RCP app binary (e.g. `cache/esp32/rcp/esp_ot_rcp.bin`) |
| `RCP_FLASH_ADDR` | flash | Flash offset for firmware binary (default: `0x10000` for app-only binary) |
| `RCP_FIRMWARE_URL` | flash | Download URL for RCP firmware (cached as `cache/esp32/rcp/rcp-firmware-cache.bin`) |
| `SIM_RCP_BIN` | incus | Path to pre-built `ot-rcp` Linux simulation binary |
| `SIM_RCP_URL` | incus | Download URL for sim binary (cached as `cache/ot-rcp-sim/ot-rcp`) |
| `DONGLE_VENDOR` | docker | USB vendor ID for Thread dongle (from `udevadm info`) |
| `DONGLE_PRODUCT` | docker | USB product ID for Thread dongle |
| `DONGLE_SERIAL` | docker | USB serial string for Thread dongle (unique; creates stable symlink) |
| `DONGLE_SYMLINK` | docker | Symlink name under `/dev/` (default: `ttyTHREAD`) |
| `BAUD_RATE` | docker | Serial baud rate (default: `460800`) |
| `INFRA_IF` | snap | Backbone/infrastructure network interface (default: auto-detected) |
| `THREAD_IF` | snap | Thread virtual interface (default: `wpan0`) |
| `OT_REPO_PATH` | — | **Removed.** Build-from-source is gone; use `SIM_RCP_BIN`/`SIM_RCP_URL`. |

## Architecture

Four deployment paths share the same `.env` file and `THREAD_DATASET_TLV` variable:

| Script | Target OS | Runtime | RCP detection |
|--------|-----------|---------|---------------|
| `flash-piotbr.sh` | Ubuntu Server 26.04 (Raspberry Pi) | snap (cloud-init) | ESP32-C6 via USB |
| `otbr-snap-setup.sh` | Ubuntu Server/Desktop (bare metal) | snap (live) | ESP32-C6 or Sonoff |
| `otbr-docker-setup.sh` | Ubuntu Server/Desktop (bare metal) | Docker CE + nginx | any USB dongle via udev symlink |
| `provision_incus.sh` | Incus VM or container (test) | snap | simulated or USB passthrough |

- `flash-piotbr.sh` — downloads Ubuntu Server 26.04 arm64+raspi image, verifies SHA-256, flashes to SD, injects cloud-init NoCloud payload into the `system-boot` partition
- `otbr-snap-setup.sh` — detects USB RCP, verifies Spinel firmware, installs and configures the OTBR snap; runs as normal user (`sudo` invoked internally)
- `otbr-docker-setup.sh` — installs Docker CE, pulls `openthread/otbr`, writes udev rule for stable dongle symlink, sets up nginx reverse proxy, joins Thread network; requires root
- `provision_incus.sh` — Incus VM or system container test; native x86_64 or QEMU-emulated arm64
- `incus/` — cloud-init template for Incus VM and container
- `cache/` — all third-party downloaded content (see layout below)
- `artifacts/` — generated shared artifacts (cloud-init output, pyspinel venv)

### Docker architecture notes

`otbr-docker-setup.sh` is designed for **any USB Thread dongle** (Sonoff, ESP32-C6, Silicon Labs, etc.). The dongle is identified by USB vendor/product/serial via udev, which creates a stable `/dev/ttyTHREAD` symlink. nginx exposes the OTBR REST API on `:8080` and the web UI on `:8088`, both proxied from the container's `127.0.0.1` ports.

### Snap architecture notes

`otbr-snap-setup.sh` prefers an **ESP32-C6** (Espressif vendor ID `303a`) and falls back to a Sonoff dongle (Silicon Labs `10c4:ea60`). It verifies RCP firmware via pyspinel before configuring the snap. The pyspinel venv is shared with other scripts at `artifacts/pyspinel-venv/`.

### Cache layout

```
cache/
  ubuntu/server/    ← Ubuntu Server 26.04 arm64+raspi .img.xz and .img (flash-piotbr.sh)
  snap/             ← openthread-border-router .snap + .assert (all provisioners)
  esp32/rcp/        ← ESP32-C6 RCP firmware binary (user-placed or URL-downloaded)
  ot-rcp-sim/       ← ot-rcp simulation binary (provision_incus.sh)

artifacts/
  rpi/              ← cloud-init payloads from flash-piotbr.sh runs (timestamped)
  x64vm/            ← cloud-init payloads from provision_incus.sh x86_64 runs
  arm64vm/          ← cloud-init payloads from provision_incus.sh arm64 runs
  pyspinel-venv/    ← auto-created Python venv for RCP Spinel probing
```

## Testing (Incus)

`provision_incus.sh` provisions an Incus VM or system container with the same OTBR first-boot sequence, but on native x86_64 — no emulation overhead.

```bash
sudo ./provision_incus.sh                        # VM (default), name=otbrvm64
sudo ./provision_incus.sh --container            # system container, name=otbr-ct
sudo ./provision_incus.sh --vm --name=otbr-test  # custom name
sudo ./provision_incus.sh --reprovision          # delete and reprovision
```

**Container-only constraints:**
- `security.nesting=true` is set automatically (required for snapd)
- `modprobe` in the container is a no-op; host kernel must have `cdc_acm`/`cp210x` loaded
- If the OTBR snap's AppArmor profile blocks `/dev/pts/N` for the sim PTY, reconnect the interface manually: `incus exec <name> -- snap connect openthread-border-router:serial-port`

**Prerequisite:** Run `setup.sh` first to populate `cache/snap/`. The Incus provisioner reuses that cache.

## RCP firmware flashing

When the ESP32-C6 is detected but has no Spinel response, the provisioner prompts to flash firmware.

### ESP32-C6 build configuration (verified)

The `ot_rcp` example in ESP-IDF should be built with these settings (`menuconfig` / `sdkconfig`):
- `CONFIG_OPENTHREAD_RCP_USB_SERIAL_JTAG=y` — use the built-in USB JTAG peripheral (not UART pins). The device appears as `/dev/ttyACM0`.
- `CONFIG_OPENTHREAD_RADIO=y` + `CONFIG_OPENTHREAD_RADIO_NATIVE=y` — RCP mode, native IEEE 802.15.4 radio.
- `CONFIG_ESP_COEX_SW_COEXIST_ENABLE=n` — disable WiFi/BT coexistence (RCP only).

The standard ESP-IDF `idf.py build` produces **three separate binaries** (not a merged image):
- `bootloader/bootloader.bin` → flash at `0x0`
- `partition_table/partition-table.bin` → flash at `0x8000`
- `esp_ot_rcp.bin` (the app) → flash at `0x10000`

For a **fresh device**, use `idf.py flash` directly — it handles all three automatically. For a device that already has the correct bootloader/partition table, copy the app binary:

```bash
cp .../build/esp_ot_rcp.bin cache/esp32/rcp/
# then in .env:
RCP_FIRMWARE_PATH=cache/esp32/rcp/esp_ot_rcp.bin
RCP_FLASH_ADDR=0x10000
```

The baud rate `460800` in the Spinel URL is conventional — USB CDC-ACM (`/dev/ttyACM0`) doesn't use host-side baud rates internally (USB bulk transfers are not baud-rate-limited). The setting is harmless and expected by the OTBR snap.

**Note:** esp-thread-br GitHub releases publish no binary assets — firmware must be built from source. Build instructions: https://github.com/espressif/esp-thread-br/tree/main/examples/ot_rcp

## Key constraints

- cloud-init on Ubuntu Server uses the **NoCloud** datasource, which reads `user-data` and `meta-data` from the **root** of the `system-boot` FAT32 partition (not a subdirectory).
- Ubuntu Core 24 intentionally disables cloud-init at first boot — it is not a viable provisioning target for this approach. Use Ubuntu Server instead.
- Target arch is `arm64` (aarch64). The image is `ubuntu-26.04.4-preinstalled-server-arm64+raspi.img.xz`.
- RCP is an ESP32-C6 connected via USB, communicating over Spinel/HDLC at 460800 baud.

## Code style

- Shell scripts: bash, `set -euo pipefail`, functions for repeated logic
- Avoid hardcoding device paths — always read from env or detect dynamically
- Log progress to stderr; only actionable output goes to stdout
