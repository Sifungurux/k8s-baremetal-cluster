#!/usr/bin/env bash
# Build a self-installing Debian ISO for this rack.
#
# Takes the current Debian stable netinst image and adds three things:
#   /preseed.cfg          unattended install, LVM sized to leave Longhorn room
#   /k8s-ansible.tar.gz   this repo, unpacked to /opt on the target
#   one boot menu entry per inventory host, so the hostname is a menu choice
#
# Result is a hybrid ISO: dd it to a USB stick, boot a node, pick its name.
set -euo pipefail

cd "$(dirname "$0")/.."
REPO_ROOT=$(pwd)
# Overridable so installer/test-build.sh can render against fixtures.
VARS=${VARS:-inventory/group_vars/all.yml}
HOSTS=${HOSTS:-inventory/hosts.yml}
OUT=dist/k8s-node-installer.iso
KEY="${HOME}/.ssh/id_ed25519.pub"
DRY_RUN=false
MIRROR="${DEBIAN_MIRROR:-deb.debian.org}"
CD_BASE="${DEBIAN_CD_BASE:-https://cdimage.debian.org/debian-cd/current/amd64/iso-cd}"

usage() {
    cat <<USAGE
usage: installer/build-iso.sh [--key PUBKEY] [--out ISO] [--dry-run]

  --key      SSH public key authorised on every node (default: ~/.ssh/id_ed25519.pub)
  --out      output ISO path (default: $OUT)
  --dry-run  render preseed.cfg and the boot menu into dist/ and stop; no download,
             no xorriso. Use it to check the generated config against the inventory.

env:
  INSTALLER_PASSWORD_CRYPTED  crypt(3) hash for the console password of the admin
                              user. Unset means no password: SSH key only, and
                              recovery needs the installer's rescue mode.
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        --key) KEY=$2; shift 2 ;;
        --out) OUT=$2; shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

die() { echo "build-iso: $*" >&2; exit 1; }

command -v yq >/dev/null || die "yq is required (brew install yq)"

# Everything the first-boot playbook needs has to be real before an image is
# worth burning — a CHANGEME only surfaces as a failed install at the rack.
if grep -q CHANGEME "$VARS"; then
    die "fill in $VARS first — still CHANGEME: $(grep -c CHANGEME "$VARS") value(s)"
fi

get() { yq -r "$1" "$2"; }
VG=$(get '.longhorn_vg' "$VARS")
LV_SIZE=$(get '.longhorn_lv_size' "$VARS")
DISK=$(get '.installer_disk' "$VARS")
ROOT_GB=$(get '.installer_root_size_gb' "$VARS")
TIMEZONE=$(get '.installer_timezone' "$VARS")
KEYMAP=$(get '.installer_keymap' "$VARS")
DOMAIN=$(get '.installer_domain' "$VARS")
ADMIN_USER=$(get '.all.vars.ansible_user' "$HOSTS")

[ "$ADMIN_USER" != "CHANGEME" ] && [ "$ADMIN_USER" != "null" ] \
    || die "set all.vars.ansible_user in $HOSTS — it is the account the image creates"
[ -r "$KEY" ] || die "no SSH public key at $KEY — pass --key; without one the nodes are unreachable"
case "$(cat "$KEY")" in
    ssh-*|ecdsa-*) : ;;
    *) die "$KEY does not look like an SSH public key" ;;
esac

ROOT_MAX_MB=$((ROOT_GB * 1024))
mkdir -p dist

### 1. preseed
sed \
    -e "s|@VG@|$VG|g" \
    -e "s|@LONGHORN_LV_SIZE@|$LV_SIZE|g" \
    -e "s|@DISK@|$DISK|g" \
    -e "s|@ROOT_MAX_MB@|$ROOT_MAX_MB|g" \
    -e "s|@TIMEZONE@|$TIMEZONE|g" \
    -e "s|@KEYMAP@|$KEYMAP|g" \
    -e "s|@DOMAIN@|$DOMAIN|g" \
    -e "s|@MIRROR@|$MIRROR|g" \
    -e "s|@USER@|$ADMIN_USER|g" \
    -e "s|@PASSWORD_CRYPTED@|${INSTALLER_PASSWORD_CRYPTED:-*}|g" \
    -e "s|@SSH_KEY@|$(cat "$KEY")|g" \
    installer/preseed.cfg.in > dist/preseed.cfg

! grep -q '@[A-Z_]*@' dist/preseed.cfg || die "unsubstituted placeholder in dist/preseed.cfg"

### 2. boot menu, one entry per inventory host
KERNEL=/install.amd/vmlinuz
INITRD=/install.amd/initrd.gz

emit_menu() {
    local kernel=$1 initrd=$2 grub=$3 syslinux=$4 first=""
    : > "$grub"
    : > "$syslinux"
    for group in $(get '.all.children | keys | .[]' "$HOSTS"); do
        for host in $(get ".all.children.$group.hosts | keys | .[]" "$HOSTS"); do
            local title="Install Kubernetes node: $host ($group)"
            local params="auto=true priority=critical preseed/file=/cdrom/preseed.cfg"
            params="$params hostname=$host netcfg/hostname=$host netcfg/get_hostname=$host"
            [ -n "$first" ] || first=$title
            cat >> "$grub" <<ENTRY
menuentry '$title' {
    set gfxpayload=keep
    linux  $kernel $params ---
    initrd $initrd
}
ENTRY
            cat >> "$syslinux" <<ENTRY
label k8s-$host
	menu label ^$title
	kernel $kernel
	append initrd=$initrd $params ---
ENTRY
        done
    done
    [ -n "$first" ] || die "no hosts found in $HOSTS"
    # -1 waits forever: an unattended installer that auto-starts on timeout will
    # eventually wipe a disk nobody meant to touch.
    printf "\nset default='%s'\nset timeout=-1\n" "$first" >> "$grub"
}
emit_menu "$KERNEL" "$INITRD" dist/k8s-menu.cfg dist/k8s-menu.syslinux.cfg

if $DRY_RUN; then
    echo "build-iso: dry run — wrote dist/preseed.cfg, dist/k8s-menu.cfg, dist/k8s-menu.syslinux.cfg"
    exit 0
fi

command -v xorriso >/dev/null || die "xorriso is required (brew install xorriso)"

### 3. base image — whatever Debian currently ships as stable
echo "build-iso: resolving current Debian stable netinst"
SUMS=$(curl -fsSL "$CD_BASE/SHA256SUMS")
LINE=$(echo "$SUMS" | grep -E '^[0-9a-f]{64}  debian-[0-9.]+-amd64-netinst\.iso$' | head -1) \
    || die "could not find a netinst image at $CD_BASE"
ISO_SUM=${LINE%% *}
ISO_NAME=${LINE##* }
ISO=dist/$ISO_NAME

if [ ! -f "$ISO" ]; then
    echo "build-iso: downloading $ISO_NAME"
    curl -fL --progress-bar -o "$ISO.part" "$CD_BASE/$ISO_NAME"
    mv "$ISO.part" "$ISO"
fi
echo "$ISO_SUM  $ISO" | shasum -a 256 -c - >/dev/null \
    || die "checksum mismatch on $ISO — delete it and retry"

### 4. the repo itself
UNTRACKED=$(git ls-files --others --exclude-standard)
[ -z "$UNTRACKED" ] || echo "build-iso: note — untracked files are NOT in the image:
$UNTRACKED" >&2
git ls-files -z | tar -czf dist/k8s-ansible.tar.gz --null -T -

### 5. splice the menu into the ISO's own boot config
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
xorriso -osirrox on -indev "$ISO" -extract /boot/grub/grub.cfg "$WORK/grub.orig" >/dev/null 2>&1 \
    || die "no /boot/grub/grub.cfg in $ISO_NAME — the image layout changed, check it by hand"

# Take the kernel path from the image rather than assuming it: Debian has moved
# it before, and a wrong path is a boot menu entry that silently does nothing.
FOUND=$(grep -hoE '/install[a-z.]*/[a-z0-9./_-]*vmlinuz' "$WORK/grub.orig" | head -1 || true)
if [ -n "$FOUND" ]; then
    KERNEL=$FOUND
    INITRD="${FOUND%/*}/initrd.gz"
fi
echo "build-iso: kernel $KERNEL, initrd $INITRD"
emit_menu "$KERNEL" "$INITRD" dist/k8s-menu.cfg dist/k8s-menu.syslinux.cfg
cat "$WORK/grub.orig" dist/k8s-menu.cfg > "$WORK/grub.cfg"

MAPS=(-map dist/preseed.cfg /preseed.cfg
      -map dist/k8s-ansible.tar.gz /k8s-ansible.tar.gz
      -map "$WORK/grub.cfg" /boot/grub/grub.cfg)

# BIOS boot on Debian images still goes through isolinux; patch it too when the
# image has one, so the menu is there in legacy mode as well as UEFI.
if xorriso -osirrox on -indev "$ISO" -extract /isolinux/txt.cfg "$WORK/txt.orig" >/dev/null 2>&1; then
    cat dist/k8s-menu.syslinux.cfg "$WORK/txt.orig" > "$WORK/txt.cfg"
    MAPS+=(-map "$WORK/txt.cfg" /isolinux/txt.cfg)
else
    echo "build-iso: no isolinux on this image — UEFI boot only" >&2
fi

echo "build-iso: writing $OUT"
# xorriso refuses an -outdev that already holds data, so a rebuild over a
# previous image fails unless the old one is gone first.
mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"
xorriso -indev "$ISO" -outdev "$OUT" \
    -boot_image any replay \
    -compliance no_emul_toc \
    -overwrite on \
    "${MAPS[@]}" >/dev/null

xorriso -indev "$OUT" -report_el_torito plain 2>&1 | grep -E '^El Torito (boot img|catalog)' || true
echo
echo "build-iso: $OUT ready ($(du -h "$OUT" | cut -f1))"
echo "  write it:  sudo dd if=$OUT of=/dev/rdiskN bs=4m status=progress   # diskutil list first"
