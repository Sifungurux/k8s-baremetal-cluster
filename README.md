# k8s-baremetal-cluster

Ansible-driven [kubeadm](https://kubernetes.io/docs/reference/setup-tools/kubeadm/) install for a 5-node physical rack, plus the platform add-ons that k3s used to bundle for free.

The bare-metal counterpart to [`k8s-colima-cluster`](../k8s-colima-cluster) (local dev cluster). Hands off a cluster that behaves like the k3d ones — CNI, LoadBalancer, ingress, default StorageClass — so [`k8s-infra`](../k8s-infra) and everything downstream run against it unchanged.

**Status: design only.** Nothing is implemented yet. See
[`docs/superpowers/specs/2026-08-31-baremetal-kubeadm-cluster-design.md`](docs/superpowers/specs/2026-08-31-baremetal-kubeadm-cluster-design.md).
