# Traefik 2.5 - What a Mesh&excl;

`Disclaimer`: This post is freely inspired by an Official Traefik Labs blog [post](https://traefik.io/blog/integrating-consul-connect-service-mesh-with-traefik-2-5/).
I took some part and adapted to achieve a simpler working example (in my humble opinion).

Few weeks ago Traefik Labs announced the new release of Traefik Proxy, now at version 2.5.
Many features have been shipped:

- HTTP/3
- Private & Provider Plugins
- Load Balancer Healthchecks
- Kubernetes 1.22 support
- TCP Middleware
- Consul Connect integration

The latter is one of the most interesting newcomers. Service Mesh is always an important challenge when dealing with quite large distributed architectures.

Among Traefik Labs products there is already [Traefik Mesh](https://traefik.io/traefik-mesh/), a lightweight Service Mesh, not invasive built on top of Traefik Proxy. These peculiarities are achieved by leaving the "Sidecar Pattern" in favour of a "DaemonSet Pattern", so a per-node instead of a per-pod design pattern.
Using a `DaemonSet` in this context brings along a shortcoming (that Traefik Labs has never hidden), `mTLS` communication among services is not available and it should be implemented by application itself, for example using Traefik Mesh at TCP level only.

Consul by `HashiCorp` is one of the reference solutions when talking about Service Mesh. Indeed it leverages the Sidecar pattern and offers mTLS communication.

## What really is Service Mesh?

Let's take a step back on service mesh.
Service Mesh is intended as a network layer in the cluster that allows fast and reliable communication among services and applications within the cluster itself.

Service mesh is based on this concepts:

- `Discoverability` - services need to discover each other, in order to be able to talk together.
- `Configurability` - services need to be configured. There should be an abstraction layer for network (no need to know by applications)
- `Segmentation` - services need fine-grained access control between them, to ensure that only specific sets of services should be able to communicate with each other. In a few words traffic control.

That said, how do Consul components deal with all these concepts?

- [Consul Catalog](https://www.consul.io/api-docs/catalog) registers all of your services into a directory. They will be discoverable throughout all the network [*Service Discoverability*]
- [Consul Connect](https://www.consul.io/docs/connect) is a proxy layer that routes all service-to-service traffic through an encrypted and authenticated (Mutual TLS) tunnel. [*Abstraction layer*]
- [Consul Intentions](https://www.consul.io/docs/connect/intentions) acts as a service-to-service firewall, and authorization system. Full segmentation can be easily achieved by creating a `Deny all` rule, and then adding each explicit service-to-service connection rule needed. [*Traffic Control*]

As stated before Consul leverages the `Sidecar Pattern`, injecting a sidecar container for each service Pod in the mesh.
This sidecar container is called **Envoy Proxy** and:

- it routes traffic among services pods via other sidecar containers
- it enforces the firewall rules in the mesh network using `Intentions`

The following diagram illustrates how the communication works when to service works:

- target service is discovered via Consul Catalog
- service access is verified and ruled by Consul Intentions
- traffic flows from source service via Envoy Proxy through corresponding Envoy Proxy of target service and finally to the target service itself.

![Envoy Proxy communication](https://learn.hashicorp.com/img/consul/basic-proxy.png)

## Working with Consul Connect in Kubernetes

Let's see how the previous concepts can be applied to Kubernetes. Service registration to Consul Connect can be achieved by adding a simple annotation in Pod Spec:

```yaml
spec:
  replicas: ...
  selector:
    matchLabels:
    ...
  template:
    metadata:
      labels:
        ...
      annotations:
        consul.hashicorp.com/connect-inject: "true"
```

The previous annotation will automatically:

- inject Envoy Proxy as sidecar container
- register a new service in the Consul Catalog

There is another annotation we should take into account.

```yaml  
annotations:
  consul.hashicorp.com/service-sync: "true"
```

We will see next why this is a relevant annotation. But at the moment let's remember that this will exclusively register a service into the Consul Catalog, skipping the Envoy Proxy injection.

## Traefik Proxy 2.5 - Consul Connect integration

After explaining a little bit of Consul let's see how `Traefik Proxy` is integrating Consul Connect.

First of all Traefik Proxy will drop the `Sidecar Proxy` (similarly to Traefik Mesh), instead a Traefik native support to Consul Connect will be in charge.
Eventually, since Traefik Proxy is based on the concept of [Providers](https://doc.traefik.io/traefik/providers/overview/) which enables configuration discovery, the `Consul Catalog provider` will be the one in charge.

Let's now go back for a while at the previous annotations of Consul Connect.
`consul.hashicorp.com/service-sync` is exactly what is useful: it does not inject sidecar Envoy Proxy, but it rather registers the service into the Consul Catalog. So in order to allow Traefik Proxy to be seen by Consul without injecting it with a sidecar container, the previous annotation will be required.

## Hands-On

### Requirements

From here on we will suppose you have:

- a configured and working K8s cluster
- Helm installed and available

All the commands can be found at the following [repository](https://github.com/sw360cab/traefik-consul-demo)

### Consul Connect Configuration

First of all we will leverage `Helm` to install `Consul`.

```bash
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update
```

Here is a list of possible values for the `Consul Helm Chart`:

```yaml
global:
  name: consul
  datacenter: dc1
  image: hashicorp/consul:1.10
  imageEnvoy: envoyproxy/envoy:v1.19-latest
  metrics:
    enabled: true
  tls:
    enabled: true
  #   enableAutoEncrypt: true
  #   verify: true
  #   serverAdditionalDNSSANs:
  #     ## Add the K8s domain name to the consul server certificate
  #     - "consul-server.consul-system.svc.cluster.local"
server:
  # Scale this according to your needs:
  replicas: 1
  affinity: null
ui:
  enabled: true
controller:
  enabled: true  
connectInject:
  # This method will inject the sidecar container into Pods:
  enabled: true
  # But not by default, only do this for Pods that have the explicit annotation:
  #        consul.hashicorp.com/connect-inject: "true"
  default: false
syncCatalog:
  # This method will automatically synchronize Kubernetes services to Consul:
  # (No sidecar is injected by this method):
  enabled: true
  # But not by default, only for Services that have the explicit annotation:
  #        consul.hashicorp.com/service-sync: "true"
  default: false
  # Synchronize from Kubernetes to Consul:
  toConsul: true
  # But not from Consul to K8s:
  toK8S: false
```

_Note_: I explicitly disabled the following section which prevented Consul Helm Chart to be fully bootstrapped:

```yaml
enableAutoEncrypt: true
  verify: true
  serverAdditionalDNSSANs:
    ## Add the K8s domain name to the consul server certificate
    - "consul-server.consul-system.svc.cluster.local"
```

First create a namespace, then run the Helm chart:

```bash
kubectl create namespace consul-system
helm upgrade --install -f consul-values.yaml consul \
  hashicorp/consul --namespace consul-system
```

You can adjust these values as you like BUT remember in order to leverage Traefik Proxy integration, Envoy Proxy should not be enabled by default. So basically the advice here is disabling by default Envoy Proxy Injection and Service Registration in Helm values.

### Traefik Proxy Configuration

Traefik Proxy can also be configured via Helm, but I'd rather configure it explicitly to exploit its simplicity and straightforwardness.

`Important`: Before proceeding remember that Traefik Proxy needs a copy of the Consul certificate authority TLS certificate. Copy the `Secret` resource from the consul namespace into the traefik namespace:

```bash
kubectl get secret consul-ca-cert -n consul-system -oyaml | \
  sed 's/namespace: consul-system$/namespace: traefik-system/' | \
kubectl apply -f -
```

Then remember to mount the secret into the Deployment of Traefik Proxy:

```yaml
volumes:
  - name: consul-ca-cert
    mountPath: "/certs/consul-ca/"
    type: secret
```

The `Traefik Proxy CLI` arguments are those which enable Consul Catalog provider:

```yaml
  ## Consul config: 
  # Enable Traefik to use Consul Connect:
  - "--providers.consulcatalog.connectAware=true" 
  # Traefik routes should only be created for services with explicit `traefik.enable=true` service-tags:
  - "--providers.consulcatalog.exposedByDefault=false"
  # For routes that are exposed (`traefik.enable=true`) use Consul Connect by default:
  - "--providers.consulcatalog.connectByDefault=true"
  # Rename the service inside Consul: `traefik-system-ingress`
  - "--providers.consulcatalog.servicename=traefik-system-ingress"
  # Connect Traefik to the Consul service:
  - "--providers.consulcatalog.endpoint.address=consul-server.<consul_namespace>.svc.cluster.local:8501"
  - "--providers.consulcatalog.endpoint.scheme=https"
  - "--providers.consulcatalog.endpoint.tls.ca=/certs/consul-ca/tls.crt"
```

The cli arguments above include the reference to the Consul CA certificate created via a secret and mounted on a volume.
Moreover as stated above, the service will be _discoverable_ by Consul leveraging annotations:

- only `service-sync` is enabled (not the Envoy Proxy injection)
- there is a correspondence between the `service name` in the annotations and in the Traefik CLI arguments

```yaml
consul.hashicorp.com/service-sync: "true"
consul.hashicorp.com/service-name: "traefik-system-ingress"
```

Here the full Traefik Proxy configuration (Deployment+Service):

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: traefik-ingress-controller
  namespace: traefik-consul
---
kind: Deployment
apiVersion: apps/v1
metadata:
  name: traefik
  namespace: traefik-consul
  labels:
    app: traefik
spec:
  replicas: 1
  selector:
    matchLabels:
      app: traefik
  template:
    metadata:
      labels:
        app: traefik
    spec:
      serviceAccountName: traefik-ingress-controller
      containers:
        - name: traefik
          image: traefik:v2.5
          args:
            - --api.insecure
            - --accesslog
            - --entrypoints.web.address=:80
            - --entrypoints.websecure.address=:443
            # Consul config: 
            # Enable Traefik to use Consul Connect:
            - "--providers.consulcatalog.connectAware=true" 
            # Traefik routes should only be created for services with explicit `traefik.enable=true` service-tags:
            - "--providers.consulcatalog.exposedByDefault=false"
            # For routes that are exposed (`traefik.enable=true`) use Consul Connect by default:
            - "--providers.consulcatalog.connectByDefault=true"
            # Rename the service inside Consul: `traefik-system-ingress`
            - "--providers.consulcatalog.servicename=traefik-system-ingress"
            # Connect Traefik to the Consul service:
            - "--providers.consulcatalog.endpoint.address=consul-server.consul-system.svc.cluster.local:8501"
            - "--providers.consulcatalog.endpoint.scheme=https"
            - "--providers.consulcatalog.endpoint.tls.ca=/certs/consul-ca/tls.crt"
            - "--providers.consulcatalog.endpoint.tls.insecureskipverify=true"
          ports:
            - name: web
              containerPort: 80
            - name: websecure
              containerPort: 443
            - name: admin
              containerPort: 8080
          resources:
            limits:
              cpu: "2"
              memory: "500Mi"
          volumeMounts:
            - name: consul-ca-cert
              mountPath: "/certs/consul-ca/"
              readOnly: true
      volumes:
      - name: consul-ca-cert
        secret:
          secretName: consul-ca-cert
---
apiVersion: v1
kind: Service
metadata:
  name: traefik
  namespace: traefik-consul
  annotations: 
    # Register the service in Consul as `traefik-system-ingress`:
    consul.hashicorp.com/service-sync: "true"
    consul.hashicorp.com/service-name: "traefik-system-ingress"
spec:
  selector:
    app: traefik
  ports:
  - name: web
    protocol: TCP
    nodePort: 30080
    port: 80
    targetPort: 80
  - name: admin
    protocol: TCP
    nodePort: 30808
    port: 8080
    targetPort: 8080
  - name: webtls
    protocol: TCP
    nodePort: 30443
    port: 443
    targetPort: 443
```

If everything works, accessing the Consul UI you should find a service named "traefik-system-ingress" registered via Kubernetes.

`Tip`: in a development environment `Port Forwarding` is an easy and straightforward way to access Consul UI from your own browser

```bash
kubectl port-forward --address 0.0.0.0 --namespace consul-system service/consul-ui 18500:443
```

Then you can access Consul UI at `https://<your host IP>:18500/`

### Configure a service route by adding Consul tags to Services

Let's now add a service to the Consul service Mesh.
From the Consul side the service only needs the Envoy sidecar proxy (remember the annotation: `consul.hashicorp.com/connect-inject: "true"`).
However the same service may be exposed also on the Traefik Proxy side, and here is where the magic happens, and there are two key components:

- the `Consul Catalog provider` from the Traefik domain
- `service tags` annotations from the Consul domain

When using the Consul Catalog provider, Traefik Proxy routes are added by creating service tags in Consul itself. This can be done via the Consul HTTP API, or from the Kubernetes API, by adding an annotation in the Deployment Pod spec: `consul.hashicorp.com/service-tags`.

Following the relevant part:

```yaml
  spec:
    replicas: ...
    selector:
      matchLabels:
      ….
    template:
      metadata:
        labels:
          ...
        annotations:
          consul.hashicorp.com/connect-inject: "true"
          consul.hashicorp.com/service-tags: "\
            traefik.enable=true,\
            traefik.http.routers.whoami.entrypoints=web,\
            traefik.http.routers.whoami.rule=Host(`ks3.minimalgap.com`)"
```

The value for the `service-tags` annotation must be all in one line, tags separated with commas, and no spaces. In order to make it more readable, the line is wrapped onto multiple lines with the `\` character after the commas.
This is different by employing a pure Kubernetes Provider Configuration in Traefik Proxy, where you would expect these values in the definition of an `Ingress` component.

After deploying a service annotated as above, if you now access the Traefik Dashboard you will notice that the `Whoami` service is now marked with `Consul Catalog` provider.

`Note`: Remember to set up a valid and correct FQDN in the `service-tags` annotation for the `Host Rule` in the router section.

## Note on TLS

You may note that the service above is exposed on a simple HTTP endpoint, skipping TLS support.
I struggled a little bit with configuring TLS. As far as I know a `Let's Encrypt resolver` should be employed.

This requires a further configuration for the Traefik Proxy CLI, e.g.:

```yaml
## TLS CHALLENGE
- --certificatesresolvers.autoresolver.acme.tlschallenge
## LetsEncrypt definitions
- --certificatesresolvers.autoresolver.acme.email=foo@you.com
- --certificatesresolvers.autoresolver.acme.storage=acme.json
## Please note that this is the staging Let's Encrypt server.
## Once you get things working, you should remove that whole line altogether.
- --certificatesresolvers.autoresolver.acme.caserver=https://acme-staging-v02.api.letsencrypt.org/directory
```

and the corresponding reference in the service discovered via Consul, changing the service-tags annotation:

```yaml
annotations:
  traefik.enable=true,\
  traefik.http.routers.whoami.entrypoints=web,\
  traefik.http.routers.whoami.rule=Host(`ks3.minimalgap.com`),\
  traefik.http.routers.whoami.tls=true,\
  traefik.http.routers.whoami.tls.certresolver=autoresolver"
```

Since this topic it's outside of the scope of this post, for sake of simplicity I left apart the TLS configuration.
I advise you to carefully read the Traefik Proxy, [User Guide](https://doc.traefik.io/traefik/user-guides/crd-acme/) section to attempt a fully TLS configuration.
Moreover the whole process would be much simpler if you own a domain that is compliant with the [dnsChallenge](https://doc.traefik.io/traefik/https/acme/#dnschallenge).

### Playing with Consul Intentions

It's now time for fun!
So far we have configured:

- Consul Connect (via Helm)
- Traefik Proxy (with Consul Catalog provider)
- a service (_whoami_) that is _visible_ by both Consul Connect and Traefik Proxy

Now we can access the service using `cUrl`. This can be tricky depending from your configuration, you may use:

- `Port Forwarding` the whole Traefik service (Gotcha `sudoing`, check [here](https://doc.traefik.io/traefik/user-guides/crd-acme/#port-forwarding))

```bash
kubectl  port-forward --address 0.0.0.0 service/traefik 80:80 8080:8080 -n traefik-consul
```

- Attaching a `shell` to a Pod and executing _curl_ from there (if cUrl is available within the Pod itself)

```bash
kubectl exec -ti -n consul-system consul-server-0 -- curl http://ks3.minimalgap.com:80
```

- Creating a `K8s IngressRoute` in Traefik Proxy

Let's suppose one of the above finally works. The response would be something like:

```bash
curl http://ks3.minimalgap.com:80 -vv
*   Trying 34.240.156.240:80...
* Connected to ks3.minimalgap.com (34.240.156.240) port 80 (#0)
> GET / HTTP/1.1
> Host: ks3.minimalgap.com
> User-Agent: curl/7.79.1
> Accept: */*
>
* Mark bundle as not supporting multiuse
< HTTP/1.1 200 OK
IP: 127.0.0.1
IP: ::1
IP: 10.42.0.140
IP: fe80::d09e:6dff:feee:cb78
RemoteAddr: 127.0.0.1:43100
GET / HTTP/1.1
Host: ks3.minimalgap.com
User-Agent: curl/7.79.1
Accept: */*
Accept-Encoding: gzip
X-Forwarded-For: 10.42.0.139
X-Forwarded-Host: ks3.minimalgap.com
X-Forwarded-Port: 80
X-Forwarded-Proto: http
X-Forwarded-Server: traefik-f9bbb4fb8-fzx6v
X-Real-Ip: 10.42.0.139
```

At this point we can state we achieved a working configuration. It's time to create `Intentions`!
Consul Intentions are more or less firewall rules for services, they have a Source Service, a Target Service, a Description and a Deny/Allow option.
These rules can easily be visually created from the Consul Dashboard. Suppose that we want to create a Deny All rule:

- \* (All Services) for the Source Service
- \* (All Services) for the Destination Service
- Should this source connect to the destination? choose Deny
- click Save to create the Intention.

Now test the _whoami_ service again, using your real service domain name:

```bash
curl http://ks3.minimalgap.com:80 -vv
```

You should see a response of `502 Bad Gateway`.
`Note`: the response may be still _200 OK_ for few minutes. This is because the Intentions may take some time to update to the envoy sidecar. I promise after a while the Bad Gateway response should come up!

Alternatively Consul Intentions can be configured via Kubernetes API. This is achieved via K8s CRDs. Let's use this method to configure an `Allow` Rule from the Traefik Proxy (`traefik-system-ingress`) to the destination service (_whoami_).

First define a Service Definition CRD:

```yaml
apiVersion: consul.hashicorp.com/v1alpha1
kind: ServiceDefaults
metadata:
  name: whoami
  namespace: consul-demo
spec:
  protocol: 'http'
```

The Service Intentions can be defined via YAML in a similar way respect to Consul Dashboard:

```yaml
apiVersion: consul.hashicorp.com/v1alpha1
kind: ServiceIntentions
metadata:
  name: whoami
  namespace: consul-demo
spec:
  destination:
    # Name of the destination service affected by this ServiceIntentions entry.
    name: whoami
  sources:
    # The set of traffic sources affected by this ServiceIntentions entry.
    # When the source is the Traefik Proxy:
    - name: traefik-system-ingress
      # The set of permissions to apply for Traefik Proxy to access whoami:
      # The first permission to match in the list is terminal, and stops further evaluation.
      permissions:
        - action: allow
```

Accessing the endpoint should stop giving (quite immediately) a `Bad Gateway` response in favour of a successful response again.

## Conclusions

[Traefik Labs](https://traefik.io/) keeps on doing giant leaps and integrating Consul Connect is another step beyond for `Traefik Proxy`. This indicates the path of this product is humble but reliable and flexible, with an open-minded philosophy behind that is never scared of comparing and collaborating with other important competitors and actors in the CNCF big landscape picture.

Probably `Consul Connect` is a product more suitable in advanced use cases where big clusters are involved. But Consul Connect integration is a kind of Enterprise level feature that demonstrates how Traefik Proxy is powerful: it works the same way, from the homemade pet project to a huge diverse enterprise cluster.
