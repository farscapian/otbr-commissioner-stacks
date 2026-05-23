# raspi-otbr

Flash a Raspberry Pi 4B with Ubuntu Server 26.04 LTS pre-configured as an OpenThread Border Router (OTBR), using an ESP32-C6 as the Radio Co-Processor (RCP). Combined with a UPS Hat, batteries, and a small USB keypad, this makes a purpose-built Thread OTBR with Bluetooth+Thread commissioning capability via the chiptool snap.

## Key commands

```bash
# Full flash (or cloud-init-only if Ubuntu Server already present)
otbrstack flash /dev/sdX

# Force full reflash
otbrstack flash -f /dev/sdX

# Skip confirmation prompt
otbrstack flash -y /dev/sdX

# Use a specific env file
otbrstack flash --env-file=pangolin.env /dev/sdX

# Incus VM test (native x86_64, faster)
otbrstack vm x64

# Incus system container test
otbrstack vm x64 --container

# Tear down Incus instance
incus delete otbrvm64 --force   # or otbr-ct

# Docker on bare metal (Ubuntu Server/Desktop; installs Docker CE + nginx)
otbrstack docker

# Snap on bare metal (Ubuntu Server/Desktop; installs/configures openthread-border-router snap)
otbrstack snap
```

## Environment setup

Copy and edit an env file before running:

```bash
cp pangolin.env .env   # or tvpc.env — pick the closest example
# Edit .env: set THREAD_DATASET_TLV, WIFI_SSID, WIFI_PASSWORD, etc.
```

The env file is sourced automatically — no `export` or `sudo -E` needed.

### Relevant .env variables

| Variable | Scripts | Purpose |
|----------|---------|---------|
| `THREAD_DATASET_TLV` | all | Thread Active Operational Dataset (hex). Required. |
| `SSH_PUBKEY` | flash, incus | SSH public key to inject into VM/image |
| `SSH_MGMT_CIDRS` | flash | Space-separated IPs/CIDRs allowed SSH inbound via UFW (empty = allow all) |
| `IDF_PATH` | snap, incus | Path to existing ESP-IDF install (optional); if unset and `idf.py` not in PATH, ESP-IDF is auto-cloned to `cache/esp-idf` |
| `DONGLE_VENDOR` | docker | USB vendor ID for Thread dongle (from `udevadm info`) |
| `DONGLE_PRODUCT` | docker | USB product ID for Thread dongle |
| `DONGLE_SERIAL` | docker | USB serial string for Thread dongle (unique; creates stable symlink) |
| `DONGLE_SYMLINK` | docker | Symlink name under `/dev/` (default: `ttyTHREAD`) |
| `BAUD_RATE` | docker | Serial baud rate (default: `460800`) |
| `INFRA_IF` | snap | Backbone/infrastructure network interface (default: auto-detected) |
| `THREAD_IF` | snap | Thread virtual interface (default: `wpan0`) |
| `OT_REPO_PATH` | — | **Removed.** |
| `SIM_RCP_BIN` | — | **Removed.** Sim binary is built automatically from `cache/openthread/` by `otbrstack vm`. |
| `SIM_RCP_URL` | — | **Removed.** |
| `SIM_CLI_BIN` | — | **Removed.** `ot-cli` is built alongside `ot-rcp` and cached at `cache/ot-rcp-sim/ot-cli`. |
| `SIM_CLI_URL` | — | **Removed.** |

## Architecture

Four deployment paths share the same `.env` file and `THREAD_DATASET_TLV` variable:

| Command | Target OS | Runtime | RCP detection |
|---------|-----------|---------|---------------|
| `otbrstack flash` | Ubuntu Server 26.04 (Raspberry Pi) | snap (cloud-init) | ESP32-C6 via USB |
| `otbrstack snap` | Ubuntu Server/Desktop (bare metal) | snap (live) | ESP32-C6 or Sonoff |
| `otbrstack docker` | Ubuntu Server/Desktop (bare metal) | Docker CE + nginx | any USB dongle via udev symlink |
| `otbrstack vm x64` / `otbrstack vm arm64` | Incus VM or container (test) | snap | simulated or USB passthrough |

- `otbrstack flash` — downloads Ubuntu Server 26.04 arm64+raspi image, verifies SHA-256, flashes to SD, injects cloud-init NoCloud payload into the `system-boot` partition
- `otbrstack snap` — detects USB RCP, verifies Spinel firmware, installs and configures the OTBR snap; runs as normal user (`sudo` invoked internally)
- `otbrstack docker` — installs Docker CE, pulls `openthread/otbr`, writes udev rule for stable dongle symlink, sets up nginx reverse proxy, joins Thread network; requires root
- `otbrstack vm x64` / `otbrstack vm arm64` — Incus VM or system container test; native x86_64 or arm64
- `incus/` — cloud-init template for Incus VM and container
- `cache/` — all third-party downloaded content (see layout below)
- `artifacts/` — generated shared artifacts (cloud-init output, pyspinel venv)

### Docker architecture notes

`otbrstack docker` is designed for **any USB Thread dongle** (Sonoff, ESP32-C6, Silicon Labs, etc.). The dongle is identified by USB vendor/product/serial via udev, which creates a stable `/dev/ttyTHREAD` symlink. nginx exposes the OTBR REST API on `:8080` and the web UI on `:8088`, both proxied from the container's `127.0.0.1` ports.

### Snap architecture notes

`otbrstack snap` prefers an **ESP32-C6** (Espressif vendor ID `303a`) and falls back to a Sonoff dongle (Silicon Labs `10c4:ea60`). It verifies RCP firmware via pyspinel before configuring the snap. The pyspinel venv is shared with other scripts at `artifacts/pyspinel-venv/`.

### Cache layout

```
cache/
  ubuntu/server/    ← Ubuntu Server 26.04 arm64+raspi .img.xz and .img (otbrstack flash)
  snap/             ← openthread-border-router .snap + .assert (all provisioners)
  esp32/rcp/        ← ESP32-C6 RCP app binary (built from esp-thread-br source)
  esp-idf/          ← shallow clone of espressif/esp-idf (auto-cloned if IDF_PATH unset); ot_rcp example lives at examples/openthread/ot_rcp inside this clone
  openthread/       ← shallow clone of openthread/openthread; cmake simulation build produces ot-rcp + ot-cli
  ot-rcp-sim/       ← ot-rcp and ot-cli sim binaries (built from cache/openthread/ by otbrstack vm)

artifacts/
  rpi/<hostname>/   ← cloud-init payloads from otbrstack flash (latest run, overwritten each time)
  x64vm/            ← cloud-init payloads from otbrstack vm x64 runs
  arm64vm/          ← cloud-init payloads from otbrstack vm arm64 runs
  pyspinel-venv/    ← auto-created Python venv for RCP Spinel probing
```

## Testing (Incus)

`otbrstack vm x64` provisions an Incus VM or system container with the same OTBR first-boot sequence, but on native x86_64 — no emulation overhead.

```bash
otbrstack vm x64                          # VM (default), name=otbrvm64
otbrstack vm x64 --container             # system container, name=otbr-ct
otbrstack vm x64 --vm --name=otbr-test   # custom name
otbrstack vm x64 --reprovision           # delete and reprovision
```

**Container-only constraints:**
- `security.nesting=true` is set automatically (required for snapd)
- `modprobe` in the container is a no-op; host kernel must have `cdc_acm`/`cp210x` loaded
- If the OTBR snap's AppArmor profile blocks `/dev/pts/N` for the sim PTY, reconnect the interface manually: `incus exec <name> -- snap connect openthread-border-router:serial-port`

**Prerequisite:** Run `setup.sh` first to populate `cache/snap/`. The Incus provisioner reuses that cache.

## RCP firmware flashing

When an ESP32-C6 is detected, the provisioner always builds from source using the `ot_rcp` example in [esp-thread-br](https://github.com/espressif/esp-thread-br). All three binaries (bootloader + partition table + app) are flashed via `idf.py flash` — no pre-built binaries required.

### How it works

On every run the provisioner:

1. **Updates ESP-IDF** — clones to `cache/esp-idf/` on first run, then `git fetch --depth 1` + `install.sh esp32c6` on subsequent runs. Skipped if `idf.py` is already in PATH or `IDF_PATH` points to an existing install.
2. **Updates esp-thread-br** — clones `cache/esp-thread-br/` on first run, then pulls latest (`git fetch --depth 1` + `reset --hard origin/HEAD` + submodule update). Tracks the HEAD hash before and after.
3. **Rebuilds** only if the esp-thread-br HEAD changed or no prior build artifact exists. Uses `sdkconfig.defaults.otbrstack` with:
   - `CONFIG_OPENTHREAD_RCP_USB_SERIAL_JTAG=y` — USB JTAG peripheral (`/dev/ttyACM0`)
   - `CONFIG_OPENTHREAD_RADIO=y` + `CONFIG_OPENTHREAD_RADIO_NATIVE=y` — RCP mode
   - `CONFIG_ESP_COEX_SW_COEXIST_ENABLE=n` — disable WiFi/BT coexistence
4. **Flashes** only if the freshly built binary differs (sha256) from `cache/esp32/rcp/esp_ot_rcp.bin` (the last-flashed copy). If identical, the connected device is already up to date and flash is skipped.
5. On flash, updates `cache/esp32/rcp/esp_ot_rcp.bin` to reflect what is now on the device.

The baud rate `460800` in the Spinel URL is conventional — USB CDC-ACM doesn't use host-side baud rates internally. The setting is harmless and expected by the OTBR snap.

## Key constraints

- cloud-init on Ubuntu Server uses the **NoCloud** datasource, which reads `user-data` and `meta-data` from the **root** of the `system-boot` FAT32 partition (not a subdirectory).
- Ubuntu Core 24 intentionally disables cloud-init at first boot — it is not a viable provisioning target for this approach. Use Ubuntu Server instead.
- Target arch is `arm64` (aarch64). The image is `ubuntu-26.04.4-preinstalled-server-arm64+raspi.img.xz`.
- RCP is an ESP32-C6 connected via USB, communicating over Spinel/HDLC at 460800 baud.

## Code style

- Shell scripts: bash, `set -euo pipefail`, functions for repeated logic
- Avoid hardcoding device paths — always read from env or detect dynamically
- Log progress to stderr; only actionable output goes to stdout
