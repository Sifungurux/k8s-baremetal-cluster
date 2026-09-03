# USB installer image

`make iso` builds one bootable image that installs Debian on a rack node and
leaves it prepared for `kubeadm` — no SSH, no controller, no manual steps
between racking the machine and `make bootstrap`.

It is the stock Debian **stable** netinst image (currently Debian 13, *trixie*)
with three additions:

| Added to the ISO | Does what |
|---|---|
| `/preseed.cfg` | Unattended install: LVM without swap, admin user, your SSH key, no root password. |
| `/k8s-ansible.tar.gz` | This repo, unpacked to `/opt/k8s-baremetal-cluster` on the node. |
| One boot menu entry per inventory host | Picking `cp2` at the boot menu is what makes the node `cp2`. One image installs the whole rack. |

After the install reboots, a oneshot unit (`k8s-node-prep.service`) runs
`playbooks/prep.yml` locally against this node — the same `os_prep` and
`storage_prep` roles the controller would have run over SSH.

---

## 1. Prerequisites

```bash
brew install xorriso yq          # macOS; Debian: apt install xorriso yq
```

You also need an SSH public key. It is the **only** way into the finished node:
the image locks the root account and sets no user password.

## 2. Fill in the inventory

The builder refuses to run while `inventory/group_vars/all.yml` still holds a
`CHANGEME` — a placeholder here only shows up as a failed install at the rack.

Installer-specific values, all in `all.yml`:

| Variable | Notes |
|---|---|
| `installer_disk` | The install target, e.g. `/dev/nvme0n1`. **This disk is wiped.** Pick an unambiguous device — on a machine where the internal disk is `/dev/sda`, the USB stick may claim that name instead. |
| `installer_root_size_gb` | Size of the root LV. Everything past it stays free in the VG. |
| `installer_timezone`, `installer_keymap`, `installer_domain` | Locale and DNS domain. `installer_domain` may be empty. |

`inventory/hosts.yml` supplies two more: the host names become boot menu
entries, and `all.vars.ansible_user` is the account the image creates.

> **The root LV cap is load-bearing.** `storage_prep` carves
> `longhorn_lv_size` out of *free extents* in the volume group, and `preflight`
> fails if there are none. A stock Debian LVM recipe gives the whole disk to
> root and would break both. Keep
> `installer_root_size_gb + longhorn_lv_size` comfortably under the disk size.

`containerd_version` is pinned to `1.7.24`, the version Debian 13 ships. If you
rebuild against a different Debian release, re-check it with
`apt-cache madison containerd` — `os_prep` installs that exact version and
fails hard when it is absent.

## 3. Build

```bash
make iso-check     # renders preseed + boot menu, checks them against the inventory
make iso           # downloads Debian stable, verifies its checksum, repacks
```

Both write into `dist/` (gitignored). The netinst image is cached there, so
rebuilds after an inventory change are fast.

`make iso` embeds the repo as `git ls-files` sees it — tracked files with your
current edits, but **not** untracked ones. It warns about what it left out.

Options:

```bash
installer/build-iso.sh --key ~/.ssh/rack.pub --out /tmp/rack.iso
INSTALLER_PASSWORD_CRYPTED="$(openssl passwd -6)" installer/build-iso.sh
```

`INSTALLER_PASSWORD_CRYPTED` sets a console password for the admin user. Without
it there is no password login at all, and recovering a node whose SSH key you
lost means booting the installer in rescue mode.

## 4. Write the USB stick

macOS:

```bash
diskutil list                       # find the stick — get this wrong and you lose a disk
diskutil unmountDisk /dev/disk4
sudo dd if=dist/k8s-node-installer.iso of=/dev/rdisk4 bs=4m status=progress
```

Linux: `sudo dd if=dist/k8s-node-installer.iso of=/dev/sdX bs=4M status=progress conv=fsync`.

The image is a hybrid ISO — no `unetbootin`, no Etcher, no reformatting.

## 5. Install a node

1. Boot the node from the stick. UEFI and legacy BIOS both land on a menu.
2. Pick the entry for the node you are standing in front of —
   `Install Kubernetes node: cp2 (control_plane)`.
3. Walk away. The menu never times out into an install, so a stick left in a
   machine cannot wipe it.
4. The node reboots, then spends a few minutes running `prep.yml`. Progress is
   on the console as well as in the journal.

Check it afterwards:

```bash
systemctl status k8s-node-prep      # active (exited) on success
journalctl -u k8s-node-prep
vgs                                 # VFree must be >= longhorn_lv_size
```

The unit only writes `/var/lib/k8s-node-prep.done` after the playbook succeeds
*and* containerd is running, so a node that lost the network mid-install retries
on the next boot instead of quietly staying unprepared. To force a re-run:

```bash
sudo rm -f /var/lib/k8s-node-prep.done && sudo systemctl start k8s-node-prep
```

Repeat for every node, then continue from
[Part 3 of the deployment guide](deployment.md#part-3--prove-the-nodes-are-reachable)
— the nodes are already prepped, so `make prep` from the controller is a no-op
idempotency check rather than the first real run.

---

## What it deliberately does not do

- **No offline install.** The node needs a network to reach the Debian mirror,
  `pkgs.k8s.io`, and Ansible Galaxy. DHCP is assumed.
- **No PXE.** One USB stick, walked around the rack.
- **No per-node network config.** Addresses come from DHCP; give the nodes
  static reservations and put the same addresses in `hosts.yml`.
- **No bootstrap.** The image stops at *prepared for `kubeadm`*, which is where
  this repo currently stops.
