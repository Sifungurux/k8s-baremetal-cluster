#!/usr/bin/env bash
# Cluster smoke test: the checks that between them catch essentially every way
# this stack breaks. Read-only apart from one temporary namespace, which is
# removed on exit however the script ends.
#
# Check 4 is the one that matters. Everything else proves a thing exists; check
# 4 proves Longhorn replication actually works, by moving a pod to a different
# node and reading back what the first one wrote. A volume that merely exists
# tells you nothing about whether the data would survive losing a node.
set -euo pipefail

cd "$(dirname "$0")/.."
VARS=${VARS:-inventory/group_vars/all.yml}
HOSTS=${HOSTS:-inventory/hosts.yml}

pass() { printf '  \033[32mok\033[0m   %s\n' "$*"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$*" >&2; failed=$((failed + 1)); }
failed=0

ns=verify-$$
cleanup() { kubectl delete ns "$ns" --wait=false >/dev/null 2>&1 || true; }
trap cleanup EXIT

# The rack size comes from the inventory rather than a hardcoded number — this
# repo has already grown from five nodes to six.
expected=$(yq '[.all.children[].hosts | keys | .[]] | length' "$HOSTS")
pool=$(yq -r '.metallb_pool' "$VARS")

echo
echo "Cluster smoke test  (inventory says $expected nodes)"
echo

# Without this the first kubectl failure kills the script under `set -e` and the
# operator gets an exit code and nothing else.
if ! kubectl version -o json >/dev/null 2>&1; then
    fail "cannot reach the cluster — check KUBECONFIG, or run make kubeconfig"
    echo
    echo "1 check failed."
    exit 1
fi

### 1. every node registered and Ready
ready=$(kubectl get nodes --no-headers 2>/dev/null | awk '$2=="Ready"' | wc -l | tr -d ' ')
if [ "$ready" -eq "$expected" ]; then
    pass "$ready/$expected nodes Ready"
else
    fail "$ready/$expected nodes Ready — a NotReady node usually means the CNI did not start there"
fi

# Longhorn places replicas on schedulable nodes only, and wants three. Two very
# different things make a node unschedulable, so they are reported separately:
# the control-plane taint is a deliberate config choice, while memory-pressure,
# unreachable and not-ready are transient health. Blaming the untaint for a
# starved node sends you to the wrong file.
nodes_json=$(kubectl get nodes -o json 2>/dev/null)
cp_tainted=$(echo "$nodes_json" | jq '[.items[] | select((.spec.taints // [])
    | map(select(.key=="node-role.kubernetes.io/control-plane")) | length > 0)] | length')
unhealthy=$(echo "$nodes_json" | jq -r '[.items[] | select((.spec.taints // [])
    | map(select(.effect=="NoSchedule" and (.key | startswith("node.kubernetes.io/") or startswith("node.cilium.io/"))))
    | length > 0) | .metadata.name] | join(", ")')
schedulable=$(echo "$nodes_json" | jq '[.items[] | select((.spec.taints // [])
    | map(select(.effect=="NoSchedule")) | length == 0)] | length')

if [ "${schedulable:-0}" -ge 3 ]; then
    pass "$schedulable schedulable nodes (Longhorn needs 3 for its replica count)"
else
    fail "only ${schedulable:-0} schedulable nodes — three-replica volumes will not place"
    [ "${cp_tainted:-0}" -gt 0 ] && \
        echo "       $cp_tainted still carry the control-plane taint; set untaint_control_planes and re-run make bootstrap"
    [ -n "$unhealthy" ] && \
        echo "       unhealthy (not a config problem): $unhealthy"
fi

### 2. the platform is installed
kubectl get storageclass 2>/dev/null | grep -q '(default)' \
    && pass "a default StorageClass exists" \
    || fail "no default StorageClass — Longhorn did not install, or is not marked default"

if kubectl get gatewayclass envoy >/dev/null 2>&1; then
    acc=$(kubectl get gatewayclass envoy -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' 2>/dev/null)
    [ "$acc" = "True" ] \
        && pass "GatewayClass envoy is Accepted" \
        || fail "GatewayClass envoy exists but Accepted=$acc — the Envoy Gateway controller is not running"
else
    fail "GatewayClass envoy missing — run make gateway"
fi

kubectl get ingressclass -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | grep -q nginx \
    && pass "IngressClass nginx exists" \
    || fail "no nginx IngressClass — run make ingress"

kubectl create ns "$ns" >/dev/null

### 3. MetalLB hands out an address from the declared pool
kubectl -n "$ns" create deployment lb --image=nginx:alpine >/dev/null
kubectl -n "$ns" expose deployment lb --port=80 --type=LoadBalancer >/dev/null
ip=""
for _ in $(seq 1 45); do
    ip=$(kubectl -n "$ns" get svc lb -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
    [ -n "$ip" ] && break
    sleep 2
done
if [ -z "$ip" ]; then
    fail "no external IP after 90s — MetalLB is not running, or its pool is exhausted"
elif python3 -c "
import ipaddress, sys
lo, hi = '$pool'.split('-')
sys.exit(0 if ipaddress.ip_address(lo) <= ipaddress.ip_address('$ip') <= ipaddress.ip_address(hi) else 1)"; then
    pass "LoadBalancer got $ip, inside metallb_pool"
else
    fail "LoadBalancer got $ip, which is outside metallb_pool ($pool)"
fi

### 4. data written on one node is readable from another
kubectl -n "$ns" apply -f - >/dev/null <<YAML
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: data
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 1Gi
YAML
kubectl -n "$ns" apply -f - >/dev/null <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: writer
spec:
  restartPolicy: Never
  containers:
    - name: writer
      image: busybox:1.36
      command: ["sh", "-c", "echo persisted-by-writer > /data/f && sleep 3600"]
      volumeMounts:
        - { name: d, mountPath: /data }
  volumes:
    - name: d
      persistentVolumeClaim:
        claimName: data
YAML
if ! kubectl -n "$ns" wait --for=condition=Ready pod/writer --timeout=300s >/dev/null 2>&1; then
    fail "the writer pod never became Ready — the PVC did not bind; check longhorn-system"
    echo; echo "$failed check(s) failed"; exit 1
fi
node1=$(kubectl -n "$ns" get pod writer -o jsonpath='{.spec.nodeName}')
pass "PVC bound and mounted on $node1"

kubectl -n "$ns" delete pod writer --wait=true >/dev/null
other=$(kubectl get nodes -o json \
    | jq -r --arg n "$node1" '[.items[] | select(.metadata.name != $n)
        | select((.spec.taints // []) | map(select(.effect=="NoSchedule")) | length == 0)
        | .metadata.name] | first // empty')
if [ -z "$other" ]; then
    fail "no second schedulable node to move the volume to"
else
    kubectl -n "$ns" apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: reader
spec:
  nodeSelector:
    kubernetes.io/hostname: "$other"
  restartPolicy: Never
  containers:
    - name: reader
      image: busybox:1.36
      command: ["sh", "-c", "cat /data/f"]
      volumeMounts:
        - { name: d, mountPath: /data }
  volumes:
    - name: d
      persistentVolumeClaim:
        claimName: data
YAML
    for _ in $(seq 1 90); do
        phase=$(kubectl -n "$ns" get pod reader -o jsonpath='{.status.phase}' 2>/dev/null || true)
        [ "$phase" = Succeeded ] || [ "$phase" = Failed ] && break
        sleep 2
    done
    if [ "$(kubectl -n "$ns" logs reader 2>/dev/null | tr -d '\r\n')" = "persisted-by-writer" ]; then
        pass "the same data read back on $other — replication works"
    else
        fail "could not read the data from $other; the volume did not follow the pod"
    fi
fi

echo
if [ "$failed" -eq 0 ]; then
    echo "All checks passed. The cluster is ready to hand off."
else
    echo "$failed check(s) failed."
    exit 1
fi
