[English](README.md) | [Русский](README.ru.md)

# OpenWrt Hot-Installer (`openwrt-hot-install.sh`)

A universal POSIX `sh` script that installs **OpenWrt** directly onto a running Linux server or VPS disk from RAM (`tmpfs`) without requiring a rescue/ISO boot.

> [!CAUTION]
> **Destructive operation:** Writing OpenWrt directly to the root disk **erases all existing data** on the target block device. Always back up important data first, and test with `--dry-run` before flashing.

---

## Features

- **Latest Stable, Specific Release, or SNAPSHOT:**
  - Default: resolves `stable_version` automatically from `https://downloads.openwrt.org/.versions.json`.
  - `-s` / `-snapshot`: installs OpenWrt `SNAPSHOT`.
  - `-v <ver>` / `-version <ver>`: installs a specific OpenWrt release (e.g. `25.12.6`).
- **Auto-Detection:**
  - Architecture: `x86_64` (`x86/64`) and `aarch64` / `arm64` (`armsr/armv8`).
  - Boot mode: Legacy BIOS (`ext4-combined.img.gz`) vs UEFI (`ext4-combined-efi.img.gz`).
  - Target disk & root partition (works across `vda`, `sda`, `nvme0n1`, `xvda`).
  - Network settings: preserves MAC address, IPv4 CIDR/netmask, IPv6 address/gateway, and non-loopback DNS servers. Handles `/32` and off-subnet (`onlink`) VPS gateways via explicit `netifd` `route` sections (`scope link` + `onlink '1'`).
- **Pre-Seeded Credentials & Firewall:**
  - Hashes `-p <password>` with SHA-512 (`$6$`) for OpenWrt `musl` compatibility (or reuses compatible existing shadow hashes; avoids incompatible yescrypt `$y$` hashes).
  - Preserves `/root/.ssh/authorized_keys` in `/etc/dropbear/authorized_keys`.
  - Disables DHCP/RA servers (`lan` / `wan`) and opens `22/tcp` (`Allow-SSH`) on `wan` in `firewall4`.
- **Safe RAM Staging & Live Flashing:**
  - Downloads and verifies official `sha256sums` entirely in `tmpfs` (mounts a dedicated 300 MiB `tmpfs` if `/tmp` is disk-backed).
  - Runs `e2fsck -fn` (and repairs benign `make_ext4fs` Pass-5 inode bitmap padding if needed) before touching the disk.
  - Stops noisy disk writers, locks the Python flasher in RAM via `mlockall(MCL_CURRENT | MCL_FUTURE)` (with a `tmpfs` `chroot` fallback if `python3` is absent), remounts `/` read-only via SysRq (`s`, `u`), wipes stale trailing backup GPT when switching GPT → MBR, flashes sequentially, verifies `0x55aa` boot signature, and reboots cleanly via `SysRq-b`.
- **First-Boot Rootfs Expansion Setup:**
  - Stages `/etc/init.d/firstboot-rootfs-pkgs` (`S99firstboot-rootfs-pkgs`) and `/usr/sbin/firstboot-install-rootfs-pkgs.sh` inside the OpenWrt rootfs so on first boot it automatically installs:
    `parted`, `resize2fs`, `losetup`, `e2fsprogs`, `partx-utils` (via `apk` on OpenWrt ≥ 25.12 / snapshots, or `opkg` on ≤ 24.10).
  - Also includes `/usr/sbin/expand-rootfs.sh` for safe offline rootfs expansion to 100% of the disk.

---

## Quick Start (`wget`)

Run as `root` on the target Linux server.

### 1. Install latest stable OpenWrt (recommended)

**Download, inspect/chmod, and run:**
```sh
wget -O openwrt-hot-install.sh https://raw.githubusercontent.com/atrumn/openwrt-hot-install/main/openwrt-hot-install.sh
chmod +x openwrt-hot-install.sh
./openwrt-hot-install.sh -p 'YourStrongRootPassword'
```

**Or download and run in one command:**
```sh
wget -O openwrt-hot-install.sh https://raw.githubusercontent.com/atrumn/openwrt-hot-install/main/openwrt-hot-install.sh && sh openwrt-hot-install.sh -p 'YourStrongRootPassword'
```

### 2. Install OpenWrt SNAPSHOT (`-s` / `-snapshot`)

```sh
wget -O openwrt-hot-install.sh https://raw.githubusercontent.com/atrumn/openwrt-hot-install/main/openwrt-hot-install.sh && sh openwrt-hot-install.sh -snapshot -p 'YourStrongRootPassword'
```

### 3. Install a specific OpenWrt version (`-v` / `-version`)

```sh
wget -O openwrt-hot-install.sh https://raw.githubusercontent.com/atrumn/openwrt-hot-install/main/openwrt-hot-install.sh && sh openwrt-hot-install.sh -version 25.12.6 -p 'YourStrongRootPassword'
```

### 4. Dry-run (test without modifying the disk)

Downloads, verifies SHA-256, mounts, pre-seeds configs, runs `e2fsck`, prints the summary, and exits cleanly without writing to the disk:

```sh
wget -O openwrt-hot-install.sh https://raw.githubusercontent.com/atrumn/openwrt-hot-install/main/openwrt-hot-install.sh && sh openwrt-hot-install.sh --dry-run -p 'YourStrongRootPassword'
```

---

## CLI Options

| Option | Description |
| :--- | :--- |
| *(none)* | Install latest stable OpenWrt from `downloads.openwrt.org/.versions.json` |
| `-s`, `-snapshot`, `--snapshot` | Install OpenWrt `SNAPSHOT` build (cannot be combined with `-v`/`-version`) |
| `-v`, `-version`, `--version <ver>` | Install specific release version, e.g. `25.12.6` |
| `-p`, `--password <pass>` | Set OpenWrt `root` password (hashed as SHA-512 `$6$`) |
| `-d`, `--disk <dev>` | Override auto-detected target whole disk (e.g. `/dev/vda`) |
| `-y`, `--yes` | Skip the 5-second countdown before flashing |
| `--dry-run` | Prepare and verify image in RAM only; do not write to disk or reboot |
| `-h`, `-help`, `--help` | Show help and exit |

---

## Expanding Rootfs After Reboot

1. After OpenWrt boots, wait briefly for `/etc/init.d/firstboot-rootfs-pkgs` to finish installing `parted`, `resize2fs`, `losetup`, `e2fsprogs`, and `partx-utils` in the background. You can check its status via SSH:
   ```sh
   ls -la /etc/firstboot-rootfs-pkgs.done
   cat /var/log/firstboot-rootfs-pkgs.log
   ```
2. Once `/etc/firstboot-rootfs-pkgs.done` exists, run the bundled helper to expand the root partition and `ext4` filesystem safely to 100% of your disk (reboots automatically via SysRq):
   ```sh
   /usr/sbin/expand-rootfs.sh
   ```
3. After reboot, verify with `df -h`.

---

## Requirements

- Linux server running as `root` with at least **320 MiB** of free RAM.
- Tools on host: `wget` or `curl`, `gunzip`, `sha256sum`, `losetup`, `mount`, `umount`, `e2fsck`, `dd`, `awk`, `sed`, `grep`, `ip`, and (`python3` or `openssl`/`mkpasswd` for `-p`).
- SysRq supported by kernel (`/proc/sys/kernel/sysrq`).

---

## License

[MIT](LICENSE)
