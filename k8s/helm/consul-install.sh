#!/bin/sh
# Install Helm repos
# helm repo add traefik https://helm.traefik.io/traefik
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update

kubectl create namespace consul-system

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
helm upgrade --install -f consul-values.yaml \
  consul hashicorp/consul --namespace consul-system

# kubectl get secret consul-ca-cert -n consul-system -oyaml | \
#   sed 's/namespace: consul-system$/namespace: traefik-consul/' | \
#   kubectl apply -f -