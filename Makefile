.DEFAULT_GOAL := help
ANSIBLE := ansible-playbook
VARS := inventory/group_vars/all.yml
HOSTS := inventory/hosts.yml
INVENTORY := inventory/hosts.yml
CONFIRM ?= no

# Single source of truth: every version is read from group_vars, never duplicated here.
CILIUM_VERSION        := $(shell yq '.cilium_version' $(VARS))
METALLB_VERSION       := $(shell yq '.metallb_version' $(VARS))
INGRESS_NGINX_VERSION := $(shell yq '.ingress_nginx_version' $(VARS))
ENVOY_GATEWAY_VERSION := $(shell yq '.envoy_gateway_version' $(VARS))
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
	@echo "    make metallb     LoadBalancer IPs from metallb_pool"
	@echo "    make ingress     ingress-nginx (Ingress resources)"
	@echo "    make gateway     Envoy Gateway (Gateway API) + GatewayClass envoy"
	@echo "    make longhorn    Default StorageClass, 3 replicas"
	@echo "    make platform    All of the above, in order"
	@echo "    make kubeconfig  Merge admin.conf in as context 'rack'"
	@echo "    make verify      Cluster smoke test"
	@echo "    make reset       DESTRUCTIVE: tears down the cluster (CONFIRM=yes)"
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

# MetalLB has to land before anything asking for a LoadBalancer, or those
# services sit Pending forever waiting for an external IP that nothing hands out.
.PHONY: metallb
metallb:
	helm repo add metallb https://metallb.github.io/metallb
	helm repo update metallb
	helm upgrade --install metallb metallb/metallb \
		--version $(METALLB_VERSION) \
		--namespace metallb-system --create-namespace \
		-f platform/metallb/values.yaml \
		--wait --timeout 5m
	sed 's|__METALLB_POOL__|$(METALLB_POOL)|' platform/metallb/pool.yaml.tpl | kubectl apply -f -

# Needs three schedulable nodes for its three-replica default, and the
# /var/lib/longhorn mount that storage_prep created on each of them.
.PHONY: longhorn
longhorn:
	helm repo add longhorn https://charts.longhorn.io
	helm repo update longhorn
	helm upgrade --install longhorn longhorn/longhorn \
		--version $(LONGHORN_VERSION) \
		--namespace longhorn-system --create-namespace \
		-f platform/longhorn/values.yaml \
		--wait --timeout 15m

# Ingress resources only. ingress-nginx dropped its Gateway API support, so
# Gateway API is Envoy Gateway's job below.
.PHONY: ingress
ingress:
	helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
	helm repo update ingress-nginx
	helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
		--version $(INGRESS_NGINX_VERSION) \
		--namespace ingress-nginx --create-namespace \
		-f platform/ingress-nginx/values.yaml \
		--wait --timeout 5m

# Gateway API. The chart ships the gateway.networking.k8s.io CRDs as well as
# the controller, but creates no GatewayClass, so the cluster provides one.
.PHONY: gateway
gateway:
	helm upgrade --install envoy-gateway oci://docker.io/envoyproxy/gateway-helm \
		--version $(ENVOY_GATEWAY_VERSION) \
		--namespace envoy-gateway-system --create-namespace \
		-f platform/envoy-gateway/values.yaml \
		--wait --timeout 10m
	kubectl apply -f platform/envoy-gateway/gatewayclass.yaml

# Order is not cosmetic: MetalLB must precede anything wanting a LoadBalancer,
# and Longhorn wants the cluster already settled.
.PHONY: platform
platform: cilium metallb ingress gateway longhorn

# Fetches admin.conf and merges it in as a context named "rack", rather than
# overwriting whatever kubeconfig you already have.
.PHONY: kubeconfig
kubeconfig:
	@set -eu; \
	umask 077; \
	mkdir -p $(HOME)/.kube; \
	work=$$(mktemp -d); \
	trap 'rm -rf "$$work"' EXIT INT TERM; \
	cp=$$(yq -r '.all.children.control_plane.hosts | keys | .[0]' $(HOSTS)); \
	ansible -i $(INVENTORY) -m fetch \
		-a "src=/etc/kubernetes/admin.conf dest=$$work/admin.conf flat=yes" "$$cp" >/dev/null; \
	KUBECONFIG="$$work/admin.conf" kubectl config rename-context \
		kubernetes-admin@kubernetes rack >/dev/null; \
	KUBECONFIG="$$work/admin.conf:$(HOME)/.kube/config" kubectl config view --flatten \
		> "$$work/merged"; \
	cat "$$work/merged" > $(HOME)/.kube/config; \
	chmod 600 $(HOME)/.kube/config; \
	echo "context 'rack' merged into ~/.kube/config — kubectl config use-context rack"

.PHONY: verify
verify:
	scripts/verify.sh

# DESTROYS the cluster. Requires CONFIRM=yes so a mistyped target cannot do it.
# The Longhorn volume is left alone; that is where the data lives.
.PHONY: reset
reset:
	$(ANSIBLE) playbooks/reset.yml -e confirm_reset=$(CONFIRM)
