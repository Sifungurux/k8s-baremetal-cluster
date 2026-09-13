---
# __METALLB_POOL__ is substituted by the Makefile from metallb_pool in
# group_vars, so the range is declared once and preflight can check it against
# rack_subnet, the control-plane VIP, pod_cidr and service_cidr.
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: rack-pool
  namespace: metallb-system
spec:
  addresses:
    - "__METALLB_POOL__"
---
# autoAssign false is the whole point: MetalLB never allocates from this pool on
# its own, so an address in it stays free until a Service asks for it by name
# with metallb.io/loadBalancerIPs. That is what makes a DNS record safe to write
# against it — see metallb_named_pool in group_vars.
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: rack-named
  namespace: metallb-system
spec:
  autoAssign: false
  addresses:
    - "__METALLB_NAMED_POOL__"
---
# Layer 2, not BGP: the rack is a single VLAN with no router peering, and L2
# needs nothing from the network the way BGP would.
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: rack-l2
  namespace: metallb-system
spec:
  # Both pools: an address is useless unless something ARPs for it on the VLAN,
  # and a pool left out here is advertised by nobody.
  ipAddressPools:
    - rack-pool
    - rack-named
