# Traefik Proxy + Consul Connect: DEMO

This is a demo that shows the integrations between Traefik Proxy and Consul Connect.

## Prerequisites

* K8s
* Helm

## Install a cluster

* Using [Kind](https://kind.sigs.k8s.io)

      kind create cluster --config=kind.yaml

* Using [K3s](https://rancher.com/docs/k3s/latest/en/)

      sh cluset.sh

## Install Consul

    sh k8s/helm/consul-install.sh

## Install Traefik

    sh k8s/traefik/traefik-install.sh

### Note

Exposing the service to the outside of the host/network is always tricky.

* when using `Kind` I suggest playing with ports (check `extraPortMapping` in [kind.yaml](kind.yaml)
and `nodePort` in service in [k8s/traefik/traefik.yaml](k8s/traefik/traefik.yaml))
* when using `K3s` I would play with port forwarding (remeber the parameter `--address 0.0.0.0`)

## Install a service visible both in Consul Connect and in Traefik Proxy

    kubectl create -f k8s/whoami.yaml

Then from the Consul UI you can play with `Intentions` between `Traefik Proxy` and the _whoami_ service

`Tip`: expose Consul UI like this

    kubectl port-forward --address 0.0.0.0 --namespace consul-system service/consul-ui 18500:443
