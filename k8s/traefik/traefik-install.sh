#!/bin/sh

# Copy Consul Root CA
kubectl get secret consul-ca-cert -n consul-system -oyaml | \
  sed 's/namespace: consul-system$/namespace: traefik-consul/' | \
  kubectl apply -f -

kubectl create -f rbac.yaml
kubectl create -f traefik.yaml
