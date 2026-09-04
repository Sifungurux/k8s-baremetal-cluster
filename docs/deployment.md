# Deployment guide

How to install the tooling, fill in the inventory, and run this repo against the
five-node rack.

> **Read this first — the repo is partially built.**
>
> `make deps`, `make preflight`, and `make prep` work end to end. Everything
> after that (`bootstrap`, `platform`, `kubeconfig`, `verify`, `reset`) is
> **not implemented yet** — the playbooks and Makefile targets do not exist.
> `make help` advertises them anyway. See [Part 6](#part-6--stop-here) for what
> happens if you run them.
>
> Concretely: this guide takes you from bare Debian nodes to *nodes prepared for
> `kubeadm init`*. It does not yet take you to a cluster.

---

## Part 0 — Preconditions the repo cannot check for you

### 0.1 The operating system

**A full OS must be installed and running on all five servers before the
controller can do anything.** Ansible connects over SSH to machines that
already boot.

You have two ways to get there. Build the USB installer image
([`docs/installer.md`](installer.md), `make iso`) and boot each node from it —
it installs Debian 13 and runs `prep.yml` on the node itself, so the servers
arrive at Part 3 of this guide already prepared. Or install Debian by hand and
meet the preconditions below. There is still no PXE or netboot.

| | |
|---|---|
| **Distribution** | Debian 12 (bookworm) is the tested target — it is the image all three molecule scenarios run against. Ubuntu 22.04/24.04 LTS should work; the roles are `apt`-only, so RHEL-family distributions will not. |
| **Install type** | A **server install with systemd**. The roles use the `systemd` module for containerd, kubelet, and iscsid, and preflight calls `timedatectl`. |
| **Init** | systemd. Nothing else is supported. |

Installed on the node *before* Ansible first connects:

| Package | Why |
|---|---|
| `openssh-server`, running | The only transport. |
| `python3` at exactly `/usr/bin/python3` | `hosts.yml` pins `ansible_python_interpreter` to that literal path. |
| `sudo` | **Not installed by default on a Debian netinst where you set a root password.** Without it every task fails at privilege escalation. |
| `lvm2` | Preflight runs `vgs`; `storage_prep` runs `lvol`. |
| `iputils-ping` | Preflight pings the VIP from `cp1`. |
| A time-sync daemon | Preflight requires `timedatectl show -p NTPSynchronized` to return `yes`. `systemd-timesyncd` is the default on both Debian and Ubuntu and is sufficient. |

Everything else — containerd, kubelet, kubeadm, kubectl, `open-iscsi`,
`nfs-common` — is installed by `os_prep`. Do not pre-install them.

> **containerd comes from your distribution's repo, not Docker's.** `os_prep`
> installs `containerd={{ containerd_version }}*`, so the versions you can pin
> are whatever your release actually carries. Check with
> `apt-cache madison containerd` on a real node before choosing.

**Partitioning is decided at install time and cannot be fixed afterwards
without repartitioning.** Choose LVM during the installer, and do **not** let it
allocate the whole volume group to root. Leave at least `longhorn_lv_size`
worth of free extents — `storage_prep` creates its logical volume inside that
free space and hard-fails without it.

Confirm a node is ready in one command:

```bash
ssh youruser@10.20.0.11 \
  'ls /usr/bin/python3; command -v sudo lvm ping; \
   timedatectl show -p NTPSynchronized --value; vgs'
```

### 0.2 The Ansible user

There is no special-purpose account to create. Any regular user works, subject
to four constraints the repo imposes:

**One user for all five nodes.** `ansible_user` sits under `all: vars:` in
`inventory/hosts.yml`, so it applies to every host. If your nodes have different
usernames, move `ansible_user` down to the individual host entries.

**Key-based SSH.** Nothing in the repo prompts for or supplies an SSH password.

**Passwordless sudo — this is the one that catches people.** `ansible.cfg` sets
`become = True` globally with `become_method = sudo`, and neither the Makefile
nor `ansible.cfg` passes `--ask-become-pass`. So `sudo` must not prompt:

```bash
# on each node, as root:
echo 'youruser ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/ansible
chmod 0440 /etc/sudoers.d/ansible
visudo -c
```

If you would rather keep a sudo password, run the playbooks by hand with
`ansible-playbook -K playbooks/preflight.yml` instead of `make preflight` — the
Makefile targets have no way to pass it.

> **The gitignored `vault.yml` will not load, so do not put the become password
> there.** `.gitignore` lists `inventory/group_vars/vault.yml`, which looks like
> the intended home for secrets, but Ansible names `group_vars` files after
> *groups* — a flat `vault.yml` only loads for a group called `vault`, which
> does not exist. Verified: variables placed in it are silently never read.
> Nothing in the repo needs a secret yet, so this is a trap waiting for the
> bootstrap stage rather than a current bug. When it matters, use the directory
> form — `group_vars/all/vars.yml` alongside `group_vars/all/vault.yml`.

**The login user must be able to run `ping` unprivileged.** The VIP probes are
the only node tasks that run with `become: false`, delegated to `cp1`, so they
execute as `ansible_user` rather than root.

Using `root` as `ansible_user` does work — sudo-to-root is a no-op — but a
normal account with NOPASSWD sudo is the intended shape.

### 0.3 Decisions you need before starting

Six values, none of which have safe defaults: the rack VLAN subnet and gateway;
the control-plane VIP; the MetalLB pool range; confirmation that the pod and
service CIDRs do not collide with either; the Kubernetes minor version to pin;
and the node hostnames, IPs, and SSH user.

---

## Part 1 — Controller setup

The "controller" is your laptop. Nothing here is installed on the nodes.

### 1.1 Python and ansible-core — the version trap

`requirements.yml` pins `community.general` 13.0.1, which declares
`requires_ansible: '>=2.18.0'`. `community.general` is the collection providing
`lvol`, `filesystem`, and `modprobe` — the modules `make prep` actually
executes. ansible-core 2.18 in turn requires **Python 3.11+**.

Check what you have:

```bash
ansible --version          # need core >= 2.18
python3 --version          # need >= 3.11
```

If `ansible --version` reports anything below 2.18, Ansible will still run but
will print `Collection community.general does not support Ansible version
<x.y.z>` and the LVM modules are unsupported. Fix it with a virtualenv:

```bash
python3.13 -m venv ~/.venvs/k8s-rack
source ~/.venvs/k8s-rack/bin/activate
pip install 'ansible-core>=2.18'
```

Activate that venv for every command in this guide.

### 1.2 The rest of the toolchain

`make deps` does **not** install these. Do them by hand:

| Tool | Notes |
|---|---|
| `yq` | Must be **mikefarah yq v4**. The Makefile uses `yq '.cilium_version' file`, which is v4 syntax; the Python `yq` (a jq wrapper) needs `-r` and will silently return quoted strings. `brew install yq`. |
| `helm` | Needed only from `make platform` onwards (not yet built). |
| `kubectl` | Needed only once a cluster exists. |
| `docker` | Needed only to run molecule tests. Not needed to deploy. |

### 1.3 Install the Ansible dependencies

```bash
make deps
```

This runs `ansible-galaxy install -r requirements.yml` (community.general,
ansible.posix, ansible.utils — all version-pinned) and
`pip install -r requirements.txt` (`netaddr`).

`netaddr` is a **controller-side** dependency, not a node one: preflight's CIDR
assertions run with `delegate_to: localhost`, so the filters evaluate on your
machine.

---

## Part 2 — Fill in the inventory

Every value in the inventory ships as `CHANGEME`. Nothing runs until they are
replaced.

### 2.1 `inventory/hosts.yml`

```yaml
all:
  children:
    control_plane:
      hosts:
        cp1: { ansible_host: 10.20.0.11 }
        cp2: { ansible_host: 10.20.0.12 }
        cp3: { ansible_host: 10.20.0.13 }
    workers:
      hosts:
        w1: { ansible_host: 10.20.0.21 }
        w2: { ansible_host: 10.20.0.22 }
  vars:
    ansible_user: youruser
    ansible_python_interpreter: /usr/bin/python3
```

Node roles are inventory-driven by design — moving a node between
`control_plane` and `workers` is an inventory edit, not a rewrite.

### 2.2 The nine values preflight asserts

`preflight` asserts exactly these nine are set and not `CHANGEME`. They are the
ones `os_prep` and `storage_prep` actually consume. One of them,
`containerd_version`, is pre-filled — see below.

If you are building the USB installer, [`docs/installer.md`](installer.md) adds
five more (`installer_*`), and the builder refuses to run while any `CHANGEME`
remains.

| Variable | How to choose it |
|---|---|
| `kubernetes_version` | Minor only, e.g. `"1.34"`. The spec advises one release behind newest. See the discovery command below. |
| `kubernetes_patch_version` | Full `major.minor.patch`, e.g. `"1.34.11"`. Must exist in the apt repo — `os_prep` installs `kubelet={{ kubernetes_patch_version }}-*` and fails hard if it does not. |
| `containerd_version` | Pre-filled with `1.7.24`, what Debian 13 ships and what the USB installer image installs. On any other base OS, discover it per-node: `apt-cache madison containerd`. |
| `pause_image_version` | e.g. `"3.10"`. Tracks the Kubernetes minor. Easiest to confirm *after* prep — see below. |
| `control_plane_vip` | A single free IP on the rack VLAN, outside DHCP. |
| `rack_subnet` | e.g. `"10.20.0.0/24"`. |
| `metallb_pool` | Contiguous range, e.g. `"10.20.0.200-10.20.0.250"`. Parsed by splitting on `-`, so the exact `start-end` form matters. |
| `longhorn_vg` | The VG name from the OS install. |
| `longhorn_lv_size` | e.g. `"400G"`. |

**Discovering the available Kubernetes patch versions** for a given minor,
straight from the upstream apt repo:

```bash
curl -sL "https://pkgs.k8s.io/core:/stable:/v1.34/deb/Packages" \
  | awk '/^Package: kubeadm$/{p=1;next} p&&/^Version:/{print $2;p=0}' \
  | sort -uV | tail -5
```

Swap `v1.34` for the minor you are pinning. If this prints nothing, that minor
has no published repo.

**Confirming `pause_image_version`** is easiest after `make prep`, because it
installs `kubeadm`:

```bash
ansible cp1 -m shell -a "kubeadm config images list | grep pause"
```

Correct the value and re-run `make prep` if it disagrees. Prep is idempotent, so
this is cheap.

### 2.3 The six you can leave as `CHANGEME` for now

`kube_vip_version`, `kube_vip_interface`, `cilium_version`, `metallb_version`,
`ingress_nginx_version`, `longhorn_version`.

Preflight deliberately does not assert these — only the unbuilt bootstrap and
platform stages read them. Fill them in when those stages exist.

### 2.4 The non-overlap rules preflight enforces

Four ranges, and preflight checks every pairing that matters:

- `pod_cidr` and `service_cidr` must not overlap `rack_subnet` (checked in both
  containment directions).
- `control_plane_vip` must fall **inside** `rack_subnet`.
- `control_plane_vip` must fall **outside** `metallb_pool`.
- `metallb_pool` must sit entirely inside `rack_subnet`, and outside both
  `pod_cidr` and `service_cidr`.

The kubeadm defaults (`10.244.0.0/16`, `10.96.0.0/12`) are pre-filled and are
safe as long as your rack VLAN is not inside them.

---

## Part 3 — Prove the nodes are reachable

`ansible.cfg` sets `host_key_checking = True`, so unknown host keys are a hard
failure, not a prompt. Accept them first:

```bash
ssh-keyscan -H 10.20.0.11 10.20.0.12 10.20.0.13 10.20.0.21 10.20.0.22 \
  >> ~/.ssh/known_hosts
```

Then check inventory parsing and connectivity:

```bash
ansible-inventory --list --yaml | head -30   # expect 5 hosts in 2 groups
ansible all -m ping                          # expect 5 x SUCCESS
ansible all -m command -a "sudo -n true"     # expect no password prompt
```

---

## Part 4 — `make preflight`

```bash
make preflight
```

Modifies nothing. Free to re-run as often as you like. It splits into two kinds
of check:

**On your controller** (`delegate_to: localhost`, `run_once`) — the nine
required variables are set, and all the CIDR/VIP/pool non-overlap arithmetic.

**On the nodes** (tagged `hostcheck`) — free space in the volume group, NTP
sync, and a VIP reachability probe run from `cp1`.

The VIP probe is state-aware: it first stats `/etc/kubernetes/admin.conf` on
`cp1`. Pre-bootstrap it requires the VIP to be **silent** (nothing must already
own it). Post-bootstrap it requires the VIP to **answer**. This is what makes
preflight safe to re-run against a live cluster.

Fix everything preflight reports before continuing. This is the cheapest step in
the repo and prevents the most expensive failure mode.

---

## Part 5 — `make prep`

```bash
make prep
```

`prep` depends on `preflight`, so preflight runs again first automatically.

**`os_prep`** does, in order: disables swap for the boot and comments swap
entries out of `/etc/fstab` (with a backup); writes
`/etc/modules-load.d/k8s.conf` and loads `overlay` + `br_netfilter`; writes
`/etc/sysctl.d/99-kubernetes.conf`; installs and pins containerd, writes
`/etc/containerd/config.toml` with `SystemdCgroup = true` and the pinned pause
image, restarts it and verifies it is active; adds the Kubernetes apt repo and
signing key; installs and holds `kubelet`/`kubeadm`/`kubectl` at the pinned
patch version; writes kubelet `system-reserved`/`kube-reserved` limits **on
control planes only**; installs `open-iscsi` and `nfs-common` and enables
`iscsid`.

**`storage_prep`** creates the `longhorn` LV in your VG, makes an ext4
filesystem, and mounts it at `/var/lib/longhorn` with an fstab entry. The LV is
created with `shrink: false` — reducing `longhorn_lv_size` later is refused
rather than silently truncating a live filesystem. Increasing it grows the ext4
to match.

### Verify on metal

Molecule cannot prove any of this (see [Part 7](#part-7--running-the-tests)), so
check the real hosts:

```bash
ansible all -m shell -a "swapon --show"                    # expect empty output
ansible all -a "systemctl is-active containerd"            # expect: active
ansible all -m shell -a "containerd config dump | grep SystemdCgroup"
ansible all -a "kubeadm version -o short"                  # expect your pinned patch
ansible all -m shell -a "lsmod | grep -E 'overlay|br_netfilter'"
ansible all -a "sysctl net.ipv4.ip_forward net.bridge.bridge-nf-call-iptables"
ansible all -a "findmnt /var/lib/longhorn"                 # expect the LV mounted
ansible control_plane -a "cat /etc/default/kubelet"        # expect the reservations
```

**`kubelet` will not be running, and that is correct.** It has no config until
`kubeadm init` gives it one. Do not try to "fix" it.

---

## Part 6 — Stop here

This is as far as the repo goes today.

```bash
make bootstrap    # FAILS: playbooks/bootstrap.yml does not exist
make platform     # FAILS: no such Makefile target
make kubeconfig   # FAILS: no such Makefile target
make verify       # FAILS: no such Makefile target
make reset        # FAILS: no such Makefile target
```

`make help` lists all five. The `bootstrap` target exists in the Makefile and
invokes a playbook that was never written; the other four have no target at all.

Still to be built, in order (Tasks 7–15 of the implementation plan):

| Missing | What it will do |
|---|---|
| `roles/kube_vip` | kube-vip static pod manifest — the VIP must answer *before* `kubeadm init` uses it as `--control-plane-endpoint`. |
| `roles/control_plane` | `kubeadm init` on `cp1`, then join `cp2`/`cp3` one at a time (`serial: 1`, or concurrent etcd joins can lose quorum). |
| `roles/worker` | Join `w1`/`w2`, then untaint the control planes. |
| `platform/` + Makefile targets | Cilium → MetalLB → ingress-nginx → Longhorn, as Helm releases. Order matters: untaint before Longhorn, MetalLB before ingress. |
| `scripts/verify.sh` | Four-check smoke test, including a PVC that must survive rescheduling onto another node. |
| `playbooks/reset.yml` | Guarded teardown (`-e confirm_reset=yes`). |
| `docs/runbook-day2.md` | etcd snapshots, cert renewal, node loss, upgrades. |

The full step-by-step for these lives in
[`docs/superpowers/plans/2026-08-31-baremetal-kubeadm-cluster.md`](superpowers/plans/2026-08-31-baremetal-kubeadm-cluster.md).

---

## Part 7 — Running the tests

Molecule needs Docker running, plus the test tooling in your venv:

```bash
pip install molecule molecule-plugins[docker] ansible-lint
```

These are not in `requirements.txt` — that file carries only the runtime
controller dependency.

```bash
cd roles/preflight  && molecule test                    # valid input passes
cd roles/preflight  && molecule test -s negative        # bad input is rejected
cd roles/os_prep    && molecule test
cd roles/storage_prep && molecule test
```

### What molecule can and cannot prove

The docker driver shares the host kernel and has no LVM, so anything touching
the kernel or disks is tagged and skipped:

- **`hostonly`** — skipped in `os_prep` and `storage_prep` runs. Covers
  `swapoff`, `modprobe`, package installation, service restarts, `iscsid`, and
  all the LVM/mount work.
- **`hostcheck`** — skipped in `preflight` runs. Covers the VIP ping, `vgs`, and
  the NTP check.

So molecule proves *what was rendered and installed*, never that swap is off or
that the LV mounted. Real verification is the on-metal commands in Part 5.

One consequence worth knowing if you edit `os_prep`: containerd and kubelet
restarts are plain `hostonly` tasks rather than handlers, because
`--skip-tags` does not suppress an already-notified handler.

---

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `Collection community.general does not support Ansible version 2.15.13` | ansible-core too old. Needs ≥ 2.18, which needs Python ≥ 3.11. See Part 1.1. |
| Makefile version variables come out empty or quoted | Wrong `yq`. Needs mikefarah v4, not the Python jq wrapper. |
| `Host key verification failed` | `host_key_checking = True` in `ansible.cfg`. Run the `ssh-keyscan` in Part 3. |
| `Fill in inventory/group_vars/all.yml before running anything` | One of the nine required values is still `CHANGEME`. Part 2.2. |
| `pod_cidr/service_cidr overlap rack_subnet` | Your VLAN sits inside the kubeadm defaults. Move the VLAN or change the CIDRs. |
| `control_plane_vip and metallb_pool collide` | The VIP falls inside the pool range. Move one. |
| VIP check fails pre-bootstrap | Something already answers on that address — it is not free. Pick another, or find what owns it. |
| `No free space in VG <name>` | The VG is fully allocated, or `longhorn_vg` names the wrong group. Check `vgs` on the node. |
| `NTPSynchronized` not `yes` | `timedatectl set-ntp true` on the node, then wait for sync. |
| `E: Version '1.34.11-*' for 'kubelet' was not found` | That patch is not in the repo for that minor. Use the discovery command in Part 2.2. |
| `lvol`: volume group not found | `longhorn_vg` is wrong, or the VG was never created at OS-install time. |
| `make bootstrap` → `ERROR! the playbook ... could not be found` | Expected. Not implemented. Part 6. |
| `make platform` → `No rule to make target` | Expected. Not implemented. Part 6. |
