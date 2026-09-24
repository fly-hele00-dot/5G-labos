#!/usr/bin/env bash
# Creates the kind cluster (1 control-plane + 1 worker) for the 5G lab,
# installs the standard CNI plugin binaries into each node (kind ships
# without them), and installs Multus CNI so free5GC's N2/N3/N4/N6 network
# attachments can be created.
#
# Requires: docker usable without sudo (run 00-install-docker.sh and
# re-login first), kind/kubectl/helm on PATH.
set -euo pipefail

# Belt-and-braces: make kubectl/kind/helm resolve even if the calling
# shell's PATH doesn't have ~/.local/bin on it.

# Resolve the real (non-root) user's home even when invoked via sudo --
# sudo resets $HOME to /root, which would otherwise point PATH/KUBECONFIG
# at /root/.local/bin and /root/.kube/config instead of where
# kubectl/kind/helm and the kind cluster's kubeconfig actually live.
REAL_HOME="$HOME"
if [ -n "${SUDO_USER:-}" ]; then
  REAL_HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
fi
export PATH="$REAL_HOME/.local/bin:$PATH"
export KUBECONFIG="${KUBECONFIG:-$REAL_HOME/.kube/config}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(dirname "$SCRIPT_DIR")"
CLUSTER_NAME="corelab"

# Dedicated docker network for the kind nodes instead of kind's default
# `kind` network (172.18.0.0/16 on most hosts). Docker only hands out
# addresses from the lower half (--ip-range .0/25), leaving .128-.254 free
# for static ipvlan addresses such as the UPF's N6 IP (.200, see
# 03-deploy-free5gc.sh). host_binding_ipv4=127.0.0.1 makes any port ever
# published from this network bind to loopback only, never a LAN interface.
DOCKER_NET="corelab-net"
DOCKER_SUBNET="172.29.40.0/24"
DOCKER_IP_RANGE="172.29.40.0/25"
DOCKER_GATEWAY="172.29.40.1"

if ! docker ps >/dev/null 2>&1; then
  echo "ERROR: docker not usable (not installed, daemon down, or you need to re-login" >&2
  echo "       after being added to the docker group). Run scripts/00-install-docker.sh first." >&2
  exit 1
fi

echo "== Creating docker network '$DOCKER_NET' ($DOCKER_SUBNET) =="
if ! docker network inspect "$DOCKER_NET" >/dev/null 2>&1; then
  docker network create "$DOCKER_NET" \
    --driver bridge \
    --subnet "$DOCKER_SUBNET" \
    --ip-range "$DOCKER_IP_RANGE" \
    --gateway "$DOCKER_GATEWAY" \
    --opt com.docker.network.bridge.enable_ip_masquerade=true \
    --opt com.docker.network.bridge.host_binding_ipv4=127.0.0.1 \
    --opt com.docker.network.driver.mtu=1500
fi
export KIND_EXPERIMENTAL_DOCKER_NETWORK="$DOCKER_NET"

echo "== Creating kind cluster '$CLUSTER_NAME' =="
kind create cluster --config "$LAB_DIR/cluster/kind-cluster.yaml"

echo "== Installing CNI plugin binaries into kind nodes =="
CNI_VERSION="v1.5.1"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
curl -sSL -o "$WORKDIR/cni-plugins.tgz" \
  "https://github.com/containernetworking/plugins/releases/download/${CNI_VERSION}/cni-plugins-linux-amd64-${CNI_VERSION}.tgz"
mkdir -p "$WORKDIR/cni-bin"
tar -xzf "$WORKDIR/cni-plugins.tgz" -C "$WORKDIR/cni-bin"

for node in $(kind get nodes --name "$CLUSTER_NAME"); do
  echo "  copying CNI plugins into $node"
  docker exec "$node" mkdir -p /opt/cni/bin
  docker cp "$WORKDIR/cni-bin/." "$node:/opt/cni/bin/"
done

echo "== Installing Multus CNI =="
kubectl apply -f https://raw.githubusercontent.com/k8snetworkplumbingwg/multus-cni/master/deployments/multus-daemonset-thick.yml

echo "== Waiting for multus daemonset to be ready =="
kubectl -n kube-system rollout status daemonset/kube-multus-ds --timeout=180s

echo "== Cluster nodes =="
kubectl get nodes -o wide

echo
echo "Done. Nodes are on $DOCKER_NET ($DOCKER_SUBNET); 03-deploy-free5gc.sh"
echo "reads that subnet to configure free5GC's N6 network."
