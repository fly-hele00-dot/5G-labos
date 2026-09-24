#!/usr/bin/env bash
# Port-forwards Grafana, Prometheus and the free5GC WebUI to 127.0.0.1 only
# (explicit --address, never 0.0.0.0) -- none of these services is exposed
# any other way. Runs in the foreground -- Ctrl-C stops all forwards cleanly.
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

GRAFANA_PORT="${GRAFANA_PORT:-3000}"
PROMETHEUS_PORT="${PROMETHEUS_PORT:-9090}"
WEBUI_PORT="${WEBUI_PORT:-5000}"

cleanup() {
  echo
  echo "Stopping port-forwards..."
  kill "${GRAFANA_PID:-}" "${PROM_PID:-}" "${WEBUI_PID:-}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

kubectl -n monitoring port-forward --address 127.0.0.1 svc/grafana "${GRAFANA_PORT}:3000" >/tmp/grafana-port-forward.log 2>&1 &
GRAFANA_PID=$!
kubectl -n monitoring port-forward --address 127.0.0.1 svc/prometheus "${PROMETHEUS_PORT}:9090" >/tmp/prometheus-port-forward.log 2>&1 &
PROM_PID=$!
kubectl -n core port-forward --address 127.0.0.1 svc/webui-service "${WEBUI_PORT}:5000" >/tmp/webui-port-forward.log 2>&1 &
WEBUI_PID=$!

sleep 2
if ! kill -0 "$GRAFANA_PID" 2>/dev/null; then
  echo "ERROR: Grafana port-forward failed to start:" >&2
  cat /tmp/grafana-port-forward.log >&2
  exit 1
fi

echo "Grafana:    http://127.0.0.1:${GRAFANA_PORT}/d/5g-core-lab  (anonymous viewer access, no login needed)"
echo "Prometheus: http://127.0.0.1:${PROMETHEUS_PORT}"
echo "WebUI:      http://127.0.0.1:${WEBUI_PORT}  (admin / free5gc)"
echo
echo "Press Ctrl-C to stop."
wait
