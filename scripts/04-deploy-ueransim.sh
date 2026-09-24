#!/usr/bin/env bash
# Deploys UERANSIM (simulated gNB + UE) into the same namespace as free5GC
# and runs the built-in connectivity test (registration -> PDU session ->
# ping through the UPF).
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
CHART_DIR="$LAB_DIR/charts/towards5gs-helm/charts/ueransim"
NAMESPACE="core"
RELEASE="ran"

echo "== Provisioning the default test subscriber (imsi-208930000000003) =="
DB_PYTHON_POD=$(kubectl get po --namespace "$NAMESPACE" -o name -l nf=dbpython)
# add_subscribers.py defaults --imsi to 999700000000001 and overwrites every
# ueId with it, so the IMSI must be passed explicitly to match the UERANSIM
# UE (charts/.../ueransim/values.yaml -> ue.configuration.supi). `clean`
# first keeps re-runs idempotent (no duplicate subscriber documents).
SUBSCRIBER_IMSI="imsi-208930000000003"
kubectl --namespace "$NAMESPACE" exec "${DB_PYTHON_POD#pod/}" -- python3 add_subscribers.py -a clean
kubectl --namespace "$NAMESPACE" exec "${DB_PYTHON_POD#pod/}" -- python3 add_subscribers.py -a add -i "$SUBSCRIBER_IMSI"

# The dbpython image bundles free5GC v3.2.1-era add_subscribers.py, which
# writes the OLD authenticationSubscription schema (nested
# milenage/opc/permanentKey objects, bare sequenceNumber string). The
# current official UDM/UDR (v4.2.3, see 03-deploy-free5gc.sh) require the
# 3GPP TS 29.504 shape instead: flat encPermanentKey/encOpcKey hex strings
# and a structured sequenceNumber. Migrate it in place rather than rebuilding
# that image.
echo "== Migrating subscriber auth data to the current UDM/UDR schema =="
MONGO_POD=$(kubectl get pod --namespace "$NAMESPACE" -l app.kubernetes.io/name=mongodb -o jsonpath='{.items[0].metadata.name}')
kubectl --namespace "$NAMESPACE" exec -i "$MONGO_POD" -- mongo free5gc --quiet --eval '
db.getCollection("subscriptionData.authenticationData.authenticationSubscription").updateOne(
  {ueId: "'"$SUBSCRIBER_IMSI"'"},
  {
    $set: {
      encPermanentKey: "8baf473f2f8fd09487cccbd7097c6862",
      encOpcKey: "8e27b6af0e692e750f32667a3b14605d",
      sequenceNumber: {sqn: "16f3b3f70fc2", sqnScheme: "NON_TIME_BASED", lastIndexes: {}, indLength: NumberInt(5), difSign: "POSITIVE"}
    },
    $unset: { permanentKey: "", opc: "", milenage: "" }
  }
)'

echo "== Installing UERANSIM (release: $RELEASE) =="
# fullnameOverride keeps pod names short and neutral (ran-gnb-*, ran-ue-*)
# instead of the chart's default <release>-ueransim-* naming.
helm -n "$NAMESPACE" upgrade --install "$RELEASE" "$CHART_DIR" \
  --set fullnameOverride="$RELEASE" \
  --timeout 5m --wait

echo "== Pods =="
kubectl -n "$NAMESPACE" get pods -l "component in (gnb,ue)" -o wide

POD_NAME=$(kubectl get pods --namespace "$NAMESPACE" -l "component=ue" -o jsonpath="{.items[0].metadata.name}")
echo "== UE pod: $POD_NAME =="

echo "== UE logs (looking for PDU session establishment) =="
kubectl --namespace "$NAMESPACE" logs "$POD_NAME" | tail -40

echo "== UE interfaces =="
kubectl --namespace "$NAMESPACE" exec -it "$POD_NAME" -- ip address

echo
echo "If uesimtun0 is up, try from inside this script's shell:"
echo "  kubectl --namespace $NAMESPACE exec -it $POD_NAME -- ping -I uesimtun0 -c4 8.8.8.8"
echo
echo "Or run the packaged helm test:"
echo "  helm --namespace $NAMESPACE test $RELEASE"
