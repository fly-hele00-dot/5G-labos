#!/usr/bin/env bash
# Builds and installs the gtp5g kernel module on the HOST.
# free5GC's UPF uses this module to create/manage GTP-U tunnels for the
# user-plane (N3/N9). Without it, PDU sessions and UE data traffic through
# the UPF will not work, even though control-plane signaling (registration,
# AMF<->SMF, etc.) would still succeed.
#
# Needs sudo (kernel module build/install). Run this yourself:
#   ./scripts/01-install-gtp5g.sh
set -euo pipefail

# towards5gs-helm's bundled free5gc-upf image only accepts gtp5g 0.8.1<=v<0.9.0,
# and that old gtp5g line does not build cleanly against modern kernels
# (removed NETIF_F_LLTX flag, reworked rtnl_link_ops.newlink signature) without
# hand-patching. Instead, the lab uses current gtp5g + the current official
# free5gc/upf image (see scripts/03-deploy-free5gc.sh).
#
# Track the `master` branch (this repo's default branch), NOT the latest
# release tag (currently v0.10.2): v0.10.2 still uses the removed
# `flowi4_tos` struct field (this kernel's headers renamed it to
# `flowi4_dscp`), and that fix has landed on master but not been cut into a
# tag yet. This sacrifices some reproducibility (a future master commit
# could break something else) -- if this ever fails, check
# https://github.com/free5gc/gtp5g/tags for a newer release that includes
# the fix and pin that instead.
GTP5G_VERSION="master"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

if lsmod | grep -q '^gtp5g'; then
  echo "Removing existing gtp5g module before (re)install..."
  sudo rmmod gtp5g || true
fi

echo "Building gtp5g $GTP5G_VERSION kernel module for kernel $(uname -r)..."
git clone --depth 1 --branch "$GTP5G_VERSION" https://github.com/free5gc/gtp5g.git "$WORKDIR/gtp5g"
cd "$WORKDIR/gtp5g"
make clean || true
make
sudo make install
sudo depmod -a
sudo modprobe gtp5g

echo
echo "gtp5g module status:"
lsmod | grep gtp5g || echo "WARNING: gtp5g not showing in lsmod"
modinfo gtp5g | head -5
