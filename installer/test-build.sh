#!/usr/bin/env bash
# Checks the half of build-iso.sh that can be checked without a Debian ISO:
# does the generated preseed and boot menu match the inventory?
set -euo pipefail
cd "$(dirname "$0")/.."

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

cat > "$WORK/all.yml" <<'YAML'
kubernetes_version: "1.35"
kubernetes_patch_version: "1.35.8"
containerd_version: "1.7.24"
longhorn_vg: "rackvg"
longhorn_lv: "longhorn"
longhorn_lv_size: "400G"
longhorn_mount: "/var/lib/longhorn"
installer_disk: "/dev/nvme0n1"
installer_root_size_gb: 60
installer_timezone: "Europe/Copenhagen"
installer_keymap: "dk"
installer_domain: "rack.example"
YAML
cat > "$WORK/hosts.yml" <<'YAML'
all:
  children:
    control_plane:
      hosts:
        cp1: { ansible_host: 10.20.0.11 }
        cp2: { ansible_host: 10.20.0.12 }
    workers:
      hosts:
        w1: { ansible_host: 10.20.0.21 }
  vars:
    ansible_user: rackadm
YAML
ssh-keygen -q -t ed25519 -N '' -C test -f "$WORK/key" </dev/null

VARS=$WORK/all.yml HOSTS=$WORK/hosts.yml installer/build-iso.sh --dry-run --key "$WORK/key.pub" >/dev/null

# 1. every inventory host gets a boot menu entry, in both bootloaders
for h in cp1 cp2 w1; do
    grep -q "menuentry 'Install Kubernetes node: $h " dist/k8s-menu.cfg || fail "no GRUB entry for $h"
    grep -q "^label k8s-$h$" dist/k8s-menu.syslinux.cfg || fail "no isolinux entry for $h"
    # the whole point of per-node entries: the hostname is preseeded from the menu
    grep -q "hostname=$h netcfg/hostname=$h netcfg/get_hostname=$h" dist/k8s-menu.cfg \
        || fail "GRUB entry for $h does not set the hostname"
done
[ "$(grep -c '^menuentry ' dist/k8s-menu.cfg)" = 3 ] || fail "wrong number of GRUB entries"

# 2. nothing auto-boots into a disk wipe on timeout
grep -q '^set timeout=-1$' dist/k8s-menu.cfg || fail "boot menu has a timeout"

# 3. preseed is fully rendered
! grep -q '@[A-Z_]*@' dist/preseed.cfg || fail "unsubstituted placeholder in preseed"
grep -q 'partman-auto-lvm/new_vg_name string rackvg' dist/preseed.cfg || fail "VG name not substituted"
# the disk travels on each menu entry, so the preseed must not name one — a
# value in the file would override whatever the entry set
! grep -qE '^d-i (partman-auto/disk|grub-installer/bootdev)' dist/preseed.cfg \
    || fail "preseed names a disk; it would override the per-node menu entries"
# the title and the kernel line are separate lines of the entry
entry_disk() { grep -A2 "node: $1 " dist/k8s-menu.cfg | grep -oE 'partman-auto/disk=[^ ]*' | head -1; }
for h in cp1 cp2; do
    [ "$(entry_disk $h)" = "partman-auto/disk=/dev/nvme0n1" ] || fail "$h did not get the all.yml disk"
done
grep -q 'passwd/username string rackadm' dist/preseed.cfg || fail "admin user not taken from inventory"
grep -q "$(cut -d' ' -f2 "$WORK/key.pub")" dist/preseed.cfg || fail "SSH key not embedded"

# 4. root LV is capped, so the VG keeps free extents for the Longhorn LV
grep -q '20480 61440 61440 ext4' dist/preseed.cfg || fail "root LV is not capped at installer_root_size_gb"
# "max" makes the last LV swallow every free extent, cap or no cap
grep -q 'guided_size string 60 GB' dist/preseed.cfg || fail "LV allocation is not capped at installer_root_size_gb"
# naming the VG on the PV but not on the LV aborts partitioning with
# "No physical volume defined in volume group" — leave both to new_vg_name
! grep -v '^#' dist/preseed.cfg | grep -q 'vg_name{' || fail "recipe names the VG on the PV side only"
! grep -qE 'method\{ swap \}' dist/preseed.cfg || fail "recipe creates swap; kubelet will not start"

# 5. an unfilled inventory must not produce an image. Only the keys the image
#    actually reads are guarded — the platform versions are none of its business.
sed -i.bak 's/rackvg/CHANGEME/' "$WORK/all.yml"
if VARS=$WORK/all.yml HOSTS=$WORK/hosts.yml installer/build-iso.sh --dry-run --key "$WORK/key.pub" >/dev/null 2>&1; then
    fail "built an image from an inventory still holding CHANGEME"
fi

# 6. no key means unreachable nodes — refuse rather than ship a locked-out image
sed -i.bak 's/CHANGEME/rackvg/' "$WORK/all.yml"
if VARS=$WORK/all.yml HOSTS=$WORK/hosts.yml installer/build-iso.sh --dry-run --key "$WORK/nope.pub" >/dev/null 2>&1; then
    fail "built an image with no SSH key"
fi

# 6a. a group may override the disk: a rack is not uniform, and the wrong
#     device here wipes the wrong drive
mkdir -p "$WORK/group_vars"
cp "$WORK/all.yml" "$WORK/group_vars/all.yml"
cat > "$WORK/group_vars/workers.yml" <<'YAML'
installer_disk: "/dev/sda"
YAML
VARS=$WORK/group_vars/all.yml HOSTS=$WORK/hosts.yml installer/build-iso.sh --dry-run --key "$WORK/key.pub" >/dev/null
[ "$(entry_disk w1)"  = "partman-auto/disk=/dev/sda" ]       || fail "worker did not take the group override"
[ "$(entry_disk cp1)" = "partman-auto/disk=/dev/nvme0n1" ]   || fail "control plane lost the all.yml disk"

# 6b. mixing auto with explicit devices must be refused, not silently resolved:
#     the auto early_command would clobber the explicit entries
cat > "$WORK/group_vars/workers.yml" <<'YAML'
installer_disk: "auto"
YAML
if VARS=$WORK/group_vars/all.yml HOSTS=$WORK/hosts.yml installer/build-iso.sh --dry-run --key "$WORK/key.pub" >/dev/null 2>&1; then
    fail "built an image mixing auto and explicit installer_disk"
fi
rm -rf "$WORK/group_vars"

# 6c. installer_disk: auto defers the choice to install time, so one image can
#     target the first internal disk without naming it
sed -i.bak 's|/dev/nvme0n1|auto|' "$WORK/all.yml"
VARS=$WORK/all.yml HOSTS=$WORK/hosts.yml installer/build-iso.sh --dry-run --key "$WORK/key.pub" >/dev/null
grep -q 'partman/early_command' dist/preseed.cfg || fail "auto disk did not emit an early_command"
grep -q 'list-devices disk' dist/preseed.cfg || fail "auto disk does not enumerate disks"
! grep -q 'partman-auto/disk string' dist/preseed.cfg || fail "auto disk still hardcodes a device"
sed -i.bak 's|installer_disk: "auto"|installer_disk: "/dev/nvme0n1"|' "$WORK/all.yml"

# 7. the platform versions belong to the unbuilt bootstrap stage — leaving one
#    as CHANGEME must not block an image the stage has nothing to do with
cat >> "$WORK/all.yml" <<'YAML'
cilium_version: "CHANGEME"
control_plane_vip: "CHANGEME"
YAML
VARS=$WORK/all.yml HOSTS=$WORK/hosts.yml installer/build-iso.sh --dry-run --key "$WORK/key.pub" >/dev/null \
    || fail "an unfilled platform version blocked the image build"

echo "PASS: preseed and boot menu match the inventory"
