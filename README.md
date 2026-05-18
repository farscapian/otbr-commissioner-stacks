# otbr-commissioner-stacks

Provision an [OpenThread Border Router](https://openthread.io/guides/border-router) (OTBR)
across four deployment targets — all driven by the same `.env` file:

| Command | Target | Runtime |
|---------|--------|---------|
| `otbrstack flash` | Raspberry Pi 4B (Ubuntu Server 26.04) | snap via cloud-init |
| `otbrstack snap` | Any Ubuntu bare-metal host | snap (live install) |
| `otbrstack docker` | Any Ubuntu bare-metal host | Docker CE + nginx |
| `otbrstack vm x64` / `otbrstack vm arm64` | Incus VM or container | snap (for testing) |

Source `otbrstack.sh` to get the `otbrstack` command (add to `~/.bashrc` for persistence):

```bash
source ./otbrstack.sh
```

## Hardware

| Component | Notes |
|-----------|-------|
| Raspberry Pi 4B | Primary target. Pi 3B also works. |
| ESP32-C6 (RCP firmware) | Connected via USB; communicates over Spinel/HDLC at 460800 baud. |
| microSD card | 8 GB minimum. |
| Network | eth0 (preferred) and/or wlan0 (optional fallback). |

## Host requirements

x86-64 Linux with the following available on `PATH`:

```
curl  sha256sum  xzcat  dd  mount  umount  partprobe  lsblk  python3  snap
```

`pyserial` is optional but enables a more reliable RCP probe:

```
pip3 install pyserial
# or: sudo apt install python3-serial
```

## Quick start

**1. Flash RCP firmware onto the ESP32-C6** and connect it via USB before running
`otbrstack`. It will detect the serial device and probe it for a valid Spinel response.

**2. Generate or export your Thread Active Operational Dataset TLV:**

```bash
# On an existing OpenThread device:
ot-ctl dataset active -x

# Or generate a fresh one:
ot-ctl dataset init new
ot-ctl dataset active -x
```

**3. Create a `.env` file** with your configuration:

```bash
cp .env.example .env
# edit .env with your values
```

The env file is sourced automatically, so no `export` or `sudo -E` is needed.

**4. Identify your SD card device** (`lsblk`, `dmesg | tail`), then run:

```bash
# uses .env in the script directory by default
otbrstack flash /dev/sdX

# or point to any env file explicitly
otbrstack flash --env-file=/path/to/production.env /dev/sdX
```

If no `.env` is found and `--env-file` is not given, the command errors out.

`otbrstack flash` will ask for confirmation before writing. All data on the
target device will be destroyed.

## What the script does

1. **Probes the RCP** — sends a Spinel `PROP_VALUE_GET(PROP_NCP_VERSION)` frame
   over the USB serial port and verifies a valid response. Falls back to a raw
   HDLC probe if `pyserial` is absent. Records the device path (or schedules
   auto-detection at boot if no RCP is plugged in yet).

2. **Downloads Ubuntu Server 26.04** (`ubuntu-26.04-preinstalled-server-arm64+raspi.img.xz`) from
   Canonical, verifies its SHA-256, and extracts it. Both the compressed and
   extracted images are cached next to the script.

4. **Flashes the image** to the SD card with `dd`.

5. **Injects a cloud-init payload** onto the `system-boot` FAT partition:
   - **Netplan** — DHCP on eth0 (route metric 100) and, if WiFi credentials are
     set, wlan0 (metric 200). Linux routing always prefers the lower metric, so
     eth0 wins when both links are up.
   - **Wireless regulatory domain** — sets `REGDOMAIN=US` via CRDA and
     `cfg80211`.
   - **OTBR interface watcher** — a Python daemon
     (`/usr/local/sbin/otbr-ifwatcher.py`) that listens for
     `systemd-networkd` D-Bus events and reconfigures the OTBR snap's backbone
     interface in real time, always preferring eth0. Falls back to polling every
     10 s if `python3-dbus`/`python3-gi` are unavailable.
   - **First-boot script** (`/usr/local/sbin/otbr-firstboot.sh`) — installs the
     OTBR snap offline, connects snap interfaces, configures the RCP URL and
     backbone interface, starts the service, and seeds the Thread dataset TLV.
   - The **OTBR snap** is installed from the snap store on first boot (`snap install openthread-border-router`).

## First boot

### OTBR first-boot

First boot takes a few minutes. Progress is logged on the device at:

```
/var/log/otbr-firstboot.log
```

The sequence on the device is:

1. cloud-init applies netplan and regulatory settings.
2. `otbr-firstboot.sh` runs in the background:
   - Waits for `snapd` to finish seeding.
   - Installs the OTBR snap from the embedded copy.
   - Connects snap interfaces (serial-port, network-control, firewall-control,
     network-observe, raw-usb).
   - Configures the snap with the RCP URL and backbone interface.
   - Starts the snap service.
   - Commits the Thread Active Operational Dataset.
   - Brings up the Thread interface.
3. `otbr-ifwatcher.service` starts and monitors interface state changes for the
   lifetime of the device.

## Smart flash detection

By default, `flash-piotbr.sh` checks whether Ubuntu Server is already on the target device (by looking for the `system-boot` partition label). If found, it skips the image download and `dd` flash entirely and only updates the cloud-init files — much faster when you only changed a config value.

| Flag | Effect |
|------|--------|
| _(none)_ | Auto-detect: cloud-init-only if system-boot present, full flash otherwise |
| `-f` | Force full reflash even if Ubuntu Server is already on the device |
| `-y` | Skip the `YES` confirmation prompt (full-flash mode only) |

## Testing with Incus (`provision_incus.sh`)

`provision_incus.sh` runs an end-to-end test of the OTBR first-boot sequence inside an Incus VM or system container — no physical hardware required.

**Host requirements:** Incus installed and current user in the `incus` group.

**What it does:**

1. Renders the cloud-init user-data template with env vars.
2. Creates and starts the Incus instance (VM or container).
3. Pushes snap cache and sim binary via `incus file push`.
4. Waits for `ot-ctl state` to confirm the Thread node is active.

**Usage:**

```bash
sudo ./provision_incus.sh                       # x86_64 VM, name=otbrvm64
sudo ./provision_incus.sh --container           # system container, name=otbr-ct
sudo ./provision_incus.sh --arch=arm64          # arm64 VM (QEMU-emulated), name=otbrarm64
sudo ./provision_incus.sh --reprovision         # delete and reprovision
```

## Bare-metal snap (`otbr-snap-setup.sh`)

Installs and configures the `openthread-border-router` snap on any Ubuntu
Server or Desktop host (x86_64 or arm64) with a USB Thread radio attached.

**Host requirements:** `snap`, `python3` (for pyspinel RCP verification)

**Supported radios (auto-detected in priority order):**
1. ESP32-C6 (Espressif USB vendor `303a`) → `/dev/ttyACM0`
2. Sonoff Dongle-E / CP210x (Silicon Labs `10c4:ea60`) → `/dev/ttyUSB0`

**What it does:**

1. Loads `.env` and validates `THREAD_DATASET_TLV`.
2. Adds the current user to the `dialout` group if needed (then exits — re-run after login).
3. Loads and persists required kernel modules (`ip_set*`).
4. Detects the USB Thread radio device.
5. Verifies ESP32-C6 RCP firmware via pyspinel (skipped for Sonoff).
6. Installs the snap from the store (if absent), sets `radio-url`, `infra-if`, `thread-if`, enables autostart, restarts the snap.
7. Ensures all required snap interfaces are connected.
8. Configures UFW rules for Thread/mDNS forwarding if UFW is active.
9. Commits the Thread dataset and brings up the Thread interface.

**Usage:**

```bash
./otbr-snap-setup.sh
```

Run as your normal user — `sudo` is invoked internally only where needed.

Optional `.env` variables:

| Variable | Default | Purpose |
|----------|---------|---------|
| `INFRA_IF` | auto (default route interface) | Backbone network interface |
| `THREAD_IF` | `wpan0` | Thread virtual interface name |

## Bare-metal Docker (`otbr-docker-setup.sh`)

Installs Docker CE, pulls `openthread/otbr:latest`, writes a stable udev
symlink for the USB dongle, and sets up nginx as a reverse proxy — all on a
plain Ubuntu Server or Desktop host.

**Host requirements:** Ubuntu (Debian-based); run as root (`sudo`)

**Supported radios:** Any USB serial Thread dongle identified by vendor/product/serial.

**What it does:**

1. Loads `.env` and validates dongle identification variables.
2. Disables system sleep/suspend.
3. Detects the backbone Ethernet interface on `192.168.4.x` (configurable via `TARGET_SUBNET` in the script).
4. Loads and persists IPv6 kernel modules (`ip6table_filter`, `ip6_tables`).
5. Writes `/etc/udev/rules.d/99-thread-dongle.rules` to create `/dev/ttyTHREAD`.
6. Installs Docker CE from the official apt repository.
7. Pulls the OTBR image and writes `/opt/otbr/otbr-agent` config.
8. Launches the `otbr` container with `--privileged --network host`.
9. Installs nginx and configures reverse proxies: REST API on `:8080`, web UI on `:8088`.
10. Prompts for a Home Assistant IP and sets UFW rules.
11. Commits the Thread dataset via `docker exec otbr ot-ctl`.

**Usage:**

```bash
sudo ./otbr-docker-setup.sh
```

Required `.env` variables (in addition to `THREAD_DATASET_TLV`):

| Variable | Purpose | How to find |
|----------|---------|-------------|
| `DONGLE_VENDOR` | USB vendor ID | `udevadm info /dev/ttyACM0 \| grep ID_VENDOR_ID` |
| `DONGLE_PRODUCT` | USB product ID | `udevadm info /dev/ttyACM0 \| grep ID_MODEL_ID` |
| `DONGLE_SERIAL` | USB serial string (unique) | `udevadm info /dev/ttyACM0 \| grep ID_SERIAL_SHORT` |

Optional:

| Variable | Default | Purpose |
|----------|---------|---------|
| `DONGLE_SYMLINK` | `ttyTHREAD` | Symlink name created under `/dev/` |
| `BAUD_RATE` | `460800` | Serial baud rate passed to the OTBR agent |

## Partition layout (Ubuntu Server 26.04 arm64+raspi)

| Partition | Filesystem | Label | Purpose |
|-----------|-----------|-------|---------|
| p1 | vfat | system-boot | Bootloader, kernel, cloud-init |
| p2 | ext4 | ubuntu-seed | Snap seed |
| p3 | ext4 | ubuntu-save | Encrypted save partition |
| p4 | ext4 | ubuntu-data | Writable data |

## Files

| File | Purpose |
|------|---------|
| `flash-piotbr.sh` | Flash Ubuntu Server 26.04 to SD card (Raspberry Pi) |
| `otbr-snap-setup.sh` | Bare-metal snap provisioner (Ubuntu Server/Desktop) |
| `otbr-docker-setup.sh` | Bare-metal Docker provisioner (Ubuntu Server/Desktop) |
| `provision_incus.sh` | Incus VM/container test (x86_64 or arm64) |
| `pangolin.env` / `tvpc.env` | Example env files — copy to `.env` and edit |
| `cache/` | Downloaded images, snaps, and firmware |
| `artifacts/` | Generated cloud-init payloads and pyspinel venv |
