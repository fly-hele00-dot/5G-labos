#!/usr/bin/env bash
# Streams a live packet capture from one or more docker containers (kind
# nodes, or any other docker service) straight into a single local
# Wireshark window. Each node is a distinct capture source in Wireshark
# (visible/colorable by "Interface" column), all merged into one session.
#
# Why per-node, not per-pod: kind nodes ARE the docker containers; every
# free5GC NF pod's traffic (SBI over the pod network, and N2/N3/N4/N6/N9
# over ipvlan sub-interfaces on the node's eth0) is visible from "-i any"
# on whichever node that pod is scheduled to. If NFs are spread across
# multiple worker nodes, capture on all of them at once.
#
# Usage:
#   ./scripts/06-wireshark-live.sh                       # pick from a menu
#   ./scripts/06-wireshark-live.sh corelab-worker           # one node
#   ./scripts/06-wireshark-live.sh corelab-worker corelab-worker2   # multiple nodes
#   ./scripts/06-wireshark-live.sh --all-kind             # every kind node in the corelab cluster
#   FILTER='sctp or port 8805 or port 2152' ./scripts/06-wireshark-live.sh corelab-worker
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
WORKDIR="$(mktemp -d)"
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$WORKDIR"' EXIT

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

WIRESHARK_ARGS=()
for NODE in "${NODES[@]}"; do
  if ! docker exec "$NODE" which tcpdump >/dev/null 2>&1; then
    echo "Installing tcpdump in $NODE (persists only until that container is recreated)..."
    docker exec "$NODE" bash -c "apt-get update -qq && apt-get install -y -qq tcpdump" >/dev/null
  fi
  FIFO="$WORKDIR/$NODE.fifo"
  mkfifo "$FIFO"
  echo "Capturing on: $NODE"
  docker exec "$NODE" tcpdump -i any -U -w - ${FILTER:+"$FILTER"} > "$FIFO" 2>"$WORKDIR/$NODE.err" &
  WIRESHARK_ARGS+=(-i "$FIFO")
done

echo "Opening Wireshark with ${#NODES[@]} capture source(s). Close the window to stop."
wireshark -k "${WIRESHARK_ARGS[@]}"
