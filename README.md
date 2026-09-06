# k8s-baremetal-cluster

Ansible-driven [kubeadm](https://kubernetes.io/docs/reference/setup-tools/kubeadm/) install for a 5-node physical rack, plus the platform add-ons that k3s used to bundle for free.

The bare-metal counterpart to [`k8s-colima-cluster`](../k8s-colima-cluster) (local dev cluster). Hands off a cluster that behaves like the k3d ones — CNI, LoadBalancer, ingress, default StorageClass — so [`k8s-infra`](../k8s-infra) and everything downstream run against it unchanged.

**Status: in progress.** The whole path is built — `make iso` produces a
bootable USB image that installs Debian stable and prepares a node for
`kubeadm`; `make bootstrap` brings up three control planes behind a kube-vip
VIP and joins the workers; `make platform` adds Cilium, MetalLB, ingress-nginx,
Envoy Gateway and Longhorn. Both `Ingress` and Gateway API are served, so
applications use whichever they already speak. Still missing: the cluster smoke
test, `make kubeconfig`, and `make reset`.

Before any of this can run, fill in the operator-supplied values (currently
`CHANGEME`) in [`inventory/group_vars/all.yml`](inventory/group_vars/all.yml)
and [`inventory/hosts.yml`](inventory/hosts.yml).

- [`docs/installer.md`](docs/installer.md) — build the USB image, install the rack
- [`docs/deployment.md`](docs/deployment.md) — run the repo from a controller
- [`docs/superpowers/specs/2026-08-31-baremetal-kubeadm-cluster-design.md`](docs/superpowers/specs/2026-08-31-baremetal-kubeadm-cluster-design.md) — the design
