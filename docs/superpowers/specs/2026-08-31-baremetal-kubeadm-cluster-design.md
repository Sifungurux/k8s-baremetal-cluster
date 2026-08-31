# Bare-metal kubeadm cluster — design

**Date:** 2026-08-31
**Status:** approved design, not yet implemented
**Repo:** `k8s-baremetal-cluster`

## Purpose

Convert a 5-server rack into a permanent, highly-available Kubernetes cluster that runs
home-production workloads (NetBird, Sigstore, Zabbix, DNS filtering) continuously.

The repo's job ends at a cluster with CNI, LoadBalancer, ingress, and a default StorageClass —
the set of things k3s bundled invisibly and kubeadm does not provide. At that point
`k8s-infra`'s `make deploy` runs unchanged and provides `local-ca-issuer`.

## Goals

- Survive the loss of any single node without losing the API or persistent data.
- Be re-runnable: every step idempotent, a full rebuild reproducible from the inventory.
- Keep add-ons expressed as Helm releases so migrating them to `k8s-fleet` (Flux) later is a
  move, not a rewrite.

## Non-goals

- Cluster upgrades are **not** automated in v1 (see [Day-2](#day-2-operations)).
- OS installation is out of scope. Nodes arrive with Debian/Ubuntu LTS and SSH access.
- No application workloads. Those live in their own repos and deploy on top.

## Context and prior decisions

- `k8s-infra` was deliberately scoped to shared services on a running cluster (commit `634b5c6`);
  cluster lifecycle lives in dedicated repos. This repo is the bare-metal peer of
  `k8s-colima-cluster`, which owns the same concern locally.
- Alternatives considered and rejected:
  - **Kubespray.** Production-grade and solves upgrades, but it is hundreds of opaque roles
    behind a variables file. For a 5-node rack it is a very large dependency used at a
    fraction of its capability, and it does not fit the existing `molecule` practice.
    Its one real advantage — day-2 upgrades — can be adopted later if hand-rolled upgrades
    prove painful. The reverse migration is much harder.
  - **Everything in Ansible, including add-ons.** Puts Helm releases behind Ansible's control
    loop, which fits worse than Helm's own, and makes the eventual Flux migration a rewrite.

## Hardware

| Node | Role | RAM | Disk |
|---|---|---|---|
| `cp1` | control-plane | 16 GB | 1× SSD/NVMe |
| `cp2` | control-plane | 16 GB | 1× SSD/NVMe |
| `cp3` | control-plane | 32 GB | 1× SSD/NVMe |
| `w1` | worker | 32 GB | 1× SSD/NVMe |
| `w2` | worker | 32 GB | 1× SSD/NVMe |

**Why the small machines run the control plane.** Control-plane overhead is roughly 4 GB per
node and etcd for a cluster this size uses 1–2 GB; 16 GB is ample. Total workload capacity is
identical whichever three nodes take the role (~112 GB), because the overhead is paid on three
nodes either way. The difference only appears later: if the control planes are ever tainted,
this layout leaves 2 × 32 GB = 64 GB of workload capacity, where control-planes-on-32 GB would
leave 2 × 16 GB = 32 GB.

**All five nodes are schedulable in v1.** Longhorn needs three schedulable nodes to place three
replicas, and there are only two workers. This is a compromise forced by the node count, not a
preference — see [Target state](#target-state-6-nodes).

**Control-plane protection.** Because workloads share the 16 GB control planes, kubelet
`system-reserved` and `kube-reserved` are set explicitly on those nodes and control-plane
components get a priority class. A runaway pod must not be able to starve etcd. Defaults are
not sufficient here.

## Architecture

### Networking

The rack sits on its own VLAN/subnet, separate from the house LAN.

| Element | Mechanism | Notes |
|---|---|---|
| Control-plane endpoint | `kube-vip`, ARP mode | A VIP on the rack VLAN. All nodes and all `kubectl` traffic address the VIP, never `cp1` directly — this is what makes losing a control plane survivable. |
| CNI | Cilium | `kube-proxy` left in place initially. Cilium's kube-proxy replacement is better but is a deliberate later change, not something to debug during first bring-up. |
| Service LoadBalancer | MetalLB, L2 mode | Address pool reserved on the rack VLAN, outside any DHCP range. Replaces k3s ServiceLB. |
| Ingress | ingress-nginx | Replaces k3s's bundled Traefik. |

Four ranges must be chosen and must not overlap. They are inventory inputs, not defaults:

1. The rack VLAN subnet.
2. A single VIP address for the control-plane endpoint.
3. The MetalLB pool — a contiguous range in the VLAN, outside DHCP.
4. Pod and service CIDRs. kubeadm's defaults are `10.244.0.0/16` and `10.96.0.0/12`; these are
   safe only if the rack VLAN does not fall inside them.

### Storage

Each node has a single SSD. LVM is laid down at OS-install time with free space deliberately
left in the volume group. A dedicated logical volume is formatted and mounted at
`/var/lib/longhorn`, so Longhorn data cannot fill the root filesystem.

Longhorn runs on all five nodes with three replicas. Replica placement is driven by disk
capacity, not node RAM, and the disks are uniform.

**Known risk: etcd and Longhorn share each control-plane SSD.** etcd is unusually sensitive to
fsync latency; when it degrades, the symptom is spurious leader elections and API timeouts that
do not look like a disk problem. On NVMe this is acceptable, but it must be monitored from day
one, not discovered later. See [Day-2](#day-2-operations).

## Repository structure

```
k8s-baremetal-cluster/
├── Makefile                    front door
├── inventory/
│   ├── hosts.yml               5 nodes; groups: control_plane, workers
│   └── group_vars/all.yml      versions, CIDRs, VIP, MetalLB pool
├── playbooks/
│   ├── preflight.yml           validation only; modifies nothing
│   ├── prep.yml                OS + storage across all nodes
│   ├── bootstrap.yml           kubeadm init, joins, CNI
│   └── reset.yml               kubeadm reset — deliberate teardown
├── roles/
│   ├── preflight/              fail-fast validation before anything is touched
│   ├── os_prep/                swap, kernel modules, sysctls, containerd, kubelet reservations
│   ├── storage_prep/           LV + mkfs + mount /var/lib/longhorn
│   ├── kube_vip/               static pod manifest for the VIP
│   ├── control_plane/          init on cp1, join cp2/cp3
│   └── worker/                 join w1/w2
├── platform/                   Helm values, applied by the Makefile
│   ├── cilium/
│   ├── metallb/
│   ├── ingress-nginx/
│   └── longhorn/
└── docs/
```

Ansible does what only Ansible can — SSH, apt, kernel modules, `kubeadm`. Anything expressible
as a Helm release stays one, in `platform/`. That split is what keeps the Flux migration cheap.

### Version pinning

Kubernetes, containerd, Cilium, MetalLB, ingress-nginx, and Longhorn versions are pinned
explicitly in `inventory/group_vars/all.yml`. No `latest`, no floating tags — a rebuild six
months from now must produce the same cluster. Choose the Kubernetes minor version at
implementation time, preferring one release behind the newest so the ecosystem has caught up.

## Build flow

```
make preflight   →  validate inventory and network assumptions; fail loudly
make prep        →  os_prep + storage_prep on all 5 nodes
make bootstrap   →  kube-vip on cp1 → kubeadm init → join cp2,cp3 → join w1,w2 → untaint CPs
make platform    →  Cilium → MetalLB → ingress-nginx → Longhorn
make kubeconfig  →  fetch admin.conf, merge as context `rack`
make verify      →  smoke test (see Testing)
                    ↓
                 k8s-infra: make deploy
```

### Ordering constraints

These are the failure modes worth encoding rather than rediscovering:

1. **`kube-vip` must be running before `kubeadm init`.** The VIP has to answer before it can be
   `--control-plane-endpoint`. The static pod manifest is placed on `cp1` first; init then
   targets the VIP, which is what allows `cp2`/`cp3` to join a stable address.
2. **Nodes stay `NotReady` until Cilium is applied.** Expected. The bootstrap playbook must not
   wait for `Ready` before installing CNI.
3. **Untaint the control planes before installing Longhorn**, or replica placement fails with
   only two candidate nodes.
4. **MetalLB before ingress-nginx**, which otherwise sits `Pending` waiting for an external IP.
5. **`open-iscsi` and `nfs-common` belong in `os_prep`**, not in the Longhorn step. They are
   Longhorn prerequisites, but installing them later means another SSH pass across all nodes
   after the cluster is already up.

### Preflight checks

Run before anything is modified. Most bare-metal bring-up disasters are a wrong value in a
variables file discovered twenty minutes in.

- VIP address is free — nothing answers ARP.
- MetalLB pool does not overlap the VLAN's DHCP range.
- Pod and service CIDRs do not collide with the rack VLAN.
- Free space exists in every node's volume group.
- All five nodes are reachable over SSH and time-synced.

### Idempotence

Every step is re-runnable. `kubeadm init` is guarded on the presence of
`/etc/kubernetes/admin.conf`; joins are guarded on the node already being a cluster member.
Re-running `make bootstrap` against a healthy cluster is a no-op. `reset.yml` is the deliberate
escape hatch for starting over.

## Testing

Two layers, with honest limits.

**Role-level (`molecule`)** — covers `os_prep` and `storage_prep`: package installation,
template rendering, idempotence. Matches the existing practice in the `ansible-*` repos. The
limit is real: containers cannot meaningfully exercise kernel modules, sysctls, or LVM, so
molecule proves a role is well-formed, not that it works on metal. Lima VMs are the honest
test bed for the parts containers cannot reach.

**Cluster-level (`make verify`)** — the higher-value artifact. Four checks that between them
catch essentially every way this stack breaks:

1. All five nodes report `Ready`.
2. A `LoadBalancer` service receives an IP from the MetalLB pool.
3. A PVC binds **and survives its pod being rescheduled onto a different node** — the only real
   proof that Longhorn replication works, as opposed to a volume merely existing.
4. An ingress serves traffic end to end.

## Day-2 operations

The part that determines whether this cluster still works in two years.

- **etcd snapshots, scheduled, stored off-box, from day one.** Losing two control planes without
  a snapshot means rebuilding from nothing. Non-negotiable for a cluster described as permanent.
- **Certificate expiry.** kubeadm issues one-year certificates. This is the classic way a working
  home cluster dies — silently, twelve months in. A Zabbix check on
  `kubeadm certs check-expiration` costs nothing and Zabbix is already deployed.
- **etcd fsync latency alerting**, because etcd and Longhorn share each control-plane SSD.
- **Node loss.** With three control planes, losing one preserves quorum. Recovery is
  `kubeadm reset` on the dead node, removing its etcd member, and re-joining. Losing two leaves
  a read-only cluster requiring an etcd snapshot restore.
- **Upgrades are out of scope for v1.** `kubeadm upgrade` one node at a time with
  drain/uncordon, written up as a documented manual procedure. Automate after performing it by
  hand at least once. This is the single capability Kubespray would have provided; automating an
  unvalidated upgrade path is worse than not automating it.

## Target state (6 nodes)

If a sixth node can be added, the recommended posture changes: **3 control-plane + 3 workers,
with the control planes tainted.** Longhorn then gets its three replica targets from the workers
alone, and the control plane stops competing with workloads for RAM and disk — which also
retires the etcd/Longhorn co-location risk on the control-plane SSDs.

The design accommodates this without a rebuild: node roles are inventory-driven, so the change
is an inventory edit, `make prep`, a join, and flipping the untaint variable.

## Downstream impact

- **`k8s-netbird` assumes Traefik**, because k3s bundled it. Its ingress annotations need
  revisiting for ingress-nginx. Tracked as a follow-up in that repo, not this one.
- **`k8s-sigstore` already targets ingress-nginx**, so it needs no change.
- **`k8s-infra` needs no change** and gains nothing to fix — it is cluster-agnostic today.

## Required inputs before implementation

These are decisions, not defaults, and implementation cannot start without them:

1. Rack VLAN subnet and gateway.
2. Control-plane VIP address.
3. MetalLB pool range.
4. Confirmation that pod/service CIDRs do not collide with the above.
5. Kubernetes minor version to pin.
6. Hostnames and SSH access details for the five nodes.
