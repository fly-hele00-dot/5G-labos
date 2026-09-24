#!/usr/bin/env bash
# Deploys Prometheus + kube-state-metrics + Grafana into the `monitoring`
# namespace, and re-applies the free5gc chart so AMF's Prometheus metrics
# endpoint (enabled in amf-configmap.yaml) actually comes up.
#
# What you get:
#  - AMF PDU session / GMM-state / CM-state metrics (the only free5GC NF in
#    this stack with built-in Prometheus support -- see the comment in
#    charts/.../free5gc-amf/templates/amf-configmap.yaml)
#  - Kubernetes node/pod health (Ready status, restarts) via kube-state-metrics
#  - Per-node CPU/memory via kubelet cAdvisor
#  - A pre-built Grafana dashboard (monitoring/dashboard-5g-lab.json)
set -euo pipefail

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
MON_DIR="$LAB_DIR/monitoring"

echo "== Re-deploying free5GC so AMF picks up its metrics config =="
"$SCRIPT_DIR/03-deploy-free5gc.sh" >/dev/null
echo "  (AMF redeployed if its config changed; see 03-deploy-free5gc.sh output above if you ran it separately)"

echo "== Applying monitoring namespace + RBAC + kube-state-metrics + Prometheus =="
kubectl apply -f "$MON_DIR/00-namespace.yaml"
kubectl apply -f "$MON_DIR/01-kube-state-metrics.yaml"
kubectl apply -f "$MON_DIR/02-prometheus-rbac.yaml"
kubectl apply -f "$MON_DIR/03-prometheus-config.yaml"
kubectl apply -f "$MON_DIR/04-prometheus.yaml"

echo "== Applying Grafana (datasource, dashboard, deployment) =="
kubectl apply -f "$MON_DIR/05-grafana-datasource.yaml"
kubectl apply -f "$MON_DIR/06-grafana-dashboard-provider.yaml"
kubectl -n monitoring create configmap grafana-dashboard-json \
  --from-file=5g-lab.json="$MON_DIR/dashboard-5g-lab.json" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "$MON_DIR/07-grafana.yaml"

echo "== Restarting Prometheus/Grafana to pick up any config changes =="
kubectl -n monitoring rollout restart deployment/prometheus deployment/grafana >/dev/null

echo "== Waiting for monitoring pods to be ready =="
kubectl -n monitoring rollout status deployment/kube-state-metrics --timeout=120s
kubectl -n monitoring rollout status deployment/prometheus --timeout=120s
kubectl -n monitoring rollout status deployment/grafana --timeout=120s

echo "== Pods =="
kubectl -n monitoring get pods -o wide

echo
echo "Done. Start the local port-forwards with:"
echo "  ./scripts/09-open-grafana.sh"
