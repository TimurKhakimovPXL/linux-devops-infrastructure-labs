> [!NOTE]
> This is a sanitized copy of an internship lab document. Names, addresses, credentials, and other internal details use placeholders. Review the commands before applying them elsewhere.

# Kubernetes and OpenShift Basics

Kubernetes works like an operating system for a cluster. You declare the state you want, and its controllers keep working to bring the cluster back to that state.

## 1. Pods

A Pod is the smallest unit Kubernetes deploys. It contains one or more containers that share an IP address, network namespace, and any volumes declared by the Pod. Containers in the same Pod can reach one another through `localhost` and are scheduled together.

```text
Pod
 ├─ nginx container
 └─ sidecar container (log collector)
```

## 2. ReplicaSets

A ReplicaSet keeps a requested number of identical Pods running. With `replicas: 3`, Kubernetes creates replacements whenever the count falls below three.

```yaml
replicas: 3
```

ReplicaSets are normally created and managed through Deployments rather than edited directly.

## 3. Deployments

A Deployment manages ReplicaSets and handles application rollouts and rollbacks.

```text
Deployment
  └─ ReplicaSet
       └─ Pods
```

Changing an image from `nginx:v1` to `nginx:v2` starts a rolling update: new Pods become ready while old Pods are removed gradually.

## 4. DaemonSets

A DaemonSet runs one Pod on every matching node. Common examples include log collectors, monitoring agents, and node-level networking components.

## 5. StatefulSets

StatefulSets are intended for workloads that need stable identity or storage, such as databases, Kafka, and etcd. They provide predictable Pod names such as `db-0`, `db-1`, and `db-2`, persistent volume associations, and ordered startup or shutdown.

## 6. Services

Pod IP addresses are temporary. A Service gives a changing set of Pods one stable network endpoint.

- **ClusterIP:** exposes the Service only inside the cluster.
- **NodePort:** opens the same high port on each node, such as `30007`.
- **LoadBalancer:** asks the platform's load-balancer integration for an external address.

## 7. OpenShift Routes

An OpenShift Route publishes a Service through an HTTP or HTTPS hostname.

```text
Internet
   ↓
OpenShift Router
   ↓
Service
   ↓
Pods
```

## 8. Namespaces and Projects

A Kubernetes namespace groups resources and provides a boundary for names, RBAC, and quotas. Typical examples include:

```text
dev
prod
monitoring
```

An OpenShift Project is a namespace presented through OpenShift's API and user interface, with additional project-oriented defaults and policy controls.
