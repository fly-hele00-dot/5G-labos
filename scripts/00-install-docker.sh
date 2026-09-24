#!/usr/bin/env bash
# Installs Docker Engine and adds the current user to the docker group.
# Must be run with sudo access (interactive password). Run this yourself:
#   ./scripts/00-install-docker.sh
set -euo pipefail

if command -v docker >/dev/null 2>&1; then
  echo "Docker already installed: $(docker --version)"
else
  sudo apt update
  sudo apt install -y docker.io
  sudo systemctl enable --now docker
fi

if ! groups "$USER" | grep -qw docker; then
  sudo usermod -aG docker "$USER"
  echo
  echo "Added $USER to the docker group."
  echo "You must log out/in (or run 'newgrp docker') before docker works without sudo."
else
  echo "$USER already in docker group."
fi
