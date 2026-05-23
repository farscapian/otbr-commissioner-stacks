# otbr-commissioner-stacks

Flash a Raspberry Pi 4B with Ubuntu Server 26.04 LTS, pre-configured as an
[OpenThread Border Router](https://openthread.io/guides/border-router) (OTBR).
An ESP32-C6 acts as the Thread Radio Co-Processor (RCP), connected via USB.

The same `.env` file drives four deployment paths:

| Command | Where it runs | How |
|---------|---------------|-----|
| `otbrstack flash` | Raspberry Pi 4B (SD card) | Ubuntu Server + cloud-init + snap |
| `otbrstack snap` | Any Ubuntu host (bare metal) | snap (live install) |
| `otbrstack docker` | Any Ubuntu host (bare metal) | Docker CE + nginx |
| `otbrstack vm x64` | Incus VM or container (testing) | snap (no hardware needed) |

---

## What you'll need

### Hardware (for the Pi path)

| Item | Notes |
|------|-------|
| Raspberry Pi 4B | Pi 3B also works |
| ESP32-C6 development board | The Thread radio. Connected to the Pi via USB at first boot |
| microSD card | 8 GB minimum, 16 GB+ recommended |
| Ethernet cable | Recommended for first boot. Wi-Fi is supported as a fallback |

### Software on your Linux host (x86-64)

- Standard tools: `curl`, `xzcat`, `dd`, `lsblk`, `python3`, `snap`, `rsync`
- QEMU user-mode emulation (for the arm64 chroot step): `qemu-user-binfmt`

Install any missing packages with:

```bash
sudo apt-get install qemu-user-binfmt rsync
```

---

## Getting started

### 1. Clone the repo and activate the command

```bash
git clone https://github.com/farscapian/otbr-commissioner-stacks.git
cd otbr-commissioner-stacks
source ./otbrstack.sh
```

The `source` command loads the `otbrstack` shell function into your current
terminal. To make it permanent, add this line to your `~/.bashrc`:

```bash
source /path/to/otbr-commissioner-stacks/otbrstack.sh
```

### 2. Create your `.env` file

Copy the example and fill in your values:

```bash
cp .env.example .env
nano .env   # or your preferred editor
```

The two required values are:

- **`THREAD_DATASET_TLV`** — your Thread network's Active Operational Dataset (a hex string).
  If you don't have one yet, generate a new one:

  ```bash
  # On any machine with the OTBR snap or ot-ctl installed:
  snap run openthread-border-router.ot-ctl dataset init new
  snap run openthread-border-router.ot-ctl dataset commit active
  snap run openthread-border-router.ot-ctl dataset active -x
  # Copy the hex output into THREAD_DATASET_TLV in your .env
  ```

  Or if you already have an existing Thread commissioner, export it:

  ```bash
  ot-ctl dataset active -x
  ```

- **`SSH_PUBKEY`** — your SSH public key (the contents of `~/.ssh/id_ed25519.pub` or
  similar). This is injected into the Pi image so you can SSH in without a password.

Everything else in `.env` has sensible defaults. Wi-Fi credentials are optional —
if you're using Ethernet, leave `WIFI_SSID` and `WIFI_PASSWORD` blank.

### 3. Add an SSH config entry for your Pi

The flash script checks that your `~/.ssh/config` has an entry for the Pi's
hostname (default: `otbr-raspi4`) so you can reach it by name after boot.
If one doesn't exist, the script will offer to create it. You can also add
it manually:

```
# ~/.ssh/config
Host otbr-raspi4
    User ubuntu
    # HostName 192.168.x.y   # optional if you use mDNS / .local hostname
```

---

## Flashing the Raspberry Pi

Insert the microSD card into your Linux host and identify its device path
(`lsblk` or `dmesg | tail` after inserting). It will look like `/dev/sdb`
or `/dev/mmcblk0` — **never** `/dev/sda` (that's usually your main drive).

```bash
# Standard flash — asks for confirmation before writing
otbrstack flash /dev/sdX

# Force a full reflash even if Ubuntu is already on the card
otbrstack flash -f /dev/sdX

# Skip the confirmation prompt (useful for scripting)
otbrstack flash -y /dev/sdX

# Use a different env file
otbrstack flash --env-file=pangolin.env /dev/sdX

# Set a custom hostname for this device
otbrstack flash --hostname=otbr-kitchen /dev/sdX
```

> **Smart re-flash:** If Ubuntu Server is already on the card (detected by the
> `system-boot` partition label), `otbrstack flash` skips the image download and
> `dd` step entirely and only rewrites the cloud-init config. This is much faster
> when you just changed a config value.

### What happens during the flash

1. Downloads `ubuntu-26.04-preinstalled-server-arm64+raspi.img.xz` from
   Canonical (cached in `cache/ubuntu/server/` — only downloaded once).
2. Verifies the SHA-256 of the downloaded image.
3. Expands the root partition to fill the SD card.
4. Runs an arm64 chroot to pre-install packages (`git`, `cmake`, `python3`, etc.)
   and pre-load the ESP-IDF toolchain so the Pi doesn't have to download them at boot.
5. Caches arm64 snaps (`openthread-border-router`, `chip-tool`) and copies them
   to the SD card so first boot can install offline.
6. Writes a cloud-init config into the `system-boot` partition that sets up
   networking, installs and configures the OTBR snap, and seeds the Thread dataset.

---

## First boot

Insert the SD card into the Pi, connect the ESP32-C6 via USB, and power on.

First boot takes **5–15 minutes** depending on internet speed (the Pi may still
need to pull some packages). You can watch progress over SSH:

```bash
# Tail all logs in real time (journald + firstboot log)
otbrstack logs -f otbr-raspi4

# Or SSH in and check the firstboot log directly
ssh otbr-raspi4
sudo tail -f /var/log/otbr-firstboot.log
```

### What happens on first boot

1. **Networking** — eth0 comes up via DHCP (preferred). If Wi-Fi credentials
   were set, wlan0 is configured as a fallback.
2. **RCP firmware** — `otbr-rcp-update.sh` waits for the ESP32-C6 to enumerate,
   then fetches the latest ESP-IDF release, builds the `ot_rcp` firmware, and
   flashes it to the ESP32-C6 if the firmware has changed. Identical firmware
   is detected by SHA-256 and skipped.
3. **Snap install** — `openthread-border-router` is installed from the pre-loaded
   copy on the SD card (no store download needed). `chip-tool` is also installed
   for Matter commissioning.
4. **OTBR configuration** — snap interfaces are connected, the radio URL is set,
   the backbone interface is configured, and the service is started.
5. **Thread dataset** — the TLV from your `.env` is committed and the Thread
   interface is brought up.
6. **Firewall** — UFW is enabled. SSH is allowed from the CIDRs in
   `SSH_MGMT_CIDRS` (or from anywhere if that's empty).

After first boot, `otbr-rcp-update.service` runs on every subsequent boot to
keep the RCP firmware up to date. A weekly timer triggers a reboot to check for
new firmware.

### Checking OTBR status

```bash
ssh otbr-raspi4

# Check Thread state (should be leader, router, or child)
snap run openthread-border-router.ot-ctl state

# Check active dataset
snap run openthread-border-router.ot-ctl dataset active -x

# Check snap service status
snap services openthread-border-router
```

---

## Remote management

```bash
# Tail logs from any otbrstack-managed device
otbrstack logs -f otbr-raspi4

# View last-boot logs (static)
otbrstack logs otbr-raspi4

# Reboot the device
otbrstack restart otbr-raspi4

# Graceful shutdown
otbrstack shutdown otbr-raspi4
```

---

## Testing without hardware (Incus VM)

`otbrstack vm x64` provisions an Incus VM with the same OTBR first-boot
sequence — no Raspberry Pi or ESP32-C6 needed. A simulated RCP (`ot-rcp`) is
built from OpenThread source and used instead of the physical ESP32-C6.

**Prerequisites:** Incus installed, current user in the `incus` group.

```bash
otbrstack vm x64             # VM (default), instance name: otbr-test-x64
otbrstack vm x64 --container # system container (faster), name: otbr-test-ct
otbrstack vm arm64           # arm64 VM (QEMU-emulated, slower)
```

The first run clones and builds the OpenThread simulator (~5 min). Subsequent
runs reuse the cached binary at `cache/ot-rcp-sim/ot-rcp`.

To tear down an instance:

```bash
incus delete otbr-test-x64 --force
```

### Running the test suite

```bash
sudo ./tests/test_otbr_vm.sh             # full test, x64 VM
sudo ./tests/test_otbr_vm.sh --no-peer-test  # skip neighbor exchange (T6)
```

Six tests verify: Ubuntu 26.04 running, OTBR snap installed, all services
active, Thread state is leader/router/child, dataset TLV committed, and
neighbor table has ≥1 entry (T6, requires `ot-cli` binary).

---

## Bare-metal snap (`otbrstack snap`)

Installs and configures the `openthread-border-router` snap on any Ubuntu host
with a USB Thread radio attached. Runs as your normal user — `sudo` is invoked
internally only where needed.

**Supported radios (auto-detected):**
1. ESP32-C6 (USB vendor `303a`) on `/dev/ttyACM0`
2. Sonoff Dongle-E / CP210x (Silicon Labs `10c4:ea60`) on `/dev/ttyUSB0`

```bash
otbrstack snap
```

The script detects the radio, verifies its Spinel firmware (flashing the
ESP32-C6 if needed), installs and configures the snap, and commits the Thread
dataset. Optional `.env` variables:

| Variable | Default | Purpose |
|----------|---------|---------|
| `INFRA_IF` | auto (default route) | Backbone network interface |
| `THREAD_IF` | `wpan0` | Thread virtual interface name |

---

## Bare-metal Docker (`otbrstack docker`)

Installs Docker CE, pulls `openthread/otbr`, writes a stable udev symlink for
the USB dongle, and sets up nginx as a reverse proxy. Run as root.

```bash
otbrstack docker
```

Exposes: REST API on `:8080`, web UI on `:8088`.

Required `.env` variables (find values with `udevadm info /dev/ttyACM0`):

| Variable | Purpose |
|----------|---------|
| `DONGLE_VENDOR` | USB vendor ID |
| `DONGLE_PRODUCT` | USB product ID |
| `DONGLE_SERIAL` | USB serial string (unique per device) |

Optional:

| Variable | Default | Purpose |
|----------|---------|---------|
| `DONGLE_SYMLINK` | `ttyTHREAD` | Symlink name under `/dev/` |
| `BAUD_RATE` | `460800` | Serial baud rate |

---

## Environment variable reference

All variables are read from your `.env` file. See `.env.example` for the full
annotated list. Key variables:

| Variable | Used by | Purpose |
|----------|---------|---------|
| `THREAD_DATASET_TLV` | all | Thread Active Operational Dataset (hex). Required. |
| `SSH_PUBKEY` | flash, vm | SSH public key injected into the image |
| `OTBR_SNAP_CHANNEL` | flash, snap, vm | Snap channel (default: `latest/edge`) |
| `CHIP_TOOL_SNAP_CHANNEL` | flash | chip-tool snap channel (default: `latest/stable`) |
| `WIFI_SSID` / `WIFI_PASSWORD` | flash | Wi-Fi credentials (optional; eth0 is preferred) |
| `OTBR_HOSTNAME` | flash | Device hostname (default: `otbr-raspi4`) |
| `SSH_MGMT_CIDRS` | flash | Space-separated CIDRs for SSH access via UFW |
| `HTTP_PROXY` | all | Optional HTTP proxy (e.g. `http://squid.local:3128`) |
| `INFRA_IF` | snap | Backbone interface (default: auto-detected) |
| `DONGLE_VENDOR/PRODUCT/SERIAL` | docker | USB dongle identification |

---

## Repository layout

```
otbrstack.sh          # Shell function — source this to get the otbrstack command
flash-piotbr.sh       # Raspberry Pi SD card flasher (called by otbrstack flash)
provision_incus.sh    # Incus VM/container provisioner (called by otbrstack vm)
otbr-snap-setup.sh    # Bare-metal snap provisioner (called by otbrstack snap)
otbr-docker-setup.sh  # Bare-metal Docker provisioner (called by otbrstack docker)
scripts/
  flash_rcp.sh        # ESP32-C6 RCP firmware builder and flasher
  verify_rcp.py       # Spinel probe (checks if RCP firmware responds correctly)
tests/
  test_otbr_vm.sh     # Integration test suite for Incus provisioning
.env.example          # Annotated template — copy to .env and edit
pangolin.env          # Example env for a specific host (copy and adapt)
cache/                # Downloaded images, snaps, firmware (gitignored)
artifacts/            # Generated cloud-init payloads (gitignored)
```
