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
	@echo "    make iso         Build the USB installer image (dist/); KEY=... to pick a key"
	@echo "    make iso-check   Check the generated preseed and boot menu"
	@echo "    make deps        Install Ansible collections"
	@echo "    make preflight   Validate inventory and network (changes nothing)"
	@echo "    make prep        OS + storage prep on all nodes"
	@echo "    make bootstrap   kubeadm init and the control-plane VIP"
	@echo "    make cilium      CNI — nodes stay NotReady until this runs"
	@echo "    make platform    MetalLB, ingress-nginx, Longhorn"
	@echo "    make kubeconfig  Fetch admin.conf as context 'rack'"
	@echo "    make verify      Cluster smoke test"
	@echo "    make reset       DESTRUCTIVE: kubeadm reset all nodes"
	@echo ""

# Override with: make iso KEY=~/.ssh/other.pub
KEY ?= $(HOME)/.ssh/rack_ecdsa.pub

.PHONY: iso
iso:
	installer/build-iso.sh --key $(KEY)

.PHONY: iso-check
iso-check:
	installer/test-build.sh

.PHONY: deps
deps:
	ansible-galaxy install -r requirements.yml
	pip install -r requirements.txt

.PHONY: preflight
preflight:
	$(ANSIBLE) playbooks/preflight.yml

.PHONY: prep
prep: preflight
	$(ANSIBLE) playbooks/prep.yml

.PHONY: bootstrap
bootstrap:
	$(ANSIBLE) playbooks/bootstrap.yml

# Until Cilium runs, every node is NotReady and there is no pod networking.
# That is the expected state after bootstrap, not a fault.
# Run this once every node has joined: operator.replicas is 2, so --wait fails
# on a cluster with only one schedulable node.
.PHONY: cilium
cilium:
	helm repo add cilium https://helm.cilium.io/
	helm repo update cilium
	helm upgrade --install cilium cilium/cilium \
		--version $(CILIUM_VERSION) \
		--namespace kube-system \
		-f platform/cilium/values.yaml \
		--wait --timeout 10m
	kubectl wait --for=condition=Ready nodes --all --timeout=300s
