# Bare-metal kubeadm cluster Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn five bare Debian/Ubuntu servers into a highly-available kubeadm cluster with CNI, LoadBalancer, ingress, and a default StorageClass, so that `k8s-infra`'s `make deploy` runs against it unchanged.

**Architecture:** Ansible does everything that requires SSH and root on the hosts — OS prep, LVM, `kubeadm`. Everything expressible as a Helm release lives in `platform/` and is applied by the Makefile, so migrating add-ons to Flux later is a file move rather than a rewrite. Three control planes with stacked etcd behind a `kube-vip` ARP VIP; all five nodes schedulable so Longhorn can place three replicas.

**Tech Stack:** Ansible, molecule (docker driver), kubeadm, containerd, kube-vip, Cilium, MetalLB, ingress-nginx, Longhorn, Helm, Make.

**Spec:** `docs/superpowers/specs/2026-08-31-baremetal-kubeadm-cluster-design.md`

## Global Constraints

- **OS:** Debian/Ubuntu LTS on all five nodes. `apt`-based logic only.
- **Version pinning:** Kubernetes, containerd, Cilium, MetalLB, ingress-nginx, and Longhorn versions are pinned in `inventory/group_vars/all.yml`. No `latest`, no floating tags.
- **Node layout:** `cp1` (16GB), `cp2` (16GB), `cp3` (32GB) are control-plane; `w1` (32GB), `w2` (32GB) are workers. All five schedulable in v1.
- **Idempotence:** Every playbook is re-runnable. Re-running against a healthy cluster is a no-op, never a failure.
- **No automated upgrades in v1.** Upgrades are a documented manual procedure only.
- **Add-ons stay Helm releases** in `platform/`, never Ansible `kubernetes.core` resource loops.
- **Never commit secrets.** `inventory/group_vars/vault.yml` is gitignored; use `ansible-vault` for anything sensitive.

## Blocking preconditions

Task 1 cannot be completed without these six values. Do not start Task 2 until Task 1 is committed with real values:

1. Rack VLAN subnet and gateway
2. Control-plane VIP address (must be outside DHCP)
3. MetalLB pool range (contiguous, outside DHCP)
4. Confirmation that pod/service CIDRs do not collide with the VLAN
5. Kubernetes minor version to pin
6. Node hostnames, IPs, and SSH user

## File Structure

| File | Responsibility |
|---|---|
| `Makefile` | Front door. One target per phase; contains no logic beyond invoking playbooks and helm. |
| `ansible.cfg` | Inventory path, SSH settings, `become` defaults. |
| `inventory/hosts.yml` | The five nodes and their groups. The only file naming real hardware. |
| `inventory/group_vars/all.yml` | All pinned versions, CIDRs, VIP, pool. Single source of truth for values. |
| `playbooks/preflight.yml` | Validation only. Modifies nothing. |
| `playbooks/prep.yml` | `os_prep` + `storage_prep` across all nodes. |
| `playbooks/bootstrap.yml` | `kube_vip` → `control_plane` → `worker`. |
| `playbooks/reset.yml` | `kubeadm reset` teardown. |
| `roles/preflight/` | Fail-fast assertions on inventory and network. |
| `roles/os_prep/` | swap, modules, sysctls, containerd, kube packages, kubelet reservations, Longhorn prereqs. |
| `roles/storage_prep/` | LV, filesystem, mount at `/var/lib/longhorn`. |
| `roles/kube_vip/` | Static pod manifest on control planes. |
| `roles/control_plane/` | `kubeadm init` on `cp1`, join `cp2`/`cp3`, untaint. |
| `roles/worker/` | Join `w1`/`w2`. |
| `platform/*/values.yaml` | Helm values, one directory per add-on. |
| `scripts/verify.sh` | Cluster smoke test. |
| `docs/runbook-day2.md` | Snapshots, cert renewal, node loss, upgrades. |

**Testing note that applies to every role task below:** molecule uses the docker driver, which cannot exercise `swapoff`, kernel module loading, sysctl writes, or LVM. Those steps are therefore guarded so they no-op in a container, and molecule asserts on *what was rendered and installed* rather than on kernel state. The real verification is Task 14's smoke test against the cluster. Each task states explicitly which of its behaviours molecule can and cannot prove.

---

### Task 1: Repo skeleton, inventory, and pinned versions

**Files:**
- Create: `ansible.cfg`, `Makefile`, `inventory/hosts.yml`, `inventory/group_vars/all.yml`, `requirements.yml`
- Modify: `.gitignore`

**Interfaces:**
- Consumes: nothing.
- Produces: the variable names every later task reads — `kubernetes_version`, `containerd_version`, `cilium_version`, `metallb_version`, `ingress_nginx_version`, `longhorn_version`, `control_plane_endpoint`, `pod_cidr`, `service_cidr`, `metallb_pool`, `longhorn_vg`, `longhorn_lv`, `longhorn_lv_size`, `longhorn_mount`. Groups `control_plane` and `workers`.

- [ ] **Step 1: Write `inventory/hosts.yml` with the real five nodes**

Replace every `CHANGEME` with real values from the blocking preconditions.

```yaml
all:
  children:
    control_plane:
      hosts:
        cp1: { ansible_host: CHANGEME }
        cp2: { ansible_host: CHANGEME }
        cp3: { ansible_host: CHANGEME }
    workers:
      hosts:
        w1: { ansible_host: CHANGEME }
        w2: { ansible_host: CHANGEME }
  vars:
    ansible_user: CHANGEME
    ansible_python_interpreter: /usr/bin/python3
```

- [ ] **Step 2: Write `inventory/group_vars/all.yml`**

```yaml
---
# Pinned versions — no floating tags. Bump deliberately.
kubernetes_version: "CHANGEME"        # minor only, e.g. "1.33" — selects the apt repo
kubernetes_patch_version: "CHANGEME"  # full version for kubeadm, e.g. "1.33.4"
containerd_version: "CHANGEME"
kube_vip_version: "CHANGEME"          # e.g. v0.8.x
kube_vip_interface: "CHANGEME"        # rack VLAN interface, e.g. eno1
cilium_version: "CHANGEME"
metallb_version: "CHANGEME"
ingress_nginx_version: "CHANGEME"
longhorn_version: "CHANGEME"

# Network — all four must not overlap
control_plane_vip: "CHANGEME"          # single free IP on the rack VLAN
control_plane_endpoint: "{{ control_plane_vip }}:6443"
rack_subnet: "CHANGEME"                # e.g. 10.20.0.0/24
pod_cidr: "10.244.0.0/16"
service_cidr: "10.96.0.0/12"
metallb_pool: "CHANGEME"               # e.g. 10.20.0.200-10.20.0.250

# Storage
longhorn_vg: "CHANGEME"                # volume group name from the OS install
longhorn_lv: "longhorn"
longhorn_lv_size: "CHANGEME"           # e.g. 400G
longhorn_mount: "/var/lib/longhorn"

# v1 posture: control planes carry workloads because Longhorn needs 3 schedulable nodes.
# Flip to false once a 6th node exists.
untaint_control_planes: true
```

- [ ] **Step 3: Write `ansible.cfg`**

```ini
[defaults]
inventory = inventory/hosts.yml
host_key_checking = True
stdout_callback = yaml
roles_path = roles

[privilege_escalation]
become = True
become_method = sudo
```

- [ ] **Step 4: Write `requirements.yml`**

```yaml
---
collections:
  - name: community.general
  - name: ansible.posix
  - name: kubernetes.core
```

- [ ] **Step 5: Write the `Makefile`**

```make
.DEFAULT_GOAL := help
ANSIBLE := ansible-playbook
VARS := inventory/group_vars/all.yml

# Single source of truth: every version is read from group_vars, never duplicated here.
CILIUM_VERSION        := $(shell yq '.cilium_version' $(VARS))
METALLB_VERSION       := $(shell yq '.metallb_version' $(VARS))
INGRESS_NGINX_VERSION := $(shell yq '.ingress_nginx_version' $(VARS))
LONGHORN_VERSION      := $(shell yq '.longhorn_version' $(VARS))
METALLB_POOL          := $(shell yq '.metallb_pool' $(VARS))

.PHONY: help
help:
	@echo ""
	@echo "  k8s-baremetal-cluster"
	@echo ""
	@echo "    make deps        Install Ansible collections"
	@echo "    make preflight   Validate inventory and network (changes nothing)"
	@echo "    make prep        OS + storage prep on all nodes"
	@echo "    make bootstrap   kubeadm init, joins, CNI"
	@echo "    make platform    MetalLB, ingress-nginx, Longhorn"
	@echo "    make kubeconfig  Fetch admin.conf as context 'rack'"
	@echo "    make verify      Cluster smoke test"
	@echo "    make reset       DESTRUCTIVE: kubeadm reset all nodes"
	@echo ""

.PHONY: deps
deps:
	ansible-galaxy install -r requirements.yml

.PHONY: preflight
preflight:
	$(ANSIBLE) playbooks/preflight.yml

.PHONY: prep
prep: preflight
	$(ANSIBLE) playbooks/prep.yml

.PHONY: bootstrap
bootstrap:
	$(ANSIBLE) playbooks/bootstrap.yml
```

- [ ] **Step 6: Add vault file to `.gitignore`**

Confirm `inventory/group_vars/vault.yml` is present in `.gitignore`. It already is from the scaffold commit; verify rather than duplicate.

Run: `grep -c 'vault.yml' .gitignore`
Expected: `1`

- [ ] **Step 7: Verify Ansible parses the inventory**

Run: `ansible-inventory --list --yaml | head -30`
Expected: five hosts under `control_plane` and `workers`, no parse errors.

- [ ] **Step 8: Commit**

```bash
git add ansible.cfg Makefile inventory/ requirements.yml .gitignore
git commit -m "feat: inventory, pinned versions, and Makefile front door"
```

---

### Task 2: Preflight validation role

Catches wrong values before anything is modified. This is the cheapest task in the plan and prevents the most expensive failure mode.

**Files:**
- Create: `roles/preflight/tasks/main.yml`, `playbooks/preflight.yml`
- Test: `roles/preflight/molecule/default/{molecule.yml,converge.yml,verify.yml}`

**Interfaces:**
- Consumes: all variables from Task 1.
- Produces: nothing. Fails the run on bad input.

- [ ] **Step 1: Write the failing molecule verify**

`roles/preflight/molecule/default/verify.yml`:

```yaml
---
- name: Verify
  hosts: all
  gather_facts: false
  tasks:
    - name: CIDRs must not overlap the rack subnet
      ansible.builtin.assert:
        that:
          - pod_cidr | ansible.utils.network_in_network(rack_subnet) is false
          - service_cidr | ansible.utils.network_in_network(rack_subnet) is false
        fail_msg: "pod_cidr or service_cidr overlaps rack_subnet"
```

- [ ] **Step 2: Run molecule to verify it fails**

Run: `cd roles/preflight && molecule test`
Expected: FAIL — the role has no tasks yet, converge errors on the missing `tasks/main.yml`.

- [ ] **Step 3: Write `roles/preflight/tasks/main.yml`**

```yaml
---
- name: Required variables are defined
  ansible.builtin.assert:
    that:
      - kubernetes_version is defined and kubernetes_version != "CHANGEME"
      - control_plane_vip is defined and control_plane_vip != "CHANGEME"
      - metallb_pool is defined and metallb_pool != "CHANGEME"
      - rack_subnet is defined and rack_subnet != "CHANGEME"
      - longhorn_vg is defined and longhorn_vg != "CHANGEME"
    fail_msg: "Fill in inventory/group_vars/all.yml before running anything"
  run_once: true
  delegate_to: localhost

- name: Pod and service CIDRs do not collide with the rack subnet
  ansible.builtin.assert:
    that:
      - not (pod_cidr | ansible.utils.network_in_network(rack_subnet))
      - not (service_cidr | ansible.utils.network_in_network(rack_subnet))
    fail_msg: "pod_cidr/service_cidr overlap rack_subnet — pick non-overlapping ranges"
  run_once: true
  delegate_to: localhost

- name: Control-plane VIP must be free
  ansible.builtin.command:
    cmd: "ping -c1 -W1 {{ control_plane_vip }}"
  register: vip_ping
  failed_when: vip_ping.rc == 0
  changed_when: false
  run_once: true
  delegate_to: localhost

- name: Volume group has free space for the Longhorn LV
  ansible.builtin.command:
    cmd: "vgs --noheadings -o vg_free --units g {{ longhorn_vg }}"
  register: vg_free
  changed_when: false

- name: Fail if the volume group is full
  ansible.builtin.assert:
    that:
      - vg_free.stdout | trim | regex_replace('g$', '') | float > 0
    fail_msg: "No free space in VG {{ longhorn_vg }} on {{ inventory_hostname }}"

- name: Time is synchronised
  ansible.builtin.command:
    cmd: timedatectl show -p NTPSynchronized --value
  register: ntp_sync
  changed_when: false
  failed_when: ntp_sync.stdout | trim != "yes"
```

- [ ] **Step 4: Write `playbooks/preflight.yml`**

```yaml
---
- name: Preflight validation
  hosts: all
  gather_facts: true
  roles:
    - preflight
```

- [ ] **Step 5: Run molecule to verify it passes**

Run: `cd roles/preflight && molecule test`
Expected: PASS.

**Molecule proves:** the CIDR-overlap and required-variable assertions. **Molecule cannot prove:** the ARP/ping check for a free VIP, `vgs` output, or NTP state — those need real hosts and are exercised by `make preflight` against the rack.

- [ ] **Step 6: Commit**

```bash
git add roles/preflight playbooks/preflight.yml
git commit -m "feat: preflight validation role"
```

---

### Task 3: OS prep — swap, kernel modules, sysctls

**Files:**
- Create: `roles/os_prep/tasks/main.yml`, `roles/os_prep/handlers/main.yml`
- Test: `roles/os_prep/molecule/default/{molecule.yml,converge.yml,verify.yml}`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `/etc/modules-load.d/k8s.conf` and `/etc/sysctl.d/99-kubernetes.conf`, both read by Task 5's containerd config and required before `kubeadm init` in Task 8.

- [ ] **Step 1: Write the failing molecule verify**

`roles/os_prep/molecule/default/verify.yml`:

```yaml
---
- name: Verify
  hosts: all
  tasks:
    - name: Kernel module config exists
      ansible.builtin.stat:
        path: /etc/modules-load.d/k8s.conf
      register: modconf

    - name: Sysctl config exists
      ansible.builtin.stat:
        path: /etc/sysctl.d/99-kubernetes.conf
      register: sysctlconf

    - name: Assert both are present
      ansible.builtin.assert:
        that:
          - modconf.stat.exists
          - sysctlconf.stat.exists

    - name: Sysctl file enables forwarding and bridge filtering
      ansible.builtin.slurp:
        src: /etc/sysctl.d/99-kubernetes.conf
      register: sysctl_content

    - name: Assert required sysctls present
      ansible.builtin.assert:
        that:
          - "'net.ipv4.ip_forward = 1' in (sysctl_content.content | b64decode)"
          - "'net.bridge.bridge-nf-call-iptables = 1' in (sysctl_content.content | b64decode)"
```

- [ ] **Step 2: Run molecule to verify it fails**

Run: `cd roles/os_prep && molecule test`
Expected: FAIL — `/etc/modules-load.d/k8s.conf` does not exist.

- [ ] **Step 3: Write `roles/os_prep/tasks/main.yml`** (first section only; later tasks append)

```yaml
---
- name: Disable swap for the current boot
  ansible.builtin.command: swapoff -a
  when: ansible_swaptotal_mb | default(0) > 0
  changed_when: ansible_swaptotal_mb | default(0) > 0

- name: Remove swap entries from fstab
  ansible.posix.mount:
    path: "{{ item.mount }}"
    state: absent
  loop: "{{ ansible_mounts | selectattr('fstype', 'equalto', 'swap') | list }}"
  when: ansible_mounts is defined

- name: Load required kernel modules at boot
  ansible.builtin.copy:
    dest: /etc/modules-load.d/k8s.conf
    content: |
      overlay
      br_netfilter
    owner: root
    group: root
    mode: "0644"

- name: Load modules now
  community.general.modprobe:
    name: "{{ item }}"
    state: present
  loop:
    - overlay
    - br_netfilter
  failed_when: false          # no-ops in containers; real hosts load them

- name: Set kubernetes sysctls
  ansible.builtin.copy:
    dest: /etc/sysctl.d/99-kubernetes.conf
    content: |
      net.bridge.bridge-nf-call-iptables = 1
      net.bridge.bridge-nf-call-ip6tables = 1
      net.ipv4.ip_forward = 1
    owner: root
    group: root
    mode: "0644"
  notify: reload sysctl
```

- [ ] **Step 4: Write `roles/os_prep/handlers/main.yml`**

```yaml
---
- name: reload sysctl
  ansible.builtin.command: sysctl --system
  failed_when: false
```

- [ ] **Step 5: Run molecule to verify it passes**

Run: `cd roles/os_prep && molecule test`
Expected: PASS.

**Molecule proves:** both files are rendered with the right content. **Molecule cannot prove:** that swap is actually off or the modules actually loaded — containers share the host kernel. Verified on real hosts by `make prep` followed by `swapon --show` returning empty.

- [ ] **Step 6: Commit**

```bash
git add roles/os_prep
git commit -m "feat(os_prep): swap, kernel modules, and sysctls"
```

---

### Task 4: OS prep — containerd

**Files:**
- Modify: `roles/os_prep/tasks/main.yml` (append)
- Create: `roles/os_prep/templates/containerd-config.toml.j2`
- Test: `roles/os_prep/molecule/default/verify.yml` (append assertions)

**Interfaces:**
- Consumes: `containerd_version` from Task 1.
- Produces: a running containerd with `SystemdCgroup = true`, which `kubeadm init` in Task 8 requires. A mismatch here is the single most common kubeadm bring-up failure.

- [ ] **Step 1: Append the failing assertion to `verify.yml`**

```yaml
    - name: containerd config exists with systemd cgroup driver
      ansible.builtin.slurp:
        src: /etc/containerd/config.toml
      register: containerd_conf

    - name: Assert SystemdCgroup is enabled
      ansible.builtin.assert:
        that:
          - "'SystemdCgroup = true' in (containerd_conf.content | b64decode)"
        fail_msg: "containerd must use the systemd cgroup driver or kubelet will not start"
```

- [ ] **Step 2: Run molecule to verify it fails**

Run: `cd roles/os_prep && molecule test`
Expected: FAIL — `/etc/containerd/config.toml` does not exist.

- [ ] **Step 3: Append to `roles/os_prep/tasks/main.yml`**

```yaml
- name: Install containerd
  ansible.builtin.apt:
    name: "containerd={{ containerd_version }}*"
    state: present
    update_cache: true
    cache_valid_time: 3600

- name: Hold containerd at the pinned version
  ansible.builtin.dpkg_selections:
    name: containerd
    selection: hold

- name: Ensure containerd config directory exists
  ansible.builtin.file:
    path: /etc/containerd
    state: directory
    owner: root
    group: root
    mode: "0755"

- name: Write containerd config with the systemd cgroup driver
  ansible.builtin.template:
    src: containerd-config.toml.j2
    dest: /etc/containerd/config.toml
    owner: root
    group: root
    mode: "0644"
  notify: restart containerd
```

- [ ] **Step 4: Write `roles/os_prep/templates/containerd-config.toml.j2`**

```toml
version = 2

[plugins."io.containerd.grpc.v1.cri"]
  sandbox_image = "registry.k8s.io/pause:3.10"

[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc]
  runtime_type = "io.containerd.runc.v2"

[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
  SystemdCgroup = true
```

- [ ] **Step 5: Append the handler to `roles/os_prep/handlers/main.yml`**

```yaml
- name: restart containerd
  ansible.builtin.systemd:
    name: containerd
    state: restarted
    enabled: true
    daemon_reload: true
  failed_when: false
```

- [ ] **Step 6: Run molecule to verify it passes**

Run: `cd roles/os_prep && molecule test`
Expected: PASS.

**Molecule proves:** the config renders with `SystemdCgroup = true` and the package installs. **Molecule cannot prove:** containerd actually running under systemd. Verified on real hosts by `systemctl is-active containerd`.

- [ ] **Step 7: Commit**

```bash
git add roles/os_prep
git commit -m "feat(os_prep): containerd with systemd cgroup driver"
```

---

### Task 5: OS prep — Kubernetes packages, kubelet reservations, Longhorn prerequisites

**Files:**
- Modify: `roles/os_prep/tasks/main.yml` (append)
- Test: `roles/os_prep/molecule/default/verify.yml` (append)

**Interfaces:**
- Consumes: `kubernetes_version` from Task 1.
- Produces: `kubeadm`, `kubelet`, `kubectl` installed and held; `/etc/default/kubelet` carrying reservations. Tasks 8 and 9 invoke `kubeadm` directly.

Longhorn's `open-iscsi` and `nfs-common` are installed here, not at Longhorn install time — otherwise Task 13 needs another SSH pass across all five nodes after the cluster is already running.

On the priority class the spec calls for: kubeadm already assigns `system-node-critical` to the control-plane static pods it creates, so no extra work is needed there. The kubelet reservations below are the actionable half of protecting etcd on the 16GB control planes.

- [ ] **Step 1: Append the failing assertions to `verify.yml`**

```yaml
    - name: kubeadm is installed
      ansible.builtin.command: kubeadm version -o short
      register: kubeadm_ver
      changed_when: false

    - name: Assert kubeadm matches the pinned minor version
      ansible.builtin.assert:
        that:
          - kubernetes_version in kubeadm_ver.stdout

    - name: Longhorn prerequisites are present
      ansible.builtin.command: dpkg -s open-iscsi nfs-common
      register: longhorn_prereqs
      changed_when: false
```

- [ ] **Step 2: Run molecule to verify it fails**

Run: `cd roles/os_prep && molecule test`
Expected: FAIL — `kubeadm: command not found`.

- [ ] **Step 3: Append to `roles/os_prep/tasks/main.yml`**

```yaml
- name: Install apt prerequisites
  ansible.builtin.apt:
    name:
      - apt-transport-https
      - ca-certificates
      - curl
      - gpg
    state: present
    update_cache: true

- name: Add the Kubernetes apt signing key
  ansible.builtin.get_url:
    url: "https://pkgs.k8s.io/core:/stable:/v{{ kubernetes_version }}/deb/Release.key"
    dest: /etc/apt/keyrings/kubernetes-apt-keyring.asc
    owner: root
    group: root
    mode: "0644"

- name: Add the Kubernetes apt repository
  ansible.builtin.apt_repository:
    repo: >-
      deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.asc]
      https://pkgs.k8s.io/core:/stable:/v{{ kubernetes_version }}/deb/ /
    filename: kubernetes
    state: present

- name: Install kubelet, kubeadm, and kubectl
  ansible.builtin.apt:
    name:
      - kubelet
      - kubeadm
      - kubectl
    state: present
    update_cache: true

- name: Hold the kube packages so unattended upgrades cannot move them
  ansible.builtin.dpkg_selections:
    name: "{{ item }}"
    selection: hold
  loop:
    - kubelet
    - kubeadm
    - kubectl

- name: Reserve resources for the system and kubelet on control planes
  ansible.builtin.copy:
    dest: /etc/default/kubelet
    content: |
      KUBELET_EXTRA_ARGS=--system-reserved=cpu=500m,memory=1Gi --kube-reserved=cpu=500m,memory=1Gi --eviction-hard=memory.available<500Mi
    owner: root
    group: root
    mode: "0644"
  when: inventory_hostname in groups['control_plane']
  notify: restart kubelet

- name: Install Longhorn node prerequisites
  ansible.builtin.apt:
    name:
      - open-iscsi
      - nfs-common
    state: present

- name: Enable iscsid
  ansible.builtin.systemd:
    name: iscsid
    enabled: true
    state: started
  failed_when: false
```

- [ ] **Step 4: Append the handler to `roles/os_prep/handlers/main.yml`**

```yaml
- name: restart kubelet
  ansible.builtin.systemd:
    name: kubelet
    state: restarted
    daemon_reload: true
  failed_when: false
```

- [ ] **Step 5: Run molecule to verify it passes**

Run: `cd roles/os_prep && molecule test`
Expected: PASS.

**Molecule proves:** repository setup, package installation, version match, and that reservations render on control-plane hosts. **Molecule cannot prove:** kubelet running — it will not start until `kubeadm init` gives it a config, which is expected and correct.

- [ ] **Step 6: Commit**

```bash
git add roles/os_prep
git commit -m "feat(os_prep): kube packages, kubelet reservations, Longhorn prereqs"
```

---

### Task 6: Storage prep — Longhorn logical volume

**Files:**
- Create: `roles/storage_prep/tasks/main.yml`, `playbooks/prep.yml`
- Test: `roles/storage_prep/molecule/default/{molecule.yml,converge.yml,verify.yml}`

**Interfaces:**
- Consumes: `longhorn_vg`, `longhorn_lv`, `longhorn_lv_size`, `longhorn_mount` from Task 1.
- Produces: an ext4 filesystem mounted at `/var/lib/longhorn`, which Task 13's Longhorn install uses as its data path.

- [ ] **Step 1: Write the failing molecule verify**

`roles/storage_prep/molecule/default/verify.yml`:

```yaml
---
- name: Verify
  hosts: all
  tasks:
    - name: Longhorn mount point exists
      ansible.builtin.stat:
        path: /var/lib/longhorn
      register: lh_dir

    - name: Assert the directory is present
      ansible.builtin.assert:
        that:
          - lh_dir.stat.exists
          - lh_dir.stat.isdir
```

- [ ] **Step 2: Run molecule to verify it fails**

Run: `cd roles/storage_prep && molecule test`
Expected: FAIL — `/var/lib/longhorn` does not exist.

- [ ] **Step 3: Write `roles/storage_prep/tasks/main.yml`**

```yaml
---
- name: Create the Longhorn logical volume
  community.general.lvol:
    vg: "{{ longhorn_vg }}"
    lv: "{{ longhorn_lv }}"
    size: "{{ longhorn_lv_size }}"
    state: present
  when: ansible_virtualization_type | default('') != 'container'

- name: Create an ext4 filesystem on it
  community.general.filesystem:
    fstype: ext4
    dev: "/dev/{{ longhorn_vg }}/{{ longhorn_lv }}"
  when: ansible_virtualization_type | default('') != 'container'

- name: Ensure the mount point exists
  ansible.builtin.file:
    path: "{{ longhorn_mount }}"
    state: directory
    owner: root
    group: root
    mode: "0755"

- name: Mount the Longhorn volume and persist it in fstab
  ansible.posix.mount:
    path: "{{ longhorn_mount }}"
    src: "/dev/{{ longhorn_vg }}/{{ longhorn_lv }}"
    fstype: ext4
    opts: defaults
    state: mounted
  when: ansible_virtualization_type | default('') != 'container'
```

- [ ] **Step 4: Write `playbooks/prep.yml`**

```yaml
---
- name: Prepare all nodes
  hosts: all
  gather_facts: true
  roles:
    - os_prep
    - storage_prep
```

- [ ] **Step 5: Run molecule to verify it passes**

Run: `cd roles/storage_prep && molecule test`
Expected: PASS.

**Molecule proves:** the mount point is created and the LVM steps are correctly skipped in a container. **Molecule cannot prove:** LVM or the mount. Verified on real hosts by `findmnt /var/lib/longhorn` after `make prep`.

- [ ] **Step 6: Commit**

```bash
git add roles/storage_prep playbooks/prep.yml
git commit -m "feat(storage_prep): dedicated Longhorn logical volume"
```

---

### Task 7: kube-vip static pod

The VIP must answer *before* `kubeadm init` runs, because init takes it as `--control-plane-endpoint`. This is a genuine chicken-and-egg: the manifest is written to `/etc/kubernetes/manifests/` where the kubelet will pick it up as a static pod the moment kubelet starts during init.

**Files:**
- Create: `roles/kube_vip/tasks/main.yml`, `roles/kube_vip/templates/kube-vip.yaml.j2`

**Interfaces:**
- Consumes: `control_plane_vip`, `kube_vip_version`, `kube_vip_interface` from Task 1.
- Produces: `/etc/kubernetes/manifests/kube-vip.yaml` on all three control planes. Task 8 depends on the VIP being reachable after init.

- [ ] **Step 1: Confirm the kube-vip variables exist**

`kube_vip_version` and `kube_vip_interface` are declared in `inventory/group_vars/all.yml` from Task 1, alongside every other pinned version — this role has no `defaults/main.yml`, so there is one source of truth for versions.

Run: `grep -c 'kube_vip_' inventory/group_vars/all.yml`
Expected: `2`

- [ ] **Step 2: Write `roles/kube_vip/templates/kube-vip.yaml.j2`**

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: kube-vip
  namespace: kube-system
spec:
  hostNetwork: true
  containers:
    - name: kube-vip
      image: "ghcr.io/kube-vip/kube-vip:{{ kube_vip_version }}"
      imagePullPolicy: IfNotPresent
      args: ["manager"]
      env:
        - { name: vip_arp,        value: "true" }
        - { name: port,           value: "6443" }
        - { name: vip_interface,  value: "{{ kube_vip_interface }}" }
        - { name: vip_address,    value: "{{ control_plane_vip }}" }
        - { name: cp_enable,      value: "true" }
        - { name: cp_namespace,   value: "kube-system" }
        - { name: vip_leaderelection, value: "true" }
      securityContext:
        capabilities:
          add: ["NET_ADMIN", "NET_RAW"]
      volumeMounts:
        - name: kubeconfig
          mountPath: /etc/kubernetes/admin.conf
  volumes:
    - name: kubeconfig
      hostPath:
        path: /etc/kubernetes/admin.conf
```

- [ ] **Step 3: Write `roles/kube_vip/tasks/main.yml`**

```yaml
---
- name: Ensure the static pod manifest directory exists
  ansible.builtin.file:
    path: /etc/kubernetes/manifests
    state: directory
    owner: root
    group: root
    mode: "0755"

- name: Place the kube-vip static pod manifest
  ansible.builtin.template:
    src: kube-vip.yaml.j2
    dest: /etc/kubernetes/manifests/kube-vip.yaml
    owner: root
    group: root
    mode: "0644"
```

- [ ] **Step 4: Verify the template renders**

Run: `ansible-playbook playbooks/bootstrap.yml --check --diff --limit cp1`
Expected: a diff showing `kube-vip.yaml` would be created with the real VIP substituted. This task has no molecule scenario — a static pod manifest is inert until a kubelet reads it, so `--check --diff` is the meaningful verification.

- [ ] **Step 5: Commit**

```bash
git add roles/kube_vip
git commit -m "feat(kube_vip): control-plane VIP static pod"
```

---

### Task 8: Control-plane bootstrap — init on cp1

**Files:**
- Create: `roles/control_plane/tasks/main.yml`, `roles/control_plane/templates/kubeadm-config.yaml.j2`, `playbooks/bootstrap.yml`

**Interfaces:**
- Consumes: `control_plane_endpoint`, `pod_cidr`, `service_cidr`, `kubernetes_version`; `kube_vip` role must have run.
- Produces: `/etc/kubernetes/admin.conf` on `cp1`; registered facts `cp_join_command` and `worker_join_command` consumed by Task 9 and Task 10.

- [ ] **Step 1: Write `roles/control_plane/templates/kubeadm-config.yaml.j2`**

```yaml
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: "v{{ kubernetes_patch_version }}"
controlPlaneEndpoint: "{{ control_plane_endpoint }}"
networking:
  podSubnet: "{{ pod_cidr }}"
  serviceSubnet: "{{ service_cidr }}"
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
```

`kubernetes_patch_version` must be the full `major.minor.patch` that the apt repo actually installed. Confirm the two agree before running init:

Run: `ansible control_plane -a "kubeadm version -o short"`
Expected: every node reports `v{{ kubernetes_patch_version }}`. A mismatch makes `kubeadm init` pull control-plane images for a version the binaries do not match.

- [ ] **Step 2: Write `roles/control_plane/tasks/main.yml`**

```yaml
---
- name: Check whether this node is already initialised
  ansible.builtin.stat:
    path: /etc/kubernetes/admin.conf
  register: admin_conf

- name: Render the kubeadm config on the first control plane
  ansible.builtin.template:
    src: kubeadm-config.yaml.j2
    dest: /etc/kubernetes/kubeadm-config.yaml
    owner: root
    group: root
    mode: "0600"
  when: inventory_hostname == groups['control_plane'][0]

- name: Initialise the first control plane
  ansible.builtin.command:
    cmd: kubeadm init --config /etc/kubernetes/kubeadm-config.yaml --upload-certs
  when:
    - inventory_hostname == groups['control_plane'][0]
    - not admin_conf.stat.exists
  register: kubeadm_init
  changed_when: kubeadm_init.rc == 0

- name: Generate the control-plane join command
  ansible.builtin.shell:
    cmd: >-
      echo "$(kubeadm token create --print-join-command)
      --control-plane --certificate-key $(kubeadm init phase upload-certs
      --upload-certs 2>/dev/null | tail -1)"
  when: inventory_hostname == groups['control_plane'][0]
  register: cp_join
  changed_when: false

- name: Generate the worker join command
  ansible.builtin.command:
    cmd: kubeadm token create --print-join-command
  when: inventory_hostname == groups['control_plane'][0]
  register: worker_join
  changed_when: false

- name: Publish join commands as facts
  ansible.builtin.set_fact:
    cp_join_command: "{{ cp_join.stdout }}"
    worker_join_command: "{{ worker_join.stdout }}"
  when: inventory_hostname == groups['control_plane'][0]
```

- [ ] **Step 3: Write `playbooks/bootstrap.yml`**

```yaml
---
- name: Place the control-plane VIP
  hosts: control_plane
  roles:
    - kube_vip

- name: Bootstrap the control plane
  hosts: control_plane
  serial: 1
  roles:
    - control_plane

- name: Join the workers
  hosts: workers
  roles:
    - worker
```

`serial: 1` matters: `cp2` and `cp3` must join one at a time, or concurrent etcd member additions can lose quorum during the join.

- [ ] **Step 4: Dry-run against the real inventory**

Run: `ansible-playbook playbooks/bootstrap.yml --check --limit cp1`
Expected: no errors; init task reports it would run.

- [ ] **Step 5: Commit**

```bash
git add roles/control_plane playbooks/bootstrap.yml
git commit -m "feat(control_plane): kubeadm init on the first control plane"
```

---

### Task 9: Join the remaining control planes

**Files:**
- Modify: `roles/control_plane/tasks/main.yml` (append)

**Interfaces:**
- Consumes: `cp_join_command` from Task 8.
- Produces: a three-member etcd cluster.

- [ ] **Step 1: Append to `roles/control_plane/tasks/main.yml`**

```yaml
- name: Join the remaining control planes
  ansible.builtin.command:
    cmd: "{{ hostvars[groups['control_plane'][0]]['cp_join_command'] }}"
  when:
    - inventory_hostname != groups['control_plane'][0]
    - not admin_conf.stat.exists
  register: cp_joined
  changed_when: cp_joined.rc == 0
```

- [ ] **Step 2: Verify quorum after the run**

Run: `kubectl get nodes` (after `make bootstrap`)
Expected: three nodes with the `control-plane` role, all present. They will be `NotReady` — that is correct until Task 11 installs CNI.

- [ ] **Step 3: Verify etcd has three members**

Run:
```bash
kubectl -n kube-system exec etcd-cp1 -- etcdctl \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  member list
```
Expected: three members listed.

- [ ] **Step 4: Commit**

```bash
git add roles/control_plane
git commit -m "feat(control_plane): join cp2 and cp3 to the etcd cluster"
```

---

### Task 10: Join the workers and untaint the control planes

**Files:**
- Create: `roles/worker/tasks/main.yml`

**Interfaces:**
- Consumes: `worker_join_command` from Task 8, `untaint_control_planes` from Task 1.
- Produces: a five-node cluster, all schedulable.

Untainting must happen before Longhorn (Task 13) or replica placement fails with only two candidate nodes.

- [ ] **Step 1: Write `roles/worker/tasks/main.yml`**

```yaml
---
- name: Check whether this node has already joined
  ansible.builtin.stat:
    path: /etc/kubernetes/kubelet.conf
  register: kubelet_conf

- name: Join the cluster as a worker
  ansible.builtin.command:
    cmd: "{{ hostvars[groups['control_plane'][0]]['worker_join_command'] }}"
  when: not kubelet_conf.stat.exists
  register: worker_joined
  changed_when: worker_joined.rc == 0
```

- [ ] **Step 2: Append the untaint play to `playbooks/bootstrap.yml`**

```yaml
- name: Untaint the control planes so they can carry workloads
  hosts: "{{ groups['control_plane'][0] }}"
  tasks:
    - name: Remove the control-plane NoSchedule taint
      ansible.builtin.command:
        cmd: >-
          kubectl --kubeconfig /etc/kubernetes/admin.conf taint nodes
          --all node-role.kubernetes.io/control-plane- --overwrite
      register: untaint
      changed_when: "'untainted' in untaint.stdout"
      failed_when:
        - untaint.rc != 0
        - "'not found' not in untaint.stderr"
      when: untaint_control_planes | bool
```

The `failed_when` guard is what makes this idempotent: removing an already-absent taint returns non-zero with "not found", which is success on a re-run.

- [ ] **Step 3: Verify all five nodes are present**

Run: `kubectl get nodes -o wide`
Expected: five nodes. Still `NotReady` — CNI comes next.

- [ ] **Step 4: Verify the taint is gone**

Run: `kubectl describe node cp1 | grep -i taint`
Expected: `Taints: <none>`

- [ ] **Step 5: Commit**

```bash
git add roles/worker playbooks/bootstrap.yml
git commit -m "feat(worker): join workers and untaint control planes"
```

---

### Task 11: Cilium CNI

Until this runs, every node is `NotReady` and no pod networking exists. That is expected, not a failure.

**Files:**
- Create: `platform/cilium/values.yaml`
- Modify: `Makefile` (add `platform` target, first section)

**Interfaces:**
- Consumes: `cilium_version`, `pod_cidr`.
- Produces: nodes reaching `Ready`, which every later task depends on.

- [ ] **Step 1: Write `platform/cilium/values.yaml`**

```yaml
---
ipam:
  mode: kubernetes
# kube-proxy is left in place for the initial bring-up.
# Switching to kubeProxyReplacement is a deliberate later change.
kubeProxyReplacement: false
operator:
  replicas: 2
```

- [ ] **Step 2: Add the Cilium section to the `Makefile`**

```make
.PHONY: platform
platform: cilium metallb ingress longhorn

.PHONY: cilium
cilium:
	helm repo add cilium https://helm.cilium.io/
	helm repo update
	helm upgrade --install cilium cilium/cilium \
		--version $(CILIUM_VERSION) \
		--namespace kube-system \
		-f platform/cilium/values.yaml \
		--wait --timeout 10m
	kubectl wait --for=condition=Ready nodes --all --timeout=300s
```

`CILIUM_VERSION` is already defined at the top of the Makefile from Task 1, read straight out of `group_vars/all.yml` — no version string is duplicated between Ansible and Make.

- [ ] **Step 3: Run it and verify nodes go Ready**

Run: `make cilium`
Expected: `kubectl wait` returns success; `kubectl get nodes` shows five `Ready`.

- [ ] **Step 4: Verify pod-to-pod networking across nodes**

Run:
```bash
kubectl run net-a --image=busybox --restart=Never -- sleep 3600
kubectl run net-b --image=busybox --restart=Never -- sleep 3600
kubectl wait --for=condition=Ready pod/net-a pod/net-b --timeout=120s
kubectl exec net-a -- ping -c3 "$(kubectl get pod net-b -o jsonpath='{.status.podIP}')"
kubectl delete pod net-a net-b
```
Expected: three successful pings.

- [ ] **Step 5: Commit**

```bash
git add platform/cilium Makefile
git commit -m "feat(platform): Cilium CNI"
```

---

### Task 12: MetalLB and ingress-nginx

MetalLB must land before ingress-nginx, which otherwise sits `Pending` forever waiting for an external IP.

**Files:**
- Create: `platform/metallb/values.yaml`, `platform/metallb/pool.yaml.tpl`, `platform/ingress-nginx/values.yaml`
- Modify: `Makefile`

**Interfaces:**
- Consumes: `metallb_pool`, `metallb_version`, `ingress_nginx_version`.
- Produces: working `type: LoadBalancer` services and an ingress controller with an external IP — both asserted by Task 14.

- [ ] **Step 1: Write `platform/metallb/pool.yaml.tpl`**

```yaml
---
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: rack-pool
  namespace: metallb-system
spec:
  addresses:
    - "__METALLB_POOL__"
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: rack-l2
  namespace: metallb-system
spec:
  ipAddressPools:
    - rack-pool
```

- [ ] **Step 2: Write `platform/ingress-nginx/values.yaml`**

```yaml
---
controller:
  replicaCount: 2
  service:
    type: LoadBalancer
  ingressClassResource:
    default: true
```

- [ ] **Step 3: Add both to the `Makefile`**

```make
.PHONY: metallb
metallb:
	helm repo add metallb https://metallb.github.io/metallb
	helm repo update
	helm upgrade --install metallb metallb/metallb \
		--version $(METALLB_VERSION) \
		--namespace metallb-system --create-namespace \
		--wait --timeout 5m
	sed 's|__METALLB_POOL__|$(METALLB_POOL)|' platform/metallb/pool.yaml.tpl | kubectl apply -f -

.PHONY: ingress
ingress:
	helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
	helm repo update
	helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
		--version $(INGRESS_NGINX_VERSION) \
		--namespace ingress-nginx --create-namespace \
		-f platform/ingress-nginx/values.yaml \
		--wait --timeout 5m
```

- [ ] **Step 4: Verify the pool assigns an address**

Run:
```bash
make metallb
kubectl create deployment lbtest --image=nginx
kubectl expose deployment lbtest --port=80 --type=LoadBalancer
kubectl get svc lbtest -w
```
Expected: `EXTERNAL-IP` populates from the pool within a few seconds. Clean up with `kubectl delete svc,deployment lbtest`.

- [ ] **Step 5: Verify ingress-nginx gets an external IP**

Run: `make ingress && kubectl -n ingress-nginx get svc ingress-nginx-controller`
Expected: `EXTERNAL-IP` is an address from the pool, not `<pending>`.

- [ ] **Step 6: Commit**

```bash
git add platform/metallb platform/ingress-nginx Makefile
git commit -m "feat(platform): MetalLB L2 and ingress-nginx"
```

---

### Task 13: Longhorn

**Files:**
- Create: `platform/longhorn/values.yaml`
- Modify: `Makefile`

**Interfaces:**
- Consumes: `longhorn_version`, `longhorn_mount`; requires Task 10's untaint and Task 5's `open-iscsi`.
- Produces: a default StorageClass, asserted by Task 14.

- [ ] **Step 1: Write `platform/longhorn/values.yaml`**

```yaml
---
defaultSettings:
  defaultDataPath: /var/lib/longhorn
  defaultReplicaCount: 3
  # Replicas must not share a node, or a node loss takes multiple copies.
  replicaSoftAntiAffinity: false
persistence:
  defaultClass: true
  defaultClassReplicaCount: 3
```

- [ ] **Step 2: Add the Longhorn target to the `Makefile`**

```make
.PHONY: longhorn
longhorn:
	helm repo add longhorn https://charts.longhorn.io
	helm repo update
	helm upgrade --install longhorn longhorn/longhorn \
		--version $(LONGHORN_VERSION) \
		--namespace longhorn-system --create-namespace \
		-f platform/longhorn/values.yaml \
		--wait --timeout 10m
```

- [ ] **Step 3: Verify the StorageClass is default**

Run: `kubectl get storageclass`
Expected: `longhorn (default)`.

- [ ] **Step 4: Verify Longhorn sees five schedulable nodes**

Run: `kubectl -n longhorn-system get nodes.longhorn.io`
Expected: five entries. Fewer than three means the untaint in Task 10 did not apply and three-replica volumes will not schedule.

- [ ] **Step 5: Commit**

```bash
git add platform/longhorn Makefile
git commit -m "feat(platform): Longhorn with a dedicated data path"
```

---

### Task 14: Cluster smoke test

The four checks that between them catch essentially every way this stack breaks. Check 3 is the important one — it is the only proof that Longhorn replication actually works, as opposed to a volume merely existing.

**Files:**
- Create: `scripts/verify.sh`
- Modify: `Makefile`

**Interfaces:**
- Consumes: a fully built cluster.
- Produces: a pass/fail gate before handing off to `k8s-infra`.

- [ ] **Step 1: Write `scripts/verify.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail

fail() { echo "FAIL: $*" >&2; exit 1; }
ns=verify-$$
cleanup() { kubectl delete ns "$ns" --wait=false >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "1/4 all nodes Ready"
[ "$(kubectl get nodes --no-headers | grep -c ' Ready ')" -eq 5 ] \
  || fail "expected 5 Ready nodes"

kubectl create ns "$ns" >/dev/null

echo "2/4 LoadBalancer gets an external IP"
kubectl -n "$ns" create deployment lb --image=nginx >/dev/null
kubectl -n "$ns" expose deployment lb --port=80 --type=LoadBalancer >/dev/null
for _ in $(seq 1 30); do
  ip=$(kubectl -n "$ns" get svc lb -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  [ -n "$ip" ] && break
  sleep 2
done
[ -n "${ip:-}" ] || fail "no external IP assigned by MetalLB"

echo "3/4 PVC survives a pod moving to another node"
kubectl -n "$ns" apply -f - >/dev/null <<YAML
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: data }
spec:
  accessModes: [ReadWriteOnce]
  resources: { requests: { storage: 1Gi } }
YAML
kubectl -n "$ns" run writer --image=busybox --restart=Never \
  --overrides='{"spec":{"containers":[{"name":"writer","image":"busybox","command":["sh","-c","echo persisted > /data/f && sleep 3600"],"volumeMounts":[{"name":"d","mountPath":"/data"}]}],"volumes":[{"name":"d","persistentVolumeClaim":{"claimName":"data"}}]}}' >/dev/null
kubectl -n "$ns" wait --for=condition=Ready pod/writer --timeout=180s >/dev/null
node1=$(kubectl -n "$ns" get pod writer -o jsonpath='{.spec.nodeName}')
kubectl -n "$ns" delete pod writer --wait=true >/dev/null

other=$(kubectl get nodes -o jsonpath='{.items[*].metadata.name}' \
  | tr ' ' '\n' | grep -v "^${node1}$" | head -1)
[ -n "$other" ] || fail "could not find a second node to reschedule onto"

kubectl -n "$ns" apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Pod
metadata: { name: reader }
spec:
  nodeSelector: { kubernetes.io/hostname: "$other" }
  restartPolicy: Never
  containers:
    - name: reader
      image: busybox
      command: ["sh", "-c", "cat /data/f && sleep 30"]
      volumeMounts: [{ name: d, mountPath: /data }]
  volumes:
    - name: d
      persistentVolumeClaim: { claimName: data }
YAML
kubectl -n "$ns" wait --for=condition=Ready pod/reader --timeout=180s >/dev/null
kubectl -n "$ns" logs reader | grep -q persisted \
  || fail "data did not survive rescheduling — Longhorn replication is not working"

echo "4/4 ingress serves traffic"
kubectl -n "$ns" create ingress web --class=nginx --rule="verify.local/*=lb:80" >/dev/null
lbip=$(kubectl -n ingress-nginx get svc ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
sleep 5
curl -sf -H "Host: verify.local" "http://$lbip/" >/dev/null \
  || fail "ingress did not serve traffic"

echo "ALL CHECKS PASSED"
```

- [ ] **Step 2: Make it executable and add the Makefile target**

```make
.PHONY: verify
verify:
	./scripts/verify.sh
```

Run: `chmod +x scripts/verify.sh`

- [ ] **Step 3: Run it**

Run: `make verify`
Expected: `ALL CHECKS PASSED`.

- [ ] **Step 4: Commit**

```bash
git add scripts/verify.sh Makefile
git commit -m "feat: cluster smoke test"
```

---

### Task 15: kubeconfig, reset, and the day-2 runbook

**Files:**
- Create: `playbooks/reset.yml`, `docs/runbook-day2.md`
- Modify: `Makefile`, `README.md`

**Interfaces:**
- Consumes: a working cluster.
- Produces: the handoff to `k8s-infra`.

- [ ] **Step 1: Add the `kubeconfig` target to the `Makefile`**

```make
.PHONY: kubeconfig
kubeconfig:
	ansible control_plane[0] -m fetch \
		-a "src=/etc/kubernetes/admin.conf dest=/tmp/rack.conf flat=yes"
	KUBECONFIG=$$HOME/.kube/config:/tmp/rack.conf kubectl config view --flatten > /tmp/merged
	mv /tmp/merged $$HOME/.kube/config
	kubectl config rename-context kubernetes-admin@kubernetes rack || true
	rm -f /tmp/rack.conf
```

- [ ] **Step 2: Write `playbooks/reset.yml`**

```yaml
---
- name: DESTRUCTIVE - reset every node
  hosts: all
  tasks:
    - name: Require explicit confirmation
      ansible.builtin.assert:
        that:
          - confirm_reset | default('') == 'yes'
        fail_msg: "Re-run with -e confirm_reset=yes"

    - name: kubeadm reset
      ansible.builtin.command:
        cmd: kubeadm reset -f
      changed_when: true

    - name: Remove leftover CNI and kubernetes state
      ansible.builtin.file:
        path: "{{ item }}"
        state: absent
      loop:
        - /etc/cni/net.d
        - /etc/kubernetes
        - /var/lib/etcd
```

Note: `/var/lib/longhorn` is deliberately not removed. Wiping persistent data must be a separate, explicit act.

- [ ] **Step 3: Write `docs/runbook-day2.md`**

Cover, each with the exact command:

- **etcd snapshots** — `etcdctl snapshot save`, scheduled, copied off-box. State plainly that without this, losing two control planes means rebuilding from nothing.
- **Certificate renewal** — `kubeadm certs check-expiration` and `kubeadm certs renew all`, plus restarting the control-plane static pods. Note the one-year default and that this is the usual way a working home cluster dies silently.
- **Zabbix checks to add** — cert expiry, etcd fsync latency (etcd and Longhorn share each control-plane SSD), node Ready, Longhorn volume health.
- **Node loss** — with three control planes, losing one keeps quorum. Recovery is `kubeadm reset` on the dead node, `etcdctl member remove`, then re-join. Losing two leaves a read-only cluster needing a snapshot restore.
- **Upgrades** — the manual `kubeadm upgrade plan` / `apply` procedure, one node at a time with `kubectl drain` and `kubectl uncordon`. Explicitly out of scope for automation in v1; automate only after performing it by hand once.

- [ ] **Step 4: Update `README.md`**

Replace the "design only" status line with the real quick start: `make deps`, `make preflight`, `make prep`, `make bootstrap`, `make platform`, `make kubeconfig`, `make verify`, then `k8s-infra: make deploy`.

- [ ] **Step 5: Verify the reset guard works**

Run: `ansible-playbook playbooks/reset.yml`
Expected: FAIL with "Re-run with -e confirm_reset=yes" — the guard fires and nothing is touched.

- [ ] **Step 6: Commit**

```bash
git add playbooks/reset.yml docs/runbook-day2.md Makefile README.md
git commit -m "feat: kubeconfig handoff, guarded reset, day-2 runbook"
```

---

## Follow-up, tracked elsewhere

`k8s-netbird` assumes Traefik because k3s bundled it. Its ingress annotations need revisiting for ingress-nginx. That work belongs in that repo, not this plan.
