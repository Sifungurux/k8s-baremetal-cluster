#!/bin/sh
# Runs once on first boot, from k8s-node-prep.service.
# Prepares this node for kubeadm by running the repo's own prep playbook
# locally. Leaves the sentinel behind only on success, so a failed or
# network-starved run is retried on the next boot instead of being skipped.
set -eu

REPO=/opt/k8s-baremetal-cluster
SENTINEL=/var/lib/k8s-node-prep.done
HOST=$(hostname -s)

cd "$REPO"
export ANSIBLE_CONFIG="$REPO/ansible.cfg"

# network-online.target only promises the interface is configured, not that DNS
# answers, and everything below (Galaxy, the apt repos, pkgs.k8s.io) needs names.
# Wait for resolution rather than failing the run, and give a node with no
# network at all a clear message instead of a Galaxy stack trace.
waited=0
while ! getent hosts deb.debian.org >/dev/null 2>&1; do
    waited=$((waited + 5))
    if [ "$waited" -ge 300 ]; then
        echo "k8s-node-prep: no DNS after ${waited}s — check the node's network." >&2
        exit 1
    fi
    sleep 5
done

# ansible-playbook --limit with a name that is not in the inventory prints
# "no hosts matched" and exits 0 — which would leave the node unprepped while
# looking like a clean install. Check membership before running anything.
if ! ansible-inventory -i inventory/hosts.yml --list \
    | python3 -c 'import json,sys; sys.exit(0 if sys.argv[1] in json.load(sys.stdin)["_meta"]["hostvars"] else 1)' "$HOST"
then
    echo "k8s-node-prep: '$HOST' is not a host in inventory/hosts.yml — nothing to do." >&2
    echo "k8s-node-prep: set the hostname to an inventory name and re-run: systemctl start k8s-node-prep" >&2
    exit 1
fi

ansible-galaxy collection install -r requirements.yml
ansible-playbook -i inventory/hosts.yml -c local -l "$HOST" playbooks/prep.yml

# prep.yml is what installs and configures containerd; if it is not running,
# the play reported success without doing the work.
systemctl is-active --quiet containerd

touch "$SENTINEL"
echo "k8s-node-prep: $HOST is ready for kubeadm."
