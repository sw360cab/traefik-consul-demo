#!/bin/sh
# Run remotely with -> source <(curl -s http://<remote-address-of-this-script>.sh)

set -e

# Run as su
if [ `id -u` -ne 0 ]
then
  echo "You need to be root to run this script"
  exit 1
fi

apt update && apt install -y apt-transport-https ca-certificates curl gnupg lsb-release

# Install K3S
curl -sfL https://get.k3s.io | sh -
# Change permission to Rancher file
chmod 775 /etc/rancher/k3s/k3s.yaml

# Install Helm
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash -