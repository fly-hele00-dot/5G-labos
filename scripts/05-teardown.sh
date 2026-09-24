#!/usr/bin/env bash
# Tears down the kind cluster (everything inside it goes with it: free5GC,
# UERANSIM, mongodb data, etc). Does NOT remove the gtp5g kernel module or
# docker itself.
set -euo pipefail

# Belt-and-braces: make kind resolve even if the calling shell's PATH
# doesn't have ~/.local/bin on it.

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

kind delete cluster --name corelab

# Remove the dedicated node network created by 02-create-kind-cluster.sh.
docker network rm corelab-net 2>/dev/null || true
