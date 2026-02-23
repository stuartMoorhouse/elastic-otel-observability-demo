#!/usr/bin/env bash
# Thin userdata script — installs Podman + podman-compose.
# Application deployment is handled separately via Terraform provisioners.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

apt-get update -y
apt-get install -y podman podman-compose

# Enable Podman socket for the ubuntu user (rootless)
loginctl enable-linger ubuntu
sudo -u ubuntu systemctl --user enable podman.socket
sudo -u ubuntu systemctl --user start podman.socket
