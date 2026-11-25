#!/bin/sh
#
# Universal OpenWrt Hot-Installer for running Linux servers/VPSs.
# Downloads an official OpenWrt ext4-combined image into RAM (tmpfs),
# pre-seeds network/SSH/firewall + first-boot rootfs-expansion package installer,
# remounts the live root filesystem read-only via SysRq, writes directly to disk,
# and triggers an immediate clean SysRq reboot.
#
# Usage:
#   openwrt-hot-install.sh                         # latest stable
#   openwrt-hot-install.sh -s | -snapshot          # snapshot build
#   openwrt-hot-install.sh -v <ver> | -version <ver>
#   openwrt-hot-install.sh -p <root_password> [-d /dev/vda] [-y] [--dry-run]

set -eu

# ---------------------------------------------------------------------------
# Globals & Defaults
# ---------------------------------------------------------------------------
MODE=""                 # stable | snapshot | version
TARGET_VERSION=""
ROOT_PASSWORD=""
OVERRIDE_DISK=""
ASSUME_YES=0
DRY_RUN=0
PASS_HASH=""

VERSIONS_URL="https://downloads.openwrt.org/.versions.json"
RELEASES_BASE="https://downloads.openwrt.org/releases"
SNAPSHOT_BASE="https://downloads.openwrt.org/snapshots"

WORK_DIR=""
MOUNTED_TMPFS=0
LOOP_DEV=""
BOOT_MNT=""
ROOT_MNT=""

# ---------------------------------------------------------------------------
# Logging & Cleanup
# ---------------------------------------------------------------------------
log() {
    printf '[owrt-hot-install] %s\n' "$*"
}

warn() {
    printf '[owrt-hot-install] WARNING: %s\n' "$*" >&2
}

die() {
    printf '[owrt-hot-install] ERROR: %s\n' "$*" >&2
    exit 1
}

cleanup() {
    set +e
    if [ -n "$BOOT_MNT" ] && grep -q " $BOOT_MNT " /proc/mounts 2>/dev/null; then
        umount "$BOOT_MNT" 2>/dev/null || true
    fi
    if [ -n "$ROOT_MNT" ] && grep -q " $ROOT_MNT " /proc/mounts 2>/dev/null; then
        umount "$ROOT_MNT" 2>/dev/null || true
    fi
    if [ -n "$WORK_DIR" ]; then
        if grep -q " $WORK_DIR/ramroot/dev " /proc/mounts 2>/dev/null; then
            umount "$WORK_DIR/ramroot/dev" 2>/dev/null || true
        fi
        if grep -q " $WORK_DIR/ramroot/proc " /proc/mounts 2>/dev/null; then
            umount "$WORK_DIR/ramroot/proc" 2>/dev/null || true
        fi
    fi
    if [ -n "$LOOP_DEV" ]; then
        losetup -d "$LOOP_DEV" 2>/dev/null || true
    fi
    if [ -n "$WORK_DIR" ] && [ -d "$WORK_DIR" ]; then
        if [ "$MOUNTED_TMPFS" -eq 1 ]; then
            umount "$WORK_DIR" 2>/dev/null || true
            rmdir "$WORK_DIR" 2>/dev/null || true
        else
            rm -rf "$WORK_DIR" 2>/dev/null || true
        fi
    fi
}
trap cleanup EXIT HUP INT TERM

usage() {
    cat <<'EOF'
Usage: openwrt-hot-install.sh [OPTIONS]

Hot-installs OpenWrt onto the running Linux server's root disk from RAM (tmpfs).
By default (with no version flags), installs the latest stable OpenWrt release.

Version selection (mutually exclusive):
  (default)                  Install latest stable release from .versions.json
  -s, -snapshot, --snapshot  Install OpenWrt SNAPSHOT build
  -v, -version, --version <ver>
                             Install a specific OpenWrt release (e.g. 25.12.6)

Other options:
  -p, --password <pass>      Set OpenWrt root password (hashed as SHA-512 $6$)
  -d, --disk <dev>           Override auto-detected target disk (e.g. /dev/vda)
  -y, --yes                  Skip the 5-second confirmation countdown
  --dry-run                  Download, verify, pre-seed & fsck in RAM only;
                             do not write to the disk or reboot
  -h, -help, --help          Show this help message and exit

First-boot rootfs expansion package prep:
  The script installs /etc/init.d/firstboot-rootfs-pkgs and
  /usr/sbin/firstboot-install-rootfs-pkgs.sh inside OpenWrt so that on first
  boot (once network is up) it automatically installs:
    parted resize2fs losetup e2fsprogs partx-utils
  It also installs /usr/sbin/expand-rootfs.sh for safe offline rootfs expansion.
EOF
}

# ---------------------------------------------------------------------------
# Argument Parsing
# ---------------------------------------------------------------------------
parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -s|-snapshot|--snapshot)
                if [ -n "$MODE" ] && [ "$MODE" != "snapshot" ]; then
                    die "Options -s/-snapshot and -v/-version are mutually exclusive."
                fi
                MODE="snapshot"
                shift
                ;;
            -v|-version|--version)
                if [ "$#" -lt 2 ] || [ -z "$2" ]; then
                    die "Option $1 requires a version argument (e.g. 25.12.6)."
                fi
                if [ -n "$MODE" ] && [ "$MODE" != "version" ]; then
                    die "Options -s/-snapshot and -v/-version are mutually exclusive."
                fi
                MODE="version"
                TARGET_VERSION="$2"
                shift 2
                ;;
            -v=*|-version=*|--version=*)
                if [ -n "$MODE" ] && [ "$MODE" != "version" ]; then
                    die "Options -s/-snapshot and -v/-version are mutually exclusive."
                fi
                MODE="version"
                TARGET_VERSION="${1#*=}"
                [ -n "$TARGET_VERSION" ] || die "Version value cannot be empty."
                shift
                ;;
            -p|--password)
                [ "$#" -ge 2 ] || die "Option $1 requires a password argument."
                ROOT_PASSWORD="$2"
                shift 2
                ;;
            -p=*|--password=*)
                ROOT_PASSWORD="${1#*=}"
                shift
                ;;
            -d|--disk)
                [ "$#" -ge 2 ] || die "Option $1 requires a block device path."
                OVERRIDE_DISK="$2"
                shift 2
                ;;
            -d=*|--disk=*)
                OVERRIDE_DISK="${1#*=}"
                shift
                ;;
            -y|--yes)
                ASSUME_YES=1
                shift
                ;;
            --dry-run)
                DRY_RUN=1
                shift
                ;;
            -h|-help|--help)
                usage
                exit 0
                ;;
            *)
                die "Unknown argument: $1 (use -h for help)"
                ;;
        esac
    done

    if [ -z "$MODE" ]; then
        MODE="stable"
    fi

    if [ "$MODE" = "version" ]; then
        case "$TARGET_VERSION" in
            *[!0-9A-Za-z._-]*|'')
                die "Invalid OpenWrt version string: '$TARGET_VERSION'"
                ;;
        esac
    fi
}

# ---------------------------------------------------------------------------
# HTTP & Hashing Helpers
# ---------------------------------------------------------------------------
HTTP_TOOL=""
detect_http_tool() {
    if command -v curl >/dev/null 2>&1; then
        HTTP_TOOL="curl"
    elif command -v wget >/dev/null 2>&1; then
        HTTP_TOOL="wget"
    else
        die "Neither curl nor wget is installed."
    fi
}

http_stdout() {
    if [ "$HTTP_TOOL" = "curl" ]; then
        curl -fsSL --connect-timeout 15 --max-time 60 "$1"
    else
        wget -qO- --timeout=60 "$1"
    fi
}

http_download() {
    if [ "$HTTP_TOOL" = "curl" ]; then
        curl -fL --connect-timeout 15 --max-time 600 -o "$2" "$1"
    else
        wget -O "$2" --timeout=600 "$1"
    fi
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Required command '$1' not found."
}

hash_sha512() {
    _pw="$1"
    if command -v openssl >/dev/null 2>&1; then
        _h=$(printf '%s\n' "$_pw" | openssl passwd -6 -stdin 2>/dev/null || openssl passwd -6 "$_pw" 2>/dev/null || true)
        case "$_h" in
            \$6\$*) printf '%s\n' "$_h"; return 0 ;;
        esac
    fi
    if command -v mkpasswd >/dev/null 2>&1; then
        _h=$(printf '%s\n' "$_pw" | mkpasswd -m sha-512 -s 2>/dev/null || true)
        case "$_h" in
            \$6\$*) printf '%s\n' "$_h"; return 0 ;;
        esac
    fi
    if command -v python3 >/dev/null 2>&1; then
        _h=$(PW="$_pw" python3 - <<'PY' 2>/dev/null || true
import os
pw = os.environ["PW"]
try:
    import crypt
    print(crypt.crypt(pw, crypt.mksalt(crypt.METHOD_SHA512)))
except Exception:
    pass
PY
)
        case "$_h" in
            \$6\$*) printf '%s\n' "$_h"; return 0 ;;
        esac
    fi
    return 1
}

# ---------------------------------------------------------------------------
# Reconnaissance: Arch, Boot Mode, Disk, RAM/tmpfs, Network, Credentials
# ---------------------------------------------------------------------------
detect_platform() {
    _arch=$(uname -m)
    case "$_arch" in
        x86_64|amd64)
            OWRT_TARGET="x86"
            OWRT_SUBTARGET="64"
            ;;
        aarch64|arm64)
            OWRT_TARGET="armsr"
            OWRT_SUBTARGET="armv8"
            ;;
        *)
            die "Unsupported CPU architecture '$_arch' (supported: x86_64, aarch64)."
            ;;
    esac

    if [ -d /sys/firmware/efi ] || [ "$OWRT_TARGET" = "armsr" ]; then
        BOOT_MODE="efi"
        IMG_SUFFIX="generic-ext4-combined-efi.img.gz"
    else
        BOOT_MODE="bios"
        IMG_SUFFIX="generic-ext4-combined.img.gz"
    fi
}

detect_root_and_disk() {
    ROOT_DEV_RAW=$(awk '$2 == "/" { print $1; exit }' /proc/mounts)
    [ -n "$ROOT_DEV_RAW" ] || die "Could not determine root device from /proc/mounts."
    ROOT_DEV=$(readlink -f "$ROOT_DEV_RAW" 2>/dev/null || printf '%s' "$ROOT_DEV_RAW")
    [ -b "$ROOT_DEV" ] || die "Root device '$ROOT_DEV' is not a block device (overlay/ZFS/LVM not supported directly)."

    ROOT_PART_BASE=$(basename "$ROOT_DEV")

    if [ -n "$OVERRIDE_DISK" ]; then
        TARGET_DISK=$(readlink -f "$OVERRIDE_DISK" 2>/dev/null || printf '%s' "$OVERRIDE_DISK")
    else
        if [ -e "/sys/class/block/$ROOT_PART_BASE/partition" ]; then
            _sys_part=$(readlink -f "/sys/class/block/$ROOT_PART_BASE")
            _sys_disk=$(dirname "$_sys_part")
            TARGET_DISK="/dev/$(basename "$_sys_disk")"
        else
            # Root is directly on whole disk (unlikely, but handle gracefully)
            TARGET_DISK="$ROOT_DEV"
        fi
    fi

    [ -b "$TARGET_DISK" ] || die "Target disk '$TARGET_DISK' is not a valid block device."
    DISK_BASE=$(basename "$TARGET_DISK")
    [ -r "/sys/block/$DISK_BASE/size" ] || die "Cannot read /sys/block/$DISK_BASE/size."
    DISK_SECTORS=$(cat "/sys/block/$DISK_BASE/size")
    DISK_BYTES=$((DISK_SECTORS * 512))
    [ "$DISK_BYTES" -gt 134217728 ] || die "Target disk $TARGET_DISK is unexpectedly small ($DISK_BYTES bytes)."

    # Check whether the existing disk uses GPT (so we wipe trailing backup GPT if writing MBR)
    HAS_GPT=0
    if dd if="$TARGET_DISK" bs=512 skip=1 count=1 2>/dev/null | grep -q "EFI PART"; then
        HAS_GPT=1
    fi
}

setup_ram_workdir() {
    # Require >= 280 MiB in RAM tmpfs for compressed + uncompressed image + tools
    _tmp_fstype=$(awk '$2 == "/tmp" { print $3; exit }' /proc/mounts)
    _tmp_avail_kb=0
    if [ "$_tmp_fstype" = "tmpfs" ]; then
        _tmp_avail_kb=$(df -Pk /tmp | awk 'NR==2 { print $4 }')
    fi

    if [ "$_tmp_fstype" = "tmpfs" ] && [ "${_tmp_avail_kb:-0}" -ge 286720 ]; then
        WORK_DIR="/tmp/owrt-hot-install.$$"
        mkdir -p "$WORK_DIR"
        MOUNTED_TMPFS=0
    else
        _mem_avail_kb=$(awk '/MemAvailable:/ { print $2; exit }' /proc/meminfo)
        [ "${_mem_avail_kb:-0}" -ge 327680 ] || die "Not enough free RAM (MemAvailable=${_mem_avail_kb:-0} KiB, need >= 320 MiB)."
        WORK_DIR="/mnt/owrt-ram.$$"
        mkdir -p "$WORK_DIR"
        mount -t tmpfs -o size=300M tmpfs "$WORK_DIR"
        MOUNTED_TMPFS=1
    fi
    BOOT_MNT="$WORK_DIR/mnt_boot"
    ROOT_MNT="$WORK_DIR/mnt_root"
    mkdir -p "$BOOT_MNT" "$ROOT_MNT"
}

cidr_to_netmask() {
    _p="$1"
    _out=""
    _i=0
    while [ "$_i" -lt 4 ]; do
        if [ "$_p" -ge 8 ]; then
            _oct=255
            _p=$((_p - 8))
        elif [ "$_p" -gt 0 ]; then
            _shift=$((8 - _p))
            _oct=$(( (255 << _shift) & 255 ))
            _p=0
        else
            _oct=0
        fi
        if [ -z "$_out" ]; then
            _out="$_oct"
        else
            _out="${_out}.${_oct}"
        fi
        _i=$((_i + 1))
    done
    printf '%s\n' "$_out"
}

same_subnet_v4() {
    _ip="$1"
    _gw="$2"
    _mask="$3"
    awk -v ip="$_ip" -v gw="$_gw" -v mask="$_mask" '
        function band(a, b,    r, p, i) {
            r = 0; p = 1
            for (i = 0; i < 8; i++) {
                if ((a % 2) == 1 && (b % 2) == 1) r += p
                a = int(a / 2); b = int(b / 2); p *= 2
            }
            return r
        }
        BEGIN {
            split(ip, A, "."); split(gw, B, "."); split(mask, M, ".")
            for (i = 1; i <= 4; i++) {
                if (band(A[i]+0, M[i]+0) != band(B[i]+0, M[i]+0)) exit 1
            }
            exit 0
        }
    '
}

detect_network() {
    _def4=$(ip -4 route show default | head -n 1)
    [ -n "$_def4" ] || die "No IPv4 default route found; cannot preserve network settings safely."

    WAN_IF=$(printf '%s\n' "$_def4" | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
    GW4=$(printf '%s\n' "$_def4" | awk '{for(i=1;i<=NF;i++) if($i=="via"){print $(i+1); exit}}')
    [ -n "$WAN_IF" ] || die "Could not determine WAN interface from default IPv4 route."
    [ -n "$GW4" ] || die "Could not determine IPv4 gateway (via) from default route."

    WAN_MAC=""
    if [ -r "/sys/class/net/$WAN_IF/address" ]; then
        WAN_MAC=$(cat "/sys/class/net/$WAN_IF/address")
    fi

    _addr4_cidr=$(ip -4 -o addr show dev "$WAN_IF" scope global | awk 'NR==1 { print $4 }')
    [ -n "$_addr4_cidr" ] || die "No global IPv4 address found on interface '$WAN_IF'."
    IP4="${_addr4_cidr%/*}"
    PREFIX4="${_addr4_cidr#*/}"
    MASK4=$(cidr_to_netmask "$PREFIX4")

    ONLINK_GW=0
    case "$_def4" in
        *onlink*) ONLINK_GW=1 ;;
    esac
    if [ "$PREFIX4" -eq 32 ] || ! same_subnet_v4 "$IP4" "$GW4" "$MASK4"; then
        ONLINK_GW=1
    fi

    # Optional IPv6 detection
    IP6_CIDR=$(ip -6 -o addr show dev "$WAN_IF" scope global | awk 'NR==1 { print $4 }' || true)
    GW6=""
    _def6=$(ip -6 route show default dev "$WAN_IF" | head -n 1 || true)
    if [ -n "$_def6" ]; then
        GW6=$(printf '%s\n' "$_def6" | awk '{for(i=1;i<=NF;i++) if($i=="via"){print $(i+1); exit}}')
    fi

    # DNS servers (skip systemd-resolved loopback stubs)
    DNS_LIST=""
    for _rc in /run/systemd/resolve/resolv.conf /etc/resolv.conf; do
        [ -r "$_rc" ] || continue
        _found=$(awk '/^nameserver[[:space:]]+/ {
            ip=$2
            if (ip !~ /^127\./ && ip != "::1") print ip
        }' "$_rc" | head -n 3 | tr '\n' ' ')
        if [ -n "$_found" ]; then
            DNS_LIST="$_found"
            break
        fi
    done
    if [ -z "$DNS_LIST" ]; then
        DNS_LIST="1.1.1.1 8.8.8.8"
    fi
}

prepare_credentials() {
    HAS_AUTH_KEYS=0
    if [ -s /root/.ssh/authorized_keys ]; then
        HAS_AUTH_KEYS=1
    fi

    if [ -n "$ROOT_PASSWORD" ]; then
        PASS_HASH=$(hash_sha512 "$ROOT_PASSWORD") || die "Failed to generate SHA-512 (\$6\$) password hash."
        return 0
    fi

    # Check existing /etc/shadow hash compatibility with OpenWrt musl crypt()
    _cur_hash=$(awk -F: '$1 == "root" { print $2; exit }' /etc/shadow 2>/dev/null || true)
    case "$_cur_hash" in
        \$6\$*|\$5\$*|\$2a\$*|\$2b\$*|\$1\$*)
            PASS_HASH="$_cur_hash"
            ;;
        *)
            if [ "$HAS_AUTH_KEYS" -eq 1 ]; then
                warn "Current root shadow hash is not musl-compatible (e.g. yescrypt \$y\$) and -p was not specified; SSH key auth from /root/.ssh/authorized_keys will be preserved, password login left unset."
                PASS_HASH=""
            else
                die "Current root shadow hash uses an incompatible scheme (e.g. \$y\$ yescrypt) and no /root/.ssh/authorized_keys exist. Pass -p <password>."
            fi
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Resolve OpenWrt Version & Download/Verify Image
# ---------------------------------------------------------------------------
resolve_version_and_urls() {
    if [ "$MODE" = "stable" ]; then
        log "Fetching latest stable OpenWrt version from $VERSIONS_URL ..."
        _vjson=$(http_stdout "$VERSIONS_URL") || die "Failed to download $VERSIONS_URL"
        TARGET_VERSION=$(printf '%s\n' "$_vjson" | sed -n 's/.*"stable_version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
        [ -n "$TARGET_VERSION" ] || die "Could not parse stable_version from $VERSIONS_URL"
        BASE_URL="$RELEASES_BASE/$TARGET_VERSION/targets/$OWRT_TARGET/$OWRT_SUBTARGET"
    elif [ "$MODE" = "version" ]; then
        BASE_URL="$RELEASES_BASE/$TARGET_VERSION/targets/$OWRT_TARGET/$OWRT_SUBTARGET"
    else
        TARGET_VERSION="SNAPSHOT"
        BASE_URL="$SNAPSHOT_BASE/targets/$OWRT_TARGET/$OWRT_SUBTARGET"
    fi

    log "Target OpenWrt: $TARGET_VERSION ($OWRT_TARGET/$OWRT_SUBTARGET, boot=$BOOT_MODE)"
    log "Feed base URL: $BASE_URL"

    _sums=$(http_stdout "$BASE_URL/sha256sums") || die "Failed to fetch $BASE_URL/sha256sums (check version/target)."
    _match=$(printf '%s\n' "$_sums" | awk -v suf="$IMG_SUFFIX" '$2 ~ "^\\*.*" suf "$" { print $1 " " substr($2, 2); exit }')
    [ -n "$_match" ] || die "Could not find image ending with '$IMG_SUFFIX' in $BASE_URL/sha256sums"

    IMG_SHA256="${_match%% *}"
    IMG_NAME="${_match#* }"
    IMG_URL="$BASE_URL/$IMG_NAME"
}

download_and_unpack_image() {
    log "Downloading $IMG_URL into RAM ($WORK_DIR)..."
    http_download "$IMG_URL" "$WORK_DIR/openwrt.img.gz" || die "Image download failed."

    log "Verifying SHA-256 checksum ($IMG_SHA256)..."
    printf '%s  %s\n' "$IMG_SHA256" "$WORK_DIR/openwrt.img.gz" | sha256sum -c - || die "SHA-256 verification failed."

    log "Decompressing image in RAM..."
    gunzip -f "$WORK_DIR/openwrt.img.gz"
    IMG_FILE="$WORK_DIR/openwrt.img"
    [ -s "$IMG_FILE" ] || die "Decompressed image is missing or empty."
    IMG_BYTES=$(wc -c < "$IMG_FILE" | tr -d ' ')
    [ "$IMG_BYTES" -gt 10485760 ] || die "Unexpected decompressed image size: $IMG_BYTES bytes."
}

# ---------------------------------------------------------------------------
# Pre-seed Image: Shadow, SSH Keys, UCI Defaults, First-Boot Rootfs Pkgs
# ---------------------------------------------------------------------------
customize_image() {
    log "Attaching loop device for $IMG_FILE..."
    LOOP_DEV=$(losetup --find --show --partscan "$IMG_FILE")
    [ -b "$LOOP_DEV" ] || die "losetup failed."

    if [ ! -b "${LOOP_DEV}p2" ]; then
        command -v partx >/dev/null 2>&1 && partx -a "$LOOP_DEV" 2>/dev/null || true
        sleep 1
    fi
    [ -b "${LOOP_DEV}p1" ] && [ -b "${LOOP_DEV}p2" ] || die "Loop partition nodes ${LOOP_DEV}p1/${LOOP_DEV}p2 not found."

    # Verify boot partition
    mount -o ro "${LOOP_DEV}p1" "$BOOT_MNT"
    if [ ! -f "$BOOT_MNT/boot/grub/grub.cfg" ] && [ ! -d "$BOOT_MNT/EFI" ]; then
        die "Boot partition ${LOOP_DEV}p1 does not contain GRUB config or EFI directory."
    fi
    umount "$BOOT_MNT"

    # Mount rootfs rw
    mount "${LOOP_DEV}p2" "$ROOT_MNT"

    # 1. Root password & SSH keys
    if [ -n "$PASS_HASH" ]; then
        _shadow="$ROOT_MNT/etc/shadow"
        [ -f "$_shadow" ] || die "Missing $_shadow in OpenWrt rootfs."
        _mode=$(stat -c '%a' "$_shadow" 2>/dev/null || printf '600')
        PASS_HASH="$PASS_HASH" awk -F: 'BEGIN{OFS=":"} $1=="root"{$2=ENVIRON["PASS_HASH"]} {print}' "$_shadow" > "${_shadow}.new"
        mv "${_shadow}.new" "$_shadow"
        chmod "$_mode" "$_shadow"
        grep -q '^root:\$' "$_shadow" || die "Failed to set root hash in $_shadow."
    fi

    if [ "$HAS_AUTH_KEYS" -eq 1 ]; then
        mkdir -p "$ROOT_MNT/etc/dropbear"
        cp /root/.ssh/authorized_keys "$ROOT_MNT/etc/dropbear/authorized_keys"
        chmod 600 "$ROOT_MNT/etc/dropbear/authorized_keys"
    fi

    # Detect dropbear section name (usually 'main' on 25.x, anonymous on older releases)
    DROPBEAR_SEC="@dropbear[0]"
    if [ -f "$ROOT_MNT/etc/config/dropbear" ] && grep -qE "^config[[:space:]]+dropbear[[:space:]]+['\"]?main['\"]?" "$ROOT_MNT/etc/config/dropbear"; then
        DROPBEAR_SEC="main"
    fi

    # 2. First-boot UCI configuration script (runs last via zzz- prefix)
    mkdir -p "$ROOT_MNT/etc/uci-defaults"
    _uci_script="$ROOT_MNT/etc/uci-defaults/zzz-99-vps-setup"
    {
        cat <<EOF
#!/bin/sh
# Generated by openwrt-hot-install.sh

WAN_DEV="eth0"
if [ -n "${WAN_MAC}" ]; then
    for p in /sys/class/net/*; do
        [ -f "\$p/address" ] || continue
        if [ "\$(cat "\$p/address")" = "${WAN_MAC}" ]; then
            WAN_DEV="\$(basename "\$p")"
            break
        fi
    done
fi

ULA_PREFIX="\$(uci -q get network.globals.ula_prefix || true)"

cat <<EONET > /etc/config/network
config interface 'loopback'
	option device 'lo'
	option proto 'static'
	option ipaddr '127.0.0.1'
	option netmask '255.255.255.0'

config globals 'globals'
	option dhcp_default_duid 'auto'

config device
	option name 'br-lan'
	option type 'bridge'
	option bridge_empty '1'

config interface 'lan'
	option device 'br-lan'
	option proto 'static'
	option ipaddr '192.168.1.1'
	option netmask '255.255.255.0'
	option ip6assign '60'

config interface 'wan'
	option device '\$WAN_DEV'
	option proto 'static'
	option ipaddr '${IP4}'
	option netmask '${MASK4}'
EOF
        if [ "$ONLINK_GW" -eq 0 ]; then
            printf "\toption gateway '%s'\n" "$GW4"
        fi
        if [ -n "$IP6_CIDR" ]; then
            printf "\toption ip6addr '%s'\n" "$IP6_CIDR"
        fi
        if [ -n "$GW6" ]; then
            printf "\toption ip6gw '%s'\n" "$GW6"
        fi
        for _dns in $DNS_LIST; do
            printf "\tlist dns '%s'\n" "$_dns"
        done
        if [ "$ONLINK_GW" -eq 1 ]; then
            cat <<EONET_ROUTES

config route 'wan_gw_link'
	option interface 'wan'
	option target '${GW4}/32'

config route 'wan_default'
	option interface 'wan'
	option target '0.0.0.0/0'
	option gateway '${GW4}'
	option onlink '1'
EONET_ROUTES
        fi
        cat <<EOF
EONET

[ -n "\$ULA_PREFIX" ] && uci set network.globals.ula_prefix="\$ULA_PREFIX"

# Never serve DHCP or RA on VPS provider network
uci -q set dhcp.lan.ignore='1'
uci -q set dhcp.lan.dhcpv6='disabled'
uci -q set dhcp.lan.ra='disabled'
uci -q set dhcp.wan.ignore='1'

# Allow SSH on wan in firewall4
uci -q delete firewall.allow_ssh
uci set firewall.allow_ssh=rule
uci set firewall.allow_ssh.name='Allow-SSH'
uci set firewall.allow_ssh.src='wan'
uci set firewall.allow_ssh.proto='tcp'
uci set firewall.allow_ssh.dest_port='22'
uci set firewall.allow_ssh.target='ACCEPT'

# Ensure dropbear listens on all interfaces with SSH enabled
uci -q delete dropbear.${DROPBEAR_SEC}.Interface
uci -q set dropbear.${DROPBEAR_SEC}.enable='1'
uci -q set dropbear.${DROPBEAR_SEC}.Port='22'
EOF
        if [ -n "$PASS_HASH" ]; then
            cat <<EOF
uci -q set dropbear.${DROPBEAR_SEC}.PasswordAuth='on'
uci -q set dropbear.${DROPBEAR_SEC}.RootPasswordAuth='on'
EOF
        fi
        cat <<'EOF'

uci commit
exit 0
EOF
    } > "$_uci_script"
    chmod 755 "$_uci_script"
    sh -n "$_uci_script"

    # 3. First-boot package installer for rootfs expansion tools
    mkdir -p "$ROOT_MNT/usr/sbin" "$ROOT_MNT/etc/init.d" "$ROOT_MNT/etc/rc.d" "$ROOT_MNT/var/log"

    cat <<'EOF' > "$ROOT_MNT/usr/sbin/firstboot-install-rootfs-pkgs.sh"
#!/bin/sh
# Installs packages needed to expand OpenWrt rootfs to the full disk on first boot.

LOG_FILE="/var/log/firstboot-rootfs-pkgs.log"
DONE_FILE="/etc/firstboot-rootfs-pkgs.done"
PKGS="parted resize2fs losetup e2fsprogs partx-utils"

log_msg() {
    logger -t firstboot-rootfs-pkgs "$*" 2>/dev/null || true
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo 'boot')" "$*" >> "$LOG_FILE"
}

[ -f "$DONE_FILE" ] && exit 0

log_msg "Waiting for network/DNS connectivity to downloads.openwrt.org..."
_ready=0
_i=0
while [ "$_i" -lt 60 ]; do
    if command -v uclient-fetch >/dev/null 2>&1; then
        if uclient-fetch -q --spider --timeout=5 "https://downloads.openwrt.org/.versions.json" >/dev/null 2>&1; then
            _ready=1
            break
        fi
    elif command -v wget >/dev/null 2>&1; then
        if wget -q --spider --timeout=5 "https://downloads.openwrt.org/.versions.json" >/dev/null 2>&1; then
            _ready=1
            break
        fi
    elif nslookup downloads.openwrt.org >/dev/null 2>&1; then
        _ready=1
        break
    fi
    _i=$((_i + 1))
    sleep 3
done

if [ "$_ready" -ne 1 ]; then
    log_msg "ERROR: Network/DNS did not become ready within 180s; will retry next boot."
    exit 1
fi

if command -v apk >/dev/null 2>&1; then
    PKG_MGR="apk"
elif command -v opkg >/dev/null 2>&1; then
    PKG_MGR="opkg"
else
    log_msg "ERROR: Neither apk nor opkg found."
    exit 1
fi

_attempt=1
_ok=0
while [ "$_attempt" -le 3 ]; do
    log_msg "Installing ($PKG_MGR) attempt $_attempt: $PKGS"
    if [ "$PKG_MGR" = "apk" ]; then
        if apk update >> "$LOG_FILE" 2>&1 && apk add $PKGS >> "$LOG_FILE" 2>&1; then
            _ok=1
            break
        fi
    else
        if opkg update >> "$LOG_FILE" 2>&1 && opkg install $PKGS >> "$LOG_FILE" 2>&1; then
            _ok=1
            break
        fi
    fi
    _attempt=$((_attempt + 1))
    sleep 5
done

if [ "$_ok" -ne 1 ]; then
    log_msg "ERROR: Package installation failed after 3 attempts; check $LOG_FILE."
    exit 1
fi

date > "$DONE_FILE" 2>/dev/null || touch "$DONE_FILE"
log_msg "SUCCESS: Installed rootfs expansion packages ($PKGS)."
/etc/init.d/firstboot-rootfs-pkgs disable 2>/dev/null || rm -f /etc/rc.d/S99firstboot-rootfs-pkgs
exit 0
EOF
    chmod 755 "$ROOT_MNT/usr/sbin/firstboot-install-rootfs-pkgs.sh"
    sh -n "$ROOT_MNT/usr/sbin/firstboot-install-rootfs-pkgs.sh"

    cat <<'EOF' > "$ROOT_MNT/etc/init.d/firstboot-rootfs-pkgs"
#!/bin/sh /etc/rc.common

START=99

start() {
    [ -f /etc/firstboot-rootfs-pkgs.done ] && return 0
    /usr/sbin/firstboot-install-rootfs-pkgs.sh >/dev/null 2>&1 &
}
EOF
    chmod 755 "$ROOT_MNT/etc/init.d/firstboot-rootfs-pkgs"
    sh -n "$ROOT_MNT/etc/init.d/firstboot-rootfs-pkgs"
    ln -sf "../init.d/firstboot-rootfs-pkgs" "$ROOT_MNT/etc/rc.d/S99firstboot-rootfs-pkgs"

    # 4. Helper script inside OpenWrt to safely expand rootfs offline from RAM chroot
    cat <<'EOF' > "$ROOT_MNT/usr/sbin/expand-rootfs.sh"
#!/bin/sh
# Safely expands OpenWrt's ext4 root partition (p2) to 100% of the disk
# using an isolated RAM tmpfs chroot so malformed make_ext4fs resize_inode
# metadata never fails online resizing.

set -eu

for c in parted partx losetup e2fsck resize2fs; do
    command -v "$c" >/dev/null 2>&1 || { echo "Missing required command: $c (wait for firstboot-rootfs-pkgs or install it)."; exit 1; }
done

BOOT_DEV=$(awk '$2 == "/boot" { print $1; exit }' /proc/mounts)
[ -n "$BOOT_DEV" ] || { echo "Could not detect /boot device."; exit 1; }
PART_NUM="${BOOT_DEV##*[!0-9]}"
DISK_PREFIX="${BOOT_DEV%${PART_NUM}}"
ROOT_PART="${DISK_PREFIX}$((PART_NUM + 1))"
DISK_DEV="${DISK_PREFIX%p}"
[ -b "$DISK_DEV" ] || DISK_DEV="$DISK_PREFIX"
[ -b "$DISK_DEV" ] && [ -b "$ROOT_PART" ] || { echo "Invalid disk ($DISK_DEV) or root partition ($ROOT_PART)."; exit 1; }

echo "Target disk: $DISK_DEV, root partition: $ROOT_PART"
parted -f -s "$DISK_DEV" resizepart "$((PART_NUM + 1))" 100%
partx -u "$DISK_DEV" 2>/dev/null || true

rm -rf /tmp/ramroot
mkdir -p /tmp/ramroot/bin /tmp/ramroot/sbin /tmp/ramroot/usr/sbin /tmp/ramroot/lib /tmp/ramroot/usr/lib /tmp/ramroot/etc /tmp/ramroot/dev /tmp/ramroot/proc
cp -L /bin/busybox /tmp/ramroot/bin/busybox
cp -L /usr/sbin/e2fsck /tmp/ramroot/usr/sbin/e2fsck
cp -L /usr/sbin/resize2fs /tmp/ramroot/usr/sbin/resize2fs
cp -L /usr/sbin/losetup /tmp/ramroot/usr/sbin/losetup
[ -f /etc/e2fsck.conf ] && cp -L /etc/e2fsck.conf /tmp/ramroot/etc/e2fsck.conf
for cmd in sh sync sleep grep cat echo mount umount ls test [; do
    ln -sf /bin/busybox "/tmp/ramroot/bin/$cmd"
done
for bin in /bin/busybox /usr/sbin/e2fsck /usr/sbin/resize2fs /usr/sbin/losetup; do
    for lib in $(ldd "$bin" 2>/dev/null | tr ' \t' '\n\n' | grep '^/'); do
        [ -e "$lib" ] || continue
        mkdir -p "/tmp/ramroot$(dirname "$lib")"
        cp -L "$lib" "/tmp/ramroot$lib"
    done
done
mount --bind /dev /tmp/ramroot/dev
mount --bind /proc /tmp/ramroot/proc

cat <<EODO > /tmp/ramroot/do_resize.sh
#!/bin/sh
export PATH=/bin:/sbin:/usr/sbin
trap '' HUP INT TERM
losetup -d /dev/loop0 2>/dev/null || true
losetup /dev/loop0 "${ROOT_PART}" || exit 1
e2fsck -fy /dev/loop0 || true
resize2fs -f /dev/loop0
e2fsck -fy /dev/loop0 || true
e2fsck -fn /dev/loop0
losetup -d /dev/loop0
sync
echo s > /proc/sysrq-trigger
echo "Resize complete. Rebooting via SysRq-b..."
sleep 2
echo b > /proc/sysrq-trigger
EODO
chmod 755 /tmp/ramroot/do_resize.sh

echo 1 > /proc/sys/kernel/sysrq
sync
echo s > /proc/sysrq-trigger
sleep 1
echo u > /proc/sysrq-trigger

RO_OK=0
_i=0
while [ "$_i" -lt 15 ]; do
    sleep 1
    if grep -qE '^/dev/root / ext4 ([^ ]*,)?ro(,| )' /proc/mounts; then
        RO_OK=1
        break
    fi
    _i=$((_i + 1))
done
[ "$RO_OK" = "1" ] || { echo "ABORT: / did not remount read-only."; exit 1; }
exec chroot /tmp/ramroot /bin/sh /do_resize.sh
EOF
    chmod 755 "$ROOT_MNT/usr/sbin/expand-rootfs.sh"
    sh -n "$ROOT_MNT/usr/sbin/expand-rootfs.sh"

    sync
    umount "$ROOT_MNT"

    # Verify customized rootfs cleanly
    set +e
    e2fsck -fn "${LOOP_DEV}p2" >"$WORK_DIR/fsck.log" 2>&1
    _fsck_rc=$?
    set -e
    if [ "$_fsck_rc" -ne 0 ]; then
        if grep -q "Padding at end of inode bitmap is not set" "$WORK_DIR/fsck.log" && ! grep -q "UNEXPECTED INCONSISTENCY" "$WORK_DIR/fsck.log"; then
            log "Fixing benign make_ext4fs inode bitmap padding via e2fsck -fy..."
            set +e
            e2fsck -fy "${LOOP_DEV}p2"
            _fix_rc=$?
            set -e
            [ "$_fix_rc" -le 1 ] || die "e2fsck -fy failed with code $_fix_rc"
            e2fsck -fn "${LOOP_DEV}p2"
        else
            cat "$WORK_DIR/fsck.log" >&2
            die "e2fsck -fn reported errors on customized rootfs (code $_fsck_rc)."
        fi
    fi

    losetup -d "$LOOP_DEV"
    LOOP_DEV=""
}

# ---------------------------------------------------------------------------
# Flashing & Rebooting
# ---------------------------------------------------------------------------
stop_disk_writers() {
    if command -v systemctl >/dev/null 2>&1; then
        systemctl stop systemd-journald.socket systemd-journald cron crond rsyslog unattended-upgrades 2>/dev/null || true
    fi
}

flash_with_python() {
    cat <<'PY' > "$WORK_DIR/flash.py"
#!/usr/bin/env python3
import ctypes
import os
import signal
import sys
import time

signal.signal(signal.SIGHUP, signal.SIG_IGN)
signal.signal(signal.SIGINT, signal.SIG_IGN)
signal.signal(signal.SIGTERM, signal.SIG_IGN)

img_path = sys.argv[1]
disk_path = sys.argv[2]
expected_disk_bytes = int(sys.argv[3])
root_dev = sys.argv[4]
has_gpt = int(sys.argv[5])
boot_mode = sys.argv[6]

img_size = os.path.getsize(img_path)
assert img_size > 10 * 1024 * 1024, f"Unexpected image size: {img_size}"

with open("/proc/sys/kernel/sysrq", "wb") as f:
    f.write(b"1\n")

img_fd = os.open(img_path, os.O_RDONLY)
disk_fd = os.open(disk_path, os.O_RDWR)
sysrq_fd = os.open("/proc/sysrq-trigger", os.O_WRONLY)
mounts_fd = os.open("/proc/mounts", os.O_RDONLY)

actual_disk_bytes = os.lseek(disk_fd, 0, os.SEEK_END)
assert actual_disk_bytes == expected_disk_bytes, f"Disk size mismatch: {actual_disk_bytes} != {expected_disk_bytes}"
os.lseek(disk_fd, 0, os.SEEK_SET)

zero_buf = b"\x00" * (1024 * 1024)
CHUNK = 4 * 1024 * 1024

libc = ctypes.CDLL("libc.so.6", use_errno=True)
rc = libc.mlockall(1 | 2)
if rc != 0:
    errno = ctypes.get_errno()
    raise OSError(errno, f"mlockall failed: errno={errno}")

os.sync()
os.write(sysrq_fd, b"s")
time.sleep(1.0)
os.write(sysrq_fd, b"u")

ro_ok = False
for _ in range(75):
    time.sleep(0.2)
    os.lseek(mounts_fd, 0, os.SEEK_SET)
    data = os.read(mounts_fd, 65536).decode("ascii", errors="ignore")
    for line in data.splitlines():
        parts = line.split()
        if len(parts) >= 4 and parts[1] == "/" and (parts[0] == root_dev or os.path.realpath(parts[0]) == root_dev):
            if "ro" in parts[3].split(","):
                ro_ok = True
                break
    if ro_ok:
        break

if not ro_ok:
    print("ABORT: / did not remount read-only; target disk untouched.", flush=True)
    sys.exit(1)

print(f"OK: / is read-only. Flashing {img_size} bytes to {disk_path}...", flush=True)

if has_gpt == 1 and boot_mode == "bios":
    os.lseek(disk_fd, expected_disk_bytes - len(zero_buf), os.SEEK_SET)
    off = 0
    while off < len(zero_buf):
        off += os.write(disk_fd, zero_buf[off:])

os.lseek(disk_fd, 0, os.SEEK_SET)
os.lseek(img_fd, 0, os.SEEK_SET)
total = 0
while True:
    buf = os.read(img_fd, CHUNK)
    if not buf:
        break
    off = 0
    while off < len(buf):
        n = os.write(disk_fd, buf[off:])
        if n <= 0:
            raise RuntimeError("Short write to target disk")
        off += n
    total += len(buf)

assert total == img_size, f"Short total write: {total} != {img_size}"
os.fsync(disk_fd)
os.lseek(disk_fd, 0, os.SEEK_SET)
mbr = os.read(disk_fd, 512)
assert mbr[510:512] == b"\x55\xaa", "MBR/protective-MBR boot signature 0x55aa missing!"

os.sync()
os.write(sysrq_fd, b"s")
print(f"SUCCESS: Flashed {total} bytes to {disk_path}. Rebooting via SysRq-b...", flush=True)
time.sleep(1.5)
os.write(sysrq_fd, b"b")
PY
    python3 -m py_compile "$WORK_DIR/flash.py"
    stop_disk_writers
    python3 "$WORK_DIR/flash.py" "$IMG_FILE" "$TARGET_DISK" "$DISK_BYTES" "$ROOT_DEV" "$HAS_GPT" "$BOOT_MODE"
}

flash_with_ramroot() {
    _ram="$WORK_DIR/ramroot"
    mkdir -p "$_ram/bin" "$_ram/dev" "$_ram/proc" "$_ram/img"
    _sh_bin=$(command -v sh)
    _dd_bin=$(command -v dd)
    cp -L "$_sh_bin" "$_ram/bin/sh"
    cp -L "$_dd_bin" "$_ram/bin/dd"
    for _cmd in sleep echo sync; do
        if command -v "$_cmd" >/dev/null 2>&1; then
            cp -L "$(command -v "$_cmd")" "$_ram/bin/$_cmd"
        fi
    done
    for _bin in "$_sh_bin" "$_dd_bin"; do
        for _lib in $(ldd "$_bin" 2>/dev/null | tr ' \t' '\n\n' | grep '^/'); do
            [ -e "$_lib" ] || continue
            mkdir -p "$_ram$(dirname "$_lib")"
            cp -L "$_lib" "$_ram$_lib"
        done
    done
    mv "$IMG_FILE" "$_ram/img/openwrt.img"
    mount --bind /dev "$_ram/dev"
    mount --bind /proc "$_ram/proc"

    _seek_mb=$(( (DISK_BYTES / 1048576) - 1 ))
    cat <<EOF > "$_ram/do_flash.sh"
#!/bin/sh
export PATH=/bin
trap '' HUP INT TERM
if [ "$HAS_GPT" = "1" ] && [ "$BOOT_MODE" = "bios" ] && [ "$_seek_mb" -gt 0 ]; then
    dd if=/dev/zero of="$TARGET_DISK" bs=1M count=1 seek="$_seek_mb" conv=notrunc 2>/dev/null || true
fi
dd if=/img/openwrt.img of="$TARGET_DISK" bs=4M conv=fsync
sync
echo s > /proc/sysrq-trigger
echo "SUCCESS: Flashed OpenWrt to $TARGET_DISK. Rebooting via SysRq-b..."
sleep 2
echo b > /proc/sysrq-trigger
EOF
    chmod 755 "$_ram/do_flash.sh"

    stop_disk_writers
    echo 1 > /proc/sys/kernel/sysrq
    sync
    echo s > /proc/sysrq-trigger
    sleep 1
    echo u > /proc/sysrq-trigger

    _ro_ok=0
    _i=0
    while [ "$_i" -lt 15 ]; do
        sleep 1
        if awk '$2 == "/" { print $4 }' /proc/mounts | tr ',' '\n' | grep -qx 'ro'; then
            _ro_ok=1
            break
        fi
        _i=$((_i + 1))
    done
    [ "$_ro_ok" -eq 1 ] || die "ABORT: / did not remount read-only; target disk untouched."

    exec chroot "$_ram" /bin/sh /do_flash.sh
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    parse_args "$@"

    [ "$(id -u)" -eq 0 ] || die "Must be run as root."

    detect_http_tool
    for _c in gunzip sha256sum losetup mount umount e2fsck dd awk sed grep ip; do
        require_cmd "$_c"
    done

    detect_platform
    detect_root_and_disk
    detect_network
    prepare_credentials
    setup_ram_workdir
    resolve_version_and_urls

    log "=== Pre-flight Summary ==="
    log "  OpenWrt version : $TARGET_VERSION ($OWRT_TARGET/$OWRT_SUBTARGET, $BOOT_MODE)"
    log "  Image           : $IMG_NAME"
    log "  Target disk     : $TARGET_DISK (${DISK_BYTES} bytes, GPT=$HAS_GPT, root=$ROOT_DEV)"
    log "  Network         : $WAN_IF ($WAN_MAC) -> $IP4/$PREFIX4 (gw $GW4, onlink=$ONLINK_GW)"
    if [ -n "$IP6_CIDR" ]; then
        log "  IPv6            : $IP6_CIDR (gw ${GW6:-none})"
    fi
    log "  DNS             : $DNS_LIST"
    log "  RAM workdir     : $WORK_DIR"

    download_and_unpack_image
    customize_image

    if [ "$DRY_RUN" -eq 1 ]; then
        log "DRY-RUN complete: image downloaded, verified, pre-seeded, and e2fsck passed. Disk $TARGET_DISK untouched."
        exit 0
    fi

    if [ "$ASSUME_YES" -ne 1 ]; then
        log "WARNING: About to overwrite $TARGET_DISK with OpenWrt $TARGET_VERSION in 5 seconds (Ctrl+C to abort)..."
        sleep 5
    fi

    if command -v python3 >/dev/null 2>&1; then
        flash_with_python
    else
        flash_with_ramroot
    fi
}

main "$@"
