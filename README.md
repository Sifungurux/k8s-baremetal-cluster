# k8s-baremetal-cluster

Ansible-driven [kubeadm](https://kubernetes.io/docs/reference/setup-tools/kubeadm/) install for a 5-node physical rack, plus the platform add-ons that k3s used to bundle for free.

The bare-metal counterpart to [`k8s-colima-cluster`](../k8s-colima-cluster) (local dev cluster). Hands off a cluster that behaves like the k3d ones — CNI, LoadBalancer, ingress, default StorageClass — so [`k8s-infra`](../k8s-infra) and everything downstream run against it unchanged.

**Status: in progress.** The inventory, `Makefile`, `preflight` role, and
`os_prep` role are implemented and molecule-tested. Cluster bootstrap
(kubeadm, CNI, MetalLB, ingress, Longhorn) is not yet built. Before any of
this can run, fill in the operator-supplied values (currently `CHANGEME`)
in [`inventory/group_vars/all.yml`](inventory/group_vars/all.yml) and
[`inventory/hosts.yml`](inventory/hosts.yml). See
[`docs/superpowers/specs/2026-08-31-baremetal-kubeadm-cluster-design.md`](docs/superpowers/specs/2026-08-31-baremetal-kubeadm-cluster-design.md).
