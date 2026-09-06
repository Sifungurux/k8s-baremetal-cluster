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
# Layer 2, not BGP: the rack is a single VLAN with no router peering, and L2
# needs nothing from the network the way BGP would.
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: rack-l2
  namespace: metallb-system
spec:
  ipAddressPools:
    - rack-pool
