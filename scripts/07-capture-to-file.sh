#!/usr/bin/env bash
# Captures traffic on one or more docker containers (kind nodes, or any
# other docker service) to .pcap file(s), for inspecting later in Wireshark
# -- e.g. capture across a full UE registration / PDU session test, then
# analyze afterwards. Multiple nodes are merged (by timestamp) into one file.
#
# Usage:
#   ./scripts/07-capture-to-file.sh                          # pick from a menu, Ctrl-C to stop
#   ./scripts/07-capture-to-file.sh corelab-worker
#   ./scripts/07-capture-to-file.sh corelab-worker corelab-worker2
#   ./scripts/07-capture-to-file.sh --all-kind
#   FILTER='sctp or port 8805' ./scripts/07-capture-to-file.sh corelab-worker
set -euo pipefail

# Belt-and-braces: make kind resolve even if the calling shell's PATH
# doesn't have ~/.local/bin on it.

# Resolve the real (non-root) user's home even when invoked via sudo --
# sudo resets $HOME to /root, which would otherwise point PATH at
# /root/.local/bin instead of where kind actually lives.
REAL_HOME="$HOME"
if [ -n "${SUDO_USER:-}" ]; then
  REAL_HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
fi
export PATH="$REAL_HOME/.local/bin:$PATH"

if ! docker ps >/dev/null 2>&1; then
  echo "ERROR: can't talk to docker (permission denied or docker not running)." >&2
  echo "If you were just added to the 'docker' group, that needs a new login" >&2
  echo "session to take effect -- open a new terminal, or run: newgrp docker" >&2
  exit 1
fi

FILTER="${FILTER:-}"
LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STAMP="$(date +%Y%m%d-%H%M%S)"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

list_kind_nodes() {
  kind get nodes --name corelab 2>/dev/null || true
}

NODES=()
if [ "${1:-}" = "--all-kind" ]; then
  mapfile -t NODES < <(list_kind_nodes)
elif [ "$#" -ge 1 ]; then
  NODES=("$@")
else
  echo "Available kind nodes (corelab cluster):"
  mapfile -t KIND_NODES < <(list_kind_nodes)
  echo "Other running docker containers:"
  OTHER=$(docker ps --format '{{.Names}}' | grep -vFf <(printf '%s\n' "${KIND_NODES[@]}") || true)
  i=1
  ALL_OPTIONS=("${KIND_NODES[@]}")
  for n in "${KIND_NODES[@]}"; do echo "  $i) $n [kind node]"; i=$((i+1)); done
  for n in $OTHER; do echo "  $i) $n"; ALL_OPTIONS+=("$n"); i=$((i+1)); done
  if [ "${#ALL_OPTIONS[@]}" -eq 0 ]; then
    echo "ERROR: no kind nodes or docker containers found to capture on." >&2
    exit 1
  fi
  read -rp "Select node number(s), space-separated (e.g. '1' or '1 2'): " -a picks
  for p in "${picks[@]}"; do
    if ! [[ "$p" =~ ^[0-9]+$ ]] || [ "$p" -lt 1 ] || [ "$p" -gt "${#ALL_OPTIONS[@]}" ]; then
      echo "ERROR: '$p' is not a valid choice (1-${#ALL_OPTIONS[@]})." >&2
      exit 1
    fi
    NODES+=("${ALL_OPTIONS[$((p-1))]}")
  done
fi

if [ "${#NODES[@]}" -eq 0 ]; then
  echo "No nodes selected." >&2
  exit 1
fi

PIDS=()
PER_NODE_FILES=()
for NODE in "${NODES[@]}"; do
  if ! docker exec "$NODE" which tcpdump >/dev/null 2>&1; then
    echo "Installing tcpdump in $NODE (persists only until that container is recreated)..."
    docker exec "$NODE" bash -c "apt-get update -qq && apt-get install -y -qq tcpdump" >/dev/null
  fi
  echo "Capturing on: $NODE"
  docker exec "$NODE" rm -f /tmp/capture.pcap
  docker exec -t "$NODE" tcpdump -i any -w /tmp/capture.pcap ${FILTER:+"$FILTER"} &
  PIDS+=($!)
  PER_NODE_FILES+=("$NODE")
done

echo "Capturing on ${#NODES[@]} node(s). Press Ctrl-C to stop."
trap 'true' INT  # let the wait below catch it instead of killing us immediately
wait "${PIDS[@]}" 2>/dev/null || true

echo "Copying captures out and merging..."
LOCAL_FILES=()
for NODE in "${PER_NODE_FILES[@]}"; do
  LOCAL="$WORKDIR/$NODE.pcap"
  docker cp "$NODE:/tmp/capture.pcap" "$LOCAL" 2>/dev/null && LOCAL_FILES+=("$LOCAL")
done

OUT_LOCAL="$LAB_DIR/cluster/capture-$STAMP.pcap"
if [ "${#LOCAL_FILES[@]}" -eq 1 ]; then
  cp "${LOCAL_FILES[0]}" "$OUT_LOCAL"
elif [ "${#LOCAL_FILES[@]}" -gt 1 ]; then
  mergecap -w "$OUT_LOCAL" "${LOCAL_FILES[@]}"
else
  echo "No captures were produced." >&2
  exit 1
fi

echo "Saved to: $OUT_LOCAL"
echo "Open with: wireshark \"$OUT_LOCAL\""
